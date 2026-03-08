// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {PoolInfo} from "../structs/PoolInfo.sol";

/// @notice A terminal that routes payments by discovering what token a project accepts and converting automatically.
interface IJBRouterTerminal {
    error JBRouterTerminal_NoRouteFound(uint256 projectId, address tokenIn);
    error JBRouterTerminal_TokenNotAccepted(uint256 projectId, address token);
    error JBRouterTerminal_CallerNotPool(address caller);
    error JBRouterTerminal_CallerNotPoolManager(address caller);
    error JBRouterTerminal_SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error JBRouterTerminal_NoPoolFound(address tokenIn, address tokenOut);
    error JBRouterTerminal_NoCashOutPath(uint256 sourceProjectId, uint256 destProjectId);
    error JBRouterTerminal_NoMsgValueAllowed(uint256 value);
    error JBRouterTerminal_PermitAllowanceNotEnough(uint256 amount, uint256 allowance);
    error JBRouterTerminal_NoLiquidity();
    error JBRouterTerminal_NoObservationHistory();
    error JBRouterTerminal_AmountOverflow(uint256 amount);
    error JBRouterTerminal_CashOutLoopLimit();

    /// @notice Search the Uniswap V3 factory for a pool between two tokens across common fee tiers.
    /// @param normalizedTokenIn The input token (wrapped if native).
    /// @param normalizedTokenOut The output token (wrapped if native).
    /// @return pool The pool with the highest liquidity.
    function discoverPool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        external
        view
        returns (IUniswapV3Pool pool);

    /// @notice Discover the best pool across both V3 and V4 for a token pair.
    /// @param normalizedTokenIn The input token (wrapped if native).
    /// @param normalizedTokenOut The output token (wrapped if native).
    /// @return pool The best pool found.
    function discoverBestPool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        external
        view
        returns (PoolInfo memory pool);
}
