// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A consecutive, gas-qualified failure streak for a retained terminal call.
/// @custom:member count The number of matching failures recorded in distinct retry windows.
/// @custom:member lastFailureAt The timestamp of the latest matching failure.
/// @custom:member errorHash The hash of the exact revert data returned by the downstream call.
/// @custom:member routeHash The hash of the resolved terminal address, its code hash, and the call operation.
struct JBPendingTerminalCallFailure {
    uint32 count;
    uint48 lastFailureAt;
    bytes32 errorHash;
    bytes32 routeHash;
}
