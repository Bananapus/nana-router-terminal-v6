// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {IJBPayRoutePreviewer} from "./IJBPayRoutePreviewer.sol";

/// @notice Resolves the best pay route preview for a router terminal.
interface IJBPayRouteResolver {
    /// @notice Whether routing through a terminal would immediately cycle back into the router.
    /// @param router The router whose topology is being checked.
    /// @param projectId The destination project whose terminal resolution should be checked.
    /// @param terminal The terminal that would receive the route.
    /// @return isCircular A flag indicating whether `terminal` resolves back into `router`.
    function isCircularTerminal(
        IJBPayRoutePreviewer router,
        uint256 projectId,
        IJBTerminal terminal
    )
        external
        view
        returns (bool isCircular);

    /// @notice Preview the best pay route for a router terminal.
    /// @param router The router terminal whose preview helpers should be used.
    /// @param projectId The destination project that would receive the payment.
    /// @param tokenIn The token currently available to route.
    /// @param amount The amount of `tokenIn` being previewed.
    /// @param beneficiary The address whose minted token count should be optimized.
    /// @param metadata Metadata forwarded into route and pay previews.
    /// @return destTerminal The terminal chosen for the best previewed route.
    /// @return tokenOut The token `destTerminal` would receive.
    /// @return amountOut The amount of `tokenOut` that would be paid.
    /// @return ruleset The ruleset returned by the chosen terminal preview.
    /// @return beneficiaryTokenCount The effective beneficiary token count for the chosen route.
    /// @return reservedTokenCount The effective reserved token count for the chosen route.
    /// @return hookSpecifications The hook specifications returned by the chosen terminal preview.
    function previewBestPayRoute(
        IJBPayRoutePreviewer router,
        uint256 projectId,
        address tokenIn,
        uint256 amount,
        address beneficiary,
        bytes calldata metadata
    )
        external
        view
        returns (
            IJBTerminal destTerminal,
            address tokenOut,
            uint256 amountOut,
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        );

    /// @notice Preview a specific candidate pay route so callers can isolate revert-prone candidates with `try/catch`.
    /// @param router The router terminal whose preview helpers should be used.
    /// @param projectId The destination project that would receive the payment.
    /// @param tokenIn The token currently available to route.
    /// @param amount The amount of `tokenIn` being previewed.
    /// @param beneficiary The address whose minted token count is being measured.
    /// @param metadata Metadata forwarded into route and pay previews.
    /// @param tokenOut The candidate destination token to preview.
    /// @param destTerminal The terminal that accepts `tokenOut` for the destination project.
    /// @return routedDestTerminal The terminal chosen for this candidate route.
    /// @return routedTokenOut The routed token that would be paid into the destination terminal.
    /// @return routedAmountOut The routed amount that would be paid into the destination terminal.
    /// @return ruleset The ruleset returned by the terminal preview.
    /// @return beneficiaryTokenCount The effective beneficiary token count for this candidate route.
    /// @return reservedTokenCount The effective reserved token count for this candidate route.
    /// @return hookSpecifications The hook specifications returned by the terminal preview.
    function previewPayRouteForCandidate(
        IJBPayRoutePreviewer router,
        uint256 projectId,
        address tokenIn,
        uint256 amount,
        address beneficiary,
        bytes calldata metadata,
        address tokenOut,
        IJBTerminal destTerminal
    )
        external
        view
        returns (
            IJBTerminal routedDestTerminal,
            address routedTokenOut,
            uint256 routedAmountOut,
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        );

    /// @notice Determine what output token a project accepts for a given input token.
    /// @param router The router whose view helpers should be used.
    /// @param projectId The destination project being paid.
    /// @param tokenIn The input token being routed.
    /// @param metadata Metadata forwarded into route-token resolution.
    /// @return tokenOut The token the project accepts.
    /// @return destTerminal The terminal that accepts `tokenOut`.
    function resolveTokenOut(
        IJBPayRoutePreviewer router,
        uint256 projectId,
        address tokenIn,
        bytes calldata metadata
    )
        external
        view
        returns (address tokenOut, IJBTerminal destTerminal);
}
