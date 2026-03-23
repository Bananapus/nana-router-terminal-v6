# Administration

Admin privileges and their scope in nana-router-terminal-v6.

## Roles

### 1. Registry Owner (Ownable)

**Contract**: `JBRouterTerminalRegistry`
**Assigned via**: Constructor parameter `owner`, transferable via `Ownable.transferOwnership()`.
**Scope**: Global -- controls which router terminals can be used by any project and sets the system-wide default terminal.

### 2. Project Owner / SET_ROUTER_TERMINAL Delegate

**Contract**: `JBRouterTerminalRegistry`
**Assigned via**: Ownership of the project's ERC-721 NFT (via `JBProjects.ownerOf(projectId)`), or delegation via `JBPermissions` with permission ID `SET_ROUTER_TERMINAL` (29).
**Scope**: Per-project -- controls which router terminal a specific project uses, and can permanently lock that choice.

### 3. Router Terminal Owner (Ownable)

**Contract**: `JBRouterTerminal`
**Assigned via**: Constructor parameter `owner`, transferable via `Ownable.transferOwnership()`.
**Scope**: Currently unused. `JBRouterTerminal` inherits `Ownable` but does not gate any functions behind `onlyOwner`. The owner exists for potential future use or subclass extensions. The `Ownable.renounceOwnership()` and `Ownable.transferOwnership()` functions are inherited but have no practical effect on the terminal's operation.

**Risk note:** While the owner has no current powers over the terminal's operation, the `Ownable` inheritance means a future code change or subclass could introduce `onlyOwner`-gated functions. If the terminal is deployed with a specific owner address, that address retains transfer rights indefinitely.

### 4. Credit Cashout Payer (Implicit)

**Contract**: `JBRouterTerminal`
**Required permission**: `TRANSFER_CREDITS` (permission ID 13) -- must be granted by the payer to the router terminal address for the source project via `JBPermissions`.
**Scope**: Per-transaction. Required only when using the `cashOutSource` metadata key to route payments through credit cashouts.

## Terminal Resolution

When a payment is forwarded through the registry, the terminal is resolved as follows:

1. If the project has called `setTerminalFor(projectId, terminal)`, that explicit terminal is used.
2. If no explicit terminal is set, the registry's `defaultTerminal` is used.
3. If neither exists, the forwarding reverts.

**Lock semantics:** When `lockTerminalFor()` is called on a project with no explicit terminal, the current default is snapshot into `_terminalOf[projectId]` before locking. The project becomes independent of future default changes.

**Disallow interaction:** If the registry owner calls `disallowTerminal()` on the current default terminal, the `defaultTerminal` is automatically cleared (set to `address(0)`). Projects relying on the default (without locking) would lose their terminal resolution until a new default is set. Projects should lock their terminal to avoid disruption.

## Privileged Functions

### JBRouterTerminalRegistry

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|--------------|
| `allowTerminal(terminal)` | Registry Owner | `onlyOwner` | Global | Adds a terminal to the allowlist (`isTerminalAllowed[terminal] = true`). Projects can only use allowlisted terminals. |
| `disallowTerminal(terminal)` | Registry Owner | `onlyOwner` | Global | Removes a terminal from the allowlist. Also clears `defaultTerminal` if it matches the disallowed terminal. Does NOT affect projects that have already locked their terminal. |
| `setDefaultTerminal(terminal)` | Registry Owner | `onlyOwner` | Global | Sets the default terminal for all projects that have not set a project-specific terminal. Also auto-allows the terminal. |
| `setTerminalFor(projectId, terminal)` | Project Owner or Delegate | `SET_ROUTER_TERMINAL` (29) | Per-project | Routes a specific project to a specific allowed terminal. Reverts if the terminal is not allowlisted or if the project's terminal is locked. |
| `lockTerminalFor(projectId, expectedTerminal)` | Project Owner or Delegate | `SET_ROUTER_TERMINAL` (29) | Per-project | Permanently locks the terminal choice for a project. If no explicit terminal is set, snapshots the current default into `_terminalOf[projectId]`. Reverts with `TerminalMismatch` if the resolved terminal differs from `expectedTerminal` (race condition protection). **Irreversible.** |

### JBRouterTerminal

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|--------------|
| `transferOwnership(newOwner)` | Owner | `onlyOwner` (inherited) | Global | Transfers contract ownership. No functions currently gated by ownership. |
| `renounceOwnership()` | Owner | `onlyOwner` (inherited) | Global | Renounces contract ownership. No functions currently gated by ownership. |

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
| `PERMISSIONS` | Constructor | No | JB permissions registry for permission checks |
| `Trusted forwarder` | Constructor | No | ERC-2771 trusted forwarder for meta-transactions |
| `DIRECTORY` | Constructor | No | JB directory for terminal/controller lookups |
| `PROJECTS` | Constructor | No | JB project NFT registry |
| `TOKENS` | Constructor | No | JB token manager for credit transfers and project token lookups |
| `FACTORY` | Constructor | No | Uniswap V3 factory for pool discovery and callback verification |
| `POOL_MANAGER` | Constructor | No | Uniswap V4 PoolManager (can be `address(0)` to disable V4) |
| `PERMIT2` | Constructor | No | Permit2 contract for gasless approvals |
| `WETH` | Constructor | No | Wrapped ETH contract |
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

### Router Terminal Owner Cannot:
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
