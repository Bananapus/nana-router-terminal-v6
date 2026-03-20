# nana-router-terminal-v6 -- User Journeys

Every path a user or integrated contract can take through the router terminal.

The journeys below describe payment routing behavior. They should not be read as proof that the router terminal or
registry is a truthful accounting source for arbitrary tokens. Both surfaces report synthetic accounting contexts with
`decimals = 18`, so any integration that depends on real token decimals must query a real terminal instead.

---

## Journey 1: Pay a Project Through the Router Terminal

A payer sends any token to a project. The router discovers what the project accepts and converts automatically.

### Entry Point

```solidity
function pay(
    uint256 projectId,
    address token,
    uint256 amount,
    address beneficiary,
    uint256 minReturnedTokens,
    string calldata memo,
    bytes calldata metadata
) external payable returns (uint256 beneficiaryTokenCount)
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `projectId` | `uint256` | Destination project ID |
| `token` | `address` | Token being paid. Use `JBConstants.NATIVE_TOKEN` (0x...EEEe) for ETH. |
| `amount` | `uint256` | Amount of tokens. Ignored for native token (uses `msg.value`). |
| `beneficiary` | `address` | Receives project tokens minted by destination terminal |
| `minReturnedTokens` | `uint256` | Minimum project tokens expected. Reverts if destination mints fewer. |
| `memo` | `string` | Passed to destination terminal's payment event |
| `metadata` | `bytes` | JBMetadataResolver-encoded. Optional keys: `permit2`, `quoteForSwap`, `routeTokenOut`, `cashOutSource`, `cashOutMinReclaimed` |

### Metadata Keys

| Key ID | Type | Purpose |
|--------|------|---------|
| `permit2` | `JBSingleAllowance` | Permit2 signature for ERC-20 token approval |
| `quoteForSwap` | `uint256` | User-provided minimum swap output. Bypasses TWAP/spot calculation. Recommended for V4 swaps. |
| `routeTokenOut` | `address` | Force the router to convert to this specific token (must be accepted by destination). |
| `cashOutSource` | `(uint256 sourceProjectId, uint256 creditAmount)` | Pay with JB project credits instead of an ERC-20 token. |
| `cashOutMinReclaimed` | `uint256` | Minimum tokens reclaimed in the first cashout step. |

### State Changes (by path)

#### Path A: Direct Forwarding (project accepts tokenIn)

1. `_acceptFundsFor()` -- transfers tokens from payer to router via ERC-20 `transferFrom`, Permit2, or accepts `msg.value`
2. `_route()` calls `_resolveTokenOut()` -- finds `primaryTerminalOf(projectId, tokenIn)` returns a terminal
3. `_convert()` is a no-op (same token)
4. `_beforeTransferFor()` -- sets ERC-20 allowance for destination terminal (or returns amount as `msg.value` for native)
5. `destTerminal.pay()` -- forwards tokens, returns minted project tokens

State touched: Only the destination terminal's state. Router holds zero tokens after completion.

#### Path B: Wrap/Unwrap (native <-> WETH equivalence)

1. `_acceptFundsFor()` -- accepts funds
2. `_route()` -> `_resolveTokenOut()` -- project does not accept `tokenIn` directly, but accepts the native/wrapped equivalent
3. `_convert()` -- calls `WETH.deposit()` or `WETH.withdraw()` to wrap/unwrap
4. Forward to destination terminal

State touched: WETH balance changes transiently. Router ends at zero.

#### Path C: Uniswap Swap (V3 or V4)

1. `_acceptFundsFor()` -- accepts funds
2. `_route()` -> `_resolveTokenOut()` -> `_discoverAcceptedToken()` -- finds the accepted token with the best Uniswap pool liquidity
3. `_convert()` -> `_handleSwap()` -> `_executeSwap()`:
   - `_pickPoolAndQuote()` discovers the best pool and computes `minAmountOut`. For V4 pools, token addresses are normalized (WETH → `address(0)`) before querying OracleLibrary to match V4's native ETH convention.
   - **V3:** `pool.swap()` with callback `uniswapV3SwapCallback()` to supply input tokens
   - **V4:** `POOL_MANAGER.unlock()` -> `unlockCallback()` -> `POOL_MANAGER.swap()` + settle/take. Settlement via `_settleV4` automatically unwraps WETH to native ETH when the pool uses `address(0)` for its native currency.
4. Leftover input tokens from partial fills returned to payer
5. If output is native token, unwrap WETH
6. Forward converted tokens to destination terminal

State touched: Uniswap pool state (tick, liquidity positions). Router ends at zero.

#### Path D: JB Token Cashout Chain

1. `_acceptFundsFor()` -- accepts JB project tokens (ERC-20 or credits via `cashOutSource` metadata)
2. `_route()` detects input is a JB project token (via `TOKENS.projectIdOf()` or metadata override)
3. `_cashOutLoop()` iterates:
   - Calls `_findCashOutPath()` to find which terminal to cash out from and which token to reclaim
   - Calls `cashOutTerminal.cashOutTokensOf()` -- burns project tokens, receives reclaimable token
   - If reclaimable token is accepted by destination, loop exits
   - If reclaimable token is another JB project token, loop continues
   - If reclaimable token is a base token (ETH, USDC, etc.), loop exits
4. If the reclaimed token is not directly accepted by destination, falls through to Path C (swap)
5. Forward final token to destination terminal

State touched: Source project's token supply (burned), terminal balances. Potentially Uniswap pool state if a swap follows.

### Edge Cases

- **Token not accepted by any path:** Reverts with `JBRouterTerminal_NoRouteFound(projectId, tokenIn)` if no accepted token or pool is found.
- **No Uniswap pool:** Reverts with `JBRouterTerminal_NoPoolFound(tokenIn, tokenOut)` if the destination accepts a token but no V3 or V4 pool exists for the pair.
- **Circular cashout dependency:** Reverts with `JBRouterTerminal_CashOutLoopLimit()` after 20 iterations.
- **Zero liquidity pool:** Reverts with `JBRouterTerminal_NoLiquidity()`.
- **No TWAP history:** Reverts with `JBRouterTerminal_NoObservationHistory()` for V3 pools with zero observations.
- **Slippage exceeded:** Reverts with `JBRouterTerminal_SlippageExceeded(amountOut, minAmountOut)`.
- **Amount overflow:** Reverts with `JBRouterTerminal_AmountOverflow(amount)` if swap amount exceeds `type(uint128).max`, or if Permit2 transfer amount exceeds `type(uint160).max`.
- **ETH sent with ERC-20 payment:** Reverts with `JBRouterTerminal_NoMsgValueAllowed(value)`.
- **Router is destination terminal:** If `primaryTerminalOf` returns the router itself, it is skipped to prevent infinite recursion (line 625).
- **Destination terminal reverts:** The entire transaction reverts atomically. No tokens are stuck.
- **Destination terminal accepts tokens but misbehaves:** If it does not revert but does not credit the project, tokens are lost. No recovery mechanism.

---

## Journey 2: Add to a Project's Balance Through the Router Terminal

Identical to Journey 1 except the final call is `addToBalanceOf` instead of `pay`. Adds funds without minting project tokens.

### Entry Point

```solidity
function addToBalanceOf(
    uint256 projectId,
    address token,
    uint256 amount,
    bool shouldReturnHeldFees,
    string calldata memo,
    bytes calldata metadata
) external payable
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `projectId` | `uint256` | Destination project ID |
| `token` | `address` | Token being paid. Use `JBConstants.NATIVE_TOKEN` for ETH. |
| `amount` | `uint256` | Amount of tokens. Ignored for native token (uses `msg.value`). |
| `shouldReturnHeldFees` | `bool` | Passed to destination terminal to return held fees proportionally |
| `memo` | `string` | Passed to destination terminal's event |
| `metadata` | `bytes` | Same metadata keys as `pay()` |

### State Changes

Same routing logic as Journey 1 (Paths A-D). The only difference is the final forwarding call:

```solidity
destTerminal.addToBalanceOf{value: payValue}({
    projectId: projectId,
    token: token,
    amount: amount,
    shouldReturnHeldFees: shouldReturnHeldFees,
    memo: memo,
    metadata: metadata
});
```

No project tokens are returned to the beneficiary. The destination project's balance increases.

### Edge Cases

Same as Journey 1. Additionally:
- No `beneficiary` or `minReturnedTokens` parameters. This path cannot revert on minimum token output from the destination terminal (it mints nothing).

---

## Journey 2A: Preview a Payment Through the Router Terminal

The caller asks what a payment would do without moving funds.

### Entry Point

```solidity
function previewPayFor(
    uint256 projectId,
    address token,
    uint256 amount,
    address beneficiary,
    bytes calldata metadata
)
    external
    view
    returns (
        JBRuleset memory ruleset,
        uint256 beneficiaryTokenCount,
        uint256 reservedTokenCount,
        JBPayHookSpecification[] memory hookSpecifications
    )
```

### Behavior

1. `_previewAcceptFundsFor()` mirrors the router's source-of-funds logic in view context.
2. `_previewRoute()` mirrors `_route()` and determines which terminal would ultimately receive the payment.
3. If the route is exact, the router forwards `previewPayFor()` to that destination terminal.
4. If the route would require a swap, the call reverts with `JBRouterTerminal_PreviewNotAccurateForRoute()`.

### Exactness Boundary

- **Direct forwarding:** exact
- **Native/WETH wrap-unwrap:** exact
- **Cashout-only routes:** exact when the downstream cashout terminal exposes an exact preview surface
- **Swap routes:** not previewed today; the router reverts rather than returning a best-effort value

---

## Journey 3: Pay a Project Through the Registry

The registry resolves which router terminal instance a project uses, then forwards the payment.

### Entry Point

```solidity
// On JBRouterTerminalRegistry:
function pay(
    uint256 projectId,
    address token,
    uint256 amount,
    address beneficiary,
    uint256 minReturnedTokens,
    string calldata memo,
    bytes calldata metadata
) external payable returns (uint256)
```

### State Changes

1. Resolve terminal: `_terminalOf[projectId]`, falling back to `defaultTerminal`
2. `_acceptFundsFor()` -- accepts tokens (native or ERC-20 via Permit2/transferFrom). NOTE: does NOT use balance-delta accounting.
3. `_beforeTransferFor()` -- sets allowance for resolved terminal
4. `terminal.pay()` -- forwards to the resolved router terminal (which then does its own routing)

### Edge Cases

- **No terminal set and no default:** The resolved terminal is `address(0)`. The subsequent `terminal.pay()` call will revert.
- **Fee-on-transfer tokens:** The registry returns the user-supplied `amount` (not the actual received amount). If fewer tokens arrived due to transfer fees, the forwarding call may revert or behave incorrectly.
- **Terminal disallowed after being set:** A project's explicit terminal remains set even if `disallowTerminal()` is called later. Only the default is cleared.

---

## Journey 3A: Preview a Payment Through the Registry

The registry resolves which router terminal instance a project uses, then forwards the preview.

### Entry Point

```solidity
// On JBRouterTerminalRegistry:
function previewPayFor(
    uint256 projectId,
    address token,
    uint256 amount,
    address beneficiary,
    bytes calldata metadata
)
    external
    view
    returns (
        JBRuleset memory ruleset,
        uint256 beneficiaryTokenCount,
        uint256 reservedTokenCount,
        JBPayHookSpecification[] memory hookSpecifications
    )
```

### State Changes

None. The registry resolves `_terminalOf[projectId]`, falling back to `defaultTerminal`, then forwards `previewPayFor()` to the resolved router terminal.

### Edge Cases

- **No terminal set and no default:** The preview will revert when forwarded to `address(0)`.
- **Inexact downstream route:** The resolved router terminal may revert with `JBRouterTerminal_PreviewNotAccurateForRoute()`.

---

## Journey 4: Add to a Project's Balance Through the Registry

### Entry Point

```solidity
// On JBRouterTerminalRegistry:
function addToBalanceOf(
    uint256 projectId,
    address token,
    uint256 amount,
    bool shouldReturnHeldFees,
    string calldata memo,
    bytes calldata metadata
) external payable
```

### State Changes

Same as Journey 3 but calls `terminal.addToBalanceOf()` instead of `terminal.pay()`.

---

## Journey 5: Configure a Project's Router Terminal

A project owner assigns which router terminal instance handles their project's payments.

### Entry Point

```solidity
// On JBRouterTerminalRegistry:
function setTerminalFor(uint256 projectId, IJBTerminal terminal) external
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `projectId` | `uint256` | The project to configure |
| `terminal` | `IJBTerminal` | The router terminal to assign. Must be in the allowlist. |

### Prerequisites

- Caller must be the project owner (`PROJECTS.ownerOf(projectId)`) or have `JBPermissionIds.SET_ROUTER_TERMINAL` (28) permission.
- Terminal must be in the allowlist (`isTerminalAllowed[terminal]` must be true).
- Project must not be locked (`hasLockedTerminal[projectId]` must be false).

### State Changes

1. Permission check via `_requirePermissionFrom()`
2. `isTerminalAllowed[terminal]` check
3. `_terminalOf[projectId] = terminal`
4. Emits `JBRouterTerminalRegistry_SetTerminal(projectId, terminal, caller)`

### Edge Cases

- **Terminal not in allowlist:** Reverts with `JBRouterTerminalRegistry_TerminalNotAllowed(terminal)`.
- **Project locked:** Reverts with `JBRouterTerminalRegistry_TerminalLocked(projectId)`.
- **No permission:** Reverts with JBPermissioned's unauthorized error.
- **Setting to a different allowed terminal:** Overwrites the previous assignment freely (as long as not locked).

---

## Journey 6: Lock a Project's Router Terminal

Permanently freeze a project's router terminal assignment. Prevents the registry owner from redirecting payments by changing the default.

### Entry Point

```solidity
// On JBRouterTerminalRegistry:
function lockTerminalFor(uint256 projectId, IJBTerminal expectedTerminal) external
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `projectId` | `uint256` | The project to lock |
| `expectedTerminal` | `IJBTerminal` | Must match the current resolved terminal. Race condition guard. |

### Prerequisites

- Caller must be the project owner or have `SET_ROUTER_TERMINAL` permission.
- The resolved terminal (explicit or default) must not be `address(0)`.
- The resolved terminal must match `expectedTerminal`.

### State Changes

1. Permission check
2. Resolve current terminal: `_terminalOf[projectId]` or `defaultTerminal`
3. If using default, snapshot it: `_terminalOf[projectId] = defaultTerminal`
4. Verify `terminal == expectedTerminal`
5. `hasLockedTerminal[projectId] = true`
6. Emits `JBRouterTerminalRegistry_LockTerminal(projectId, caller)`

### Edge Cases

- **No terminal resolvable:** Reverts with `JBRouterTerminalRegistry_TerminalNotSet(projectId)` if both explicit and default are `address(0)`.
- **Race condition -- default changed between submission and mining:** If `expectedTerminal` does not match the resolved terminal, reverts with `JBRouterTerminalRegistry_TerminalMismatch(currentTerminal, expectedTerminal)`. This prevents accidental lock to the wrong terminal.
- **Already locked:** Technically, calling `lockTerminalFor` on an already-locked project will succeed (it just sets `hasLockedTerminal` to `true` again, which is a no-op). The terminal cannot change because `setTerminalFor` already blocks.
- **Irreversibility:** There is no `unlockTerminalFor()`. Once locked, the assignment is permanent.

---

## Journey 7: Registry Owner Administration

The registry owner manages the allowlist and default terminal.

### Allow a Terminal

```solidity
function allowTerminal(IJBTerminal terminal) external onlyOwner
```

Sets `isTerminalAllowed[terminal] = true`. Emits `JBRouterTerminalRegistry_AllowTerminal(terminal, caller)`.

### Disallow a Terminal

```solidity
function disallowTerminal(IJBTerminal terminal) external onlyOwner
```

Sets `isTerminalAllowed[terminal] = false`. If the disallowed terminal is the current `defaultTerminal`, clears the default to `address(0)`. Emits `JBRouterTerminalRegistry_DisallowTerminal(terminal, caller)`.

**Note:** Disallowing a terminal does NOT remove it from projects that have explicitly set it via `setTerminalFor()`. Those projects continue using the disallowed terminal until they change it (if not locked).

### Set Default Terminal

```solidity
function setDefaultTerminal(IJBTerminal terminal) external onlyOwner
```

Reverts if `terminal == address(0)`. Sets `defaultTerminal = terminal` and auto-allows it (`isTerminalAllowed[terminal] = true`). Emits `JBRouterTerminalRegistry_SetDefaultTerminal(terminal, caller)`.

**Impact:** All projects without an explicit terminal assignment or lock are silently migrated to the new default. This is the highest-impact admin action.

### State Changes Summary

| Action | State Modified | Side Effects |
|--------|---------------|-------------|
| `allowTerminal(t)` | `isTerminalAllowed[t] = true` | None |
| `disallowTerminal(t)` | `isTerminalAllowed[t] = false` | Clears `defaultTerminal` if it matches `t` |
| `setDefaultTerminal(t)` | `defaultTerminal = t`, `isTerminalAllowed[t] = true` | Redirects all unlocked projects without explicit assignment |

### Edge Cases

- **Disallow the default:** Default is cleared to `address(0)`. All projects relying on the default now have no terminal. Payments through the registry will revert.
- **Allow and set in one call:** `setDefaultTerminal()` auto-allows, so no separate `allowTerminal()` call is needed.
- **Disallow a terminal used by locked projects:** The locked project's `_terminalOf` mapping is unaffected. The terminal continues to work for that project regardless of allowlist status.

---

## Journey 8: Pay with JB Project Credits

A holder pays a destination project using credits (internal token balance) from another JB project. This avoids needing to claim credits as ERC-20 first.

### Entry Point

`JBRouterTerminal.pay()` with `cashOutSource` metadata.

### Metadata Required

```solidity
bytes memory metadata = JBMetadataResolver.addToMetadata({
    originalMetadata: bytes(""),
    id: JBMetadataResolver.getId("cashOutSource"),
    data: abi.encode(sourceProjectId, creditAmount)
});
```

### Prerequisites

- Payer must have granted `TRANSFER_CREDITS` permission to the router terminal for `sourceProjectId`.
- Payer must hold at least `creditAmount` credits for `sourceProjectId`.

### State Changes

1. `_acceptFundsFor()` detects `cashOutSource` metadata
2. Calls `TOKENS.transferCreditsFrom(holder, sourceProjectId, routerTerminal, creditAmount)` -- transfers credits to the router
3. Credits are now held by the router as the source project's tokens
4. `_route()` enters the JB token cashout path (Path D from Journey 1)
5. `_cashOutLoop()` cashes out the credits via source project's terminal
6. Reclaimed tokens are converted and forwarded to destination project

### Edge Cases

- **ETH sent with credit payment:** Reverts with `JBRouterTerminal_NoMsgValueAllowed(value)` -- credits do not use `msg.value`.
- **Insufficient credits:** `TOKENS.transferCreditsFrom()` reverts.
- **No TRANSFER_CREDITS permission:** `TOKENS.transferCreditsFrom()` reverts.
- **Source project has no cashout terminal:** `_findCashOutPath()` reverts with `JBRouterTerminal_NoCashOutPath(sourceProjectId, destProjectId)`.

---

## Journey 9: Discover Available Pools (Off-Chain Query)

Front-ends and integrators can query which Uniswap pools the router would use for a given token pair.

### Entry Points

```solidity
// Best pool across V3 and V4:
function discoverBestPool(
    address normalizedTokenIn,
    address normalizedTokenOut
) external view returns (PoolInfo memory pool)

// V3-only pool (returns address(0) if best pool is V4):
function discoverPool(
    address normalizedTokenIn,
    address normalizedTokenOut
) external view returns (IUniswapV3Pool pool)
```

### Parameters

Both functions take **normalized** token addresses -- use the WETH address instead of `NATIVE_TOKEN` sentinel.

### Return Values

`discoverBestPool` returns a `PoolInfo` struct:
- `isV4`: Whether the best pool is V4
- `v3Pool`: The V3 pool reference (valid when `isV4 == false`)
- `v4Key`: The V4 pool key (valid when `isV4 == true`)

`discoverPool` returns only the V3 pool. If the best pool is V4, returns `address(0)`.

### Edge Cases

- **No pool exists:** Both functions revert with `JBRouterTerminal_NoPoolFound(normalizedTokenIn, normalizedTokenOut)`.
- **Using NATIVE_TOKEN sentinel:** Will not find pools. Callers must use the WETH address.
- **V4 unavailable (POOL_MANAGER == address(0)):** V4 search is skipped. Only V3 pools are returned.
