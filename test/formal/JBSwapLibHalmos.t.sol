// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {JBSwapLib} from "../../src/libraries/JBSwapLib.sol";

/// @notice Small Halmos entrypoints for router-terminal swap math.
/// @dev These proofs stay on pure helper branches so CI can prove core slippage limits without deploying pools.
contract JBSwapLibHalmos {
    /// @notice The hard ceiling used by `JBSwapLib.getSlippageTolerance`.
    uint256 internal constant _MAX_SLIPPAGE = 8800;

    /// @notice Proves zero impact returns the minimum tolerance floor exactly.
    function check_zeroImpactReturnsFloor(uint16 poolFeeBps) public pure {
        uint256 tolerance = JBSwapLib.getSlippageTolerance({impact: 0, poolFeeBps: uint256(poolFeeBps)});

        uint256 expectedFloor = uint256(poolFeeBps) + 100;
        if (expectedFloor < 200) expectedFloor = 200;
        if (expectedFloor > _MAX_SLIPPAGE) expectedFloor = _MAX_SLIPPAGE;

        assert(tolerance == expectedFloor);
    }

    /// @notice Proves pool fees at or above the ceiling always return the ceiling.
    function check_poolFeeAtCeilingReturnsCeiling(uint256 impact, uint16 excessFeeBps) public pure {
        uint256 poolFeeBps = _MAX_SLIPPAGE + uint256(excessFeeBps);

        assert(JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: poolFeeBps}) == _MAX_SLIPPAGE);
    }

    /// @notice Proves overflow-risk impact values return the ceiling before adding the sigmoid constant.
    function check_overflowImpactReturnsCeiling(uint32 excessImpact, uint16 poolFeeBps) public pure {
        uint256 impact = type(uint256).max - 5e16 + 1 + uint256(excessImpact);

        assert(JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: uint256(poolFeeBps)}) == _MAX_SLIPPAGE);
    }

    /// @notice Proves the impact estimator soft-fails to zero for missing liquidity.
    function check_calculateImpactZeroLiquidityReturnsZero(
        uint64 amountIn,
        uint160 sqrtP,
        bool zeroForOne
    )
        public
        pure
    {
        assert(
            JBSwapLib.calculateImpact({amountIn: uint256(amountIn), liquidity: 0, sqrtP: sqrtP, zeroForOne: zeroForOne})
                == 0
        );
    }

    /// @notice Proves the impact estimator soft-fails to zero for missing price.
    function check_calculateImpactZeroPriceReturnsZero(
        uint64 amountIn,
        uint128 liquidity,
        bool zeroForOne
    )
        public
        pure
    {
        assert(
            JBSwapLib.calculateImpact({
                amountIn: uint256(amountIn), liquidity: liquidity, sqrtP: 0, zeroForOne: zeroForOne
            }) == 0
        );
    }

    /// @notice Proves no-minimum-output swaps map to the directional V3 no-limit sentinel.
    function check_zeroMinimumOutputReturnsNoLimit(uint64 amountIn, bool zeroForOne) public pure {
        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts({
            amountIn: uint256(amountIn), minimumAmountOut: 0, zeroForOne: zeroForOne
        });

        assert(limit == (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1));
    }

    /// @notice Proves zero-input swaps map to the same directional no-limit sentinel.
    function check_zeroAmountInReturnsNoLimit(uint64 minimumAmountOut, bool zeroForOne) public pure {
        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts({
            amountIn: 0, minimumAmountOut: uint256(minimumAmountOut), zeroForOne: zeroForOne
        });

        assert(limit == (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1));
    }

    /// @notice Proves bounded positive amount ratios always produce valid V3 price-limit sentinels or in-range limits.
    function check_boundedPositivePriceLimitStaysInV3Range(
        uint64 amountIn,
        uint64 minimumAmountOut,
        bool zeroForOne
    )
        public
        pure
    {
        if (amountIn == 0 || minimumAmountOut == 0) return;

        uint160 limit = JBSwapLib.sqrtPriceLimitFromAmounts({
            amountIn: uint256(amountIn), minimumAmountOut: uint256(minimumAmountOut), zeroForOne: zeroForOne
        });

        assert(limit > TickMath.MIN_SQRT_RATIO);
        assert(limit < TickMath.MAX_SQRT_RATIO);
    }
}
