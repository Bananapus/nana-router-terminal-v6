# Accepted Security Risks

Documented risks that were reviewed and accepted.

## Oracle & Slippage Risks

**Pool-local V3 TWAP trusted as swap floor for permissionless pools.** *(Medium)*
An attacker could deploy a manipulable pool with higher liquidity to become the selected candidate. Users should provide `quoteForSwap` metadata from off-chain sources. Mitigated by 120s minimum TWAP window and sigmoid slippage formula.

**Liquidity-based pool selection enables unsafe spot quoting.** *(Medium)*
Pool discovery ranks candidates by instantaneous liquidity, so an attacker could inflate liquidity to force selection of a manipulable pool. Mitigated by V4 TWAP hardening and sigmoid slippage formula. Users should provide off-chain quotes for high-value swaps.

**Harmonic-mean liquidity inflates V3 slippage tolerance.** *(Medium)*
`OracleLibrary.consult` returns harmonic-mean liquidity, which can be deflated by brief low-liquidity periods. However, harmonic mean is more resistant to manipulation than spot liquidity. Mitigated by 120s TWAP minimum and 10-minute default observation window.

**`quoteForSwap` / auto-selected tokenOut mismatch.** *(Minor)*
When a user provides `quoteForSwap` metadata, the quote may not match the auto-selected output token. Frontends should set `quoteForSwap` per the expected output token.

**Multi-hop cashout slippage cleared after first hop.** *(Minor)*
Only the final output matters; the outer function enforces end-to-end minimum via `minReclaimed`. Intermediate per-hop slippage checks are intentionally omitted. Maximum 20 recursive cashout iterations allowed (`_MAX_CASHOUT_ITERATIONS`); beyond that the operation reverts.

**Zero oracle quote disables swap protection.** *(Minor)*
When the oracle returns zero (no liquidity), slippage tolerance becomes zero. The swap would fail anyway due to lack of liquidity, so this has no practical impact.

> **Note:** The V4 TWAP window was hardened from 30s to 120s. This is no longer an accepted risk -- it was fixed.

## Registry & Forwarding Risks

**Registry forwarding uses registry as credit holder.** *(Medium)*
When payments flow through the registry, credits accrue to the registry address, not the original user. Credit-based cashouts must go directly to the router terminal, not through the registry. This is intentional to prevent `originalPayer()` spoofing attacks.

**Forwarding-terminal receipt bypass.** *(Minor)*
`_isForwardingTerminal` bypasses receipt validation on incoming transfers. Forwarding terminals are registered by project owners and therefore trusted to handle receipts correctly.

**Forwarder claim disables receipt check.** *(Minor)*
Forwarding terminals registered by project owners are trusted to handle receipts correctly, so receipt validation is skipped for these callers.

## Token Compatibility Risks

**Fee-on-transfer (FOT) tokens not supported for routed payments.** *(Medium)*
The `pay()` flow does not enforce an ERC-20 receipt check (balance-delta validation) on the destination terminal. This was intentionally removed because pay hooks attached to the destination terminal can legitimately consume tokens during `pay()`, making a balance-delta check produce false reverts for any project with active pay hooks. As a consequence, fee-on-transfer tokens will silently lose value during routing — the terminal receives fewer tokens than `amount` but the router cannot detect this. Projects using FOT tokens should route payments directly to the terminal, bypassing the router. The `addToBalanceOf()` flow retains receipt enforcement since it has no hooks.

## Minor Configuration Risks

**Unbounded quadratic candidate enumeration.** *(Minor)*
`_candidatePayRouteTokens` can enumerate O(n^2) candidates in theory. Bounded in practice to ~5-10 terminals per project, keeping gas costs manageable.

**Permit2 try/catch falls through to ERC20 allowance.** *(Minor)*
Standard Permit2 fallback pattern. If Permit2 signature verification fails, the contract falls back to standard ERC20 `transferFrom` using existing allowance.
