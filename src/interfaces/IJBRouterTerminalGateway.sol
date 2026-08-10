// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";

import {IJBForwardingTerminal} from "./IJBForwardingTerminal.sol";
import {IJBRouterTerminal} from "./IJBRouterTerminal.sol";

import {JBPendingRouterTerminalCall} from "../structs/JBPendingRouterTerminalCall.sol";
import {JBPendingRouterTerminalCallFailure} from "../structs/JBPendingRouterTerminalCallFailure.sol";

/// @notice A fail-closed gateway which retains original input tokens when a router-terminal call fails.
interface IJBRouterTerminalGateway is IJBForwardingTerminal, IJBPayerTracker, IJBRouterTerminal {
    /// @notice Emitted after a retained call succeeds on a permissionless retry.
    /// @param id The pending call identifier.
    /// @param call The call which was processed.
    /// @param beneficiaryTokenCount The project tokens returned by a successful `pay` call.
    /// @param caller The account which processed the call.
    event JBRouterTerminalGateway_ProcessPendingCall(
        bytes32 indexed id, JBPendingRouterTerminalCall call, uint256 beneficiaryTokenCount, address caller
    );

    /// @notice Emitted when a failed router-terminal call is retained for retry.
    /// @param id The pending call identifier.
    /// @param call The retained call.
    /// @param errorHash The selector-level fingerprint of the initial downstream error.
    /// @param caller The account whose call was retained.
    event JBRouterTerminalGateway_QueuePendingCall(
        bytes32 indexed id, JBPendingRouterTerminalCall call, bytes32 errorHash, address caller
    );

    /// @notice Emitted when a qualified retry fails.
    /// @param id The pending call identifier.
    /// @param errorHash The selector-level downstream error fingerprint.
    /// @param count The consecutive qualified attempts with this error selector.
    /// @param nextAttemptAt The earliest timestamp of the next qualified attempt.
    /// @param caller The account which attempted the call.
    event JBRouterTerminalGateway_RecordTerminalCallFailure(
        bytes32 indexed id, bytes32 indexed errorHash, uint32 count, uint256 nextAttemptAt, address caller
    );

    /// @notice Emitted when a consistently failing call is returned to its source project.
    /// @param id The pending call identifier.
    /// @param call The refunded call.
    /// @param caller The account which finalized the refund.
    event JBRouterTerminalGateway_RefundPendingCall(
        bytes32 indexed id, JBPendingRouterTerminalCall call, address caller
    );

    /// @notice The directory used to resolve a source project's current accounting terminal for refunds.
    /// @return directory The core terminal directory.
    function DIRECTORY() external view returns (IJBDirectory directory);

    /// @notice The number of matching qualified failures required before finalization.
    /// @return count The required failure count.
    function FINALIZATION_FAILURE_COUNT() external view returns (uint256 count);

    /// @notice The default and minimum gas forwarded by a qualified router attempt.
    /// @return gasLimit The default and minimum qualified attempt gas limit.
    function QUALIFIED_CALL_GAS() external view returns (uint256 gasLimit);

    /// @notice The minimum delay between qualified failures and before finalization.
    /// @return delay The retry delay in seconds.
    function RETRY_DELAY() external view returns (uint256 delay);

    /// @notice The immutable router terminal called by this gateway.
    /// @return router The downstream router terminal.
    function ROUTER() external view returns (IJBRouterTerminal router);

    /// @notice The total number of pending-call identifiers issued.
    /// @return count The issued identifier count.
    function pendingCallCount() external view returns (uint256 count);

    /// @notice Return a pending call's consecutive matching failure state.
    /// @param id The pending call identifier.
    /// @return failure The matching failure state.
    function pendingCallFailureOf(bytes32 id) external view returns (JBPendingRouterTerminalCallFailure memory failure);

    /// @notice Return a router call retained after its first attempt failed.
    /// @param id The pending call identifier.
    /// @return call The retained call.
    function pendingCallOf(bytes32 id) external view returns (JBPendingRouterTerminalCall memory call);

    /// @notice Make one final qualified attempt, refunding only if its error selector matches the qualified streak.
    /// @param id The pending call identifier.
    /// @param memo The original memo bound by the pending call.
    /// @param metadata The original metadata bound by the pending call.
    /// @return wasRefunded Whether the retained input was refunded.
    /// @return beneficiaryTokenCount The project tokens returned if the final `pay` attempt succeeded.
    function finalizePendingCall(
        bytes32 id,
        string calldata memo,
        bytes calldata metadata
    )
        external
        returns (bool wasRefunded, uint256 beneficiaryTokenCount);

    /// @notice Make one final qualified attempt with an expanded gas budget.
    /// @param id The pending call identifier.
    /// @param gasLimit The gas to forward, which must be at least `QUALIFIED_CALL_GAS`.
    /// @param memo The original memo bound by the pending call.
    /// @param metadata The original metadata bound by the pending call.
    /// @return wasRefunded Whether the retained input was refunded.
    /// @return beneficiaryTokenCount The project tokens returned if the final `pay` attempt succeeded.
    function finalizePendingCallWithGas(
        bytes32 id,
        uint256 gasLimit,
        string calldata memo,
        bytes calldata metadata
    )
        external
        returns (bool wasRefunded, uint256 beneficiaryTokenCount);

    /// @notice Make a gas-qualified, permissionless attempt to process a retained call.
    /// @param id The pending call identifier.
    /// @param memo The original memo bound by the pending call.
    /// @param metadata The original metadata bound by the pending call.
    /// @return beneficiaryTokenCount The project tokens returned if a routed `pay` succeeds.
    function processPendingCall(
        bytes32 id,
        string calldata memo,
        bytes calldata metadata
    )
        external
        returns (uint256 beneficiaryTokenCount);

    /// @notice Make a gas-qualified, permissionless attempt with an expanded gas budget.
    /// @param id The pending call identifier.
    /// @param gasLimit The gas to forward, which must be at least `QUALIFIED_CALL_GAS`.
    /// @param memo The original memo bound by the pending call.
    /// @param metadata The original metadata bound by the pending call.
    /// @return beneficiaryTokenCount The project tokens returned if a routed `pay` succeeds.
    function processPendingCallWithGas(
        bytes32 id,
        uint256 gasLimit,
        string calldata memo,
        bytes calldata metadata
    )
        external
        returns (uint256 beneficiaryTokenCount);
}
