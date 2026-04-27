// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBForwardingTerminal} from "../interfaces/IJBForwardingTerminal.sol";

/// @notice Shared circular-terminal detection used by both `JBRouterTerminal` (execution) and
/// `JBPayRouteResolver` (preview).
library JBForwardingCheck {
    /// @notice Whether routing through `terminal` would cycle back to `target` within 5 hops.
    /// @param target The address to detect cycles against (typically the router).
    /// @param projectId The project whose forwarding chain is being followed.
    /// @param terminal The starting terminal to check.
    /// @return isCircular True if the terminal forwards (directly or transitively) back to `target`.
    function isCircularTerminal(
        address target,
        uint256 projectId,
        IJBTerminal terminal
    )
        internal
        view
        returns (bool isCircular)
    {
        IJBTerminal current = terminal;
        for (uint256 i; i < 5; i++) {
            if (address(current) == target) return true;

            // Follow the forwarding chain. Non-forwarding terminals end the chain — not circular.
            // slither-disable-next-line calls-loop
            try IJBForwardingTerminal(address(current)).terminalOf(projectId) returns (IJBTerminal forwardingTarget) {
                if (address(forwardingTarget) == address(0)) return false;
                current = forwardingTarget;
            } catch {
                return false;
            }
        }

        // 5 hops without resolution — treat as circular to be safe.
        return true;
    }
}
