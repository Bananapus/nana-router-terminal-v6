// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";
import {IJBPermitTerminal} from "@bananapus/core-v6/src/interfaces/IJBPermitTerminal.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {IJBForwardingTerminal} from "./interfaces/IJBForwardingTerminal.sol";
import {IJBRouterTerminal} from "./interfaces/IJBRouterTerminal.sol";
import {IJBRouterTerminalGateway} from "./interfaces/IJBRouterTerminalGateway.sol";

import {JBForwardingCheck} from "./libraries/JBForwardingCheck.sol";

import {JBPendingRouterTerminalCall} from "./structs/JBPendingRouterTerminalCall.sol";
import {JBPendingRouterTerminalCallFailure} from "./structs/JBPendingRouterTerminalCallFailure.sol";
import {PoolInfo} from "./structs/PoolInfo.sol";

/// @notice A router-terminal gateway which retains an original input token when the fallible routing call fails.
/// @dev The registry points to this contract, which forwards atomically into an immutable `JBRouterTerminal`.
contract JBRouterTerminalGateway is ERC2771Context, IJBRouterTerminalGateway {
    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when an amount exceeds the maximum width Permit2 can transfer.
    error JBRouterTerminalGateway_AmountOverflow(uint256 amount);

    /// @notice Thrown when the live block gas limit cannot support the minimum qualified call budget.
    error JBRouterTerminalGateway_BlockGasLimitTooLow(uint256 maximum, uint256 minimum);

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

    /// @notice Thrown when the payment amount exceeds the Permit2 allowance provided in metadata.
    error JBRouterTerminalGateway_PermitAllowanceNotEnough(uint256 amount, uint256 allowance);

    /// @notice Thrown when a callback-capable token re-enters the inbound balance-delta measurement.
    error JBRouterTerminalGateway_ReentrantTokenTransfer(address token);

    /// @notice Thrown when no non-circular registered source-project terminal accepts a refund.
    error JBRouterTerminalGateway_RefundFailed(address originalTerminal, address primaryTerminal);

    /// @notice Thrown when a caller-specified gas limit exceeds the live chain's executable budget.
    error JBRouterTerminalGateway_RetryGasLimitTooHigh(uint256 gasLimit, uint256 maximum);

    /// @notice Thrown when a caller-specified gas limit is below the budget required by the failure state.
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

    /// @notice The base and minimum gas forwarded by a qualified retry or final attempt.
    uint256 public constant override QUALIFIED_CALL_GAS = 5_000_000;

    /// @notice The minimum delay between qualified failures and before finalization.
    uint256 public constant override RETRY_DELAY = 1 days;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice Gas retained around an attempted route for cleanup and durable failure accounting.
    uint256 internal constant _FAILURE_GAS_RESERVE = 750_000;

    /// @notice The stable fingerprint used when an attempt consumes its complete forwarded gas budget.
    bytes32 internal constant _GAS_EXHAUSTED_ERROR_HASH = keccak256("JBRouterTerminalGateway: gas exhausted");

    /// @notice Block gas retained for transaction overhead, EIP-150 withholding, and durable failure accounting.
    uint256 internal constant _TRANSACTION_GAS_RESERVE = 1_500_000;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The immutable directory used to resolve a source project's current accounting terminal for refunds.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The Permit2 contract used for gasless ERC-20 approvals and transfers.
    IPermit2 public immutable override PERMIT2;

    /// @notice The immutable router terminal this gateway calls atomically.
    IJBRouterTerminal public immutable override ROUTER;

    //*********************************************************************//
    // -------------- internal immutable stored properties -------------- //
    //*********************************************************************//

    /// @notice Pre-computed metadata ID for `permit2` allowances addressed to this gateway.
    bytes4 internal immutable _PERMIT2_ID;

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
    /// @param permit2 The Permit2 singleton used for gasless ERC-20 approvals and transfers.
    /// @param router The immutable router terminal to call atomically.
    /// @param trustedForwarder The trusted ERC-2771 forwarder used by the surrounding protocol.
    constructor(
        IJBDirectory directory,
        IPermit2 permit2,
        IJBRouterTerminal router,
        address trustedForwarder
    )
        ERC2771Context(trustedForwarder)
    {
        if (address(directory) == address(0) || address(router) == address(0)) {
            revert JBRouterTerminalGateway_ZeroAddress();
        }
        // Refuse an installation whose chain cannot execute even the base recovery attempt.
        uint256 maximumGasLimit = _maximumQualifiedCallGas(block.gaslimit);
        if (maximumGasLimit < QUALIFIED_CALL_GAS) {
            revert JBRouterTerminalGateway_BlockGasLimitTooLow({maximum: maximumGasLimit, minimum: QUALIFIED_CALL_GAS});
        }
        DIRECTORY = directory;
        PERMIT2 = permit2;
        ROUTER = router;
        _PERMIT2_ID = JBMetadataResolver.getId("permit2");
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
        address refundTo = _resolveOriginalPayer(_msgSender());
        amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});
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

    /// @notice Make one final qualified attempt, refunding only after the same failure class is reproduced.
    function finalizePendingCall(
        bytes32 id,
        string calldata memo,
        bytes calldata metadata
    )
        external
        override
        returns (bool wasRefunded, uint256 beneficiaryTokenCount)
    {
        return _finalizePendingCall({id: id, gasLimit: 0, memo: memo, metadata: metadata});
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
        address refundTo = _resolveOriginalPayer(_msgSender());
        amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});
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
        return _processPendingCall({id: id, gasLimit: 0, memo: memo, metadata: metadata});
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

    /// @notice Return the largest qualified call budget executable under the live chain's block gas limit.
    /// @return gasLimit The maximum gas which may be forwarded while preserving accounting reserves.
    function maximumQualifiedCallGas() public view override returns (uint256 gasLimit) {
        return _maximumQualifiedCallGas(block.gaslimit);
    }

    /// @notice Indicates whether this gateway implements an interface.
    /// @param interfaceId The interface identifier to test.
    /// @return supported Whether the gateway implements `interfaceId`.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool supported) {
        return interfaceId == type(IJBForwardingTerminal).interfaceId
            || interfaceId == type(IJBPayerTracker).interfaceId || interfaceId == type(IJBPermitTerminal).interfaceId
            || interfaceId == type(IJBRouterTerminal).interfaceId
            || interfaceId == type(IJBRouterTerminalGateway).interfaceId || interfaceId == type(IJBTerminal).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Accept an input token from the gateway's resolved ERC-2771 caller.
    /// @param token The token to accept, or the native-token sentinel.
    /// @param amount The maximum token amount to pull from the caller.
    /// @param metadata Metadata which may contain a Permit2 allowance addressed to this gateway.
    /// @return acceptedAmount The amount which actually arrived after the transfer.
    function _acceptFundsFor(
        address token,
        uint256 amount,
        bytes calldata metadata
    )
        internal
        returns (uint256 acceptedAmount)
    {
        if (token == JBConstants.NATIVE_TOKEN) return msg.value;
        if (msg.value != 0) revert JBRouterTerminalGateway_NoMsgValueAllowed(msg.value);

        address sender = _msgSender();
        (bool exists, bytes memory parsedMetadata) =
            JBMetadataResolver.getDataFor({id: _PERMIT2_ID, metadata: metadata});
        if (exists) {
            JBSingleAllowance memory allowance = abi.decode(parsedMetadata, (JBSingleAllowance));
            if (amount > allowance.amount) {
                revert JBRouterTerminalGateway_PermitAllowanceNotEnough({amount: amount, allowance: allowance.amount});
            }

            IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
                details: IAllowanceTransfer.PermitDetails({
                    token: token, amount: allowance.amount, expiration: allowance.expiration, nonce: allowance.nonce
                }),
                spender: address(this),
                sigDeadline: allowance.sigDeadline
            });

            try PERMIT2.permit({owner: sender, permitSingle: permitSingle, signature: allowance.signature}) {}
            catch (bytes memory reason) {
                emit Permit2AllowanceFailed({token: token, owner: sender, reason: reason, caller: sender});
            }
        }

        // Snapshot the balance so fee-on-transfer inputs use the amount which actually arrives.
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // Keep callback-capable tokens from nesting another intake inside this balance-delta measurement.
        if (_acceptingToken) revert JBRouterTerminalGateway_ReentrantTokenTransfer(token);
        _acceptingToken = true;

        // Pull the input only after closing the reentrant measurement window.
        _transferFrom({from: sender, to: address(this), token: token, amount: amount});
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
        gasLimit = _qualifiedGasLimit({failure: failure, requestedGasLimit: gasLimit});

        delete _pendingCallOf[id];

        (bool success, bytes32 errorHash, uint256 count, bool gasExhausted) =
            _attempt({call: call, memo: memo, metadata: metadata, gasLimit: gasLimit});

        if (success) {
            delete _pendingCallFailureOf[id];
            emit JBRouterTerminalGateway_ProcessPendingCall({
                id: id, call: call, beneficiaryTokenCount: count, caller: _msgSender()
            });
            return (false, count);
        }

        // Gas exhaustion is its own stable failure class, so each matching retry must use a larger budget.
        if (gasExhausted) errorHash = _GAS_EXHAUSTED_ERROR_HASH;

        if (errorHash != failure.errorHash) {
            _pendingCallOf[id] = call;
            _recordFailure({id: id, errorHash: errorHash, previous: failure});
            return (false, 0);
        }

        delete _pendingCallFailureOf[id];
        _refund(call);

        emit JBRouterTerminalGateway_RefundPendingCall({id: id, call: call, caller: _msgSender()});
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
        gasLimit = _qualifiedGasLimit({failure: failure, requestedGasLimit: gasLimit});

        delete _pendingCallOf[id];

        (bool success, bytes32 errorHash, uint256 count, bool gasExhausted) =
            _attempt({call: call, memo: memo, metadata: metadata, gasLimit: gasLimit});

        if (success) {
            delete _pendingCallFailureOf[id];
            emit JBRouterTerminalGateway_ProcessPendingCall({
                id: id, call: call, beneficiaryTokenCount: count, caller: _msgSender()
            });
            return count;
        }

        // Gas exhaustion advances only after the failure state has enforced the next larger budget.
        if (gasExhausted) errorHash = _GAS_EXHAUSTED_ERROR_HASH;

        _pendingCallOf[id] = call;
        _recordFailure({id: id, errorHash: errorHash, previous: failure});
    }

    /// @notice Queue a failed call while retaining its original input token.
    function _queue(JBPendingRouterTerminalCall memory call, bytes32 errorHash) internal {
        bytes32 id = bytes32(++pendingCallCount);
        _pendingCallOf[id] = call;

        emit JBRouterTerminalGateway_QueuePendingCall({id: id, call: call, errorHash: errorHash, caller: _msgSender()});
    }

    /// @notice Record a qualified failure, resetting the streak whenever the failure class changes.
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
            caller: _msgSender()
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

        // Search the remaining registered terminals so a circular or stale primary cannot permanently trap custody.
        IJBTerminal[] memory terminals = DIRECTORY.terminalsOf(call.sourceProjectId);
        for (uint256 i; i < terminals.length; i++) {
            IJBTerminal terminal = terminals[i];
            if (terminal == originalTerminal || terminal == primaryTerminal) continue;
            if (_tryRefund({call: call, terminal: terminal})) return;
        }

        revert JBRouterTerminalGateway_RefundFailed({
            originalTerminal: address(originalTerminal), primaryTerminal: address(primaryTerminal)
        });
    }

    /// @notice Pull an ERC-20 through direct approval when available, otherwise through Permit2.
    /// @param from The ERC-2771-resolved token owner.
    /// @param to The address which receives the token.
    /// @param token The ERC-20 token to transfer.
    /// @param amount The token amount to transfer.
    function _transferFrom(address from, address to, address token, uint256 amount) internal {
        if (IERC20(token).allowance({owner: from, spender: address(this)}) >= amount) {
            return IERC20(token).safeTransferFrom({from: from, to: to, value: amount});
        }

        if (amount > type(uint160).max) revert JBRouterTerminalGateway_AmountOverflow(amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        PERMIT2.transferFrom({from: from, to: to, amount: uint160(amount), token: token});
    }

    /// @notice Attempt a project-accounting refund without letting one terminal block an alternate terminal.
    /// @param call The retained call whose original input must be refunded.
    /// @param terminal The candidate source-project terminal to credit.
    /// @return success Whether the candidate accepted and accounted for the complete refund.
    function _tryRefund(JBPendingRouterTerminalCall memory call, IJBTerminal terminal) internal returns (bool success) {
        if (
            address(terminal) == address(0)
                || JBForwardingCheck.isCircularTerminal({
                    target: address(this), projectId: call.sourceProjectId, terminal: terminal
                })
        ) {
            return false;
        }

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

    /// @notice Derive the largest call budget which preserves the transaction's accounting reserves.
    /// @dev Applies the EIP-150 forwarding ratio after reserving gas for transaction overhead and failure accounting.
    /// @param blockGasLimit The block gas limit from which to derive an executable call budget.
    /// @return gasLimit The maximum call budget supported by `blockGasLimit`.
    function _maximumQualifiedCallGas(uint256 blockGasLimit) internal pure returns (uint256 gasLimit) {
        if (blockGasLimit <= _TRANSACTION_GAS_RESERVE) return 0;
        return (blockGasLimit - _TRANSACTION_GAS_RESERVE) * 63 / 64;
    }

    /// @notice Resolve the minimum escalating gas budget for a qualified attempt on the live chain.
    /// @dev Consecutive gas exhaustion targets 5M, 10M, 15M, then 20M gas, capped by the executable block budget.
    /// @param failure The pending call's current matching failure state.
    /// @param requestedGasLimit The explicit caller-selected budget, or zero to select the required minimum.
    /// @return gasLimit The validated gas budget to forward.
    function _qualifiedGasLimit(
        JBPendingRouterTerminalCallFailure memory failure,
        uint256 requestedGasLimit
    )
        internal
        view
        returns (uint256 gasLimit)
    {
        return _qualifiedGasLimitFor({
            failure: failure, requestedGasLimit: requestedGasLimit, maximumGasLimit: maximumQualifiedCallGas()
        });
    }

    /// @notice Resolve a qualified gas budget against a supplied executable maximum.
    /// @param failure The pending call's current matching failure state.
    /// @param requestedGasLimit The explicit caller-selected budget, or zero to select the required minimum.
    /// @param maximumGasLimit The maximum budget executable under the live block gas limit.
    /// @return gasLimit The validated gas budget to forward.
    function _qualifiedGasLimitFor(
        JBPendingRouterTerminalCallFailure memory failure,
        uint256 requestedGasLimit,
        uint256 maximumGasLimit
    )
        internal
        pure
        returns (uint256 gasLimit)
    {
        if (maximumGasLimit < QUALIFIED_CALL_GAS) {
            revert JBRouterTerminalGateway_BlockGasLimitTooLow({maximum: maximumGasLimit, minimum: QUALIFIED_CALL_GAS});
        }

        uint256 minimum = QUALIFIED_CALL_GAS;
        if (failure.errorHash == _GAS_EXHAUSTED_ERROR_HASH) minimum *= uint256(failure.count) + 1;
        if (minimum > maximumGasLimit) minimum = maximumGasLimit;

        if (requestedGasLimit == 0) return minimum;
        if (requestedGasLimit < minimum) {
            revert JBRouterTerminalGateway_RetryGasLimitTooLow({gasLimit: requestedGasLimit, minimum: minimum});
        }
        if (requestedGasLimit > maximumGasLimit) {
            revert JBRouterTerminalGateway_RetryGasLimitTooHigh({gasLimit: requestedGasLimit, maximum: maximumGasLimit});
        }
        return requestedGasLimit;
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
        uint256 required = gasLimit + (gasLimit + 62) / 63 + _FAILURE_GAS_RESERVE;
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
