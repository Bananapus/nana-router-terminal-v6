# Juicebox Router Terminal

## Use This File For

- Use this file when the task involves routed payments or cash-outs, swap-path metadata, dynamic accepted-token discovery, route-registry selection, or router-terminal fee and slippage behavior.
- Start here, then open the terminal, registry, swap helpers, or tests that own the exact behavior in question.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and routing model | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Terminal execution path | [`src/JBRouterTerminal.sol`](./src/JBRouterTerminal.sol) |
| Registry behavior and terminal selection | [`src/JBRouterTerminalRegistry.sol`](./src/JBRouterTerminalRegistry.sol) |
| Shared libraries, interfaces, and metadata structs | [`src/libraries/`](./src/libraries/), [`src/interfaces/`](./src/interfaces/), [`src/structs/`](./src/structs/) |
| Forked routing behavior, preview parity, and regressions | [`test/RouterTerminalPreviewFork.t.sol`](./test/RouterTerminalPreviewFork.t.sol), [`test/RouterTerminalCashOutFork.t.sol`](./test/RouterTerminalCashOutFork.t.sol), [`test/RouterTerminalReentrancy.t.sol`](./test/RouterTerminalReentrancy.t.sol), [`test/regression/`](./test/regression/) |

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
- Treat preview behavior, quote selection, and execution callbacks as tightly coupled. Changes in one usually need verification in the others.
- When the input token is itself a Juicebox project token, follow the cash-out loop carefully. Recursive routing assumptions are where subtle bugs hide.
- If you touch registry behavior, verify project-specific overrides, allowlisting, and terminal locking all still match the intended governance model.
