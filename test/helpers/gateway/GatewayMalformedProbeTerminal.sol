// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GatewayTestSourceTerminal} from "./GatewayTestSourceTerminal.sol";

/// @notice Acts as a source terminal whose forwarding probe returns a word with dirty upper bits.
contract GatewayMalformedProbeTerminal is GatewayTestSourceTerminal {
    /// @notice Responds to a forwarding probe with a word outside the ABI address range.
    /// @dev The project identifier is ignored because every project probe has the same malformed response.
    /// @return terminal The malformed address word returned directly by the assembly block.
    function terminalOf(uint256) external pure returns (address terminal) {
        // The dirty upper bits exercise forwarding-probe validation before refund discovery tries another terminal.
        assembly ("memory-safe") {
            terminal := not(0)
            mstore(0, terminal)
            return(0, 32)
        }
    }
}
