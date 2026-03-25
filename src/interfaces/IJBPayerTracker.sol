// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Exposes the original payer of a forwarded transaction.
/// @dev Implemented by intermediaries (e.g. JBRouterTerminalRegistry) that forward calls on behalf of a user.
/// Downstream contracts can query this to refund partial-fill leftovers to the true payer.
interface IJBPayerTracker {
    /// @notice The original payer of the current transaction.
    /// @return The original payer address, or `address(0)` if no forwarding is in progress.
    function originalPayer() external view returns (address);
}
