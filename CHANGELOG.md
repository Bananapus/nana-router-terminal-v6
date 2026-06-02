# Changelog

## Scope

This file describes the verified change from `nana-swap-terminal-v5` to the current `nana-router-terminal-v6` repo. In-v6 behavior changes that have semantic implications for integrators are also captured here.

## In-v6 changes

### `0.0.62` — Fail-open registry discovery views; refund partial-fill source cash-out residue

Two pre-deploy audit fixes; no storage-layout changes.

**`JBRouterTerminalRegistry.accountingContextForTokenOf` / `accountingContextsOf` no longer revert when no terminal
resolves.** These are read-only *discovery* views: `JBDirectory.primaryTerminalOf` calls `accountingContextForTokenOf`
and reads an empty context (`token == address(0)`) as "this terminal does not accept the token", falling through to the
next terminal. Reverting `JBRouterTerminalRegistry_TerminalNotSet` there propagated out of `primaryTerminalOf` and
bricked the *originating* operation — e.g. a USDC protocol-fee cash-out/payout routed to the fee project on a chain
where the registry has no default terminal set. The views now resolve via the non-reverting `_resolvedTerminalOf` and
return an empty context / empty array when nothing resolves, so the caller fails open (the fee is forgiven, not the
user's cash-out bricked). The transactional/fund-accepting paths (`pay`, `addToBalanceOf`, `previewPayFor`,
`lockTerminalFor`) keep `_requireResolvedTerminalOf` and still revert before accepting funds or forwarding into
`address(0)`.

**The recursive source cash-out loop refunds unsold project-token residue.** On a partial buyback-hook fill the hook
returns the unsold source project tokens to the holder (this router). The loop previously measured only the
reclaimed-token delta and left that residue stranded on the router. Each hop now measures the source-token residue as
`balanceAfter + cashOutCount - sourceBalanceBefore` — exactly the hook's returned unsold count, never sweeping
pre-existing balances — and refunds it to the route's refund recipient (`refundTo`).

### `0.0.61` — Raise dependency floors and document conventions in the style guide

Raise the dependency floors to the latest published versions, and document the NatSpec, comment, and lint conventions
in `STYLE_GUIDE.md`. No source contract changes.

### The registry's first default terminal also serves projects that pre-date it

`JBRouterTerminalRegistry.setDefaultTerminal` previously recorded a history segment only when replacing an existing
default. The very first call recorded none, so projects that already existed when the registry's default was first set —
the pre-existing cohort, which includes the canonical fee project (ID 1) and the other canonical revnets — resolved to no
terminal. As a result those projects could not route any token through the registry: a fee or payment in a token the
project's own multi-terminal does not hold resolved to nothing and was silently forgiven instead of being swapped to the
project's accepted token.

The first `setDefaultTerminal` now records a `(0, count]` history segment mapping the pre-existing cohort onto the new
default, so those projects resolve to it. Later default changes are unchanged: each still snapshots the outgoing default
for its own cohort, so an already-deployed project is never silently rerouted by a later default change.

Integrator impact: `accountingContextForTokenOf`, `accountingContextsOf`, `terminalOf`, `pay`, and `addToBalanceOf` now
return data / forward to the resolved default for pre-existing projects instead of reverting
`JBRouterTerminalRegistry_TerminalNotSet`. When no default has *ever* been set, the transactional paths (`pay`,
`addToBalanceOf`, `lockTerminalFor`) still revert; the read-only discovery views (`accountingContextForTokenOf`,
`accountingContextsOf`, `terminalOf`) instead return an empty context / empty array / `address(0)` — see the `0.0.62`
entry above.

### `discoverPool` returns the best V3 pool even when a deeper V4 pool exists

`JBRouterTerminal.discoverPool` is documented as a V3-only helper for off-chain queries, but it previously returned
`address(0)` whenever the best OVERALL pool for the pair was a V4 pool — even when a usable V3 pool existed. External
consumers reading it then saw "no pool" though a V3 pool was available.

`discoverPool` now returns the deepest available V3 pool whenever one exists, independent of whether a deeper V4 pool
exists for the same pair. It still reverts `JBRouterTerminal_NoPoolFound` only when no V3 pool exists at all.
`discoverBestPool` (which spans both V3 and V4) is unchanged.

Integrator impact: off-chain consumers of `discoverPool` now receive the V3 pool for pairs that also have a deeper V4
pool. No interface or on-chain routing behavior changes.

### Un-backstopped swap legs require a manipulation-resistant quote

The router auto-discovers Uniswap V4 pools including vanilla (hookless) pools, which expose no on-chain
manipulation-resistant price. For a quote-less swap through such a pool, `_getV4SpotQuote` previously fell back to a
slippage floor derived from the same pool's instantaneous spot tick — self-referential, and exploitable on legs with
no downstream backstop.

`pay` is unaffected: its top-level `minReturnedTokens` guards the entire routed result end-to-end. But
`addToBalanceOf` (and cash-out routes that settle via add-to-balance) have no such backstop. A new transient
`_strictSwapQuote` flag is set on those legs; when set, `_getV4SpotQuote` refuses the spot fallback for a pool with no
manipulation-resistant oracle and reverts `JBRouterTerminal_ManipulationResistantQuoteRequired`. V3 routing
(factory-verified + TWAP) and canonical-hook V4 pools (geomean oracle) are unaffected; off-chain previews keep the
default (lenient) behavior so estimates still resolve.

Integrator impact: programmatic callers of `addToBalanceOf` (or cash-out-to-add-balance routes) on a pair that only
has a vanilla V4 pool must now supply a `pay` swap quote, or the call reverts.

### Source cash-outs normalize router-held credits

When a route starts from a JB project token, the router now converts any internal credits it already holds for that
source project into ERC-20 project tokens before calling the source terminal's `cashOutTokensOf`. Core burns credits
before ERC-20 balances, so normalizing first keeps each source cash-out scoped to token balances that are visible to the
router's ERC-20 accounting.

This does not reintroduce credit inputs: callers still cannot route unclaimed credits directly through the router. Credit
holders must materialize their own credits as ERC-20 project tokens before paying through the router.

Integrator impact: no metadata or interface changes. Source cash-out routes become more robust when the router has
pre-existing credits for the source project.

### Metadata purposes renamed to lifecycle-phase names (`pay` / `cashOut`)

The router's two metadata purposes were renamed to match the lifecycle-phase naming the buyback hook (as of
`@bananapus/buyback-hook-v6@0.0.63`) and the 721 tiers hook already use:

- `quoteForSwap` → **`pay`** (the pay-phase swap quote, still encoded `(address tokenOut, uint256 minAmountOut)`).
- `cashOutMinReclaimed` → **`cashOut`** (the cash-out reclaim floor, still encoded `(uint256 minTokensReclaimed)`).

These purposes are keyed to the router's own address (`JBMetadataResolver.getId(purpose)` → `target: address(this)`),
so they never collided with the buyback hook's same-named purposes (which are keyed to the buyback address) — the
rename is purely a naming-consistency change, not a behavioral one. The encodings are unchanged.

Integrator impact: front-ends and programmatic callers building router metadata must key entries to `getId("pay", router)`
and `getId("cashOut", router)` instead of the old purpose strings. Old `getId("quoteForSwap", ...)` /
`getId("cashOutMinReclaimed", ...)` entries are silently ignored (different id), which disables slippage protection — so
this is a required update before using this router version.

Also bumps the `@bananapus/buyback-hook-v6` dependency `^0.0.58` → `^0.0.64` (0.0.63 introduced the matching
`pay`/`cashOut` purpose names on the buyback hook; 0.0.64 is a gas-only refactor that pre-computes those IDs as
constructor immutables). The router does not build buyback-targeted metadata, so the bump has no behavioral impact on
the router beyond staying current.

### `pay` swap quote binds the quoted output token

The `pay` swap-quote metadata encodes `(address tokenOut, uint256 minAmountOut)` instead of only `uint256 minAmountOut`.
The router normalizes ETH/WETH and reverts with `JBRouterTerminal_QuoteTokenMismatch` if the quoted token does not
match the route's selected output token.

Integrator impact: quote providers must encode `abi.encode(tokenOut, minAmountOut)`. Existing callers that still encode
only `abi.encode(minAmountOut)` must update their metadata construction before using this router version.

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
