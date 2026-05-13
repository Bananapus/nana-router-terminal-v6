# Accepted Security Risks

Documented risks that were reviewed and accepted.

## Oracle & Slippage Risks

**Pool-local V3 TWAP trusted as swap floor for permissionless pools.** *(Medium)*
An attacker could deploy a manipulable pool with higher liquidity to become the selected candidate. Users should provide `quoteForSwap` metadata from off-chain sources. Mitigated by 120s minimum TWAP window and sigmoid slippage formula.

**Liquidity-based pool selection enables unsafe spot quoting.** *(Medium)*
Pool discovery ranks candidates by instantaneous liquidity, so an attacker could inflate liquidity to force selection of a manipulable pool. Mitigated by V4 TWAP hardening and sigmoid slippage formula. Users should provide off-chain quotes for high-value swaps.

**Harmonic-mean liquidity inflates V3 slippage tolerance.** *(Medium)*
`OracleLibrary.consult` returns harmonic-mean liquidity, which can be deflated by brief low-liquidity periods. However, harmonic mean is more resistant to manipulation than spot liquidity. Mitigated by 120s TWAP minimum and 10-minute default observation window.

**V4 TWAP branch uses live in-range liquidity for slippage tolerance, not time-averaged.** *(Medium)*
In `_getV4SpotQuote`, when the V4 hook provides a TWAP tick (`usedTwap = true`), the gross quote tick is time-averaged but `_getLiquidity(id)` reads `POOL_MANAGER.getLiquidity(id)` — the CURRENT in-range liquidity. That live value feeds `_quoteWithSlippage` → `_getSlippageTolerance` → `JBSwapLib.calculateImpact`, where the sigmoid `tolerance = minSlippage + range * impact / (impact + K)` is monotonically increasing in impact. An attacker who thins in-range liquidity around quote time inflates the modeled impact and widens the tolerance up to `MAX_SLIPPAGE = 8800` (88%). Asymmetric vs the V3 path, which feeds `OracleLibrary.consult`'s `harmonicMeanLiquidity` over the same window into the same sigmoid.

Why the practical impact is bounded rather than catastrophic:
1. The TWAP tick anchors the gross quote price over the 120s window — an attacker cannot move the priced tick within a single block, only widen the tolerance band around it.
2. Callers can pass `quoteForSwap` metadata to bypass the V4 spot-quote path entirely.
3. Pool selection in `_pickPoolAndQuote` can choose a V3 pool over V4 if it has more liquidity (and V3 uses harmonic-mean liquidity).

Frontends and programmatic callers that route value-sensitive swaps through V4 should always supply `quoteForSwap` rather than relying on the auto-quoted minimum-out. The in-code `SECURITY NOTE` at `JBRouterTerminal.sol:2286-2312` covers the same surface from the pool-selection angle.

**`quoteForSwap` / auto-selected tokenOut mismatch.** *(Minor)*
When a user provides `quoteForSwap` metadata, the quote may not match the auto-selected output token. Frontends should set `quoteForSwap` per the expected output token.

**Multi-hop cashout slippage cleared after first hop.** *(Minor)*
Only the final output matters; the outer function enforces end-to-end minimum via `minReclaimed`. Intermediate per-hop slippage checks are intentionally omitted. Maximum 20 recursive cashout iterations allowed (`_MAX_CASHOUT_ITERATIONS`); beyond that the operation reverts.

**Zero oracle quote disables swap protection.** *(Minor)*
When the oracle returns zero (no liquidity), slippage tolerance becomes zero. The swap would fail anyway due to lack of liquidity, so this has no practical impact.

> **Note:** The V4 TWAP window was hardened from 30s to 120s. This is no longer an accepted risk -- it was fixed.

## Registry & Forwarding Risks

**Credit cash-outs are not supported.** *(Documented limitation)*
The router does not accept project-token credits as an input. Holders of unclaimed Juicebox credits must first call `JBTokens.claimFor` (or equivalent) to materialize the credits as ERC-20 tokens, then route through the router as a normal ERC-20 payment. This was an intentional simplification: supporting credit inputs required pulling credits via `IJBController.transferCreditsFrom` and carrying a `cashOutSource` metadata override through the cashout loop, which added attack surface (the holder had to be sourced from `msg.sender` rather than `originalPayer()` to prevent spoofing) and ~580 bytes of runtime size. Removing it leaves credit holders with a two-tx flow (`claimFor` → `router.pay`) but keeps the router's contract size below the EIP-170 24,576 B limit with room for future features.

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

## Pool Discovery Risks

**Fresh high-liquidity V3 pool without TWAP history can block auto-quoting.** *(Minor)*
`_discoverPool` selects the highest-liquidity V3 pool, but `_getV3TwapQuote` requires sufficient observation history. A freshly deployed pool with high liquidity wins discovery but fails the TWAP check, reverting the routing flow while lower-liquidity pools with adequate TWAP are ignored. Accepted because: (1) this is self-correcting — the pool accumulates observations over time, (2) the griefing cost is high — attacker must deploy real liquidity, (3) callers can bypass auto-quoting entirely by providing `quoteForSwap` metadata, and (4) the condition is temporary and resolves within the TWAP observation window (default 10 minutes).

## Multi-Chain Native Token Assumption

**Router assumes the chain has a native token with a WETH9-compatible wrapper.** *(Informational)*
The `WRAPPED_NATIVE_TOKEN` constructor parameter must be a WETH9-compatible contract (`deposit()` / `withdraw()` interface). On Ethereum this is WETH, on Celo it would be WCELO, etc. On chains without a native token (e.g. Tempo), the router's native-token swap and refund paths are not applicable — the router should either not be deployed, or the `WRAPPED_NATIVE_TOKEN` should be set to a no-op wrapper. All native-token routing logic (`_wrapNativeToken`, `_unwrapNativeToken`, `receive()`, V4 settlement with `msg.value`) depends on this assumption.
