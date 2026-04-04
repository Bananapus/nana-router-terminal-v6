// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

/// @notice Indicates that a terminal is a forwarding layer rather than the final accounting receiver.
interface IJBForwardingTerminal {
    /// @notice Whether this terminal forwards incoming terminal calls to another terminal-facing surface.
    /// @return isForwarding A flag indicating whether downstream receipt enforcement should happen elsewhere.
    function forwardsTerminalPayments() external view returns (bool isForwarding);

    /// @notice The concrete terminal this forwarding layer would route a project's payment into.
    /// @param projectId The project whose downstream terminal should be resolved.
    /// @return terminal The concrete terminal the forwarder would call for `projectId`.
    function forwardingTerminalOf(uint256 projectId) external view returns (IJBTerminal terminal);
}
