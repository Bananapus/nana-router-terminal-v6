# RISKS.md -- nana-router-terminal-v6

## 1. Trust Assumptions

- **Uniswap V3 Factory / V4 PoolManager.** Pool discovery trusts `FACTORY.getPool()` and `POOL_MANAGER.getSlot0()` to return legitimate pools. If the factory or pool manager is compromised, swaps route through attacker-controlled pools.
- **Trusted forwarder.** ERC-2771 `_msgSender()` trusted for fund transfers. A compromised forwarder can initiate payments/transfers on behalf of any user.
- **JBDirectory.** Terminal resolution trusts `DIRECTORY.primaryTerminalOf()` and `DIRECTORY.terminalsOf()`. A compromised directory can redirect funds.
- **PERMIT2.** Used as fallback for token transfers. Permit2 approvals can be exploited if users have stale allowances.
- **Owner (Ownable).** Contract owner has no fund access but controls the registry terminal allowlist and default.

## 2. Economic / Manipulation Risks

- **V4 spot price manipulation.** `_getV4SpotQuote` reads the instantaneous `getSlot0` tick, which is manipulable via sandwich attacks or flash loans. The sigmoid slippage formula provides a floor (min 2%) but does NOT provide full MEV protection. Without user-supplied `quoteForSwap` metadata, V4 swaps are vulnerable to extraction. Front-ends MUST supply `quoteForSwap` metadata for V4 swaps.
- **V3 TWAP manipulation.** Short TWAP windows (falls back to `oldestObservation` if < 10 minutes) reduce manipulation resistance. A newly created pool with minimal history can be manipulated within the TWAP window.
- **Cashout loop value extraction.** `_cashOutLoop` iterates up to 20 times, cashing out JB project tokens recursively. Each cashout incurs bonding curve slippage. `minTokensReclaimed` is only applied to the first step -- subsequent steps have zero slippage protection.
- **Leftover token absorption.** `_handleSwap` wraps all remaining `address(this).balance` as WETH after swaps. Any ETH sent directly to the contract (via `receive()`) is absorbed into the next swap's leftover calculation and routed to the project -- not returned to the sender.
- **Pool selection by liquidity.** `_discoverPool` selects the pool with the highest `liquidity()` value. An attacker can deploy a pool with high but concentrated (out-of-range) liquidity to win selection, then manipulate the actual swap execution at worse prices.

## 3. Access Control

- **No access control on `pay` / `addToBalanceOf`.** Anyone can route payments. This is by design but means the contract processes arbitrary token types and amounts.
- **Fee-on-transfer tokens unsupported.** `_acceptFundsFor` in the terminal uses balance-delta, but the registry does NOT. Fee-on-transfer tokens through the registry will mismatch.
- **Credit cashout path.** `_acceptFundsFor` processes `cashOutSource` metadata to transfer credits from `_msgSender()`. Requires `TRANSFER_CREDITS` permission. If a user has this permission set broadly, any caller through the trusted forwarder could drain their credits.
- **Registry owner.** Controls which terminals are allowlisted and sets the global default. Disallowing a terminal clears the default if it matches but does NOT clear per-project terminal settings already set to the disallowed terminal.

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
