// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBForwardingTerminal} from "../interfaces/IJBForwardingTerminal.sol";

/// @notice Shared circular-terminal detection used by both `JBRouterTerminal` (execution) and
/// `JBPayRouteResolver` (preview).
library JBForwardingCheck {
    /// @notice Whether routing through `terminal` would cycle back to `target` within 5 hops.
    /// @param target The address to detect cycles against (typically the router).
    /// @param projectId The project to follow the forwarding chain for.
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

            // Probe via staticcall so plain terminals degrade cleanly.
            (bool success, bytes memory data) =
                address(current).staticcall(abi.encodeCall(IJBForwardingTerminal.terminalOf, (projectId)));

            // Non-forwarding terminals (call fails, returns zero, or returns a word that is not an address) end the
            // chain — not circular. Decode as a word rather than an address so a malformed reply cannot revert the
            // caller's frame; the refund search in particular must be able to move on to the next candidate.
            if (!success || data.length < 32) return false;
            uint256 forwardingTarget = abi.decode(data, (uint256));
            if (forwardingTarget == 0 || forwardingTarget > type(uint160).max) return false;

            // forge-lint: disable-next-line(unsafe-typecast)
            current = IJBTerminal(address(uint160(forwardingTarget)));
        }

        // 5 hops without resolution — treat as circular to be safe.
        return true;
    }
}
