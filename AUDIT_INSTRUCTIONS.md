# Audit Instructions

This repo accepts one token and routes value into whatever token a destination project actually accepts. Audit the Router as a stateless executor and the Gateway as a narrowly stateful failed-call escrow whose mistakes show up as lost value, bad slippage control, wrong-route accounting, or unauthorized refunds.

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
- `src/JBRouterTerminalGateway.sol`
- `src/JBRouterTerminalRegistry.sol`
- `src/interfaces/`
- `src/libraries/JBSwapLib.sol`
- `src/structs/`
- deployment scripts in `script/`

Key dependencies:

- `nana-core-v6`
- Uniswap V3 and V4 integration surfaces

## Start here

1. `src/JBRouterTerminalGateway.sol`
2. `src/JBRouterTerminal.sol`
3. `src/JBRouterTerminalRegistry.sol`
4. `src/libraries/JBSwapLib.sol`

## Security model

The router terminal:

- discovers what token a project's terminal accepts
- decides whether to route via wrap/unwrap, V3, V4, Juicebox token cash-out, or a combination
- forwards value into the destination terminal
- optionally handles Permit2-funded transfers

The registry chooses which router terminal instance a project uses and whether that choice is locked.

The gateway selected by the registry takes custody before calling the immutable Router. Only failed calls from a verified source-project terminal become permissionlessly retryable; ordinary caller failures remain synchronous. Refunds require a time-separated matching-selector streak and one final matching failure.

## Roles and privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| User or relayer | Initiate routed payment with beneficiary and slippage intent | Must receive exact refund semantics requested |
| Registry controller | Set default or allowed router terminals | Must not redirect projects unexpectedly |
| Router terminal | Hold funds only transiently during routing | Must not retain leftovers across flows |
| Router gateway | Retain only original inputs represented by pending records | Immutable retry policy and refund destination |

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
5. Pending custody is conserved.
   Each pending amount remains in the gateway's original input token until the exact call settles or an atomic refund credits its fixed recipient.
6. Error changes block finalization.
   Qualification advances only for the same error selector; encoded arguments are ignored and any changed retry or final selector resets the streak.

## Attack surfaces

- payment entrypoints and refund logic
- V3 callback verification
- V4 unlock callback and swap settlement
- pool discovery and best-path selection
- registry allowlist and lock behavior
- gateway gas reservation, selector-bounded return-data handling, retry timing, reentrancy, nested allowances, and refund rollback

## Verification

- `npm install`
- `forge build --deny notes`
- `forge test --deny notes`
- `forge test --match-path test/regression/RouterTerminalGatewayFailure.t.sol`
