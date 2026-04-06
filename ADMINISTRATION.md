# Administration

Admin privileges and their scope in nana-router-terminal-v6.

## At A Glance

| Item | Details |
|------|---------|
| Scope | Registry-level selection of router terminal implementations plus immutable router-terminal swap and forwarding behavior. |
| Operators | Registry owner for the global allowlist/default, project owners or `SET_ROUTER_TERMINAL` delegates for per-project selection, and users who must supply valid routing metadata. |
| Highest-risk actions | Locking a project to the wrong terminal, changing the default terminal without understanding who inherits it, or assuming the router is an accounting-truth surface when it is not. |
| Recovery posture | Unlocked projects can switch terminals. Locked projects keep the stored terminal choice, so recovery requires moving the project to a different admin path outside the registry. |

## Routine Operations

- Keep the registry allowlist limited to router terminal implementations you actually want projects to choose from.
- Change the default terminal only when you are comfortable affecting every project that still relies on fallback resolution.
- Encourage projects to lock their terminal only after verifying the resolved terminal address and expected routing behavior.
- For credit-cashout routing, verify the payer has granted the router terminal the needed `TRANSFER_CREDITS` permission before relying on that path.

## One-Way Or High-Risk Actions

- `lockTerminalFor` is irreversible.
- The current default terminal cannot be disallowed; the registry owner must move the default first before removing the old implementation from the allowlist.

## Recovery Notes

- If the default terminal is wrong, update the registry quickly before more projects snapshot it through `lockTerminalFor`.
- If a project already locked the wrong terminal, the registry cannot unlock it; recovery has to happen by migrating the project's broader terminal setup elsewhere.

## Roles

### 1. Registry Owner (Ownable)

**Contract**: `JBRouterTerminalRegistry`
**Assigned via**: Constructor parameter `owner`, transferable via `Ownable.transferOwnership()`.
**Scope**: Global -- controls which router terminals can be used by any project and sets the system-wide default terminal.

### 2. Project Owner / SET_ROUTER_TERMINAL Delegate

**Contract**: `JBRouterTerminalRegistry`
**Assigned via**: Ownership of the project's ERC-721 NFT (via `JBProjects.ownerOf(projectId)`), or delegation via `JBPermissions` with permission ID `SET_ROUTER_TERMINAL` (30).
**Scope**: Per-project -- controls which router terminal a specific project uses, and can permanently lock that choice.

### 3. Credit Cashout Payer (Implicit)

**Contract**: `JBRouterTerminal`
**Required permission**: `TRANSFER_CREDITS` (permission ID 13) -- must be granted by the payer to the router terminal address for the source project via `JBPermissions`.
**Scope**: Per-transaction. Required only when using the `cashOutSource` metadata key to route payments through credit cashouts.

## Terminal Resolution

When a payment is forwarded through the registry, the terminal is resolved as follows:

1. If the project has called `setTerminalFor(projectId, terminal)`, that explicit terminal is used.
2. If no explicit terminal is set, the registry's `defaultTerminal` is used.
3. If neither exists, the forwarding reverts.

**Lock semantics:** When `lockTerminalFor()` is called on a project with no explicit terminal, the current default is snapshot into `_terminalOf[projectId]` before locking. The project becomes independent of future default changes.

**Disallow interaction:** The registry owner cannot disallow the current default terminal. `disallowTerminal()` reverts with `JBRouterTerminalRegistry_CannotDisallowDefaultTerminal` until `setDefaultTerminal()` has moved the default elsewhere first. Projects relying on the default therefore keep a valid fallback terminal unless the owner explicitly changes that default.

## Privileged Functions

### JBRouterTerminalRegistry

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|--------------|
| `allowTerminal(terminal)` | Registry Owner | `onlyOwner` | Global | Adds a terminal to the allowlist (`isTerminalAllowed[terminal] = true`). Projects can only use allowlisted terminals. |
| `disallowTerminal(terminal)` | Registry Owner | `onlyOwner` | Global | Removes a terminal from the allowlist. Reverts if `terminal` is the current `defaultTerminal`, so the owner must move the default first. Does NOT affect projects that have already locked their terminal or explicitly set another terminal. |
| `setDefaultTerminal(terminal)` | Registry Owner | `onlyOwner` | Global | Sets the default terminal for all projects that have not set a project-specific terminal. Also auto-allows the terminal. |
| `setTerminalFor(projectId, terminal)` | Project Owner or Delegate | `SET_ROUTER_TERMINAL` (30) | Per-project | Routes a specific project to a specific allowed terminal. Reverts if the terminal is not allowlisted or if the project's terminal is locked. |
| `lockTerminalFor(projectId, expectedTerminal)` | Project Owner or Delegate | `SET_ROUTER_TERMINAL` (30) | Per-project | Permanently locks the terminal choice for a project. If no explicit terminal is set, snapshots the current default into `_terminalOf[projectId]`. Reverts with `TerminalMismatch` if the resolved terminal differs from `expectedTerminal` (race condition protection). **Irreversible.** |

### Implicit Permission Requirements (not `onlyOwner`, but enforced by external contracts)

| Operation | Required By | Permission | What Happens |
|-----------|------------|------------|--------------|
| Credit cashout via `cashOutSource` metadata | Payer | `TRANSFER_CREDITS` (13) granted to router terminal | `TOKENS.transferCreditsFrom()` pulls credits from payer. Reverts if payer has not granted the permission. |
| Cashout execution | Router terminal (as holder) | None (terminal holds the tokens) | `IJBCashOutTerminal.cashOutTokensOf()` is called with the router as the holder. The router already holds the tokens from the credit transfer or prior cashout step. |

## Immutable Configuration

The following values are set at deploy time and cannot be changed:

### JBRouterTerminal

| Property | Set At | Mutable? | Description |
|----------|--------|----------|-------------|
| `Trusted forwarder` | Constructor | No | ERC-2771 trusted forwarder for meta-transactions |
| `DIRECTORY` | Constructor | No | JB directory for terminal/controller lookups |
| `TOKENS` | Constructor | No | JB token manager for credit transfers and project token lookups |
| `FACTORY` | Constructor | No | Uniswap V3 factory for pool discovery and callback verification |
| `POOL_MANAGER` | Constructor | No | Uniswap V4 PoolManager (can be `address(0)` to disable V4) |
| `PERMIT2` | Constructor | No | Permit2 contract for gasless approvals |
| `WETH` | Constructor | No | Wrapped ETH contract |
| `BUYBACK_HOOK` | Constructor | No | Canonical buyback hook whose metadata this router understands |
| `UNIV4_HOOK` | Constructor | No | Canonical Uniswap V4 hook address searched during hooked-pool discovery |
| `DEFAULT_TWAP_WINDOW` | Compile-time constant | No | 10 minutes (600 seconds) |
| `SLIPPAGE_DENOMINATOR` | Compile-time constant | No | 10,000 (basis points) |
| `_FEE_TIERS` | Storage (initialized) | No | `[3000, 500, 10000, 100]` -- V3 fee tiers |
| `_V4_FEES` / `_V4_TICK_SPACINGS` | Storage (initialized) | No | V4 pool parameters |
| `_MAX_CASHOUT_ITERATIONS` | Compile-time constant | No | 20 iterations |

### JBRouterTerminalRegistry

| Property | Set At | Mutable? | Description |
|----------|--------|----------|-------------|
| `PERMISSIONS` | Constructor | No | JB permissions registry for permission checks |
| `Trusted forwarder` | Constructor | No | ERC-2771 trusted forwarder for meta-transactions |
| `PROJECTS` | Constructor | No | JB project NFT registry |
| `PERMIT2` | Constructor | No | Permit2 contract for gasless approvals |

### JBSwapLib

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_SLIPPAGE` | 8,800 (88%) | Maximum slippage tolerance ceiling |
| `IMPACT_PRECISION` | 1e18 | Precision for impact calculations |
| `SIGMOID_K` | 5e16 | Sigmoid curve shape parameter |

## Admin Boundaries

What admins **cannot** do:

### Registry Owner Cannot:
- **Unlock a locked terminal.** `lockTerminalFor` is irreversible -- there is no `unlockTerminalFor` function.
- **Override a project's locked terminal choice.** Once locked, the terminal is permanently stored in `_terminalOf[projectId]` and `hasLockedTerminal[projectId]` is permanently `true`.
- **Force a project to use a specific terminal.** Only the project owner (or delegate) can call `setTerminalFor`.
- **Access project funds.** The registry is a pass-through; it holds funds transiently during forwarding only.
- **Modify swap parameters, slippage, or routing logic.** These are controlled by the `JBRouterTerminal` contract, not the registry.
- **Pause payments.** There is no pause mechanism.

### Router Terminal Maintainers Cannot:
- **Modify swap slippage parameters.** The TWAP window, sigmoid constants, fee tiers, and max slippage are all immutable.
- **Redirect funds.** The terminal is stateless between transactions and routes payments to whichever terminal the JB directory specifies.
- **Change the Uniswap factory or PoolManager.** These are immutable constructor parameters.
- **Override user-provided quotes.** The `quoteForSwap` metadata is decoded and used as-is.
- **Prevent specific users from paying.** There is no blocklist mechanism.
- **Extract stuck funds.** There is no sweep or rescue function. The terminal relies on completing all token movements within a single transaction.

### Project Owner / Delegate Cannot:
- **Change the terminal after locking.** The `setTerminalFor` function reverts with `TerminalLocked` if the terminal is locked.
- **Set a disallowed terminal.** `setTerminalFor` reverts with `TerminalNotAllowed` if the terminal is not on the registry owner's allowlist.
- **Affect other projects' routing.** Permission checks are scoped to the specific `projectId`.
