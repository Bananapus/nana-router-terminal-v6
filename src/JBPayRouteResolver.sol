// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {JBForwardingCheck} from "./libraries/JBForwardingCheck.sol";
import {IJBPayRoutePreviewer} from "./interfaces/IJBPayRoutePreviewer.sol";
import {IJBPayRouteResolver} from "./interfaces/IJBPayRouteResolver.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";

/// @notice Evaluates every token a destination project accepts and returns the route that yields the most project
/// tokens for the beneficiary, deployed as a helper to keep `JBRouterTerminal` within runtime size limits.
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

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The directory storing project terminal relationships.
    /// @dev The wrapped-native-token address is intentionally NOT cached here. The router passes it in as a parameter
    /// (`address wrappedNativeToken`) on every external resolver call and the resolver threads it through internal
    /// helpers. This keeps the resolver's constructor inputs chain-same (no chain-specific WETH baked in) so its
    /// CREATE address (router + nonce 1) stays unified, AND avoids paying an extra external call per normalization
    /// step inside loops like `_discoverAcceptedToken`.
    constructor(IJBDirectory directory) {
        DIRECTORY = directory;
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
    /// @param wrappedNativeToken The router's wrapped-native-token address (threaded from the caller to avoid an extra
    /// external call on every normalization in this loop).
    /// @param projectId The destination project whose accepted tokens should be searched.
    /// @param tokenIn The input token to find a route from.
    /// @return tokenOut The best accepted token found.
    /// @return destTerminal The terminal that accepts `tokenOut`.
    function _discoverAcceptedToken(
        IJBPayRoutePreviewer router,
        address wrappedNativeToken,
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
        address normalizedTokenIn = _normalizedTokenOf({wrappedNativeToken: wrappedNativeToken, token: tokenIn});

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

                // Normalize the candidate so native-vs-wrapped comparisons behave the same as the router.
                address normalizedCandidate =
                    _normalizedTokenOf({wrappedNativeToken: wrappedNativeToken, token: candidateToken});

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

            // Decode the buyback hook's routing metadata. When the hook mints in `afterPayRecordedWith`, the terminal
            // preview returns zero token counts and the router must score the route from the hook's commitments.
            (
                ,
                uint256 amountToMintWith,
                uint256 minimumSwapAmountOut,,,
                uint256 tokenCountWithoutHook,,,,,
                uint256 minimumBeneficiaryTokenCount,
                uint256 minimumReservedTokenCount,
                uint256 rawSwapQuote
            ) = abi.decode(
                specification.metadata,
                (
                    bool,
                    uint256,
                    uint256,
                    bool,
                    address,
                    uint256,
                    uint256,
                    int24,
                    uint128,
                    bytes32,
                    uint256,
                    uint256,
                    uint256
                )
            );

            // The hook's beneficiary/reserved commitments are only for the AMM leg. If the hook leaves part of the
            // payment to mint directly, estimate that direct-mint leg at the same issuance rate used for the swapped
            // amount so the router compares a whole-route token count against ordinary terminal previews.
            uint256 directMintTokenCount;
            if (amountToMintWith != 0 && specification.amount != 0 && tokenCountWithoutHook != 0) {
                directMintTokenCount =
                    mulDiv({x: amountToMintWith, y: tokenCountWithoutHook, denominator: specification.amount});
            }

            // Score the executable floor first. This supports callers that only provide a minimum and no live quote.
            (uint256 candidateBeneficiaryTokenCount, uint256 candidateReservedTokenCount) = _scaledPreviewPayTokenCounts({
                tokenCount: minimumSwapAmountOut + directMintTokenCount,
                referenceTokenCount: minimumSwapAmountOut,
                referenceBeneficiaryTokenCount: minimumBeneficiaryTokenCount,
                referenceReservedTokenCount: minimumReservedTokenCount
            });
            (effectiveBeneficiaryTokenCount, effectiveReservedTokenCount) = _strongerPreviewPayTokenCounts({
                currentBeneficiaryTokenCount: effectiveBeneficiaryTokenCount,
                currentReservedTokenCount: effectiveReservedTokenCount,
                candidateBeneficiaryTokenCount: candidateBeneficiaryTokenCount,
                candidateReservedTokenCount: candidateReservedTokenCount
            });

            // If the hook also surfaced a stronger live quote, score it too. This lets programmatic buyback routes win
            // when the expected executable output is better than the conservative minimum.
            if (rawSwapQuote > minimumSwapAmountOut) {
                (candidateBeneficiaryTokenCount, candidateReservedTokenCount) = _scaledPreviewPayTokenCounts({
                    tokenCount: rawSwapQuote + directMintTokenCount,
                    referenceTokenCount: minimumSwapAmountOut,
                    referenceBeneficiaryTokenCount: minimumBeneficiaryTokenCount,
                    referenceReservedTokenCount: minimumReservedTokenCount
                });
                (effectiveBeneficiaryTokenCount, effectiveReservedTokenCount) = _strongerPreviewPayTokenCounts({
                    currentBeneficiaryTokenCount: effectiveBeneficiaryTokenCount,
                    currentReservedTokenCount: effectiveReservedTokenCount,
                    candidateBeneficiaryTokenCount: candidateBeneficiaryTokenCount,
                    candidateReservedTokenCount: candidateReservedTokenCount
                });
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
        return JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId(key, address(router)), metadata: metadata});
    }

    /// @notice Check whether two tokens share the same routing representation for the router.
    /// @param wrappedNativeToken The router's wrapped-native-token address, used to normalize native vs wrapped.
    /// @param tokenA The first token to compare.
    /// @param tokenB The second token to compare.
    /// @return hasSameAsset A flag indicating whether the router would treat both tokens as the same asset.
    function _hasSameRoutingAsset(
        address wrappedNativeToken,
        address tokenA,
        address tokenB
    )
        internal
        pure
        returns (bool hasSameAsset)
    {
        // Treat exact-token matches as the same routing asset without extra normalization work.
        if (tokenA == tokenB) return true;

        // Otherwise compare normalized representations so native and wrapped native tokens share one routing identity.
        return _normalizedTokenOf({wrappedNativeToken: wrappedNativeToken, token: tokenA})
            == _normalizedTokenOf({wrappedNativeToken: wrappedNativeToken, token: tokenB});
    }

    /// @notice Whether previewing through a terminal would cycle back into the router.
    /// @dev Delegates to `JBForwardingCheck.isCircularTerminal` — shared with `JBRouterTerminal` so that
    /// preview and execution use identical cycle-detection logic.
    /// @param router The router whose preview path to evaluate.
    /// @param projectId The project to resolve forwarding terminal for.
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
        return JBForwardingCheck.isCircularTerminal({target: address(router), projectId: projectId, terminal: terminal});
    }

    /// @notice Normalize a token into the form the router uses for routing comparisons.
    /// @param wrappedNativeToken The router's wrapped-native-token address.
    /// @param token The token to normalize.
    /// @return normalizedToken The normalized token address.
    function _normalizedTokenOf(
        address wrappedNativeToken,
        address token
    )
        internal
        pure
        returns (address normalizedToken)
    {
        return token == JBConstants.NATIVE_TOKEN ? wrappedNativeToken : token;
    }

    /// @notice Preview the amount that would be routed into a specific destination token.
    /// @param router The router terminal whose preview helpers to use.
    /// @param wrappedNativeToken The router's wrapped-native-token address.
    /// @param destProjectId The destination project the router is trying to pay.
    /// @param tokenIn The token currently available to route.
    /// @param amount The amount of `tokenIn` to preview.
    /// @param metadata Metadata that may encode cashout-source and route-token overrides.
    /// @param tokenOut The preferred destination token to preview.
    /// @return routedTokenIn The token that would actually be provided to the destination terminal.
    /// @return routedAmountIn The amount of `routedTokenIn` that would reach the destination terminal.
    function _previewAmountToToken(
        IJBPayRoutePreviewer router,
        address wrappedNativeToken,
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
        // Project-token inputs are intercepted upstream in `JBRouterTerminal.pay()` and routed through
        // `IJBCashOutTerminal.cashOutAndPay`, so the resolver only sees non-project-token inputs here.
        destProjectId; // Silence "unused parameter" — kept for natspec / signature stability.
        routedTokenIn = tokenIn;
        routedAmountIn = amount;

        // Return early when the routed token already matches the desired destination token.
        if (_hasSameRoutingAsset({wrappedNativeToken: wrappedNativeToken, tokenA: routedTokenIn, tokenB: tokenOut})) {
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
    /// @param router The router terminal whose preview helpers to use.
    /// @param projectId The destination project that would receive the payment.
    /// @param tokenIn The token currently available to route.
    /// @param amount The amount of `tokenIn` to preview.
    /// @param beneficiary The address to measure beneficiary token count for.
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
        address wrappedNativeToken,
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
            wrappedNativeToken: wrappedNativeToken,
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

    /// @notice Preview the fallback route that would be used when no candidate token can be scored directly.
    /// @param router The router terminal whose preview helpers to use.
    /// @param destProjectId The destination project to pay.
    /// @param tokenIn The token currently available to route.
    /// @param amount The amount of `tokenIn` to preview.
    /// @param metadata Metadata forwarded into preview helpers.
    /// @return destTerminal The terminal the router would use.
    /// @return tokenOut The token `destTerminal` would receive.
    /// @return amountOut The amount of `tokenOut` that would be routed.
    function _previewRoute(
        IJBPayRoutePreviewer router,
        address wrappedNativeToken,
        uint256 destProjectId,
        address tokenIn,
        uint256 amount,
        bytes calldata metadata
    )
        internal
        view
        returns (IJBTerminal destTerminal, address tokenOut, uint256 amountOut)
    {
        // Project-token inputs are intercepted upstream in `JBRouterTerminal.pay()` and routed through
        // `IJBCashOutTerminal.cashOutAndPay`; the resolver only handles non-project-token inputs here.

        // Resolve the destination token and terminal that the project would accept from the remaining input.
        (tokenOut, destTerminal) = _resolveTokenOut({
            router: router,
            wrappedNativeToken: wrappedNativeToken,
            projectId: destProjectId,
            tokenIn: tokenIn,
            metadata: metadata
        });

        // Return the current amount unchanged when no swap is needed after token resolution.
        if (_hasSameRoutingAsset({wrappedNativeToken: wrappedNativeToken, tokenA: tokenIn, tokenB: tokenOut})) {
            return (destTerminal, tokenOut, amount);
        }

        // Otherwise preview the swap into the resolved destination token.
        amountOut =
            router.previewSwapAmountOutOf({tokenIn: tokenIn, tokenOut: tokenOut, amount: amount, metadata: metadata});
    }

    /// @notice Resolve what output token a project accepts for a given input token.
    /// @param router The router whose view helpers to use.
    /// @param wrappedNativeToken The router's wrapped-native-token address.
    /// @param projectId The destination project to pay.
    /// @param tokenIn The input token to route.
    /// @param metadata Metadata forwarded into route-token resolution.
    /// @return tokenOut The token the project accepts.
    /// @return destTerminal The terminal that accepts `tokenOut`.
    function _resolveTokenOut(
        IJBPayRoutePreviewer router,
        address wrappedNativeToken,
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
                revert JBRouterTerminal_NoRouteFound({projectId: projectId, tokenIn: tokenIn});
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
        if (tokenIn == JBConstants.NATIVE_TOKEN || tokenIn == wrappedNativeToken) {
            tokenOut = tokenIn == JBConstants.NATIVE_TOKEN ? wrappedNativeToken : JBConstants.NATIVE_TOKEN;
            destTerminal = directory.primaryTerminalOf({projectId: projectId, token: tokenOut});
            if (
                address(destTerminal) != address(0)
                    && !_isCircularTerminal({router: router, projectId: projectId, terminal: destTerminal})
            ) {
                return (tokenOut, destTerminal);
            }
        }

        // Finally discover the best accepted token using the router's liquidity heuristic.
        (tokenOut, destTerminal) = _discoverAcceptedToken({
            router: router, wrappedNativeToken: wrappedNativeToken, projectId: projectId, tokenIn: tokenIn
        });

        // Revert when discovery failed entirely or only found a circular route.
        if (
            address(destTerminal) == address(0)
                || _isCircularTerminal({router: router, projectId: projectId, terminal: destTerminal})
        ) {
            revert JBRouterTerminal_NoRouteFound({projectId: projectId, tokenIn: tokenIn});
        }
    }

    /// @notice Best-effort terminal lookup that degrades to an empty list if the directory call reverts.
    /// @param directory The directory storing project terminal relationships.
    /// @param projectId The project to look up terminals for.
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

    /// @notice Scale a known beneficiary/reserved token split to a different total token count.
    /// @param tokenCount The total token count to score.
    /// @param referenceTokenCount The total token count the reference split was computed from.
    /// @param referenceBeneficiaryTokenCount The beneficiary share of the reference split.
    /// @param referenceReservedTokenCount The reserved share of the reference split.
    /// @return beneficiaryTokenCount The scaled beneficiary token count.
    /// @return reservedTokenCount The scaled reserved token count.
    function _scaledPreviewPayTokenCounts(
        uint256 tokenCount,
        uint256 referenceTokenCount,
        uint256 referenceBeneficiaryTokenCount,
        uint256 referenceReservedTokenCount
    )
        internal
        pure
        returns (uint256 beneficiaryTokenCount, uint256 reservedTokenCount)
    {
        // A zero candidate means there is no stronger route output to scale, so preserve the known reference split.
        if (tokenCount == 0) {
            return (referenceBeneficiaryTokenCount, referenceReservedTokenCount);
        }

        // Prefer the already-previewed beneficiary/reserved total because it includes the destination's reserve logic.
        uint256 referenceTotal = referenceBeneficiaryTokenCount + referenceReservedTokenCount;

        // Fall back to the original token count when previewed counts were unavailable but the hook reported a floor.
        if (referenceTotal == 0) referenceTotal = referenceTokenCount;

        // If both reference totals are zero, treat the whole candidate as beneficiary tokens so the route stays
        // comparable instead of disappearing from scoring.
        if (referenceTotal == 0) return (tokenCount, 0);

        // Scale the beneficiary share proportionally from the reference split to the candidate total being scored.
        beneficiaryTokenCount = mulDiv({x: tokenCount, y: referenceBeneficiaryTokenCount, denominator: referenceTotal});

        // Assign the residual to reserved tokens so rounding cannot lose supply during route comparison.
        reservedTokenCount = tokenCount - beneficiaryTokenCount;
    }

    /// @notice Choose the stronger preview outcome using beneficiary tokens first and reserved tokens as a tie-break.
    /// @param currentBeneficiaryTokenCount The beneficiary token count from the strongest route so far.
    /// @param currentReservedTokenCount The reserved token count from the strongest route so far.
    /// @param candidateBeneficiaryTokenCount The beneficiary token count from the candidate route.
    /// @param candidateReservedTokenCount The reserved token count from the candidate route.
    /// @return beneficiaryTokenCount The beneficiary token count to keep.
    /// @return reservedTokenCount The reserved token count to keep.
    function _strongerPreviewPayTokenCounts(
        uint256 currentBeneficiaryTokenCount,
        uint256 currentReservedTokenCount,
        uint256 candidateBeneficiaryTokenCount,
        uint256 candidateReservedTokenCount
    )
        internal
        pure
        returns (uint256 beneficiaryTokenCount, uint256 reservedTokenCount)
    {
        // Prefer the route that gives the beneficiary more tokens, since that is the user's primary output.
        if (
            candidateBeneficiaryTokenCount > currentBeneficiaryTokenCount
                || (
                    // When beneficiary output ties, keep the route that also mints more reserved tokens.
                    candidateBeneficiaryTokenCount == currentBeneficiaryTokenCount
                    && candidateReservedTokenCount > currentReservedTokenCount
                )
        ) {
            return (candidateBeneficiaryTokenCount, candidateReservedTokenCount);
        }

        // Keep the current winner when the candidate does not improve beneficiary output or the reserved tie-break.
        return (currentBeneficiaryTokenCount, currentReservedTokenCount);
    }

    /// @notice Resolve the usable primary terminal for a discovered candidate token.
    /// @param router The router whose circular-terminal rule to apply.
    /// @param directory The directory used to resolve primary terminals.
    /// @param projectId The destination project to inspect.
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

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @inheritdoc IJBPayRouteResolver
    function previewBestPayRoute(
        IJBPayRoutePreviewer router,
        address wrappedNativeToken,
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
                revert JBRouterTerminal_NoRouteFound({projectId: projectId, tokenIn: tokenIn});
            }

            // Score the explicitly requested route directly instead of scanning every accepted token.
            return _previewPayRouteForCandidate({
                router: router,
                wrappedNativeToken: wrappedNativeToken,
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
                router,
                wrappedNativeToken,
                projectId,
                tokenIn,
                amount,
                beneficiary,
                metadata,
                candidateTokens[i],
                candidateTerminal
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

        // No candidate token could be scored — fall back to the router's generic route resolution.
        // Uses an external self-call (`self.previewFallbackRoute`) so Solidity's try/catch can isolate
        // reverts from broken terminals or price feeds without bricking the entire best-route preview.
        try self.previewFallbackRoute(
            router, wrappedNativeToken, projectId, tokenIn, amount, beneficiary, metadata
        ) returns (
            IJBTerminal fallbackDestTerminal,
            address fallbackTokenOut,
            uint256 fallbackAmountOut,
            JBRuleset memory fallbackRuleset,
            uint256 fallbackBeneficiaryTokenCount,
            uint256 fallbackReservedTokenCount,
            JBPayHookSpecification[] memory fallbackHookSpecifications
        ) {
            destTerminal = fallbackDestTerminal;
            tokenOut = fallbackTokenOut;
            amountOut = fallbackAmountOut;
            ruleset = fallbackRuleset;
            beneficiaryTokenCount = fallbackBeneficiaryTokenCount;
            reservedTokenCount = fallbackReservedTokenCount;
            hookSpecifications = fallbackHookSpecifications;
        } catch {
            // If the fallback also fails, return default zero values — the caller gets "no route found".
        }
    }

    /// @notice External self-call wrapper that previews the fallback route in an isolated context.
    /// @dev Solidity's `try/catch` only works on external calls. `previewBestPayRoute` calls
    /// `self.previewFallbackRoute(...)` so that a revert in the fallback path (e.g. a broken terminal or
    /// price feed) is caught instead of bricking the entire best-route preview.
    /// @dev This function should only be called by this contract itself — external callers have no reason to use it.
    /// @param routePreviewer The router terminal whose preview helpers to use for simulating the route.
    /// @param destProjectId The project to pay through the fallback route.
    /// @param tokenIn The token the payer is sending.
    /// @param amountIn The amount of `tokenIn` to route.
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
        address wrappedNativeToken,
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
        )
    {
        // Resolve which terminal and token the fallback route would use.
        (destTerminal, tokenOut, amountOut) = _previewRoute({
            router: routePreviewer,
            wrappedNativeToken: wrappedNativeToken,
            destProjectId: destProjectId,
            tokenIn: tokenIn,
            amount: amountIn,
            metadata: metadata
        });

        // Simulate the terminal pay to get token counts and hook specs.
        (ruleset, beneficiaryTokenCount, reservedTokenCount, hookSpecifications) = routePreviewer.previewTerminalPayOf({
            destTerminal: destTerminal,
            projectId: destProjectId,
            token: tokenOut,
            amount: amountOut,
            beneficiary: beneficiary,
            metadata: metadata
        });

        // Normalize counts to account for buyback-hook overrides.
        (beneficiaryTokenCount, reservedTokenCount) = _effectivePreviewPayTokenCounts({
            buybackHook: routePreviewer.BUYBACK_HOOK(),
            beneficiaryTokenCount: beneficiaryTokenCount,
            reservedTokenCount: reservedTokenCount,
            hookSpecifications: hookSpecifications
        });
    }

    /// @notice External wrapper so candidate previews can be isolated with `try/catch`.
    /// @param router The router terminal whose preview helpers to use.
    /// @param projectId The destination project that would receive the payment.
    /// @param tokenIn The token currently available to route.
    /// @param amount The amount of `tokenIn` to preview.
    /// @param beneficiary The address to measure beneficiary token count for.
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
        address wrappedNativeToken,
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
            wrappedNativeToken: wrappedNativeToken,
            projectId: projectId,
            tokenIn: tokenIn,
            amount: amount,
            beneficiary: beneficiary,
            metadata: metadata,
            tokenOut: tokenOut,
            destTerminal: destTerminal
        });
    }

    /// @inheritdoc IJBPayRouteResolver
    function resolveTokenOut(
        IJBPayRoutePreviewer router,
        address wrappedNativeToken,
        uint256 projectId,
        address tokenIn,
        bytes calldata metadata
    )
        external
        view
        returns (address tokenOut, IJBTerminal destTerminal)
    {
        return _resolveTokenOut({
            router: router,
            wrappedNativeToken: wrappedNativeToken,
            projectId: projectId,
            tokenIn: tokenIn,
            metadata: metadata
        });
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

    /// @notice Pick the `(sourceTerminal, tokenToReclaim)` that yields the highest previewed beneficiary mint when
    /// the router routes a JB project-token input through `IJBCashOutTerminal.cashOutAndPay`.
    /// @dev Walks the source project's terminals, filters to `IJBCashOutTerminal` implementers, and previews each
    /// accounting context as a potential `tokenToReclaim`. Each candidate's score is the predicted destination-side
    /// mint, sourced from `previewCashOutFrom` (cashout side) + `previewBestPayRoute` (destination side). Broken
    /// candidates are isolated with `try/catch` so a single revert cannot brick selection.
    /// @param router The router terminal whose preview helpers to use.
    /// @param wrappedNativeToken The router's wrapped-native-token address.
    /// @param sourceProjectId The source project whose tokens were paid in.
    /// @param cashOutCount The number of source-project tokens to burn.
    /// @param beneficiaryProjectId The destination project that should receive the routed payment.
    /// @param beneficiary The address whose minted destination-project tokens to score.
    /// @param payMetadata Metadata forwarded into the destination-side preview.
    /// @return sourceTerminal The winning source project's cash-out terminal, or `address(0)` if nothing scored.
    /// @return tokenToReclaim The winning `tokenToReclaim`, or `address(0)` if nothing scored.
    function previewBestCashOutPath(
        IJBPayRoutePreviewer router,
        address wrappedNativeToken,
        uint256 sourceProjectId,
        uint256 cashOutCount,
        uint256 beneficiaryProjectId,
        address beneficiary,
        bytes calldata payMetadata
    )
        external
        view
        returns (IJBCashOutTerminal sourceTerminal, address tokenToReclaim)
    {
        // Cache a self-interface once so per-candidate previews can be isolated with `try/catch`.
        IJBPayRouteResolver self = IJBPayRouteResolver(address(this));

        // Walk the source project's terminals. Best-effort so a single reverting terminal does not brick selection.
        IJBTerminal[] memory terminals = _safeTerminalsOf({directory: DIRECTORY, projectId: sourceProjectId});

        // Track the highest previewed beneficiary mint observed across all candidates.
        uint256 bestBeneficiaryCount;

        for (uint256 i; i < terminals.length;) {
            // Filter to cashout-capable terminals so the eventual `cashOutAndPay` call cannot land on a terminal
            // that does not implement the cashout surface.
            try IERC165(address(terminals[i])).supportsInterface(type(IJBCashOutTerminal).interfaceId) returns (
                bool supported
            ) {
                if (!supported) {
                    unchecked {
                        ++i;
                    }
                    continue;
                }
            } catch {
                unchecked {
                    ++i;
                }
                continue;
            }

            // Read the source terminal's accounting contexts. Wrap in try/catch so a single reverting terminal does
            // not brick selection.
            JBAccountingContext[] memory contexts;
            try terminals[i].accountingContextsOf(sourceProjectId) returns (JBAccountingContext[] memory ctx) {
                contexts = ctx;
            } catch {
                unchecked {
                    ++i;
                }
                continue;
            }

            IJBCashOutTerminal candidateTerminal = IJBCashOutTerminal(address(terminals[i]));

            for (uint256 j; j < contexts.length;) {
                address candidateToken = contexts[j].token;

                // Skip candidates the destination project cannot actually receive on any terminal — core's
                // `_routeReclaimToBeneficiaryProject` would revert with `RecipientProjectTerminalNotFound` later.
                if (
                    address(DIRECTORY.primaryTerminalOf({projectId: beneficiaryProjectId, token: candidateToken}))
                        == address(0)
                ) {
                    unchecked {
                        ++j;
                    }
                    continue;
                }

                // Score the candidate via an isolated self-call so a single broken preview cannot brick the loop.
                try self.previewCashOutThenPay(
                    router,
                    wrappedNativeToken,
                    candidateTerminal,
                    sourceProjectId,
                    cashOutCount,
                    candidateToken,
                    beneficiaryProjectId,
                    beneficiary,
                    payMetadata
                ) returns (
                    uint256 previewedBeneficiaryCount
                ) {
                    if (previewedBeneficiaryCount > bestBeneficiaryCount) {
                        bestBeneficiaryCount = previewedBeneficiaryCount;
                        tokenToReclaim = candidateToken;
                        sourceTerminal = candidateTerminal;
                    }
                } catch {
                    // Ignore broken candidates so the search can continue scoring the remaining options.
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

    /// @notice External self-call wrapper so a single candidate's preview can be isolated with `try/catch`.
    /// @dev Only meaningful to call internally from `previewBestCashOutPath`. `previewCashOutFrom` (source side)
    /// gives the gross reclaim — the cashout-side fee is skipped in the atomic entrypoint, so the gross is what
    /// the destination receives. `previewBestPayRoute` (destination side) handles any downstream swap/forward leg
    /// internally. Returns `0` for any preview that surfaced a zero reclaim or could not be scored.
    /// @param router The router terminal whose preview helpers to use.
    /// @param wrappedNativeToken The router's wrapped-native-token address.
    /// @param sourceTerminal The source project's cash-out terminal.
    /// @param sourceProjectId The source project whose tokens were paid in.
    /// @param cashOutCount The number of source-project tokens to burn.
    /// @param tokenToReclaim The candidate `tokenToReclaim` being scored.
    /// @param beneficiaryProjectId The destination project that should receive the routed payment.
    /// @param beneficiary The address whose minted destination-project tokens to score.
    /// @param payMetadata Metadata forwarded into the destination-side preview.
    /// @return beneficiaryTokenCount The previewed beneficiary token count, or `0` if the candidate is unscoreable.
    function previewCashOutThenPay(
        IJBPayRoutePreviewer router,
        address wrappedNativeToken,
        IJBCashOutTerminal sourceTerminal,
        uint256 sourceProjectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 beneficiaryProjectId,
        address beneficiary,
        bytes calldata payMetadata
    )
        external
        view
        returns (uint256 beneficiaryTokenCount)
    {
        // Preview the source-side cashout to obtain the gross reclaim that would land on the destination terminal.
        (, uint256 reclaimAmount,,) = sourceTerminal.previewCashOutFrom({
            holder: address(router),
            projectId: sourceProjectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: tokenToReclaim,
            beneficiary: payable(address(router)),
            metadata: ""
        });

        if (reclaimAmount == 0) return 0;

        // Preview the destination-side route. `previewBestPayRoute` explores accepted-token candidates and any
        // necessary swap leg internally so this scorer doesn't need to re-enumerate.
        (,,,, beneficiaryTokenCount,,) = IJBPayRouteResolver(address(this))
            .previewBestPayRoute({
            router: router,
            wrappedNativeToken: wrappedNativeToken,
            projectId: beneficiaryProjectId,
            tokenIn: tokenToReclaim,
            amount: reclaimAmount,
            beneficiary: beneficiary,
            metadata: payMetadata
        });
    }
}
