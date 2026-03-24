# RISKS.md -- nana-router-terminal-v6

## 1. Trust Assumptions

- **Uniswap V3 Factory / V4 PoolManager.** Pool discovery trusts `FACTORY.getPool()` and `POOL_MANAGER.getSlot0()` to return legitimate pools. If the factory or pool manager is compromised, swaps route through attacker-controlled pools.
- **Trusted forwarder.** ERC-2771 `_msgSender()` trusted for fund transfers. A compromised forwarder can initiate payments/transfers on behalf of any user.
- **JBDirectory.** Terminal resolution trusts `DIRECTORY.primaryTerminalOf()` and `DIRECTORY.terminalsOf()`. A compromised directory can redirect funds.
- **PERMIT2.** Used as fallback for token transfers. Permit2 approvals can be exploited if users have stale allowances.
- **Owner (Ownable).** Contract owner has no fund access but controls the registry terminal allowlist and default.

## 2. Economic / Manipulation Risks

- **V4 spot price manipulation.** `_getV4SpotQuote` reads the instantaneous `getSlot0` tick, which is manipulable via sandwich attacks or flash loans. The sigmoid slippage formula provides a floor (min 2%) but does NOT provide full MEV protection. Without user-supplied `quoteForSwap` metadata, V4 swaps are vulnerable to extraction. Front-ends MUST supply `quoteForSwap` metadata for V4 swaps. Note: `_getV4SpotQuote` normalizes WETH to `address(0)` before calling OracleLibrary, since V4 uses `address(0)` for native ETH -- without this normalization, token sorting would mismatch the pool's currency ordering and produce inverted quotes.
- **V3 TWAP manipulation.** Short TWAP windows (falls back to `oldestObservation` if < 10 minutes) reduce manipulation resistance. A newly created pool with minimal history can be manipulated within the TWAP window.
- **Cashout loop value extraction.** `_cashOutLoop` iterates up to 20 times, cashing out JB project tokens recursively. Each cashout incurs bonding curve slippage. `minTokensReclaimed` is only applied to the first step -- subsequent steps have zero slippage protection. Gas cost: each cashout iteration involves `terminal.cashOutTokensOf` (external call, ~100-200k gas) plus token transfer and balance accounting. At 20 iterations maximum, the worst case is ~4M gas for the loop alone, leaving headroom within a 30M block but consuming a significant portion.
- **Leftover token absorption.** `_handleSwap` wraps all remaining `address(this).balance` as WETH after swaps. Any ETH sent directly to the contract (via `receive()`) is absorbed into the next swap's leftover calculation and routed to the project -- not returned to the sender. There is no sweep mechanism — ETH absorbed this way is permanently incorporated into the next routing operation. This is by design (the router is stateless and holds no balances across transactions), but users who accidentally send ETH directly to the contract should understand that it is unrecoverable.
- **V4 native ETH settlement.** `_settleV4` unwraps WETH to native ETH when settling a `Currency.wrap(address(0))` debt with PoolManager. This is necessary because the router may hold WETH (from ERC-20 transfers or prior wrapping) but V4 native pools require `msg.value` settlement. If `address(this).balance` is already sufficient, no unwrap occurs.
- **Pool selection by liquidity.** `_discoverPool` selects the pool with the highest `liquidity()` value. An attacker can deploy a pool with high but concentrated (out-of-range) liquidity to win selection, then manipulate the actual swap execution at worse prices.

## 3. Access Control

- **No access control on `pay` / `addToBalanceOf`.** Anyone can route payments. This is by design but means the contract processes arbitrary token types and amounts.
- **Fee-on-transfer tokens unsupported.** `_acceptFundsFor` in the terminal uses balance-delta, but the registry does NOT. Fee-on-transfer tokens through the registry will mismatch.
- **Credit cashout path.** `_acceptFundsFor` processes `cashOutSource` metadata to transfer credits from `_msgSender()`. Requires `TRANSFER_CREDITS` permission. If a user has this permission set broadly, any caller through the trusted forwarder could drain their credits.
- **Registry owner.** Controls which terminals are allowlisted and sets the global default. Disallowing the current default terminal now reverts with `CannotDisallowDefaultTerminal` instead of silently clearing it. Per-project terminal settings already set to a disallowed terminal are NOT cleared.
- **Synthetic accounting contexts.** `JBRouterTerminal.accountingContextForTokenOf()` uses best-effort decimals for
  routing discovery: native tokens use `18`, ERC-20s probe `IERC20Metadata.decimals()` when available, and broken or
  non-standard tokens fall back to `18`. `JBRouterTerminalRegistry` simply forwards that context. This is safe for
  routing discovery but unsafe for integrations that treat the router or registry as a truthful accounting source for
  non-18-decimal assets. Lending and debt-normalization flows must point at a real terminal, not the router layer.
  The router now refuses to treat a primary terminal as direct acceptance unless that terminal also exposes non-empty
  accounting contexts for the project, so router-stack terminals do not win the direct-forward fast path.
  For example, a USDC terminal (6 decimals) routed through the router reports `decimals: 6` correctly. But if the router cannot probe `IERC20Metadata.decimals()` (non-standard token, or reverting `decimals()` function), it falls back to 18 decimals — a 1e12 scaling error. This only affects routing discovery heuristics, not actual fund transfers, but could cause suboptimal pool selection in `_discoverPool`.

## 4. DoS Vectors

- **No pool exists.** If no V3 or V4 pool exists for a token pair, `_discoverPool` returns empty and the swap reverts. Projects accepting uncommon tokens may become unpayable through this terminal.
- **No observation history.** V3 pools without TWAP observations cause `_getV3TwapQuote` to revert with `NoObservationHistory`. This blocks automatic routing.
- **Cashout loop limit.** Circular or deep token dependency chains hit `_MAX_CASHOUT_ITERATIONS = 20` and revert.
- **Pool with zero liquidity.** Pools with zero in-range liquidity cause reverts.
- **External terminal reverts.** The final `destTerminal.pay()` or `destTerminal.addToBalanceOf()` call is not wrapped in try-catch. A reverting destination terminal blocks the entire payment.

## 5. Integration Risks

- **Registry default terminal change.** Projects without explicit terminal assignments use `defaultTerminal`. If the registry owner changes the default, all unlocked projects are silently migrated. `lockTerminalFor` mitigates this.
- **safeIncreaseAllowance for terminal transfers.** `_beforeTransferFor` uses `safeIncreaseAllowance` which adds to existing allowance. If previous transactions left stale allowance, the cumulative allowance could exceed intended amounts.
- **Callback data trust.** `uniswapV3SwapCallback` validates the caller by reconstructing the pool address from `(tokenIn, tokenOut, fee)`. The factory `getPool` lookup makes spoofing infeasible in practice.
- **receive() function.** The contract accepts arbitrary ETH via `receive()`. This ETH is absorbed into the next swap operation rather than being recoverable.

## 6. MEV Surface

- **V3 path: TWAP-protected.** The 10-minute TWAP oracle makes single-block manipulation futile. Multi-block attacks require sustained capital.
- **V4 path: spot-vulnerable.** Without `quoteForSwap` metadata, V4 swaps are exposed to up to sigmoid-slippage% loss per trade. The 2% floor bounds worst-case extraction.
- **Cross-route arbitrage.** When JB routing bypasses the AMM (minting tokens directly), an arbitrage opportunity exists between the JB bonding curve price and the AMM price.

## 7. Invariants to Verify

- After any `pay()` or `addToBalanceOf()`, the contract should hold zero tokens (all routed to destination terminal or returned as leftovers).
- `minAmountOut` in swaps is never zero when TWAP/spot price is available (the sigmoid formula has a 2% floor).
- Callback validation: `uniswapV3SwapCallback` only transfers tokens to verified pool addresses.
- `unlockCallback` only executes when called by `POOL_MANAGER`.
- Credit cashout path: credits are transferred FROM `_msgSender()` only, never from arbitrary addresses.
- Cashout loop terminates: either finds a terminal, reverts with `CashOutLoopLimit`, or reverts with `NoCashOutPath`.

## 8. Accepted Behaviors

### 8.1 No reentrancy guard (stateless routing)

The router terminal has no `ReentrancyGuard` or `_routing` flag. This is a conscious design choice, not an oversight. During `_cashOutLoop`, the cashout terminal's callback could re-enter `pay()` or `addToBalanceOf()` on this router. This is safe because:

- **The router is stateless.** It does not maintain mutable accounting between `_route()` and the final `destTerminal.pay/addToBalanceOf`. Each call independently accepts funds, routes them, and forwards the result. There is no shared mutable state that a re-entrant call could corrupt — no balances, no counters, no flags. The only storage is immutable configuration (DIRECTORY, TOKENS, WETH, etc.).
- **CEI ordering is maintained within each call.** The execution flow follows a strict pipeline: (1) `_acceptFundsFor` pulls funds from the caller, (2) `_route` computes the destination and converts tokens if needed, (3) `_beforeTransferFor` + `destTerminal.pay/addToBalanceOf` forwards the result. Because there is no mutable state written between steps (1) and (3), there is nothing for a re-entrant call to read-before-write or corrupt. The "checks" and "effects" are collapsed into stateless computation, and the "interaction" (the final forwarding call) operates only on local variables.
- **Each call uses its own funds.** The re-entrant call would need to supply its own tokens/ETH (via `_acceptFundsFor`). It cannot consume funds belonging to the outer call because those funds are already committed to the routing pipeline.
- **A reentrancy guard would block legitimate composition.** Projects may have terminal chains where terminal A routes through this router, which cashes out into terminal B, which itself routes through this router for a different project. A blanket reentrancy guard would break such flows.

Verified in `RouterTerminalReentrancy.t.sol`: re-entrant calls via both `pay()` and `addToBalanceOf()` succeed without corrupting the outer call's ETH forwarding. The invariant suite (`RouterTerminalInvariant.t.sol`) further confirms that the router holds zero tokens and zero ETH after every operation — including operations that exercise the cashout recursion loop (`_cashOutLoop`, up to `_MAX_CASHOUT_ITERATIONS = 20`).

### 8.2 Cashout loop slippage is first-hop only (accepted trade-off)

`_cashOutLoop` applies `minTokensReclaimed` only to the first cashout step. Subsequent recursive cashouts (steps 2-20) have zero explicit slippage protection. This is accepted because: (1) adding per-step slippage would require the caller to predict intermediate token amounts across an unknown chain of cashouts, which is impractical, (2) the first-hop slippage check ensures the initial conversion meets the user's expectation, and (3) the recursive path is deterministic — intermediate projects' bonding curves and rulesets are on-chain state that cannot be manipulated between steps within a single transaction. The risk is limited to scenarios where intermediate projects have very low liquidity, causing high bonding-curve slippage on small amounts.
