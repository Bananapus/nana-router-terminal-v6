// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
/// @notice Math library that computes dynamic slippage tolerances for Uniswap swaps using a continuous sigmoid curve
/// based on estimated price impact, and derives sqrtPriceLimitX96 values from minimum output amounts.
/// @dev Uses continuous sigmoid formula instead of stepped if/else brackets for smoother slippage tolerance across all
/// swap sizes. Floor of 2% (or pool fee + 1%), ceiling of 88%.
library JBSwapLib {
    /// @notice The precision multiplier for impact calculations.
    /// @dev Using 1e18 instead of 1e5 (10 * _SLIPPAGE_DENOMINATOR) gives 13 extra orders of magnitude,
    ///      preventing small-swap-in-deep-pool impacts from rounding to zero.
    uint256 internal constant _IMPACT_PRECISION = 1e18;

    /// @notice The maximum slippage ceiling (88%).
    uint256 internal constant _MAX_SLIPPAGE = 8800;

    /// @notice The K parameter for the sigmoid curve, scaled to match _IMPACT_PRECISION.
    /// @dev Preserves the same sigmoid shape as the original K=5000 with amplifier=1e5:
    ///      K_new / _IMPACT_PRECISION = K_old / (10 * _SLIPPAGE_DENOMINATOR)
    ///      → K_new = 5000 * 1e18 / 1e5 = 5e16
    uint256 internal constant _SIGMOID_K = 5e16;

    /// @notice The denominator used for slippage tolerance basis points.
    uint256 internal constant _SLIPPAGE_DENOMINATOR = 10_000;

    //*********************************************************************//
    // -------------------- Expected Output ----------------------------- //
    //*********************************************************************//

    /// @notice The output a single liquidity range gives for a swap after its price impact, before any LP fee.
    /// @dev Mirrors the buyback hook's `JBSwapLib.getExpectedAmountOut` with no fee, since route previews do not see
    ///      the pool's fee. Constant liquidity moves the sqrt price by the fraction `impact` (calculateImpact), so the
    ///      output is quote / (1 + impact).
    /// @param quote The oracle quote for the full input at the quoted price, before impact.
    /// @param impact The estimated price impact of the full input from calculateImpact (scaled by _IMPACT_PRECISION).
    /// @return amountOut The expected swap output.
    function getExpectedAmountOut(uint256 quote, uint256 impact) internal pure returns (uint256 amountOut) {
        // An impact past 1e36 (a million-fold price move) leaves no meaningful output, and bounding it keeps the
        // denominator below overflow for any input.
        if (impact > 1e36) return 0;
        return mulDiv({x: quote, y: _IMPACT_PRECISION, denominator: _IMPACT_PRECISION + impact});
    }

    /// @notice How a pay settles when its swap is limited to the issuance rate: the pool fills until its spot rate
    /// meets issuance, and the rest of the input mints at issuance.
    /// @dev Mirrors the buyback hook's `JBSwapLib.getExpectedSettlement` with no fee. In the single-range model of
    ///      `getExpectedAmountOut`, the spot rate after input fraction φ is quote / (1 + impact * φ)^2. The price
    ///      limit stops the swap where that meets issuance, at φ* = (u - 1) / impact with u = sqrt(quote / issuance),
    ///      and the swap leg then returns issuance * u * φ*.
    /// @param quote The oracle quote for the full input at the quoted price, before impact.
    /// @param impact The estimated price impact of the full input from calculateImpact (scaled by _IMPACT_PRECISION).
    /// @param issuanceTokenCount The tokens issuance gives for the full input.
    /// @return swapAmountOut The expected output of the swap leg.
    /// @return issuedAmountOut The tokens issuance gives for the input the swap leaves.
    function getExpectedSettlement(
        uint256 quote,
        uint256 impact,
        uint256 issuanceTokenCount
    )
        internal
        pure
        returns (uint256 swapAmountOut, uint256 issuedAmountOut)
    {
        // With no issuance or no impact the price limit never stops the swap. A quote 1e40 times issuance or more
        // also takes the full-input estimate, a conservative bound that keeps the square root in range.
        if (issuanceTokenCount != 0 && impact != 0 && quote / issuanceTokenCount < 1e40) {
            // u at 1e18 precision.
            uint256 u = Math.sqrt(mulDiv({x: quote, y: 1e36, denominator: issuanceTokenCount}));

            // A pool whose spot rate is no better than issuance is already at the price limit, so it takes nothing.
            if (u <= _IMPACT_PRECISION) return (0, issuanceTokenCount);

            // φ* at 1e18 precision; below 1, the swap stops at the price limit before using the whole input.
            uint256 filled = mulDiv({x: u - _IMPACT_PRECISION, y: _IMPACT_PRECISION, denominator: impact});
            if (filled < _IMPACT_PRECISION) {
                swapAmountOut = mulDiv({
                    x: mulDiv({x: issuanceTokenCount, y: u, denominator: _IMPACT_PRECISION}),
                    y: filled,
                    denominator: _IMPACT_PRECISION
                });
                issuedAmountOut =
                    mulDiv({x: issuanceTokenCount, y: _IMPACT_PRECISION - filled, denominator: _IMPACT_PRECISION});
                return (swapAmountOut, issuedAmountOut);
            }
        }

        swapAmountOut = getExpectedAmountOut({quote: quote, impact: impact});
    }

    //*********************************************************************//
    // -------------------- Slippage Tolerance -------------------------- //
    //*********************************************************************//

    /// @notice Compute a continuous sigmoid slippage tolerance based on swap impact and pool fee.
    /// @dev tolerance = minSlippage + (maxSlippage - minSlippage) * impact / (impact + K)
    ///      When impact is 0 (negligible swap in deep pool), returns minSlippage.
    /// @param impact The estimated price impact from calculateImpact (scaled by _IMPACT_PRECISION).
    /// @param poolFeeBps The pool fee in basis points (e.g., 30 for 0.3%).
    /// @return tolerance The slippage tolerance in basis points of _SLIPPAGE_DENOMINATOR.
    function getSlippageTolerance(uint256 impact, uint256 poolFeeBps) internal pure returns (uint256) {
        // If pool fee alone meets/exceeds the ceiling, return the ceiling.
        if (poolFeeBps >= _MAX_SLIPPAGE) return _MAX_SLIPPAGE;

        // Minimum slippage: at least pool fee + 1% buffer, with a floor of 2%.
        uint256 minSlippage = poolFeeBps + 100;
        if (minSlippage < 200) minSlippage = 200;
        if (minSlippage >= _MAX_SLIPPAGE) return _MAX_SLIPPAGE;

        // When impact is 0, sigmoid returns minSlippage directly.
        if (impact == 0) return minSlippage;

        // For extreme impact values, cap to prevent overflow in (impact + K).
        if (impact > type(uint256).max - _SIGMOID_K) return _MAX_SLIPPAGE;

        // Sigmoid: minSlippage + (maxSlippage - minSlippage) * impact / (impact + K)
        uint256 range = _MAX_SLIPPAGE - minSlippage;
        uint256 tolerance = minSlippage + mulDiv({x: range, y: impact, denominator: impact + _SIGMOID_K});

        // Return the bounded tolerance implied by the sigmoid curve.
        return tolerance;
    }

    //*********************************************************************//
    // -------------------- Impact Calculation -------------------------- //
    //*********************************************************************//

    /// @notice Estimate the price impact of a swap, scaled by _IMPACT_PRECISION.
    /// @dev Uses 1e18 precision to capture sub-basis-point impacts for small swaps in deep pools.
    /// @param amountIn The amount of tokens to swap in.
    /// @param liquidity The pool's in-range liquidity.
    /// @param sqrtP The sqrt price in Q96 format.
    /// @param zeroForOne Whether the swap is token0 → token1.
    /// @return impact The estimated price impact scaled by _IMPACT_PRECISION.
    function calculateImpact(
        uint256 amountIn,
        uint128 liquidity,
        uint160 sqrtP,
        bool zeroForOne
    )
        internal
        pure
        returns (uint256 impact)
    {
        // Treat empty-liquidity or zero-price inputs as having no meaningful impact estimate.
        if (liquidity == 0 || sqrtP == 0) return 0;

        // Scale the input amount against the pool liquidity so impact is expressed in the library's precision space.
        uint256 base = mulDiv({x: amountIn, y: _IMPACT_PRECISION, denominator: uint256(liquidity)});

        // Convert the liquidity-scaled input into a direction-aware price impact estimate.
        impact = zeroForOne
            ? mulDiv({x: base, y: uint256(sqrtP), denominator: uint256(1) << 96})
            : mulDiv({x: base, y: uint256(1) << 96, denominator: uint256(sqrtP)});
    }

    //*********************************************************************//
    // -------------------- Price Limit -------------------------------- //
    //*********************************************************************//

    /// @notice Compute a sqrtPriceLimitX96 from input/output amounts so the swap stops
    ///         if the execution price would be worse than the minimum acceptable rate.
    /// @dev When `minimumAmountOut == 0`, returns extreme values (no limit).
    /// @param amountIn The amount of tokens to swap in.
    /// @param minimumAmountOut The minimum acceptable output.
    /// @param zeroForOne True when selling token0 for token1 (price decreases).
    /// @return sqrtPriceLimit The V3-compatible sqrtPriceLimitX96.
    function sqrtPriceLimitFromAmounts(
        uint256 amountIn,
        uint256 minimumAmountOut,
        bool zeroForOne
    )
        internal
        pure
        returns (uint160 sqrtPriceLimit)
    {
        // Without a positive minimum output and input amount, the safest behavior is to leave the price unlimited.
        if (minimumAmountOut == 0 || amountIn == 0) {
            return zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        }

        // Arrange the ratio so the square-root price limit can be derived in the correct swap direction.
        uint256 num;
        uint256 den;
        if (zeroForOne) {
            num = minimumAmountOut;
            den = amountIn;
        } else {
            num = amountIn;
            den = minimumAmountOut;
        }

        uint256 sqrtResult;

        if (num / den >= (uint256(1) << 128)) {
            // Ratio too large for any valid sqrtPriceX96 — fall back to no limit.
            return zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        } else if (num / den >= (uint256(1) << 64)) {
            // Extended range: use ratioX128 to avoid mulDiv overflow, then shift.
            uint256 ratioX128 = mulDiv({x: num, y: uint256(1) << 128, denominator: den});
            sqrtResult = Math.sqrt(ratioX128) * (uint256(1) << 32);
        } else {
            // Normal range: full precision via ratioX192.
            uint256 ratioX192 = mulDiv({x: num, y: uint256(1) << 192, denominator: den});
            sqrtResult = Math.sqrt(ratioX192);
        }

        if (zeroForOne) {
            // Clamp into the valid V3 range for downward price movement limits.
            if (sqrtResult <= uint256(TickMath.MIN_SQRT_RATIO)) {
                return TickMath.MIN_SQRT_RATIO + 1;
            }
            if (sqrtResult >= uint256(TickMath.MAX_SQRT_RATIO)) {
                return TickMath.MAX_SQRT_RATIO - 1;
            }
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint160(sqrtResult);
        } else {
            // Clamp into the valid V3 range for upward price movement limits.
            if (sqrtResult >= uint256(TickMath.MAX_SQRT_RATIO)) {
                return TickMath.MAX_SQRT_RATIO - 1;
            }
            if (sqrtResult <= uint256(TickMath.MIN_SQRT_RATIO)) {
                return TickMath.MIN_SQRT_RATIO + 1;
            }
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint160(sqrtResult);
        }
    }
}
