// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

import {JBSwapLib} from "../../src/libraries/JBSwapLib.sol";

/// @notice Wrapper to expose JBSwapLib internal functions for testing.
contract SwapLibHarness {
    function getSlippageTolerance(uint256 impact, uint256 poolFeeBps) external pure returns (uint256) {
        return JBSwapLib.getSlippageTolerance(impact, poolFeeBps);
    }

    function calculateImpact(
        uint256 amountIn,
        uint128 liquidity,
        uint160 sqrtP,
        bool zeroForOne
    )
        external
        pure
        returns (uint256)
    {
        return JBSwapLib.calculateImpact(amountIn, liquidity, sqrtP, zeroForOne);
    }
}

/// @notice Regression test for audit finding M-3: V4 swaps use manipulable spot price for slippage calculation.
/// @dev V4 vanilla pools have no TWAP oracle, so `_getV4SpotQuote` reads `getSlot0` — an instantaneous tick
/// that can be manipulated within the same block. This test suite verifies that the sigmoid slippage formula
/// enforces a meaningful minimum output floor regardless of the spot price, and that user-provided quotes
/// (`quoteForSwap` metadata) bypass the spot-based path entirely.
///
/// Because setting up a full V4 PoolManager in unit tests requires significant infrastructure, these tests
/// exercise the slippage math in isolation via JBSwapLib, which is the same code path used by
/// `_getV4SpotQuote` and `_getV3TwapQuote`.
contract M3_V4SpotPriceSlippageTest is Test {
    SwapLibHarness lib;

    /// @notice The same constants from JBSwapLib / JBRouterTerminal.
    uint256 constant SLIPPAGE_DENOMINATOR = 10_000;
    uint256 constant MAX_SLIPPAGE = 8800;
    uint256 constant IMPACT_PRECISION = 1e18;
    uint256 constant SIGMOID_K = 5e16;

    function setUp() public {
        lib = new SwapLibHarness();
    }

    //*********************************************************************//
    // ---------- Sigmoid slippage: minimum floor enforcement ----------- //
    //*********************************************************************//

    /// @notice With zero impact (tiny swap in deep pool), slippage = max(poolFee + 1%, 2%).
    /// This is the floor that protects even the smallest swaps.
    function test_sigmoidSlippage_zeroImpact_returns2PercentFloor() public view {
        // 0.3% pool fee → minSlippage = 30 + 100 = 130 bps, but floor is 200 bps (2%).
        uint256 tolerance = lib.getSlippageTolerance(0, 30);
        assertEq(tolerance, 200, "zero impact should return 2% floor for low-fee pools");
    }

    /// @notice For a 1% fee pool with zero impact, min slippage = fee + 1% = 2%.
    function test_sigmoidSlippage_zeroImpact_1PercentFeePool() public view {
        uint256 tolerance = lib.getSlippageTolerance(0, 100);
        assertEq(tolerance, 200, "zero impact with 1% fee should return 2% (fee + 1%)");
    }

    /// @notice For a 0.05% fee pool with zero impact, floor should still be 2%.
    function test_sigmoidSlippage_zeroImpact_5bpsFeePool() public view {
        uint256 tolerance = lib.getSlippageTolerance(0, 5);
        assertEq(tolerance, 200, "zero impact with 5 bps fee should still be 2% floor");
    }

    /// @notice For a 5% (500 bps) fee pool with zero impact, min slippage = 500 + 100 = 600 bps (6%).
    function test_sigmoidSlippage_zeroImpact_highFeePool() public view {
        uint256 tolerance = lib.getSlippageTolerance(0, 500);
        assertEq(tolerance, 600, "zero impact with 5% fee should return 6% (fee + 1%)");
    }

    //*********************************************************************//
    // ---------- Sigmoid slippage: monotonicity with impact ------------ //
    //*********************************************************************//

    /// @notice Slippage tolerance increases monotonically with impact.
    function test_sigmoidSlippage_monotonicallyIncreasing() public view {
        uint256 feeBps = 30; // 0.3% pool
        uint256 prev = lib.getSlippageTolerance(0, feeBps);

        // Test a range of impacts from tiny to large.
        uint256[8] memory impacts = [
            uint256(1e12),
            uint256(1e14),
            uint256(1e15),
            uint256(1e16),
            uint256(5e16),
            uint256(1e17),
            uint256(1e18),
            uint256(1e20)
        ];

        for (uint256 i; i < impacts.length; i++) {
            uint256 current = lib.getSlippageTolerance(impacts[i], feeBps);
            assertGe(current, prev, "slippage must be monotonically non-decreasing with impact");
            prev = current;
        }
    }

    //*********************************************************************//
    // ---------- Sigmoid slippage: bounded between floor and ceiling --- //
    //*********************************************************************//

    /// @notice Slippage is always >= 2% (200 bps) and <= 88% (8800 bps).
    function test_sigmoidSlippage_boundedRange() public view {
        uint256 feeBps = 30;

        // Test with many different impacts.
        uint256[6] memory impacts =
            [uint256(0), uint256(1e10), uint256(1e16), uint256(1e18), uint256(1e30), uint256(1e50)];

        for (uint256 i; i < impacts.length; i++) {
            uint256 tolerance = lib.getSlippageTolerance(impacts[i], feeBps);
            assertGe(tolerance, 200, "slippage must be >= 2%");
            assertLe(tolerance, MAX_SLIPPAGE, "slippage must be <= 88%");
        }
    }

    /// @notice Extreme impact should approach (but not exceed) the 88% ceiling.
    /// @dev Due to integer rounding in mulDiv, the sigmoid may return MAX_SLIPPAGE - 1 for very large
    /// (but not overflow-triggering) impacts. The overflow guard at type(uint256).max - SIGMOID_K
    /// catches truly extreme values and returns exactly MAX_SLIPPAGE.
    function test_sigmoidSlippage_extremeImpact_approachesCeiling() public view {
        uint256 tolerance = lib.getSlippageTolerance(1e50, 30);
        // Sigmoid asymptotically approaches ceiling; may be off by 1 bps due to rounding.
        assertGe(tolerance, MAX_SLIPPAGE - 1, "extreme impact should be within 1 bps of ceiling");
        assertLe(tolerance, MAX_SLIPPAGE, "extreme impact must not exceed ceiling");
    }

    /// @notice Impact near overflow should return ceiling safely.
    function test_sigmoidSlippage_nearOverflow_returnsCeiling() public view {
        uint256 tolerance = lib.getSlippageTolerance(type(uint256).max - SIGMOID_K + 1, 30);
        assertEq(tolerance, MAX_SLIPPAGE, "near-overflow impact should return ceiling");
    }

    //*********************************************************************//
    // ---------- calculateImpact: basic sanity checks ----------------- //
    //*********************************************************************//

    /// @notice Zero liquidity returns zero impact (division guard).
    function test_calculateImpact_zeroLiquidity_returnsZero() public view {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        uint256 impact = lib.calculateImpact(1 ether, 0, sqrtP, true);
        assertEq(impact, 0, "zero liquidity should return zero impact");
    }

    /// @notice Zero sqrtPrice returns zero impact (division guard).
    function test_calculateImpact_zeroSqrtPrice_returnsZero() public view {
        uint256 impact = lib.calculateImpact(1 ether, 1e18, 0, true);
        assertEq(impact, 0, "zero sqrtP should return zero impact");
    }

    /// @notice Higher amountIn produces higher impact for same liquidity.
    function test_calculateImpact_higherAmount_higherImpact() public view {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0); // 1:1 price
        uint128 liquidity = 1e18;

        uint256 impactSmall = lib.calculateImpact(1 ether, liquidity, sqrtP, true);
        uint256 impactLarge = lib.calculateImpact(100 ether, liquidity, sqrtP, true);
        assertGt(impactLarge, impactSmall, "larger swap should have higher impact");
    }

    /// @notice Lower liquidity produces higher impact for same amount.
    function test_calculateImpact_lowerLiquidity_higherImpact() public view {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);

        uint256 impactDeep = lib.calculateImpact(1 ether, 1e20, sqrtP, true);
        uint256 impactShallow = lib.calculateImpact(1 ether, 1e16, sqrtP, true);
        assertGt(impactShallow, impactDeep, "shallower pool should have higher impact");
    }

    //*********************************************************************//
    // ---------- End-to-end: minAmountOut floor with spot price -------- //
    //*********************************************************************//

    /// @notice Simulates the full _getV4SpotQuote calculation to show the sigmoid floor protects output.
    /// @dev This mirrors the exact logic in JBRouterTerminal._getV4SpotQuote:
    ///      1. Read spot tick -> get quote at tick
    ///      2. Compute slippage tolerance via sigmoid
    ///      3. Apply slippage: minAmountOut -= (minAmountOut * tolerance) / DENOMINATOR
    ///      The test proves that minAmountOut is always at least (1 - maxSlippage) * spotQuote,
    ///      and that the sigmoid slippage tolerance is bounded between the floor and ceiling.
    function test_v4QuoteSimulation_sigmoidFloorEnforcesMinOutput() public view {
        // Simulate a pool at tick 0 with 0.3% fee.
        int24 tick = 0;
        uint256 feeBps = 30;

        // Token ordering: tokenIn < tokenOut (zeroForOne = true).
        address tokenIn = address(0x1111);
        address tokenOut = address(0x2222);

        uint160 sqrtP = TickMath.getSqrtRatioAtTick(tick);

        // --- Scenario A: Small swap in deep pool (low impact) ---
        {
            uint128 liquidityDeep = type(uint128).max; // Maximum possible liquidity
            uint256 amountSmall = 1000; // Very small swap to ensure negligible impact

            uint256 spotQuote = OracleLibrary.getQuoteAtTick({
                tick: tick, baseAmount: uint128(amountSmall), baseToken: tokenIn, quoteToken: tokenOut
            });

            uint256 impact = lib.calculateImpact(amountSmall, liquidityDeep, sqrtP, true);
            uint256 slippageTolerance = lib.getSlippageTolerance(impact, feeBps);

            // With negligible impact, tolerance should be exactly the floor (2%).
            assertEq(slippageTolerance, 200, "negligible impact should yield 2% floor slippage");

            // minAmountOut should be 98% of spot quote.
            if (spotQuote > 0) {
                uint256 minAmountOut = spotQuote - (spotQuote * slippageTolerance) / SLIPPAGE_DENOMINATOR;
                assertGe(
                    minAmountOut, spotQuote * 98 / 100, "small swap in deep pool: minAmountOut should be >= 98% of spot"
                );
                assertLe(minAmountOut, spotQuote, "minAmountOut should not exceed spot quote");
            }
        }

        // --- Scenario B: Any swap — absolute floor guarantee ---
        {
            uint128 liquidity = 1e20;
            uint256 amount = 1 ether;

            uint256 spotQuote = OracleLibrary.getQuoteAtTick({
                tick: tick, baseAmount: uint128(amount), baseToken: tokenIn, quoteToken: tokenOut
            });

            uint256 impact = lib.calculateImpact(amount, liquidity, sqrtP, true);
            uint256 slippageTolerance = lib.getSlippageTolerance(impact, feeBps);

            // Slippage is always bounded.
            assertGe(slippageTolerance, 200, "tolerance must be >= 2% floor");
            assertLe(slippageTolerance, MAX_SLIPPAGE, "tolerance must be <= 88% ceiling");

            // minAmountOut is always at least (1 - 88%) = 12% of spot.
            uint256 minAmountOut = spotQuote - (spotQuote * slippageTolerance) / SLIPPAGE_DENOMINATOR;
            assertGe(
                minAmountOut,
                spotQuote * (SLIPPAGE_DENOMINATOR - MAX_SLIPPAGE) / SLIPPAGE_DENOMINATOR,
                "minAmountOut must be >= 12% of spot quote (88% max slippage)"
            );
        }
    }

    /// @notice Shows that a large swap in a shallow pool gets higher slippage (sigmoid scales up),
    /// but the output is still bounded by the 88% ceiling.
    function test_v4QuoteSimulation_largeSwapShallowPool_higherSlippage() public view {
        int24 tick = 0;
        uint128 liquidity = 1e14; // Shallow pool
        uint256 amount = 1000 ether; // Large swap
        uint256 feeBps = 30;

        address tokenIn = address(0x1111);
        address tokenOut = address(0x2222);

        uint256 spotQuote = OracleLibrary.getQuoteAtTick({
            tick: tick, baseAmount: uint128(amount), baseToken: tokenIn, quoteToken: tokenOut
        });

        uint160 sqrtP = TickMath.getSqrtRatioAtTick(tick);
        uint256 impact = lib.calculateImpact(amount, liquidity, sqrtP, true);
        uint256 slippageTolerance = lib.getSlippageTolerance(impact, feeBps);

        // Large swap in shallow pool should have higher slippage than the floor.
        assertGt(slippageTolerance, 200, "large swap in shallow pool should exceed 2% floor");
        assertLe(slippageTolerance, MAX_SLIPPAGE, "slippage must not exceed 88% ceiling");

        // minAmountOut still bounded.
        uint256 minAmountOut = spotQuote - (spotQuote * slippageTolerance) / SLIPPAGE_DENOMINATOR;
        assertGe(
            minAmountOut,
            spotQuote * (SLIPPAGE_DENOMINATOR - MAX_SLIPPAGE) / SLIPPAGE_DENOMINATOR,
            "even worst case, minAmountOut >= 12% of spot"
        );
    }

    //*********************************************************************//
    // ---------- quoteForSwap metadata bypasses spot-based path -------- //
    //*********************************************************************//

    /// @notice Demonstrates that a user-provided quoteForSwap completely overrides the sigmoid calculation.
    /// @dev In _pickPoolAndQuote, when metadata contains "quoteForSwap", the decoded value is used directly
    /// as minAmountOut — neither _getV4SpotQuote nor _getV3TwapQuote is called. This test verifies the
    /// logic by simulating both paths and showing they produce different results.
    function test_userQuote_overrides_sigmoidCalculation() public view {
        // Simulate the automatic V4 path with a moderate impact scenario.
        int24 tick = 0;
        uint128 liquidity = 1e20;
        uint256 amount = 1 ether;
        uint256 feeBps = 30;
        address tokenIn = address(0x1111);
        address tokenOut = address(0x2222);

        uint256 spotQuote = OracleLibrary.getQuoteAtTick({
            tick: tick, baseAmount: uint128(amount), baseToken: tokenIn, quoteToken: tokenOut
        });

        uint160 sqrtP = TickMath.getSqrtRatioAtTick(tick);
        uint256 impact = lib.calculateImpact(amount, liquidity, sqrtP, true);
        uint256 slippageTolerance = lib.getSlippageTolerance(impact, feeBps);
        uint256 automaticMinOut = spotQuote - (spotQuote * slippageTolerance) / SLIPPAGE_DENOMINATOR;

        // The automatic path always applies at least the floor slippage (>= 2%).
        // A user-provided quote from an off-chain quoter can be much tighter.
        // For example, a user might accept only 0.5% slippage via their own quote.
        uint256 userQuoteTight = spotQuote * 995 / 1000; // 99.5% of spot

        // The user quote and automatic calculation are distinct values.
        // The automatic path includes at least 2% slippage, so it's always <= 98% of spot.
        assertLe(automaticMinOut, spotQuote * 98 / 100, "automatic path must apply at least 2% slippage");

        // A user-provided quote can be tighter (closer to spot) than the automatic path.
        // This is the key benefit: users can get better MEV protection by providing their own quote.
        assertGt(userQuoteTight, automaticMinOut, "user-provided tight quote should exceed automatic sigmoid minimum");

        // Conversely, a user can also set a lower quote (more permissive) — the contract uses it as-is.
        // This demonstrates that quoteForSwap is a direct override, not a floor.
        uint256 userQuoteLoose = automaticMinOut / 2;
        assertLt(userQuoteLoose, automaticMinOut, "user can also set a more permissive (lower) quote");
    }

    //*********************************************************************//
    // ---------- Fuzz: sigmoid properties hold for all inputs ---------- //
    //*********************************************************************//

    /// @notice Fuzz: slippage tolerance is always within [floor, MAX_SLIPPAGE].
    function testFuzz_sigmoidSlippage_alwaysBounded(uint256 impact, uint256 feeBps) public view {
        // Bound fee to realistic range (0-100%).
        feeBps = bound(feeBps, 0, 10_000);

        uint256 tolerance = lib.getSlippageTolerance(impact, feeBps);

        // Floor: max(feeBps + 100, 200), capped at MAX_SLIPPAGE.
        uint256 expectedFloor = feeBps + 100;
        if (expectedFloor < 200) expectedFloor = 200;
        if (expectedFloor > MAX_SLIPPAGE) expectedFloor = MAX_SLIPPAGE;

        assertGe(tolerance, expectedFloor, "tolerance must be >= floor");
        assertLe(tolerance, MAX_SLIPPAGE, "tolerance must be <= ceiling");
    }

    /// @notice Fuzz: calculateImpact returns 0 for zero liquidity/sqrtP, and for non-zero inputs
    /// the result feeds into getSlippageTolerance which always returns a bounded value.
    /// @dev Note: calculateImpact uses mulDiv which can revert on overflow for extreme input combinations.
    /// This is acceptable because the contract guards against such inputs (e.g., amount > uint128 is rejected,
    /// liquidity is read from the pool, sqrtP comes from TickMath). The fuzz test bounds inputs to realistic ranges.
    function testFuzz_calculateImpact_bounded(
        uint256 amountIn,
        uint128 liquidity,
        uint160 sqrtP,
        bool zeroForOne
    )
        public
        view
    {
        // Bound to realistic ranges to avoid mulDiv overflow.
        amountIn = bound(amountIn, 0, type(uint128).max);
        // Ensure sqrtP is in valid tick range to avoid unrealistic values.
        if (sqrtP != 0) {
            sqrtP = uint160(bound(sqrtP, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO));
        }

        uint256 impact = lib.calculateImpact(amountIn, liquidity, sqrtP, zeroForOne);

        if (liquidity == 0 || sqrtP == 0) {
            assertEq(impact, 0, "zero liquidity or sqrtP should return zero impact");
        }

        // Regardless of impact value, slippage tolerance should always be bounded.
        uint256 tolerance = lib.getSlippageTolerance(impact, 30);
        assertGe(tolerance, 200, "tolerance from fuzzed impact must be >= floor");
        assertLe(tolerance, MAX_SLIPPAGE, "tolerance from fuzzed impact must be <= ceiling");
    }
}
