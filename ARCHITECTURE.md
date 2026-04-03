# Architecture

## Purpose

`nana-router-terminal-v6` lets a payer fund a Juicebox project with a token the project does not directly accept. It discovers the destination token, unwraps or wraps native assets when needed, optionally cashes out upstream JB project tokens, and swaps through the deepest available Uniswap V3 or V4 route before forwarding the final asset to the destination terminal.
The router is intentionally heuristic: it does not exhaustively search every viable pool for the absolute best execution price.

## Boundaries

- The router is a terminal-shaped payment adapter, not a canonical accounting terminal.
- It owns routing, swapping, quoting, and refund behavior.
- Final accounting still occurs at the destination terminal that actually accepts the routed token.
- Pool selection is optimized for simple, bounded route discovery, not full best-execution search across all candidate pools.

## Main Components

| Component | Responsibility |
| --- | --- |
| `JBRouterTerminal` | Source-token intake, route discovery, swapping, and forwarding |
| `JBRouterTerminalRegistry` | Project-level selection and locking of router terminal instances |
| `JBSwapLib` | Pool discovery, quoting, and slippage helpers |
| `PoolInfo` and interfaces | Typed routing metadata and registry/payer integration surfaces |

## Runtime Model

```text
router pay call
  -> accept native, ERC-20, or JB-token-like input
  -> if input is a project token, recursively cash it out first
  -> resolve the destination token the project can actually receive
  -> pick the best direct, wrap/unwrap, or swap route
  -> execute the route and forward the result to the destination terminal
  -> return any leftover input to the original payer when possible
```

## Critical Invariants

- The router's own accounting context is synthetic. Consumers should not treat it as the source of truth for project accounting.
- Pool discovery and quote logic must stay aligned between preview and execution paths.
- Refund resolution is part of correctness, not ergonomics. Partial fills without correct refunds create value leaks.
- Registry locking is a security feature; it prevents projects from being silently switched to untrusted router implementations.
- Final forwarded ERC-20 hops are only supported for standard tokens whose destination-terminal pull transfers the full nominal amount without transfer fees or burns.

## Where Complexity Lives

- The router composes multiple route families: direct, wrap/unwrap, recursive JB cash-out, and DEX swaps.
- Native-asset handling and refund handling are the most failure-prone parts of the implementation.
- Liquidity discovery across V3 and V4 is simple to describe but easy to desynchronize between preview and live execution.
- “Best route” in this system means the best route under the router's discovery heuristic, not a guarantee of globally optimal output across every live pool.
- Fee-on-transfer or otherwise lossy ERC-20s are only tolerated on ingress where the router can reconcile the received balance delta. They are rejected on the final terminal-facing hop.

## Dependencies

- `nana-core-v6` terminal and directory surfaces
- Uniswap V3, Uniswap V4, and Permit2
- Optional `IJBPayerTracker` intermediaries for refund attribution

## Safe Change Guide

- Keep route selection and execution semantics paired. If preview and execution diverge, frontends will misprice user flows.
- Be cautious with native-token handling; wrap and unwrap edge cases are where routers usually leak value.
- If you change recursive cash-out behavior, inspect the hop limit and failure modes together.
- Do not promote the router into a stateful treasury layer.
- Treat any new convenience path as a new asset-conservation proof obligation.
