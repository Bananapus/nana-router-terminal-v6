// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {IJBPayRoutePreviewer} from "./IJBPayRoutePreviewer.sol";

/// @notice Resolves the best pay route preview for a router terminal.
interface IJBPayRouteResolver {
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

    /// @notice External self-call wrapper that previews the fallback route in an isolated context.
    /// @dev Called via `self.previewFallbackRoute(...)` so `try/catch` can absorb reverts from broken
    /// terminals or price feeds without bricking the entire best-route preview.
    /// @param routePreviewer The router terminal whose preview helpers are used to simulate the route.
    /// @param destProjectId The project being paid through the fallback route.
    /// @param tokenIn The token the payer is sending.
    /// @param amountIn The amount of `tokenIn` being routed.
    /// @param beneficiary The address that would receive minted project tokens.
    /// @param metadata Arbitrary bytes forwarded into route and terminal pay previews.
    /// @return destTerminal The terminal the fallback route would deliver funds to.
    /// @return tokenOut The token `destTerminal` would receive after any intermediate swaps.
    /// @return amountOut The amount of `tokenOut` that would arrive at `destTerminal`.
    /// @return ruleset The ruleset that would govern the terminal pay.
    /// @return beneficiaryTokenCount The number of project tokens `beneficiary` would receive.
    /// @return reservedTokenCount The number of project tokens that would be reserved.
    /// @return hookSpecifications Any pay-hook specifications returned by the terminal preview.
    function previewFallbackRoute(
        IJBPayRoutePreviewer routePreviewer,
        uint256 destProjectId,
        address tokenIn,
        uint256 amountIn,
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

    /// @notice Resolve a project's primary terminal only when the router can safely forward into it.
    /// @param router The router whose forwarding-terminal rules should be applied.
    /// @param projectId The project whose primary terminal should be checked.
    /// @param token The token that terminal should accept.
    /// @return terminal The usable primary terminal, or address(0) if none is usable.
    function usablePrimaryTerminalOf(
        IJBPayRoutePreviewer router,
        uint256 projectId,
        address token
    )
        external
        view
        returns (IJBTerminal terminal);
}
