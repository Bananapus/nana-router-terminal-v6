# nana-router-terminal-v6

## Purpose

Accept payments in any ERC-20 token (or native ETH), dynamically discover what token the destination project accepts, and route there — via Uniswap V3/V4 swap, direct forwarding, JB token cashout, or a combination.

## Contracts

| Contract | Role |
|----------|------|
| `JBRouterTerminal` | Core terminal: accepts any token, discovers the best route to the destination project's accepted token, swaps via Uniswap V3 or V4, forwards to primary terminal. Implements `IJBTerminal`, `IJBPermitTerminal`, `IUniswapV3SwapCallback`, `IUnlockCallback`. |
| `JBRouterTerminalRegistry` | Proxy terminal routing `pay`/`addToBalanceOf` to a per-project or default `JBRouterTerminal`. Implements `IJBTerminal`. |

## Key Functions

| Function | Contract | What it does |
|----------|----------|--------------|
| `pay(projectId, token, amount, beneficiary, minReturnedTokens, memo, metadata)` | `JBRouterTerminal` | Accept any token, discover destination's accepted token, swap if needed via best V3/V4 pool, forward to project's primary terminal. Returns project token count. |
| `addToBalanceOf(projectId, token, amount, shouldReturnHeldFees, memo, metadata)` | `JBRouterTerminal` | Same routing flow but calls `terminal.addToBalanceOf(...)` instead of `terminal.pay(...)`. |
| `discoverPool(normalizedTokenIn, normalizedTokenOut)` | `JBRouterTerminal` | Search V3 factory for highest liquidity pool across 4 fee tiers (0.01%, 0.05%, 0.3%, 1%). |
| `discoverBestPool(normalizedTokenIn, normalizedTokenOut)` | `JBRouterTerminal` | Discover best pool across both V3 and V4, comparing liquidity. Returns `PoolInfo` with version, key, and liquidity. |
| `setTerminalFor(projectId, terminal)` | `JBRouterTerminalRegistry` | Route a project to a specific allowed router terminal. Requires `SET_ROUTER_TERMINAL` permission. |
| `lockTerminalFor(projectId)` | `JBRouterTerminalRegistry` | Lock the terminal choice for a project (irreversible). |
| `allowTerminal(terminal)` | `JBRouterTerminalRegistry` | Owner-only: add a terminal to the allowlist. |
| `setDefaultTerminal(terminal)` | `JBRouterTerminalRegistry` | Owner-only: set the default terminal for projects without a custom choice. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `nana-core-v6` | `IJBDirectory`, `IJBTerminal`, `IJBProjects`, `IJBPermissions`, `IJBTokens` | Directory lookups (`primaryTerminalOf`), project ownership, permission checks, token discovery |
| `nana-core-v6` | `JBMetadataResolver` | Parsing `quoteForSwap` and `permit2` metadata from calldata |
| `nana-core-v6` | `JBAccountingContext`, `JBSingleAllowance` | Token accounting and Permit2 allowance structs |
| `nana-permission-ids-v6` | `JBPermissionIds` | Permission ID constants (`SET_ROUTER_TERMINAL`) |
| `@uniswap/v3-core` | `IUniswapV3Pool`, `IUniswapV3Factory`, `TickMath` | V3 pool swaps, factory pool discovery, tick math |
| `@uniswap/v3-periphery` | `OracleLibrary` | TWAP oracle consultation (`consult`, `getQuoteAtTick`, `getOldestObservationSecondsAgo`) |
| `@uniswap/v4-core` | `IPoolManager`, `PoolKey`, `Currency`, `StateLibrary` | V4 pool swaps and liquidity queries |
| `@uniswap/permit2` | `IPermit2`, `IAllowanceTransfer` | Gasless token approvals |
| `@openzeppelin/contracts` | `Ownable`, `ERC2771Context`, `SafeERC20` | Access control, meta-transactions, safe transfers |

## Key Types

| Struct/Enum | Key Fields | Used In |
|-------------|------------|---------|
| `PoolInfo` | `isV4`, `v3Pool`, `v4Key`, `liquidity` | Returned by `discoverBestPool`. Indicates whether the best route is V3 or V4 and stores the pool details. |
| `JBAccountingContext` | `token`, `decimals`, `currency` | Token accounting contexts for accepted tokens. |
| `JBSingleAllowance` | `sigDeadline`, `amount`, `expiration`, `nonce`, `signature` | Decoded from `permit2` metadata key for gasless approvals. |

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `DEFAULT_TWAP_WINDOW` | `10 minutes` | Default TWAP oracle window for auto-discovered pools |
| `FEE_TIERS` | `[3000, 500, 10000, 100]` | V3 fee tiers to search (0.3%, 0.05%, 1%, 0.01%) |
| `V4_FEES` | `[3000, 500, 10000, 100]` | V4 fee tiers to search |
| `V4_TICK_SPACINGS` | `[60, 10, 200, 1]` | V4 tick spacings paired with fee tiers |
| `SLIPPAGE_DENOMINATOR` | `10,000` | Basis points denominator for slippage |

## Gotchas

- The terminal never holds a token balance. After every swap, all output tokens are forwarded and leftover input tokens are returned to the payer.
- Unlike the swap terminal which had a fixed `TOKEN_OUT`, the router terminal dynamically discovers what token each project accepts. This makes it a universal entry point.
- Pool discovery runs at call time — it searches V3 and V4 pools across multiple fee tiers. The best pool (by liquidity) wins. This is gas-intensive but ensures optimal routing.
- When `tokenIn == NATIVE_TOKEN`, the terminal wraps ETH to WETH before swapping. When the output is `NATIVE_TOKEN`, it unwraps WETH after swapping.
- The `receive()` function only accepts ETH from the WETH contract (during unwrap). All other senders revert.
- TWAP fallback: when no observations exist (`oldestObservation == 0`), the terminal falls back to the pool's current spot tick and liquidity rather than reverting.
- Uniswap V4 requires `cancun` EVM version (transient storage). Chains without EIP-1153 cannot use V4 routing — the terminal falls back to V3.
- The `JBRouterTerminalRegistry` handles token custody during delegation — it transfers tokens from the payer to itself, then to the underlying terminal.
- Metadata keys: `"quoteForSwap"` for the minimum output amount, `"permit2"` for gasless approvals.
- `_msgSender()` (ERC-2771) is used instead of `msg.sender` for meta-transaction compatibility.
- The `JBSwapLib` library contains the core swap execution logic, extracted for contract size management.

## Example Integration

```solidity
import {JBRouterTerminal} from "@bananapus/router-terminal-v6/src/JBRouterTerminal.sol";
import {JBRouterTerminalRegistry} from "@bananapus/router-terminal-v6/src/JBRouterTerminalRegistry.sol";

// The registry is the entry point for payments.
// It delegates to per-project or default JBRouterTerminal instances.

// Pay project 1 with USDC — the router terminal discovers that
// project 1 accepts ETH, finds the best USDC/WETH pool across
// V3 and V4, swaps, and forwards ETH to the project's terminal.
IERC20(usdc).approve(address(registry), 1000e6);
registry.pay{value: 0}(
    1,           // projectId
    usdc,        // token (USDC)
    1000e6,      // amount (1000 USDC)
    beneficiary, // who receives project tokens
    0,           // minReturnedTokens
    "Payment via router",
    ""           // metadata (empty = use TWAP quote)
);

// Project owners can choose a specific router terminal:
registry.setTerminalFor(projectId, preferredTerminal);

// And lock it permanently:
registry.lockTerminalFor(projectId);
```
