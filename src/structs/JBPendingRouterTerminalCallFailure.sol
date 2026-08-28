// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev `count` and `lastFailureAt` follow `errorHash` so the struct packs into two storage slots.
/// @custom:member errorHash The selector-level fingerprint of the matching downstream error.
/// @custom:member count The consecutive qualified attempts which produced `errorHash`.
/// @custom:member highestGasLimit The largest qualified budget already forwarded, which later attempts never go below.
/// @custom:member lastFailureAt The timestamp of the latest qualified failure.
struct JBPendingRouterTerminalCallFailure {
    bytes32 errorHash;
    uint32 count;
    uint48 lastFailureAt;
    uint64 highestGasLimit;
}
