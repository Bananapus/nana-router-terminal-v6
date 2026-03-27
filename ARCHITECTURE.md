# nana-router-terminal-v6 — Architecture

## Purpose

Payment routing terminal for Juicebox V6. Accepts any token and dynamically discovers what each destination project accepts, then routes payment via direct forwarding, Uniswap swap (V3 or V4), JB token cashout, or a combination.

## Contract Map

```
src/
├── JBRouterTerminal.sol         — Payment routing: swap + forward to destination terminal
├── JBRouterTerminalRegistry.sol — Registry mapping projects to router terminal configs
├── interfaces/
│   ├── IJBPayerTracker.sol
│   ├── IJBRouterTerminal.sol
│   ├── IJBRouterTerminalRegistry.sol
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
  │
  ├─ Accept funds (msg.value for native, Permit2 pull for ERC-20, or credit transfer)
  │
  ├─ If input is a JB project token (credit or ERC-20):
  │    → Cash out recursively via _cashOutLoop (up to 20 hops)
  │    → Reclaimed token becomes the new tokenIn
  │
  ├─ Resolve tokenOut: what does the destination project accept?
  │    1. Metadata override ("routeTokenOut")
  │    2. Direct acceptance — project already accepts tokenIn
  │    3. NATIVE ↔ WETH equivalence check
  │    4. Dynamic discovery — iterate project terminals, find swappable token
  │
  ├─ Convert tokenIn → tokenOut via _convert:
  │    ├─ Same token: no-op
  │    ├─ NATIVE ↔ WETH: wrap (WETH.deposit) or unwrap (WETH.withdraw)
  │    └─ Different tokens: Uniswap swap
  │         │
  │         ├─ If native ETH input: held as raw ETH until V3 callback
  │         │   wraps (WETH.deposit) only the amount the pool consumes
  │         │
  │         ├─ Pool discovery (_discoverPool):
  │         │   Search V3 pools across 4 fee tiers (0.3%, 0.05%, 1%, 0.01%)
  │         │   Search V4 pools across same fee tiers (if PoolManager deployed)
  │         │   Compare in-range liquidity across all candidates
  │         │   Select the single pool with highest liquidity
  │         │
  │         ├─ Quote & slippage (_pickPoolAndQuote):
  │         │   1. User-provided quote (metadata "quoteForSwap") — used as-is
  │         │   2. V3 fallback: 10-min TWAP via OracleLibrary.consult()
  │         │   3. V4 fallback: spot price from getSlot0() (no built-in TWAP)
  │         │   Apply sigmoid slippage: minSlippage + range * impact/(impact+K)
  │         │
  │         ├─ Execute swap via V3 pool.swap() or V4 POOL_MANAGER.unlock()
  │         │
  │         ├─ If native ETH input: wrap any remaining raw ETH (partial fills)
  │         ├─ If native ETH output: unwrap WETH → ETH (WETH.withdraw)
  │         └─ Return leftover input tokens via _resolveRefundTo (checks msg.sender's IJBPayerTracker.originalPayer() via try-catch, falls back to _msgSender() for both pay() and addToBalanceOf())
  │
  ├─ Approve destination terminal for output tokens (or set msg.value for native)
  └─ Forward to destTerminal.pay() → return beneficiary token count
```

### Preview Routing
```
Caller → JBRouterTerminal.previewPayFor(projectId, token, amount)
  → Mirror source-of-funds and routing logic in view context
  → If direct, wrap-unwrap, or exact cashout route: forward preview to destination terminal
  → If swap route: estimate output using the same quote-selection logic used for execution bounds
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Terminal | `IJBTerminal` | Acts as a terminal that routes payments |
| Registry | `IJBRouterTerminalRegistry` | Maps projects to routing configs |
| Payer tracker | `IJBPayerTracker` | Exposes the original payer of a forwarded call for refund resolution |
| Permit | `IJBPermitTerminal` | Permit2 token approval support |

## Composition Boundary

The router terminal exposes the `IJBTerminal` surface because it needs to participate in Juicebox routing, but its
accounting context is intentionally synthetic. `accountingContextForTokenOf()` returns `decimals = 18` for native
tokens and probes `IERC20Metadata.decimals()` for ERC-20s (falling back to `18` if the call fails). The registry
forwards that value unchanged. Treat the router layer as a payment router only, not as an accounting-sensitive
terminal source for loan sizing, debt normalization, or any other decimals-dependent logic.

## Design Decisions

**Why the router is a terminal, not a standalone contract.** By implementing `IJBTerminal`, the router can be set as a project's terminal in the directory. Payers and frontend integrations call the same `pay()` / `addToBalanceOf()` interface they use for any terminal — no special routing code required on the caller side. The router accepts funds, converts them, and forwards to the real destination terminal in a single transaction.

**Why both Uniswap V3 and V4 support.** V4 pools may offer deeper liquidity for certain pairs (especially native-ETH pairs that V4 handles natively), while V3 pools have years of established liquidity. The router searches both and picks the pool with the highest in-range liquidity, giving payers the best available execution without requiring them to know which protocol version has the better pool.

**Why synthetic accounting contexts.** The router accepts any token and converts it before forwarding. It never holds balances between transactions, so it has no meaningful accounting of its own. `accountingContextForTokenOf()` returns a best-effort context (probing `decimals()` with an 18-decimal fallback) purely so the directory can register it. The real accounting happens at the destination terminal.

**Why the registry pattern.** `JBRouterTerminalRegistry` lets project owners lock a specific `JBRouterTerminal` instance for their project and manage Permit2 approvals in one place. This provides a stable entry point: if the router implementation is upgraded, the registry can be pointed to the new instance without changing the project's directory entry. It also gates which router terminals are allowed, preventing untrusted implementations from being set.

**Why `IJBPayerTracker` is a separate interface.** The router terminal needs to know the original payer when called through an intermediary so it can return leftover tokens from partial swap fills to the right address. Rather than coupling the router to `IJBRouterTerminalRegistry` specifically, the refund resolution logic (`_resolveRefundTo`) queries `IJBPayerTracker(msg.sender).originalPayer()` via a try-catch. This means any contract that implements `IJBPayerTracker` -- not just the registry -- can act as a forwarding intermediary. The registry inherits `IJBPayerTracker` through `IJBRouterTerminalRegistry`, keeping backward compatibility while opening the door for other intermediary patterns.

**Why liquidity-based pool selection instead of quote comparison.** Comparing actual output quotes across V3 and V4 would require executing (or simulating) swaps on both — expensive on-chain and complex for V4 where swaps must go through `PoolManager.unlock()`. Comparing in-range liquidity is a single `liquidity()` or `getLiquidity()` read per pool, is gas-cheap, and strongly correlates with execution quality for typical swap sizes.

## Dependencies
- `@bananapus/core-v6` — Terminal, directory, permissions
- `@uniswap/v3-core` + `v3-periphery` — V3 swap routing
- `@uniswap/v4-core` — V4 pool manager
- `@uniswap/permit2` — Token approvals
- `@openzeppelin/contracts` — SafeERC20, ERC2771, Ownable
