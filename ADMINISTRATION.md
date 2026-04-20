# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Global router terminal allowlisting and project-local terminal selection |
| Control posture | Mixed registry-owner and project-local delegated control |
| Highest-risk actions | Changing the default terminal, locking a project to the wrong terminal, and relying on misconfigured credit-cashout routing |
| Recovery posture | Unlocked projects can move; locked projects and immutable router wiring limit recovery |

## Purpose

`nana-router-terminal-v6` splits administration between a global registry and project-local terminal selection. The router logic itself is mostly immutable; the mutable control plane lives in `JBRouterTerminalRegistry`.

## Control Model

- `JBRouterTerminalRegistry` is globally `Ownable`.
- Project owners or delegates choose and can lock their router terminal.
- `JBRouterTerminal` has immutable routing dependencies and no owner-controlled strategy knobs.
- Some transaction paths depend on project-local `JBPermissions`, such as `TRANSFER_CREDITS`.

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Registry owner | `Ownable(owner)` | Global | Controls allowlist and default terminal |
| Project owner | `JBProjects.ownerOf(projectId)` | Per project | May delegate `SET_ROUTER_TERMINAL` |
| Terminal delegate | `JBPermissions` grant | Per project | Usually `SET_ROUTER_TERMINAL` |
| Payer | Per transaction | Per payment | May need `TRANSFER_CREDITS` for credit-cashout routing |

## Privileged Surfaces

| Contract | Function | Who Can Call | Effect |
| --- | --- | --- | --- |
| `JBRouterTerminalRegistry` | `allowTerminal(...)`, `disallowTerminal(...)`, `setDefaultTerminal(...)` | Registry owner | Controls global terminal availability and fallback |
| `JBRouterTerminalRegistry` | `setTerminalFor(...)` | Project owner or `SET_ROUTER_TERMINAL` delegate | Sets a project's explicit router terminal |
| `JBRouterTerminalRegistry` | `lockTerminalFor(...)` | Project owner or `SET_ROUTER_TERMINAL` delegate | Irreversibly locks the resolved terminal for a project |

## Immutable And One-Way

- `lockTerminalFor(...)` is irreversible.
- Constructor dependencies on the router are immutable.
- The current default terminal must move before the old default can be disallowed.

## Operational Notes

- Keep the terminal allowlist small and explicit.
- Change the default terminal carefully because unconfigured projects inherit it.
- Encourage projects to lock only after validating the resolved terminal and routing behavior.
- Review credit-cashout routing permissions before relying on that path operationally.
- Distinguish configuration risk from quote-quality risk: some route-discovery paths are best-effort, and some V4 quote paths can rely on weaker spot-style assumptions when robust history is unavailable.

## Machine Notes

- Do not treat registry ownership as authority to override locked project choice.
- Inspect `src/JBRouterTerminalRegistry.sol` and `src/JBRouterTerminal.sol` separately; they govern different control boundaries.
- If the effective terminal resolution and the documented default differ, stop and resolve the registry state before further actions.
- If route previews are falling back to weaker discovery or quote paths, do not describe the router as offering uniform oracle-quality guarantees across all pools and states.

## Recovery

- Unlocked projects can switch to another allowlisted terminal.
- Locked projects cannot be unlocked by the registry.
- Bad immutable router behavior means replacement infrastructure, not in-place edits.
- Quote-path weakness is usually mitigated operationally with better pool choice, external quoting, or replacement routing infrastructure, not with an owner-only hotfix.

## Admin Boundaries

- The registry owner cannot unlock or override a locked project terminal.
- Project operators cannot set a terminal that the registry does not allow.
- Router maintainers cannot tune routing heuristics or constructor immutables post-deploy.
- There is no pause surface in the registry or router.

## Source Map

- `src/JBRouterTerminalRegistry.sol`
- `src/JBRouterTerminal.sol`
- `src/JBPayRouteResolver.sol`
- `test/`
