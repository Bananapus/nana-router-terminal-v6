// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

/// @notice Indicates that a terminal is a forwarding layer rather than the final accounting receiver.
/// @dev A non-zero return from `terminalOf` means "forwards"; zero or revert means "does not forward."
interface IJBForwardingTerminal {
    /// @notice The concrete terminal this forwarding layer would route a project's payment into.
    /// @param projectId The project whose downstream terminal should be resolved.
    /// @return terminal The concrete terminal the forwarder would call for `projectId`.
    function terminalOf(uint256 projectId) external view returns (IJBTerminal terminal);
}
