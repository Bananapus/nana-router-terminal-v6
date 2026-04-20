// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {IJBForwardingTerminal} from "./interfaces/IJBForwardingTerminal.sol";
import {IJBPayRoutePreviewer} from "./interfaces/IJBPayRoutePreviewer.sol";
import {IJBPayRouteResolver} from "./interfaces/IJBPayRouteResolver.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";

/// @notice Resolves the best pay route preview for `JBRouterTerminal`.
contract JBPayRouteResolver is IJBPayRouteResolver {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBRouterTerminal_NoRouteFound(uint256 projectId, address tokenIn);

    //*********************************************************************//
    // --------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The directory storing project terminal relationships, cached from the router at construction time.
    IJBDirectory public immutable DIRECTORY;

    /// @notice The wrapped native token, cached from the router at construction time.
    IWETH9 public immutable WETH;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The directory storing project terminal relationships.
    /// @param weth The wrapped native token used for router token normalization.
    constructor(IJBDirectory directory, IWETH9 weth) {
        DIRECTORY = directory;
        WETH = weth;
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Collect unique candidate pay-route tokens.
    /// @param directory The directory used to look up project terminals.
    /// @param projectId The destination project whose accepted tokens should be enumerated.
    /// @param terminals The terminal list already fetched for the destination project.
    /// @return tokens The unique candidate tokens that can be paid into the project.
    /// @return count The number of populated entries in `tokens`.
    // slither-disable-next-line calls-loop
    function _candidatePayRouteTokens(
        IJBDirectory directory,
        uint256 projectId,
        IJBTerminal[] memory terminals
    )
        internal
        view
        returns (address[] memory tokens, uint256 count)
    {
        // Read every terminal's accounting contexts once upfront to avoid double external calls.
        JBAccountingContext[][] memory allContexts = new JBAccountingContext[][](terminals.length);
        uint256 totalContexts;
        for (uint256 i; i < terminals.length;) {
            // Wrap in try/catch so a single reverting terminal does not DoS the entire route enumeration.
            try terminals[i].accountingContextsOf(projectId) returns (JBAccountingContext[] memory ctx) {
                allContexts[i] = ctx;
                totalContexts += ctx.length;
            } catch {
                // Skip terminals that revert — allContexts[i] remains an empty array.
            }
            unchecked {
                ++i;
            }
        }

        // Allocate enough space for the worst case where every accounting context contributes a distinct token.
        tokens = new address[](totalContexts);

        for (uint256 i; i < terminals.length;) {
            // Reuse the contexts already read in the sizing pass above.
            JBAccountingContext[] memory contexts = allContexts[i];

            for (uint256 j; j < contexts.length;) {
                // Start from the token surfaced by this accounting context.
                address candidateToken = contexts[j].token;

                // Track whether the token was already emitted by a previous terminal/context pair.
                bool alreadySeen;

                for (uint256 k; k < count;) {
                    if (tokens[k] == candidateToken) {
                        // Mark the candidate as already emitted so the outer loop can skip it below.
                        alreadySeen = true;
                        break;
                    }
                    unchecked {
                        ++k;
                    }
                }

                // Skip duplicate tokens so the preview scorer only evaluates each candidate once.
                if (alreadySeen) {
                    unchecked {
                        ++j;
                    }
                    continue;
                }

                // Skip tokens that no longer resolve to a primary terminal for this project.
                if (address(directory.primaryTerminalOf({projectId: projectId, token: candidateToken})) == address(0)) {
                    unchecked {
                        ++j;
                    }
                    continue;
                }

                // Record the unique token in the compacted prefix of the array.
                tokens[count] = candidateToken;

                // Advance the populated length so the next unique token lands in the next slot.
                count++;
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Search a project's terminals for an accepted token that has a Uniswap pool with `tokenIn`.
    /// @dev Falls back to the first accepted token if no pool exists.
    /// @param router The router whose normalization and pool-discovery helpers should be used.
    /// @param projectId The destination project whose accepted tokens should be searched.
    /// @param tokenIn The input token to find a route from.
    /// @return tokenOut The best accepted token found.
    /// @return destTerminal The terminal that accepts `tokenOut`.
    // slither-disable-next-line calls-loop
    function _discoverAcceptedToken(
        IJBPayRoutePreviewer router,
        uint256 projectId,
        address tokenIn
    )
        internal
        view
        returns (address tokenOut, IJBTerminal destTerminal)
    {
        // Use the constructor-cached directory so fallback candidates can be resolved back to their primary terminals.
        IJBDirectory directory = DIRECTORY;

        // Normalize the input token once so liquidity comparisons use the router's canonical token form.
        address normalizedTokenIn = _normalizedTokenOf(tokenIn);

        // Read the destination project's currently known terminals directly from the directory.
        IJBTerminal[] memory terminals = directory.terminalsOf(projectId);

        // Track the best liquidity discovered so far across all accepted candidate tokens.
        uint128 bestLiquidity;

        // Track whether any acceptable fallback token has been seen in case no pool exists at all.
        bool hasFallback;

        for (uint256 i; i < terminals.length;) {
            // Read each terminal's accepted accounting contexts so the scorer can inspect every candidate token.
            // Wrap in try/catch so a single reverting terminal does not DoS the entire route discovery.
            JBAccountingContext[] memory contexts;
            try terminals[i].accountingContextsOf(projectId) returns (JBAccountingContext[] memory ctx) {
                contexts = ctx;
            } catch {
                // Skip terminals that revert.
                unchecked {
                    ++i;
                }
                continue;
            }

            for (uint256 j; j < contexts.length;) {
                // Pull the candidate token out of the accounting context being inspected.
                address candidateToken = contexts[j].token;

                // Normalize the candidate so native-vs-WETH comparisons behave the same as the router.
                address normalizedCandidate = _normalizedTokenOf(candidateToken);

                // Skip tokens that are equivalent to the input token because they do not require route discovery.
                if (normalizedCandidate == normalizedTokenIn) {
                    unchecked {
                        ++j;
                    }
                    continue;
                }

                // Resolve the candidate token back to its usable primary terminal so discovery agrees with
                // preview/execution terminal selection.
                IJBTerminal candidateTerminal = _usablePrimaryTerminalForCandidate({
                    router: router, directory: directory, projectId: projectId, candidateToken: candidateToken
                });
                if (address(candidateTerminal) == address(0)) {
                    unchecked {
                        ++j;
                    }
                    continue;
                }

                // Keep the first viable candidate as a fallback in case no pool-backed route exists.
                if (!hasFallback) {
                    tokenOut = candidateToken;
                    destTerminal = candidateTerminal;
                    hasFallback = true;
                }

                // Compare candidate pools by the router's discovered-liquidity heuristic.
                uint128 candidateLiquidity =
                    router.bestPoolLiquidityOf({tokenA: normalizedTokenIn, tokenB: normalizedCandidate});
                if (candidateLiquidity > bestLiquidity) {
                    // Replace the fallback with the candidate backed by the deepest discovered pool so far.
                    bestLiquidity = candidateLiquidity;
                    tokenOut = candidateToken;
                    destTerminal = candidateTerminal;
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Normalize previewed pay token counts when buyback-hook metadata changes the user-visible result.
    /// @param buybackHook The canonical buyback hook address the router recognizes.
    /// @param beneficiaryTokenCount The beneficiary token count returned by the terminal preview.
    /// @param reservedTokenCount The reserved token count returned by the terminal preview.
    /// @param hookSpecifications The hook specifications returned by the terminal preview.
    /// @return effectiveBeneficiaryTokenCount The beneficiary token count after applying understood hook metadata.
    /// @return effectiveReservedTokenCount The reserved token count after applying understood hook metadata.
    function _effectivePreviewPayTokenCounts(
        address buybackHook,
        uint256 beneficiaryTokenCount,
        uint256 reservedTokenCount,
        JBPayHookSpecification[] memory hookSpecifications
    )
        internal
        pure
        returns (uint256 effectiveBeneficiaryTokenCount, uint256 effectiveReservedTokenCount)
    {
        // Start from the raw preview values returned by the destination terminal.
        effectiveBeneficiaryTokenCount = beneficiaryTokenCount;
        effectiveReservedTokenCount = reservedTokenCount;

        // Skip hook decoding when the terminal already surfaced non-zero counts directly.
        if (beneficiaryTokenCount != 0 || reservedTokenCount != 0) {
            return (beneficiaryTokenCount, reservedTokenCount);
        }

        for (uint256 i; i < hookSpecifications.length;) {
            // Inspect one hook specification at a time so only understood buyback metadata influences scoring.
            JBPayHookSpecification memory specification = hookSpecifications[i];

            // Ignore no-op hooks and hooks the router does not recognize as the canonical buyback hook.
            if (specification.noop || address(specification.hook) != buybackHook) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // Decode only the minimum token-count commitments needed to score the buyback-enhanced preview.
            (,,,,,,,,, uint256 minimumBeneficiaryTokenCount, uint256 minimumReservedTokenCount,) = abi.decode(
                specification.metadata,
                (bool, uint256, uint256, bool, address, uint256, int24, uint128, bytes32, uint256, uint256, uint256)
            );

            // Keep whichever decoded hook commitment implies the stronger user-visible preview outcome.
            if (
                minimumBeneficiaryTokenCount > effectiveBeneficiaryTokenCount
                    || (minimumBeneficiaryTokenCount == effectiveBeneficiaryTokenCount
                        && minimumReservedTokenCount > effectiveReservedTokenCount)
            ) {
                effectiveBeneficiaryTokenCount = minimumBeneficiaryTokenCount;
                effectiveReservedTokenCount = minimumReservedTokenCount;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Read a metadata entry from the router-scoped metadata namespace.
    /// @param router The router whose metadata namespace should be used.
    /// @param metadata The metadata blob to query.
    /// @param key The metadata key to resolve.
    /// @return exists A flag indicating whether the metadata entry was present.
    /// @return data The raw metadata payload for `key`.
    function _getDataFor(
        IJBPayRoutePreviewer router,
        bytes calldata metadata,
        string memory key
    )
        internal
        pure
        returns (bool exists, bytes memory data)
    {
        // slither-disable-next-line unused-return
        // slither-disable-next-line unused-return
        return JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId(key, address(router)), metadata: metadata});
    }

    /// @notice Check whether two tokens share the same routing representation for the router.
    /// @param tokenA The first token to compare.
    /// @param tokenB The second token to compare.
    /// @return hasSameAsset A flag indicating whether the router would treat both tokens as the same asset.
    function _hasSameRoutingAsset(address tokenA, address tokenB) internal view returns (bool hasSameAsset) {
        // Treat exact-token matches as the same routing asset without extra normalization work.
        if (tokenA == tokenB) return true;

        // Otherwise compare normalized representations so ETH and WETH share one routing identity.
        return _normalizedTokenOf(tokenA) == _normalizedTokenOf(tokenB);
    }

    /// @notice Whether previewing through a terminal would immediately cycle back into the router.
    /// @param router The router whose preview path is being evaluated.
    /// @param projectId The project whose forwarding terminal would be resolved.
    /// @param terminal The terminal that would receive the previewed route.
    /// @return isCircular A flag indicating whether `terminal` is the router itself or forwards back into it.
    function _isCircularTerminal(
        IJBPayRoutePreviewer router,
        uint256 projectId,
        IJBTerminal terminal
    )
        internal
        view
        returns (bool isCircular)
    {
        // Treat direct self-routes as circular immediately.
        if (address(terminal) == address(router)) return true;

        // Probe via staticcall so plain terminals degrade cleanly.
        (bool success, bytes memory data) =
            address(terminal).staticcall(abi.encodeCall(IJBForwardingTerminal.terminalOf, (projectId)));

        // Non-forwarding terminals (call fails or returns zero) are not circular.
        if (!success || data.length < 32) return false;
        IJBTerminal forwardingTarget = abi.decode(data, (IJBTerminal));
        if (address(forwardingTarget) == address(0)) return false;

        // Forwarding terminals that route back into the router are circular.
        return address(forwardingTarget) == address(router);
    }

    /// @notice Normalize a token into the form the router uses for routing comparisons.
    /// @param token The token to normalize.
    /// @return normalizedToken The normalized token address.
    function _normalizedTokenOf(address token) internal view returns (address normalizedToken) {
        return token == JBConstants.NATIVE_TOKEN ? address(WETH) : token;
    }

    /// @notice Preview the amount that would be routed into a specific destination token.
    /// @param router The router terminal whose preview helpers should be used.
    /// @param destProjectId The destination project the router is trying to pay.
    /// @param tokenIn The token currently available to route.
    /// @param amount The amount of `tokenIn` being previewed.
    /// @param metadata Metadata that may encode cashout-source and route-token overrides.
    /// @param tokenOut The preferred destination token to preview.
    /// @return routedTokenIn The token that would actually be provided to the destination terminal.
    /// @return routedAmountIn The amount of `routedTokenIn` that would reach the destination terminal.
    function _previewAmountToToken(
        IJBPayRoutePreviewer router,
        uint256 destProjectId,
        address tokenIn,
        uint256 amount,
        bytes calldata metadata,
        address tokenOut
    )
        internal
        view
        returns (address routedTokenIn, uint256 routedAmountIn)
    {
        // Preview any source-project cashout first so the remaining routing work starts from the right token and
        // amount.
        (, routedTokenIn, routedAmountIn) = _previewRouteInputFromSource({
            router: router,
            destProjectId: destProjectId,
            tokenIn: tokenIn,
            amount: amount,
            metadata: metadata,
            preferredToken: tokenOut
        });

        // Return early when the routed token already matches the desired destination token.
        if (_hasSameRoutingAsset({tokenA: routedTokenIn, tokenB: tokenOut})) {
            return (tokenOut, routedAmountIn);
        }

        // Otherwise preview the final swap into the candidate destination token.
        routedAmountIn = router.previewSwapAmountOutOf({
            tokenIn: routedTokenIn, tokenOut: tokenOut, amount: routedAmountIn, metadata: metadata
        });

        // Surface the post-swap token as the routed token returned to the caller.
        routedTokenIn = tokenOut;
    }

    /// @notice Preview a pay route for a specific destination token.
    /// @param router The router terminal whose preview helpers should be used.
    /// @param projectId The destination project that would receive the payment.
    /// @param tokenIn The token currently available to route.
    /// @param amount The amount of `tokenIn` being previewed.
    /// @param beneficiary The address whose beneficiary token count is being measured.
    /// @param metadata Metadata forwarded into both the routing preview and terminal preview.
    /// @param tokenOut The candidate destination token to preview.
    /// @param destTerminal The terminal that accepts `tokenOut` for the destination project.
    /// @return routedDestTerminal The terminal chosen for this candidate route.
    /// @return routedTokenOut The routed token that would be paid into the destination terminal.
    /// @return routedAmountOut The routed amount that would be paid into the destination terminal.
    /// @return ruleset The ruleset returned by the terminal preview.
    /// @return beneficiaryTokenCount The effective beneficiary token count for this candidate route.
    /// @return reservedTokenCount The effective reserved token count for this candidate route.
    /// @return hookSpecifications The hook specifications returned by the terminal preview.
    function _previewPayRouteForCandidate(
        IJBPayRoutePreviewer router,
        uint256 projectId,
        address tokenIn,
        uint256 amount,
        address beneficiary,
        bytes calldata metadata,
        address tokenOut,
        IJBTerminal destTerminal
    )
        internal
        view
        returns (
            IJBTerminal routedDestTerminal,
            address routedTokenOut,
            uint256 routedAmountOut,
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        )
    {
        // First preview the route into the candidate destination token so the terminal is scored on post-route inputs.
        (address routedTokenIn, uint256 routedAmountIn) = _previewAmountToToken({
            router: router,
            destProjectId: projectId,
            tokenIn: tokenIn,
            amount: amount,
            metadata: metadata,
            tokenOut: tokenOut
        });

        // Ask the destination terminal for the minting preview using the router-owned caller context.
        (ruleset, beneficiaryTokenCount, reservedTokenCount, hookSpecifications) = router.previewTerminalPayOf({
            destTerminal: destTerminal,
            projectId: projectId,
            token: routedTokenIn,
            amount: routedAmountIn,
            beneficiary: beneficiary,
            metadata: metadata
        });

        // Normalize the returned token counts so buyback-hook metadata influences route ranking consistently.
        (beneficiaryTokenCount, reservedTokenCount) = _effectivePreviewPayTokenCounts({
            buybackHook: router.BUYBACK_HOOK(),
            beneficiaryTokenCount: beneficiaryTokenCount,
            reservedTokenCount: reservedTokenCount,
            hookSpecifications: hookSpecifications
        });

        // Surface the routed terminal and token data alongside the normalized preview counts.
        routedDestTerminal = destTerminal;
        routedTokenOut = routedTokenIn;
        routedAmountOut = routedAmountIn;
    }

    /// @notice External wrapper so candidate previews can be isolated with `try/catch`.
    /// @param router The router terminal whose preview helpers should be used.
    /// @param projectId The destination project that would receive the payment.
    /// @param tokenIn The token currently available to route.
    /// @param amount The amount of `tokenIn` being previewed.
    /// @param beneficiary The address whose beneficiary token count is being measured.
    /// @param metadata Metadata forwarded into both the routing preview and terminal preview.
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
        )
    {
        return _previewPayRouteForCandidate({
            router: router,
            projectId: projectId,
            tokenIn: tokenIn,
            amount: amount,
            beneficiary: beneficiary,
            metadata: metadata,
            tokenOut: tokenOut,
            destTerminal: destTerminal
        });
    }

    /// @notice Preview the fallback route that would be used when no candidate token can be scored directly.
    /// @param router The router terminal whose preview helpers should be used.
    /// @param destProjectId The destination project being paid.
    /// @param tokenIn The token currently available to route.
    /// @param amount The amount of `tokenIn` being previewed.
    /// @param metadata Metadata forwarded into preview helpers.
    /// @return destTerminal The terminal the router would use.
    /// @return tokenOut The token `destTerminal` would receive.
    /// @return amountOut The amount of `tokenOut` that would be routed.
    function _previewRoute(
        IJBPayRoutePreviewer router,
        uint256 destProjectId,
        address tokenIn,
        uint256 amount,
        bytes calldata metadata
    )
        internal
        view
        returns (IJBTerminal destTerminal, address tokenOut, uint256 amountOut)
    {
        // Preview any source-project cashout before attempting direct-acceptance or swap-route resolution.
        (destTerminal, tokenIn, amount) = _previewRouteInputFromSource({
            router: router,
            destProjectId: destProjectId,
            tokenIn: tokenIn,
            amount: amount,
            metadata: metadata,
            preferredToken: address(0)
        });

        // Return immediately when the cashout loop already found the final destination terminal.
        if (address(destTerminal) != address(0)) return (destTerminal, tokenIn, amount);

        // Resolve the destination token and terminal that the project would accept from the remaining input.
        (tokenOut, destTerminal) =
            _resolveTokenOut({router: router, projectId: destProjectId, tokenIn: tokenIn, metadata: metadata});

        // Return the current amount unchanged when no swap is needed after token resolution.
        if (_hasSameRoutingAsset({tokenA: tokenIn, tokenB: tokenOut})) {
            return (destTerminal, tokenOut, amount);
        }

        // Otherwise preview the swap into the resolved destination token.
        amountOut =
            router.previewSwapAmountOutOf({tokenIn: tokenIn, tokenOut: tokenOut, amount: amount, metadata: metadata});
    }

    /// @notice Preview how the current route input would change after cashing out a project-token source if needed.
    /// @param router The router terminal whose preview helpers should be used.
    /// @param destProjectId The destination project the route is trying to reach.
    /// @param tokenIn The current route input token.
    /// @param amount The current route input amount.
    /// @param metadata Metadata that may include a cashout-source override.
    /// @param preferredToken The preferred token to target during any previewed cashout loop.
    /// @return resolvedTerminal The terminal found by the previewed cashout loop, or address(0) if conversion should
    /// continue. @return routedTokenIn The token that remains to be routed after the previewed cashout step.
    /// @return routedAmountIn The amount of `routedTokenIn` that remains to be routed.
    function _previewRouteInputFromSource(
        IJBPayRoutePreviewer router,
        uint256 destProjectId,
        address tokenIn,
        uint256 amount,
        bytes calldata metadata,
        address preferredToken
    )
        internal
        view
        returns (IJBTerminal resolvedTerminal, address routedTokenIn, uint256 routedAmountIn)
    {
        // Resolve whether this preview should first treat the input token as a JB project-token cashout source.
        (uint256 sourceProjectIdOverride, uint256 sourceProjectId) =
            _sourceProjectIdOf({router: router, tokenIn: tokenIn, metadata: metadata});

        // When there is no project-token source, the current input already is the routed input.
        if (sourceProjectId == 0) return (resolvedTerminal, tokenIn, amount);

        // Otherwise reuse the router's own preview cashout loop so preview and execution stay aligned.
        // slither-disable-next-line unused-return
        return router.previewCashOutLoopOf({
            destProjectId: destProjectId,
            token: tokenIn,
            amount: amount,
            sourceProjectIdOverride: sourceProjectIdOverride,
            metadata: metadata,
            preferredToken: preferredToken
        });
    }

    /// @notice Resolve what output token a project accepts for a given input token.
    /// @param router The router whose view helpers should be used.
    /// @param projectId The destination project being paid.
    /// @param tokenIn The input token being routed.
    /// @param metadata Metadata forwarded into route-token resolution.
    /// @return tokenOut The token the project accepts.
    /// @return destTerminal The terminal that accepts `tokenOut`.
    function _resolveTokenOut(
        IJBPayRoutePreviewer router,
        uint256 projectId,
        address tokenIn,
        bytes calldata metadata
    )
        internal
        view
        returns (address tokenOut, IJBTerminal destTerminal)
    {
        // Use the constructor-cached directory since every resolution branch reads from it.
        IJBDirectory directory = DIRECTORY;

        // Respect explicit token-out overrides before any direct-acceptance or discovery logic runs.
        (bool exists, bytes memory routeData) = _getDataFor({router: router, metadata: metadata, key: "routeTokenOut"});
        if (exists) {
            // Decode the caller-specified destination token.
            tokenOut = abi.decode(routeData, (address));

            // Resolve the primary terminal for the requested destination token.
            destTerminal = directory.primaryTerminalOf({projectId: projectId, token: tokenOut});

            // Reject missing or circular terminals so execution cannot preview an impossible route.
            if (
                address(destTerminal) == address(0)
                    || _isCircularTerminal({router: router, projectId: projectId, terminal: destTerminal})
            ) {
                revert JBRouterTerminal_NoRouteFound(projectId, tokenIn);
            }
            return (tokenOut, destTerminal);
        }

        // Next prefer a direct-acceptance route for the input token whenever the project already has a non-circular
        // terminal.
        destTerminal = directory.primaryTerminalOf({projectId: projectId, token: tokenIn});
        if (
            address(destTerminal) != address(0)
                && !_isCircularTerminal({router: router, projectId: projectId, terminal: destTerminal})
        ) {
            return (tokenIn, destTerminal);
        }

        // Then try the native-token and wrapped-native-token equivalent form before falling back to pool discovery.
        if (tokenIn == JBConstants.NATIVE_TOKEN || tokenIn == address(WETH)) {
            tokenOut = tokenIn == JBConstants.NATIVE_TOKEN ? address(WETH) : JBConstants.NATIVE_TOKEN;
            destTerminal = directory.primaryTerminalOf({projectId: projectId, token: tokenOut});
            if (
                address(destTerminal) != address(0)
                    && !_isCircularTerminal({router: router, projectId: projectId, terminal: destTerminal})
            ) {
                return (tokenOut, destTerminal);
            }
        }

        // Finally discover the best accepted token using the router's liquidity heuristic.
        (tokenOut, destTerminal) = _discoverAcceptedToken({router: router, projectId: projectId, tokenIn: tokenIn});

        // Revert when discovery failed entirely or only found a circular route.
        if (
            address(destTerminal) == address(0)
                || _isCircularTerminal({router: router, projectId: projectId, terminal: destTerminal})
        ) {
            revert JBRouterTerminal_NoRouteFound(projectId, tokenIn);
        }
    }

    /// @notice Best-effort terminal lookup that degrades to an empty list if the directory call reverts.
    /// @param directory The directory storing project terminal relationships.
    /// @param projectId The project whose terminals should be looked up.
    /// @return terminals The terminal list, or an empty list if the directory call failed.
    function _safeTerminalsOf(
        IJBDirectory directory,
        uint256 projectId
    )
        internal
        view
        returns (IJBTerminal[] memory terminals)
    {
        // Read the terminal list through a low-level staticcall so directory failures degrade into "no terminals."
        (bool success, bytes memory data) =
            address(directory).staticcall(abi.encodeCall(IJBDirectory.terminalsOf, (projectId)));

        // Surface an empty list when the directory reverted or returned no data.
        if (!success || data.length == 0) return terminals;

        // Decode the returned terminal array on successful responses.
        return abi.decode(data, (IJBTerminal[]));
    }

    /// @notice Resolve whether the current route input should first be treated as a project-token cashout source.
    /// @param router The router terminal whose project-token lookup should be used.
    /// @param tokenIn The current route input token.
    /// @param metadata Metadata that may include an explicit cashout-source override.
    /// @return sourceProjectIdOverride The source project ID encoded in metadata, or 0 if none was provided.
    /// @return sourceProjectId The effective source project ID inferred from `metadata` and `tokenIn`.
    function _sourceProjectIdOf(
        IJBPayRoutePreviewer router,
        address tokenIn,
        bytes calldata metadata
    )
        internal
        view
        returns (uint256 sourceProjectIdOverride, uint256 sourceProjectId)
    {
        // Read the router-scoped cashout-source metadata so preview matches the router's own metadata namespace.
        (bool exists, bytes memory creditData) = _getDataFor({router: router, metadata: metadata, key: "cashOutSource"});

        // Decode the explicit source-project override when the caller supplied one.
        if (exists) (sourceProjectIdOverride,) = abi.decode(creditData, (uint256, uint256));

        // Start from the explicit override.
        sourceProjectId = sourceProjectIdOverride;

        // Fall back to inferring the project ID from the input token whenever the token is not the native sentinel.
        if (sourceProjectId == 0 && tokenIn != JBConstants.NATIVE_TOKEN) {
            sourceProjectId = router.TOKENS().projectIdOf(IJBToken(tokenIn));
        }
    }

    /// @notice Resolve the usable primary terminal for a discovered candidate token.
    /// @param router The router whose circular-terminal rule should be applied.
    /// @param directory The directory used to resolve primary terminals.
    /// @param projectId The destination project being inspected.
    /// @param candidateToken The discovered accepted token candidate.
    /// @return candidateTerminal The candidate token's primary terminal, or address(0) if unusable.
    function _usablePrimaryTerminalForCandidate(
        IJBPayRoutePreviewer router,
        IJBDirectory directory,
        uint256 projectId,
        address candidateToken
    )
        internal
        view
        returns (IJBTerminal candidateTerminal)
    {
        // Resolve the primary terminal for the candidate token so fallback discovery agrees with preview/execution.
        candidateTerminal = directory.primaryTerminalOf({projectId: projectId, token: candidateToken});

        // Drop candidates whose primary terminal disappeared or would route straight back into the router.
        if (
            address(candidateTerminal) == address(0)
                || _isCircularTerminal({router: router, projectId: projectId, terminal: candidateTerminal})
        ) {
            return IJBTerminal(address(0));
        }
    }

    /// @inheritdoc IJBPayRouteResolver
    function usablePrimaryTerminalOf(
        IJBPayRoutePreviewer router,
        uint256 projectId,
        address token
    )
        external
        view
        returns (IJBTerminal terminal)
    {
        return _usablePrimaryTerminalForCandidate({
            router: router, directory: DIRECTORY, projectId: projectId, candidateToken: token
        });
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @inheritdoc IJBPayRouteResolver
    function resolveTokenOut(
        IJBPayRoutePreviewer router,
        uint256 projectId,
        address tokenIn,
        bytes calldata metadata
    )
        external
        view
        returns (address tokenOut, IJBTerminal destTerminal)
    {
        return _resolveTokenOut({router: router, projectId: projectId, tokenIn: tokenIn, metadata: metadata});
    }

    /// @inheritdoc IJBPayRouteResolver
    // slither-disable-next-line calls-loop
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
        )
    {
        // Cache a self-interface once because candidate isolation requires an external call that can be caught.
        IJBPayRouteResolver self = IJBPayRouteResolver(address(this));

        // Use the constructor-cached directory because every route-selection branch uses it.
        IJBDirectory directory = DIRECTORY;

        // Respect explicit route-token overrides before scanning candidate tokens.
        (bool routeOverrideExists, bytes memory routeData) =
            _getDataFor({router: router, metadata: metadata, key: "routeTokenOut"});
        if (routeOverrideExists) {
            // Decode the requested token-out override.
            tokenOut = abi.decode(routeData, (address));

            // Resolve the primary terminal for the requested token-out candidate.
            destTerminal = directory.primaryTerminalOf({projectId: projectId, token: tokenOut});
            if (
                address(destTerminal) == address(0)
                    || _isCircularTerminal({router: router, projectId: projectId, terminal: destTerminal})
            ) {
                revert JBRouterTerminal_NoRouteFound(projectId, tokenIn);
            }

            // Score the explicitly requested route directly instead of scanning every accepted token.
            return _previewPayRouteForCandidate({
                router: router,
                projectId: projectId,
                tokenIn: tokenIn,
                amount: amount,
                beneficiary: beneficiary,
                metadata: metadata,
                tokenOut: tokenOut,
                destTerminal: destTerminal
            });
        }

        // Read the project's terminals without allowing a reverting directory call to brick preview.
        IJBTerminal[] memory terminals = _safeTerminalsOf({directory: directory, projectId: projectId});

        // Compact the project's accepted tokens down to the unique candidates worth scoring.
        (address[] memory candidateTokens, uint256 candidateCount) =
            _candidatePayRouteTokens({directory: directory, projectId: projectId, terminals: terminals});

        // Track whether any candidate produced a usable preview route.
        bool foundRoute;

        for (uint256 i; i < candidateCount; i++) {
            // Resolve the current candidate token back into the terminal that would receive it.
            IJBTerminal candidateTerminal =
                directory.primaryTerminalOf({projectId: projectId, token: candidateTokens[i]});

            // Skip candidates that would obviously bounce straight back into the router.
            if (_isCircularTerminal({router: router, projectId: projectId, terminal: candidateTerminal})) continue;

            // Isolate each candidate preview so one broken route does not brick the whole search.
            try self.previewPayRouteForCandidate(
                router, projectId, tokenIn, amount, beneficiary, metadata, candidateTokens[i], candidateTerminal
            ) returns (
                IJBTerminal candidateDestTerminal,
                address candidateTokenOut,
                uint256 candidateAmountOut,
                JBRuleset memory candidateRuleset,
                uint256 candidateBeneficiaryTokenCount,
                uint256 candidateReservedTokenCount,
                JBPayHookSpecification[] memory candidateHookSpecifications
            ) {
                // Replace the current winner whenever the candidate improves beneficiary count or tie-break reserved
                // count.
                if (
                    !foundRoute || candidateBeneficiaryTokenCount > beneficiaryTokenCount
                        || (candidateBeneficiaryTokenCount == beneficiaryTokenCount
                            && candidateReservedTokenCount > reservedTokenCount)
                ) {
                    // Persist the winning candidate's full preview payload for the eventual return value.
                    destTerminal = candidateDestTerminal;
                    tokenOut = candidateTokenOut;
                    amountOut = candidateAmountOut;
                    ruleset = candidateRuleset;
                    beneficiaryTokenCount = candidateBeneficiaryTokenCount;
                    reservedTokenCount = candidateReservedTokenCount;
                    hookSpecifications = candidateHookSpecifications;
                    foundRoute = true;
                }
            } catch {
                // Ignore broken candidates so the search can continue scoring the remaining options.
                continue;
            }
        }

        // Return the winning candidate when at least one candidate preview succeeded.
        if (foundRoute) {
            return
                (
                    destTerminal,
                    tokenOut,
                    amountOut,
                    ruleset,
                    beneficiaryTokenCount,
                    reservedTokenCount,
                    hookSpecifications
                );
        }

        // Fall back to the router's generic route resolution when no candidate token could be scored directly.
        (destTerminal, tokenOut, amountOut) = _previewRoute({
            router: router, destProjectId: projectId, tokenIn: tokenIn, amount: amount, metadata: metadata
        });

        // Preview the final terminal pay for that fallback route.
        (ruleset, beneficiaryTokenCount, reservedTokenCount, hookSpecifications) = router.previewTerminalPayOf({
            destTerminal: destTerminal,
            projectId: projectId,
            token: tokenOut,
            amount: amountOut,
            beneficiary: beneficiary,
            metadata: metadata
        });

        // Normalize the fallback preview counts so buyback-hook metadata still affects route ranking consistently.
        (beneficiaryTokenCount, reservedTokenCount) = _effectivePreviewPayTokenCounts({
            buybackHook: router.BUYBACK_HOOK(),
            beneficiaryTokenCount: beneficiaryTokenCount,
            reservedTokenCount: reservedTokenCount,
            hookSpecifications: hookSpecifications
        });
    }
}
