// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {IJBForwardingTerminal} from "./IJBForwardingTerminal.sol";
import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";

import {DefaultTerminalSegment} from "../structs/DefaultTerminalSegment.sol";
import {JBPendingTerminalCall} from "../structs/JBPendingTerminalCall.sol";
import {JBPendingTerminalCallFailure} from "../structs/JBPendingTerminalCallFailure.sol";

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

    /// @notice Emitted after a retained terminal call is successfully retried.
    /// @param id The deterministic identifier of the processed call.
    /// @param call The pending call that was processed.
    /// @param terminal The terminal that received the retained funds.
    /// @param caller The address that retried the call.
    event JBRouterTerminalRegistry_ProcessTerminalCall(
        bytes32 indexed id, JBPendingTerminalCall call, IJBTerminal terminal, address caller
    );

    /// @notice Emitted when a terminal-originated payment is retained after its downstream forwarding call fails.
    /// @param id The deterministic identifier of the pending call.
    /// @param call The pending call that was retained.
    /// @param amount The amount added to this pending call.
    /// @param caller The address that originated the registry call.
    event JBRouterTerminalRegistry_QueueTerminalCall(
        bytes32 indexed id, JBPendingTerminalCall call, uint256 amount, address caller
    );

    /// @notice Emitted when a gas-qualified retry reproduces a downstream terminal failure.
    /// @param id The deterministic identifier of the pending call.
    /// @param errorHash The hash of the exact revert data.
    /// @param routeHash The hash of the resolved terminal, its code hash, and the call operation.
    /// @param count The number of consecutive matching qualified failures.
    /// @param nextAttemptAt The earliest timestamp at which another qualifying attempt may be made.
    /// @param reason The exact revert data returned by the downstream call.
    /// @param caller The address that retried the call.
    event JBRouterTerminalRegistry_RecordTerminalCallFailure(
        bytes32 indexed id,
        bytes32 indexed errorHash,
        bytes32 indexed routeHash,
        uint32 count,
        uint256 nextAttemptAt,
        bytes reason,
        address caller
    );

    /// @notice Emitted when a consistently failing pending call is restored to its source project's balance.
    /// @param id The deterministic identifier of the refunded pending call.
    /// @param call The pending call whose retained funds were restored.
    /// @param caller The address that finalized the refund.
    event JBRouterTerminalRegistry_RefundTerminalCall(bytes32 indexed id, JBPendingTerminalCall call, address caller);

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
    /// @param caller The address that called the terminal function.
    event Permit2AllowanceFailed(address indexed token, address indexed owner, bytes reason, address caller);

    /// @notice The default terminal used when a project has not set a specific terminal.
    /// @dev Only applies to projects with ID > `defaultTerminalProjectIdThreshold`. Older projects resolve via
    /// `defaultTerminalFor(projectId)`.
    /// @return terminal The default terminal.
    function defaultTerminal() external view returns (IJBTerminal terminal);

    /// @notice The default terminal applicable to a specific project on fall-through, accounting for the threshold
    /// and the snapshot history. Returns zero if no default ever applied to the project's ID range.
    /// @param projectId The ID of the project to resolve the default for.
    /// @return terminal The default terminal applicable to this project (zero if none).
    function defaultTerminalFor(uint256 projectId) external view returns (IJBTerminal terminal);

    /// @notice Read a historical default-terminal snapshot.
    /// @param index The history index (0 is the oldest captured snapshot).
    /// @return segment The `maxProjectId + terminal` pair for that history slot.
    function defaultTerminalHistoryAt(uint256 index) external view returns (DefaultTerminalSegment memory segment);

    /// @notice The total number of historical default-terminal snapshots captured.
    /// @return length The number of entries in the default-terminal history.
    function defaultTerminalHistoryLength() external view returns (uint256 length);

    /// @notice The `PROJECTS.count()` snapshot at the latest `setDefaultTerminal`, used for historical fall-through.
    /// @return threshold The project-ID threshold beyond which `defaultTerminal` applies on fall-through.
    function defaultTerminalProjectIdThreshold() external view returns (uint256 threshold);

    /// @notice Whether the terminal for the given project is locked and cannot be changed.
    /// @param projectId The ID of the project.
    /// @return isLocked Whether the terminal is locked.
    function hasLockedTerminal(uint256 projectId) external view returns (bool isLocked);

    /// @notice Whether the given terminal is allowed to be set for projects.
    /// @param terminal The terminal to check.
    /// @return isAllowed Whether the terminal is allowed.
    function isTerminalAllowed(IJBTerminal terminal) external view returns (bool isAllowed);

    /// @notice Return the consecutive qualified failure streak for a pending terminal call.
    /// @param id The deterministic pending-call identifier.
    /// @return failure The pending call's matching failure state.
    function pendingTerminalCallFailureOf(bytes32 id)
        external
        view
        returns (JBPendingTerminalCallFailure memory failure);

    /// @notice Return a terminal-originated payment retained after downstream forwarding failed.
    /// @param id The deterministic pending-call identifier.
    /// @return call The retained terminal call.
    function pendingTerminalCallOf(bytes32 id) external view returns (JBPendingTerminalCall memory call);

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

    /// @notice Make the final well-funded delivery attempt and autonomously refund a consistently failing call.
    /// @param id The deterministic pending-call identifier.
    /// @return wasRefunded Whether the retained payment was restored to its source project.
    /// @return beneficiaryTokenCount The number of project tokens minted if the final attempt succeeded.
    function finalizePendingTerminalCall(bytes32 id) external returns (bool wasRefunded, uint256 beneficiaryTokenCount);

    /// @notice Lock the terminal for a project, preventing it from being changed.
    /// @param projectId The ID of the project to lock the terminal for.
    /// @param expectedTerminal The terminal the caller expects to lock. Reverts if the current terminal doesn't match.
    function lockTerminalFor(uint256 projectId, IJBTerminal expectedTerminal) external;

    /// @notice Make a gas-qualified retry of a terminal-originated payment retained after downstream failure.
    /// @param id The deterministic pending-call identifier.
    /// @return beneficiaryTokenCount The number of project tokens minted if the retry succeeds, or zero for a failed
    /// retry or add-to-balance call.
    function processPendingTerminalCall(bytes32 id) external returns (uint256 beneficiaryTokenCount);

    /// @notice Set the default terminal used when a project has not set a specific terminal.
    /// @param terminal The terminal to set as the default.
    function setDefaultTerminal(IJBTerminal terminal) external;

    /// @notice Set the terminal for a specific project.
    /// @param projectId The ID of the project to set the terminal for.
    /// @param terminal The terminal to set.
    function setTerminalFor(uint256 projectId, IJBTerminal terminal) external;
}
