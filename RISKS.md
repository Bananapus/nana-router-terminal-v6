# Accepted Security Risks

Documented risks that were reviewed and accepted.

## Oracle and slippage risks

**Pool-local V3 TWAP trusted as swap floor for permissionless pools.** *(Medium)*
An attacker could deploy a manipulable pool with higher liquidity to become the selected candidate. Users should provide `pay` swap-quote metadata from off-chain sources. Mitigated by 120s minimum TWAP window and sigmoid slippage formula.

**Liquidity-based pool selection enables unsafe spot quoting.** *(Medium)*
Pool discovery ranks candidates by instantaneous liquidity, so an attacker could inflate liquidity to force selection of a manipulable pool. Mitigated by V4 TWAP hardening and sigmoid slippage formula. Users should provide off-chain quotes for high-value swaps.

**Harmonic-mean liquidity inflates V3 slippage tolerance.** *(Medium)*
`OracleLibrary.consult` returns harmonic-mean liquidity, which can be deflated by brief low-liquidity periods. However, harmonic mean is more resistant to manipulation than spot liquidity. Mitigated by 120s TWAP minimum and 10-minute default observation window.

**V4 TWAP branch uses live in-range liquidity for slippage tolerance, not time-averaged.** *(Medium)*
In `_getV4SpotQuote`, when the V4 hook provides a TWAP tick (`usedTwap = true`), the gross quote tick is time-averaged but `_getLiquidity(id)` reads `POOL_MANAGER.getLiquidity(id)` — the CURRENT in-range liquidity. That live value feeds `_quoteWithSlippage` → `_getSlippageTolerance` → `JBSwapLib.calculateImpact`, where the sigmoid `tolerance = minSlippage + range * impact / (impact + K)` is monotonically increasing in impact. An attacker who thins in-range liquidity around quote time inflates the modeled impact and widens the tolerance up to `MAX_SLIPPAGE = 8800` (88%). Asymmetric vs the V3 path, which feeds `OracleLibrary.consult`'s `harmonicMeanLiquidity` over the same window into the same sigmoid.

If the V4 oracle hook reports partial observation coverage, the router quotes against the longest retained best-effort window instead of reverting the auto-quote. That keeps programmatic routing live during pool warmup, but it is weaker than the full 120-second router TWAP until the pool has retained enough history.

Why the practical impact is bounded rather than catastrophic:
1. The TWAP tick anchors the gross quote price over the 120s window — an attacker cannot move the priced tick within a single block, only widen the tolerance band around it.
2. Callers can pass `pay` swap-quote metadata to bypass the V4 spot-quote path entirely.
3. Pool selection in `_pickPoolAndQuote` can choose a V3 pool over V4 if it has more liquidity (and V3 uses harmonic-mean liquidity).

Frontends and programmatic callers that route value-sensitive swaps through V4 should always supply `pay` swap-quote rather than relying on the auto-quoted minimum-out. The in-code `SECURITY NOTE` at `JBRouterTerminal.sol:2286-2312` covers the same surface from the pool-selection angle.

**`pay` swap-quote output token binding.** *(Mitigated)*
`pay` swap-quote metadata is encoded as `abi.encode(tokenOut, minAmountOut)`. The router normalizes ETH/WETH before comparing `tokenOut` to the selected route output, then reverts on mismatch. Frontends and programmatic callers must encode the two-field payload `abi.encode(tokenOut, minAmountOut)`; a single-field `abi.encode(minAmountOut)` payload does not decode and the swap protection does not apply.

**Multi-hop cashout slippage cleared after first hop.** *(Minor)*
`cashOut` applies to the first cash-out hop only. The router forwards the original metadata to that hop so
the source hook can make the same route-selection decision the router later enforces against the actual balance delta.
After the first hop, the metadata-level floor is cleared because later hops may use different token units. Maximum 20
recursive cashout iterations are allowed (`_MAX_CASHOUT_ITERATIONS`); beyond that the operation reverts.

**Zero oracle quote disables swap protection.** *(Minor)*
When the oracle returns zero (no liquidity), slippage tolerance becomes zero. The swap would fail anyway due to lack of liquidity, so this has no practical impact.

> **Status:** The V4 TWAP window is 120s, long enough that a single-block tick push cannot move the priced quote. A shorter window is not used.

## Registry and forwarding risks

**Autonomous pending-call refund cannot prove permanent sink failure.** *(Accepted tradeoff)*
The EVM cannot distinguish a permanently broken destination from a route which is temporarily failing or deliberately made to fail. The gateway therefore requires three permissionless attempts separated by at least one day, followed by another one-day wait and a final attempt. All four failures must have the same selector-level class. Encoded arguments are ignored; a changed selector resets the streak to one and keeps the input retryable. Complete-budget empty failures share a gas-exhaustion class whose target budgets escalate through 5M, 10M, 15M, and 20M gas, capped by the live chain's executable block budget. A sink can still alternate selectors to prevent autonomous refund or reproduce one class through every window, so this is strong evidence rather than proof of permanent failure.

**Failure classes intentionally ignore encoded error arguments.** *(Accepted tradeoff)*
`JBRouterTerminalGateway` hashes only the first four bytes of return data when a selector is present. Empty and shorter failures are hashed as-is. This prevents changing pool quotes, balances, and other live error arguments from resetting qualification while copying at most four bytes of adversarial return data. Different errors with the same selector intentionally share a failure class. An empty failure which consumes the complete forwarded gas budget uses a separate stable fingerprint so it cannot be confused with a cheap explicit empty revert.

**Arbitrarily underfunded outer transactions cannot be made safe by an inner contract.** *(Documented limitation)*
The gateway reserves 750,000 gas around its initial Router attempt so a route-level OOG normally becomes durable custody instead of bubbling into an upstream fail-open catch. No EVM callee can guarantee progress when the transaction itself supplies too little gas to reach or persist that fallback. Permissionless source-project-opted operations can therefore force a healthy route into custody by constraining the outer transaction, but later callers cannot advance qualification without supplying the gas required by the autonomous schedule. Clients should submit at least 1.5–2x `eth_estimateGas`. The reported Base transaction and a 750,000–1,500,000 gas sweep are covered by `RouterTerminalGatewayBaseForkTest`.

**Qualified gas budgets escalate for complete-budget exhaustion.** *(Mitigated)*
The default retry and finalization entry points target 5M, 10M, 15M, then 20M gas after consecutive complete-budget empty failures. `maximumQualifiedCallGas` derives the executable ceiling from `block.gaslimit` while preserving transaction and failure-accounting reserves; target steps above that ceiling use the ceiling instead. The `WithGas` variants accept budgets between the current capped step and that ceiling. Callers cannot manufacture qualification with a smaller limit or request an unexecutable larger limit; a healthy route needing more than the base can settle on a later attempt, while a destination which consumes every executable budget cannot lock custody solely by exceeding a fixed cross-chain cap.

**A source terminal can reject its eventual project refund.** *(Documented limitation)*
The gateway never degrades a project-accounting refund into a raw token transfer to a terminal address. It first tries the original source terminal if that terminal remains registered for the source project, then the current token-specific primary, then the project's other registered terminals. Any forwarding chain which reaches the Gateway is skipped. This keeps the creditor project and amount immutable while following the project's current accounting configuration. If every non-circular terminal rejects the refund, finalization reverts atomically and preserves pending custody for another permissionless attempt. There is deliberately no administrator, sweep, or recipient override.

**Gateway refunds do not restore `feeFreeSurplusOf`.** *(Accepted tradeoff)*
The core terminal's caught `FeeReverted` path credits both project balance and `feeFreeSurplusOf`. The gateway can only call the terminal's public `addToBalanceOf` surface, so an autonomously refunded fee is credited as ordinary project balance and may be fee-liable on a later cash out. This accounting difference is accepted in exchange for preventing the failed fee from being silently forgiven.

**Raw source-project metadata opts a payment into custody.** *(Accepted tradeoff)*
Metadata which is exactly 32 bytes and encodes a nonzero project ID opts a zero-minimum payment into failed-route custody and fixes that project as the eventual refund creditor. This lets immutable protocol payers such as `REVLoans` avoid fee forgiveness without caller authentication or contract changes. A direct caller can forge the metadata, but can escrow only tokens it supplies; after matching failures those tokens are credited to the project it named, not returned to the caller. Calls without the opt-in and all non-zero-minimum payments retain synchronous failure semantics.

**Partial-pull and rebasing input tokens can leave unassigned Gateway surplus.** *(Documented limitation)*
The transient intake guard prevents a nested transfer from being counted twice, but it cannot make arbitrary ERC-20 balance semantics trustworthy. If a token lets the Router report success after removing less from the Gateway than the approved call amount, the unpulled remainder is not represented by pending state and cannot be swept through another call. Such partial-pull and rebasing tokens are unsupported for Gateway custody. Standard tokens and ordinary fee-on-transfer tokens remove the full sender-side amount.

**Direct Gateway calls preserve the Router's approval and forwarder surface.** *(Mitigated)*
The Gateway implements `IJBPermitTerminal`, parses Permit2 metadata in its own namespace, falls back from direct ERC-20 allowance to Permit2 transfer, and resolves token owners through the same immutable ERC-2771 trusted forwarder used by the Router and Registry. Direct callers still fail synchronously unless exact raw source-project metadata explicitly opts their zero-minimum payment into project-refund custody.

**Partial source-token cash-out residue can be donated to a terminal-shaped payer.** *(Documented limitation)*
The Router returns unsold project-token residue to its resolved original payer with an ERC-20 transfer. When that payer is a source terminal, the transfer does not call `addToBalanceOf`, so the tokens can sit above recorded project balances. This behavior predates Gateway custody, and the Router has only 164 bytes of EIP-170 runtime margin; adding terminal classification and project-accounting delivery would exceed the current deployment envelope without a broader Router size reduction.

**Native protocol fees may bypass the gateway.** *(Documented limitation)*
When the fee token is `JBConstants.NATIVE_TOKEN` and the fee project directly accepts it, `JBMultiTerminal` pays that terminal directly. The Registry and Gateway are used only when terminal discovery chooses the Registry path, such as USDC paid to an ETH-denominated fee project. Native project payouts explicitly sent through the Registry are still protected.

**Existing project cohorts do not follow a new default automatically.** *(Operational constraint)*
Selecting a gateway as a later Registry default only affects new project cohorts. `Deploy.s.sol` therefore attempts project 1 and every project ID listed in `NANA_ROUTER_TERMINAL_MIGRATION_PROJECT_IDS`. An unauthorized or locked cohort emits `RouterTerminalMigrationFailed(projectId)` without aborting unrelated migration attempts, but deployment then requires project 1 to resolve through the Gateway and reverts if it does not. Other affected projects remain on their old route until their owner or `SET_ROUTER_TERMINAL` operator runs `script/MigrateProject.s.sol` with `NANA_ROUTER_TERMINAL_REGISTRY`, `NANA_ROUTER_TERMINAL_GATEWAY`, and `NANA_ROUTER_TERMINAL_MIGRATION_PROJECT_ID`. Locked projects cannot be moved; the deployment must therefore be executed with project-1 authority or coordinated with a separate authorized migration transaction.

**Credit cash-outs are not supported.** *(Documented limitation)*
The router does not accept project-token credits as an input. Holders of unclaimed Juicebox credits must first call `JBTokens.claimFor` (or equivalent) to materialize the credits as ERC-20 tokens, then route through the router as a normal ERC-20 payment. This was an intentional simplification: supporting credit inputs required pulling credits via `IJBController.transferCreditsFrom` and carrying a `cashOutSource` metadata override through the cashout loop, which added attack surface (the holder had to be sourced from `msg.sender` rather than `originalPayer()` to prevent spoofing) and ~580 bytes of runtime size. Removing it leaves credit holders with a two-tx flow (`claimFor` → `router.pay`) but keeps the router's contract size below the EIP-170 24,576 B limit with room for future features.

The router may still normalize its own pre-existing credits before a source-project cash-out. That is internal cleanup
for the router's holder balance, not a supported user input path.

**Forwarding-terminal receipt bypass.** *(Minor)*
`_isForwardingTerminal` bypasses receipt validation on incoming transfers. Forwarding terminals are registered by project owners and therefore trusted to handle receipts correctly.

**Forwarder claim disables receipt check.** *(Minor)*
Forwarding terminals registered by project owners are trusted to handle receipts correctly, so receipt validation is skipped for these callers.

**Multi-hop forwarding-cycle DoS in registry admission.** *(Accepted: Low)*
`JBRouterTerminalRegistry._requireNonCircularTerminalFor` only walks one hop of `IJBForwardingTerminal.terminalOf` when admitting a new explicit/default terminal. A multi-hop chain `A → B → registry` passes the admission check (registry only sees `downstream == B ≠ self`), but once locked in, a subsequent `pay`/`addToBalanceOf` recurses `registry → A → B → registry → A → ...` until OOG. The `JBPayRouteResolver` swap-routing path already uses the bounded multi-hop helper `JBForwardingCheck.isCircularTerminal`; the registry admission path does not.

*Why accepted:* The registry's allowlist already requires project-owner action to install each terminal, and the only known impact is a self-locking DoS on the project that constructs the multi-hop chain — no value can be extracted, and the project owner can rotate the default terminal at the registry level to unwedge. Credible cycles need at least two forwarding terminals controlled by the project, which is an unusual configuration. Per-PR retrofit cost is non-trivial relative to that impact, so this is documented as a known risk rather than patched.

*Mitigation guidance:* Project owners installing chained forwarding terminals should run a manual `JBForwardingCheck.isCircularTerminal({target: registry, projectId: …, terminal: candidate})` simulation before approving the candidate.

## Token compatibility risks

**Fee-on-transfer (FOT) tokens not supported for routed payments.** *(Medium)*
The `pay()` flow does not enforce an ERC-20 receipt check (balance-delta validation) on the destination terminal. This was intentionally removed because pay hooks attached to the destination terminal can legitimately consume tokens during `pay()`, making a balance-delta check produce false reverts for any project with active pay hooks. As a consequence, fee-on-transfer tokens will silently lose value during routing — the terminal receives fewer tokens than `amount` but the router cannot detect this. Projects using FOT tokens should route payments directly to the terminal, bypassing the router. The `addToBalanceOf()` flow retains shortfall enforcement since it has no hooks: the terminal must receive at least the forwarded ERC-20 amount, while benign surplus balance deltas are allowed.

## Minor configuration risks

**Unbounded quadratic candidate enumeration.** *(Minor)*
`_candidatePayRouteTokens` can enumerate O(n^2) candidates in theory. Bounded in practice to ~5-10 terminals per project, keeping gas costs manageable.

**Permit2 try/catch falls through to ERC-20 allowance.** *(Minor)*
Standard Permit2 fallback pattern. If Permit2 signature verification fails, the contract falls back to standard ERC-20 `transferFrom` using existing allowance.

## Pool discovery risks

**Fresh high-liquidity V3 pool without TWAP history can block auto-quoting.** *(Minor)*
`_discoverPool` selects the highest-liquidity V3 pool, but `_getV3TwapQuote` requires sufficient observation history. A freshly deployed pool with high liquidity wins discovery but fails the TWAP check, reverting the routing flow while lower-liquidity pools with adequate TWAP are ignored. Accepted because: (1) this is self-correcting — the pool accumulates observations over time, (2) the griefing cost is high — attacker must deploy real liquidity, (3) callers can bypass auto-quoting entirely by providing `pay` swap-quote metadata, and (4) the condition is temporary and resolves within the TWAP observation window (default 10 minutes).

## Multi-chain native token assumption

**Router assumes the chain has a native token with a WETH9-compatible wrapper.** *(Informational)*
The `WRAPPED_NATIVE_TOKEN` constructor parameter must be a WETH9-compatible contract (`deposit()` / `withdraw()` interface). On Ethereum this is WETH, on Celo it would be WCELO, etc. On chains without a native token (e.g. Tempo), the router's native-token swap and refund paths are not applicable — the router should either not be deployed, or the `WRAPPED_NATIVE_TOKEN` should be set to a no-op wrapper. All native-token routing logic (`_wrapNativeToken`, `_unwrapNativeToken`, `receive()`, V4 settlement with `msg.value`) depends on this assumption.
