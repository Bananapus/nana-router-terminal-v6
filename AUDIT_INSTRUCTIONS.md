# Audit Instructions

This repo accepts one token and routes value into whatever token a destination project actually accepts. Audit it as a stateless router whose mistakes show up as lost value, bad slippage control, or wrong-route accounting.

## Objective

Find issues that:
- route user funds through an incorrect pool or protocol path
- under-deliver relative to quoted or minimum-return semantics
- refund leftovers to the wrong party or trap them in the router
- misuse Permit2, router registry, or callback settlement
- let a project or operator force routing behavior the user did not authorize

## Scope

In scope:
- `src/JBRouterTerminal.sol`
- `src/JBRouterTerminalRegistry.sol`
- `src/interfaces/`
- `src/libraries/JBSwapLib.sol`
- `src/structs/`
- deployment scripts in `script/`

Key dependencies:
- `nana-core-v6`
- Uniswap V3 and V4 integration surfaces

## System Model

The router terminal:
- discovers what token a project’s terminal accepts
- decides whether to route via wrap/unwrap, V3, V4, Juicebox token cash-out, or a combination
- forwards value into the destination terminal
- optionally handles Permit2-funded transfers

The registry chooses which router terminal instance a project uses and whether that choice is locked.

## Critical Invariants

1. User intent is preserved
The actual destination project, beneficiary, minimum output semantics, and refund recipient must match the request and metadata.

2. No leftover value disappears
Partial fills, failed paths, and overfunded inputs must either be forwarded or refunded to the intended party.

3. Pool discovery and settlement agree
The quoted path, callback settlement, and final forwarded amount must all describe the same trade.

4. Registry controls stay narrow
Default terminals, allowed terminals, and lock semantics must not let an unexpected router instance take over project routing.

## Threat Model

Prioritize:
- V3 or V4 callback reentrancy
- sandwiching around discovered pool liquidity
- beneficiary versus payer refund mismatches
- Permit2 allowance or deadline misuse
- races around registry terminal locking

## Hotspots

- payment entrypoints and refund logic
- V3 callback verification
- V4 unlock callback and swap settlement
- pool discovery and best-path selection
- registry allowlist and lock behavior

## Build And Verification

Standard workflow:
- `npm install`
- `forge build`
- `forge test`

Current tests focus on:
- refund edge cases
- payer tracking
- Permit2 failure handling
- cash-out-assisted routes
- reentrancy and sandwich-sensitive fork cases

Strong findings in this repo usually show the router holding onto value or satisfying user slippage checks with the wrong sign, recipient, or output token.
