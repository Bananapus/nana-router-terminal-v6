# Architecture

## Purpose

`nana-router-terminal-v6` lets a payer fund a Juicebox project with a token the project does not directly accept. It discovers the destination token, wraps or unwraps native assets when needed, can recursively cash out upstream JB project tokens, and swaps through bounded Uniswap V3 or V4 routes before forwarding value to the destination terminal.

The router is intentionally heuristic. It does not search every possible route for a globally optimal price.

## System overview

`JBRouterTerminal` is a terminal-shaped route executor, not an accounting source of truth. `JBRouterTerminalGateway` is the fail-closed implementation selected by `JBRouterTerminalRegistry`: it owns the outer atomic boundary around a Router call and retains failed input only when source-project metadata and the resolved payer's self-asserted terminal shape qualify the call for project refund. The registry remains a stable project-facing proxy and is unchanged by this mechanism. `JBPayRouteResolver` expands preview candidates without forcing the main router contract to carry all preview complexity inline.

Final accounting still happens in the downstream terminal selected through `nana-core-v6`.

## Core invariants

- the router's own accounting context is synthetic and must not be treated as the project ledger
- preview route discovery and live execution must stay aligned
- buyback-hook preview scoring must distinguish executable floors from diagnostics
- refund behavior is part of correctness, not only UX
- a failed gateway attempt rolls back every swap and downstream call before the original input is retained
- qualified failure streaks advance on identical error selectors; encoded arguments are ignored and a changed selector resets the streak
- callback-capable ERC-20 inputs cannot nest another intake inside the gateway's balance-delta measurement
- registry locking prevents silent migration to untrusted router implementations
- `addToBalanceOf` final hops reject ERC-20 receipt shortfalls; `pay` cannot rely on terminal balance deltas because pay hooks can consume tokens during settlement
- recursive project-token cashout routing is intentionally bounded
- caller reclaim minima only apply to the first cashout hop, because later hops may change token units
- circular `router -> registry -> same router` forwarding remains blocked in the registry

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBRouterTerminal` | Intake, route discovery, swap execution, forwarding, and refunds | Main runtime surface |
| `JBRouterTerminalGateway` | Atomic Router boundary, failed-input escrow, permissionless retries, and autonomous refunds | Registry-selected safety surface |
| `JBRouterTerminalRegistry` | Project-level router selection, locking, and proxy forwarding to the resolved router terminal | Governance, safety, and proxy surface |
| `JBPayRouteResolver` | Preview candidate evaluation | Helper to keep runtime size bounded |
| `JBSwapLib` and routing structs | Pool discovery, quoting, and route metadata | Shared routing logic |

## Trust boundaries

- final accounting remains in the downstream terminal selected through `JBDirectory`
- the router trusts Uniswap V3, Uniswap V4, Permit2, and optional payer trackers for routing-side behavior
- fee-on-transfer tokens are reconciled on ingress but remain unsafe for routed payments because terminal-side loss is not enforced on `pay`
- the registry is trusted to resolve and forward into the intended router implementation for a project
- the gateway's immutable `ROUTER` is trusted as the route executor; it cannot be changed after deployment

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

### Gateway failure lifecycle

```text
registry forwards original input to gateway
  -> gateway calls immutable router inside one fallible external-call boundary
  -> success: route settles synchronously
  -> ordinary caller failure: the call reverts synchronously
  -> shape-qualified project-refund failure: every inner transfer/swap rolls back and gateway retains the original input token
  -> anyone may retry with the original memo and metadata and at least the qualified gas budget
  -> matching error selectors: advance at most once per day, regardless of encoded arguments
  -> changed selector: reset the streak to one and keep retrying
  -> after three matches and one more day: one final qualified attempt
       -> success: settle
       -> changed selector: reset and retain
       -> same selector: atomically refund the source project's terminal
```

## Accounting model

The Router and Registry do not own project balances. The Gateway can persistently escrow only the original inputs of shape-qualified failed calls. Those tokens are liabilities represented one-for-one by `pendingCallOf(id)` until successful settlement or atomic source-project refund; they are never reported as project surplus by the gateway. Shape qualification is not authentication: the resolved payer merely self-asserts `IJBTerminal` support through ERC-165.

Preview and execution share the same conceptual route shape: optional recursive cashout first, then destination-token resolution, then final conversion and forwarding.

## Security model

- native-asset handling and refunds are the most failure-prone paths
- V3 and V4 discovery must stay synchronized between preview and live execution
- V3 callbacks are valid only during the router-initiated pool swap that set the transient expected pool
- V4 discovery intentionally considers both vanilla pools and pools using the canonical `UNIV4_HOOK`
- the router's "best route" claim is only as strong as its bounded discovery set and external-terminal safety checks
- recursive cashout behavior, preferred-token handling, and one-shot source overrides are tightly coupled
- a refund to a source project deletes pending state before interaction and relies on transaction rollback to restore state and custody if the source terminal rejects it
- the gateway closes only its inbound balance-delta window against reentrancy and restores nested Router allowances so legitimate downstream forwarding hooks remain composable
- retry and final attempts forward at least `QUALIFIED_CALL_GAS`; matching gas exhaustion escalates the required budget from 5M through 20M, while entrypoint attempts dynamically reserve `_FAILURE_GAS_RESERVE` for durable queueing

## Safe change guide

- keep route discovery and route execution semantics paired
- be conservative with native wrapping, unwrapping, and refund behavior
- if recursive cash-out logic changes, review hop limits and failure handling together
- if metadata semantics change, re-check first-hop reclaim minima, one-shot source overrides, and preferred-token routing together
- do not turn the router into a persistent treasury layer
- preserve the gateway's outer custody boundary; do not catch failures after the Router has performed irreversible work in the gateway's frame
- keep `JBRouterTerminalRegistry` source, ABI, and storage independent from gateway retry policy

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
- exact Base fee-failure replay, matching-error qualification, and refunds:
  `test/regression/RouterTerminalGatewayFailure.t.sol`

## Source map

- `src/JBRouterTerminal.sol`
- `src/JBRouterTerminalGateway.sol`
- `src/JBRouterTerminalRegistry.sol`
- `src/JBPayRouteResolver.sol`
- `test/regression/CashOutLoopLimit.t.sol`
- `test/regression/PreviewPrimaryTerminalMismatch.t.sol`
- `test/invariant/RouterTerminalInvariant.t.sol`
