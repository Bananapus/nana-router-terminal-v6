// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {PoolInfo} from "../structs/PoolInfo.sol";

/// @notice A terminal that routes payments by discovering what token a project accepts and converting automatically.
interface IJBRouterTerminal is IJBTerminal {
    /// @notice A Permit2 allowance approval failed.
    /// @param token The token the approval was attempted for.
    /// @param owner The owner of the tokens.
    /// @param reason The failure reason.
    /// @param caller The address that called the terminal function.
    event Permit2AllowanceFailed(address indexed token, address indexed owner, bytes reason, address caller);

    /// @notice Discover the best pool across both V3 and V4 for a token pair.
    /// @param normalizedTokenIn The input token (wrapped if native).
    /// @param normalizedTokenOut The output token (wrapped if native).
    /// @return pool The best pool found across the supported V3 and V4 search spaces.
    function discoverBestPool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        external
        view
        returns (PoolInfo memory pool);

    /// @notice Search the Uniswap V3 factory for a pool between two tokens across common fee tiers.
    /// @param normalizedTokenIn The input token (wrapped if native).
    /// @param normalizedTokenOut The output token (wrapped if native).
    /// @return pool The V3 pool with the highest liquidity across the searched fee tiers.
    function discoverPool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        external
        view
        returns (IUniswapV3Pool pool);
}
