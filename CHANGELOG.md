# Changelog

## Scope

This file describes the verified change from `nana-swap-terminal-v5` to the current `nana-router-terminal-v6` repo.

## Current v6 surface

- `JBRouterTerminal`
- `JBRouterTerminalRegistry`
- `IJBRouterTerminal`
- `IJBRouterTerminalRegistry`
- `JBSwapLib`

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
