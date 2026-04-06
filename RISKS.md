# Router Terminal Risk Register

This file focuses on the routing, accounting-context, and liquidity-selection risks in the terminal that accepts arbitrary tokens and forwards them into the destination project's real accounting surface.

## How to use this file

- Read `Priority risks` first; they explain where routing convenience can diverge from accounting truth.
- Use the detailed sections for token-decimal synthesis, swap-path, and integration reasoning.
- Treat `Accepted Behaviors` as explicit statements about what this terminal does not guarantee.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Synthetic accounting context misuse | The router synthesizes best-effort decimals and routing context; if downstream systems treat it as accounting truth, they can misprice or mis-lend. | Clear docs, registry scoping, and explicit prohibition on accounting-sensitive reuse. |
| P1 | Wrong-route or low-liquidity execution | The router chooses among direct forwarding, V3, V4, and cash-out paths; a bad route can degrade user execution. | Route selection tests, liquidity checks, and user-specified minimum returns. |
| P1 | Integration fragility with broken tokens | Non-standard ERC-20 metadata or transfer behavior can distort decimal inference or swap execution. | Fallback defaults, defensive probing, receipt checks on terminal-facing hops, and integration testing with hostile token behavior. |


## 1. Trust Assumptions

- **Uniswap V3 Factory / V4 PoolManager.** Pool discovery trusts `FACTORY.getPool()` and `POOL_MANAGER.getSlot0()` to return legitimate pools. If the factory or pool manager is compromised, swaps route through attacker-controlled pools.
- **Canonical V4 hook configuration.** Hooked V4 pool discovery relies on the immutable `UNIV4_HOOK` constructor value. If deployers point it at the wrong hook, the router can miss the intended buyback-hook / LP-split-hook pools and degrade to weaker routes or no route.
- **Trusted forwarder.** ERC-2771 `_msgSender()` trusted for fund transfers. A compromised forwarder can initiate payments/transfers on behalf of any user.
- **JBDirectory.** Terminal resolution trusts `DIRECTORY.primaryTerminalOf()` and `DIRECTORY.terminalsOf()`. A compromised directory can redirect funds.
- **PERMIT2.** Used as fallback for token transfers. Permit2 approvals can be exploited if users have stale allowances.
- **Owner (Ownable).** Contract owner has no fund access but controls the registry terminal allowlist and default.
- **`IJBPayerTracker` implementers.** `_resolveRefundWithBackupRecipient` in the router terminal queries `IJBPayerTracker(msg.sender).originalPayer()` via try-catch. Any contract that is the `msg.sender` and implements `IJBPayerTracker` can direct leftover refunds to an arbitrary address. This is safe when the caller is a trusted intermediary (e.g. the registry), but a malicious `msg.sender` implementing `IJBPayerTracker` could redirect refunds. The risk is bounded: the caller must have already supplied the funds being routed, so it can only redirect leftovers from its own payment.

## 2. Economic / Manipulation Risks

- **V4 price manipulation.** `_getV4Quote` first attempts a 30-second TWAP from the pool's oracle hook (e.g., `IGeomeanOracle.observe()`). If no oracle hook exists or the call fails, it falls back to the instantaneous `getSlot0` tick, which is manipulable via sandwich attacks or flash loans. The sigmoid slippage formula provides a floor (min 2%) but does NOT provide full MEV protection. Without user-supplied `quoteForSwap` metadata, V4 swaps using the spot fallback are vulnerable to extraction. Front-ends MUST supply `quoteForSwap` metadata for V4 swaps without oracle hooks. Note: `_getV4Quote` normalizes WETH to `address(0)` before calling OracleLibrary, since V4 uses `address(0)` for native ETH -- without this normalization, token sorting would mismatch the pool's currency ordering and produce inverted quotes.
- **Hooked V4 discovery scope.** Auto-discovery checks both vanilla V4 pools and pools using the configured canonical `UNIV4_HOOK`. That keeps buyback-hook and LP-split-hook routes discoverable, but it also means deployment misconfiguration of `UNIV4_HOOK` changes which hooked pools are even visible to the router.
- **V3 TWAP manipulation.** Short TWAP windows (falls back to `oldestObservation` if < 10 minutes) reduce manipulation resistance. A newly created pool with minimal history can be manipulated within the TWAP window.
- **Cashout loop value extraction.** `_cashOutLoop` iterates up to 20 times, cashing out JB project tokens recursively. Each cashout incurs bonding curve slippage. `cashOutMinReclaimed` is enforced only on the first concrete cashout hop. Later hops intentionally do not reuse or rescale that minimum, because multi-hop cashouts can change token units and a single metadata amount cannot be propagated safely across different assets. Gas cost: each cashout iteration involves `terminal.cashOutTokensOf` (external call, ~100-200k gas) plus token transfer and balance accounting. At 20 iterations maximum, the worst case is ~4M gas for the loop alone, leaving headroom within a 30M block but consuming a significant portion.
- **Leftover token handling.** `_handleSwap` refunds the full remaining input token balance after a swap. The router is stateless and should never hold funds between transactions. If tokens are accidentally sent to the contract, they are absorbed into the next caller's refund rather than being permanently stuck — this is intentional, as recovering stuck funds is preferable to locking them forever. There is no sweep mechanism because there should be no persistent balance to sweep.
- **V4 native ETH settlement.** `_settleV4` unwraps WETH to native ETH when settling a `Currency.wrap(address(0))` debt with PoolManager. This is necessary because the router may hold WETH (from ERC-20 transfers or prior wrapping) but V4 native pools require `msg.value` settlement. If `address(this).balance` is already sufficient, no unwrap occurs.
- **Pool selection by liquidity.** `_discoverPool` selects the pool with the highest `liquidity()` value. An attacker can deploy a pool with high but concentrated (out-of-range) liquidity to win selection, then manipulate the actual swap execution at worse prices.
- **Heuristic route selection, not best execution.** Automatic routing chooses among discovered paths using bounded heuristics, and pool discovery prefers the deepest discovered pool rather than exhaustively quoting every viable pool. This is an intentional tradeoff to keep routing predictable and gas-bounded. Integrators should treat router-selected execution as best-effort convenience, not a guarantee of the globally best obtainable output. When execution quality matters more than convenience, frontends should supply `quoteForSwap` metadata.

## 3. Access Control

- **No access control on `pay` / `addToBalanceOf`.** Anyone can route payments. This is by design but means the contract processes arbitrary token types and amounts.
- **Lossy terminal-facing ERC-20s unsupported on the router.** Ingress into the router is balance-delta reconciled, and the router's final forwarded ERC-20 hop is enforced by checking that the destination terminal actually received the full nominal ERC-20 amount. Fee-on-transfer or otherwise lossy terminal-facing ERC-20 pulls revert on the router. The registry does not perform receipt enforcement because it always forwards to the router terminal, which never retains tokens.
- **Credit cashout path.** `_acceptFundsFor` processes `cashOutSource` metadata to transfer credits from `_msgSender()`. Requires `TRANSFER_CREDITS` permission. If a user has this permission set broadly, any caller through the trusted forwarder could drain their credits.
- **Registry owner.** Controls which terminals are allowlisted and sets the global default. Disallowing the current default terminal now reverts with `CannotDisallowDefaultTerminal` instead of silently clearing it. Per-project terminal settings already set to a disallowed terminal are NOT cleared.
- **Registry terminal selection can permanently snapshot a bad terminal.** `lockTerminalFor` is intentionally a one-way commitment to the project's currently resolved terminal. If governance or a project owner selects a terminal that later proves unusable, hostile, or simply misconfigured, locking that choice can permanently brick registry-mediated routing for that project until governance and deployment topology change around it. This is not unique to the registry itself pointing at itself; it is true for any bad terminal choice, so terminal selection and locking should be treated as a high-trust operational action.
- **Synthetic accounting contexts.** `JBRouterTerminal.accountingContextForTokenOf()` uses best-effort decimals for
  routing discovery: native tokens use `18`, ERC-20s probe `IERC20Metadata.decimals()` when available, and broken or
  non-standard tokens fall back to `18`. `JBRouterTerminalRegistry` simply forwards that context. This is safe for
  routing discovery but unsafe for integrations that treat the router or registry as a truthful accounting source for
  non-18-decimal assets. Lending and debt-normalization flows must point at a real terminal, not the router layer.
  For example, a USDC terminal (6 decimals) routed through the router reports `decimals: 6` correctly. But if the router cannot probe `IERC20Metadata.decimals()` (non-standard token, or reverting `decimals()` function), it falls back to 18 decimals — a 1e12 scaling error. This only affects routing discovery heuristics, not actual fund transfers, but could cause suboptimal pool selection in `_discoverPool`.

## 4. DoS Vectors

- **No pool exists.** If no V3 or V4 pool exists for a token pair, `_discoverPool` returns empty and the swap reverts. Projects accepting uncommon tokens may become unpayable through this terminal.
- **No observation history.** V3 pools without TWAP observations cause `_getV3TwapQuote` to revert with `NoObservationHistory`. This blocks automatic routing.
- **Cashout loop limit.** Circular or deep token dependency chains hit `_MAX_CASHOUT_ITERATIONS = 20` and revert.
- **Pool with zero liquidity.** Pools with zero in-range liquidity cause reverts.
- **External terminal reverts.** The final `destTerminal.pay()` or `destTerminal.addToBalanceOf()` call is not wrapped in try-catch. A reverting destination terminal blocks the entire payment.
- **Non-standard final ERC-20 transfer behavior.** Terminal-facing ERC-20 hops are enforced to settle exactly on the router path. Tokens that burn, tax, or otherwise reduce the amount actually received by the destination terminal will revert on the final forwarded hop. The registry does not independently enforce receipt checks; it relies on the router to reject lossy transfers.

## 5. Integration Risks

- **Registry default terminal change.** Projects without explicit terminal assignments use `defaultTerminal`. If the registry owner changes the default, all unlocked projects are silently migrated. `lockTerminalFor` mitigates this.
- **Locked bad-terminal risk.** `lockTerminalFor` protects projects from silent migrations, but it also freezes the current resolved terminal exactly as-is. If the locked terminal is malformed, recursively forwards, reverts on use, or otherwise cannot actually process routed payments, the project can be left permanently unroutable through the registry.
- **safeIncreaseAllowance for terminal transfers.** `_beforeTransferFor` uses `safeIncreaseAllowance` which adds to existing allowance. If previous transactions left stale allowance, the cumulative allowance could exceed intended amounts.
- **Callback data trust.** `uniswapV3SwapCallback` validates the caller by reconstructing the pool address from `(tokenIn, tokenOut, fee)`. The factory `getPool` lookup makes spoofing infeasible in practice.
- **receive() function.** The contract accepts arbitrary ETH via `receive()`. This is necessary for WETH unwraps, cashout reclaims, and V4 PoolManager takes. Any ETH received is absorbed into the next swap's leftover refund. Since the router is stateless by design, this is acceptable — funds should not persist between transactions, and recovering accidentally-sent ETH is preferable to locking it permanently.

## 6. MEV Surface

- **V3 path: TWAP-protected.** The 10-minute TWAP oracle makes single-block manipulation futile. Multi-block attacks require sustained capital.
- **V4 path: TWAP-first, spot-fallback.** V4 pools attempt a 30-second TWAP via the oracle hook first. If unavailable, the spot fallback is vulnerable. Without `quoteForSwap` metadata, V4 swaps using the spot fallback are exposed to up to sigmoid-slippage% loss per trade. The 2% floor bounds worst-case extraction.
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

### 8.2 Router trusts `originalPayer()` from any `msg.sender` that implements it

`_resolveRefundWithBackupRecipient` calls `IJBPayerTracker(msg.sender).originalPayer()` in a try-catch. If the call succeeds and returns a non-zero address, leftover tokens from partial swap fills are sent to that address instead of the beneficiary or `_msgSender()`. The router does not verify that `msg.sender` is the registry or any specific contract -- it trusts any caller that implements the interface. This is accepted because: (1) the caller (`msg.sender`) is the entity that supplied the funds, so redirecting its own leftovers is a legitimate operation, (2) if the call reverts or returns `address(0)`, the router falls back to the normal beneficiary/`_msgSender()` logic, and (3) decoupling from the registry allows other intermediary contracts (e.g. batch payers, aggregators) to participate in refund routing without requiring changes to the router terminal.

### 8.5 Registry owns immediate circular-forward protection

The router and resolver no longer contain registry-specific circular-resolution logic. Instead, `JBRouterTerminalRegistry` rejects forwarding back into its immediate caller. This preserves separation of concerns: the router only rejects direct self-routes, while the registry owns protection against `router -> registry -> same router` recursion.

### 8.3 Cashout loop slippage is first-hop only

`_cashOutLoop` applies `cashOutMinReclaimed` to the first cashout step only. Subsequent recursive cashouts (steps 2-20) do not carry that minimum forward. This is intentional: later hops may reclaim different assets with different units and decimals, so rescaling a single metadata amount across the remaining path would be unit-unsound. Users who need tighter protection on the final routed output should still rely on the destination terminal's `minReturnedTokens` parameter and swap-level quote controls such as `quoteForSwap`.

### 8.4 Liquidity-first pool selection is intentional

The router does not attempt full best-execution search across every viable V3 and V4 pool. `_discoverPool` prefers the deepest discovered pool, and the selected pool is then quoted and executed. This can underperform an alternative pool in some market states, but it is an accepted product tradeoff: bounded route discovery, lower complexity, and predictable behavior are prioritized over exhaustive output maximization. Users who need tighter execution guarantees should provide `quoteForSwap` metadata or route externally.
