// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Exposes a gas-consuming call that the router can invoke from a view function.
interface IGatewayGasBurner {
    /// @notice Consume the gas forwarded to this call without returning.
    /// @dev A separate call frame models a downstream route exhausting its allocated gas.
    function burn() external view;
}
