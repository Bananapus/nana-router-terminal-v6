// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {IJBForwardingTerminal} from "./interfaces/IJBForwardingTerminal.sol";
import {IJBRouterTerminal} from "./interfaces/IJBRouterTerminal.sol";
import {IJBRouterTerminalGateway} from "./interfaces/IJBRouterTerminalGateway.sol";

import {JBPendingRouterTerminalCall} from "./structs/JBPendingRouterTerminalCall.sol";
import {JBPendingRouterTerminalCallFailure} from "./structs/JBPendingRouterTerminalCallFailure.sol";
import {PoolInfo} from "./structs/PoolInfo.sol";

/// @notice A router-terminal gateway which retains an original input token when the fallible routing call fails.
/// @dev The registry points to this contract, which forwards atomically into an immutable `JBRouterTerminal`.
contract JBRouterTerminalGateway is IJBRouterTerminalGateway {
    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when retry calldata does not match the data retained with a pending call.
    error JBRouterTerminalGateway_CallDataMismatch(bytes32 expectedHash, bytes32 actualHash);

    /// @notice Thrown when a qualified attempt was not supplied enough gas.
    error JBRouterTerminalGateway_InsufficientRetryGas(uint256 available, uint256 required);

    /// @notice Thrown when native tokens are sent on an ERC20 call.
    error JBRouterTerminalGateway_NoMsgValueAllowed(uint256 value);

    /// @notice Thrown when a pending call has not accumulated enough matching failures to be finalized.
    error JBRouterTerminalGateway_PendingCallNotFinalizable(bytes32 id, uint32 failureCount);

    /// @notice Thrown when a pending call does not exist.
    error JBRouterTerminalGateway_PendingCallNotFound(bytes32 id);

    /// @notice Thrown when another qualified attempt is made before the retry delay has elapsed.
    error JBRouterTerminalGateway_PendingCallNotReady(bytes32 id, uint256 nextAttemptAt);

    /// @notice Thrown when ordinary processing is attempted after a call has qualified for finalization.
    error JBRouterTerminalGateway_PendingCallRequiresFinalization(bytes32 id);

    /// @notice Thrown when a `pay` call with a non-zero minimum cannot be settled synchronously.
    error JBRouterTerminalGateway_RouteFailed(bytes32 errorHash);

    /// @notice Thrown when the immutable router is the zero address.
    error JBRouterTerminalGateway_ZeroAddress();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The number of matching, time-separated qualified failures required before finalization.
    uint256 public constant override FINALIZATION_FAILURE_COUNT = 3;

    /// @notice The gas forwarded by every qualified retry and final attempt.
    uint256 public constant override QUALIFIED_CALL_GAS = 5_000_000;

    /// @notice The minimum delay between qualified failures and before finalization.
    uint256 public constant override RETRY_DELAY = 1 days;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice Gas retained around an attempted route for cleanup and durable failure accounting.
    uint256 internal constant _FAILURE_GAS_RESERVE = 750_000;

    /// @notice The maximum amount of return data included in a bounded failure fingerprint.
    uint256 internal constant _MAX_ERROR_DATA_LENGTH = 256;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The immutable router terminal this gateway calls atomically.
    IJBRouterTerminal public immutable override ROUTER;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The total number of pending-call identifiers issued.
    uint256 public override pendingCallCount;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Qualified failure state for each retained call.
    mapping(bytes32 id => JBPendingRouterTerminalCallFailure) internal _pendingCallFailureOf;

    /// @notice Calls whose original input tokens are retained by this gateway.
    mapping(bytes32 id => JBPendingRouterTerminalCall) internal _pendingCallOf;

    //*********************************************************************//
    // ------------------- transient stored properties ------------------- //
    //*********************************************************************//

    /// @notice The original payer propagated into the downstream router during an active attempt.
    address public transient override originalPayer;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param router The immutable router terminal to call atomically.
    constructor(IJBRouterTerminal router) {
        if (address(router) == address(0)) revert JBRouterTerminalGateway_ZeroAddress();
        ROUTER = router;
    }

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Receive native tokens retained after a failed route.
    receive() external payable {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Empty implementation because accounting contexts are delegated to `ROUTER`.
    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    /// @notice Route an add-to-balance call, retaining its original input if the atomic router call fails.
    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool shouldReturnHeldFees,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        override
    {
        address refundTo = _resolveOriginalPayer(msg.sender);
        amount = _acceptFundsFor({token: token, amount: amount});
        uint256 sourceProjectId = _sourceProjectIdFrom(metadata);

        JBPendingRouterTerminalCall memory call = JBPendingRouterTerminalCall({
            amount: amount,
            beneficiary: address(0),
            callDataHash: keccak256(abi.encode(memo, metadata)),
            minReturnedTokens: 0,
            preferAddToBalance: true,
            projectId: projectId,
            refundTo: refundTo,
            refundToProject: sourceProjectId != 0 && _isTerminal(refundTo),
            shouldReturnHeldFees: shouldReturnHeldFees,
            sourceProjectId: sourceProjectId,
            token: token
        });

        (bool success, bytes32 errorHash,) = _attempt({call: call, memo: memo, metadata: metadata, gasLimit: 0});
        if (!success) _queue({call: call, errorHash: errorHash});
    }

    /// @notice Make one final qualified attempt, refunding only after the same matching error is reproduced.
    function finalizePendingCall(
        bytes32 id,
        string calldata memo,
        bytes calldata metadata
    )
        external
        override
        returns (bool wasRefunded, uint256 beneficiaryTokenCount)
    {
        JBPendingRouterTerminalCall memory call = _requirePendingCall({id: id, memo: memo, metadata: metadata});
        JBPendingRouterTerminalCallFailure memory failure = _pendingCallFailureOf[id];

        if (failure.count < FINALIZATION_FAILURE_COUNT) {
            revert JBRouterTerminalGateway_PendingCallNotFinalizable({id: id, failureCount: failure.count});
        }
        _requireReady({id: id, lastFailureAt: failure.lastFailureAt});

        delete _pendingCallOf[id];

        (bool success, bytes32 errorHash, uint256 count) =
            _attempt({call: call, memo: memo, metadata: metadata, gasLimit: QUALIFIED_CALL_GAS});

        if (success) {
            delete _pendingCallFailureOf[id];
            emit JBRouterTerminalGateway_ProcessPendingCall({
                id: id, call: call, beneficiaryTokenCount: count, caller: msg.sender
            });
            return (false, count);
        }

        if (errorHash != failure.errorHash) {
            _pendingCallOf[id] = call;
            _recordFailure({id: id, errorHash: errorHash, previous: failure});
            return (false, 0);
        }

        delete _pendingCallFailureOf[id];
        _refund(call);

        emit JBRouterTerminalGateway_RefundPendingCall({id: id, call: call, caller: msg.sender});
        return (true, 0);
    }

    /// @notice Empty implementation because the gateway only escrows retained calls, not project balances.
    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256 balance) {
        return 0;
    }

    /// @notice Route a payment, retaining its original input if a zero-minimum atomic router call fails.
    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        override
        returns (uint256 beneficiaryTokenCount)
    {
        address refundTo = _resolveOriginalPayer(msg.sender);
        amount = _acceptFundsFor({token: token, amount: amount});
        uint256 sourceProjectId = _sourceProjectIdFrom(metadata);

        JBPendingRouterTerminalCall memory call = JBPendingRouterTerminalCall({
            amount: amount,
            beneficiary: beneficiary,
            callDataHash: keccak256(abi.encode(memo, metadata)),
            minReturnedTokens: minReturnedTokens,
            preferAddToBalance: false,
            projectId: projectId,
            refundTo: refundTo,
            refundToProject: sourceProjectId != 0 && _isTerminal(refundTo),
            shouldReturnHeldFees: false,
            sourceProjectId: sourceProjectId,
            token: token
        });

        (bool success, bytes32 errorHash, uint256 count) =
            _attempt({call: call, memo: memo, metadata: metadata, gasLimit: 0});
        if (success) return count;

        if (minReturnedTokens != 0) revert JBRouterTerminalGateway_RouteFailed(errorHash);
        _queue({call: call, errorHash: errorHash});
    }

    /// @notice Make a permissionless gas-qualified attempt to process a retained call.
    function processPendingCall(
        bytes32 id,
        string calldata memo,
        bytes calldata metadata
    )
        external
        override
        returns (uint256 beneficiaryTokenCount)
    {
        JBPendingRouterTerminalCall memory call = _requirePendingCall({id: id, memo: memo, metadata: metadata});
        JBPendingRouterTerminalCallFailure memory failure = _pendingCallFailureOf[id];

        if (failure.count >= FINALIZATION_FAILURE_COUNT) {
            revert JBRouterTerminalGateway_PendingCallRequiresFinalization(id);
        }
        if (failure.count != 0) _requireReady({id: id, lastFailureAt: failure.lastFailureAt});

        delete _pendingCallOf[id];

        (bool success, bytes32 errorHash, uint256 count) =
            _attempt({call: call, memo: memo, metadata: metadata, gasLimit: QUALIFIED_CALL_GAS});

        if (success) {
            delete _pendingCallFailureOf[id];
            emit JBRouterTerminalGateway_ProcessPendingCall({
                id: id, call: call, beneficiaryTokenCount: count, caller: msg.sender
            });
            return count;
        }

        _pendingCallOf[id] = call;
        _recordFailure({id: id, errorHash: errorHash, previous: failure});
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Delegate the accounting-context lookup to the immutable router.
    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        override
        returns (JBAccountingContext memory)
    {
        return ROUTER.accountingContextForTokenOf({projectId: projectId, token: token});
    }

    /// @notice Delegate the accounting-context lookup to the immutable router.
    function accountingContextsOf(uint256 projectId) external view override returns (JBAccountingContext[] memory) {
        return ROUTER.accountingContextsOf(projectId);
    }

    /// @notice Delegate the surplus lookup to the immutable router.
    function currentSurplusOf(
        uint256 projectId,
        address[] calldata tokens,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        override
        returns (uint256)
    {
        return ROUTER.currentSurplusOf({projectId: projectId, tokens: tokens, decimals: decimals, currency: currency});
    }

    /// @notice Delegate best-pool discovery to the immutable router.
    function discoverBestPool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        external
        view
        override
        returns (PoolInfo memory pool)
    {
        return ROUTER.discoverBestPool({normalizedTokenIn: normalizedTokenIn, normalizedTokenOut: normalizedTokenOut});
    }

    /// @notice Delegate V3 pool discovery to the immutable router.
    function discoverPool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        external
        view
        override
        returns (IUniswapV3Pool pool)
    {
        return ROUTER.discoverPool({normalizedTokenIn: normalizedTokenIn, normalizedTokenOut: normalizedTokenOut});
    }

    /// @notice Return a retained call's consecutive matching failure state.
    function pendingCallFailureOf(bytes32 id)
        external
        view
        override
        returns (JBPendingRouterTerminalCallFailure memory failure)
    {
        return _pendingCallFailureOf[id];
    }

    /// @notice Return a call retained after its atomic router attempt failed.
    function pendingCallOf(bytes32 id) external view override returns (JBPendingRouterTerminalCall memory call) {
        return _pendingCallOf[id];
    }

    /// @notice Delegate payment previewing to the immutable router.
    function previewPayFor(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        bytes calldata metadata
    )
        external
        view
        override
        returns (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        )
    {
        return ROUTER.previewPayFor({
            projectId: projectId, token: token, amount: amount, beneficiary: beneficiary, metadata: metadata
        });
    }

    /// @notice Return the immutable concrete router reached by this forwarding gateway.
    function terminalOf(uint256) external view override returns (IJBTerminal terminal) {
        return ROUTER;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates whether this gateway implements an interface.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool supported) {
        return interfaceId == type(IJBForwardingTerminal).interfaceId
            || interfaceId == type(IJBPayerTracker).interfaceId || interfaceId == type(IJBRouterTerminal).interfaceId
            || interfaceId == type(IJBRouterTerminalGateway).interfaceId || interfaceId == type(IJBTerminal).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Accept an input token from the gateway's caller.
    function _acceptFundsFor(address token, uint256 amount) internal returns (uint256 acceptedAmount) {
        if (token == JBConstants.NATIVE_TOKEN) return msg.value;
        if (msg.value != 0) revert JBRouterTerminalGateway_NoMsgValueAllowed(msg.value);

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom({from: msg.sender, to: address(this), value: amount});
        return IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    /// @notice Attempt a retained call atomically against the immutable router.
    function _attempt(
        JBPendingRouterTerminalCall memory call,
        string calldata memo,
        bytes calldata metadata,
        uint256 gasLimit
    )
        internal
        returns (bool success, bytes32 errorHash, uint256 beneficiaryTokenCount)
    {
        bytes memory routerCall;
        if (call.preferAddToBalance) {
            routerCall = abi.encodeCall(
                IJBTerminal.addToBalanceOf,
                (call.projectId, call.token, call.amount, call.shouldReturnHeldFees, memo, metadata)
            );
        } else {
            routerCall = abi.encodeCall(
                IJBTerminal.pay,
                (call.projectId, call.token, call.amount, call.beneficiary, call.minReturnedTokens, memo, metadata)
            );
        }

        uint256 value;
        if (call.token == JBConstants.NATIVE_TOKEN) {
            value = call.amount;
        } else {
            IERC20(call.token).forceApprove({spender: address(ROUTER), value: call.amount});
        }

        if (gasLimit == 0) {
            uint256 available = gasleft();
            if (available > _FAILURE_GAS_RESERVE) gasLimit = available - _FAILURE_GAS_RESERVE;
        } else {
            _requireRetryGas(gasLimit);
        }

        address previousPayer = originalPayer;
        originalPayer = call.refundTo;

        (success, errorHash, beneficiaryTokenCount) =
            _boundedCall({target: address(ROUTER), value: value, gasLimit: gasLimit, data: routerCall});

        originalPayer = previousPayer;
        if (call.token != JBConstants.NATIVE_TOKEN) {
            IERC20(call.token).forceApprove({spender: address(ROUTER), value: 0});
        }
    }

    /// @notice Queue a failed call while retaining its original input token.
    function _queue(JBPendingRouterTerminalCall memory call, bytes32 errorHash) internal {
        bytes32 id = bytes32(++pendingCallCount);
        _pendingCallOf[id] = call;

        emit JBRouterTerminalGateway_QueuePendingCall({id: id, call: call, errorHash: errorHash, caller: msg.sender});
    }

    /// @notice Record a qualified failure, resetting the streak whenever the fingerprint changes.
    function _recordFailure(
        bytes32 id,
        bytes32 errorHash,
        JBPendingRouterTerminalCallFailure memory previous
    )
        internal
    {
        uint32 count = errorHash == previous.errorHash ? previous.count + 1 : 1;
        // forge-lint: disable-next-line(block-timestamp)
        uint48 failedAt = uint48(block.timestamp);

        _pendingCallFailureOf[id] =
            JBPendingRouterTerminalCallFailure({count: count, errorHash: errorHash, lastFailureAt: failedAt});

        emit JBRouterTerminalGateway_RecordTerminalCallFailure({
            id: id,
            errorHash: errorHash,
            count: count,
            nextAttemptAt: uint256(failedAt) + RETRY_DELAY,
            caller: msg.sender
        });
    }

    /// @notice Refund a finalized call in its original input token.
    function _refund(JBPendingRouterTerminalCall memory call) internal {
        if (!call.refundToProject) {
            if (call.token == JBConstants.NATIVE_TOKEN) {
                Address.sendValue(payable(call.refundTo), call.amount);
            } else {
                IERC20(call.token).safeTransfer({to: call.refundTo, value: call.amount});
            }
            return;
        }

        uint256 value;
        if (call.token == JBConstants.NATIVE_TOKEN) {
            value = call.amount;
        } else {
            IERC20(call.token).forceApprove({spender: call.refundTo, value: call.amount});
        }

        IJBTerminal(call.refundTo).addToBalanceOf{value: value}({
            projectId: call.sourceProjectId,
            token: call.token,
            amount: call.amount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: ""
        });

        if (call.token != JBConstants.NATIVE_TOKEN) {
            IERC20(call.token).forceApprove({spender: call.refundTo, value: 0});
        }
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Call the router while hashing only bounded return data so a reverting sink cannot bomb the catch path.
    /// @dev The fingerprint hashes the full return-data length and its first 256 bytes. Standard Solidity errors are
    /// matched exactly; oversized adversarial errors are matched by this bounded canonical representation.
    function _boundedCall(
        address target,
        uint256 value,
        uint256 gasLimit,
        bytes memory data
    )
        internal
        returns (bool success, bytes32 errorHash, uint256 result)
    {
        uint256 maxErrorDataLength = _MAX_ERROR_DATA_LENGTH;

        assembly ("memory-safe") {
            let ptr := mload(0x40)
            success := call(gasLimit, target, value, add(data, 0x20), mload(data), ptr, 0x20)

            let size := returndatasize()
            if and(success, gt(size, 0x1f)) { result := mload(ptr) }

            let copySize := size
            if gt(copySize, maxErrorDataLength) { copySize := maxErrorDataLength }

            mstore(ptr, size)
            returndatacopy(add(ptr, 0x20), 0, copySize)
            errorHash := keccak256(ptr, add(copySize, 0x20))
            mstore(0x40, add(add(ptr, 0x20), maxErrorDataLength))
        }
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Test whether an address identifies itself as a Juicebox terminal.
    function _isTerminal(address account) internal view returns (bool) {
        if (account.code.length == 0) return false;
        (bool success, bytes memory data) =
            account.staticcall{gas: 30_000}(abi.encodeCall(IERC165.supportsInterface, (type(IJBTerminal).interfaceId)));
        return success && data.length >= 32 && abi.decode(data, (bool));
    }

    /// @notice Require a pending call and verify its original memo and metadata.
    function _requirePendingCall(
        bytes32 id,
        string calldata memo,
        bytes calldata metadata
    )
        internal
        view
        returns (JBPendingRouterTerminalCall memory call)
    {
        call = _pendingCallOf[id];
        if (call.refundTo == address(0)) revert JBRouterTerminalGateway_PendingCallNotFound(id);

        bytes32 actualHash = keccak256(abi.encode(memo, metadata));
        if (actualHash != call.callDataHash) {
            revert JBRouterTerminalGateway_CallDataMismatch({expectedHash: call.callDataHash, actualHash: actualHash});
        }
    }

    /// @notice Require the retry delay to have elapsed.
    function _requireReady(bytes32 id, uint48 lastFailureAt) internal view {
        uint256 nextAttemptAt = uint256(lastFailureAt) + RETRY_DELAY;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < nextAttemptAt) {
            revert JBRouterTerminalGateway_PendingCallNotReady({id: id, nextAttemptAt: nextAttemptAt});
        }
    }

    /// @notice Require enough gas to forward a qualified attempt while retaining the failure-accounting reserve.
    function _requireRetryGas(uint256 gasLimit) internal view {
        uint256 available = gasleft();
        uint256 required = gasLimit + _FAILURE_GAS_RESERVE;
        if (available < required) {
            revert JBRouterTerminalGateway_InsufficientRetryGas({available: available, required: required});
        }
    }

    /// @notice Resolve an upstream payer exposed by a forwarding caller.
    function _resolveOriginalPayer(address fallback_) internal view returns (address payer) {
        if (msg.sender.code.length != 0) {
            try IJBPayerTracker(msg.sender).originalPayer() returns (address original) {
                if (original != address(0)) return original;
            } catch {}
        }
        return fallback_;
    }

    /// @notice Decode the raw source-project metadata used by core terminal fees and project payouts.
    function _sourceProjectIdFrom(bytes calldata metadata) internal pure returns (uint256 sourceProjectId) {
        if (metadata.length != 32) return 0;
        assembly ("memory-safe") {
            sourceProjectId := calldataload(metadata.offset)
        }
    }
}
