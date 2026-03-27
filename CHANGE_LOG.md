# nana-router-terminal-v6 Changelog (v5 → v6)

This document describes all changes between `nana-swap-terminal` (v5) and `nana-router-terminal-v6` (v6).

**Note:** This repo was renamed from `nana-swap-terminal` to `nana-router-terminal` in v6.

## Summary

This release represents a **philosophical shift from configured to automatic**: the swap terminal required manual pool registration and per-project TWAP configuration, while the router terminal automatically discovers the best route for any payment.

- **Renamed `JBSwapTerminal` → `JBRouterTerminal`**: Reflects the broader scope — not just swapping, but full payment routing including JB token cashouts, credit transfers, and multi-hop resolution.
- **Automatic pool discovery**: Pools are auto-discovered across both Uniswap V3 and V4 by scanning all fee tiers and selecting the highest-liquidity pool. No manual `addDefaultPool()` needed.
- **Automatic token route discovery**: The terminal dynamically determines what token a destination project accepts by querying terminals and accounting contexts.
- **JB token cashout routing**: Can recursively cash out JB project tokens (ERC-20 or credits) from source projects before routing the reclaimed tokens to the destination.
- **Shared `JBSwapLib` library**: Swap math extracted for reuse with `nana-buyback-hook-v6` — includes continuous sigmoid slippage and V4 price limit computation.

---

## 1. Breaking Changes

### 1.1 Contract Renamed: `JBSwapTerminal` → `JBRouterTerminal`
The main contract was renamed from `JBSwapTerminal` (and `JBSwapTerminal5_1`) to `JBRouterTerminal`. All error prefixes, interface names, and references changed accordingly.

### 1.2 No Fixed `TOKEN_OUT` — Dynamic Token Discovery
- **v5:** The terminal had an immutable `TOKEN_OUT` address set at construction. All incoming tokens were swapped to this single output token. Projects had to explicitly configure pools via `addDefaultPool()`.
- **v6:** The terminal dynamically discovers what token each destination project accepts by querying `DIRECTORY.primaryTerminalOf()` and iterating the project's terminal accounting contexts. There is no `TOKEN_OUT` immutable. The `_OUT_IS_NATIVE_TOKEN` flag is also removed.

### 1.3 Constructor Parameters Changed
- **v5:** `constructor(directory, permissions, projects, permit2, owner, weth, tokenOut, factory, trustedForwarder)` — required a fixed `tokenOut` and reverted on `address(0)`.
- **v6:** `constructor(directory, permissions, projects, tokens, permit2, owner, weth, factory, poolManager, trustedForwarder)` — added `IJBTokens tokens` and `IPoolManager poolManager`; removed `tokenOut`.

### 1.4 `IJBSwapTerminal` Interface Removed, Replaced by `IJBRouterTerminal`
- **v5 `IJBSwapTerminal`** exposed: `DEFAULT_PROJECT_ID()`, `MAX_TWAP_WINDOW()`, `MIN_TWAP_WINDOW()`, `MIN_DEFAULT_POOL_CARDINALITY()`, `UNCERTAIN_SLIPPAGE_TOLERANCE()`, `SLIPPAGE_DENOMINATOR()`, `twapWindowOf()`, `addDefaultPool()`, `addTwapParamsFor()`.
- **v6 `IJBRouterTerminal`** exposes: `discoverBestPool()`, `discoverPool()`, and `previewPayFor()`.
- All pool/TWAP configuration functions are removed (see section 1.5).

### 1.5 Removed: Per-Project Pool Configuration and TWAP Management
The following functions and storage were removed entirely in v6:
- `addDefaultPool(uint256 projectId, address token, IUniswapV3Pool pool)` — projects no longer manually configure pools.
- `addTwapParamsFor(uint256 projectId, IUniswapV3Pool pool, uint256 secondsAgo)` — TWAP windows are no longer project-configurable.
- `getPoolFor(uint256 projectId, address tokenIn)` — pool lookup is now fully automatic.
- `twapWindowOf(uint256 projectId, IUniswapV3Pool pool)` — replaced by a fixed `DEFAULT_TWAP_WINDOW = 10 minutes`.
- Storage mappings `_poolFor`, `_accountingContextFor`, `_tokensWithAContext`, `_twapWindowOf` — all removed.

### 1.6 Removed: Constants
The following public constants from v5 were removed:
- `DEFAULT_PROJECT_ID` (was `0`)
- `MAX_TWAP_WINDOW` (was `2 days`)
- `MIN_TWAP_WINDOW` (was `2 minutes`)
- `MIN_DEFAULT_POOL_CARDINALITY` (was `10`)
- `UNCERTAIN_SLIPPAGE_TOLERANCE` (was `1050`)

The `SLIPPAGE_DENOMINATOR` constant was kept but changed from `uint160` to `uint256`.

### 1.7 `supportsInterface` Changed
- **v5:** Reported support for `IJBTerminal`, `IJBPermitTerminal`, `IERC165`, `IUniswapV3SwapCallback`, `IJBPermissioned`, `IJBSwapTerminal`.
- **v6:** Reports support for `IJBTerminal`, `IJBPermitTerminal`, `IJBRouterTerminal`, `IERC165`, and `IJBPermissioned`. It no longer advertises `IUniswapV3SwapCallback`.

### 1.8 Permission ID Changed (Registry)
- **v5:** `lockTerminalFor()` and `setTerminalFor()` used `JBPermissionIds.ADD_SWAP_TERMINAL_POOL`.
- **v6:** These functions use `JBPermissionIds.SET_ROUTER_TERMINAL`.

### 1.9 `lockTerminalFor` Signature Changed (Registry)
- **v5:** `lockTerminalFor(uint256 projectId)` — no confirmation of which terminal is being locked.
- **v6:** `lockTerminalFor(uint256 projectId, IJBTerminal expectedTerminal)` — requires the caller to confirm the expected terminal, preventing race conditions where the default changes between transaction submission and execution.

### 1.10 Accounting Contexts Are Now Dynamic
- **v5:** `accountingContextForTokenOf()` looked up stored contexts from `_accountingContextFor` mappings (set via `addDefaultPool`). `accountingContextsOf()` merged project-specific and default-project contexts.
- **v6:** `accountingContextForTokenOf()` is `pure` and returns a synthetic context with 18 decimals for any token. `accountingContextsOf()` returns an empty array since the terminal accepts any token dynamically.

### 1.11 Solidity Version
- **v5:** `pragma solidity 0.8.23`
- **v6:** `pragma solidity 0.8.28` (0.8.28 for JBRouterTerminalRegistry)

---

## 2. New Features

### 2.1 Uniswap V4 Support
The terminal now supports swapping via both Uniswap V3 and V4 pools. Pool discovery (`_discoverPool`) searches across all V3 fee tiers and V4 fee/tickSpacing combinations, selecting whichever pool has the highest in-range liquidity.

New V4-specific components:
- `IPoolManager POOL_MANAGER` immutable (can be `address(0)` if V4 is unavailable).
- `IUnlockCallback` interface implemented via `unlockCallback()`.
- `_executeV4Swap()`, `_settleV4()`, `_takeV4()`, `_discoverV4Pool()` internal functions.
- `_getV4SpotQuote()` — uses instantaneous spot price with sigmoid slippage (security note: not MEV-resistant; users should provide `quoteForSwap` metadata).
- `_V4_FEES` and `_V4_TICK_SPACINGS` arrays for vanilla V4 pool search.

### 2.2 Automatic Pool Discovery
- **v5:** Pools had to be manually registered per project via `addDefaultPool()`.
- **v6:** Pools are auto-discovered at swap time by scanning all V3 fee tiers (3000, 500, 10000, 100 bps) and V4 pools, selecting the one with the highest liquidity. No manual configuration needed.

### 2.3 Automatic Token Route Discovery
New `_resolveTokenOut()` function determines what token a destination project accepts, with the following priority:
1. Metadata override (`routeTokenOut` key).
2. Direct acceptance (project accepts `tokenIn`).
3. NATIVE/WETH equivalence check.
4. Dynamic discovery — iterate all project terminals and their accounting contexts, find the accepted token with the best Uniswap pool against `tokenIn`.

### 2.4 JB Token Cash Out Routing
New `_cashOutLoop()` function enables recursive cashout of JB project tokens:
- If `tokenIn` is a JB project token (ERC-20 or credit), the terminal can cash it out from the source project's terminal, then recursively process the reclaimed token.
- Up to `_MAX_CASHOUT_ITERATIONS = 20` iterations to prevent infinite loops.
- Supports `cashOutSource` metadata key for credit-based cashouts.
- Supports `cashOutMinReclaimed` metadata key for slippage protection on the first cashout step.

### 2.5 Credit Transfer Support
`_acceptFundsFor()` now checks for `cashOutSource` metadata. If present, instead of transferring ERC-20 tokens, it pulls JB token credits from the payer via `TOKENS.transferCreditsFrom()`.

### 2.6 New `IJBTokens TOKENS` Immutable
The terminal now has a reference to the `IJBTokens` contract for looking up project IDs from token addresses and transferring credits.

### 2.7 `PoolInfo` Struct (New File)
New struct `src/structs/PoolInfo.sol` that represents either a V3 or V4 pool:
```solidity
struct PoolInfo {
    bool isV4;
    IUniswapV3Pool v3Pool;
    PoolKey v4Key;
}
```

### 2.8 `JBSwapLib` Library (New File)
New library `src/libraries/JBSwapLib.sol` containing:
- `getSlippageTolerance(impact, poolFeeBps)` — continuous sigmoid formula replacing v5's stepped if/else brackets. Returns slippage in basis points with a minimum of `poolFee + 1%` (floor 2%) and a ceiling of 88%.
- `calculateImpact(amountIn, liquidity, sqrtP, zeroForOne)` — estimates price impact at 1e18 precision.
- `sqrtPriceLimitFromAmounts(amountIn, minimumAmountOut, zeroForOne)` — computes a `sqrtPriceLimitX96` for partial-fill protection (V3 and V4). This replaces v5's approach of using extreme price limits (`MIN_SQRT_RATIO + 1` / `MAX_SQRT_RATIO - 1`).

### 2.9 `discoverBestPool()` and `discoverPool()` Public Views
New external view functions on `IJBRouterTerminal` for off-chain queries:
- `discoverBestPool(tokenIn, tokenOut)` — returns a `PoolInfo` (V3 or V4).
- `discoverPool(tokenIn, tokenOut)` — returns only the V3 pool (backwards-compatible helper).

### 2.10 `previewPayFor()` Added
New external view functions on the router surfaces:
- `JBRouterTerminal.previewPayFor(projectId, token, amount, beneficiary, metadata)` mirrors the router's payment routing logic and forwards the preview to the terminal that would ultimately receive the payment.
- `JBRouterTerminalRegistry.previewPayFor(projectId, token, amount, beneficiary, metadata)` resolves the router terminal for a project and forwards the preview.
- Direct routes and wrap-unwrap routes are previewable exactly.
- Swap routes return best-effort estimates using the same pool discovery and quote-selection logic used for execution bounds.

### 2.11 `Permit2AllowanceFailed` Event
In v6, when a Permit2 allowance call fails during `_acceptFundsFor()`, an event `Permit2AllowanceFailed(token, owner, reason)` is emitted (inherited from `IJBPermitTerminal`), and the payment continues using fallback transfer. In v5, the failure was silently swallowed with an empty `catch`.

### 2.12 Fee-on-Transfer Token Handling
- **v5 `_acceptFundsFor`:** Returned `IERC20(token).balanceOf(address(this))` after transfer — would include any pre-existing balance.
- **v6 `_acceptFundsFor`:** Uses balance-delta pattern (`balanceAfter - balanceBefore`) to accurately measure tokens received.

### 2.13 Partial-Fill Leftover Handling via Balance Delta
- **v5 `_handleTokenTransfersAndSwap`:** Measured leftovers as the full `balanceOf(normalizedTokenIn)` — could include pre-existing balances.
- **v6 `_handleSwap`:** Snapshots `balanceBefore` and uses `balanceAfter - balanceBefore` for accurate leftover calculation.

### 2.14 `PERMIT2` Exposed on `IJBRouterTerminalRegistry` Interface
- **v5:** `PERMIT2` was an immutable on the registry contract but not exposed on the `IJBSwapTerminalRegistry` interface.
- **v6:** `PERMIT2()` is declared on the `IJBRouterTerminalRegistry` interface.

---

## 3. Event Changes

### 3.0 Indexer Notes

This repo is the direct replacement for v5 swap-terminal indexing:
- all registry event families moved from `JBSwapTerminalRegistry_*` to `JBRouterTerminalRegistry_*`;
- registry events now include `caller`;
- route discovery is dynamic, so do not assume one fixed output token or one manually-registered default pool per project.

### 3.1 Registry Events Renamed
All events were renamed from `JBSwapTerminalRegistry_*` to `JBRouterTerminalRegistry_*`.

### 3.2 Registry Events Now Include `caller`
All registry events now include an `address caller` parameter:
| v5 | v6 |
|---|---|
| `JBSwapTerminalRegistry_AllowTerminal(IJBTerminal terminal)` | `JBRouterTerminalRegistry_AllowTerminal(IJBTerminal terminal, address caller)` |
| `JBSwapTerminalRegistry_DisallowTerminal(IJBTerminal terminal)` | `JBRouterTerminalRegistry_DisallowTerminal(IJBTerminal terminal, address caller)` |
| `JBSwapTerminalRegistry_LockTerminal(uint256 projectId)` | `JBRouterTerminalRegistry_LockTerminal(uint256 indexed projectId, address caller)` |
| `JBSwapTerminalRegistry_SetDefaultTerminal(IJBTerminal terminal)` | `JBRouterTerminalRegistry_SetDefaultTerminal(IJBTerminal terminal, address caller)` |
| `JBSwapTerminalRegistry_SetTerminal(uint256 indexed projectId, IJBTerminal terminal)` | `JBRouterTerminalRegistry_SetTerminal(uint256 indexed projectId, IJBTerminal terminal, address caller)` |

### 3.3 New Event on Main Terminal
- `Permit2AllowanceFailed(address indexed token, address indexed owner, bytes reason)` — emitted when Permit2 allowance fails (from `IJBPermitTerminal`).

---

## 4. Error Changes

### 4.1 Main Terminal Errors Renamed and Restructured
| v5 Error | v6 Error | Notes |
|---|---|---|
| `JBSwapTerminal_CallerNotPool(address)` | `JBRouterTerminal_CallerNotPool(address)` | Renamed |
| `JBSwapTerminal_InvalidTwapWindow(uint256, uint256, uint256)` | *Removed* | TWAP windows are no longer configurable |
| `JBSwapTerminal_SpecifiedSlippageExceeded(uint256, uint256)` | `JBRouterTerminal_SlippageExceeded(uint256 amountOut, uint256 minAmountOut)` | Renamed |
| `JBSwapTerminal_NoDefaultPoolDefined(uint256, address)` | *Removed* | Pools are auto-discovered |
| `JBSwapTerminal_NoMsgValueAllowed(uint256)` | `JBRouterTerminal_NoMsgValueAllowed(uint256)` | Renamed |
| `JBSwapTerminal_PermitAllowanceNotEnough(uint256, uint256)` | `JBRouterTerminal_PermitAllowanceNotEnough(uint256, uint256)` | Renamed |
| `JBSwapTerminal_TokenNotAccepted(uint256, address)` | `JBRouterTerminal_TokenNotAccepted(uint256, address)` | Renamed |
| `JBSwapTerminal_UnexpectedCall(address)` | *Removed* | `receive()` is now unrestricted |
| `JBSwapTerminal_WrongPool(address, address)` | *Removed* | No manual pool registration |
| `JBSwapTerminal_ZeroToken()` | *Removed* | No fixed `tokenOut` constructor param |
| *N/A* | `JBRouterTerminal_AmountOverflow(uint256)` | New — guards `uint160` cast in `_transferFrom` and `uint128` cast in TWAP quote |
| *N/A* | `JBRouterTerminal_CallerNotPoolManager(address)` | New — V4 callback verification |
| *N/A* | `JBRouterTerminal_CashOutLoopLimit()` | New — exceeded `_MAX_CASHOUT_ITERATIONS` |
| *N/A* | `JBRouterTerminal_NoCashOutPath(uint256, uint256)` | New — no cashout terminal found |
| *N/A* | `JBRouterTerminal_NoLiquidity()` | New — pool has zero liquidity |
| *N/A* | `JBRouterTerminal_NoObservationHistory()` | New — V3 pool has no observation history for TWAP |
| *N/A* | `JBRouterTerminal_NoPoolFound(address, address)` | New — no V3 or V4 pool exists |
| *N/A* | `JBRouterTerminal_NoRouteFound(uint256, address)` | New — no accepted token found for project |

### 4.2 Registry Errors Renamed and New
| v5 Error | v6 Error | Notes |
|---|---|---|
| `JBSwapTerminalRegistry_NoMsgValueAllowed(uint256)` | `JBRouterTerminalRegistry_NoMsgValueAllowed(uint256)` | Renamed |
| `JBSwapTerminalRegistry_PermitAllowanceNotEnough(uint256, uint256)` | `JBRouterTerminalRegistry_PermitAllowanceNotEnough(uint256, uint256)` | Renamed |
| `JBSwapTerminalRegistry_TerminalLocked(uint256)` | `JBRouterTerminalRegistry_TerminalLocked(uint256)` | Renamed |
| `JBSwapTerminalRegistry_TerminalNotAllowed(IJBTerminal)` | `JBRouterTerminalRegistry_TerminalNotAllowed(IJBTerminal)` | Renamed |
| `JBSwapTerminalRegistry_TerminalNotSet(uint256)` | `JBRouterTerminalRegistry_TerminalNotSet(uint256)` | Renamed |
| *N/A* | `JBRouterTerminalRegistry_AmountOverflow()` | New — guards `uint160` cast |
| *N/A* | `JBRouterTerminalRegistry_TerminalMismatch(IJBTerminal, IJBTerminal)` | New — `lockTerminalFor` safety check |
| *N/A* | `JBRouterTerminalRegistry_ZeroAddress()` | New — prevents setting `address(0)` as default terminal |

---

## 5. Struct Changes

### 5.1 New: `PoolInfo` (`src/structs/PoolInfo.sol`)
```solidity
struct PoolInfo {
    bool isV4;
    IUniswapV3Pool v3Pool;
    PoolKey v4Key;
}
```
Represents either a Uniswap V3 or V4 pool. Used throughout the v6 pool discovery and swap execution flow.

---

## 6. Implementation Changes (Non-Interface)

### 6.1 Slippage Tolerance: Stepped → Continuous Sigmoid
- **v5:** Used a series of `if/else` brackets to map impact ranges to slippage tolerances (9 discrete brackets). Impact precision was `10 * SLIPPAGE_DENOMINATOR` (1e5).
- **v6:** Uses a continuous sigmoid formula in `JBSwapLib.getSlippageTolerance()`: `minSlippage + (MAX_SLIPPAGE - minSlippage) * impact / (impact + K)`. Impact precision is 1e18. Minimum slippage is `poolFee + 1%` with a 2% floor. Maximum is 88%.

### 6.2 `sqrtPriceLimitX96` Computation
- **v5 `_swap`:** Always used extreme price limits (`MIN_SQRT_RATIO + 1` or `MAX_SQRT_RATIO - 1`), providing no partial-fill protection.
- **v6 `_executeV3Swap` / `_executeV4Swap`:** Uses `JBSwapLib.sqrtPriceLimitFromAmounts()` to compute a meaningful price limit from `amountIn` and `minAmountOut`, providing partial-fill protection so the swap stops if execution price worsens beyond the minimum acceptable rate.

### 6.3 `uniswapV3SwapCallback` Pool Verification
- **v5:** Verified the caller by looking up the stored pool from `_poolFor[projectId][normalizedTokenIn]` and comparing `msg.sender` against it.
- **v6:** Verifies the caller by querying the factory directly with the callback data's `tokenIn`/`tokenOut` and the pool's `fee()`. This is necessary because pools are auto-discovered rather than stored.

### 6.4 `uniswapV3SwapCallback` Data Format
- **v5:** Callback data was `abi.encode(projectId, tokenIn)`.
- **v6:** Callback data is `abi.encode(projectId, tokenIn, tokenOut)` — includes `tokenOut` for factory verification.

### 6.5 `receive()` Function
- **v5:** Restricted to only accept ETH from the `WETH` contract, reverting with `JBSwapTerminal_UnexpectedCall` otherwise.
- **v6:** Unrestricted — accepts ETH from cashout reclaims, WETH unwraps, and V4 PoolManager takes.

### 6.6 `_acceptFundsFor` Uses `_msgSender()` Consistently
- **v5:** Mixed `msg.sender` and `_msgSender()` — used `msg.sender` in the Permit2 permit call and `_transferFrom`.
- **v6:** Uses `_msgSender()` consistently throughout, respecting ERC-2771 meta-transactions.

### 6.7 `pay()` and `addToBalanceOf()` Routing
- **v5:** Both functions looked up `DIRECTORY.primaryTerminalOf(projectId, TOKEN_OUT)` for a fixed output token, then swapped via `_handleTokenTransfersAndSwap()`.
- **v6:** Both functions call `_route()` which handles the full routing pipeline: credit detection, JB token cashout, token resolution, and conversion (direct/wrap/swap).

### 6.8 `_beforeTransferFor` Simplified
- **v5:** Checked the `_OUT_IS_NATIVE_TOKEN` flag.
- **v6:** Checks `token == JBConstants.NATIVE_TOKEN` directly (since there's no fixed output token).

### 6.9 `_transferFrom` Amount Overflow Guard
- **v5:** Cast `amount` to `uint160` unchecked when calling `PERMIT2.transferFrom`.
- **v6:** Checks `amount > type(uint160).max` and reverts with `JBRouterTerminal_AmountOverflow` before the cast.

### 6.10 Registry `terminalOf` Storage Encapsulation
- **v5:** `terminalOf` was a `public` mapping directly on the interface.
- **v6:** The storage mapping is `internal _terminalOf`, with a public `terminalOf(projectId)` view function that applies the default fallback. This prevents direct mapping access that would bypass the fallback logic.

### 6.11 Registry `disallowTerminal` Clears Default
- **v5:** `disallowTerminal()` only set `isTerminalAllowed[terminal] = false`.
- **v6:** Additionally clears `defaultTerminal` if it matches the terminal being disallowed.

### 6.12 Registry `setDefaultTerminal` Zero Address Check
- **v5:** No validation on the terminal address.
- **v6:** Reverts with `JBRouterTerminalRegistry_ZeroAddress()` if `address(terminal) == address(0)`.

### 6.13 Removed: `JBSwapTerminal5_1`
v5 contained both `JBSwapTerminal.sol` and `JBSwapTerminal5_1.sol` (a minor revision). v6 has a single `JBRouterTerminal.sol`.

### 6.14 `_pickPoolAndQuote` Redesigned
- **v5:** Looked up stored pools from `_poolFor` mappings. If no user quote was provided, used project-specific TWAP windows with fallback to slot0 for pools with no observations.
- **v6:** Auto-discovers pools via `_discoverPool()`. If no user quote is provided, dispatches to `_getV3TwapQuote()` (for V3 pools, using a fixed 10-minute TWAP window) or `_getV4SpotQuote()` (for V4 pools, using spot price). Reverts with `JBRouterTerminal_NoPoolFound` if no pool exists (v5 reverted with `JBSwapTerminal_NoDefaultPoolDefined`).

### 6.15 New Metadata Keys
- `cashOutSource` — specifies a source project ID and credit amount for credit-based cashouts.
- `cashOutMinReclaimed` — minimum tokens to reclaim from the first cashout step.
- `routeTokenOut` — payer-specified output token override.
- `quoteForSwap` — retained from v5 (user-provided minimum output quote).
- `permit2` — retained from v5.

---

## 7. Migration Table

| v5 File | v6 File | Status |
|---|---|---|
| `src/JBSwapTerminal.sol` | `src/JBRouterTerminal.sol` | **Renamed + Rewritten** |
| `src/JBSwapTerminal5_1.sol` | *N/A* | **Removed** (consolidated into `JBRouterTerminal`) |
| `src/JBSwapTerminalRegistry.sol` | `src/JBRouterTerminalRegistry.sol` | **Renamed + Updated** |
| `src/interfaces/IJBSwapTerminal.sol` | `src/interfaces/IJBRouterTerminal.sol` | **Renamed + Rewritten** (entirely different surface) |
| `src/interfaces/IJBSwapTerminalRegistry.sol` | `src/interfaces/IJBRouterTerminalRegistry.sol` | **Renamed + Updated** (added `PERMIT2()`, `caller` on events, new `lockTerminalFor` sig) |
| `src/interfaces/IWETH9.sol` | `src/interfaces/IWETH9.sol` | **Unchanged** (import path updated to OZ) |
| *N/A* | `src/structs/PoolInfo.sol` | **New** |
| *N/A* | `src/libraries/JBSwapLib.sol` | **New** |

> **Cross-repo impact**: `nana-fee-project-deployer-v6` replaced `SwapTerminalDeploymentLib` with `RouterTerminalDeploymentLib`. `nana-permission-ids-v6` replaced `ADD_SWAP_TERMINAL_POOL`/`ADD_SWAP_TERMINAL_TWAP_PARAMS` with `SET_ROUTER_TERMINAL` (29). `nana-buyback-hook-v6` shares the `JBSwapLib` library for sigmoid slippage and V4 swap math.
