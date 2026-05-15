# Changelog

## Scope

This file describes the verified change from `nana-swap-terminal-v5` to the current `nana-router-terminal-v6` repo. In-v6 behavior changes that have semantic implications for integrators are also captured here.

## In-v6 changes

### `pay()` routes project-token inputs through atomic cross-project cashout

When `pay(projectId, token, amount, ...)` is called with a JB project token, the router now routes through the source project's atomic `payAfterCashOutTokensOf` entrypoint on `JBMultiTerminal` (introduced in nana-core-v6 PR [#143](https://github.com/Bananapus/nana-core-v6/pull/143)) instead of doing the previous cashout-then-pay sequence as two router-driven steps. The source-side cashout fee is skipped and bound on the destination project's `_feeFreeSurplusOf` via core's balance-delta accounting. The destination project's current ruleset can opt out via `pauseCrossProjectFeeFreeInflows`, in which case the underlying core call reverts.

Selection logic: the router enumerates the source project's terminals and accounting contexts, previews `(cashout, pay-route)` per candidate via `previewCashOutFrom` + `previewBestPayRoute`, and picks the `(sourceTerminal, tokenToReclaim)` that yields the highest beneficiary mint on the destination project. Per-candidate previews are isolated with `try/catch` so one broken candidate cannot brick selection. Reverts with `JBRouterTerminal_NoCashOutPath` when nothing scores.

`addToBalanceOf()` now rejects JB project-token inputs with `JBRouterTerminal_ProjectTokenInputUnsupported(token, sourceProjectId)`. nana-core-v6 has no atomic `cashOut -> addToBalance` equivalent of `payAfterCashOutTokensOf`, and silently routing through a different shape than `pay()` would be a footgun. Callers wanting the previous "cash out a project token and add the reclaim to another project's balance" flow should cash out separately and call `addToBalanceOf` with the reclaim token.

The recursive cashout-loop machinery in the router is removed in this PR (no caller left after the `pay()` and `addToBalanceOf()` changes):

- `JBRouterTerminal`: deleted `_cashOutLoop`, `_previewCashOutLoop`, `previewCashOutLoopOf` (external), `_previewCashOutStep`, `_routeInputFromSource`, `_alignTokenToPreferredToken`, `_effectivePreviewCashOutAmount`, `_findRouteTerminal`, `_findCashOutPath`, `_recordCashOutPathCandidate`, `_minReclaimedFrom`. Removed `_MAX_CASHOUT_ITERATIONS`, `_CASH_OUT_MIN_RECLAIMED_ID`, errors `JBRouterTerminal_CashOutDidNotDeliver` and `JBRouterTerminal_CashOutLoopLimit`. `_route` and `_routeToDestination` no longer go through cashout preview — they only see non-project-token inputs.
- `JBPayRouteResolver`: deleted `_previewRouteInputFromSource` and its call sites in `_previewAmountToToken` and `_previewRoute`. Added the new `previewBestCashOutPath` external (and its `previewCashOutThenPay` external self-call helper) — these are what the router now calls from `_payAfterCashOut`.
- `IJBPayRoutePreviewer`: removed `previewCashOutLoopOf` from the preview surface the resolver consumes.
- `IJBPayRouteResolver`: added `previewBestCashOutPath` and `previewCashOutThenPay`.
- Removed: `src/structs/CashOutPathCandidates.sol` (the JB-project-token recursion fallback storage that fed `_findCashOutPath`).

A local interface extension lives at `src/interfaces/IJBCashOutTerminalCrossProject.sol`: a minimal re-declaration of `payAfterCashOutTokensOf` plus the canonical `IJBCashOutTerminal` surface, used as the cast target inside the router until the bumped core release folds the function into the canonical interface. When the bumped release is consumed, that file can be deleted and the cast site can use `IJBCashOutTerminal` directly.

Size impact:
- `JBRouterTerminal` runtime: 23,706 B → 20,211 B (-3,495 B, headroom 870 → 4,365 B against EIP-170 24,576 B).
- `JBPayRouteResolver` runtime: 10,398 B → 11,100 B (+702 B, headroom 14,178 → 13,476 B).

Integrator impact:
- `pay()` with a project-token input is strictly better-yielding now (source-side cashout fee skipped) — except when the destination project's ruleset has `pauseCrossProjectFeeFreeInflows = true`, in which case the call reverts. Front-ends should expose the opt-out flag in the destination project's ruleset config so payers can see the failure mode before submitting.
- `addToBalanceOf()` with a project-token input now reverts. Callers needing the prior shape should perform two transactions: `cashOutTokensOf` on the source project's terminal, then `addToBalanceOf` on the router with the reclaim token.

### Chain-same CREATE2 address for `JBRouterTerminal`

`JBRouterTerminal` now deploys to the same address on every chain via CREATE2. The four chain-specific
immutables (`WRAPPED_NATIVE_TOKEN`, `FACTORY`, `POOL_MANAGER`, `UNIV4_HOOK`) moved from `immutable` to public
storage and are wired in after deployment via a new one-shot `setChainSpecificConstants(wrappedNativeToken, factory, poolManager, univ4Hook)` setter, gated by a `_DEPLOYER` internal immutable (same pattern as `JBBuybackHook` and `JBUniswapV4LPSplitHookDeployer`).

- Constructor signature changed: `(IJBDirectory directory, IJBTokens tokens, IPermit2 permit2, address buybackHook, address trustedForwarder, address deployer)` — was 9 args, now 6. The four chain-different dependencies are no longer ctor inputs.
- New external function: `setChainSpecificConstants(IWETH9 wrappedNativeToken, IUniswapV3Factory factory, IPoolManager poolManager, address univ4Hook)`. Reverts with `JBRouterTerminal_Unauthorized(caller)` if msg.sender != `_DEPLOYER`; reverts with `JBRouterTerminal_AlreadyConfigured()` if `WRAPPED_NATIVE_TOKEN` has already been set.
- `BUYBACK_HOOK` stays as `public immutable` because `JBBuybackHook` is itself chain-same as of `@bananapus/buyback-hook-v6@0.0.44`.

`JBPayRouteResolver` also lost its `WRAPPED_NATIVE_TOKEN` immutable but does NOT call back into the router for it. Instead, the router passes its `WRAPPED_NATIVE_TOKEN` storage value as a parameter (`address wrappedNativeToken`) on every external resolver call (`previewBestPayRoute`, `previewPayRouteForCandidate`, `previewFallbackRoute`, `resolveTokenOut`), and the resolver threads it through internal helpers (`_normalizedTokenOf`, `_hasSameRoutingAsset`, `_discoverAcceptedToken`, `_resolveTokenOut`, `_previewAmountToToken`, `_previewRoute`). `_normalizedTokenOf` and `_hasSameRoutingAsset` are `pure` again. This avoids an extra external call per normalization step (which would compound inside the loops in `_discoverAcceptedToken`).

The resolver is still deployed in the router's constructor (chain-same input: just `directory`); its CREATE address is `router.address + nonce 1`, which is chain-same once the router itself is chain-same.

Integrator impact: deployers must call `setChainSpecificConstants` once after construction (the script in `script/Deploy.s.sol` does this in the same transaction as the deploy). Tests and the local deploy script have been updated accordingly.

Size: `JBRouterTerminal` 23,706 → 23,468 B (-238 B; headroom 870 → 1,108 B against the EIP-170 24,576 B limit). `JBPayRouteResolver` 10,438 → 10,398 B (-40 B).

### Removed: credit cash-out input path

The router no longer accepts unclaimed Juicebox credits as a payment input. The `cashOutSource` metadata key, the `sourceProjectIdOverride` parameter on `previewCashOutLoopOf`, the `IJBController.transferCreditsFrom` pull in `_acceptFundsFor`, and the `_cashOutSourceFrom` helper have all been removed. Credit holders should call `JBTokens.claimFor` to materialize their credits as an ERC-20 first, then route through the router as a normal ERC-20 payment.

- Removed: `IJBController` import + `_CASH_OUT_SOURCE_ID` immutable.
- Removed: 3 test files (`RouterTerminalCreditCashout.t.sol`, `regression/CreditCashoutSpoofedPayer.t.sol`, `regression/CreditCashoutPreferredTokenBypass.t.sol`, `regression/PreviewCashOutShortcircuitDivergence.t.sol`).
- Changed: `IJBPayRoutePreviewer.previewCashOutLoopOf` signature — dropped the `uint256 sourceProjectIdOverride` parameter (now 5 args).
- Frees ~580 B of runtime size; reduces attack surface (no msg.sender-vs-originalPayer ambiguity in the credit pull).

Integrator impact: any frontend or backend that constructs the `cashOutSource` metadata key and routes JB credits via the router must switch to a two-step flow (`claimFor` → `router.pay`).

### Threshold-protected `setDefaultTerminal`

The registry owner's `setDefaultTerminal(IJBTerminal)` call now applies only to projects created AFTER the call. Existing projects without an explicit `setTerminalFor` override keep resolving to the default that was current when their project-ID cohort was active. The outgoing default is snapshotted into an append-only `_defaultTerminalHistory` array on every `setDefaultTerminal` call.

- New view: `defaultTerminalFor(uint256 projectId)` returns the default applicable to a specific project (walks history if the project is in a legacy cohort).
- New view: `defaultTerminalProjectIdThreshold()` returns `PROJECTS.count()` at the time of the most recent `setDefaultTerminal`.
- New views: `defaultTerminalHistoryAt(uint256 index)` and `defaultTerminalHistoryLength()` expose the snapshot history.
- New struct: `DefaultTerminalSegment { uint256 maxProjectId; IJBTerminal terminal; }` in `src/structs/`.
- `lockTerminalFor` now snapshots the *cohort-correct* default into `_terminalOf` (via `_defaultTerminalFor(projectId)`) when locking a project that has no explicit terminal — not the current registry-wide default.

Indexer impact: read `defaultTerminalFor(projectId)` rather than `defaultTerminal()` when computing the effective default for any specific project.

Admin impact: the registry owner can no longer silently reroute payments for already-deployed projects by changing the default. See `ADMINISTRATION.md` for the updated boundary description.

### `0.0.41` — Document multi-hop forwarding-cycle as accepted risk

`JBRouterTerminalRegistry._requireNonCircularTerminalFor` only walks one hop of `IJBForwardingTerminal.terminalOf` when admitting a new explicit or default terminal. A multi-hop `A → B → registry` chain passes admission (the registry only sees `downstream == B ≠ self`), but once locked in, a subsequent `pay`/`addToBalanceOf` recurses through the registry until OOG. The `JBPayRouteResolver` swap-routing path already uses the bounded multi-hop helper `JBForwardingCheck.isCircularTerminal`; the registry admission path does not.

This is documented as accepted in `RISKS.md` (§Registry & Forwarding Risks). Impact is bounded to a self-locking DoS on the project that constructs the multi-hop chain — external actors cannot trigger it, and the project owner can rotate the registry default to recover. Per-PR retrofit cost was judged non-trivial relative to that impact. Project owners installing chained forwarding terminals should run a manual `JBForwardingCheck.isCircularTerminal({target: registry, projectId: …, terminal: candidate})` simulation before approving the candidate.

No runtime code change in this release — documentation only.

## Current v6 surface

- `JBRouterTerminal`
- `JBRouterTerminalRegistry`
- `JBPayRouteResolver`
- `IJBRouterTerminal`
- `IJBRouterTerminalRegistry`
- `IJBPayRouteResolver`
- `IJBPayRoutePreviewer`
- `IJBForwardingTerminal`
- `JBSwapLib`
- `CashOutPathCandidates`

## Summary

- The deployed terminal model changed from a swap terminal to a router terminal. That is a real conceptual change, not just a rename.
- Route discovery is now part of the product. The current repo is built around discovering paths and destination-token requirements instead of depending on the v5 manual pool-and-TWAP configuration style.
- The router terminal can reason about JB token cash-out flows as part of routing, which did not match the old swap-terminal mental model.
- The registry and terminal now share routing vocabulary with the v6 buyback hook through `JBSwapLib`.
- The repo moved from the v5 `0.8.23` baseline to `0.8.28`.

## Verified deltas

- The old admin surface around `addDefaultPool(...)` and `addTwapParamsFor(...)` is gone from the main interface.
- `IJBRouterTerminal` now extends `IJBTerminal`.
- `discoverPool(...)` and `discoverBestPool(...)` are first-class query methods in the interface.
- The current repo includes `previewPayFor(...)` routing behavior and JB-token cash-out path handling in its implementation and tests.

## Breaking ABI changes

- `IJBSwapTerminal` was replaced by `IJBRouterTerminal`.
- The old pool-configuration functions are gone from the main terminal interface.
- The terminal now inherits the broader `IJBTerminal` surface rather than exposing a narrow swap-only ABI.
- Discovery functions replaced manual pool/TWAP configuration as the public model.

## Indexer impact

- Event topology changed with the router-terminal and registry model; do not assume swap-terminal event families map one-to-one.
- Off-chain route computation can now rely on explicit discovery and preview methods instead of stored default-pool config.

## Migration notes

- Replace both terminology and ABI assumptions: `JBSwapTerminal` is not the right reference point for a v6 integration.
- Re-check any off-chain service that used manually configured pool metadata as the primary source of truth.
- Regenerate ABIs and re-index events from the current router-terminal contracts.

## ABI appendix

- Replaced interface
  - `IJBSwapTerminal` -> `IJBRouterTerminal`
- Removed swap-terminal-style admin/config functions
  - `addDefaultPool(...)`
  - `addTwapParamsFor(...)`
- Added router-oriented query functions
  - `discoverPool(...)`
  - `discoverBestPool(...)`
- Surface expansion
  - now inherits the broader `IJBTerminal` interface
