# Changelog

## Scope

This file describes the verified change from `nana-swap-terminal-v5` to the current `nana-router-terminal-v6` repo. In-v6 behavior changes that have semantic implications for integrators are also captured here.

## In-v6 changes

### Threshold-protected `setDefaultTerminal`

The registry owner's `setDefaultTerminal(IJBTerminal)` call now applies only to projects created AFTER the call. Existing projects without an explicit `setTerminalFor` override keep resolving to the default that was current when their project-ID cohort was active. The outgoing default is snapshotted into an append-only `_defaultTerminalHistory` array on every `setDefaultTerminal` call.

- New view: `defaultTerminalFor(uint256 projectId)` returns the default applicable to a specific project (walks history if the project is in a legacy cohort).
- New view: `defaultTerminalProjectIdThreshold()` returns `PROJECTS.count()` at the time of the most recent `setDefaultTerminal`.
- New views: `defaultTerminalHistoryAt(uint256 index)` and `defaultTerminalHistoryLength()` expose the snapshot history.
- New struct: `DefaultTerminalSegment { uint256 maxProjectId; IJBTerminal terminal; }` in `src/structs/`.
- `lockTerminalFor` now snapshots the *cohort-correct* default into `_terminalOf` (via `_defaultTerminalFor(projectId)`) when locking a project that has no explicit terminal — not the current registry-wide default.

Indexer impact: read `defaultTerminalFor(projectId)` rather than `defaultTerminal()` when computing the effective default for any specific project.

Admin impact: the registry owner can no longer silently reroute payments for already-deployed projects by changing the default. See `ADMINISTRATION.md` for the updated boundary description.



## Current v6 surface

- `JBRouterTerminal`
- `JBRouterTerminalRegistry`
- `JBPayRouteResolver`
- `IJBRouterTerminal`
- `IJBRouterTerminalRegistry`
- `IJBPayRouteResolver`
- `IJBPayRoutePreviewer`
- `IJBForwardingTerminal`
- `JBSwapLib`
- `CashOutPathCandidates`

## Summary

- The deployed terminal model changed from a swap terminal to a router terminal. That is a real conceptual change, not just a rename.
- Route discovery is now part of the product. The current repo is built around discovering paths and destination-token requirements instead of depending on the v5 manual pool-and-TWAP configuration style.
- The router terminal can reason about JB token cash-out flows as part of routing, which did not match the old swap-terminal mental model.
- The registry and terminal now share routing vocabulary with the v6 buyback hook through `JBSwapLib`.
- The repo moved from the v5 `0.8.23` baseline to `0.8.28`.

## Verified deltas

- The old admin surface around `addDefaultPool(...)` and `addTwapParamsFor(...)` is gone from the main interface.
- `IJBRouterTerminal` now extends `IJBTerminal`.
- `discoverPool(...)` and `discoverBestPool(...)` are first-class query methods in the interface.
- The current repo includes `previewPayFor(...)` routing behavior and JB-token cash-out path handling in its implementation and tests.

## Breaking ABI changes

- `IJBSwapTerminal` was replaced by `IJBRouterTerminal`.
- The old pool-configuration functions are gone from the main terminal interface.
- The terminal now inherits the broader `IJBTerminal` surface rather than exposing a narrow swap-only ABI.
- Discovery functions replaced manual pool/TWAP configuration as the public model.

## Indexer impact

- Event topology changed with the router-terminal and registry model; do not assume swap-terminal event families map one-to-one.
- Off-chain route computation can now rely on explicit discovery and preview methods instead of stored default-pool config.

## Migration notes

- Replace both terminology and ABI assumptions: `JBSwapTerminal` is not the right reference point for a v6 integration.
- Re-check any off-chain service that used manually configured pool metadata as the primary source of truth.
- Regenerate ABIs and re-index events from the current router-terminal contracts.

## ABI appendix

- Replaced interface
  - `IJBSwapTerminal` -> `IJBRouterTerminal`
- Removed swap-terminal-style admin/config functions
  - `addDefaultPool(...)`
  - `addTwapParamsFor(...)`
- Added router-oriented query functions
  - `discoverPool(...)`
  - `discoverBestPool(...)`
- Surface expansion
  - now inherits the broader `IJBTerminal` interface
