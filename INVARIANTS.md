# Invariants of `nana-router-terminal-v6`

Scope: three contracts in this package — `JBRouterTerminal` (universal-token payment terminal), `JBRouterTerminalRegistry` (per-project terminal selection with cohort-stable defaults), and `JBPayRouteResolver` (preview-only route ranking helper). Package: `@bananapus/router-terminal-v6`.

Trust model in one sentence: the router is a **stateless routing surface** that accepts ANY token, normalizes through Uniswap V3/V4 swaps and recursive JB cashout loops, and forwards into a destination terminal whose `minReturnedTokens` is the authoritative slippage gate — the router does not account for project balances as surplus, refunds route-scoped partial-fill leftovers to the *true* original payer (propagated through transient storage when called via the registry), rejects ERC-20 receipt shortfalls at the final hop on `addToBalanceOf`, and rejects circular forwarding cycles before any irreversible state is written.

This file documents invariants enforced by the **runtime contracts in this repo**. The destination-terminal slippage guarantee, fee semantics, and ruleset state machine all live in `nana-core-v6/INVARIANTS.md`. Cashout-loop economic safety against revenue-recursion attacks ultimately depends on the bonding-curve guarantees documented at `../INVARIANTS.md` Section A.2.

---

## Section A — Guarantees to paying users

### A.1 Authoritative slippage lives at the destination terminal

- Both `pay` (`JBRouterTerminal.sol:342-394`) and the registry's `pay` (`JBRouterTerminalRegistry.sol:571-622`) forward `minReturnedTokens` unchanged into the destination terminal's `pay` call. The destination terminal — never the router — is responsible for reverting if `beneficiaryTokenCount < minReturnedTokens`.
- The router does NOT independently enforce a beneficiary-token floor on `pay`; that floor is delegated to the destination terminal. This is intentional: pay hooks attached to the destination terminal may legitimately consume terminal-token balance during `pay()`, so a router-side balance-delta check would produce false reverts (`JBRouterTerminal.sol:389-393`).
- On `addToBalanceOf` (no minting, no pay hooks), the router DOES enforce a final-hop ERC-20 receipt check: `_enforceStandardTerminalReceipt` requires the destination terminal's pre- and post-call balance delta to be at least the forwarded amount and reverts `JBRouterTerminal_NonStandardTerminalToken` on any shortfall (`JBRouterTerminal.sol:365-372, 1048-1066`). Benign surplus receipts are accepted. Forwarding terminals are excluded (they enforce their own final hop), and native-token hops are excluded (value transfer is not observable via ERC-20 balance).
- Fee-on-transfer (FoT) tokens are **not supported as the final hop on `pay`** — the destination terminal would receive less than `amount`, and the router cannot detect this. This is acknowledged in code at `JBRouterTerminal.sol:389-393` and called out in `RISKS.md`.
- **Quote-less swaps on un-backstopped legs require a manipulation-resistant price.** `addToBalanceOf` (and cash-out routes that settle via add-to-balance) have no `minReturnedTokens` floor, so a swap through a vanilla V4 pool — which exposes no on-chain TWAP — must NOT fall back to the manipulable spot tick. The transient `_strictSwapQuote` flag is set true on those legs and false on `pay` (and previews); when set, `_getV4SpotQuote` reverts `JBRouterTerminal_ManipulationResistantQuoteRequired` unless the caller supplied a `pay` quote. V3 routing (factory-verified + TWAP) and canonical-hook V4 pools (geomean oracle) are unaffected; the backstopped `pay` leg keeps the bounded spot fallback.

### A.2 Balance-delta accounting on inbound transfers

- `_acceptFundsFor` (`JBRouterTerminal.sol:1050-1097`, registry `:703-750`) snapshots `IERC20.balanceOf(address(this))` before the inbound `transferFrom` and returns the post-transfer delta — NOT the nominal `amount` the caller passed. This means a fee-on-transfer source token results in the *actually received* amount being routed, instead of the router attempting to push out a phantom balance it never received.
- The same balance-delta pattern is used inside the recursive cashout loop (`JBRouterTerminal.sol:1184-1207`): each hop measures the reclaimed balance via `_balanceOf` delta, and a non-zero cashout that delivers no reclaim tokens reverts `JBRouterTerminal_CashOutDidNotDeliver`. Buyback-hook sell-side execution returns `reclaimAmount = 0` from the terminal but delivers proceeds via the hook callback; the balance-delta measurement is the only sound way to detect actual receipt across both paths.
- Before each source-project cash-out, the router claims any credits it already holds for that source project into ERC-20 project tokens. Core burns credits before ERC-20 balances, so this keeps the burn side aligned with the router's token-balance accounting while preserving the rule that users cannot pass credits directly as router input.
- Inside `_handleSwap`, the router compares the post-swap normalized-input balance against `refundBalanceBaseline` (`JBRouterTerminal.sol:1127-1133, 1465-1479`) so refunds for partial fills do not sweep ambient router balances. Pre-existing tokens parked on the router from a stuck flow are NOT swept into the current refund.
- The same partial-fill principle applies to the source cash-out loop: when a buyback-hook fill is partial it returns the unsold source project tokens to the router (the holder), so each hop measures that residue as `balanceAfter + cashOutCount - sourceBalanceBefore` — exactly the hook's returned unsold count — and refunds it to the route's `refundTo`. This both prevents the residue from stranding on the router and, by baselining against the per-hop source balance, never sweeps pre-existing/ambient balances of that token.

### A.3 Leftover refunded to the *true* originating payer

- The router refunds partial-fill leftovers to `refundTo`, which is set to `_resolveOriginalPayer(_msgSender())` on every `pay`/`addToBalanceOf` (`JBRouterTerminal.sol:277, 368`).
- `_resolveOriginalPayer` (`JBRouterTerminal.sol:761-769`) probes the immediate caller via `IJBPayerTracker.originalPayer()` if the caller has code, and uses the returned address when non-zero; otherwise it falls back to the resolved ERC-2771 sender.
- The registry implements `IJBPayerTracker` by writing the resolved payer into the `transient` storage slot `originalPayer` (`JBRouterTerminalRegistry.sol:109, 445-450, 595-601`) BEFORE the forwarded call and clearing it back to the previously-stored value AFTER (supports nested reentrant forwards through pay hooks). `_originalPayerOrSender` (`JBRouterTerminalRegistry.sol:318-337`) walks one additional hop: if the caller of the registry is itself an `IJBPayerTracker`, the upstream payer is propagated — so a `projectPayer -> registry -> router` chain refunds the originator, not the intermediary project payer.
- A direct caller to the router (no intermediary, no `IJBPayerTracker` interface) gets refunds to its own ERC-2771-resolved address — the common direct-EOA case.
- Native-token refunds fall back to the wrapped-native ERC-20 form if the recipient rejects ETH (`JBRouterTerminal.sol:1468-1478`), so contract recipients without a `receive()` still get value back.

### A.4 Cashout-loop bounded, fail-safe, and unit-correct

- `_cashOutLoop` (`JBRouterTerminal.sol:1143-1236`) iterates at most `_MAX_CASHOUT_ITERATIONS = 20` (`:111`) and reverts `JBRouterTerminal_CashOutLoopLimit` on exceedance. This bounds gas and forecloses on infinite-recursion routes constructed by adversarial project-token graphs.
- The user-supplied `cashOut` (from metadata) is enforced ONLY on the first hop (`JBRouterTerminal.sol:1153-1224`). The metadata encodes one concrete token amount and later hops change token units (project token → ETH → USDC), so carrying it across hops would mix incompatible units. Multi-hop integrators must price slippage at the final-pay step or use the explicit single-hop preview helpers.
- Each cashout call is wrapped with `minTokensReclaimed = 0` at the terminal level because the buyback-hook sell-side delivers proceeds via callback (terminal's `reclaimAmount = 0`); the router enforces the user's minimum via the balance-delta check immediately after.
- Cashout-path discovery (`_findCashOutPath`) prioritizes (1) tokens the destination directly accepts via a usable primary terminal, (2) non-JB base tokens that can exit the recursion via a swap, (3) JB project tokens (recursable). Codeless terminal entries and candidate terminals whose ERC-165, `accountingContextsOf`, or destination primary-terminal probes fail are skipped, so one broken source or destination terminal does not DoS enumeration. When no path advances the route, `JBRouterTerminal_NoCashOutPath` reverts — the router never silently drops the user's input on the floor.

### A.5 Quote vs TWAP slippage protection

- When the metadata carries an explicit `pay` swap quote, `_pickPoolAndQuote` bypasses the on-chain quoting path entirely and uses the caller-supplied `(tokenOut, minAmountOut)` — the quote token must match the expected output or the swap reverts `JBRouterTerminal_QuoteTokenMismatch` (`:90`).
- When no quote is supplied for V3 pools, `_getV3TwapQuote` (`:2194-2247`) reads the V3 oracle's arithmetic-mean tick over `DEFAULT_TWAP_WINDOW = 10 minutes` (`:99`), clamped down by the pool's oldest-observation age. Insufficient TWAP history (`< MIN_TWAP_WINDOW = 120s`) reverts `JBRouterTerminal_InsufficientTwapHistory` (`:103, 80`). Zero in-range liquidity in the chosen window reverts `JBRouterTerminal_NoLiquidity`.
- When no quote is supplied for V4 pools, `_getV4SpotQuote` (`:2287+`) prefers a hook-provided geomean/TWAP quote (`IGeomeanOracle.observe`) and falls back to the V4 slot0 spot tick. The spot-fallback path is **accepted-risk** for routine flows against deep pools and is bounded by a fixed 15% haircut; thin pools and large swaps should ALWAYS supply `pay` swap-quote. See the NatSpec block at `JBRouterTerminal.sol:2249-2281` for the full operating envelope.
- V3 and V4 swap execution both enforce realized-output ≥ `minAmountOut` post-swap (V3: `JBRouterTerminal.sol:1373-1377`; V4: `unlockCallback` at `:494-497`). Slippage limits live with the realized delta, not the sqrt-price bound (which conflates marginal and average price).

### A.6 No circular routing

- The registry rejects any explicit terminal selection that would forward back into itself: `_requireNonCircularTerminalFor` (`JBRouterTerminalRegistry.sol:345-351`) calls `JBForwardingCheck.isCircularTerminal` (depth-5 walk) on `setTerminalFor`, `lockTerminalFor`, and `setDefaultTerminal`.
- The registry additionally blocks immediate-caller cycles at forward time via `_enforceNoCircularForward` (`JBRouterTerminalRegistry.sol:294-297, 453, 604`): a router that calls back into the registry mid-forward reverts `JBRouterTerminalRegistry_CircularForward` instead of looping until out-of-gas.
- The router-side analogues — `_usablePrimaryTerminalOf` (`JBRouterTerminal.sol:1017-1036`) and the resolver's `_isCircularTerminal` (`JBPayRouteResolver.sol:403`) — drop any candidate terminal whose forwarding chain points back at the router so preview-time selection and execution-time selection agree.

---

## Section B — Guarantees to project operators / owners

### B.1 Per-project terminal selection (`SET_ROUTER_TERMINAL`)

- `setTerminalFor(projectId, terminal)` (`JBRouterTerminalRegistry.sol:672-691`) is callable by the project owner (`PROJECTS.ownerOf(projectId)`) OR an operator holding `JBPermissionIds.SET_ROUTER_TERMINAL`. It enforces, in this exact order:
  1. `hasLockedTerminal[projectId] == false` — otherwise reverts `JBRouterTerminalRegistry_TerminalLocked` (`:48, 674`).
  2. `isTerminalAllowed[terminal] == true` — otherwise reverts `JBRouterTerminalRegistry_TerminalNotAllowed` (`:50, 676`).
  3. `_requireNonCircularTerminalFor(projectId, terminal)` — depth-5 walk that catches transitive cycles (`:345-351, 679`).
  4. `_requirePermissionFrom(account: PROJECTS.ownerOf, projectId, permissionId: SET_ROUTER_TERMINAL)` (`:682-686`).
- Order matters: lock-state is checked first so a locked project can't be silently re-allowed; allowlist is checked before the cycle walk so cheap rejection paths run early; permission is the last gate so a non-authorized caller doesn't learn about routing topology via differential reverts.

### B.2 Permanent commitment via `lockTerminalFor`

- `lockTerminalFor(projectId, expectedTerminal)` (`JBRouterTerminalRegistry.sol:506-537`) is the irreversible commitment surface. Same permission set as `setTerminalFor`. Race-safe: when no explicit override exists, the function snapshots the THRESHOLD-RESOLVED default into `_terminalOf` first (`:517-522`), then compares it against `expectedTerminal`, reverting `JBRouterTerminalRegistry_TerminalMismatch` if a default change raced ahead of the lock (`:524-529`).
- The lock captures whatever default applied to *this specific project's cohort*, NOT the registry-wide `defaultTerminal`. When no default has ever been set, a project has no cohort default to lock — which is why `lockTerminalFor` reverts `JBRouterTerminalRegistry_TerminalNotSet` if both the explicit override and the cohort default are zero (`:520`).
- Once `hasLockedTerminal[projectId] = true`, `setTerminalFor` reverts permanently for that project. There is no unlock function.

### B.3 Cohort-stable defaults — the silent-reroute guard

- `setDefaultTerminal(terminal)` (`JBRouterTerminalRegistry.sol:638-671`) is `onlyOwner`. Each call:
  1. Rejects zero address and self-address (`:639-640`).
  2. Validates non-circularity against the current `PROJECTS.count()` snapshot (`:642-647`).
  3. Records a `DefaultTerminalSegment{minProjectIdExclusive: previousThreshold, maxProjectId: count, terminal: ...}` into `_defaultTerminalHistory` (`:656-662`). On the very first call (`defaultTerminal == 0`) the segment maps the projects that already existed — the pre-existing cohort, including the canonical fee project (ID 1) — onto the NEW default, so they can route tokens through it. On every later call the segment instead pins the OUTGOING default to its own cohort.
  4. Updates `defaultTerminal` and `defaultTerminalProjectIdThreshold = count` (`:664-665`).
  5. Allowlists the new default (`:668`).
- `_defaultTerminalFor(projectId)` (`JBRouterTerminalRegistry.sol:361-378`) returns:
  - `defaultTerminal` if `projectId > defaultTerminalProjectIdThreshold` (new projects pick up the current default), else
  - the first history segment whose `(minProjectIdExclusive, maxProjectId]` covers `projectId` (the pre-existing cohort resolves to the first default; later cohorts keep what was active when their range was created), else
  - `address(0)` only when no default has ever been set.
- **Invariant (serve-then-freeze):** the first default serves every project that already existed when it was set, and from then on existing projects without an explicit `_terminalOf` override CANNOT be silently rerouted by a later `setDefaultTerminal` call. The owner can change where *new* cohorts land, but the route surfaces for already-deployed projects are frozen.

### B.4 Registry-owner allowlist surface

- `allowTerminal(terminal)` (`JBRouterTerminalRegistry.sol:475-481`) and `disallowTerminal(terminal)` (`:487-498`) are `onlyOwner`.
- `disallowTerminal` reverts `JBRouterTerminalRegistry_CannotDisallowDefaultTerminal` if `terminal == defaultTerminal` (`:489-491`) — preventing the owner from leaving the registry in a state where the current default is rejected by `setTerminalFor`. Owner must change the default first.
- Disallowing a terminal does NOT retroactively unset projects that already pinned it; existing `_terminalOf` overrides survive. This is consistent with the cohort-stability principle: the registry never silently reroutes value flows post-deploy.

### B.5 Powers the registry owner does NOT have

- **Cannot redirect existing project's payments.** All silent-reroute paths are closed by the cohort-stable default mechanism (B.3) and the lock surface (B.2). The only way to change a project's resolved terminal is for the project owner / `SET_ROUTER_TERMINAL` operator to call `setTerminalFor`.
- **Cannot intercept funds.** Neither the router nor the registry holds project balances between calls. Both contracts only hold tokens for the duration of a single inbound `pay`/`addToBalanceOf` call, and any leftover is refunded to the originating payer (A.3) or pushed into the destination terminal.
- **Cannot bypass per-project permission gates.** `setTerminalFor` and `lockTerminalFor` always route through `_requirePermissionFrom(PROJECTS.ownerOf(projectId), ...)`.

---

## Section C — Per-contract operation inventory

All file:line references are to `src/<ContractName>.sol` unless otherwise noted.

### C.1 `JBRouterTerminal`

Implements `IJBTerminal`, `IJBPermitTerminal`, `IUniswapV3SwapCallback`, `IUnlockCallback`, `IJBRouterTerminal`, `IJBPayRoutePreviewer`. ERC-2771 trusted forwarder aware.

**Paying users (permissionless):**

- **`pay(projectId, token, amount, beneficiary, minReturnedTokens, memo, metadata) payable → beneficiaryTokenCount`** — `:342-394`.
  - Accepts caller funds via `_acceptFundsFor` (balance-delta, Permit2-aware); resolves best route via `_routeForPay`; converts to destination token via swap/cashout/no-op; forwards `pay` into destination terminal with caller's `minReturnedTokens` intact.
  - **Invariants:** destination terminal enforces `minReturnedTokens`; refunds go to original payer; balance-delta accounting on inbound; FoT NOT supported on final hop (acknowledged); pay-hook side effects on destination terminal are not double-charged because the router never re-asserts ERC-20 receipt on `pay`.
  - **Cannot:** mint project tokens; charge fees; modify accounting contexts on the destination terminal.

- **`addToBalanceOf(projectId, token, amount, shouldReturnHeldFees, memo, metadata) payable`** — `:305-376`.
  - Accepts, routes, forwards. ERC-20 final-hop shortfall enforcement via `_enforceStandardTerminalReceipt` (`:365-372, 1048-1066`).
  - **Invariants:** balance-delta on inbound; ERC-20 receipt must be at least the forwarded amount at the destination (non-native, non-forwarding); leftover refunded.
  - **Cannot:** mint project tokens; bypass the destination terminal's `shouldReturnHeldFees` semantics.

**Owner-only (deployer one-shot):**

- **`setChainSpecificConstants(IWETH9 newWrappedNativeToken, IUniswapV3Factory newFactory, IPoolManager newPoolManager, address newUniv4Hook)`** — `:407-421`.
  - Authorized solely by `_DEPLOYER` (held as internal immutable). One-shot: reverts `JBRouterTerminal_AlreadyConfigured` once `wrappedNativeToken != address(0)`.
  - **Invariant:** the four chain-specific constants are byte-different per chain (Uniswap factory, V4 PoolManager, V4 hook, WETH) but configured once; the contract's CREATE2 inputs stay byte-identical across chains so its deployed address is unified. Mirrors the `setChainSpecificConstants` pattern from `nana-suckers-v6`.

**Authenticated callbacks:**

- **`uniswapV3SwapCallback(amount0Delta, amount1Delta, data)`** — `:499-522`.
  - Requires `msg.sender == _v3ExpectedPool`, which `_executeV3Swap` sets immediately before the synchronous `pool.swap` call and clears immediately after it returns (`:1464-1473`). Then decodes `tokenIn` from `data` and settles the positive delta to that pool (wrapping native if `tokenIn` was the native sentinel).
  - **Invariant:** only the V3 pool that the router itself synchronously entered can pull callback settlement tokens; spoofed or out-of-band callbacks revert before any value moves.

- **`unlockCallback(data)`** — `:455-508`.
  - Authenticated by `msg.sender == address(poolManager)` (`:456`). Executes the V4 swap, enforces `amountOut >= minAmountOut` BEFORE settling and taking (`:494-497`), then settles input + takes output via `_settleV4` / `_takeV4`.
  - **Invariant:** only the configured PoolManager can drive V4 swap execution through the router.

**External views (best-effort surfaces):**

- **`accountingContextForTokenOf(_, token) → JBAccountingContext`** — `:518-539`. Synthetic: probes `IJBToken.decimals()` with `try/catch`, defaults to 18 on failure.
- **`accountingContextsOf(projectId) → []`** — `:545-553`. Empty array — the router resolves accounting contexts at runtime.
- **`currentSurplusOf(...) → 0`** — `:562-578`. Always zero (router holds no balances).
- **`migrateBalanceOf(...) → 0`** — `:316-330`. Always zero (no balance to migrate).
- **`discoverBestPool(normalizedTokenIn, normalizedTokenOut) → PoolInfo`** — `:584-599`. Reverts `JBRouterTerminal_NoPoolFound` if neither V3 nor V4 has a candidate pool.
- **`discoverPool(normalizedTokenIn, normalizedTokenOut) → IUniswapV3Pool`** — `:631-644`. V3-only convenience wrapper for off-chain queries. Returns the deepest V3 pool whenever one exists (via the `_discoverV3Pool` helper), independent of whether a deeper V4 pool exists for the pair; reverts `JBRouterTerminal_NoPoolFound` only when no V3 pool exists at all.
- **`bestPoolLiquidityOf(tokenA, tokenB) → uint128`** — `:735-737`. The liquidity heuristic the resolver uses to rank candidate accepted tokens.

**Preview surfaces (off-chain quote producers):**

- **`previewPayFor(projectId, token, amount, beneficiary, metadata) → (ruleset, beneficiaryTokenCount, reservedTokenCount, hookSpecifications)`** — `:633-653`. Delegates to `_PAY_ROUTE_RESOLVER.previewBestPayRoute` so the runtime size of `JBRouterTerminal` stays under EIP-170.
- **`previewCashOutLoopOf(destProjectId, token, amount, metadata, preferredToken) → (destTerminal, finalToken, finalAmount)`** — `:664-682`. Simulates the recursive cashout walk that `_cashOutLoop` would take.
- **`previewSwapAmountOutOf(tokenIn, tokenOut, amount, metadata) → amountOut`** — `:690-701`. Quotes a direct swap using the same `_pickPoolAndQuote` path execution uses.
- **`previewTerminalPayOf(destTerminal, projectId, token, amount, beneficiary, metadata) → (ruleset, beneficiaryTokenCount, reservedTokenCount, hookSpecifications)`** — `:714-729`. Thin wrapper over the destination terminal's `previewPayFor`.

**Public immutables / stored chain-specific constants:**

- `BUYBACK_HOOK` (canonical buyback hook address; immutable; `:127`).
- `DIRECTORY` (`IJBDirectory`; immutable; `:130`).
- `PERMIT2` (`IPermit2`; immutable; `:133`).
- `TOKENS` (`IJBTokens`; immutable; `:136`).
- `_DEPLOYER` (internal immutable, never exposed publicly; `:145`).
- `_PAY_ROUTE_RESOLVER` (internal immutable; deployed in the constructor at the router's nonce 1 so its address is unified across chains; `:152, 219`).
- `factory`, `poolManager`, `univ4Hook`, `wrappedNativeToken` — stored, set once by `_DEPLOYER` via `setChainSpecificConstants`. After the one-shot setter, effectively immutable for the contract's lifetime.

### C.2 `JBRouterTerminalRegistry`

Implements `IJBRouterTerminalRegistry`, `IJBForwardingTerminal`, `IJBTerminal`, `IJBPayerTracker`. Inherits `JBPermissioned`, `Ownable`, `ERC2771Context`.

**Paying users (permissionless):**

- **`pay(projectId, token, amount, beneficiary, minReturnedTokens, memo, metadata) payable → result`** — `:571-622`.
  - Resolves terminal via `_requireResolvedTerminalOf` (reverts `JBRouterTerminalRegistry_TerminalNotSet` if both override and cohort default are zero); accepts funds (balance-delta + Permit2); writes `originalPayer` to transient storage (with previous-payer save/restore so nested reentrant calls through pay hooks restore correctly); rejects immediate-caller cycles; forwards; revokes any leftover allowance.
  - **Invariants:** `minReturnedTokens` forwarded intact; circular forwards blocked; original payer propagated through transient storage; previous payer restored after forward to support reentrancy.

- **`addToBalanceOf(projectId, token, amount, shouldReturnHeldFees, memo, metadata) payable`** — `:423-470`.
  - Same pattern; no `minReturnedTokens`. Same transient `originalPayer` propagation.

**Project owners / operators (`SET_ROUTER_TERMINAL`):**

- **`setTerminalFor(projectId, terminal)`** — `:672-691`. See B.1.
- **`lockTerminalFor(projectId, expectedTerminal)`** — `:506-537`. See B.2.

**Registry owner (`onlyOwner`):**

- **`allowTerminal(terminal)`** — `:475-481`.
- **`disallowTerminal(terminal)`** — `:487-498`. Reverts on current default.
- **`setDefaultTerminal(terminal)`** — `:633-666`. Snapshots outgoing default into `_defaultTerminalHistory`. Auto-allowlists the incoming default.

**Views:**

- **`accountingContextForTokenOf(projectId, token)` / `accountingContextsOf(projectId)`** — `:144-174`. Read-only discovery views: delegate to the resolved terminal, or **fail open** — return an empty context / empty array (NOT revert) when no terminal resolves (no default set for the project's cohort). Callers such as `JBDirectory.primaryTerminalOf` read an empty context as "not accepted" and fall through, so a cold-start registry never bricks the caller's originating operation. The transactional paths (`pay`, `addToBalanceOf`, `lockTerminalFor`) still revert `JBRouterTerminalRegistry_TerminalNotSet` in that case.
- **`currentSurplusOf(...) → 0`** — `:182-198`. Always zero.
- **`defaultTerminalFor(projectId) → IJBTerminal`** — `:204-206`. Public view over `_defaultTerminalFor`.
- **`defaultTerminalHistoryAt(index) → DefaultTerminalSegment`** — `:211-218`.
- **`defaultTerminalHistoryLength() → uint256`** — `:223-225`.
- **`previewPayFor(projectId, token, amount, beneficiary, metadata)`** — `:238-263`. Forwards to the resolved terminal's `previewPayFor`.
- **`terminalOf(projectId) → IJBTerminal`** — `:266-268`. `IJBForwardingTerminal` surface; returns zero only when no default has ever been set.
- **`originalPayer() → address`** — transient storage view; `:109`. Reads as zero outside an in-flight forward.

**Public immutables / stored:**

- `PROJECTS` (`IJBProjects`; immutable; `:59`).
- `PERMIT2` (`IPermit2`; immutable; `:62`).
- `defaultTerminal` (`IJBTerminal`; storage; `:72`).
- `defaultTerminalProjectIdThreshold` (`uint256`; storage; `:80`).
- `hasLockedTerminal[projectId]` (`bool`; storage; `:84`).
- `isTerminalAllowed[terminal]` (`bool`; storage; `:88`).
- `_defaultTerminalHistory` (`DefaultTerminalSegment[]`; internal; append-only; `:98`).
- `_terminalOf[projectId]` (`IJBTerminal`; internal; `:102`).
- `originalPayer` (`address transient`; `:109`).

### C.3 `JBPayRouteResolver`

Stateless preview helper deployed at the router's nonce 1. Constructor input is only `directory` — wrapped-native-token is NOT cached locally; the router passes it in on every external call to keep the resolver's CREATE2 inputs byte-identical across chains.

**External views (preview-only):**

- **`previewBestPayRoute(router, wrappedNativeToken, projectId, tokenIn, amount, beneficiary, metadata) → (destTerminal, tokenOut, amountOut, ruleset, beneficiaryTokenCount, reservedTokenCount, hookSpecifications)`** — `:847-1009`.
  - Honors a `routeTokenOut` override in metadata (`:875-902`); otherwise enumerates the destination project's accepted tokens via `_candidatePayRouteTokens`, scores each candidate by routing the input through it and running the terminal preview, and returns the winner by `beneficiaryTokenCount` with `reservedTokenCount` tie-break (`:914-958`). Codeless terminal entries, reverting accounting-context probes, and reverting primary-terminal lookups are skipped during enumeration. Each candidate preview runs via external self-call (`try/catch`) so a single broken candidate cannot DoS the entire scoring loop.
  - When a terminal preview returns zero token counts because the canonical buyback hook will mint in `afterPayRecordedWith`, the resolver scores the hook's standard 15-word pay metadata itself. It uses the executable `minimumSwapAmountOut` floor and only uses `rawSwapQuote` as an optimistic scorer when the hook has not marked the oracle as unseeded. Cold-start spot diagnostics therefore do not outrank TWAP-backed or directly executable routes.
  - Fallback: if no candidate scored, calls `self.previewFallbackRoute` (`:982-1006`) — also via external self-call so any revert is caught.

- **`previewFallbackRoute(routePreviewer, wrappedNativeToken, destProjectId, tokenIn, amountIn, beneficiary, metadata) → (...)`** — `:1029-1077`. External self-call wrapper around `_previewRoute` + `previewTerminalPayOf`, normalized for buyback-hook overrides.

- **`previewPayRouteForCandidate(router, wrappedNativeToken, projectId, tokenIn, amount, beneficiary, metadata, tokenOut, destTerminal) → (...)`** — `:1095-1129`. External wrapper used by the candidate-isolation `try/catch` in `previewBestPayRoute`.

- **`resolveTokenOut(router, wrappedNativeToken, projectId, tokenIn, metadata) → (tokenOut, destTerminal)`** — `:1132-1150`. Single-pass token-out resolution used by the router's `_route` execution path.

- **`usablePrimaryTerminalOf(router, projectId, token) → IJBTerminal`** — `:1153-1165`. Returns `address(0)` for missing or circular terminals.

**Public immutables:**

- `DIRECTORY` (`IJBDirectory`; immutable; `:33`).

---

## Section D — Cross-cutting invariants

1. **Router/registry do not account for project balances as surplus.** Both contracts are forwarding surfaces, not accounting terminals: `currentSurplusOf` and `migrateBalanceOf` always return zero by design (`JBRouterTerminal.sol:562-578, 316-330`; `JBRouterTerminalRegistry.sol:182-198, 544-558`). Route-scoped leftovers are refunded to the originating payer, while pre-existing ambient balances are not swept into later routes.
2. **Balance-delta accounting on inbound transfers.** `_acceptFundsFor` returns the post-transfer balance delta, not the nominal `amount`. The cashout loop and the swap leftover detection both use the same pattern. Fee-on-transfer source tokens route the *actually received* amount.
3. **`minReturnedTokens` is the destination terminal's responsibility.** The router does not impose its own beneficiary-token floor on `pay`; the floor is delegated to the destination terminal which can see pay-hook side effects accurately. `addToBalanceOf` adds a final-hop ERC-20 receipt shortfall check because no pay hooks fire.
4. **Original payer propagated through transient storage.** `JBRouterTerminalRegistry` writes `originalPayer` transient slot before forwarding and restores the previous value after (save/restore pattern supports nested forwards through pay hooks). The router resolves refunds against this slot via `IJBPayerTracker.originalPayer()` when called through the registry. Chains like `projectPayer -> registry -> router` propagate the true originator one extra hop via `_originalPayerOrSender`.
5. **Non-circular-forward is checked at every irreversible write.** `setTerminalFor`, `lockTerminalFor`, and `setDefaultTerminal` each call `_requireNonCircularTerminalFor` (depth-5 walk via `JBForwardingCheck`). Per-call forwards additionally call `_enforceNoCircularForward` to block immediate-caller cycles.
6. **First default serves pre-existing projects, then cohort-stable defaults block silent reroutes.** The first `setDefaultTerminal` records a `(0, count]` segment mapping every project that already existed onto that first default, so they can route tokens through it. After that, `_defaultTerminalFor` resolves against the snapshot history when `projectId <= defaultTerminalProjectIdThreshold`, so a later owner change to `defaultTerminal` cannot retroactively reroute already-deployed projects without explicit overrides.
7. **One-shot deployer setter pins chain-specific constants.** `setChainSpecificConstants` is callable only by the immutable `_DEPLOYER` and only once (`wrappedNativeToken == address(0)` guard). Constructor inputs stay byte-identical across chains so the router's CREATE2 address is unified.
8. **Pool callbacks are authenticated by the active swap context.** The V3 callback verifies `msg.sender` against the transient `_v3ExpectedPool` set by `_executeV3Swap`; the V4 callback verifies `msg.sender == poolManager`, whose unlock flow returns only to the caller that initiated the unlock. Spoofed callbacks revert before any state change.
9. **Cashout-loop iteration bound + first-hop-only `minTokensReclaimed`.** The 20-hop ceiling forecloses on infinite recursion through adversarial project-token graphs; the user-supplied reclaim minimum is intentionally NOT carried across hops because token units change between hops.
10. **Quote precedence: explicit metadata > V3 TWAP > V4 hook geomean > V4 spot (accepted-risk fallback).** When supplied, `pay` swap-quote skips on-chain quoting entirely and a token-mismatch reverts `JBRouterTerminal_QuoteTokenMismatch`. The V4 spot fallback is bounded by a fixed 15% haircut and is documented as accepted-risk for routine flows.

---

## Section E — Centralization and ownership

### E.1 `JBRouterTerminal`

- **`_DEPLOYER`** holds one-shot authority over `setChainSpecificConstants`. After the call, the contract has no privileged surface — there is no Ownable, no upgrade pointer, no admin function.
- The router does NOT inherit `Ownable`. There is no on-chain authority that can pause, redirect, or change router behavior post-deploy.

### E.2 `JBRouterTerminalRegistry`

- **`Ownable.owner`** (set in constructor at `:130`) controls:
  - `allowTerminal` (`:475-481`),
  - `disallowTerminal` (`:487-498`) — but cannot disallow the current default,
  - `setDefaultTerminal` (`:633-666`) — but cohort-stable snapshots prevent silent reroutes of already-deployed projects.
- **The registry owner cannot:**
  - Redirect payments for any project with an explicit `_terminalOf` override.
  - Redirect payments for any project whose ID is covered by a historical `_defaultTerminalHistory` segment (i.e. any cohort that was created under a previous default).
  - Override `hasLockedTerminal`.
  - Take custody of in-flight funds (no admin transfer surface; balances are zero between calls).
- **Per-project authority** lives with `PROJECTS.ownerOf(projectId)` or `SET_ROUTER_TERMINAL` operators: `setTerminalFor` and `lockTerminalFor` are the only project-scoped state mutators.
- The registry allowlist is a hard prerequisite for any project to opt into a terminal; this is a *trust-minimization* surface for the registry owner — they can curate which terminals projects may select — but it does not grant the owner the ability to retroactively reroute opted-in projects.

### E.3 `JBPayRouteResolver`

- No owner. No setters. Pure view contract. The only privileged input is the `directory` constructor argument (immutable).

---

## Section F — File:line references

### `src/JBRouterTerminal.sol`

- Constants: `_MAX_CASHOUT_ITERATIONS = 20` (`:111`), `_SLIPPAGE_DENOMINATOR = 10_000` (`:114`), `DEFAULT_TWAP_WINDOW = 10 minutes` (`:99`), `MIN_TWAP_WINDOW = 120` (`:103`).
- Public immutables: `BUYBACK_HOOK` (`:127`), `DIRECTORY` (`:130`), `PERMIT2` (`:133`), `TOKENS` (`:136`).
- Internal immutables: `_DEPLOYER` (`:145`), `_PAY_ROUTE_RESOLVER` (`:152, 219`).
- Stored chain-specific constants: `factory` (`:171`), `poolManager` (`:176`), `univ4Hook` (`:182`), `wrappedNativeToken` (`:187`).
- Entry points: `pay` (`:342-394`), `addToBalanceOf` (`:256-309`), `setChainSpecificConstants` (`:407-421`), `uniswapV3SwapCallback` (`:428-450`), `unlockCallback` (`:455-508`).
- Views: `accountingContextForTokenOf` (`:518-539`), `accountingContextsOf` (`:545-553`), `currentSurplusOf` (`:562-578`), `discoverBestPool` (`:584-599`), `discoverPool` (`:605-620`), `previewPayFor` (`:633-653`), `previewCashOutLoopOf` (`:664-682`), `previewSwapAmountOutOf` (`:690-701`), `previewTerminalPayOf` (`:714-729`), `bestPoolLiquidityOf` (`:735-737`), `supportsInterface` (`:747-750`).
- Internal helpers: `_resolveOriginalPayer` (`:761-769`), `_routeForPay` (`:781-819`), `_previewBestPayRoute` (`:876-907`), `_terminalReceiptBaselineOf` (`:944-964`), `_enforceStandardTerminalReceipt` (`:972-995`), `_acceptFundsFor` (`:1050-1097`), `_refundBalanceBaselineOf` (`:1127-1133`), `_cashOutLoop` (`:1143-1236`), `_handleSwap` (`:1428-1480`), `_route` (`:1492-1533`), `_findCashOutPath` (`:2025-2104`), `_getV3TwapQuote` (`:2194-2247`).

### `src/JBRouterTerminalRegistry.sol`

- Errors: `:43-52`.
- Immutables: `PROJECTS` (`:59`), `PERMIT2` (`:62`).
- Stored: `defaultTerminal` (`:72`), `defaultTerminalProjectIdThreshold` (`:80`), `hasLockedTerminal` (`:84`), `isTerminalAllowed` (`:88`), `_defaultTerminalHistory` (`:98`), `_terminalOf` (`:102`).
- Transient: `originalPayer` (`:109`).
- Entry points: `pay` (`:571-622`), `addToBalanceOf` (`:423-470`), `setTerminalFor` (`:672-691`), `lockTerminalFor` (`:506-537`), `allowTerminal` (`:475-481`), `disallowTerminal` (`:487-498`), `setDefaultTerminal` (`:633-666`).
- Forwarding mechanics: `_enforceNoCircularForward` (`:294-297`), `_originalPayerOrSender` (`:318-337`), `_requireNonCircularTerminalFor` (`:345-351`), `_defaultTerminalFor` (`:358-375`), `_resolvedTerminalOf` (`:382-388`), `_requireResolvedTerminalOf` (`:395-398`).
- Views: `accountingContextForTokenOf` (`:144-158`), `accountingContextsOf` (`:163-174`), `currentSurplusOf` (`:182-198`), `defaultTerminalFor` (`:204-206`), `defaultTerminalHistoryAt` (`:211-218`), `defaultTerminalHistoryLength` (`:223-225`), `previewPayFor` (`:238-263`), `terminalOf` (`:266-268`), `supportsInterface` (`:277-281`).

### `src/JBPayRouteResolver.sol`

- Immutable: `DIRECTORY` (`:33`).
- External views: `previewBestPayRoute` (`:847-1009`), `previewFallbackRoute` (`:1029-1077`), `previewPayRouteForCandidate` (`:1095-1129`), `resolveTokenOut` (`:1132-1150`), `usablePrimaryTerminalOf` (`:1153-1165`).
- Internal helpers: `_candidatePayRouteTokens` (`:59`), `_discoverAcceptedToken` (`:149`), `_effectivePreviewPayTokenCounts` (`:249`), `_isCircularTerminal` (`:403`), `_previewPayRouteForCandidate` (`:494`), `_previewRoute` (`:561`), `_resolveTokenOut` (`:650`), `_safeTerminalsOf` (`:723`), `_usablePrimaryTerminalForCandidate` (`:820`).

### `src/libraries/JBForwardingCheck.sol`

- `isCircularTerminal(target, projectId, terminal) → bool` (`:15-42`). Depth-5 walk; treats unresolved chains as circular to fail-safe.

### `src/structs/`

- `CashOutPathCandidates.sol` — direct / base / recursive candidate triples used by `_findCashOutPath`.
- `DefaultTerminalSegment.sol` — `(minProjectIdExclusive, maxProjectId, terminal)` history entry used by `_defaultTerminalFor`.
- `PoolInfo.sol` — `(isV4, v3Pool, v4Key)` discriminated union returned by pool discovery.

---

## References

- Reference INVARIANTS template: `../INVARIANTS.md` (Section C.13 summarizes the router/registry at the deploy-script level).
- Sister INVARIANTS for composition partners: `nana-buyback-hook-v6/INVARIANTS.md` (buyback hook metadata the router decodes), `nana-omnichain-deployers-v6/INVARIANTS.md` (data-hook wrapping pattern), `nana-suckers-v6/INVARIANTS.md` (sucker-aware cashout accounting).
- Destination-terminal slippage and fee guarantees: `nana-core-v6/INVARIANTS.md` Section C.1 (`JBMultiTerminal`).
- Risk acknowledgments and accepted operating envelopes: `nana-router-terminal-v6/RISKS.md`.
- Style conventions and named-args usage: `nana-router-terminal-v6/STYLE_GUIDE.md`.
