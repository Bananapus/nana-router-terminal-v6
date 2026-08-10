# Router Terminal Operations

## Configuration surface

- [`src/JBRouterTerminalRegistry.sol`](../src/JBRouterTerminalRegistry.sol) is the first stop for per-project terminal choice, default terminal behavior, allowlisting, and locking.
- [`src/JBRouterTerminalGateway.sol`](../src/JBRouterTerminalGateway.sol) owns pending-call custody and the permissionless retry/finalization policy.
- [`src/JBRouterTerminal.sol`](../src/JBRouterTerminal.sol) owns the metadata-driven route selection and execution logic.
- [`script/Deploy.s.sol`](../script/Deploy.s.sol) is the deployment entry point when the task is about current deployment wiring rather than core routing logic.

## Change checklist

- If you edit route discovery, verify both direct acceptance and swap-based routes.
- If you edit the cash-out loop, check project-token cash-out flows and fork tests, not only simple payments.
- If you edit slippage or quote logic, inspect [`src/JBPayRouteResolver.sol`](../src/JBPayRouteResolver.sol) and the preview tests together.
- If you edit preview behavior, verify route ranking still normalizes buyback-hook hints and still agrees with execution.
- If you edit refund or partial-fill handling, verify baseline snapshots and destination-terminal receipt enforcement together.
- If you touch Permit2 or metadata parsing, verify the corresponding interfaces and structs in `src/interfaces/` and `src/structs/` together with the fork tests.
- If you edit Gateway failure handling, verify selector-level resets, one-day windows, minimum retry gas, complete-budget OOG rejection, expanded-gas recovery, terminal-only retention, callback-token intake, nested allowances, final-attempt success, primary-terminal refund fallback, and atomic refund rollback together.

## Common failure modes

- Router behavior looks wrong, but the real issue is the downstream terminal's accepted-token or accounting behavior.
- Preview output drifts from execution because quote and execution paths were edited independently.
- Registry state makes a project use a different router than expected.
- Metadata overrides force an output token or cash-out source that the caller did not intend.
- On `addToBalanceOf` paths, a terminal-facing ERC-20 receipt mismatch indicates a non-standard final-hop token path.
- A pending call is not a Registry balance: the Gateway holds the original input while the unchanged Registry remains stateless.
- A later `setDefaultTerminal` does not move existing project cohorts to the Gateway; deployment explicitly migrates project 1 and the issued IDs listed in `NANA_ROUTER_TERMINAL_MIGRATION_PROJECT_IDS`.

## Useful proof points

- [`test/RouterTerminalRegistry.t.sol`](../test/RouterTerminalRegistry.t.sol) for registry rules.
- [`test/RouterTerminalERC2771.t.sol`](../test/RouterTerminalERC2771.t.sol) for trusted-forwarder behavior.
- [`test/RouterTerminalSandwichFork.t.sol`](../test/RouterTerminalSandwichFork.t.sol) and [`test/RouterTerminalFeeCashOutFork.t.sol`](../test/RouterTerminalFeeCashOutFork.t.sol) for adversarial routing conditions.
- [`test/regression/LeftoverRefund.t.sol`](../test/regression/LeftoverRefund.t.sol), [`test/regression/PreviewPrimaryTerminalMismatch.t.sol`](../test/regression/PreviewPrimaryTerminalMismatch.t.sol), and [`test/regression/CashOutCircularPrimaryTerminal.t.sol`](../test/regression/CashOutCircularPrimaryTerminal.t.sol) for the route-selection and refund traps most likely to regress.
- [`test/TestRegressionGaps.sol`](../test/TestRegressionGaps.sol) for pinned edge cases.
- [`test/regression/RouterTerminalGatewayFailure.t.sol`](../test/regression/RouterTerminalGatewayFailure.t.sol) for autonomous failure lifecycle and the reported Base transaction.
