// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {IJBForwardingTerminal} from "./IJBForwardingTerminal.sol";
import {IJBPayerTracker} from "./IJBPayerTracker.sol";
import {DefaultTerminalSegment} from "../structs/DefaultTerminalSegment.sol";

/// @notice A registry that maps projects to their preferred router terminal.
interface IJBRouterTerminalRegistry is IJBTerminal, IJBForwardingTerminal, IJBPayerTracker {
    /// @notice Emitted when a terminal is allowed for use by projects.
    /// @param terminal The terminal allowed.
    /// @param caller The address that called the function.
    event JBRouterTerminalRegistry_AllowTerminal(IJBTerminal terminal, address caller);

    /// @notice Emitted when a terminal is disallowed from use by projects.
    /// @param terminal The terminal disallowed.
    /// @param caller The address that called the function.
    event JBRouterTerminalRegistry_DisallowTerminal(IJBTerminal terminal, address caller);

    /// @notice Emitted when a project's terminal is locked and can no longer be changed.
    /// @param projectId The ID of the project locked.
    /// @param caller The address that called the function.
    event JBRouterTerminalRegistry_LockTerminal(uint256 indexed projectId, address caller);

    /// @notice Emitted when the default terminal is changed.
    /// @param terminal The new default terminal.
    /// @param caller The address that called the function.
    event JBRouterTerminalRegistry_SetDefaultTerminal(IJBTerminal terminal, address caller);

    /// @notice Emitted when a project's terminal is set.
    /// @param projectId The ID of the project updated.
    /// @param terminal The terminal set for the project.
    /// @param caller The address that called the function.
    event JBRouterTerminalRegistry_SetTerminal(uint256 indexed projectId, IJBTerminal terminal, address caller);

    /// @notice A Permit2 allowance approval failed.
    /// @param token The token the approval was attempted for.
    /// @param owner The owner of the tokens.
    /// @param reason The failure reason.
    event Permit2AllowanceFailed(address indexed token, address indexed owner, bytes reason);

    /// @notice The default terminal used when a project has not set a specific terminal.
    /// @dev Only applies to projects with ID > `defaultTerminalProjectIdThreshold`. Older
    /// projects resolve via `defaultTerminalFor(projectId)`.
    /// @return terminal The default terminal.
    function defaultTerminal() external view returns (IJBTerminal terminal);

    /// @notice The `PROJECTS.count()` snapshot at the moment of the most recent `setDefaultTerminal`.
    /// Projects with ID <= this threshold do NOT fall through to `defaultTerminal`; they fall
    /// through to the historical entry that covers their ID range.
    function defaultTerminalProjectIdThreshold() external view returns (uint256);

    /// @notice The default terminal applicable to a specific project on fall-through, accounting
    /// for the threshold and the snapshot history. Returns zero if no default ever applied.
    /// @param projectId The ID of the project to resolve the default for.
    /// @return terminal The default terminal applicable to this project (zero if none).
    function defaultTerminalFor(uint256 projectId) external view returns (IJBTerminal terminal);

    /// @notice Read a historical default-terminal snapshot.
    /// @param index The history index (0 is the oldest captured snapshot).
    /// @return segment The `maxProjectId + terminal` pair for that history slot.
    function defaultTerminalHistoryAt(uint256 index) external view returns (DefaultTerminalSegment memory segment);

    /// @notice The total number of historical default-terminal snapshots captured.
    function defaultTerminalHistoryLength() external view returns (uint256);

    /// @notice Whether the terminal for the given project is locked and cannot be changed.
    /// @param projectId The ID of the project.
    /// @return isLocked Whether the terminal is locked.
    function hasLockedTerminal(uint256 projectId) external view returns (bool isLocked);

    /// @notice Whether the given terminal is allowed to be set for projects.
    /// @param terminal The terminal to check.
    /// @return isAllowed Whether the terminal is allowed.
    function isTerminalAllowed(IJBTerminal terminal) external view returns (bool isAllowed);

    /// @notice The permit2 utility used for token approvals.
    /// @return permit2 The permit2 contract.
    function PERMIT2() external view returns (IPermit2 permit2);

    /// @notice The project registry.
    /// @return projects The projects contract.
    function PROJECTS() external view returns (IJBProjects projects);

    /// @notice Allow a terminal to be used by projects.
    /// @param terminal The terminal to allow.
    function allowTerminal(IJBTerminal terminal) external;

    /// @notice Disallow a terminal from use by projects.
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
