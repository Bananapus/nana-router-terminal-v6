# nana-router-terminal-v6 — Architecture

## Purpose

Payment routing terminal for Juicebox V6. Accepts any token and dynamically discovers what each destination project accepts, then routes payment via direct forwarding, Uniswap swap (V3 or V4), JB token cashout, or a combination.

## Contract Map

```
src/
├── JBRouterTerminal.sol         — Payment routing: swap + forward to destination terminal
├── JBRouterTerminalRegistry.sol — Registry mapping projects to router terminal configs
├── interfaces/
│   ├── IJBRouterTerminal.sol
│   └── IWETH9.sol
├── libraries/
│   └── JBSwapLib.sol            — Uniswap V3/V4 swap helpers, pool discovery
└── structs/
    └── PoolInfo.sol             — Cached pool configuration
```

## Key Data Flow

### Payment Routing
```
Payer → JBRouterTerminal.pay(projectId, token, amount)
  → Discover destination project's accepted token
  → If same token: forward directly to project's terminal
  → If different token:
    → Compare V3 and V4 pool quotes
    → Swap via better pool
    → Forward swapped tokens to project's terminal
  → Return token count from destination payment
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Terminal | `IJBTerminal` | Acts as a terminal that routes payments |
| Registry | `IJBRouterTerminalRegistry` | Maps projects to routing configs |
| Permit | `IJBPermitTerminal` | Permit2 token approval support |

## Dependencies
- `@bananapus/core-v6` — Terminal, directory, permissions
- `@uniswap/v3-core` + `v3-periphery` — V3 swap routing
- `@uniswap/v4-core` — V4 pool manager
- `@uniswap/permit2` — Token approvals
- `@openzeppelin/contracts` — SafeERC20, ERC2771, Ownable
