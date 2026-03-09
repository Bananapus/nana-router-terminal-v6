# nana-router-terminal-v6 — Risks

## Trust Assumptions

1. **Uniswap Pools** — Swap execution depends on available liquidity and pool integrity. Low-liquidity pools increase slippage risk.
2. **Project Owner** — Can configure routing via registry (set/lock terminal configurations). Locking is permanent.
3. **Core Protocol** — Routes payments to destination project's terminal. Trusts JBDirectory for terminal discovery.

## Known Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| Swap slippage / sandwich | Token swaps can be sandwiched by MEV | `minAmountOut` parameter; users should set appropriate slippage |
| Stale route | Registered swap route may become suboptimal | Routes can be updated (unless locked) |
| Lock permanence | `lockTerminalFor` is irreversible | Review carefully before locking |
| Cancun dependency | Uses Cancun EVM features | Only deployable on Cancun-compatible chains |
| WETH wrapping | Native token payments require WETH wrapping for swaps | Standard pattern, well-tested |

## Privileged Roles

| Role | Permission | Scope |
|------|-----------|-------|
| Project owner | `SET_ROUTER_TERMINAL` — configure AND lock routing | Per-project |
| Contract owner | Administrative functions on JBRouterTerminal | Global |

## Reentrancy Considerations

`_swap` executes swap then forwards payment — no intermediate state exposure between these calls. Terminal store records are only updated by the destination terminal.
