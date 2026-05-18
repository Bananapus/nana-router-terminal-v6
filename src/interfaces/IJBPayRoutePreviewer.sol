// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IWETH9} from "./IWETH9.sol";

/// @notice The subset of router preview functionality used by the pay-route resolver helper.
interface IJBPayRoutePreviewer {
    /// @notice The canonical buyback hook whose metadata this router understands.
    /// @return buybackHook The canonical buyback hook address.
    function BUYBACK_HOOK() external view returns (address buybackHook);

    /// @notice The directory storing project terminal relationships.
    /// @return directory The directory storing project terminal relationships.
    function DIRECTORY() external view returns (IJBDirectory directory);

    /// @notice The token store used to map project tokens back to project IDs.
    /// @return tokens The token store used to map project tokens back to project IDs.
    function TOKENS() external view returns (IJBTokens tokens);

    /// @notice The ERC-20 wrapper for the chain's native token, used for router token normalization.
    /// @return weth The ERC-20 wrapper for the chain's native token.
    function wrappedNativeToken() external view returns (IWETH9 weth);

    /// @notice Preview the recursive cashout loop the router would use for a project-token input.
    /// @param destProjectId The destination project the router is trying to pay.
    /// @param token The current token to route.
    /// @param amount The amount of `token` to preview.
    /// @param metadata Metadata forwarded into preview helpers.
    /// @param preferredToken The token the cashout loop should prefer to land on, or `address(0)` for no preference.
    /// @return destTerminal The terminal reached by the cashout loop, or address(0) if routing should continue.
    /// @return finalToken The token produced by the previewed cashout loop.
    /// @return finalAmount The amount of `finalToken` produced by the previewed cashout loop.
    function previewCashOutLoopOf(
        uint256 destProjectId,
        address token,
        uint256 amount,
        bytes calldata metadata,
        address preferredToken
    )
        external
        view
        returns (IJBTerminal destTerminal, address finalToken, uint256 finalAmount);

    /// @notice Preview the amount a direct token-to-token swap would return.
    /// @param tokenIn The input token.
    /// @param tokenOut The output token.
    /// @param amount The amount of `tokenIn` to swap.
    /// @param metadata Metadata forwarded into quote selection.
    /// @return amountOut The quoted amount of `tokenOut`.
    function previewSwapAmountOutOf(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata metadata
    )
        external
        view
        returns (uint256 amountOut);

    /// @notice Return the highest discovered pool liquidity between two normalized tokens.
    /// @param tokenA One token in the pair.
    /// @param tokenB The other token in the pair.
    /// @return bestLiquidity The highest liquidity found, or 0 if no pool exists.
    function bestPoolLiquidityOf(address tokenA, address tokenB) external view returns (uint128 bestLiquidity);

    /// @notice Preview a destination terminal payment from the router's caller context.
    /// @param destTerminal The terminal whose pay preview to query.
    /// @param projectId The destination project that would receive the payment.
    /// @param token The token the destination terminal would receive.
    /// @param amount The amount of `token` the destination terminal would receive.
    /// @param beneficiary The address to measure beneficiary token count for.
    /// @param metadata Metadata forwarded unchanged into the destination terminal preview.
    /// @return ruleset The ruleset returned by the destination terminal preview.
    /// @return beneficiaryTokenCount The beneficiary token count returned by the destination terminal preview.
    /// @return reservedTokenCount The reserved token count returned by the destination terminal preview.
    /// @return hookSpecifications The pay hook specifications returned by the destination terminal preview.
    function previewTerminalPayOf(
        IJBTerminal destTerminal,
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        bytes calldata metadata
    )
        external
        view
        returns (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        );
}
