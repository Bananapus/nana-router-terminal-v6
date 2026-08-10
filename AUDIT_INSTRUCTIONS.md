# Audit Instructions

This repo accepts one token and routes value into whatever token a destination project actually accepts. Audit the main router as stateless and the registry as a forwarding proxy which can retain failed authenticated terminal-originated transfers. Mistakes show up as lost value, under-backed pending custody, bad slippage control, or wrong-route accounting.

## Audit objective

There is a billion dollars of well-meaning projects' money in the Juicebox Money Engine, growing exponentially. Your job is to hack it before anyone else. Whoever hacks it first saves/steals the money, and you are obsessed with being this winner, while also being a steward of the protocol and wanting it to keep growing safely.

Suggestions of where to look:

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

## Start here

1. `src/JBRouterTerminal.sol`
2. `src/JBRouterTerminalRegistry.sol`
3. `src/libraries/JBSwapLib.sol`

## Security model

The router terminal:

- discovers what token a project's terminal accepts
- decides whether to route via wrap/unwrap, V3, V4, Juicebox token cash-out, or a combination
- forwards value into the destination terminal
- optionally handles Permit2-funded transfers

The registry chooses which router terminal instance a project uses and whether that choice is locked. It also
authenticates core terminal project transfers and retains failed downstream calls for permissionless retry.

## Roles and privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| User or relayer | Initiate routed payment with beneficiary and slippage intent | Must receive exact refund semantics requested |
| Registry controller | Set default or allowed router terminals | Must not redirect projects unexpectedly |
| Router terminal | Hold funds only transiently during routing | Must not retain leftovers across flows |
| Registry | Retain failed authenticated terminal forwards | Pending amounts must stay fully backed and have no administrative withdrawal path |

## Integration assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| `nana-core-v6` | Terminal discovery and pay semantics are accurate | Routed value lands in the wrong place |
| Uniswap V3 and V4 | Callback settlement and pool discovery are authentic | Slippage and final forwarded amount diverge |
| Permit2 | Allowances and deadlines reflect user intent | Unauthorized transfer or stuck routing behavior |

## Critical invariants

1. User intent is preserved.  
   The actual destination project, beneficiary, minimum output semantics, and refund recipient must match the request and metadata.
2. No leftover value disappears.  
   Partial fills, failed paths, and overfunded inputs must either be forwarded or refunded to the intended party.
3. Pool discovery and settlement agree.  
   The quoted path, callback settlement, and final forwarded amount must all describe the same trade.
4. Registry controls stay narrow.  
   Default terminals, allowed terminals, and lock semantics must not let an unexpected router instance take over project routing.
5. Pending terminal calls remain fully backed.
   Only authenticated core terminal call shapes may be queued; success, aggregation, qualified retry, finalization, and source-project refund must conserve exact custody without reaching the source terminal's catch accounting.
6. Autonomous refunds require consistent failure evidence.
   Underfunded attempts do not count. Three failures in distinct daily windows and the final attempt must match the exact revert-data and route fingerprints; changed errors, routes, code hashes, operations, or aggregated amounts restart qualification.

## Attack surfaces

- payment entrypoints and refund logic
- V3 callback verification
- V4 unlock callback and swap settlement
- pool discovery and best-path selection
- registry allowlist and lock behavior
- source-terminal authentication, fixed retry gas, pending-call aggregation, matching-failure qualification, and autonomous refund

## Verification

- `npm install`
- `forge build --deny notes`
- `forge test --deny notes`
