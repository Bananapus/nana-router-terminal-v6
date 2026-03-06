// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @custom:member isV4 Whether this pool is on Uniswap V4 (true) or V3 (false).
/// @custom:member v3Pool The V3 pool reference. Valid when `isV4` is false.
/// @custom:member v4Key The V4 pool key. Valid when `isV4` is true.
struct PoolInfo {
    bool isV4;
    IUniswapV3Pool v3Pool;
    PoolKey v4Key;
}
