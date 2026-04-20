# Architecture

## Purpose

`nana-router-terminal-v6` lets a payer fund a Juicebox project with a token the project does not directly accept. It discovers the destination token, wraps or unwraps native assets when needed, can recursively cash out upstream JB project tokens, and swaps through bounded Uniswap V3 or V4 routes before forwarding value to the destination terminal.

The router is intentionally heuristic. It does not search every possible route for a globally optimal price.

## System Overview

`JBRouterTerminal` is a terminal-shaped adapter, not an accounting source of truth. `JBRouterTerminalRegistry` is both a registry and a stable project-facing proxy surface: projects can point at the registry while the registry resolves, and can later lock, the actual router terminal implementation to use. `JBPayRouteResolver` expands preview candidates without forcing the main router contract to carry all preview complexity inline.

Final accounting still happens in the downstream terminal selected through `nana-core-v6`.

## Core Invariants

- the router's own accounting context is synthetic and must not be treated as the project ledger
- preview route discovery and live execution must stay aligned
- refund behavior is part of correctness, not just UX
- registry locking prevents silent migration to untrusted router implementations
- final terminal-facing ERC-20 hops only support standard, non-lossy transfers
- recursive project-token cashout routing is intentionally bounded
- caller reclaim minima only apply to the first cashout hop, because later hops may change token units
- circular `router -> registry -> same router` forwarding remains blocked in the registry

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBRouterTerminal` | Intake, route discovery, swap execution, forwarding, and refunds | Main runtime surface |
| `JBRouterTerminalRegistry` | Project-level router selection, locking, and proxy forwarding to the resolved router terminal | Governance, safety, and proxy surface |
| `JBPayRouteResolver` | Preview candidate evaluation | Helper to keep runtime size bounded |
| `JBSwapLib` and routing structs | Pool discovery, quoting, and route metadata | Shared routing logic |

## Trust Boundaries

- final accounting remains in the downstream terminal selected through `JBDirectory`
- the router trusts Uniswap V3, Uniswap V4, Permit2, and optional payer trackers for routing-side behavior
- fee-on-transfer tokens are only tolerated on ingress where received-balance deltas can be reconciled
- the registry is trusted to resolve and forward into the intended router implementation for a project

## Critical Flows

### Route And Pay

```text
router pay call
  -> accept native, ERC-20, or JB-token-like input
  -> if input is a project token, recursively cash it out first
  -> resolve the destination token the project terminal actually accepts
  -> choose the best direct, wrap/unwrap, or swap path under the router's bounded candidate-discovery heuristic
  -> execute the route and forward the result to the downstream terminal
  -> refund leftover input when possible
```

## Accounting Model

The router does not own project balances. It owns transient route accounting: input reconciliation, swap execution, forwarded amount, and refund resolution.

Preview and execution share the same conceptual route shape: optional recursive cashout first, then destination-token resolution, then final conversion and forwarding.

## Security Model

- native-asset handling and refunds are the most failure-prone paths
- V3 and V4 discovery must stay synchronized between preview and live execution
- V4 discovery intentionally considers both vanilla pools and pools using the canonical `UNIV4_HOOK`
- the router's "best route" claim is only as strong as its bounded discovery set and external-terminal safety checks
- recursive cashout behavior, preferred-token handling, and one-shot source overrides are tightly coupled

## Safe Change Guide

- keep route discovery and route execution semantics paired
- be conservative with native wrapping, unwrapping, and refund behavior
- if recursive cash-out logic changes, review hop limits and failure handling together
- if metadata semantics change, re-check first-hop reclaim minima, one-shot source overrides, and preferred-token routing together
- do not turn the router into a persistent treasury layer

## Canonical Checks

- bounded recursive cash-out behavior:
  `test/regression/CashOutLoopLimit.t.sol`
- preview versus execution terminal alignment:
  `test/audit/PreviewPrimaryTerminalMismatch.t.sol`
- router-wide route and refund invariants:
  `test/invariant/RouterTerminalInvariant.t.sol`

## Source Map

- `src/JBRouterTerminal.sol`
- `src/JBRouterTerminalRegistry.sol`
- `src/JBPayRouteResolver.sol`
- `test/regression/CashOutLoopLimit.t.sol`
- `test/audit/PreviewPrimaryTerminalMismatch.t.sol`
- `test/invariant/RouterTerminalInvariant.t.sol`
