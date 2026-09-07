// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Receives a router callback before the gateway's payment tokens are pulled.
interface IGatewayRouterCallback {
    /// @notice Exercises nested routing while the outer router's allowance is outstanding.
    function beforeGatewayRouterPull() external;
}
