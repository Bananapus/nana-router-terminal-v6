// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Supplies the minimal store dependency for checking core-terminal payer and interface propagation.
contract GatewayTestTerminalStore {
    /// @notice Returns no directory because payer-propagation checks do not perform store accounting.
    /// @return directory The empty directory address.
    function DIRECTORY() external pure returns (address directory) {
        return address(0);
    }
}
