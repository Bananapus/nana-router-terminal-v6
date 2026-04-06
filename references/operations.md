# Router Terminal Operations

## Configuration Surface

- [`src/JBRouterTerminalRegistry.sol`](../src/JBRouterTerminalRegistry.sol) is the first stop for per-project terminal choice, default terminal behavior, allowlisting, and locking.
- [`src/JBRouterTerminal.sol`](../src/JBRouterTerminal.sol) owns the metadata-driven route selection and execution logic.
- [`script/Deploy.s.sol`](../script/Deploy.s.sol) is the deployment entry point when the task is about current deployment wiring rather than core routing logic.

## Change Checklist

- If you edit route discovery, verify both direct acceptance and swap-based routes.
- If you edit the cash-out loop, check credit-based flows and fork tests, not just simple payments.
- If you edit slippage or quote logic, inspect [`src/libraries/JBSwapLib.sol`](../src/libraries/JBSwapLib.sol) and the preview tests together.
- If you touch Permit2 or metadata parsing, verify the corresponding interface and struct usage in [`src/interfaces/`](../src/interfaces/) and [`src/structs/`](../src/structs/).

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
- [`test/TestAuditGaps.sol`](../test/TestAuditGaps.sol) for pinned edge cases.
