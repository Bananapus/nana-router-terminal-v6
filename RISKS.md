# Router Terminal Risk Register

This file covers the routing, accounting-context, and liquidity-selection risks in the terminal that accepts arbitrary tokens and forwards them into a project's real accounting surface.

## How To Use This File

- Read `Priority risks` first. They explain where routing convenience can diverge from accounting truth.
- Use the later sections for token-decimal synthesis, swap-path, and integration reasoning.
- Treat `Accepted behaviors` as explicit statements about what this terminal does not guarantee.

## Priority Risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Synthetic accounting context misuse | The router synthesizes best-effort decimals and routing context. If downstream systems treat it as accounting truth, they can misprice or mis-lend. | Clear docs, registry scoping, and explicit prohibition on accounting-sensitive reuse. |
| P1 | Wrong-route or low-liquidity execution | The router chooses among direct forwarding, V3, V4, and cash-out paths. A bad route can degrade user execution. | Route-selection tests, liquidity checks, and user-specified minimum returns. |
| P1 | Integration fragility with broken tokens | Non-standard ERC-20 metadata or transfer behavior can distort decimal inference or swap execution. | Fallback defaults, defensive probing, receipt checks on terminal-facing hops, and hostile-token testing. |

## 1. Trust Assumptions

- **Uniswap V3 factory and V4 PoolManager behave correctly.** Pool discovery trusts those external systems to point at real pools.
- **Canonical V4 hook configuration is correct.** If deployers set the wrong `UNIV4_HOOK`, the router can miss intended hooked pools.
- **The trusted forwarder is trustworthy.** A compromised forwarder can initiate transfers on behalf of any user.
- **`JBDirectory` resolves the right terminals.** A compromised directory can redirect funds.
- **Permit2 allowances are intentional.** Stale approvals can be abused.
- **The registry owner acts correctly.** The owner controls allowlisting and the default router terminal.
- **`IJBPayerTracker` callers are trusted to name their own refund recipient.** A caller implementing `originalPayer()` can redirect leftovers from its own route.

## 2. Economic And Manipulation Risks

- **V4 price manipulation.** `_getV4Quote` tries a 30-second TWAP first. If that fails, it falls back to spot pricing, which is manipulable within the block.
- **Hooked V4 discovery scope.** Auto-discovery checks both vanilla V4 pools and pools using the configured canonical `UNIV4_HOOK`.
- **V3 TWAP manipulation.** Short history reduces manipulation resistance, especially in new pools.
- **Cash-out loop value extraction.** `_cashOutLoop` is capped at 20 iterations. `cashOutMinReclaimed` only applies on the first real cash-out hop.
- **Pre-existing balances are intentionally excluded from route refunds.** Stray balances already sitting in the router are not swept into the next caller's refund.
- **V4 native ETH settlement is special-cased.** `_settleV4` unwraps WETH when the pool manager expects native ETH.
- **Pool selection is liquidity-first.** `_discoverPool` picks the deepest discovered pool, not the globally best execution path.
- **Route selection is heuristic, not best execution.** The router bounds discovery for predictability and gas, not exhaustive optimization.

## 3. Access Control

- **`pay` and `addToBalanceOf` are permissionless.** Anyone can route payments.
- **Lossy terminal-facing ERC-20s are unsupported.** Final forwarded ERC-20 hops must settle exactly on the router path.
- **Credit cash-out path depends on `TRANSFER_CREDITS`.** Broad grants of that permission widen the attack surface.
- **The registry owner controls allowlisting and the global default.** Disallowing the current default now reverts instead of silently clearing it.
- **Registry terminal locking can freeze a bad choice.** `lockTerminalFor` is a one-way commitment.
- **Router accounting contexts are synthetic.** They are safe for discovery, but unsafe as accounting truth for lending, debt, or balance normalization.

## 4. DoS Vectors

- **No pool exists.** If no V3 or V4 pool exists for a token pair, automatic swap routing fails.
- **No observation history.** V3 TWAP quoting can revert on fresh pools.
- **Cash-out loop limit.** Circular or deep token dependency chains hit `_MAX_CASHOUT_ITERATIONS = 20` and revert.
- **Zero-liquidity pools.** Pools with no usable liquidity revert.
- **External terminal reverts.** Final terminal calls are not wrapped in `try/catch`.
- **Non-standard final ERC-20 transfer behavior.** Lossy terminal-facing tokens revert on the final forwarded hop.

## 5. Integration Risks

- **Registry default terminal changes affect unlocked projects.** Projects without explicit assignments follow `defaultTerminal`.
- **Locked bad-terminal risk remains.** Locking protects against silent migration, but also freezes any mistake.
- **`forceApprove` is used for terminal transfers.** This resets allowance before setting a new value and avoids stale-allowance accumulation.
- **Callback data trust matters.** `uniswapV3SwapCallback` validates the pool by reconstructing its address from the expected parameters.
- **The contract accepts arbitrary ETH.** That is necessary for unwraps and V4 settlement, but stray ETH can remain stranded.

## 6. MEV Surface

- **V3 path is TWAP-protected.** A 10-minute TWAP makes single-block manipulation much harder.
- **V4 path is TWAP-first, spot-fallback.** When no oracle quote is available, the spot fallback is vulnerable.
- **Cross-route arbitrage exists.** When JB routing bypasses the AMM, differences between bonding-curve price and AMM price create arbitrage opportunities.

## 7. Invariants To Verify

- after any `pay()` or `addToBalanceOf()`, the router should not retain balances attributable to the just-processed route
- `minAmountOut` in swaps is never zero when TWAP or spot price is available
- `uniswapV3SwapCallback` only transfers tokens to verified pool addresses
- `unlockCallback` only executes when called by `POOL_MANAGER`
- credit cash-out only transfers credits from `_msgSender()`
- the cash-out loop always terminates: it finds a terminal, hits the loop limit, or reverts for lack of path

## 8. Accepted Behaviors

### 8.1 No reentrancy guard

The router has no `ReentrancyGuard` or `_routing` flag. This is intentional because the router is designed as a stateless routing layer, not a persistent accounting surface. Each call must fund and resolve its own route, and a blanket reentrancy guard would break legitimate composed routing flows.

### 8.2 Router trusts `originalPayer()` from any caller that implements it

`_resolveRefundWithBackupRecipient` calls `IJBPayerTracker(msg.sender).originalPayer()` in a `try/catch`. If the caller returns a non-zero address, leftovers can be sent there. This is accepted because the caller already supplied the funds being routed.

### 8.3 Cash-out loop slippage is first-hop only

`_cashOutLoop` applies `cashOutMinReclaimed` to the first cash-out step only. Later recursive hops may reclaim different assets with different units, so reusing one minimum across the full loop would be unsound.

### 8.4 Liquidity-first pool selection is intentional

The router does not do an exhaustive best-execution search across every viable V3 and V4 pool. It prefers bounded discovery, lower complexity, and predictable behavior.

### 8.5 Registry owns immediate circular-forward protection

The router and resolver no longer contain registry-specific circular-resolution logic. `JBRouterTerminalRegistry` rejects forwarding back into its immediate caller instead.

### 8.6 V4 spot fallback is an accepted risk for programmatic integrations

Automatic V4 quoting first tries a hook-provided oracle observation and falls back to spot only when that quote is unavailable. The fallback is still manipulable and is accepted only as a bounded on-chain quoting path for integrations that cannot provide `quoteForSwap` metadata.
