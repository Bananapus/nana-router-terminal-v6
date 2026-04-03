// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Indicates that a terminal is a forwarding layer rather than the final accounting receiver.
interface IJBForwardingTerminal {
    /// @notice Whether this terminal forwards incoming terminal calls to another terminal-facing surface.
    /// @return isForwarding A flag indicating whether downstream receipt enforcement should happen elsewhere.
    function forwardsTerminalPayments() external view returns (bool isForwarding);
}
