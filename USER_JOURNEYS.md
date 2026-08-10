# User Journeys

## Repo purpose

This repo is the project-facing payment router for "user has X, project wants Y." It owns route discovery, preview behavior, registry-level router choice, and special handling for project-token sources (recursive cash-out). It does not replace the downstream terminal that finally receives and accounts for value. Note: unclaimed Juicebox credits are not a supported input — credit holders must `JBTokens.claimFor` to an ERC-20 first and then route as a normal ERC-20 payment.

## Primary actors

- projects that want broad input-token UX while preserving canonical terminal settlement
- frontends and aggregators previewing payment routes
- operators choosing and locking a router per project
- auditors reviewing route discovery, refund behavior, and downstream terminal interactions

## Key surfaces

- `JBRouterTerminal`: route discovery and execution
- `JBRouterTerminalGateway`: failed-route custody, retry qualification, and autonomous refund
- `JBRouterTerminalRegistry`: router selection, locking, and stateless forwarding
- `JBPayRouteResolver`: preview and route-resolution helper logic

## Journey 1: Put a router in front of a project's canonical terminal

**Actor:** project operator.

**Intent:** broaden input-token UX without changing the project's downstream terminal accounting model.

**Preconditions**
- the project already has a canonical terminal
- the team wants a router in front of that terminal rather than a new accounting surface

**Main Flow**
1. Deploy or select a `JBRouterTerminal` route executor and its immutable `JBRouterTerminalGateway`.
2. Register the Gateway for the project in `JBRouterTerminalRegistry`, or rely on the initial Gateway default if appropriate.
3. Optionally lock the registry choice so later callers cannot redirect the project to a different router.
4. Frontends can route users to a known router without changing downstream accounting contracts.

**Failure Modes**
- teams configure a router but do not update the registry entry the frontend actually reads
- operators leave the router mutable longer than intended and downstream integrations assume it is fixed

**Postconditions**
- the project has a router terminal configured in the registry and users can rely on it as the approved entrypoint

## Journey 2: Pay with whatever token the user already has

**Actor:** payer.

**Intent:** route a payment from the user's existing asset into the project's accepted terminal asset.

**Preconditions**
- the user wants exposure to a project but does not hold the exact token the destination terminal accepts

**Main Flow**
1. The payer calls `pay(...)` through the Registry-selected Gateway with the input token and destination project.
2. The Gateway takes custody and calls the immutable Router atomically.
3. The Router discovers the destination terminal and accepted token.
4. It decides whether the path is direct forwarding, wrap or unwrap, UniV3 swap, or UniV4 swap.
5. It settles into the downstream terminal and passes along the payment metadata that the project actually expects.

**Failure Modes**
- quotes are stale or liquidity moved before execution
- permit, allowance, or refund handling breaks mid-route
- metadata is valid for the destination terminal but not for route-discovery assumptions
- a failed ordinary user route reverts synchronously instead of becoming pending custody

**Postconditions**
- the router converts the user's asset into the terminal's accepted asset and forwards the payment

## Journey 3: Pay with a Juicebox project token

**Actor:** payer holding a project token.

**Intent:** use project-token value as the source leg for a routed payment.

**Preconditions**
- the user holds a Juicebox project token rather than a plain external asset

**Main Flow**
1. The router recognizes that the input token is itself a Juicebox project token.
2. It may cash out that token through its own terminal path before continuing toward the destination project's accepted asset.
3. The final asset is then forwarded into the destination terminal as a normal payment.

**Failure Modes**
- the reclaim leg behaves differently from a normal swap and the user or frontend misprices it
- cross-project routing assumptions are wrong for the chosen token source

**Postconditions**
- the router handles the recursive path correctly instead of assuming the input is a normal ERC-20

## Journey 4: Preview routes and protect the user against bad settlement

**Actor:** frontend or aggregator.

**Intent:** preview the route and protect users against materially worse execution.

**Preconditions**
- a frontend or integration needs to show likely output before execution

**Main Flow**
1. Call the router's preview or quote path before execution.
2. Surface expected destination amount, input requirements, and route shape to the user.
3. On execution, enforce the relevant minimums and refund rules so the user is not silently settled on a materially worse path.

**Failure Modes**
- preview assumptions become stale between quote and execution
- the frontend presents a route as deterministic when the final path still depends on live market state

**Postconditions**
- the quote is useful, and execution either lands close to it or fails clearly when conditions changed too much

## Journey 5: Lock down which router a project uses

**Actor:** authorized operator.

**Intent:** make the chosen router durable instead of leaving later redirection open.

**Preconditions**
- the project has chosen a router and wants to prevent later redirection

**Main Flow**
1. An authorized actor sets the project-specific router in the registry.
2. The actor locks the configuration once operational confidence is high.
3. Integrations can treat the registry entry as durable infrastructure rather than mutable routing advice.

**Failure Modes**
- operators lock the wrong router and make recovery harder
- teams assume a registry entry is locked when it is merely set

**Postconditions**
- the registry records the chosen router terminal and locks the decision

## Journey 6: Retry or autonomously refund a failed fee or project payout

**Actor:** any keeper, frontend, or interested account.

**Intent:** settle a failed terminal-originated route without forgiving a fee or nullifying a project payout.

**Preconditions**
- the Gateway emitted `JBRouterTerminalGateway_QueuePendingCall`
- the caller can reproduce the original memo and metadata from transaction calldata

**Main Flow**
1. Anyone calls `processPendingCall` with the pending ID and original data.
2. A successful attempt settles immediately. A failed attempt records its selector-level class without encoded arguments.
3. Wait at least one day between qualified failures.
4. If the selector changes, the count resets to one and retries continue; changed arguments for the same selector do not reset.
5. After three matching failures and one more day, anyone calls `finalizePendingCall`.
6. Complete-budget gas exhaustion automatically raises the required budget from 5M to 10M to 15M, with 20M required for the final attempt.
7. The final attempt settles if possible, resets on a changed class, or atomically refunds the fixed source project after the same class.

**Failure Modes**
- underfunded retries revert without advancing qualification
- changed memo or metadata does not match the retained call
- a source terminal rejects the refund, reverting finalization and preserving pending custody

**Postconditions**
- the original input is either settled, still represented by pending state, or credited back to its predetermined source project through a currently registered accounting terminal

## Trust boundaries

- this repo is trusted for route discovery and forwarding decisions, not final accounting truth
- downstream terminals remain the source of actual settlement semantics and balances
- quote quality depends on the swap and oracle surfaces the chosen route relies on

## Hand-offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for the downstream terminal and accounting model the router settles into.
- Use [univ4-router-v6](../univ4-router-v6/USER_JOURNEYS.md) when the question is about the UniV4 hook-level swap primitive rather than project-facing routing.
