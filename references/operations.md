# Router Terminal Operations

## Configuration Surface

- [`src/JBRouterTerminalRegistry.sol`](../src/JBRouterTerminalRegistry.sol) is the first stop for per-project terminal choice, default terminal behavior, allowlisting, and locking.
- [`src/JBRouterTerminal.sol`](../src/JBRouterTerminal.sol) owns the metadata-driven route selection and execution logic.
- [`script/Deploy.s.sol`](../script/Deploy.s.sol) is the deployment entry point when the task is about current deployment wiring rather than core routing logic.

## Change Checklist

- If you edit route discovery, verify both direct acceptance and swap-based routes.
- If you edit the cash-out loop, check credit-based flows and fork tests, not just simple payments.
- If you edit slippage or quote logic, inspect [`src/JBPayRouteResolver.sol`](../src/JBPayRouteResolver.sol) and the preview tests together.
- If you edit preview behavior, verify route ranking still normalizes buyback-hook hints and still agrees with execution.
- If you edit refund or partial-fill handling, verify baseline snapshots and destination-terminal receipt enforcement together.
- If you touch Permit2 or metadata parsing, verify the corresponding interfaces and structs in `src/interfaces/` and `src/structs/` together with the fork tests.

## Common Failure Modes

- Router behavior looks wrong, but the real issue is the downstream terminal's accepted-token or accounting behavior.
- Preview output drifts from execution because quote and execution paths were edited independently.
- Registry state makes a project use a different router than expected.
- Metadata overrides force an output token or cash-out source that the caller did not intend.
- A terminal-facing ERC-20 path reverts because the destination terminal did not actually receive the nominal amount. This now indicates a non-standard final-hop token path, not just a documentation caveat.

## Useful Proof Points

- [`test/RouterTerminalRegistry.t.sol`](../test/RouterTerminalRegistry.t.sol) for registry rules.
- [`test/RouterTerminalERC2771.t.sol`](../test/RouterTerminalERC2771.t.sol) for trusted-forwarder behavior.
- [`test/RouterTerminalSandwichFork.t.sol`](../test/RouterTerminalSandwichFork.t.sol) and [`test/RouterTerminalFeeCashOutFork.t.sol`](../test/RouterTerminalFeeCashOutFork.t.sol) for adversarial routing conditions.
- [`test/regression/LeftoverRefund.t.sol`](../test/regression/LeftoverRefund.t.sol), [`test/regression/PreviewPrimaryTerminalMismatch.t.sol`](../test/regression/PreviewPrimaryTerminalMismatch.t.sol), and [`test/regression/CashOutCircularPrimaryTerminal.t.sol`](../test/regression/CashOutCircularPrimaryTerminal.t.sol) for the route-selection and refund traps most likely to regress.
- [`test/TestRegressionGaps.sol`](../test/TestRegressionGaps.sol) for pinned edge cases.
