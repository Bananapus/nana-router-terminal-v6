// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Receives a token callback during the gateway's intake balance measurement.
interface IGatewayTokenTransferCallback {
    /// @notice Exercises reentry before the incoming payment token changes balances.
    function beforeGatewayTokenTransfer() external;
}
