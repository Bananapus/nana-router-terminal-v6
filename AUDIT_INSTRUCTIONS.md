# nana-router-terminal-v6 -- Audit Instructions

Target: experienced Solidity auditors reviewing the Juicebox V6 router terminal.

## Architecture Overview

The router terminal accepts any token and dynamically discovers what each destination Juicebox project accepts. It then routes the payment there via direct forwarding, Uniswap swap (V3 or V4), JB token cashout, or a combination. It is stateless between transactions -- it holds no persistent balances, no queued operations, no pending state.

Two contracts. One library. One struct.

### Contract Table

| Contract | Lines | Role |
|----------|-------|------|
| `JBRouterTerminal` | ~1,672 | Core routing engine. Accepts any token, discovers destination project's accepted token, converts via wrap/unwrap, Uniswap V3 swap, Uniswap V4 swap, or JB token cashout chain, then forwards to destination terminal. Implements `IJBTerminal`, `IJBPermitTerminal`, `IUniswapV3SwapCallback`, `IUnlockCallback`. |
| `JBRouterTerminalRegistry` | ~514 | Maps projects to their preferred router terminal instance. Owner-managed allowlist of terminals. Default terminal fallback. Lock terminal pattern for immutability. Implements `IJBTerminal`. |
| `JBSwapLib` (library) | ~161 | Continuous sigmoid slippage tolerance calculation. Price impact estimation. `sqrtPriceLimitX96` computation from input/output amounts. |
| `PoolInfo` (struct) | ~14 | Tagged union: `{isV4, v3Pool, v4Key}`. Carries the winning pool from discovery. |

### Dependency Graph

```
JBRouterTerminal
  ├── JBPermissioned (nana-core-v6) -- permission checks
  ├── Ownable (OZ) -- owner management (unused operationally)
  ├── ERC2771Context (OZ) -- meta-transactions
  ├── IJBTerminal -- terminal interface
  ├── IJBPermitTerminal -- Permit2 support
  ├── IUniswapV3SwapCallback -- V3 swap callback
  ├── IUnlockCallback -- V4 swap callback
  ├── JBSwapLib -- slippage math
  ├── JBDirectory -- terminal/controller lookup
  ├── JBTokens -- credit transfers, projectIdOf lookups
  ├── IUniswapV3Factory -- V3 pool discovery & verification
  ├── IPoolManager -- V4 swap execution & pool state reads
  ├── IPermit2 -- token transfer with Permit2
  └── IWETH9 -- wrap/unwrap native token

JBRouterTerminalRegistry
  ├── JBPermissioned -- permission checks
  ├── Ownable -- owner-only admin (allow/disallow/setDefault)
  ├── ERC2771Context -- meta-transactions
  ├── IJBTerminal -- forwards pay/addToBalanceOf
  └── IPermit2 -- token transfer with Permit2
```

### Immutable State (JBRouterTerminal)

| Name | Type | Purpose |
|------|------|---------|
| `DIRECTORY` | `IJBDirectory` | Project terminal/controller lookup |
| `PROJECTS` | `IJBProjects` | ERC-721 project ownership |
| `TOKENS` | `IJBTokens` | Credit transfers, token-to-project mapping |
| `FACTORY` | `IUniswapV3Factory` | V3 pool discovery and callback verification |
| `POOL_MANAGER` | `IPoolManager` | V4 swap execution (can be `address(0)` if V4 unavailable) |
| `PERMIT2` | `IPermit2` | Token transfer utility |
| `WETH` | `IWETH9` | Native token wrapping/unwrapping |

### Mutable State (JBRouterTerminalRegistry)

| Name | Visibility | Purpose |
|------|-----------|---------|
| `defaultTerminal` | `public` | Fallback terminal for projects without explicit assignment |
| `hasLockedTerminal` | `public mapping` | Per-project lock flag (irreversible) |
| `isTerminalAllowed` | `public mapping` | Allowlist of terminals the owner has approved |
| `_terminalOf` | `internal mapping` | Per-project explicit terminal assignment |

## V3/V4 Pool Routing Mechanics

### Pool Discovery

`_discoverPool(normalizedTokenIn, normalizedTokenOut)` searches 8 pools total:

**V3 (4 fee tiers):** 3000 (0.3%), 500 (0.05%), 10000 (1%), 100 (0.01%). Each is looked up via `FACTORY.getPool()`. Liquidity read via `pool.liquidity()`.

**V4 (4 fee/tickSpacing pairs):** 3000/60, 500/10, 10000/200, 100/1. Each is looked up via `POOL_MANAGER.getSlot0(key.toId())` -- a zero `sqrtPriceX96` means the pool does not exist. Liquidity read via `POOL_MANAGER.getLiquidity()`.

The pool with the highest in-range liquidity wins. If `POOL_MANAGER == address(0)`, V4 search is skipped entirely.

### Quote Computation

Quote priority in `_pickPoolAndQuote()`:

1. **User-provided quote** -- If `quoteForSwap` metadata key is present, its value is used as `minAmountOut` directly. This is the recommended path for all swaps, especially V4.
2. **V3 TWAP** -- `_getV3TwapQuote()` uses `OracleLibrary.consult()` with a 10-minute window (capped to oldest available observation). Computes `minAmountOut = twapQuote * (1 - sigmoidSlippage)`.
3. **V4 spot price** -- `_getV4SpotQuote()` reads instantaneous tick from `getSlot0()`. Same sigmoid slippage formula applied. This is manipulable within a single block.

### Sigmoid Slippage Formula

```
impact = amountIn * PRECISION / liquidity * (sqrtP or 1/sqrtP)
tolerance = minSlippage + (MAX_SLIPPAGE - minSlippage) * impact / (impact + SIGMOID_K)
```

Where:
- `minSlippage = max(poolFee + 100 bps, 200 bps)` -- floor of 2%
- `MAX_SLIPPAGE = 8800 bps` -- ceiling of 88%
- `SIGMOID_K = 5e16` -- steepness parameter
- `IMPACT_PRECISION = 1e18`

### Swap Execution

**V3 path:** Direct `pool.swap()` call. Callback `uniswapV3SwapCallback()` wraps ETH if needed and transfers input tokens to the pool. Callback is verified by computing `FACTORY.getPool(tokenA, tokenB, fee)` and checking it matches `msg.sender`.

**V4 path:** `POOL_MANAGER.unlock(data)` triggers `unlockCallback()`. Inside the callback: `POOL_MANAGER.swap()` executes the trade, `_settleV4()` pays the input, `_takeV4()` receives the output. For native ETH output, received ETH is immediately wrapped to WETH (downstream `_handleSwap` unwraps if the destination needs native token). Callback verified by `msg.sender == address(POOL_MANAGER)`.

### Leftover Handling

After a swap, `_handleSwap()` measures the balance delta of the input token. If the swap was a partial fill (sqrtPriceLimit hit), leftover input tokens are returned to `_msgSender()`. For native token inputs, any remaining raw ETH is wrapped to WETH before the delta check, then unwrapped for the refund.

## Cashout Loop

When the input token is a JB project token (detected via `TOKENS.projectIdOf()` or `cashOutSource` metadata), the router enters `_cashOutLoop()`:

1. Check if the destination project directly accepts the current token. If yes, return.
2. Determine the source project ID (from metadata override or token lookup).
3. Call `_findCashOutPath()` which searches source project terminals for:
   - **Priority 1:** A reclaimable token the destination directly accepts.
   - **Priority 2:** A reclaimable JB project token (can recurse).
   - **Priority 3:** Any base token (the router will swap it later).
4. Execute `cashOutTerminal.cashOutTokensOf()` to reclaim tokens.
5. Loop back to step 1 with the reclaimed token.

**Iteration cap:** `_MAX_CASHOUT_ITERATIONS = 20`. Exceeding this reverts with `JBRouterTerminal_CashOutLoopLimit()`.

**Slippage:** The `cashOutMinReclaimed` metadata value is applied only to the first cashout step. Subsequent steps have zero per-step minimum. The final output amount is validated by the destination terminal's `minReturnedTokens` parameter.

**Circular dependency:** If token A cashes out to token B and token B cashes out to token A, the loop hits the 20-iteration cap and reverts cleanly (no fund loss, only gas wasted).

## Lock Terminal Pattern

The registry implements a two-phase terminal assignment:

1. **Set:** `setTerminalFor(projectId, terminal)` -- requires `SET_ROUTER_TERMINAL` permission and terminal must be in the allowlist. Can be changed freely while unlocked.

2. **Lock:** `lockTerminalFor(projectId, expectedTerminal)` -- requires `SET_ROUTER_TERMINAL` permission. The `expectedTerminal` parameter is a race condition guard: if the resolved terminal (explicit or default) does not match, the call reverts with `TerminalMismatch`. Once locked, `hasLockedTerminal[projectId] = true` and `setTerminalFor()` reverts permanently.

**Default snapshot on lock:** If a project has no explicit terminal at lock time, the current `defaultTerminal` is snapshotted into `_terminalOf[projectId]` before locking. This insulates the project from future default changes.

**Irreversibility:** There is no `unlockTerminalFor()`. Locking is permanent.

## Fee-on-Transfer Token Risks

**JBRouterTerminal:** Uses balance-delta accounting in `_acceptFundsFor()` (lines 569-575). Measures `balanceBefore` and `balanceAfter` the transfer, returning the actual amount received. This correctly handles fee-on-transfer tokens at the acceptance stage. However, the amount forwarded to the destination terminal is the delta, which may differ from what the destination terminal expects if it also performs balance-delta checks.

**JBRouterTerminalRegistry:** Does NOT use balance-delta accounting in `_acceptFundsFor()` (line 432). It returns the user-supplied `amount` directly. If a fee-on-transfer token is used through the registry, the forwarded amount will exceed actual tokens received, causing a downstream revert or incorrect accounting.

**Audit focus:** Verify that the registry's `_acceptFundsFor` cannot be exploited with fee-on-transfer tokens. The comment on lines 466-468 states these are "not supported by design" -- confirm this is documented clearly enough and that no path silently loses funds.

## uint160 Permit2 Truncation Risk

Both contracts cast `amount` to `uint160` when falling through to `PERMIT2.transferFrom()`:

- `JBRouterTerminal._transferFrom()` line 944: `if (amount > type(uint160).max) revert JBRouterTerminal_AmountOverflow(amount);`
- `JBRouterTerminalRegistry._transferFrom()` line 510: `if (amount > type(uint160).max) revert JBRouterTerminalRegistry_AmountOverflow();`

Both contracts now revert before truncation occurs. Verify these overflow checks are complete and that no code path can reach the `uint160()` cast without hitting the guard.

**Practical risk:** Low. ERC-20 supplies rarely approach `type(uint160).max` (~1.46e48). But the check is there -- verify it.

## Short TWAP Window Concerns

`_getV3TwapQuote()` defaults to a 10-minute TWAP window (`DEFAULT_TWAP_WINDOW = 600 seconds`). If the pool's oldest observation is younger than 10 minutes, the window is silently capped:

```solidity
if (oldestObservation < twapWindow) twapWindow = oldestObservation;
```

If `oldestObservation == 0`, the function reverts with `JBRouterTerminal_NoObservationHistory()`.

**Risk:** A pool with 30 seconds of observation history produces a "TWAP" that is functionally a spot price. This is the same vulnerability as the V4 spot price path, but without the V4 label warning users.

**Audit focus:** Consider whether the contract should enforce a minimum observation age (e.g., revert if `oldestObservation < 5 minutes`). Currently, any non-zero observation age is accepted.

## Priority Audit Areas

### Critical Path: Payment Routing

The most complex and highest-value code path. Follow a payment from `pay()` through:

1. `_acceptFundsFor()` -- token acceptance (native, ERC-20, Permit2, credit cashout)
2. `_route()` -- routing decision (JB token cashout path vs. resolve+convert)
3. `_cashOutLoop()` -- recursive cashout when input is a JB project token
4. `_resolveTokenOut()` -- discover what the destination project accepts
5. `_convert()` -- same-token no-op, wrap/unwrap, or Uniswap swap
6. `_handleSwap()` -> `_executeSwap()` -> V3 or V4 execution
7. `_beforeTransferFor()` -- allowance setup before forwarding
8. `destTerminal.pay()` -- final forwarding

**Key question:** Can any combination of inputs cause tokens to be stuck in the router? The contract has no sweep/rescue function and an empty `receive()`.

### Callback Verification

- **V3:** `uniswapV3SwapCallback()` reads `fee` from caller, computes expected pool via `FACTORY.getPool()`, checks `msg.sender == expectedPool`. Standard pattern but verify a malicious contract cannot satisfy this check.
- **V4:** `unlockCallback()` checks `msg.sender == address(POOL_MANAGER)`. The PoolManager's unlock pattern prevents reentrancy by design. Verify no path allows a reentrant call through `POOL_MANAGER.unlock()`.

### Slippage Math

The sigmoid formula in `JBSwapLib` is novel. Verify:
- Floor enforcement: `getSlippageTolerance(0, feeBps)` always returns `>= 200 bps`.
- Ceiling enforcement: result never exceeds `MAX_SLIPPAGE (8800)`.
- Monotonicity: higher impact always yields higher tolerance.
- No overflow: `impact + SIGMOID_K` cannot overflow `uint256`.
- `sqrtPriceLimitFromAmounts()` correctly handles edge cases (zero amounts, extreme ratios, boundary tick values).

### Registry Trust Model

- Owner can `setDefaultTerminal()` and redirect all unlocked projects.
- Owner can `disallowTerminal()` which clears default if it matches.
- `lockTerminalFor()` race condition guard: verify the `expectedTerminal` check is correct.
- Verify `setTerminalFor()` correctly blocks when `hasLockedTerminal[projectId]` is true.

## Invariants

These should hold for every transaction and can be used as fuzzing properties:

1. **Zero balance after pay/addToBalanceOf**: `address(routerTerminal).balance == 0` and `IERC20(anyToken).balanceOf(address(routerTerminal)) == 0` after every `pay()` or `addToBalanceOf()` call completes.

2. **No silent truncation**: No code path reaches a `uint160()` cast with a value exceeding `type(uint160).max` without reverting first.

3. **Cashout loop termination**: `_cashOutLoop()` always terminates in at most 20 iterations (revert or return).

4. **Callback caller verification**: `uniswapV3SwapCallback()` only executes token transfers when `msg.sender` is a legitimate V3 pool. `unlockCallback()` only executes when `msg.sender == address(POOL_MANAGER)`.

5. **Locked terminal immutability**: Once `hasLockedTerminal[projectId]` is true, `_terminalOf[projectId]` never changes.

6. **Slippage floor**: `JBSwapLib.getSlippageTolerance(impact, feeBps)` always returns `>= max(feeBps + 100, 200)` (unless the ceiling applies).

7. **TWAP window lower bound**: `_getV3TwapQuote()` reverts when `oldestObservation == 0`.

8. **Leftover refund correctness**: After `_handleSwap()`, the balance delta of the input token (relative to the pre-swap snapshot) is returned to `_msgSender()`. No input tokens remain in the contract.

## Testing Setup

### Running Tests

```bash
# Unit tests (mocked dependencies, no RPC needed)
forge test --match-path "test/RouterTerminal.t.sol"
forge test --match-path "test/RouterTerminalRegistry.t.sol"
forge test --match-path "test/regression/*.t.sol"

# Fork tests (requires Ethereum mainnet RPC)
# Set RPC_ETHEREUM_MAINNET in .env or foundry.toml
forge test --match-path "test/RouterTerminalFork.t.sol" --fork-url $RPC_ETHEREUM_MAINNET
forge test --match-path "test/RouterTerminalSandwichFork.t.sol" --fork-url $RPC_ETHEREUM_MAINNET
forge test --match-path "test/RouterTerminalFeeCashOutFork.t.sol" --fork-url $RPC_ETHEREUM_MAINNET

# All tests
forge test
```

### Foundry Configuration

- Solidity 0.8.26, EVM target `cancun`, optimizer 200 runs
- Fuzz runs: 4,096 per test
- Invariant runs: 1,024 with depth 100
- Fork tests pinned to Ethereum mainnet block 21,700,000 (post-V4 deployment)

### Test Coverage Summary

| Test File | Type | Coverage Area | Count |
|-----------|------|---------------|-------|
| `RouterTerminal.t.sol` | Unit (mocked) | Core routing, swap paths, cashout, V4, pool discovery, TWAP, errors | ~35 |
| `RouterTerminalRegistry.t.sol` | Unit (mocked) | Allow/disallow, set/lock, forwarding, permissions | ~12 |
| `RouterTerminalFork.t.sol` | Fork (mainnet) | End-to-end swaps: ETH->USDC, USDC->ETH, ETH->DAI, addToBalance, quote metadata | ~12 |
| `RouterTerminalFeeCashOutFork.t.sol` | Fork (mainnet) | Fee routing through cashout: project 3 payouts -> fee -> cashout -> project 1 | 1 |
| `RouterTerminalSandwichFork.t.sol` | Fork (mainnet) | MEV/sandwich: V3 TWAP resistance, V4 spot manipulation, user quote | 4 |
| `regression/LockTerminalRace.t.sol` | Unit | Race condition in `lockTerminalFor` with `expectedTerminal` | 3 |
| `regression/CashOutLoopLimit.t.sol` | Unit | Circular cashout loop cap at 20 iterations | 2 |
| `regression/V4SpotPriceSlippage.t.sol` | Unit + fuzz | Sigmoid math: floor, ceiling, monotonicity, bounded range, user quote | 14 |

### Coverage Gaps Worth Investigating

| Area | Status | Why It Matters |
|------|--------|----------------|
| Fee-on-transfer tokens | NOT TESTED | Registry `_acceptFundsFor` does not use balance-delta |
| Short TWAP windows (<60s) | NOT TESTED | Silently degrades to near-spot-price |
| Multi-hop cashout chains (>1 step) | NOT TESTED | Only the circular case and single-step are tested |
| V4 pools with custom hooks | NOT TESTED | All V4 tests use `hooks: IHooks(address(0))` |
| Concurrent pay + addToBalance | NOT TESTED | Mitigated by stateless design but worth verifying |
| Credit cashout path (fork) | NOT TESTED | Only unit-mocked, no fork test with real credits |
| addToBalanceOf with cashout routing | PARTIALLY | Fork covers ETH->USDC, not cashout or credit paths |
