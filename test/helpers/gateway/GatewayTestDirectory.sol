// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

/// @notice Stores configurable terminal membership and primary-terminal answers for gateway fixtures.
contract GatewayTestDirectory {
    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Whether a terminal belongs to a project.
    /// @custom:param projectId The project whose membership is configured.
    /// @custom:param terminal The terminal to check.
    mapping(uint256 projectId => mapping(address terminal => bool)) public isTerminal;

    /// @notice The primary terminal for each project's payment token.
    /// @custom:param projectId The project whose primary terminal is configured.
    /// @custom:param token The payment token.
    mapping(uint256 projectId => mapping(address token => IJBTerminal terminal)) public primaryTerminal;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The configured list of terminals for each project.
    /// @custom:param projectId The project whose terminal list is configured.
    mapping(uint256 projectId => IJBTerminal[] terminals) internal _terminalsOf;

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Configure whether a terminal belongs to a project.
    /// @param projectId The project to configure.
    /// @param terminal The terminal whose membership to set.
    /// @param flag Whether the terminal belongs to the project.
    function setIsTerminalOf(uint256 projectId, IJBTerminal terminal, bool flag) external {
        isTerminal[projectId][address(terminal)] = flag;
    }

    /// @notice Configure a project's primary terminal for a token.
    /// @param projectId The project to configure.
    /// @param token The payment token.
    /// @param terminal The primary terminal to use.
    function setPrimaryTerminalOf(uint256 projectId, address token, IJBTerminal terminal) external {
        primaryTerminal[projectId][token] = terminal;
    }

    /// @notice Configure a project's terminal list.
    /// @param projectId The project to configure.
    /// @param terminals The terminal list to return.
    function setTerminalsOf(uint256 projectId, IJBTerminal[] calldata terminals) external {
        _terminalsOf[projectId] = terminals;
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Whether a terminal belongs to a project.
    /// @param projectId The project whose membership to check.
    /// @param terminal The terminal to check.
    /// @return flag Whether the terminal belongs to the project.
    function isTerminalOf(uint256 projectId, IJBTerminal terminal) external view returns (bool flag) {
        return isTerminal[projectId][address(terminal)];
    }

    /// @notice The primary terminal configured for a project's token.
    /// @param projectId The project to check.
    /// @param token The payment token.
    /// @return terminal The configured primary terminal.
    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal terminal) {
        return primaryTerminal[projectId][token];
    }

    /// @notice The configured terminal list for a project.
    /// @param projectId The project to check.
    /// @return terminals The configured terminal list.
    function terminalsOf(uint256 projectId) external view returns (IJBTerminal[] memory terminals) {
        return _terminalsOf[projectId];
    }
}
