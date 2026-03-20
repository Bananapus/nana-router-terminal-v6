# Juicebox Router Terminal

## Purpose

Accept payments in any ERC-20 token (or native ETH), dynamically discover what token the destination project accepts, and route there -- via Uniswap V3/V4 swap, direct forwarding, JB token cashout, or a combination. The router terminal also supports credit-based cashouts where a payer transfers their JB project credits to the terminal for cashout and re-routing.

## Contracts

| Contract | Role |
|----------|------|
| `JBRouterTerminal` | Core terminal: accepts any token, previews exact payment routes with `previewPayFor`, discovers the best route to the destination project's accepted token, swaps via Uniswap V3 or V4, cashes out JB project tokens, and forwards to the primary terminal. Implements `IJBTerminal`, `IJBPermitTerminal`, `IUniswapV3SwapCallback`, `IUnlockCallback`, `IJBRouterTerminal`. |
| `JBRouterTerminalRegistry` | Proxy terminal routing `pay`, `previewPayFor`, and `addToBalanceOf` to a per-project or default `JBRouterTerminal`. Project owners can set and lock their terminal choice. Implements `IJBTerminal` via `IJBRouterTerminalRegistry`. |

## Key Functions

### JBRouterTerminal

| Function | What it does |
|----------|--------------|
| `pay(projectId, token, amount, beneficiary, minReturnedTokens, memo, metadata)` | Accept any token, route to the destination project's accepted token (cashout, swap, wrap/unwrap, or direct), forward to the project's primary terminal. Returns project token count. |
| `previewPayFor(projectId, token, amount, beneficiary, metadata)` | Preview the terminal and mint result that an exact payment route would produce. Reverts for swap routes because the router has no execution-faithful quoter. |
| `addToBalanceOf(projectId, token, amount, shouldReturnHeldFees, memo, metadata)` | Same routing flow as `pay` but calls `terminal.addToBalanceOf(...)` instead of `terminal.pay(...)`. |
| `discoverPool(normalizedTokenIn, normalizedTokenOut) -> IUniswapV3Pool` | Search V3 factory for highest-liquidity pool across 4 fee tiers. Returns the V3 pool (or zero address if V4 was better). |
| `discoverBestPool(normalizedTokenIn, normalizedTokenOut) -> PoolInfo` | Discover best pool across both V3 and V4, comparing in-range liquidity. Returns `PoolInfo` indicating protocol version and pool details. |
| `accountingContextForTokenOf(projectId, token) -> JBAccountingContext` | Returns a dynamically constructed context with 18 decimals and currency = `uint32(uint160(token))`. Does not read from storage. |
| `accountingContextsOf(projectId) -> JBAccountingContext[]` | Always returns an empty array (this terminal accepts any token dynamically). |
| `currentSurplusOf(...) -> uint256` | Always returns 0. This terminal holds no surplus. |
| `uniswapV3SwapCallback(amount0Delta, amount1Delta, data)` | V3 swap callback. Verifies caller is a legitimate pool via the factory. Wraps ETH if needed and transfers input tokens to the pool. |
| `unlockCallback(data) -> bytes` | V4 swap callback. Called by PoolManager during `unlock()`. Executes the swap, settles input, takes output, checks slippage. |
| `supportsInterface(interfaceId) -> bool` | Returns true for `IJBTerminal`, `IJBPermitTerminal`, `IJBRouterTerminal`, `IERC165`, `IJBPermissioned`. |

### JBRouterTerminalRegistry

| Function | What it does |
|----------|--------------|
| `pay(projectId, token, amount, beneficiary, minReturnedTokens, memo, metadata)` | Resolves the terminal for the project (per-project or default), accepts funds, forwards payment. |
| `previewPayFor(projectId, token, amount, beneficiary, metadata)` | Resolves the terminal for the project (per-project or default) and forwards the payment preview. |
| `addToBalanceOf(projectId, token, amount, shouldReturnHeldFees, memo, metadata)` | Same resolution and forwarding but for balance additions. |
| `terminalOf(projectId) -> IJBTerminal` | Returns the terminal for the project, or `defaultTerminal` if none is set. |
| `setTerminalFor(projectId, terminal)` | Route a project to a specific allowed router terminal. Requires `SET_ROUTER_TERMINAL` permission (ID 28). Reverts if locked or terminal not allowed. |
| `lockTerminalFor(projectId, expectedTerminal)` | Lock the terminal choice permanently. If no terminal is explicitly set, the current default is snapshotted. Reverts with `TerminalMismatch` if the resolved terminal does not match `expectedTerminal` (prevents race conditions). Requires `SET_ROUTER_TERMINAL` permission. |
| `allowTerminal(terminal)` | Owner-only: add a terminal to the allowlist. |
| `disallowTerminal(terminal)` | Owner-only: remove a terminal from the allowlist. Also clears `defaultTerminal` if it matches. |
| `setDefaultTerminal(terminal)` | Owner-only: set the default terminal and auto-allow it. |
| `accountingContextForTokenOf(projectId, token)` | Delegates to the resolved terminal. |
| `accountingContextsOf(projectId)` | Delegates to the resolved terminal. |
| `currentSurplusOf(...)` | Always returns 0 (empty implementation). |
| `supportsInterface(interfaceId) -> bool` | Returns true for `IJBRouterTerminalRegistry`, `IJBTerminal`, `IERC165`. |

## Internal Routing Functions (JBRouterTerminal)

| Function | What it does |
|----------|--------------|
| `_route(destProjectId, tokenIn, amount, metadata)` | Core routing logic. Detects JB project tokens, runs `_cashOutLoop` if needed, then resolves output token and converts. |
| `_previewRoute(destProjectId, tokenIn, amount, metadata)` | View mirror of `_route`. Returns the terminal, token, and amount that an exact payment route would use, or marks the route inexact. |
| `_resolveTokenOut(projectId, tokenIn, metadata)` | Priority: 1) `routeTokenOut` metadata override, 2) direct acceptance, 3) NATIVE/WETH equivalence, 4) `_discoverAcceptedToken`. |
| `_discoverAcceptedToken(projectId, tokenIn)` | Iterates all terminals and their accounting contexts for a project. Finds the accepted token with the deepest Uniswap pool. Falls back to the first accepted token if no pool exists. |
| `_convert(tokenIn, tokenOut, amount, projectId, metadata)` | No-op if same token, wrap/unwrap for NATIVE/WETH, or swap via `_handleSwap`. |
| `_handleSwap(projectId, tokenIn, tokenOut, amount, metadata)` | Discovers the best pool, gets a quote, executes the swap (V3 or V4), unwraps output if needed, returns leftover input to payer. |
| `_pickPoolAndQuote(metadata, normalizedTokenIn, amount, normalizedTokenOut)` | Discovers pool, checks for user-provided `quoteForSwap`, otherwise computes TWAP quote (V3) or spot quote (V4) with dynamic slippage. |
| `_cashOutLoop(destProjectId, token, amount, sourceProjectIdOverride, metadata)` | Recursively cashes out JB project tokens. At each step, checks if the destination accepts the reclaimed token. Continues until a non-JB base token is reached or the destination accepts. |
| `_findCashOutPath(sourceProjectId, destProjectId)` | Priority: 1) tokens the destination directly accepts, 2) JB project tokens (recursable), 3) any base token. Only considers terminals that support `IJBCashOutTerminal`. |
| `_getSlippageTolerance(amountIn, liquidity, tokenOut, tokenIn, tick, poolFeeBps)` | Computes sigmoid slippage from `JBSwapLib.calculateImpact` and `JBSwapLib.getSlippageTolerance`. |
| `_bestPoolLiquidity(tokenA, tokenB)` | Scans all V3 fee tiers and V4 pools for the highest in-range liquidity. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `nana-core-v6` | `IJBDirectory`, `IJBTerminal`, `IJBCashOutTerminal`, `IJBProjects`, `IJBPermissions`, `IJBTokens` | Directory lookups (`primaryTerminalOf`, `terminalsOf`), project ownership, permission checks, token discovery, cashout execution |
| `nana-core-v6` | `JBMetadataResolver` | Parsing `quoteForSwap`, `permit2`, `routeTokenOut`, `cashOutSource`, and `cashOutMinReclaimed` metadata from calldata |
| `nana-core-v6` | `JBAccountingContext`, `JBSingleAllowance` | Token accounting and Permit2 allowance structs |
| `nana-core-v6` | `IJBPermitTerminal` | Interface for Permit2 support and the `Permit2AllowanceFailed` event |
| `nana-permission-ids-v6` | `JBPermissionIds` | Permission ID constants: `SET_ROUTER_TERMINAL` (28), `TRANSFER_CREDITS` (13, required by payer for credit cashouts) |
| `@uniswap/v3-core` | `IUniswapV3Pool`, `IUniswapV3Factory`, `IUniswapV3SwapCallback`, `TickMath` | V3 pool swaps, factory pool discovery, tick math |
| `@uniswap/v3-periphery` | `OracleLibrary` | TWAP oracle consultation (`consult`, `getQuoteAtTick`, `getOldestObservationSecondsAgo`) |
| `@uniswap/v4-core` | `IPoolManager`, `IUnlockCallback`, `PoolKey`, `PoolId`, `Currency`, `BalanceDelta`, `SwapParams`, `StateLibrary` | V4 pool swaps, liquidity queries, settle/take flow |
| `@uniswap/permit2` | `IPermit2`, `IAllowanceTransfer` | Gasless token approvals |
| `@openzeppelin/contracts` | `Ownable`, `ERC2771Context`, `SafeERC20`, `Math` | Access control, meta-transactions, safe transfers, sqrt |
| `@prb/math` | `mulDiv` | Safe fixed-point multiplication in JBSwapLib |

## Key Types

| Struct | Fields | Used In |
|--------|--------|---------|
| `PoolInfo` | `bool isV4`, `IUniswapV3Pool v3Pool`, `PoolKey v4Key` | Returned by `discoverBestPool` and used internally by `_discoverPool`, `_pickPoolAndQuote`. Indicates whether the best route is V3 or V4 and stores the pool reference. |
| `JBAccountingContext` | `address token`, `uint8 decimals`, `uint32 currency` | Token accounting contexts for accepted tokens. The router terminal constructs these dynamically with 18 decimals. |
| `JBSingleAllowance` | `uint48 sigDeadline`, `uint160 amount`, `uint48 expiration`, `uint48 nonce`, `bytes signature` | Decoded from `permit2` metadata key for gasless approvals. |

## Constants

### JBRouterTerminal

| Constant | Value | Purpose |
|----------|-------|---------|
| `DEFAULT_TWAP_WINDOW` | `10 minutes` (600 seconds) | Default TWAP oracle window for V3 pool quotes |
| `SLIPPAGE_DENOMINATOR` | `10,000` | Basis points denominator for slippage tolerance |
| `_FEE_TIERS` | `[3000, 500, 10000, 100]` | V3 fee tiers to search (0.3%, 0.05%, 1%, 0.01%) |
| `_V4_FEES` | `[3000, 500, 10000, 100]` | V4 fee tiers to search |
| `_V4_TICK_SPACINGS` | `[60, 10, 200, 1]` | V4 tick spacings paired with fee tiers |

### JBSwapLib

| Constant | Value | Purpose |
|----------|-------|---------|
| `SLIPPAGE_DENOMINATOR` | `10,000` | Basis points denominator |
| `MAX_SLIPPAGE` | `8,800` (88%) | Maximum slippage ceiling |
| `IMPACT_PRECISION` | `1e18` | Precision multiplier for impact calculations |
| `SIGMOID_K` | `5e16` | K parameter for sigmoid curve |

## Errors

### JBRouterTerminal

| Error | When |
|-------|------|
| `JBRouterTerminal_NoRouteFound(uint256 projectId, address tokenIn)` | No accepted token found for the project when iterating all terminals |
| `JBRouterTerminal_TokenNotAccepted(uint256 projectId, address token)` | The `routeTokenOut` metadata override specifies a token the project does not accept |
| `JBRouterTerminal_CallerNotPool(address caller)` | V3 swap callback called by an address that is not a legitimate factory pool |
| `JBRouterTerminal_CallerNotPoolManager(address caller)` | V4 unlock callback called by an address other than the PoolManager |
| `JBRouterTerminal_SlippageExceeded(uint256 amountOut, uint256 minAmountOut)` | Swap output is below the minimum acceptable amount |
| `JBRouterTerminal_NoPoolFound(address tokenIn, address tokenOut)` | No V3 or V4 pool exists for the token pair |
| `JBRouterTerminal_NoCashOutPath(uint256 sourceProjectId, uint256 destProjectId)` | No cashout terminal found for the source project |
| `JBRouterTerminal_NoMsgValueAllowed(uint256 value)` | `msg.value > 0` when paying with an ERC-20 token or using credit cashout |
| `JBRouterTerminal_PermitAllowanceNotEnough(uint256 amount, uint256 allowance)` | Permit2 allowance is less than the payment amount |
| `JBRouterTerminal_NoLiquidity()` | Pool has zero in-range liquidity (TWAP or spot quote would be meaningless) |
| `JBRouterTerminal_NoObservationHistory()` | V3 pool has no TWAP observation history (`oldestObservation == 0`) |
| `JBRouterTerminal_AmountOverflow(uint256 amount)` | Amount exceeds `type(uint128).max` (required by `OracleLibrary.getQuoteAtTick`) |
| `JBRouterTerminal_CashOutLoopLimit()` | Cashout loop exceeded 20 iterations (circular token dependency) |

### JBRouterTerminalRegistry

| Error | When |
|-------|------|
| `JBRouterTerminalRegistry_NoMsgValueAllowed(uint256 value)` | `msg.value > 0` when paying with an ERC-20 |
| `JBRouterTerminalRegistry_PermitAllowanceNotEnough(uint256 amount, uint256 allowanceAmount)` | Permit2 allowance is less than the payment amount |
| `JBRouterTerminalRegistry_TerminalLocked(uint256 projectId)` | Attempting to change terminal after it has been locked |
| `JBRouterTerminalRegistry_TerminalMismatch(IJBTerminal currentTerminal, IJBTerminal expectedTerminal)` | Resolved terminal does not match the `expectedTerminal` passed to `lockTerminalFor` |
| `JBRouterTerminalRegistry_TerminalNotAllowed(IJBTerminal terminal)` | Attempting to set a terminal that is not on the allowlist |
| `JBRouterTerminalRegistry_TerminalNotSet(uint256 projectId)` | Attempting to lock when no terminal is set and no default exists |

## Events

### JBRouterTerminal

| Event | When |
|-------|------|
| `Permit2AllowanceFailed(address indexed token, address indexed owner, bytes reason)` | Permit2 allowance call failed (from `IJBPermitTerminal`). Payment continues using fallback transfer. |

### JBRouterTerminalRegistry

| Event | When |
|-------|------|
| `JBRouterTerminalRegistry_AllowTerminal(IJBTerminal terminal, address caller)` | Terminal added to allowlist |
| `JBRouterTerminalRegistry_DisallowTerminal(IJBTerminal terminal, address caller)` | Terminal removed from allowlist |
| `JBRouterTerminalRegistry_LockTerminal(uint256 indexed projectId, address caller)` | Terminal locked for a project |
| `JBRouterTerminalRegistry_SetDefaultTerminal(IJBTerminal terminal, address caller)` | Default terminal updated |
| `JBRouterTerminalRegistry_SetTerminal(uint256 indexed projectId, IJBTerminal terminal, address caller)` | Terminal set for a project |

## Metadata Keys

| Key | Encoding | Used In | Purpose |
|-----|----------|---------|---------|
| `"quoteForSwap"` | `abi.encode(uint256 minAmountOut)` | `_pickPoolAndQuote` | Caller-provided minimum swap output. Overrides TWAP/spot auto-quote. |
| `"permit2"` | `abi.encode(JBSingleAllowance)` | `_acceptFundsFor` | Permit2 signature for gasless ERC-20 approval. |
| `"routeTokenOut"` | `abi.encode(address tokenOut)` | `_resolveTokenOut` | Force the router to convert to a specific output token. |
| `"cashOutSource"` | `abi.encode(uint256 sourceProjectId, uint256 creditAmount)` | `_acceptFundsFor`, `_route` | Cash out credits from `sourceProjectId`. Payer must grant `TRANSFER_CREDITS` (13) to the router. |
| `"cashOutMinReclaimed"` | `abi.encode(uint256 minTokensReclaimed)` | `_cashOutLoop` | Minimum tokens reclaimed from first cashout step. |

## Gotchas

- **Dynamic accounting contexts**: `accountingContextsOf()` returns an empty array and `accountingContextForTokenOf()` constructs contexts on the fly with 18 decimals. This is intentional -- the router accepts any token.
- **No surplus, no migration**: `currentSurplusOf()` always returns 0. `migrateBalanceOf()` always returns 0. The terminal is stateless between transactions.
- Unlike `JBMultiTerminal` which has a fixed `TOKEN_OUT`, the router terminal dynamically discovers what token each project accepts. This makes it a universal entry point.
- Pool discovery runs at call time -- it searches V3 and V4 pools across 4 fee tiers each (8 pools total). The best pool (by in-range liquidity) wins. This is gas-intensive but ensures optimal routing.
- When `tokenIn == NATIVE_TOKEN`, the terminal wraps ETH to WETH before swapping. When the output is `NATIVE_TOKEN`, it unwraps WETH after swapping.
- The `receive()` function accepts ETH from any sender. This is necessary because ETH arrives from WETH unwraps, cashout reclaims from project terminals, and V4 PoolManager takes. The terminal handles all ETH within the same transaction.
- **V3 TWAP**: Reverts with `JBRouterTerminal_NoObservationHistory()` when a V3 pool has no observation history. The TWAP window is capped by the pool's oldest observation if shorter than 10 minutes.
- **V4 spot price**: V4 vanilla pools have no built-in TWAP oracle. The terminal uses the current spot tick with the same sigmoid slippage formula.
- **V4 requires cancun EVM**: Chains without EIP-1153 (transient storage) cannot use V4 routing. If `POOL_MANAGER` is `address(0)`, V4 discovery is skipped entirely.
- **Preview exactness**: `previewPayFor()` is only exposed for routes the router can preview faithfully. Swap routes revert with `JBRouterTerminal_PreviewNotAccurateForRoute()` rather than returning a misleading value.
- The `JBRouterTerminalRegistry` handles token custody during delegation -- it transfers tokens from the payer to itself, then approves and forwards to the underlying terminal.
- `_msgSender()` (ERC-2771) is used instead of `msg.sender` for meta-transaction compatibility in both contracts.
- The `JBSwapLib` library contains slippage tolerance math (sigmoid formula), price impact estimation, and V3-compatible `sqrtPriceLimitX96` calculation. It does not contain swap execution logic.
- **Leftover handling**: After a swap, leftover input tokens (from partial fills where the price limit was hit) are returned to the payer. For native token inputs, any remaining raw ETH is wrapped to WETH first so the leftover check catches it.
- **Credit cashouts**: When using `cashOutSource` metadata, the payer must have granted `TRANSFER_CREDITS` permission (ID 13) to the router terminal for the source project. The router calls `TOKENS.transferCreditsFrom()` to pull credits.
- **Cashout loop depth**: The `_cashOutLoop` iterates through JB project token chains with a cap of 20 iterations (`_MAX_CASHOUT_ITERATIONS`). Exceeding this limit reverts with `JBRouterTerminal_CashOutLoopLimit()`.
- **V3 callback verification**: The `uniswapV3SwapCallback` verifies the caller by reading the pool's `fee()` and checking `FACTORY.getPool()`. This is standard V3 security.
- **V4 amount overflow**: Both `_getV3TwapQuote` and `_getV4SpotQuote` revert if `amount > type(uint128).max` because `OracleLibrary.getQuoteAtTick` requires `uint128`.
- **Disallowing the default terminal**: `disallowTerminal()` clears `defaultTerminal` if it matches the terminal being disallowed.
- **Locking snapshots default**: `lockTerminalFor(projectId, expectedTerminal)` snapshots the current `defaultTerminal` into `_terminalOf[projectId]` if no explicit terminal was set, preventing future default changes from affecting locked projects. The `expectedTerminal` parameter prevents race conditions where the default changes between transaction submission and execution.
- **Cashout loop limit**: `_cashOutLoop` is capped at 20 iterations. Circular JB token dependencies (A -> B -> A) will revert with `CashOutLoopLimit` instead of consuming all gas.

## Example Integration

```solidity
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// --- Basic payment (auto-routing, auto-quote) ---
// Pay project 1 with USDC. The router discovers the project accepts ETH,
// finds the best USDC/WETH pool across V3 and V4, swaps, and forwards.
IERC20(usdc).approve(address(routerTerminal), 1000e6);
routerTerminal.pay(
    1,           // projectId
    usdc,        // token (USDC)
    1000e6,      // amount
    beneficiary, // who receives project tokens
    0,           // minReturnedTokens
    "USDC payment via router",
    ""           // empty metadata = use auto TWAP/spot quote
);

// --- Payment with explicit quote ---
bytes memory quoteMetadata = JBMetadataResolver.addToMetadata({
    originalMetadata: "",
    id: JBMetadataResolver.getId("quoteForSwap"),
    data: abi.encode(uint256(0.5 ether)) // minimum 0.5 ETH from swap
});

IERC20(usdc).approve(address(routerTerminal), 1000e6);
routerTerminal.pay(
    1, usdc, 1000e6, beneficiary, 0, "with quote", quoteMetadata
);

// --- Payment with explicit output token ---
bytes memory routeMetadata = JBMetadataResolver.addToMetadata({
    originalMetadata: "",
    id: JBMetadataResolver.getId("routeTokenOut"),
    data: abi.encode(dai) // force conversion to DAI
});

IERC20(usdc).approve(address(routerTerminal), 1000e6);
routerTerminal.pay(
    1, usdc, 1000e6, beneficiary, 0, "force DAI", routeMetadata
);

// --- Native ETH payment ---
routerTerminal.pay{value: 1 ether}(
    1,
    0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, // NATIVE_TOKEN
    1 ether,
    beneficiary,
    0,
    "ETH payment",
    ""
);

// --- Registry: project owner sets terminal ---
registry.setTerminalFor(projectId, preferredTerminal);
registry.lockTerminalFor(projectId, preferredTerminal); // permanent, reverts if terminal changed
```
