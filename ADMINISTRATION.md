# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Global router terminal allowlisting and project-local terminal selection |
| Control posture | Mixed registry-owner and project-local delegated control |
| Highest-risk actions | Setting the initial default terminal at deploy time, locking a project to the wrong terminal. Subsequent default-terminal changes only affect projects created after the change — existing projects keep resolving against their cohort's historical default. |
| Recovery posture | Unlocked projects can move; locked projects and immutable router wiring limit recovery |

## Purpose

`nana-router-terminal-v6` splits administration between a global registry and project-local terminal selection. The router logic itself is mostly immutable. The mutable control plane lives in `JBRouterTerminalRegistry`.

## Control Model

- `JBRouterTerminalRegistry` is globally `Ownable`
- project owners or delegates choose and can lock their router terminal
- `JBRouterTerminal` has immutable routing dependencies and no owner-controlled strategy knobs

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Registry owner | `Ownable(owner)` | Global | Controls allowlist and default terminal |
| Project owner | `JBProjects.ownerOf(projectId)` | Per project | May delegate `SET_ROUTER_TERMINAL` |
| Terminal delegate | `JBPermissions` grant | Per project | Usually `SET_ROUTER_TERMINAL` |
| Payer | Per transaction | Per payment | No special permissions needed for standard ERC-20 routing |

## Privileged Surfaces

| Contract | Function | Who Can Call | Effect |
| --- | --- | --- | --- |
| `JBRouterTerminalRegistry` | `allowTerminal(...)`, `disallowTerminal(...)`, `setDefaultTerminal(...)` | Registry owner | Controls global terminal availability and the default fallback for NEW projects only. `setDefaultTerminal` snapshots the outgoing default into `_defaultTerminalHistory` so projects with ID <= `defaultTerminalProjectIdThreshold` continue to resolve against the default that was current when their cohort was active. |
| `JBRouterTerminalRegistry` | `setTerminalFor(...)` | Project owner or `SET_ROUTER_TERMINAL` delegate | Sets a project's explicit router terminal |
| `JBRouterTerminalRegistry` | `lockTerminalFor(...)` | Project owner or `SET_ROUTER_TERMINAL` delegate | Irreversibly locks the resolved terminal for a project |

## Immutable And One-Way

- `lockTerminalFor(...)` is irreversible
- constructor dependencies on the router are immutable
- the current default terminal must move before the old default can be disallowed

## Operational Notes

- keep the terminal allowlist small and explicit
- the initial `setDefaultTerminal` at deploy time defines the cohort default for every project that exists when no later override is set; pick it carefully because it propagates to all early projects
- subsequent `setDefaultTerminal` calls only re-route projects created AFTER the call; existing projects without an explicit `setTerminalFor` keep resolving to their cohort's historical default via `_defaultTerminalHistory`
- still review fall-through resolution before changing the default — `defaultTerminalFor(projectId)` returns the resolved default for any project, and `defaultTerminalHistoryAt(index)` exposes each captured snapshot
- encourage projects to lock only after validating the resolved terminal and routing behavior
- distinguish configuration risk from quote-quality risk

## Machine Notes

- do not treat registry ownership as authority to override a locked project choice
- inspect `src/JBRouterTerminalRegistry.sol` and `src/JBRouterTerminal.sol` separately; they govern different control boundaries
- if effective terminal resolution and the documented default differ, resolve registry state before further actions
- if route previews are falling back to weaker discovery or quote paths, do not describe the router as offering uniform oracle-quality guarantees

## Recovery

- unlocked projects can switch to another allowlisted terminal
- locked projects cannot be unlocked by the registry
- bad immutable router behavior means replacement infrastructure, not in-place edits
- quote-path weakness is usually mitigated operationally with better pool choice, external quoting, or replacement routing infrastructure

## Admin Boundaries

- the registry owner cannot unlock or override a locked project terminal
- the registry owner cannot reroute an existing project's fall-through default; `setDefaultTerminal` only addresses projects created after the call (see `defaultTerminalProjectIdThreshold` and the `_defaultTerminalHistory` snapshot semantics)
- project operators cannot set a terminal that the registry does not allow
- router maintainers cannot tune routing heuristics or constructor immutables post-deploy
- there is no pause surface in the registry or router

## Source Map

- `src/JBRouterTerminalRegistry.sol`
- `src/JBRouterTerminal.sol`
- `src/JBPayRouteResolver.sol`
- `test/`
