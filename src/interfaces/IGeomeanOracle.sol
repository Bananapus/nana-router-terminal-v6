// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Minimal interface for a Uniswap V4 TWAP oracle hook (e.g. GeomeanOracle).
/// @dev Used by JBRouterTerminal to attempt TWAP-based quoting on V4 pools whose hook supports it.
interface IGeomeanOracle {
    /// @notice Returns cumulative tick and seconds-per-liquidity values for the given observation timestamps.
    /// @param key The pool key to observe.
    /// @param secondsAgos An array of seconds-ago offsets (e.g., [30, 0] for a 30-second TWAP).
    /// @return tickCumulatives The cumulative tick values at each observation point.
    /// @return secondsPerLiquidityCumulativeX128s The cumulative seconds-per-liquidity values.
    function observe(
        PoolKey calldata key,
        uint32[] calldata secondsAgos
    )
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
