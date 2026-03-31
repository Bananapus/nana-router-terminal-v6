# User Journeys

## Who This Repo Serves

- projects that want to accept more input tokens than their treasury natively accounts in
- payers arriving with the "wrong" token for a project
- integrators building quote, preview, and slippage-aware payment UX

## Journey 1: Put A Router In Front Of A Project's Canonical Terminal

**Starting state:** the project already has a real downstream terminal that defines accounting truth.

**Success:** users can pay with a wider set of tokens while the destination project's accounting still happens in its downstream terminal.

**Flow**
1. Deploy or choose the router terminal instance you want to use.
2. Use `JBRouterTerminalRegistry.setTerminalFor(...)` for a project-specific choice, or rely on the registry's default terminal.
3. Keep the project's canonical terminal configuration correct, because the router only forwards into that truth surface.
4. Expose route-preview UX so payers know what asset path will actually be used.

## Journey 2: Pay A Project With Whatever Token The User Already Has

**Starting state:** the payer has an input token that the destination project may not directly accept.

**Success:** the payment arrives at the downstream Juicebox terminal in an accepted asset and behaves like a normal project payment from there.

**Flow**
1. The payer calls the router terminal with the input token and project target.
2. The router discovers what token the destination actually accepts.
3. It chooses among direct forwarding, native wrap or unwrap, Uniswap V3 or V4 swap, or recursive project-token cash out when needed.
4. It forwards the resulting value into the destination terminal.
5. The destination project then handles accounting, minting, and hooks through its downstream terminal path rather than through router-specific accounting.

## Journey 3: Lock Down Which Router A Project Uses

**Starting state:** a project wants a specific router terminal rather than whatever default the ecosystem exposes.

**Success:** routing behavior becomes predictable for integrators and users.

**Flow**
1. Set the project's preferred router terminal in `JBRouterTerminalRegistry`.
2. Optionally lock that choice with `lockTerminalFor(...)` if the project should not drift later.
3. Frontends and operators can resolve the intended router through the registry instead of guessing.

**Main constraint:** this repo is a convenience surface. It should not be treated as the project's accounting source of truth.

## Hand-Offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for the downstream payment and accounting behavior.
- Use [univ4-router-v6](../univ4-router-v6/USER_JOURNEYS.md) if you need the pool-side routing primitive rather than the terminal-side convenience layer.
