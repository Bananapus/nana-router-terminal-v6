// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

    /// @notice Thrown when a qualified attempt consumes its entire forwarded budget without returning an error.
    error JBRouterTerminalGateway_GasExhausted(uint256 gasLimit);

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

    /// @notice Thrown when neither the original nor current primary terminal accepts a project refund.
    error JBRouterTerminalGateway_RefundFailed(address originalTerminal, address primaryTerminal);

    /// @notice Thrown when a callback-capable token re-enters the inbound balance-delta measurement.
    error JBRouterTerminalGateway_ReentrantTokenTransfer(address token);

    /// @notice Thrown when a caller-specified qualified gas limit is below the protocol minimum.
    error JBRouterTerminalGateway_RetryGasLimitTooLow(uint256 gasLimit, uint256 minimum);

    /// @notice Thrown when a call which is not eligible for retention cannot be settled synchronously.
    error JBRouterTerminalGateway_RouteFailed(bytes32 errorHash);

    /// @notice Thrown when the immutable directory or router is the zero address.
    error JBRouterTerminalGateway_ZeroAddress();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The number of matching, time-separated qualified failures required before finalization.
    uint256 public constant override FINALIZATION_FAILURE_COUNT = 3;

    /// @notice The default and minimum gas forwarded by a qualified retry or final attempt.
    uint256 public constant override QUALIFIED_CALL_GAS = 5_000_000;

    /// @notice The minimum delay between qualified failures and before finalization.
    uint256 public constant override RETRY_DELAY = 1 days;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice Gas retained around an attempted route for cleanup and durable failure accounting.
    uint256 internal constant _FAILURE_GAS_RESERVE = 750_000;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The immutable directory used to resolve a source project's current accounting terminal for refunds.
    IJBDirectory public immutable override DIRECTORY;

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

    /// @notice Whether an ERC-20 transfer is inside its inbound balance-delta measurement.
    bool internal transient _acceptingToken;

    /// @notice The original payer propagated into the downstream router during an active attempt.
    address public transient override originalPayer;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The immutable directory used to resolve project accounting terminals.
    /// @param router The immutable router terminal to call atomically.
    constructor(IJBDirectory directory, IJBRouterTerminal router) {
        if (address(directory) == address(0) || address(router) == address(0)) {
            revert JBRouterTerminalGateway_ZeroAddress();
        }
        DIRECTORY = directory;
        ROUTER = router;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Empty implementation because accounting contexts are delegated to `ROUTER`.
    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    /// @notice Route an add-to-balance call, retaining failed input only for a shape-qualified project refund.
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

        (bool success, bytes32 errorHash,,) = _attempt({call: call, memo: memo, metadata: metadata, gasLimit: 0});
        if (success) return;

        // Ordinary callers retain synchronous failure semantics; only shape-qualified project refunds enter escrow.
        if (!call.refundToProject) revert JBRouterTerminalGateway_RouteFailed(errorHash);
        _queue({call: call, errorHash: errorHash});
    }

    /// @notice Make one final qualified attempt, refunding only after the same error selector is reproduced.
    function finalizePendingCall(
        bytes32 id,
        string calldata memo,
        bytes calldata metadata
    )
        external
        override
        returns (bool wasRefunded, uint256 beneficiaryTokenCount)
    {
        return _finalizePendingCall({id: id, gasLimit: QUALIFIED_CALL_GAS, memo: memo, metadata: metadata});
    }

    /// @notice Make one final qualified attempt with an expanded gas budget.
    function finalizePendingCallWithGas(
        bytes32 id,
        uint256 gasLimit,
        string calldata memo,
        bytes calldata metadata
    )
        external
        override
        returns (bool wasRefunded, uint256 beneficiaryTokenCount)
    {
        return _finalizePendingCall({id: id, gasLimit: gasLimit, memo: memo, metadata: metadata});
    }

    /// @notice Empty implementation because the gateway only escrows retained calls, not project balances.
    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256 balance) {
        return 0;
    }

    /// @notice Route a payment, retaining failed zero-minimum input only for a shape-qualified project refund.
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

        (bool success, bytes32 errorHash, uint256 count,) =
            _attempt({call: call, memo: memo, metadata: metadata, gasLimit: 0});
        if (success) return count;

        // Preserve minimums and ordinary caller semantics instead of turning user payments into asynchronous custody.
        if (minReturnedTokens != 0 || !call.refundToProject) {
            revert JBRouterTerminalGateway_RouteFailed(errorHash);
        }
        _queue({call: call, errorHash: errorHash});
    }

    /// @notice Make a permissionless attempt using the default qualified gas budget.
    function processPendingCall(
        bytes32 id,
        string calldata memo,
        bytes calldata metadata
    )
        external
        override
        returns (uint256 beneficiaryTokenCount)
    {
        return _processPendingCall({id: id, gasLimit: QUALIFIED_CALL_GAS, memo: memo, metadata: metadata});
    }

    /// @notice Make a permissionless attempt with an expanded qualified gas budget.
    function processPendingCallWithGas(
        bytes32 id,
        uint256 gasLimit,
        string calldata memo,
        bytes calldata metadata
    )
        external
        override
        returns (uint256 beneficiaryTokenCount)
    {
        return _processPendingCall({id: id, gasLimit: gasLimit, memo: memo, metadata: metadata});
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

        // Snapshot the balance so fee-on-transfer inputs use the amount which actually arrives.
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // Keep callback-capable tokens from nesting another intake inside this balance-delta measurement.
        if (_acceptingToken) revert JBRouterTerminalGateway_ReentrantTokenTransfer(token);
        _acceptingToken = true;

        // Pull the input only after closing the reentrant measurement window.
        IERC20(token).safeTransferFrom({from: msg.sender, to: address(this), value: amount});
        acceptedAmount = IERC20(token).balanceOf(address(this)) - balanceBefore;

        // Re-open intake after the post-transfer balance has fixed this call's accepted amount.
        _acceptingToken = false;
    }

    /// @notice Attempt a retained call atomically against the immutable router.
    function _attempt(
        JBPendingRouterTerminalCall memory call,
        string calldata memo,
        bytes calldata metadata,
        uint256 gasLimit
    )
        internal
        returns (bool success, bytes32 errorHash, uint256 beneficiaryTokenCount, bool gasExhausted)
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

        uint256 previousAllowance;
        uint256 value;
        if (call.token == JBConstants.NATIVE_TOKEN) {
            value = call.amount;
        } else {
            // Preserve an enclosing same-token attempt's allowance across legitimate nested forwarding hooks.
            previousAllowance = IERC20(call.token).allowance({owner: address(this), spender: address(ROUTER)});
            IERC20(call.token).forceApprove({spender: address(ROUTER), value: call.amount});
        }

        if (gasLimit == 0) {
            uint256 available = gasleft();
            // A zero-gas attempt keeps an underfunded retention-qualified call inside the custody boundary; ordinary
            // callers still revert below instead of entering escrow.
            if (available > _FAILURE_GAS_RESERVE) gasLimit = available - _FAILURE_GAS_RESERVE;
        } else {
            if (gasLimit < QUALIFIED_CALL_GAS) {
                revert JBRouterTerminalGateway_RetryGasLimitTooLow({gasLimit: gasLimit, minimum: QUALIFIED_CALL_GAS});
            }
            _requireRetryGas(gasLimit);
        }

        address previousPayer = originalPayer;
        originalPayer = call.refundTo;

        (success, errorHash, beneficiaryTokenCount, gasExhausted) =
            _boundedCall({target: address(ROUTER), value: value, gasLimit: gasLimit, data: routerCall});

        originalPayer = previousPayer;
        if (call.token != JBConstants.NATIVE_TOKEN) {
            // Restore rather than clear so a nested route cannot clobber its enclosing Router pull.
            IERC20(call.token).forceApprove({spender: address(ROUTER), value: previousAllowance});
        }
    }

    /// @notice Finalize a retained call using a caller-selected qualified gas budget.
    function _finalizePendingCall(
        bytes32 id,
        uint256 gasLimit,
        string calldata memo,
        bytes calldata metadata
    )
        internal
        returns (bool wasRefunded, uint256 beneficiaryTokenCount)
    {
        JBPendingRouterTerminalCall memory call = _requirePendingCall({id: id, memo: memo, metadata: metadata});
        JBPendingRouterTerminalCallFailure memory failure = _pendingCallFailureOf[id];

        if (failure.count < FINALIZATION_FAILURE_COUNT) {
            revert JBRouterTerminalGateway_PendingCallNotFinalizable({id: id, failureCount: failure.count});
        }
        _requireReady({id: id, lastFailureAt: failure.lastFailureAt});

        delete _pendingCallOf[id];

        (bool success, bytes32 errorHash, uint256 count, bool gasExhausted) =
            _attempt({call: call, memo: memo, metadata: metadata, gasLimit: gasLimit});

        if (success) {
            delete _pendingCallFailureOf[id];
            emit JBRouterTerminalGateway_ProcessPendingCall({
                id: id, call: call, beneficiaryTokenCount: count, caller: msg.sender
            });
            return (false, count);
        }

        // A budget-exhausted attempt proves only that this retry limit was inadequate, not that the route is broken.
        if (gasExhausted) revert JBRouterTerminalGateway_GasExhausted(gasLimit);

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

    /// @notice Process a retained call using a caller-selected qualified gas budget.
    function _processPendingCall(
        bytes32 id,
        uint256 gasLimit,
        string calldata memo,
        bytes calldata metadata
    )
        internal
        returns (uint256 beneficiaryTokenCount)
    {
        JBPendingRouterTerminalCall memory call = _requirePendingCall({id: id, memo: memo, metadata: metadata});
        JBPendingRouterTerminalCallFailure memory failure = _pendingCallFailureOf[id];

        if (failure.count >= FINALIZATION_FAILURE_COUNT) {
            revert JBRouterTerminalGateway_PendingCallRequiresFinalization(id);
        }
        if (failure.count != 0) _requireReady({id: id, lastFailureAt: failure.lastFailureAt});

        delete _pendingCallOf[id];

        (bool success, bytes32 errorHash, uint256 count, bool gasExhausted) =
            _attempt({call: call, memo: memo, metadata: metadata, gasLimit: gasLimit});

        if (success) {
            delete _pendingCallFailureOf[id];
            emit JBRouterTerminalGateway_ProcessPendingCall({
                id: id, call: call, beneficiaryTokenCount: count, caller: msg.sender
            });
            return count;
        }

        // Do not let a caller turn an inadequate retry budget into evidence that the downstream route is broken.
        if (gasExhausted) revert JBRouterTerminalGateway_GasExhausted(gasLimit);

        _pendingCallOf[id] = call;
        _recordFailure({id: id, errorHash: errorHash, previous: failure});
    }

    /// @notice Queue a failed call while retaining its original input token.
    function _queue(JBPendingRouterTerminalCall memory call, bytes32 errorHash) internal {
        bytes32 id = bytes32(++pendingCallCount);
        _pendingCallOf[id] = call;

        emit JBRouterTerminalGateway_QueuePendingCall({id: id, call: call, errorHash: errorHash, caller: msg.sender});
    }

    /// @notice Record a qualified failure, resetting the streak whenever the error selector changes.
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

    /// @notice Refund a finalized call through an active source-project accounting terminal.
    function _refund(JBPendingRouterTerminalCall memory call) internal {
        IJBTerminal originalTerminal = IJBTerminal(call.refundTo);

        // Prefer the source terminal while it remains registered for the project, preserving the original destination.
        if (
            DIRECTORY.isTerminalOf({projectId: call.sourceProjectId, terminal: originalTerminal})
                && _tryRefund({call: call, terminal: originalTerminal})
        ) {
            return;
        }

        // If that terminal was removed or rejects the token, use the project's current token-specific primary terminal.
        IJBTerminal primaryTerminal = DIRECTORY.primaryTerminalOf({projectId: call.sourceProjectId, token: call.token});
        if (
            address(primaryTerminal) != address(0) && primaryTerminal != originalTerminal
                && _tryRefund({call: call, terminal: primaryTerminal})
        ) {
            return;
        }

        revert JBRouterTerminalGateway_RefundFailed({
            originalTerminal: address(originalTerminal), primaryTerminal: address(primaryTerminal)
        });
    }

    /// @notice Attempt a project-accounting refund without letting one terminal block an alternate terminal.
    function _tryRefund(JBPendingRouterTerminalCall memory call, IJBTerminal terminal) internal returns (bool success) {
        uint256 value;
        if (call.token == JBConstants.NATIVE_TOKEN) {
            value = call.amount;
        } else {
            IERC20(call.token).forceApprove({spender: address(terminal), value: call.amount});
        }

        (success,) = address(terminal).call{value: value}(
            abi.encodeCall(
                IJBTerminal.addToBalanceOf,
                (call.sourceProjectId, call.token, call.amount, false, string(""), bytes(""))
            )
        );

        // Always close the exact approval before trying another terminal or returning.
        if (call.token != JBConstants.NATIVE_TOKEN) {
            IERC20(call.token).forceApprove({spender: address(terminal), value: 0});
        }
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Call the router while matching failures by selector without copying encoded error arguments.
    /// @dev Empty and short return data are hashed as-is. Return data at least four bytes long is matched by selector.
    function _boundedCall(
        address target,
        uint256 value,
        uint256 gasLimit,
        bytes memory data
    )
        internal
        returns (bool success, bytes32 errorHash, uint256 result, bool gasExhausted)
    {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            let gasBefore := gas()
            success := call(gasLimit, target, value, add(data, 0x20), mload(data), ptr, 0x20)
            let gasSpent := sub(gasBefore, gas())

            let size := returndatasize()
            if and(success, gt(size, 0x1f)) { result := mload(ptr) }

            // A failed call with no error data which consumed its complete budget is an unqualified gas exhaustion.
            gasExhausted := and(iszero(success), and(iszero(size), iszero(lt(gasSpent, gasLimit))))

            let copySize := size
            if gt(copySize, 4) { copySize := 4 }

            returndatacopy(ptr, 0, copySize)
            errorHash := keccak256(ptr, copySize)
            mstore(0x40, add(ptr, 0x20))
        }
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Test whether an address identifies itself as a Juicebox terminal through ERC-165.
    /// @dev This is a shape check, not authentication. Any contract can self-assert interface support.
    function _isTerminal(address account) internal view returns (bool) {
        if (account.code.length == 0) return false;
        (bool success, bytes memory data) =
            account.staticcall{gas: 30_000}(abi.encodeCall(IERC165.supportsInterface, (type(IJBTerminal).interfaceId)));
        if (!success || data.length < 32) return false;

        // Require the canonical ABI encoding without letting a malformed boolean revert the enclosing payment.
        uint256 supported;
        assembly ("memory-safe") {
            supported := mload(add(data, 0x20))
        }
        return supported == 1;
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
        // Include the EIP-150 withholding margin so the requested amount is actually forwarded by `CALL`.
        uint256 required = gasLimit + gasLimit / 63 + _FAILURE_GAS_RESERVE;
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
