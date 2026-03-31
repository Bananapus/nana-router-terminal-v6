# Juicebox Router Terminal

`@bananapus/router-terminal-v6` is a routing terminal for Juicebox V6. It accepts value in many input tokens, discovers what token the destination project actually accepts, and forwards the payment through the best available route.

Docs: <https://docs.juicebox.money>
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)

## Overview

The router terminal is a convenience and integration surface, not the source of truth for project accounting. Its job is to get value into the correct downstream terminal.

It can route through:

- direct forwarding when the destination already accepts the input token
- wrapping or unwrapping native ETH and WETH
- Uniswap V3 or V4 swaps
- recursive Juicebox token cash outs when the input itself is a project token

Projects can use the registry contract to choose a project-specific router terminal or fall back to a default.

Use this repo when UX requires "pay with many tokens, settle into the right one." Do not use it as a replacement for downstream terminal accounting or as an authoritative decimal source.

This repo is best understood as an execution router attached to Juicebox, not as a new accounting model.

## Key Contracts

| Contract | Role |
| --- | --- |
| `JBRouterTerminal` | Main routing terminal that accepts many token types and forwards value to the destination terminal. |
| `JBRouterTerminalRegistry` | Registry and proxy surface that lets a project choose and optionally lock its preferred router terminal. |

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

- projects that expose a router terminal still settle into ordinary Juicebox terminals underneath; downstream semantics still matter
- route discovery and route execution are related but not identical, especially when liquidity or metadata-supplied quotes move
- using JB project tokens as router input creates recursive path complexity that frontends and integrators should model explicitly
- the registry layer changes who a project routes through, but not what the downstream terminal ultimately is

## Where State Lives

- route-selection logic lives in `JBRouterTerminal`
- per-project router choice and lock status live in `JBRouterTerminalRegistry`
- accepted-token accounting and final balance changes live in the downstream terminal, usually in `nana-core-v6`

That separation is the reason a successful route can still end in a downstream terminal behavior you did not expect.

## Install

```bash
npm install @bananapus/router-terminal-v6
```

## Development

```bash
npm install
forge build
forge test
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
  unit, fork, registry, audit, invariant, and regression coverage
script/
  Deploy.s.sol
  helpers/
```

## Risks And Notes

- the router synthesizes accounting context for discovery and should not be treated as an accounting-truth surface
- swap previews are best-effort estimates and depend on current pool state plus caller-supplied quote data
- recursive cash-out routing increases complexity when the input token is itself a Juicebox project token
- slippage and sandwich resistance depend on the quality of the quote path chosen for the route

The most common reader mistake here is to stop at the router and forget to inspect the terminal that actually receives the value.
