# Architecture

## Purpose

`nana-router-terminal-v6` lets a payer fund a Juicebox project with a token the project does not directly accept. It discovers the destination token, wraps or unwraps native assets when needed, can recursively cash out upstream JB project tokens, and swaps through bounded Uniswap V3 or V4 routes before forwarding value to the destination terminal.

The router is intentionally heuristic. It does not search every possible route for a globally optimal price.

## System overview

`JBRouterTerminal` is a terminal-shaped adapter, not an accounting source of truth. `JBRouterTerminalRegistry` is both a registry and a stable project-facing proxy surface: projects can point at the registry while the registry resolves, and can later lock, the actual router terminal implementation to use. For authenticated terminal-originated project transfers, it also retains failed downstream forwards for permissionless retry and deterministic source-project refund. `JBPayRouteResolver` expands preview candidates without forcing the main router contract to carry all preview complexity inline.

Final project accounting still happens in the downstream terminal selected through `nana-core-v6`. A pending registry call is custody, not credited project balance, until downstream settlement succeeds or autonomous finalization restores the original asset to the source project's terminal balance.

## Core invariants

- the router's own accounting context is synthetic and must not be treated as the project ledger
- preview route discovery and live execution must stay aligned
- buyback-hook preview scoring must distinguish executable floors from diagnostics
- refund behavior is part of correctness, not only UX
- registry locking prevents silent migration to untrusted router implementations
- `addToBalanceOf` final hops reject ERC-20 receipt shortfalls; `pay` cannot rely on terminal balance deltas because pay hooks can consume tokens during settlement
- recursive project-token cashout routing is intentionally bounded
- caller reclaim minima only apply to the first cashout hop, because later hops may change token units
- circular `router -> registry -> same router` forwarding remains blocked in the registry
- a downstream failure cannot turn an authenticated registry-mediated project payout or non-native protocol fee into a successful source-terminal catch
- an underfunded retry cannot advance a pending call's failure streak, and a changed error or route restarts qualification

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBRouterTerminal` | Intake, route discovery, swap execution, forwarding, and refunds | Main runtime surface |
| `JBRouterTerminalRegistry` | Project-level router selection, locking, proxy forwarding, and failed-forward custody | Governance, permissionless retry, and deterministic refund surface |
| `JBPayRouteResolver` | Preview candidate evaluation | Helper to keep runtime size bounded |
| `JBSwapLib` and routing structs | Pool discovery, quoting, and route metadata | Shared routing logic |

## Trust boundaries

- final accounting remains in the downstream terminal selected through `JBDirectory`
- the router trusts Uniswap V3, Uniswap V4, Permit2, and optional payer trackers for routing-side behavior
- fee-on-transfer tokens are reconciled on ingress but remain unsafe for routed payments because terminal-side loss is not enforced on `pay`
- the registry is trusted to resolve and forward into the intended router implementation for a project
- only a core terminal authenticated against the registry's `PROJECTS` directory receives fail-closed forwarding; ordinary callers keep synchronous revert semantics

## Critical flows

### Route and pay

```text
router pay call
  -> accept native, ERC-20, or JB-token-like input
  -> if input is a project token, recursively cash it out first
  -> resolve the destination token the project terminal actually accepts
  -> choose the best direct, wrap/unwrap, or swap path under the router's bounded candidate-discovery heuristic
  -> execute the route and forward the result to the downstream terminal
  -> refund leftover input when possible
```

### Terminal-originated project transfer

```text
source terminal fee or project payout
  -> registry authenticates the raw source-project metadata against the source terminal's directory
  -> registry retains enough gas to handle a failed downstream router call
  -> success: downstream terminal settles normally
  -> failure: registry keeps exact token custody and records a deterministic pending call
  -> any caller makes fixed-gas retries against the project's currently resolved terminal
  -> success: downstream terminal settles normally
  -> three identical failures in daily windows: wait one more day and make a final fixed-gas attempt
  -> identical final failure: restore the original asset to the authenticated source terminal's project balance
  -> changed error or route: restart the failure streak and keep custody
```

## Accounting model

The router does not own project balances. It owns transient route accounting: input reconciliation, swap execution, forwarded amount, and refund resolution. The registry may temporarily own assets backing pending terminal calls one-for-one, but those assets are never reported as project surplus and cannot be withdrawn by the registry owner.

Preview and execution share the same conceptual route shape: optional recursive cashout first, then destination-token resolution, then final conversion and forwarding.

## Security model

- native-asset handling and refunds are the most failure-prone paths
- V3 and V4 discovery must stay synchronized between preview and live execution
- V3 callbacks are valid only during the router-initiated pool swap that set the transient expected pool
- V4 discovery intentionally considers both vanilla pools and pools using the canonical `UNIV4_HOOK`
- the router's "best route" claim is only as strong as its bounded discovery set and external-terminal safety checks
- recursive cashout behavior, preferred-token handling, and one-shot source overrides are tightly coupled

## Safe change guide

- keep route discovery and route execution semantics paired
- be conservative with native wrapping, unwrapping, and refund behavior
- if recursive cash-out logic changes, review hop limits and failure handling together
- if metadata semantics change, re-check first-hop reclaim minima, one-shot source overrides, and preferred-token routing together
- keep pending registry custody one-for-one, non-administrative, and releasable only through the recorded destination call or deterministic source-project refund

## Canonical checks

- bounded recursive cash-out behavior:
  `test/regression/CashOutLoopLimit.t.sol`
- preview versus execution terminal alignment:
  `test/regression/PreviewPrimaryTerminalMismatch.t.sol`
- router-wide route and refund invariants:
  `test/invariant/RouterTerminalInvariant.t.sol`
- V3 callback authorization:
  `test/RouterTerminal.t.sol`
- cash-out terminal enumeration failures:
  `test/regression/CashOutFallbackPrefersRecursiveLoop.t.sol`
- final-hop ERC-20 receipt shortfalls:
  `test/regression/LossyReceiptRegression.t.sol`
- failed terminal-originated fee and project-payout forwards:
  `test/regression/RegistryForwardGasReserve.t.sol`

## Source map

- `src/JBRouterTerminal.sol`
- `src/JBRouterTerminalRegistry.sol`
- `src/JBPayRouteResolver.sol`
- `test/regression/CashOutLoopLimit.t.sol`
- `test/regression/PreviewPrimaryTerminalMismatch.t.sol`
- `test/invariant/RouterTerminalInvariant.t.sol`
