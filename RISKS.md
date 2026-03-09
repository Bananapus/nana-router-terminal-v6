# nana-router-terminal-v6 -- Risks

Deep implementation-level risk analysis.

## Trust Assumptions

1. **Uniswap V3/V4 pools** -- Swap execution depends on available liquidity and pool integrity. The terminal discovers pools at call time across 8 pools (4 V3 fee tiers + 4 V4 fee/tickSpacing pairs) and selects the one with the highest in-range liquidity.
2. **JBDirectory** -- The terminal trusts `DIRECTORY.primaryTerminalOf()` and `DIRECTORY.terminalsOf()` to return correct terminal addresses. A compromised directory could redirect funds.
3. **Destination terminals** -- After routing, funds are forwarded to the destination project's terminal via `terminal.pay()` or `terminal.addToBalanceOf()`. The router trusts these terminals to behave correctly.
4. **JBTokens** -- Credit cashout paths call `TOKENS.transferCreditsFrom()` and `TOKENS.projectIdOf()`. A compromised token registry could misroute tokens.
5. **Registry owner** -- Controls which terminals are allowlisted and sets the global default. A malicious owner could allowlist a malicious terminal, though project owners must still opt in via `setTerminalFor()`.
6. **OracleLibrary** -- V3 TWAP quotes rely on Uniswap's `OracleLibrary.consult()`. Assumes the oracle history is populated and not stale.
7. **V4 PoolManager** -- V4 swap execution uses `POOL_MANAGER.unlock()` with the router as `IUnlockCallback`. The callback is verified by checking `msg.sender == address(POOL_MANAGER)` (line 417).

## Risk Analysis

### HIGH SEVERITY

#### H-1: V4 Spot Price Manipulation (M-3 Finding)

**Location**: `JBRouterTerminal._getV4SpotQuote()` (lines 1119-1153)
**Severity**: HIGH
**Tested**: YES -- `RouterTerminalSandwichFork.t.sol` (test_fork_v4SpotPrice_manipulation), `M3_V4SpotPriceSlippage.t.sol`

V4 vanilla pools have no built-in TWAP oracle. The terminal reads the instantaneous spot tick from `POOL_MANAGER.getSlot0(id)` (line 1131), which can be manipulated within the same block via sandwich attacks or flash loans.

**Impact**: An attacker can manipulate the V4 pool's spot price before a victim's transaction, causing the sigmoid slippage formula to compute a `minAmountOut` based on a distorted price. The attacker then reverses the manipulation after the victim's swap, extracting value.

**Mitigations in place**:
1. Sigmoid slippage floor: `JBSwapLib.getSlippageTolerance()` enforces a minimum 2% slippage (200 bps), bounding worst-case loss to ~2% for small swaps in deep pools. The ceiling is 88% (line 17 of JBSwapLib.sol).
2. User-provided quote: When `quoteForSwap` metadata is present, `_pickPoolAndQuote()` (line 1239) uses the user's value directly, bypassing spot-based calculation entirely.
3. Pool discovery preference: `_discoverPool()` selects by highest in-range liquidity. If a V3 pool has more liquidity, it wins and gets the TWAP-protected path.

**Residual risk**: Without a user-provided quote, a V4 swap is exposed to up to sigmoid-slippage% loss per trade. The 2% floor means even in the best case, an attacker can extract ~2% from each V4 swap. Front-ends MUST supply `quoteForSwap` metadata for V4 swaps.

---

#### H-2: Stuck Funds on Revert After Partial Swap State

**Location**: `JBRouterTerminal._handleSwap()` (lines 1162-1202), `_route()` (lines 1316-1368)
**Severity**: HIGH (theoretical -- mitigated by atomic execution)
**Tested**: YES -- Fork tests verify zero leftover balances after every swap.

If a swap succeeds but the subsequent `terminal.pay()` or `terminal.addToBalanceOf()` reverts, the swapped tokens remain in the router terminal with no recovery mechanism. There is no sweep or rescue function.

**Mitigation**: The entire flow (accept -> route -> swap -> forward) executes atomically within a single transaction. If the destination terminal reverts, the entire transaction reverts, including the swap. However, if the destination terminal accepts the tokens but misbehaves (e.g., does not revert but does not credit the project), the tokens are lost.

**Test coverage**: Fork tests (`RouterTerminalFork.t.sol`) assert `address(routerTerminal).balance == 0` and `IERC20(...).balanceOf(address(routerTerminal)) == 0` after every operation.

---

### MEDIUM SEVERITY

#### M-1: TWAP Oracle Stale or Insufficient History

**Location**: `JBRouterTerminal._getV3TwapQuote()` (lines 1052-1096)
**Severity**: MEDIUM
**Tested**: NO -- No test directly exercises the `oldestObservation < twapWindow` fallback path.

The TWAP window defaults to 10 minutes (600 seconds). If the pool's oldest observation is younger than 10 minutes (`oldestObservation < twapWindow`, line 1067), the window is silently capped to the available history. A newly created pool or one with minimal activity could have only seconds of history, making the "TWAP" functionally equivalent to a spot price and vulnerable to manipulation.

**Impact**: Short TWAP windows (e.g., 30 seconds) provide minimal manipulation resistance.

**Additional check**: If `oldestObservation == 0`, the function reverts with `JBRouterTerminal_NoObservationHistory()` (line 1064). This prevents swaps against pools with zero history.

---

#### M-2: Cashout Loop -- Circular Token Dependencies

**Location**: `JBRouterTerminal._cashOutLoop()` (lines 603-668)
**Severity**: MEDIUM
**Tested**: YES -- `L30_CashOutLoopLimit.t.sol`

If JB project tokens form a circular dependency (token A cashes out to token B, token B cashes out to token A), the `_cashOutLoop` iterates until hitting the 20-iteration cap (`_MAX_CASHOUT_ITERATIONS`, line 591), then reverts with `JBRouterTerminal_CashOutLoopLimit()`.

**Impact**: The transaction reverts cleanly (no fund loss), but the payment path is blocked. Gas is wasted up to the iteration limit.

**Tested**: `L30_CashOutLoopLimitTest.test_cashOutLoop_revertsOnCircularDependency()` verifies the revert, and `test_cashOutLoop_succeedsWithinLimit()` verifies non-circular paths succeed.

---

#### M-3: Registry Default Terminal Change Affects Unlocked Projects

**Location**: `JBRouterTerminalRegistry.terminalOf()` (lines 155-158), `setDefaultTerminal()` (line 355)
**Severity**: MEDIUM
**Tested**: YES -- `RouterTerminalRegistry.t.sol` (test_terminalOf_fallsBackToDefault)

Projects that have not explicitly set a terminal via `setTerminalFor()` use `defaultTerminal`. If the registry owner changes the default, all unlocked projects without explicit terminal assignments are silently migrated to the new default.

**Impact**: The registry owner can redirect payments for all unlocked projects by changing the default terminal. Projects can protect against this by calling `setTerminalFor()` or `lockTerminalFor()`.

**Mitigation**: `lockTerminalFor()` snapshots the current default into `_terminalOf[projectId]` (lines 279-283), insulating the project from future default changes.

---

#### M-4: Fee-on-Transfer Token Partial Support

**Location**: `JBRouterTerminal._acceptFundsFor()` (lines 527-533)
**Severity**: MEDIUM
**Tested**: NO -- No test exercises fee-on-transfer tokens.

The `_acceptFundsFor` function measures `balanceBefore` and `balanceAfter` (lines 527, 533) to handle fee-on-transfer tokens. However, `JBRouterTerminalRegistry._acceptFundsFor()` (lines 395-433) does NOT use balance-delta accounting -- it returns the user-supplied `amount` directly. If a fee-on-transfer token is used through the registry, the forwarded amount will exceed the actual tokens received, causing a later transfer to revert or underpay.

**Impact**: Payments via the registry with fee-on-transfer tokens will revert or behave incorrectly.

---

#### M-5: uint160 Truncation in Permit2 Transfer

**Location**: `JBRouterTerminal._transferFrom()` (line 1415), `JBRouterTerminalRegistry._transferFrom()` (line 470)
**Severity**: MEDIUM
**Tested**: NO -- No test exercises amounts > `type(uint160).max`.

The `PERMIT2.transferFrom()` call casts `amount` to `uint160`: `PERMIT2.transferFrom(from, to, uint160(amount), token)`. If `amount > type(uint160).max`, the cast silently truncates, transferring fewer tokens than expected.

**Practical risk**: LOW. ERC-20 token supplies rarely approach `type(uint160).max` (~1.46e48). However, the code does not validate the cast.

---

### LOW SEVERITY

#### L-1: Lock Terminal Race Condition Protection

**Location**: `JBRouterTerminalRegistry.lockTerminalFor()` (lines 269-293)
**Severity**: LOW (mitigated)
**Tested**: YES -- `L29_LockTerminalRace.t.sol`

The `expectedTerminal` parameter prevents a race condition where the default terminal changes between transaction submission and mining. If the resolved terminal does not match `expectedTerminal`, the function reverts with `TerminalMismatch` (line 287).

**Tested**: Three test cases cover correct expected, wrong expected (default fallback), and wrong expected (explicit terminal set).

---

#### L-2: V3 Callback Verification via Factory

**Location**: `JBRouterTerminal.uniswapV3SwapCallback()` (lines 390-411)
**Severity**: LOW (standard pattern)
**Tested**: YES -- Exercised by all fork swap tests.

The callback reads `IUniswapV3Pool(msg.sender).fee()` (line 399) and verifies via `FACTORY.getPool()` (line 400). If the caller is not a legitimate pool, it reverts with `CallerNotPool`. This is the standard V3 verification pattern.

**Note**: The fee is read from the caller (`msg.sender`), so a malicious contract could return any fee value. However, the factory lookup with the actual token pair and that fee must match `msg.sender`, which is not forgeable.

---

#### L-3: Empty `receive()` Function

**Location**: `JBRouterTerminal.receive()` (line 1423)
**Severity**: LOW
**Tested**: Implicitly -- fork tests verify zero balance after operations.

The terminal accepts ETH from any sender via an empty `receive()` function. This is necessary for WETH unwraps, cashout reclaims, and V4 PoolManager takes. However, if someone accidentally sends ETH directly, it cannot be recovered.

**Impact**: Accidental ETH sent directly to the terminal is permanently stuck.

---

#### L-4: No Deadline Parameter

**Location**: `JBRouterTerminal.pay()` (lines 345-383), `addToBalanceOf()` (lines 294-328)
**Severity**: LOW
**Tested**: NO

Neither `pay()` nor `addToBalanceOf()` accepts a deadline parameter. A transaction could sit in the mempool for an extended period and execute at a stale price. The TWAP-based or spot-based `minAmountOut` is computed at execution time, not submission time, which partially mitigates this risk (the quote is always fresh). However, market conditions can change between when the user decides to pay and when the transaction is mined.

**Mitigation**: The user-provided `quoteForSwap` metadata effectively acts as a deadline mechanism by specifying a minimum output.

---

#### L-5: Pool Discovery Gas Cost

**Location**: `JBRouterTerminal._discoverPool()` (lines 766-808), `_discoverAcceptedToken()` (lines 716-759)
**Severity**: LOW
**Tested**: YES -- Fork tests execute full discovery paths.

Pool discovery at call time searches up to 8 pools (4 V3 + 4 V4) per token pair. `_discoverAcceptedToken()` iterates all terminals and all accounting contexts for a project, calling `_bestPoolLiquidity()` for each candidate. For projects with many terminals and accepted tokens, this can become gas-intensive.

**Impact**: Elevated gas costs, not a correctness issue.

---

## MEV / Sandwich Attack Vectors

### V3 Path: TWAP-Protected

The V3 swap path computes `minAmountOut` from a 10-minute TWAP oracle (`OracleLibrary.consult()`, line 1070). Same-block spot price manipulation does NOT affect the TWAP.

**Tested**: `RouterTerminalSandwichFork.t.sol`:
- `test_fork_v3Sandwich_varyingAttackSizes()` -- Simulates sandwich attacks at 0.5-100 ETH against a 1 ETH victim. Attacker pays 2x pool fees (0.05% each way) for no profit.
- `test_fork_v3Sandwich_twapResistance()` -- Proves the TWAP tick is identical before and after a 100 ETH same-block manipulation. The 10-minute observation window makes single-block attacks futile.
- `test_fork_v3Sandwich_withUserQuote()` -- Shows that a tight user quote (0.5% slippage) blocks attacks that the wider TWAP tolerance (~2%) would allow.

**Residual risk**: Multi-block TWAP manipulation is theoretically possible but requires sustained capital over many blocks, making it economically infeasible for typical swap sizes.

### V4 Path: Spot Price Vulnerable

V4 vanilla pools lack a TWAP oracle. The router reads `getSlot0()` spot price, which is manipulable within the same block.

**Tested**: `RouterTerminalSandwichFork.t.sol`:
- `test_fork_v4SpotPrice_manipulation()` -- Creates a fresh V4 pool, demonstrates that 10-100 ETH attacks can move the spot price significantly (documented as M-3 risk).

**Tested**: `M3_V4SpotPriceSlippage.t.sol`:
- 14 unit tests verifying sigmoid properties: floor enforcement, monotonicity, bounded range, fuzz tests.
- `test_v4QuoteSimulation_sigmoidFloorEnforcesMinOutput()` -- Proves `minAmountOut >= 98%` of spot for small swaps in deep pools.
- `test_userQuote_overrides_sigmoidCalculation()` -- Shows user quote bypasses the sigmoid path.

**Recommendation**: Front-ends MUST supply `quoteForSwap` metadata for V4 swaps. Without it, the sigmoid slippage floor (~2%) is the only protection.

### Leftover Return as Refund Vector

**Location**: `_handleSwap()` (lines 1196-1201)

After a swap, leftover input tokens (from partial fills where the sqrtPriceLimit was hit) are returned to `_msgSender()`. This uses a balance-delta approach (`balanceAfter - balanceBefore`), which is safe against reentrancy because the leftover is measured after the swap completes.

**Tested**: Fork tests assert zero leftover after every swap.

## Reentrancy Analysis

### No Explicit Reentrancy Guard

Neither `JBRouterTerminal` nor `JBRouterTerminalRegistry` uses OpenZeppelin's `ReentrancyGuard`. Instead, the contracts rely on state ordering and atomic execution.

### JBRouterTerminal

| Entry Point | External Calls Made | Reentrancy Risk | Analysis |
|-------------|-------------------|----------------|----------|
| `pay()` | `_acceptFundsFor()` -> `_route()` -> `_convert()` -> Uniswap swap -> `terminal.pay()` | LOW | Funds are accepted first, then routed atomically. The terminal is stateless between calls -- no storage is updated between external calls that could be exploited. |
| `addToBalanceOf()` | Same as `pay()` but ends with `terminal.addToBalanceOf()` | LOW | Same analysis as `pay()`. |
| `uniswapV3SwapCallback()` | `WETH.deposit()`, `IERC20.safeTransfer()` | LOW | Only called by verified V3 pools (factory check). Wraps ETH and transfers input tokens to the pool. |
| `unlockCallback()` | `POOL_MANAGER.swap()`, `_settleV4()`, `_takeV4()` | LOW | Only called by V4 PoolManager (address check). The PoolManager's unlock pattern prevents reentrancy by design. |
| `_cashOutLoop()` | `cashOutTerminal.cashOutTokensOf()` (in loop) | MEDIUM | Makes up to 20 external calls in a loop. Each call to `cashOutTokensOf()` could trigger arbitrary code in the cashout terminal. However, the loop only processes one token type at a time and the terminal is stateless. |

### JBRouterTerminalRegistry

| Entry Point | External Calls Made | Reentrancy Risk | Analysis |
|-------------|-------------------|----------------|----------|
| `pay()` | `_acceptFundsFor()` -> `terminal.pay()` | LOW | Accepts funds, then forwards. No state updates between these calls that could be exploited. |
| `addToBalanceOf()` | `_acceptFundsFor()` -> `terminal.addToBalanceOf()` | LOW | Same as `pay()`. |

### Key Observation

The router terminal is **stateless** between transactions. It holds no persistent balances, no queued operations, no pending state. All token movements (accept, swap, forward) happen within a single transaction and complete or revert atomically. This eliminates the primary vector for reentrancy attacks (corrupting intermediate state).

The only reentrancy concern is in `_cashOutLoop()`, where a malicious cashout terminal could re-enter `pay()`. However, since the router has no state to corrupt, re-entrant calls would be independent transactions with their own accept/route/forward flow.

## Test Coverage Summary

### Test Files (8 total)

| Test File | Type | What It Tests | Tests |
|-----------|------|---------------|-------|
| `RouterTerminal.t.sol` | Unit (mocked) | Core routing: direct forwarding, swap paths, cashout paths, V4 routing, pool discovery, TWAP quoting, error conditions | ~35 tests |
| `RouterTerminalRegistry.t.sol` | Unit (mocked) | Registry: allow/disallow, set/lock terminal, forwarding, permissions | ~12 tests |
| `RouterTerminalFork.t.sol` | Fork (mainnet) | End-to-end swaps against real Uniswap V3 pools: ETH->USDC, USDC->ETH, ETH->DAI, direct forwarding, addToBalance, quote metadata, slippage reverts | ~12 tests |
| `RouterTerminalFeeCashOutFork.t.sol` | Fork (mainnet) | Fee routing: project 3 payouts -> fee in project 2's token -> cashout -> ETH -> project 1 | 1 test |
| `RouterTerminalSandwichFork.t.sol` | Fork (mainnet) | MEV/sandwich resistance: V3 TWAP resistance, V4 spot manipulation, user quote protection | 4 tests |
| `L29_LockTerminalRace.t.sol` | Unit (regression) | Race condition in `lockTerminalFor()` with `expectedTerminal` parameter | 3 tests |
| `L30_CashOutLoopLimit.t.sol` | Unit (regression) | Circular cashout dependency cap at 20 iterations | 2 tests |
| `M3_V4SpotPriceSlippage.t.sol` | Unit + fuzz (regression) | Sigmoid slippage math: floor, ceiling, monotonicity, bounded range, user quote override | 14 tests |

### Coverage Gaps

| Area | Status | Gap Description |
|------|--------|-----------------|
| Fee-on-transfer tokens | NOT TESTED | No test exercises tokens with transfer fees. `JBRouterTerminal._acceptFundsFor()` uses balance-delta but `JBRouterTerminalRegistry._acceptFundsFor()` does not. |
| Short TWAP windows | NOT TESTED | No test verifies behavior when `oldestObservation` is very small (e.g., 10 seconds), which weakens TWAP protection. |
| uint160 truncation in Permit2 | NOT TESTED | No test exercises amounts exceeding `type(uint160).max`. |
| Deadline/stale transactions | NOT TESTED | No test simulates a transaction executing after an extended mempool delay. |
| Multi-hop routing | NOT TESTED | No test exercises a cashout chain longer than 1 step (A -> B -> C). The 20-iteration cap is tested but only for the circular case. |
| V4 with hooks | NOT TESTED | All V4 tests use `hooks: IHooks(address(0))`. No test exercises V4 pools with custom hook contracts, which could alter swap behavior. |
| Concurrent operations | NOT TESTED | No test simulates multiple simultaneous pay/addToBalance calls that might interfere. (Mitigated by stateless design.) |
| `addToBalanceOf` routing | PARTIALLY TESTED | Fork test covers ETH->USDC via `addToBalanceOf`, but not the cashout or credit-based paths. |
| Credit cashout path | PARTIALLY TESTED | Unit test mocks the path but no fork test exercises real credit transfers. |

## Privileged Roles

| Role | Permission | Scope | Risk |
|------|-----------|-------|------|
| Registry Owner | `allowTerminal`, `disallowTerminal`, `setDefaultTerminal` | Global | Can redirect all unlocked projects by changing the default terminal. Cannot affect locked projects. |
| Project Owner / Delegate | `SET_ROUTER_TERMINAL` (28) -- set and lock terminal | Per-project | Can permanently lock routing. Locking is irreversible. |
| Router Terminal Owner | `transferOwnership`, `renounceOwnership` (inherited, unused) | Global | No operational impact currently. Future subclasses could add `onlyOwner` functions. |
