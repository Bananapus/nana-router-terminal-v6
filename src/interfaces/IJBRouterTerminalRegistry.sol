// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

/// @notice A registry that maps projects to their preferred router terminal.
interface IJBRouterTerminalRegistry is IJBTerminal {
    /// @notice Emitted when a terminal is allowed for use by projects.
    /// @param terminal The terminal that was allowed.
    event JBRouterTerminalRegistry_AllowTerminal(IJBTerminal terminal);

    /// @notice Emitted when a terminal is disallowed from use by projects.
    /// @param terminal The terminal that was disallowed.
    event JBRouterTerminalRegistry_DisallowTerminal(IJBTerminal terminal);

    /// @notice Emitted when a project's terminal is locked and can no longer be changed.
    /// @param projectId The ID of the project whose terminal was locked.
    event JBRouterTerminalRegistry_LockTerminal(uint256 projectId);

    /// @notice Emitted when the default terminal is changed.
    /// @param terminal The new default terminal.
    event JBRouterTerminalRegistry_SetDefaultTerminal(IJBTerminal terminal);

    /// @notice Emitted when a project's terminal is set.
    /// @param projectId The ID of the project whose terminal was set.
    /// @param terminal The terminal that was set.
    event JBRouterTerminalRegistry_SetTerminal(uint256 indexed projectId, IJBTerminal terminal);

    /// @notice The default terminal used when a project has not set a specific terminal.
    /// @return The default terminal.
    function defaultTerminal() external view returns (IJBTerminal);

    /// @notice Whether the terminal for the given project is locked and cannot be changed.
    /// @param projectId The ID of the project.
    /// @return Whether the terminal is locked.
    function hasLockedTerminal(uint256 projectId) external view returns (bool);

    /// @notice Whether the given terminal is allowed to be set for projects.
    /// @param terminal The terminal to check.
    /// @return Whether the terminal is allowed.
    function isTerminalAllowed(IJBTerminal terminal) external view returns (bool);

    /// @notice The permit2 utility used for token approvals.
    /// @return The permit2 contract.
    function PERMIT2() external view returns (IPermit2);

    /// @notice The project registry.
    /// @return The projects contract.
    function PROJECTS() external view returns (IJBProjects);

    /// @notice The terminal for the given project, or the default terminal if none is set.
    /// @param projectId The ID of the project.
    /// @return The terminal for the project.
    function terminalOf(uint256 projectId) external view returns (IJBTerminal);

    /// @notice Allow a terminal to be used by projects.
    /// @param terminal The terminal to allow.
    function allowTerminal(IJBTerminal terminal) external;

    /// @notice Disallow a terminal from being used by projects.
    /// @param terminal The terminal to disallow.
    function disallowTerminal(IJBTerminal terminal) external;

    /// @notice Lock the terminal for a project, preventing it from being changed.
    /// @param projectId The ID of the project to lock the terminal for.
    /// @param expectedTerminal The terminal the caller expects to lock. Reverts if the current terminal doesn't match.
    function lockTerminalFor(uint256 projectId, IJBTerminal expectedTerminal) external;

    /// @notice Set the default terminal used when a project has not set a specific terminal.
    /// @param terminal The terminal to set as the default.
    function setDefaultTerminal(IJBTerminal terminal) external;

    /// @notice Set the terminal for a specific project.
    /// @param projectId The ID of the project to set the terminal for.
    /// @param terminal The terminal to set.
    function setTerminalFor(uint256 projectId, IJBTerminal terminal) external;
}
