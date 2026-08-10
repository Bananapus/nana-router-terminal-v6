# Router Terminal Runtime

## Contract roles

- [`src/JBRouterTerminal.sol`](../src/JBRouterTerminal.sol) is the main execution surface. It accepts input tokens, discovers the output token, performs conversion, and forwards settlement to the downstream terminal.
- [`src/JBRouterTerminalRegistry.sol`](../src/JBRouterTerminalRegistry.sol) selects a per-project router terminal or falls back to the default one, while enforcing allowlist and lock rules.
- Helper logic in [`src/JBPayRouteResolver.sol`](../src/JBPayRouteResolver.sol) and the repo's interfaces/structs define how pay-route resolution and metadata-driven routing fit together.

## Runtime path

1. The router accepts native tokens, ERC-20s, or claimed Juicebox project-token ERC-20s.
2. If the input is a Juicebox project token, the router may enter a cash-out loop first.
3. The router resolves the desired output token using direct acceptance, wrap/unwrap equivalence, metadata overrides, or pool discovery.
4. It converts value through direct forwarding, wrap/unwrap, Uniswap V3, or Uniswap V4.
5. It forwards the final asset to the destination project's canonical terminal.

## High-risk areas

- Preview and execution parity: changes to quote selection or route discovery should be checked against both preview and mutative paths.
- V4 discovery scope: the router searches both vanilla V4 pools and pools using the configured canonical `UNIV4_HOOK`.
- Cash-out loop behavior: recursive routing through project tokens can create subtle loop or slippage issues.
- Callback validation: V3 and V4 callback guards are security-critical and should not drift.
- Leftover/refund handling: refunds can route to the original payer or fallback recipient depending on context.
- Dynamic accounting contexts: this repo intentionally synthesizes accounting contexts instead of storing a static token list.
- Final terminal-facing ERC-20 receipt enforcement: `addToBalanceOf` rejects lossy terminal pulls, while `pay` does not enforce receipt deltas because pay hooks can consume tokens during settlement. The registry does not independently enforce receipts; it relies on the router path it forwards into.
- Preview normalization: buyback-hook metadata can improve the user-visible preview outcome, so route ranking must normalize hook-returned hints consistently across candidates.

## Tests to trust first

- [`test/RouterTerminalPreviewFork.t.sol`](../test/RouterTerminalPreviewFork.t.sol) for preview-path behavior.
- [`test/RouterTerminalCashOutFork.t.sol`](../test/RouterTerminalCashOutFork.t.sol) and [`test/RouterTerminalFeeCashOutFork.t.sol`](../test/RouterTerminalFeeCashOutFork.t.sol) for project-token cash-out routing.
- [`test/RouterTerminalReentrancy.t.sol`](../test/RouterTerminalReentrancy.t.sol) for callback and reentrancy-sensitive behavior.
- [`test/RouterTerminalFork.t.sol`](../test/RouterTerminalFork.t.sol), [`test/RouterTerminalMultihopFork.t.sol`](../test/RouterTerminalMultihopFork.t.sol), and [`test/invariant/RouterTerminalInvariant.t.sol`](../test/invariant/RouterTerminalInvariant.t.sol) for live routing assumptions.
- [`test/regression/CashOutCircularPrimaryTerminal.t.sol`](../test/regression/CashOutCircularPrimaryTerminal.t.sol), [`test/regression/CashOutFallbackPrefersRecursiveLoop.t.sol`](../test/regression/CashOutFallbackPrefersRecursiveLoop.t.sol), [`test/regression/LeftoverRefund.t.sol`](../test/regression/LeftoverRefund.t.sol), and [`test/regression/PreviewPrimaryTerminalMismatch.t.sol`](../test/regression/PreviewPrimaryTerminalMismatch.t.sol) for the misdiagnosis-prone edge cases.
