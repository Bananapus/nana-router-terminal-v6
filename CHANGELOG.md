# V5 to V6 Changelog

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. It compares V5's `nana-swap-terminal-v5` in `../../v5/evm` with the current `nana-router-terminal-v6` repo.

## Current V6 Surface

- `JBRouterTerminal`
- `JBRouterTerminalRegistry`
- `JBPayRouteResolver`
- `IJBRouterTerminal`
- `IJBRouterTerminalRegistry`
- `IJBPayRouteResolver`
- `IJBPayRoutePreviewer`
- `IJBForwardingTerminal`
- `JBSwapLib`
- route and pool structs under `src/structs`

## Summary

- V5's swap terminal is replaced by a router terminal. This is a conceptual migration, not just a contract rename.
- V5 exposed manual V3 pool/TWAP configuration. V6 discovers routes and can compare V3, V4, and Juicebox terminal paths.
- The router terminal inherits the broader `IJBTerminal` surface and supports V6 preview flows.
- The router can cash out JB project tokens as part of a route. Unclaimed credit inputs are not a direct router input; users should materialize credits first.
- Registry defaults are thresholded by project ID and expose history so changing the default does not silently reroute older projects.
- Metadata purposes use V6 lifecycle names: router metadata should use `pay` and `cashOut`, keyed to the router address.

## ABI, Event, and Error Changes

- Replaced interface:
  - `IJBSwapTerminal` -> `IJBRouterTerminal`
- Removed swap-terminal functions:
  - `addDefaultPool(...)`
  - `addTwapParamsFor(...)`
  - `twapWindowOf(uint256,IUniswapV3Pool)`
  - swap-terminal constants such as `MIN_DEFAULT_POOL_CARDINALITY` and `UNCERTAIN_SLIPPAGE_TOLERANCE`
- Added router query functions:
  - `discoverPool(address,address)`
  - `discoverBestPool(address,address)`
- Added/changed registry functions:
  - `defaultTerminalFor(uint256)`
  - `defaultTerminalHistoryAt(uint256)`
  - `defaultTerminalHistoryLength()`
  - `defaultTerminalProjectIdThreshold()`
  - `lockTerminalFor(uint256,IJBTerminal)` now includes an expected terminal.
  - `PERMIT2()`
- Added or changed events:
  - registry events are namespaced as `JBRouterTerminalRegistry_*` and include caller fields.
  - `Permit2AllowanceFailed`
- Added or migration-sensitive errors include:
  - terminal-not-set / terminal-not-allowed registry errors
  - quote token mismatch and manipulation-resistant quote errors on router paths
  - circular forwarding and lock mismatch errors

## Metadata Changes

- `quoteForSwap` metadata became `pay`.
- `cashOutMinReclaimed` metadata became `cashOut`.
- The `pay` quote payload includes the quoted output token and minimum output, so old `abi.encode(minAmountOut)` payloads are not sufficient.
- Metadata IDs are keyed to the router address; using old purpose strings silently disables the intended slippage protection.

## Machine-Checked ABI Coverage

Generated from Foundry `out/**/*.json` artifacts, filtered to this repo's own runtime source roots and excluding tests, scripts, and dependencies.

- V5 comparison package: `nana-swap-terminal-v5`.
- Own-source ABI artifacts compared: V6 `13`, V5 `6`.
- Contract/interface coverage: `12` added, `5` removed, `0` shared names with ABI changes, `1` shared names ABI-identical.
- Shared-name ABI item deltas: `0` added, `0` removed, `0` modified.

Added V6 ABI artifacts:
- `IGeomeanOracle` from `src/interfaces/IGeomeanOracle.sol`: `1` functions, `0` events, `0` errors.
- `IJBForwardingTerminal` from `src/interfaces/IJBForwardingTerminal.sol`: `1` functions, `0` events, `0` errors.
- `IJBPayRoutePreviewer` from `src/interfaces/IJBPayRoutePreviewer.sol`: `8` functions, `0` events, `0` errors.
- `IJBPayRouteResolver` from `src/interfaces/IJBPayRouteResolver.sol`: `5` functions, `0` events, `0` errors.
- `IJBPayerTracker`: consumed from `@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol` (the canonical definition; the local copy was de-duplicated). `1` functions, `0` events, `0` errors.
- `IJBRouterTerminal` from `src/interfaces/IJBRouterTerminal.sol`: `11` functions, `6` events, `0` errors.
- `IJBRouterTerminalRegistry` from `src/interfaces/IJBRouterTerminalRegistry.sol`: `25` functions, `11` events, `0` errors.
- `JBForwardingCheck` from `src/libraries/JBForwardingCheck.sol`: `0` functions, `0` events, `0` errors.
- `JBPayRouteResolver` from `src/JBPayRouteResolver.sol`: `6` functions, `0` events, `2` errors.
- `JBRouterTerminal` from `src/JBRouterTerminal.sol`: `30` functions, `7` events, `23` errors.
- `JBRouterTerminalRegistry` from `src/JBRouterTerminalRegistry.sol`: `31` functions, `12` events, `16` errors.
- `JBSwapLib` from `src/libraries/JBSwapLib.sol`: `0` functions, `0` events, `0` errors.

Removed V5 ABI artifacts:
- `IJBSwapTerminal` from `src/interfaces/IJBSwapTerminal.sol`: `9` functions, `0` events, `0` errors.
- `IJBSwapTerminalRegistry` from `src/interfaces/IJBSwapTerminalRegistry.sol`: `18` functions, `10` events, `0` errors.
- `JBSwapTerminal` from `src/JBSwapTerminal.sol`: `31` functions, `7` events, `21` errors.
- `JBSwapTerminal5_1` from `src/JBSwapTerminal5_1.sol`: `31` functions, `6` events, `18` errors.
- `JBSwapTerminalRegistry` from `src/JBSwapTerminalRegistry.sol`: `25` functions, `11` events, `11` errors.

Generated event/error name deltas:
- Event names added:
  - `AddToBalance`, `HookAfterRecordPay`, `JBRouterTerminalRegistry_AllowTerminal`, `JBRouterTerminalRegistry_DisallowTerminal`, `JBRouterTerminalRegistry_LockTerminal`, `JBRouterTerminalRegistry_SetDefaultTerminal`, `JBRouterTerminalRegistry_SetTerminal`, `MigrateTerminal`.
  - `OwnershipTransferred`, `Pay`, `Permit2AllowanceFailed`, `SetAccountingContext`.
- Event names removed or replaced:
  - `AddToBalance`, `HookAfterRecordPay`, `JBSwapTerminalRegistry_AllowTerminal`, `JBSwapTerminalRegistry_DisallowTerminal`, `JBSwapTerminalRegistry_LockTerminal`, `JBSwapTerminalRegistry_SetDefaultTerminal`, `JBSwapTerminalRegistry_SetTerminal`, `MigrateTerminal`.
  - `OwnershipTransferred`, `Pay`, `Permit2AllowanceFailed`, `SetAccountingContext`.
- Error names added:
  - `FailedCall`, `InsufficientBalance`, `JBPermissioned_Unauthorized`, `JBRouterTerminalRegistry_AmountOverflow`, `JBRouterTerminalRegistry_CannotDisallowDefaultTerminal`, `JBRouterTerminalRegistry_CircularForward`, `JBRouterTerminalRegistry_NoMsgValueAllowed`, `JBRouterTerminalRegistry_PermitAllowanceNotEnough`.
  - `JBRouterTerminalRegistry_TerminalLocked`, `JBRouterTerminalRegistry_TerminalMismatch`, `JBRouterTerminalRegistry_TerminalNotAllowed`, `JBRouterTerminalRegistry_TerminalNotSet`, `JBRouterTerminalRegistry_ZeroAddress`, `JBRouterTerminal_AlreadyConfigured`, `JBRouterTerminal_AmountOverflow`, `JBRouterTerminal_CallerNotPool`.
  - `JBRouterTerminal_CallerNotPoolManager`, `JBRouterTerminal_CashOutDidNotDeliver`, `JBRouterTerminal_CashOutLoopLimit`, `JBRouterTerminal_InsufficientTwapHistory`, `JBRouterTerminal_ManipulationResistantQuoteRequired`, `JBRouterTerminal_NoCashOutPath`, `JBRouterTerminal_NoLiquidity`, `JBRouterTerminal_NoMsgValueAllowed`.
  - `JBRouterTerminal_NoObservationHistory`, `JBRouterTerminal_NoPoolFound`, `JBRouterTerminal_NoRouteFound`, `JBRouterTerminal_NonStandardTerminalToken`, `JBRouterTerminal_PermitAllowanceNotEnough`, `JBRouterTerminal_QuoteTokenMismatch`, `JBRouterTerminal_SlippageExceeded`, `JBRouterTerminal_Unauthorized`.
  - `OwnableInvalidOwner`, `OwnableUnauthorizedAccount`, `PRBMath_MulDiv_Overflow`, `SafeERC20FailedOperation`, `T`.
- Error names removed or replaced:
  - `FailedCall`, `InsufficientBalance`, `JBPermissioned_Unauthorized`, `JBSwapTerminalRegistry_NoMsgValueAllowed`, `JBSwapTerminalRegistry_PermitAllowanceNotEnough`, `JBSwapTerminalRegistry_TerminalLocked`, `JBSwapTerminalRegistry_TerminalNotAllowed`, `JBSwapTerminalRegistry_TerminalNotSet`.
  - `JBSwapTerminal_AmountOverflow`, `JBSwapTerminal_CallerNotPool`, `JBSwapTerminal_InvalidTwapWindow`, `JBSwapTerminal_NoDefaultPoolDefined`, `JBSwapTerminal_NoLiquidity`, `JBSwapTerminal_NoMsgValueAllowed`, `JBSwapTerminal_NoObservationHistory`, `JBSwapTerminal_PermitAllowanceNotEnough`.
  - `JBSwapTerminal_SpecifiedSlippageExceeded`, `JBSwapTerminal_TokenNotAccepted`, `JBSwapTerminal_UnexpectedCall`, `JBSwapTerminal_WrongPool`, `JBSwapTerminal_ZeroToken`, `OwnableInvalidOwner`, `OwnableUnauthorizedAccount`, `PRBMath_MulDiv_Overflow`.
  - `SafeERC20FailedOperation`, `T`.

Shared ABI artifacts checked with no ABI item changes:
- `IWETH9`.

## Migration Notes

- Replace swap-terminal ABI references with router-terminal and registry ABIs.
- Rebuild route quoting and metadata construction around V6 discovery/preview methods.
- Index registry default-terminal history if your system computes historical effective terminals.
- Use `defaultTerminalFor(projectId)`, not just `defaultTerminal()`, when resolving the effective default for a specific project.
