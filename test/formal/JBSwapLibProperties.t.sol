// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {JBSwapLib} from "../../src/libraries/JBSwapLib.sol";

/// @notice Functional-correctness properties for `JBSwapLib` beyond the existing `JBSwapLibHalmos` smoke set.
/// @dev Each property is dual-implemented: a `check_*` entrypoint for Halmos symbolic proof and a `testFuzz_*`
/// wrapper for forge fuzzing. The slippage-tolerance properties are SMT-tractable (only `mulDiv` by symbolic
/// values inside well-bounded ranges, plus constant comparisons); the price-limit range/monotonicity properties
/// that exercise the full `Math.sqrt`/`mulDiv` 512-bit domain are verified by FUZZ ONLY (Halmos would time out on
/// the square-root domain) and are marked accordingly.
contract JBSwapLibProperties is Test {
    /// @notice The hard slippage ceiling (88%) used by `JBSwapLib.getSlippageTolerance`.
    uint256 internal constant _MAX_SLIPPAGE = 8800;

    /// @notice The minimum-floor constant (2%) used by `JBSwapLib.getSlippageTolerance`.
    uint256 internal constant _FLOOR = 200;

    // ------------------------------------------------------------------ //
    // getSlippageTolerance: bounds, floor, ceiling, monotonicity         //
    // ------------------------------------------------------------------ //

    /// @notice Property: the returned tolerance is ALWAYS within the documented [floor, ceiling] band.
    /// @dev Spec (JBSwapLib NatSpec): "Floor of 2% (or pool fee + 1%), ceiling of 88%." So the result is never
    /// below the floor and never above the ceiling, regardless of impact or pool fee.
    function _prop_toleranceWithinBand(uint256 impact, uint256 poolFeeBps) internal pure {
        uint256 tolerance = JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: poolFeeBps});
        assert(tolerance >= _FLOOR);
        assert(tolerance <= _MAX_SLIPPAGE);
    }

    function check_toleranceWithinBand(uint256 impact, uint256 poolFeeBps) public pure {
        _prop_toleranceWithinBand(impact, poolFeeBps);
    }

    function testFuzz_toleranceWithinBand(uint256 impact, uint256 poolFeeBps) public pure {
        _prop_toleranceWithinBand(impact, poolFeeBps);
    }

    /// @notice Property: the tolerance is never below the effective minimum slippage (pool fee + 1% buffer, floored
    /// at 2%, capped at the ceiling). The sigmoid only ever ADDS to the minimum.
    function _prop_toleranceAtLeastMin(uint256 impact, uint256 poolFeeBps) internal pure {
        // Recompute the expected effective minimum the same way the library does.
        uint256 expectedMin;
        if (poolFeeBps >= _MAX_SLIPPAGE) {
            expectedMin = _MAX_SLIPPAGE;
        } else {
            expectedMin = poolFeeBps + 100;
            if (expectedMin < _FLOOR) expectedMin = _FLOOR;
            if (expectedMin > _MAX_SLIPPAGE) expectedMin = _MAX_SLIPPAGE;
        }

        uint256 tolerance = JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: poolFeeBps});
        assert(tolerance >= expectedMin);
    }

    function check_toleranceAtLeastMin(uint256 impact, uint256 poolFeeBps) public pure {
        _prop_toleranceAtLeastMin(impact, poolFeeBps);
    }

    function testFuzz_toleranceAtLeastMin(uint256 impact, uint256 poolFeeBps) public pure {
        _prop_toleranceAtLeastMin(impact, poolFeeBps);
    }

    /// @notice Property: monotonicity in impact — for a FIXED pool fee, a larger impact never yields a smaller
    /// slippage tolerance. The sigmoid term `range * impact / (impact + K)` is monotonically non-decreasing in
    /// `impact`, so allowing more impact must (weakly) widen the allowed slippage. A regression that inverted this
    /// would silently tighten tolerance on big swaps and revert otherwise-valid routes.
    /// @dev Bounded to the non-overflow domain (`impact <= type(uint256).max - K`) where the sigmoid branch runs;
    /// beyond that both inputs short-circuit to the ceiling, which is trivially monotone.
    function _prop_monotoneInImpact(uint256 impactLow, uint256 impactDelta, uint256 poolFeeBps) internal pure {
        uint256 K = 5e16;
        // Keep both impacts inside the sigmoid (non-overflow) domain so we test the curve, not the cap branch.
        vm.assume(impactLow <= type(uint256).max - K);
        vm.assume(impactDelta <= type(uint256).max - K - impactLow);
        uint256 impactHigh = impactLow + impactDelta;

        uint256 tLow = JBSwapLib.getSlippageTolerance({impact: impactLow, poolFeeBps: poolFeeBps});
        uint256 tHigh = JBSwapLib.getSlippageTolerance({impact: impactHigh, poolFeeBps: poolFeeBps});

        assert(tHigh >= tLow);
    }

    function testFuzz_monotoneInImpact(uint256 impactLow, uint256 impactDelta, uint256 poolFeeBps) public pure {
        _prop_monotoneInImpact(impactLow, impactDelta, poolFeeBps);
    }

    /// @notice Property: when the pool fee alone meets/exceeds the ceiling, the tolerance is exactly the ceiling,
    /// independent of impact. (Generalizes the existing `check_poolFeeAtCeilingReturnsCeiling` to symbolic fee.)
    function _prop_feeAtOrAboveCeilingPinsCeiling(uint256 impact, uint256 poolFeeBps) internal pure {
        vm.assume(poolFeeBps >= _MAX_SLIPPAGE);
        assert(JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: poolFeeBps}) == _MAX_SLIPPAGE);
    }

    function check_feeAtOrAboveCeilingPinsCeiling(uint256 impact, uint256 poolFeeBps) public pure {
        _prop_feeAtOrAboveCeilingPinsCeiling(impact, poolFeeBps);
    }

    function testFuzz_feeAtOrAboveCeilingPinsCeiling(uint256 impact, uint256 poolFeeBps) public pure {
        _prop_feeAtOrAboveCeilingPinsCeiling(impact, poolFeeBps);
    }

    // ------------------------------------------------------------------ //
    // sqrtPriceLimitFromAmounts: direction sentinels + valid V3 range    //
    // ------------------------------------------------------------------ //

    /// @notice Property: the returned price limit is ALWAYS a strictly-in-range V3 sqrt price for ANY inputs.
    /// @dev Spec: the helper "Compute a sqrtPriceLimitX96" that Uniswap will accept. Uniswap V3 requires
    /// MIN_SQRT_RATIO < limit < MAX_SQRT_RATIO. This generalizes the existing positive-amount check to the full
    /// domain (including the zero short-circuits and the X128/X192 branches). FUZZ ONLY — the sqrt/mulDiv domain
    /// is intractable for Halmos.
    function _prop_priceLimitAlwaysInV3Range(uint256 amountIn, uint256 minOut, bool zeroForOne) internal pure {
        uint160 limit =
            JBSwapLib.sqrtPriceLimitFromAmounts({amountIn: amountIn, minimumAmountOut: minOut, zeroForOne: zeroForOne});
        assert(limit > TickMath.MIN_SQRT_RATIO);
        assert(limit < TickMath.MAX_SQRT_RATIO);
    }

    function testFuzz_priceLimitAlwaysInV3Range(uint256 amountIn, uint256 minOut, bool zeroForOne) public pure {
        _prop_priceLimitAlwaysInV3Range(amountIn, minOut, zeroForOne);
    }

    /// @notice Property: the NO-LIMIT short-circuit sentinel is direction-consistent. When there is no usable
    /// constraint (`minimumAmountOut == 0` OR `amountIn == 0` OR the ratio is too large to express), the helper
    /// returns the directional "no limit" sentinel: the MIN side for zeroForOne (price decreases), the MAX side
    /// for !zeroForOne (price increases). A swapped sentinel would make an unconstrained swap immediately hit its
    /// own limit and return nothing.
    /// @dev This targets ONLY the unconstrained branches. NOTE: when a real (constrained) limit is computed, the
    /// in-range clamp may legitimately return EITHER endpoint sentinel for EITHER direction (e.g. !zeroForOne with
    /// a huge min-out implies a near-zero price that clamps to MIN+1). That clamp behavior is covered by
    /// `testFuzz_priceLimitAlwaysInV3Range`; it is NOT a direction-violation, so it is excluded here.
    function testFuzz_noLimitSentinelDirection(uint256 freeValue, bool zeroAmountIn, bool zeroForOne) public pure {
        // Construct (rather than assume) the unconstrained short-circuit domain: exactly one side is zero, the
        // other is an arbitrary fuzzed value. This hits both `amountIn == 0` and `minimumAmountOut == 0` branches
        // without rejecting inputs.
        uint256 amountIn = zeroAmountIn ? 0 : freeValue;
        uint256 minOut = zeroAmountIn ? freeValue : 0;

        uint160 limit =
            JBSwapLib.sqrtPriceLimitFromAmounts({amountIn: amountIn, minimumAmountOut: minOut, zeroForOne: zeroForOne});

        if (zeroForOne) {
            assertEq(uint256(limit), uint256(TickMath.MIN_SQRT_RATIO) + 1, "zeroForOne no-limit must be MIN sentinel");
        } else {
            assertEq(uint256(limit), uint256(TickMath.MAX_SQRT_RATIO) - 1, "!zeroForOne no-limit must be MAX sentinel");
        }
    }

    /// @notice Halmos twin of `testFuzz_noLimitSentinelDirection`: the no-limit short-circuit branch is pure (no
    /// sqrt/mulDiv), so it is SMT-tractable. Symbolically proves the directional sentinel for every input where one
    /// side is zero.
    function check_noLimitSentinelDirection(uint256 freeValue, bool zeroAmountIn, bool zeroForOne) public pure {
        uint256 amountIn = zeroAmountIn ? 0 : freeValue;
        uint256 minOut = zeroAmountIn ? freeValue : 0;

        uint160 limit =
            JBSwapLib.sqrtPriceLimitFromAmounts({amountIn: amountIn, minimumAmountOut: minOut, zeroForOne: zeroForOne});

        if (zeroForOne) {
            assert(limit == TickMath.MIN_SQRT_RATIO + 1);
        } else {
            assert(limit == TickMath.MAX_SQRT_RATIO - 1);
        }
    }

    /// @notice Property: tightening the minimum-acceptable output never RELAXES the price limit. For a fixed
    /// input/direction, a larger `minimumAmountOut` demands a better execution price, which for zeroForOne means a
    /// HIGHER (less aggressive downward) sqrt limit and for !zeroForOne means a LOWER (less aggressive upward)
    /// sqrt limit. FUZZ ONLY (sqrt domain). This is the core safety guarantee: asking for more output cannot make
    /// the swap willing to accept a worse price.
    function testFuzz_priceLimitMonotoneInMinOut(
        uint256 amountIn,
        uint256 minOutLow,
        uint256 minOutDelta,
        bool zeroForOne
    )
        public
        pure
    {
        // Use bounded, realistic magnitudes so both minimums land in normal/extended (non-fallback) ranges and the
        // monotonic relationship is meaningful (the no-limit fallbacks clamp and are tested separately).
        amountIn = _bound(amountIn, 1, 1e30);
        minOutLow = _bound(minOutLow, 1, 1e30);
        minOutDelta = _bound(minOutDelta, 0, 1e30);
        uint256 minOutHigh = minOutLow + minOutDelta;

        uint160 limitLow = JBSwapLib.sqrtPriceLimitFromAmounts({
            amountIn: amountIn, minimumAmountOut: minOutLow, zeroForOne: zeroForOne
        });
        uint160 limitHigh = JBSwapLib.sqrtPriceLimitFromAmounts({
            amountIn: amountIn, minimumAmountOut: minOutHigh, zeroForOne: zeroForOne
        });

        if (zeroForOne) {
            // Selling token0: price moves down. A stricter min-out raises the floor sqrt price (>=).
            assertGe(limitHigh, limitLow, "zeroForOne: stricter minOut lowered the price floor");
        } else {
            // Buying token0: price moves up. A stricter min-out lowers the ceiling sqrt price (<=).
            assertLe(limitHigh, limitLow, "!zeroForOne: stricter minOut raised the price ceiling");
        }
    }
}
