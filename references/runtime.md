# Router Terminal Runtime

## Contract roles

- [`src/JBRouterTerminal.sol`](../src/JBRouterTerminal.sol) is the main execution surface. It accepts input tokens, discovers the output token, performs conversion, and forwards settlement to the downstream terminal.
- [`src/JBRouterTerminalGateway.sol`](../src/JBRouterTerminalGateway.sol) is the Registry-selected fail-closed surface. It takes custody before atomically calling the Router and retains original inputs only when exact raw source-project metadata opts in, the token is not the source project's own token, and a registered source terminal is paying the fee project.
- [`src/JBRouterTerminalRegistry.sol`](../src/JBRouterTerminalRegistry.sol) selects a per-project router terminal or falls back to the default one, while enforcing allowlist and lock rules.
- Helper logic in [`src/JBPayRouteResolver.sol`](../src/JBPayRouteResolver.sol) and the repo's interfaces/structs define how pay-route resolution and metadata-driven routing fit together.

## Runtime path

1. The Gateway accepts native tokens, ERC-20s, or claimed Juicebox project-token ERC-20s and calls the Router atomically.
2. If the input is a Juicebox project token, the Router may enter a cash-out loop first.
3. The Router resolves the desired output token using direct acceptance, wrap/unwrap equivalence, metadata overrides, or pool discovery.
4. It converts value through direct forwarding, wrap/unwrap, Uniswap V3, or Uniswap V4.
5. It forwards the final asset to the destination project's canonical terminal. A failed inner frame rolls back; opted-in calls retain the original input and ordinary calls revert synchronously. Retention is decided from `TOKENS.projectIdOf` and `DIRECTORY.isTerminalOf` before the attempt; the opt-in metadata is not authenticated.

## High-risk areas

- Preview and execution parity: changes to quote selection or route discovery should be checked against both preview and mutative paths.
- V4 discovery scope: the router searches both vanilla V4 pools and pools using the configured canonical `UNIV4_HOOK`.
- Cash-out loop behavior: recursive routing through project tokens can create subtle loop or slippage issues.
- Callback validation: V3 and V4 callback guards are security-critical and should not drift.
- Leftover/refund handling: refunds can route to the original payer or fallback recipient depending on context.
- Dynamic accounting contexts: this repo intentionally synthesizes accounting contexts instead of storing a static token list.
- Final terminal-facing ERC-20 receipt enforcement: `addToBalanceOf` rejects lossy terminal pulls, while `pay` does not enforce receipt deltas because pay hooks can consume tokens during settlement. The registry does not independently enforce receipts; it relies on the router path it forwards into.
- Preview normalization: buyback-hook metadata can improve the user-visible preview outcome, so route ranking must normalize hook-returned hints consistently across candidates.
- Pending-call conservation: failed Router frames must leave the Gateway holding the exact original input represented by pending state.
- Gateway intake: the transient balance-delta guard prevents callback tokens from counting a nested deposit twice, while nested Router allowances are restored for legitimate forwarding hooks.
- Qualification comparability: every counted failure gets at least five million gas, a one-day interval, and an unchanged error selector; encoded arguments are ignored, and any empty-data failure is counted as the gas-exhaustion class whose required budget escalates and never falls back.

## Tests to trust first

- [`test/RouterTerminalPreviewFork.t.sol`](../test/RouterTerminalPreviewFork.t.sol) for preview-path behavior.
- [`test/RouterTerminalCashOutFork.t.sol`](../test/RouterTerminalCashOutFork.t.sol) and [`test/RouterTerminalFeeCashOutFork.t.sol`](../test/RouterTerminalFeeCashOutFork.t.sol) for project-token cash-out routing.
- [`test/RouterTerminalReentrancy.t.sol`](../test/RouterTerminalReentrancy.t.sol) for callback and reentrancy-sensitive behavior.
- [`test/RouterTerminalFork.t.sol`](../test/RouterTerminalFork.t.sol), [`test/RouterTerminalMultihopFork.t.sol`](../test/RouterTerminalMultihopFork.t.sol), and [`test/invariant/RouterTerminalInvariant.t.sol`](../test/invariant/RouterTerminalInvariant.t.sol) for live routing assumptions.
- [`test/regression/CashOutCircularPrimaryTerminal.t.sol`](../test/regression/CashOutCircularPrimaryTerminal.t.sol), [`test/regression/CashOutFallbackPrefersRecursiveLoop.t.sol`](../test/regression/CashOutFallbackPrefersRecursiveLoop.t.sol), [`test/regression/LeftoverRefund.t.sol`](../test/regression/LeftoverRefund.t.sol), and [`test/regression/PreviewPrimaryTerminalMismatch.t.sol`](../test/regression/PreviewPrimaryTerminalMismatch.t.sol) for the misdiagnosis-prone edge cases.
- [`test/regression/RouterTerminalGatewayFailure.t.sol`](../test/regression/RouterTerminalGatewayFailure.t.sol) for the exact Base reproduction, gas sweep, callback intake, nested allowances, matching-selector resets, real-core payer propagation, retries, and refunds.
