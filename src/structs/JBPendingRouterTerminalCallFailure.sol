// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member count The consecutive qualified attempts which produced `errorHash`.
/// @custom:member errorHash The selector-level fingerprint of the matching downstream error.
/// @custom:member lastFailureAt The timestamp of the latest qualified failure.
struct JBPendingRouterTerminalCallFailure {
    uint32 count;
    bytes32 errorHash;
    uint48 lastFailureAt;
}
