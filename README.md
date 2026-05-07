# Juicebox Router Terminal

`@bananapus/router-terminal-v6` is a routing terminal for Juicebox V6. It accepts value in many input tokens, discovers what token the destination project actually accepts, and forwards the payment through the best route it can resolve from the configured candidates.

Docs: <https://docs.juicebox.money>  
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)  
User journeys: [USER_JOURNEYS.md](./USER_JOURNEYS.md)  
Skills: [SKILLS.md](./SKILLS.md)  
Risks: [RISKS.md](./RISKS.md)  
Administration: [ADMINISTRATION.md](./ADMINISTRATION.md)  
Review instructions: [REVIEW_GUIDE.md](./REVIEW_GUIDE.md)

## Overview

The router terminal is a convenience and integration surface, not the source of truth for project accounting. Its job is to get value into the correct downstream terminal.

It can route through:

- direct forwarding when the destination already accepts the input token
- wrapping or unwrapping native ETH and WETH
- Uniswap V3 or V4 swaps
- recursive Juicebox token cash outs when the input is itself a project token

Projects can use the registry to choose, and optionally lock, a project-specific router terminal or fall back to the registry's default terminal.

Use this repo when UX requires "pay with many tokens, settle into the right one." Do not use it as a replacement for downstream terminal accounting or as an authoritative decimal source.

This repo is best understood as an execution router attached to Juicebox, not as a new accounting model.

## Key Contracts

| Contract | Role |
| --- | --- |
| `JBRouterTerminal` | Main routing terminal that accepts many token types and forwards value to the destination terminal. |
| `JBRouterTerminalRegistry` | Registry and proxy surface that lets a project choose and optionally lock its preferred router terminal. |
| `JBPayRouteResolver` | Helper that evaluates pay-route candidates and selects the strongest route preview the router can resolve. |

## Mental Model

There are three separate decisions on the payment path:

1. what token the destination project actually wants
2. whether the input token can become that token directly, through a swap, or through a Juicebox cash-out path first
3. which downstream terminal should receive the final asset

The router answers those questions, then hands off to the canonical terminal. It should not be treated as the system of record after that handoff.

The shortest useful reading order is:

1. `JBRouterTerminal`
2. `JBRouterTerminalRegistry`
3. the downstream terminal selected through `JBDirectory`

## Read These Files First

1. `src/JBRouterTerminal.sol`
2. `src/JBRouterTerminalRegistry.sol`
3. `src/libraries/JBSwapLib.sol`
4. the downstream terminal implementation in `nana-core-v6`

## Integration Traps

- projects that expose a router terminal still settle into ordinary Juicebox terminals underneath
- route discovery and route execution are related but not identical, especially when liquidity or caller-supplied quote data moves
- using JB project tokens as router input creates recursive path complexity that frontends and integrators should model explicitly
- the registry changes which router a project uses, but not what downstream terminal ultimately settles the payment

## Where State Lives

- route-selection logic: `JBRouterTerminal`
- per-project router choice and lock status: `JBRouterTerminalRegistry`
- accepted-token accounting and final balance changes: the downstream terminal, usually in `nana-core-v6`

That separation is why a successful route can still end in downstream terminal behavior you did not expect.

## High-Signal Tests

1. `test/RouterTerminal.t.sol`
2. `test/RouterTerminalPreviewFork.t.sol`
3. `test/RouterTerminalCashOutFork.t.sol`
4. `test/regression/PreviewPrimaryTerminalMismatch.t.sol`
5. `test/regression/CashOutCircularPrimaryTerminal.t.sol`

## Install

```bash
npm install @bananapus/router-terminal-v6
```

## Development

```bash
npm install
forge build --deny notes
forge test --deny notes
```

Useful scripts:

- `npm run deploy:mainnets`
- `npm run deploy:testnets`

## Deployment Notes

This package depends on core, address-registry, and permission-ID packages plus Uniswap V3, V4, and Permit2 integrations. It is meant to sit in front of canonical Juicebox terminals, not replace them.

## Repository Layout

```text
src/
  JBRouterTerminal.sol
  JBRouterTerminalRegistry.sol
  interfaces/
  libraries/
  structs/
test/
  unit, fork, registry, review, invariant, and regression coverage
script/
  Deploy.s.sol
  helpers/
```

## Risks And Notes

- the router synthesizes accounting context for discovery and should not be treated as an accounting-truth surface
- swap previews are best-effort estimates and depend on current pool state plus caller-supplied quote data
- recursive cash-out routing increases complexity when the input token is itself a Juicebox project token
- slippage and sandwich resistance depend on the quality of the chosen quote path
- final terminal-facing ERC-20 hops must be standard tokens; lossy terminal pulls are rejected

The most common reader mistake here is to stop at the router and forget to inspect the terminal that actually receives the value.

## For AI Agents

- Do not claim the router is the accounting source of truth after forwarding.
- Read the preview, recursive cash-out, and registry tests before summarizing path selection behavior.
- If the route ends in surprising accounting, move to the downstream terminal in `nana-core-v6`.
