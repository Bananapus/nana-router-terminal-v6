# Juicebox Router Terminal

## Use This File For

- Use this file when the task involves routed payments or cash-outs, swap-path metadata, dynamic accepted-token discovery, route-registry selection, or router-terminal fee and slippage behavior.
- Start here, then decide whether the problem is route discovery, swap execution, cash-out recursion, or registry selection. Those are distinct failure modes in this repo.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and routing model | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Terminal execution path | [`src/JBRouterTerminal.sol`](./src/JBRouterTerminal.sol) |
| Pay-route resolution helpers | [`src/JBPayRouteResolver.sol`](./src/JBPayRouteResolver.sol) |
| Registry behavior and terminal selection | [`src/JBRouterTerminalRegistry.sol`](./src/JBRouterTerminalRegistry.sol) |
| Shared libraries, interfaces, and metadata structs | [`src/libraries/`](./src/libraries/), [`src/interfaces/`](./src/interfaces/), [`src/structs/`](./src/structs/) |
| Preview, cash-out, and buyback composition | [`test/RouterTerminalPreviewFork.t.sol`](./test/RouterTerminalPreviewFork.t.sol), [`test/RouterTerminalCashOutFork.t.sol`](./test/RouterTerminalCashOutFork.t.sol), [`test/RouterTerminalBuybackHookFork.t.sol`](./test/RouterTerminalBuybackHookFork.t.sol), [`test/RouterTerminalFeeCashOutFork.t.sol`](./test/RouterTerminalFeeCashOutFork.t.sol) |
| Registry, multihop, and adversarial coverage | [`test/RouterTerminalRegistry.t.sol`](./test/RouterTerminalRegistry.t.sol), [`test/RouterTerminalMultihopFork.t.sol`](./test/RouterTerminalMultihopFork.t.sol), [`test/RouterTerminalReentrancy.t.sol`](./test/RouterTerminalReentrancy.t.sol), [`test/RouterTerminalSandwichFork.t.sol`](./test/RouterTerminalSandwichFork.t.sol), [`test/TestAuditGaps.sol`](./test/TestAuditGaps.sol) |

## Repo Map

| Area | Where to look |
|---|---|
| Main contracts | [`src/`](./src/) |
| Libraries, interfaces, and structs | [`src/libraries/`](./src/libraries/), [`src/interfaces/`](./src/interfaces/), [`src/structs/`](./src/structs/) |
| Scripts | [`script/`](./script/) |
| Tests | [`test/`](./test/) |

## Purpose

Universal routing terminal for Juicebox V6. This repo accepts many input tokens, discovers what token a destination project actually accepts, converts through the best available path, and forwards settlement to the canonical downstream terminal.

## Reference Files

- Open [`references/runtime.md`](./references/runtime.md) when you need the route-selection flow, cash-out loop behavior, callback and swap semantics, or the main invariants.
- Open [`references/operations.md`](./references/operations.md) when you need registry and permission behavior, metadata keys, test breadcrumbs, or the main failure modes that cause stale assumptions.

## Working Rules

- Start in [`src/JBRouterTerminal.sol`](./src/JBRouterTerminal.sol) for execution behavior, but verify downstream semantics in the destination terminal before treating the router as the source of truth.
- The router intentionally synthesizes accounting contexts instead of storing a static accepted-token list. If token acceptance looks wrong, verify discovery logic before touching registry state.
- Treat preview behavior, quote selection, and execution callbacks as tightly coupled. Changes in one usually need verification in the others.
- When the input token is itself a Juicebox project token, follow the cash-out loop carefully. Recursive routing assumptions are where subtle bugs hide.
- Multi-hop and buyback-assisted routes are first-class behavior here, not edge cases. Verify them explicitly when changing route selection.
- Refund handling is route-specific state, not cleanup garnish. Baseline snapshots and partial-fill leftovers are part of correctness.
- Final terminal-facing receipt enforcement is a real boundary. If a terminal pull or forwarding model is non-standard, prove receipt semantics still hold before weakening guards.
- Callback guards and final-hop receipt checks are security boundaries. Do not weaken them to accommodate non-standard token paths.
- If you touch registry behavior, verify project-specific overrides, allowlisting, and terminal locking all still match the intended governance model.
