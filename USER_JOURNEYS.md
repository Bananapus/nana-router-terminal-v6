# User Journeys

## Who This Repo Serves

- projects that want "pay with many tokens, settle into the right terminal asset"
- frontends and aggregators previewing multi-hop or project-token-based payment routes
- operators choosing and locking a router terminal per project
- auditors reviewing swap-path, refund, and downstream-terminal interactions

## Journey 1: Put A Router In Front Of A Project's Canonical Terminal

**Starting state:** the project already has a canonical terminal but wants a broader input-token UX.

**Success:** the project has a router terminal configured in the registry and users can rely on it as the approved entrypoint.

**Flow**
1. Deploy or select a `JBRouterTerminal` instance.
2. Register it for the project in `JBRouterTerminalRegistry`, or rely on the default router if appropriate.
3. Optionally lock the registry choice so later callers cannot redirect the project to a different router.
4. Frontends can now route users to a known router without changing downstream accounting contracts.

## Journey 2: Pay With Whatever Token The User Already Has

**Starting state:** the user wants exposure to a project but does not hold the exact token the destination terminal accepts.

**Success:** the router converts the user's asset into the terminal's accepted asset and forwards the payment.

**Flow**
1. The payer calls `pay(...)` on `JBRouterTerminal` with the input token and destination project.
2. The router discovers the destination terminal and accepted token.
3. It decides whether the path is direct forwarding, wrap or unwrap, UniV3 swap, or UniV4 swap.
4. It settles into the downstream terminal and passes along the payment metadata that the project actually expects.

**Failure cases that matter:** stale quotes, insufficient liquidity, permit or allowance failures, leftover refund paths, and metadata that is valid for the terminal but not for the route discovery assumptions.

## Journey 3: Pay With A Juicebox Project Token Instead Of An External Asset

**Starting state:** the user holds a project token and wants to route its value into another project payment.

**Success:** the router handles the recursive path correctly instead of assuming the input is a normal ERC-20.

**Flow**
1. The router recognizes that the input token is itself a Juicebox project token.
2. It may cash out that token through its own terminal path before continuing toward the destination project's accepted asset.
3. The final asset is then forwarded into the destination terminal as a normal payment.

**Edge conditions that change user experience:** cash-out loop limits, cross-project routing assumptions, preview drift, and slippage when the first leg is a project-token reclaim rather than a swap.

## Journey 4: Route A Payment From Credits Or A Cash-Out Source

**Starting state:** the payer has Juicebox credits or a known source project position instead of an ordinary wallet token balance.

**Success:** the router can pull that source value, cash it out if needed, and continue routing toward the destination project.

**Flow**
1. Encode the `cashOutSource` or equivalent metadata the router expects.
2. Let the router pull credits or source-project value through the token and terminal surfaces it integrates with.
3. Continue through the route-discovery process only after the source value has been converted into something the destination path can use.

**Failure cases that matter:** sending `msg.value` alongside credit-based routing, wrong source-project metadata, and assuming credit cash-out behaves like direct ERC-20 routing.

## Journey 5: Preview Routes And Protect The User Against Bad Settlement

**Starting state:** a frontend or integration needs to show likely output before execution.

**Success:** the quote is useful, and execution either lands close to it or fails clearly when conditions changed too much.

**Flow**
1. Call the router's preview or quote path before execution.
2. Surface expected destination amount, input requirements, and route shape to the user.
3. On execution, enforce the relevant minimums and refund rules so the user is not silently settled on a materially worse path.

## Journey 6: Lock Down Which Router A Project Uses

**Starting state:** the project has chosen a router and wants to prevent later redirection.

**Success:** the registry records the chosen router terminal and locks the decision.

**Flow**
1. An authorized actor sets the project-specific router in the registry.
2. The actor locks the configuration once operational confidence is high.
3. Integrations can treat the registry entry as durable infrastructure rather than mutable routing advice.

## Journey 7: Migrate Registry-Held Balance Or Router Responsibility Safely

**Starting state:** the project is changing router expectations or needs to move balance from a registry-held context.

**Success:** the migration uses the repo's explicit migration path instead of leaving stranded value or stale routing assumptions behind.

**Flow**
1. Use the registry's migration surface when a project's router balance or canonical terminal relationship needs to change.
2. Verify the destination terminal and router assumptions before moving value.
3. Update frontends only after the registry state and balance migration agree.

## Hand-Offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for the downstream terminal and accounting model the router settles into.
- Use [univ4-router-v6](../univ4-router-v6/USER_JOURNEYS.md) when the question is about the UniV4 hook-level swap primitive rather than project-facing routing.
