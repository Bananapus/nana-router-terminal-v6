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

    /// @notice Thrown when a supplied call, memo, and metadata do not match a pending call's stored commitment.
    error JBRouterTerminalGateway_CallDataMismatch(bytes32 expectedCommitment, bytes32 actualCommitment);

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

    /// @notice The EIP-7825 per-transaction gas cap (2^24). No transaction can carry more gas than this even when the
    /// block gas limit is larger, so the retry ladder must stop here or its top rungs become unexecutable.
    uint256 internal constant _TRANSACTION_GAS_CAP = 16_777_216;

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

    /// @notice The hash commitment binding each retained call, its memo, and its metadata.
    /// @dev Only the commitment is stored so the gas-constrained queue path writes a single slot. Retriers supply the
    /// full call from the queue event and are authenticated against this hash.
    mapping(bytes32 id => bytes32) internal _pendingCallCommitmentOf;

    /// @notice Qualified failure state for each retained call.
    mapping(bytes32 id => JBPendingRouterTerminalCallFailure) internal _pendingCallFailureOf;

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
        // Both are load-bearing and unchangeable afterwards: without a router there is nothing to forward into, and
        // without a directory a retained call could never be refunded to its source project.
        if (address(directory) == address(0) || address(router) == address(0)) {
            revert JBRouterTerminalGateway_ZeroAddress();
        }

        // Refuse an installation whose chain cannot execute even the base recovery attempt. Custody would still be
        // takeable while every path out of it reverted.
        uint256 maximumGasLimit = _maximumQualifiedCallGas(block.gaslimit);
        if (maximumGasLimit < QUALIFIED_CALL_GAS) {
            revert JBRouterTerminalGateway_BlockGasLimitTooLow({maximum: maximumGasLimit, minimum: QUALIFIED_CALL_GAS});
        }

        DIRECTORY = directory;
        PERMIT2 = permit2;
        ROUTER = router;

        // Namespace the Permit2 metadata ID to this address so allowances signed for the Router or Registry are not
        // consumed here, and vice versa.
        _PERMIT2_ID = JBMetadataResolver.getId("permit2");
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Empty implementation because accounting contexts are delegated to `ROUTER`.
    /// @param projectId The ID of the project whose accounting contexts would otherwise be configured.
    /// @param accountingContexts Ignored because the immutable router derives accounting contexts at runtime.
    function addAccountingContextsFor(
        uint256 projectId,
        JBAccountingContext[] calldata accountingContexts
    )
        external
        override
    {}

    /// @notice Route an add-to-balance call, retaining failed input only when source-project metadata opts in.
    /// @dev The opt-in is metadata which is exactly 32 bytes encoding a nonzero raw source project ID. Calls without
    /// the opt-in revert synchronously when the routed attempt fails.
    /// @param projectId The ID of the destination project.
    /// @param token The address of the token to pay in.
    /// @param amount The amount of tokens to send.
    /// @param shouldReturnHeldFees Whether held fees should be returned based on the amount added.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes in `JBMetadataResolver`'s format, or exactly 32 bytes naming the source project.
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
        // Resolve the upstream payer before taking custody, because a forwarding caller only exposes it for the
        // duration of its own call. This address becomes the preferred refund terminal if the route never settles.
        address refundTo = _resolveOriginalPayer(_msgSender());

        // Take custody up front so a later Router failure rolls back to this token rather than to a swapped one. The
        // amount is re-measured from the balance delta, which is what a fee-on-transfer input actually delivered.
        amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});

        // Read the escrow opt-in. Zero means this caller never asked for custody and expects a synchronous revert.
        uint256 sourceProjectId = _sourceProjectIdFrom(metadata);

        JBPendingRouterTerminalCall memory call = JBPendingRouterTerminalCall({
            amount: amount,
            // Add-to-balance has no beneficiary; the destination project's balance is the sole recipient.
            beneficiary: address(0),
            preferAddToBalance: true,
            projectId: projectId,
            refundTo: refundTo,
            shouldReturnHeldFees: shouldReturnHeldFees,
            sourceProjectId: sourceProjectId,
            token: token
        });

        // Try the route inside this transaction first. Nothing is retained when it settles.
        (bool success, bytes32 errorHash,,) =
            _attempt({call: call, minReturnedTokens: 0, memo: memo, metadata: metadata, gasLimit: 0});
        if (success) return;

        // Calls without a usable source-project opt-in retain synchronous failure semantics.
        if (!_shouldRetain(call)) revert JBRouterTerminalGateway_RouteFailed(errorHash);

        // The opt-in was given, so absorb the failure instead of bubbling it into the caller's catch boundary. The
        // input stays in custody and recovery becomes permissionless.
        _queue({call: call, memo: memo, metadata: metadata, errorHash: errorHash});
    }

    /// @notice Make one final qualified attempt, refunding only after the same failure class is reproduced.
    /// @dev Callable permissionlessly once `FINALIZATION_FAILURE_COUNT` matching failures have accumulated and the
    /// retry delay has elapsed. A changed failure class resets the streak instead of refunding. The supplied call,
    /// memo, and metadata are read from the queue event and authenticated against the stored commitment.
    /// @param id The pending call identifier.
    /// @param call The retained call, as emitted when it was queued.
    /// @param memo The original memo bound by the pending call.
    /// @param metadata The original metadata bound by the pending call.
    /// @return wasRefunded Whether the retained input was refunded.
    /// @return beneficiaryTokenCount The project tokens returned if the final `pay` attempt succeeded.
    function finalizePendingCall(
        bytes32 id,
        JBPendingRouterTerminalCall calldata call,
        string calldata memo,
        bytes calldata metadata
    )
        external
        override
        returns (bool wasRefunded, uint256 beneficiaryTokenCount)
    {
        return _finalizePendingCall({id: id, call: call, gasLimit: 0, memo: memo, metadata: metadata});
    }

    /// @notice Make one final qualified attempt with an expanded gas budget.
    /// @dev Behaves like `finalizePendingCall` but forwards a caller-selected budget, which must satisfy the pending
    /// call's escalating minimum and fit under the live chain's executable transaction budget.
    /// @param id The pending call identifier.
    /// @param call The retained call, as emitted when it was queued.
    /// @param gasLimit The gas to forward, which must satisfy the pending call's escalating minimum.
    /// @param memo The original memo bound by the pending call.
    /// @param metadata The original metadata bound by the pending call.
    /// @return wasRefunded Whether the retained input was refunded.
    /// @return beneficiaryTokenCount The project tokens returned if the final `pay` attempt succeeded.
    function finalizePendingCallWithGas(
        bytes32 id,
        JBPendingRouterTerminalCall calldata call,
        uint256 gasLimit,
        string calldata memo,
        bytes calldata metadata
    )
        external
        override
        returns (bool wasRefunded, uint256 beneficiaryTokenCount)
    {
        return _finalizePendingCall({id: id, call: call, gasLimit: gasLimit, memo: memo, metadata: metadata});
    }

    /// @notice Empty implementation because the gateway only escrows retained calls, not project balances.
    /// @param projectId The project whose balance migration was requested.
    /// @param token The token whose balance migration was requested.
    /// @param to The destination terminal that would receive migrated funds.
    /// @return balance Always returns 0 because the gateway does not hold project balances.
    function migrateBalanceOf(
        uint256 projectId,
        address token,
        IJBTerminal to
    )
        external
        pure
        override
        returns (uint256 balance)
    {
        projectId;
        token;
        to;
        return 0;
    }

    /// @notice Route a payment, retaining failed zero-minimum input only when source-project metadata opts in.
    /// @dev Retention requires `minReturnedTokens == 0` and metadata which is exactly 32 bytes encoding a nonzero raw
    /// source project ID. All other failed payments revert synchronously.
    /// @param projectId The ID of the destination project to pay.
    /// @param token The address of the token to pay with.
    /// @param amount The amount of tokens to send.
    /// @param beneficiary The address to receive any tokens minted by the destination project.
    /// @param minReturnedTokens The minimum number of destination project tokens expected in return.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes in `JBMetadataResolver`'s format, or exactly 32 bytes naming the source project.
    /// @return beneficiaryTokenCount The number of tokens minted for the beneficiary.
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
        // Resolve the upstream payer before taking custody, because a forwarding caller only exposes it for the
        // duration of its own call. This address becomes the preferred refund terminal if the route never settles.
        address refundTo = _resolveOriginalPayer(_msgSender());

        // Take custody up front so a later Router failure rolls back to this token rather than to a swapped one. The
        // amount is re-measured from the balance delta, which is what a fee-on-transfer input actually delivered.
        amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});

        // Read the escrow opt-in. Zero means this caller never asked for custody and expects a synchronous revert.
        uint256 sourceProjectId = _sourceProjectIdFrom(metadata);

        JBPendingRouterTerminalCall memory call = JBPendingRouterTerminalCall({
            amount: amount,
            beneficiary: beneficiary,
            preferAddToBalance: false,
            projectId: projectId,
            refundTo: refundTo,
            // Held-fee handling belongs to add-to-balance; a payment never asks for it.
            shouldReturnHeldFees: false,
            sourceProjectId: sourceProjectId,
            token: token
        });

        // Try the route inside this transaction first, honoring the caller's minimum. Nothing is retained when it
        // settles, and the minimum is only ever enforced here because retained calls always carry a zero minimum.
        (bool success, bytes32 errorHash, uint256 count,) =
            _attempt({call: call, minReturnedTokens: minReturnedTokens, memo: memo, metadata: metadata, gasLimit: 0});
        if (success) return count;

        // Preserve minimums and calls without a usable source-project opt-in instead of silently expanding custody. A
        // caller who priced a minimum is asking to fail now rather than to be settled later at an unknown rate.
        if (minReturnedTokens != 0 || !_shouldRetain(call)) {
            revert JBRouterTerminalGateway_RouteFailed(errorHash);
        }

        // The opt-in was given, so absorb the failure instead of bubbling it into the caller's catch boundary. The
        // input stays in custody and recovery becomes permissionless.
        _queue({call: call, memo: memo, metadata: metadata, errorHash: errorHash});
    }

    /// @notice Make a permissionless attempt using the default qualified gas budget.
    /// @dev Once `FINALIZATION_FAILURE_COUNT` matching failures have accumulated, further attempts must go through
    /// `finalizePendingCall`. The supplied call, memo, and metadata are read from the queue event and authenticated
    /// against the stored commitment.
    /// @param id The pending call identifier.
    /// @param call The retained call, as emitted when it was queued.
    /// @param memo The original memo bound by the pending call.
    /// @param metadata The original metadata bound by the pending call.
    /// @return beneficiaryTokenCount The project tokens returned if a routed `pay` succeeds.
    function processPendingCall(
        bytes32 id,
        JBPendingRouterTerminalCall calldata call,
        string calldata memo,
        bytes calldata metadata
    )
        external
        override
        returns (uint256 beneficiaryTokenCount)
    {
        return _processPendingCall({id: id, call: call, gasLimit: 0, memo: memo, metadata: metadata});
    }

    /// @notice Make a permissionless attempt with an expanded qualified gas budget.
    /// @dev Behaves like `processPendingCall` but forwards a caller-selected budget, which must satisfy the pending
    /// call's escalating minimum and fit under the live chain's executable transaction budget.
    /// @param id The pending call identifier.
    /// @param call The retained call, as emitted when it was queued.
    /// @param gasLimit The gas to forward, which must satisfy the pending call's escalating minimum.
    /// @param memo The original memo bound by the pending call.
    /// @param metadata The original metadata bound by the pending call.
    /// @return beneficiaryTokenCount The project tokens returned if a routed `pay` succeeds.
    function processPendingCallWithGas(
        bytes32 id,
        JBPendingRouterTerminalCall calldata call,
        uint256 gasLimit,
        string calldata memo,
        bytes calldata metadata
    )
        external
        override
        returns (uint256 beneficiaryTokenCount)
    {
        return _processPendingCall({id: id, call: call, gasLimit: gasLimit, memo: memo, metadata: metadata});
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Delegate the accounting-context lookup to the immutable router.
    /// @param projectId The ID of the project to get the accounting context for.
    /// @param token The address of the token to get the accounting context for.
    /// @return context The accounting context reported by the immutable router.
    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        override
        returns (JBAccountingContext memory context)
    {
        return ROUTER.accountingContextForTokenOf({projectId: projectId, token: token});
    }

    /// @notice Delegate the accounting-context lookup to the immutable router.
    /// @param projectId The project whose accounting contexts were requested.
    /// @return contexts The accounting contexts reported by the immutable router.
    function accountingContextsOf(uint256 projectId)
        external
        view
        override
        returns (JBAccountingContext[] memory contexts)
    {
        return ROUTER.accountingContextsOf(projectId);
    }

    /// @notice Delegate the surplus lookup to the immutable router.
    /// @param projectId The project whose surplus was requested.
    /// @param tokens The token set the caller wanted surplus measured against.
    /// @param decimals The fixed-point precision the caller wanted the surplus returned in.
    /// @param currency The currency the caller wanted the surplus returned in.
    /// @return surplus The surplus reported by the immutable router.
    function currentSurplusOf(
        uint256 projectId,
        address[] calldata tokens,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        override
        returns (uint256 surplus)
    {
        return ROUTER.currentSurplusOf({projectId: projectId, tokens: tokens, decimals: decimals, currency: currency});
    }

    /// @notice Delegate best-pool discovery to the immutable router.
    /// @param normalizedTokenIn The input token (wrapped if native).
    /// @param normalizedTokenOut The output token (wrapped if native).
    /// @return pool The best pool found by the immutable router.
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
    /// @param normalizedTokenIn The input token (wrapped if native).
    /// @param normalizedTokenOut The output token (wrapped if native).
    /// @return pool The V3 pool with the highest liquidity found by the immutable router.
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

    /// @notice Return the hash commitment of a call retained after its atomic router attempt failed.
    /// @dev The full call, memo, and metadata are emitted by the queue event; only their hash is stored.
    /// @param id The pending call identifier.
    /// @return commitment The retained call's commitment, or zero when no call is pending under `id`.
    function pendingCallCommitmentOf(bytes32 id) external view override returns (bytes32 commitment) {
        return _pendingCallCommitmentOf[id];
    }

    /// @notice Return a retained call's consecutive matching failure state.
    /// @param id The pending call identifier.
    /// @return failure The matching failure state.
    function pendingCallFailureOf(bytes32 id)
        external
        view
        override
        returns (JBPendingRouterTerminalCallFailure memory failure)
    {
        return _pendingCallFailureOf[id];
    }

    /// @notice Delegate payment previewing to the immutable router.
    /// @param projectId The ID of the destination project to pay.
    /// @param token The token to provide to the router.
    /// @param amount The amount of tokens which would be sent.
    /// @param beneficiary The address which would receive any tokens minted by the destination project.
    /// @param metadata Bytes in `JBMetadataResolver`'s format.
    /// @return ruleset The destination project's ruleset the payment would be made under.
    /// @return beneficiaryTokenCount The number of tokens which would be minted for the beneficiary.
    /// @return reservedTokenCount The number of tokens which would be reserved by the destination project.
    /// @return hookSpecifications The pay hooks the destination project's ruleset would invoke.
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

    /// @notice Return the terminal this gateway forwards into.
    /// @dev One hop only, never the end of the chain. `JBForwardingCheck` walks forwarders link by link to detect
    /// cycles, so naming a terminal further downstream would hide the router from that walk and let a route that
    /// returns to the router read as non-circular.
    /// @param projectId Ignored because every project forwards to the same immutable router.
    /// @return terminal The immutable router terminal.
    function terminalOf(uint256 projectId) external view override returns (IJBTerminal terminal) {
        projectId;
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
        // Native input arrives with the call itself, so the delivered amount is simply what was attached.
        if (token == JBConstants.NATIVE_TOKEN) return msg.value;

        // An ERC-20 call has no use for attached native tokens, and accepting them would strand value the gateway
        // has no pending record for.
        if (msg.value != 0) revert JBRouterTerminalGateway_NoMsgValueAllowed(msg.value);

        // Resolve the owner through ERC-2771 so a meta-transaction pulls from the signer, not the forwarder.
        address sender = _msgSender();

        // Metadata may carry a Permit2 allowance addressed to this gateway. The ID is namespaced to this address, so
        // an allowance signed for the Router or Registry is not visible here and is left untouched.
        (bool exists, bytes memory parsedMetadata) =
            JBMetadataResolver.getDataFor({id: _PERMIT2_ID, metadata: metadata});
        if (exists) {
            JBSingleAllowance memory allowance = abi.decode(parsedMetadata, (JBSingleAllowance));

            // Refuse to pull more than the signer authorized, rather than letting the transfer below silently draw on
            // a pre-existing allowance the signer did not intend for this payment.
            if (amount > allowance.amount) {
                revert JBRouterTerminalGateway_PermitAllowanceNotEnough({amount: amount, allowance: allowance.amount});
            }

            IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
                details: IAllowanceTransfer.PermitDetails({
                    token: token, amount: allowance.amount, expiration: allowance.expiration, nonce: allowance.nonce
                }),
                // The gateway spends the allowance itself; it never delegates the pull to the Router.
                spender: address(this),
                sigDeadline: allowance.sigDeadline
            });

            // A failed permit is not fatal: the signer may already hold a direct allowance, or have had this nonce
            // consumed by an earlier transaction. Record the reason and let the transfer below decide.
            try PERMIT2.permit({owner: sender, permitSingle: permitSingle, signature: allowance.signature}) {}
            catch (bytes memory reason) {
                emit Permit2AllowanceFailed({token: token, owner: sender, reason: reason, caller: sender});
            }
        }

        // Snapshot the balance so fee-on-transfer inputs use the amount which actually arrives.
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // Keep callback-capable tokens from nesting another intake inside this balance-delta measurement. Without
        // this, a token that calls back mid-transfer could have a second deposit land between the snapshot and the
        // reading below, so both calls would measure it and custody would owe more than it holds.
        if (_acceptingToken) revert JBRouterTerminalGateway_ReentrantTokenTransfer(token);
        _acceptingToken = true;

        // Pull the input only after closing the reentrant measurement window.
        _transferFrom({from: sender, to: address(this), token: token, amount: amount});
        acceptedAmount = IERC20(token).balanceOf(address(this)) - balanceBefore;

        // Re-open intake after the post-transfer balance has fixed this call's accepted amount.
        _acceptingToken = false;
    }

    /// @notice Attempt a retained call atomically against the immutable router.
    /// @dev Scopes an exact router allowance and the transient `originalPayer` around the bounded call, restoring any
    /// enclosing values so nested forwarding hooks cannot clobber their outer attempt.
    /// @param call The call to attempt.
    /// @param minReturnedTokens The minimum project-token count required by a routed `pay` call. Always zero for
    /// retries because nonzero-minimum payments are never retained.
    /// @param memo The memo to pass along to the router.
    /// @param metadata The metadata to pass along to the router.
    /// @param gasLimit The gas to forward, or zero to forward all remaining gas minus the failure-accounting reserve.
    /// @return success Whether the router call succeeded.
    /// @return errorHash The selector-level fingerprint of the failure, if any.
    /// @return beneficiaryTokenCount The project tokens returned by a successful `pay` call.
    /// @return gasExhausted Whether a failed call consumed its complete forwarded budget with no error data.
    function _attempt(
        JBPendingRouterTerminalCall memory call,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata,
        uint256 gasLimit
    )
        internal
        returns (bool success, bytes32 errorHash, uint256 beneficiaryTokenCount, bool gasExhausted)
    {
        // Rebuild the exact terminal call the payer originally made, so a retry days later is indistinguishable from
        // the first attempt apart from its gas budget.
        bytes memory routerCall;
        if (call.preferAddToBalance) {
            routerCall = abi.encodeCall(
                IJBTerminal.addToBalanceOf,
                (call.projectId, call.token, call.amount, call.shouldReturnHeldFees, memo, metadata)
            );
        } else {
            routerCall = abi.encodeCall(
                IJBTerminal.pay,
                (call.projectId, call.token, call.amount, call.beneficiary, minReturnedTokens, memo, metadata)
            );
        }

        uint256 previousAllowance;
        uint256 value;
        if (call.token == JBConstants.NATIVE_TOKEN) {
            // Native input is handed over with the call; there is no allowance to manage.
            value = call.amount;
        } else {
            // Approve exactly this attempt's amount so a Router bug cannot reach the rest of pooled custody.
            // Preserve an enclosing same-token attempt's allowance across legitimate nested forwarding hooks.
            previousAllowance = IERC20(call.token).allowance({owner: address(this), spender: address(ROUTER)});
            IERC20(call.token).forceApprove({spender: address(ROUTER), value: call.amount});
        }

        if (gasLimit == 0) {
            uint256 available = gasleft();
            // A zero-gas attempt keeps an underfunded retention-qualified call inside the custody boundary; ordinary
            // callers still revert below instead of entering escrow. Withholding the reserve is what guarantees this
            // frame survives the callee's failure with enough gas left to record it durably.
            if (available > _FAILURE_GAS_RESERVE) gasLimit = available - _FAILURE_GAS_RESERVE;
        } else {
            // A qualified attempt must be a genuine test of the route. Anything below the base budget would fail for
            // lack of gas rather than for a real reason, letting a cheap caller manufacture failure evidence.
            if (gasLimit < QUALIFIED_CALL_GAS) {
                revert JBRouterTerminalGateway_RetryGasLimitTooLow({gasLimit: gasLimit, minimum: QUALIFIED_CALL_GAS});
            }
            _requireRetryGas(gasLimit);
        }

        // Expose the original payer to the Router for the duration of the call so residue and refunds reach whoever
        // funded the input, not this gateway. Save and restore around it because a nested forwarding hook may run
        // its own attempt inside this one.
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
    /// @param id The pending call identifier.
    /// @param call The retained call, authenticated against the stored commitment.
    /// @param gasLimit The gas to forward, or zero to select the required minimum.
    /// @param memo The original memo bound by the pending call.
    /// @param metadata The original metadata bound by the pending call.
    /// @return wasRefunded Whether the retained input was refunded.
    /// @return beneficiaryTokenCount The project tokens returned if the final `pay` attempt succeeded.
    function _finalizePendingCall(
        bytes32 id,
        JBPendingRouterTerminalCall calldata call,
        uint256 gasLimit,
        string calldata memo,
        bytes calldata metadata
    )
        internal
        returns (bool wasRefunded, uint256 beneficiaryTokenCount)
    {
        // Authenticate the caller-supplied call against the stored commitment before acting on any of its fields.
        bytes32 commitment = _requirePendingCall({id: id, call: call, memo: memo, metadata: metadata});
        JBPendingRouterTerminalCallFailure memory failure = _pendingCallFailureOf[id];

        // Refunding is only justified once the route has proven itself broken the same way three times over three
        // days. Anything less is still ordinary retry territory.
        if (failure.count < FINALIZATION_FAILURE_COUNT) {
            revert JBRouterTerminalGateway_PendingCallNotFinalizable({id: id, failureCount: failure.count});
        }

        // Space this attempt a day from the last so the evidence spans changing chain conditions rather than one
        // unlucky block.
        _requireReady({id: id, lastFailureAt: failure.lastFailureAt});
        gasLimit = _qualifiedGasLimit({failure: failure, requestedGasLimit: gasLimit});

        // Clear the pending record before interacting, so a re-entrant caller finds nothing to claim twice. Every exit
        // below either settles, rewrites it, or reverts the whole transaction and restores it.
        delete _pendingCallCommitmentOf[id];

        // Retained calls always carry a zero minimum, so the final attempt has no slippage floor of its own.
        (bool success, bytes32 errorHash, uint256 count, bool gasExhausted) =
            _attempt({call: call, minReturnedTokens: 0, memo: memo, metadata: metadata, gasLimit: gasLimit});

        // A late success is still a success: the payment lands where it was always headed and nothing is refunded.
        if (success) {
            delete _pendingCallFailureOf[id];
            emit JBRouterTerminalGateway_ProcessPendingCall({
                id: id, call: call, beneficiaryTokenCount: count, caller: _msgSender()
            });
            return (false, count);
        }

        // Gas exhaustion is its own stable failure class, so each matching retry must use a larger budget.
        if (gasExhausted) errorHash = _GAS_EXHAUSTED_ERROR_HASH;

        // A different failure than the qualifying streak means the route changed. That is new information, not the
        // confirmation a refund requires, so restore the pending call and start the evidence over.
        if (errorHash != failure.errorHash) {
            _pendingCallCommitmentOf[id] = commitment;
            _recordFailure({id: id, errorHash: errorHash, previous: failure});
            return (false, 0);
        }

        // The same failure reproduced under a qualified budget. Treat the destination as unreachable and return the
        // input to the project that was named when custody was taken.
        delete _pendingCallFailureOf[id];
        _refund(call);

        emit JBRouterTerminalGateway_RefundPendingCall({id: id, call: call, caller: _msgSender()});
        return (true, 0);
    }

    /// @notice Process a retained call using a caller-selected qualified gas budget.
    /// @param id The pending call identifier.
    /// @param call The retained call, authenticated against the stored commitment.
    /// @param gasLimit The gas to forward, or zero to select the required minimum.
    /// @param memo The original memo bound by the pending call.
    /// @param metadata The original metadata bound by the pending call.
    /// @return beneficiaryTokenCount The project tokens returned if a routed `pay` succeeds.
    function _processPendingCall(
        bytes32 id,
        JBPendingRouterTerminalCall calldata call,
        uint256 gasLimit,
        string calldata memo,
        bytes calldata metadata
    )
        internal
        returns (uint256 beneficiaryTokenCount)
    {
        // Authenticate the caller-supplied call against the stored commitment before acting on any of its fields.
        bytes32 commitment = _requirePendingCall({id: id, call: call, memo: memo, metadata: metadata});
        JBPendingRouterTerminalCallFailure memory failure = _pendingCallFailureOf[id];

        // Once the streak qualifies, the next attempt is the one that can release custody, so it must run through
        // the finalizer where a matching failure refunds instead of silently adding a fourth identical data point.
        if (failure.count >= FINALIZATION_FAILURE_COUNT) {
            revert JBRouterTerminalGateway_PendingCallRequiresFinalization(id);
        }

        // The first attempt after queuing runs immediately; every counted one after it waits a day so the streak
        // spans changing chain conditions rather than one unlucky block.
        if (failure.count != 0) _requireReady({id: id, lastFailureAt: failure.lastFailureAt});
        gasLimit = _qualifiedGasLimit({failure: failure, requestedGasLimit: gasLimit});

        // Clear the pending record before interacting, so a re-entrant caller finds nothing to claim twice. Every exit
        // below either settles, rewrites it, or reverts the whole transaction and restores it.
        delete _pendingCallCommitmentOf[id];

        // Retained calls always carry a zero minimum, so a retry has no slippage floor of its own.
        (bool success, bytes32 errorHash, uint256 count, bool gasExhausted) =
            _attempt({call: call, minReturnedTokens: 0, memo: memo, metadata: metadata, gasLimit: gasLimit});

        // The route recovered — settle into the destination and drop the failure history with the pending record.
        if (success) {
            delete _pendingCallFailureOf[id];
            emit JBRouterTerminalGateway_ProcessPendingCall({
                id: id, call: call, beneficiaryTokenCount: count, caller: _msgSender()
            });
            return count;
        }

        // Gas exhaustion advances only after the failure state has enforced the next larger budget.
        if (gasExhausted) errorHash = _GAS_EXHAUSTED_ERROR_HASH;

        // Still failing, so restore custody and fold this attempt into the streak that governs the next budget.
        _pendingCallCommitmentOf[id] = commitment;
        _recordFailure({id: id, errorHash: errorHash, previous: failure});
    }

    /// @notice Queue a failed call, retaining its original input token behind a single-slot hash commitment.
    /// @dev The full call, memo, and metadata are emitted rather than stored so the gas-constrained queue path writes
    /// one storage slot; retriers read them back from the event.
    /// @param call The call to retain.
    /// @param memo The original memo bound into the commitment.
    /// @param metadata The original metadata bound into the commitment.
    /// @param errorHash The selector-level fingerprint of the initial downstream error.
    function _queue(
        JBPendingRouterTerminalCall memory call,
        string calldata memo,
        bytes calldata metadata,
        bytes32 errorHash
    )
        internal
    {
        // A monotonic counter keeps each retained call's custody isolated, so two identical failed fees from the same
        // project never collide into one claim.
        bytes32 id = bytes32(++pendingCallCount);

        // This runs in the gas the failed route left behind, so store only the hash. The event below carries
        // everything a retrier needs to reconstruct and re-present the call.
        _pendingCallCommitmentOf[id] = _commitmentOf({call: call, memo: memo, metadata: metadata});

        emit JBRouterTerminalGateway_QueuePendingCall({
            id: id, call: call, memo: memo, metadata: metadata, errorHash: errorHash, caller: _msgSender()
        });
    }

    /// @notice Record a qualified failure, resetting the streak whenever the failure class changes.
    /// @param id The pending call identifier.
    /// @param errorHash The selector-level or gas-exhaustion failure-class fingerprint.
    /// @param previous The pending call's failure state before this attempt.
    function _recordFailure(
        bytes32 id,
        bytes32 errorHash,
        JBPendingRouterTerminalCallFailure memory previous
    )
        internal
    {
        // Only an unbroken run of the same failure justifies giving up on a route, so a changed class restarts the
        // count at this attempt rather than carrying forward evidence about a failure mode that no longer occurs.
        uint32 count = errorHash == previous.errorHash ? previous.count + 1 : 1;

        // Day-scale spacing is the only thing this timestamp gates, so validator-scale drift cannot matter.
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
    /// @dev Prefers the still-registered original source terminal, then the token's current primary terminal, then any
    /// other registered non-circular terminal. Reverts if every candidate rejects the refund.
    /// @param call The retained call whose original input must be refunded.
    function _refund(JBPendingRouterTerminalCall memory call) internal {
        // Every candidate below is credited through project accounting, never by raw transfer, so the refund lands as
        // recorded project balance rather than as tokens sitting above a terminal's books.
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

        // Nothing accepted the refund. Revert so custody, the pending record, and the qualifying streak all roll back
        // intact and the attempt can be repeated once the project's terminals change.
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
        // A direct allowance is the cheaper path and the one most payers already hold, so try it before Permit2.
        if (IERC20(token).allowance({owner: from, spender: address(this)}) >= amount) {
            return IERC20(token).safeTransferFrom({from: from, to: to, value: amount});
        }

        // Permit2 settles in 160 bits, so a wider amount cannot be pulled through it at all. Reject rather than
        // truncate, which would move less than the payment the caller asked to make.
        if (amount > type(uint160).max) revert JBRouterTerminalGateway_AmountOverflow(amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        PERMIT2.transferFrom({from: from, to: to, amount: uint160(amount), token: token});
    }

    /// @notice Attempt a project-accounting refund without letting one terminal block an alternate terminal.
    /// @param call The retained call whose original input must be refunded.
    /// @param terminal The candidate source-project terminal to credit.
    /// @return success Whether the candidate accepted and accounted for the complete refund.
    function _tryRefund(JBPendingRouterTerminalCall memory call, IJBTerminal terminal) internal returns (bool success) {
        // Skip a candidate whose forwarding chain leads back here: crediting it would hand custody straight back to
        // this gateway as a fresh unrecorded deposit rather than reaching the project's books.
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
            // Approve exactly this refund so a rejecting candidate is left with no standing claim on custody.
            IERC20(call.token).forceApprove({spender: address(terminal), value: call.amount});
        }

        // Call low-level so one uncooperative terminal reverting cannot abort the search across the remaining
        // candidates. The caller reverts only if every one of them fails.
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
    /// @param target The address to call.
    /// @param value The native-token value to send with the call.
    /// @param gasLimit The gas to forward to the call.
    /// @param data The calldata to send.
    /// @return success Whether the call succeeded.
    /// @return errorHash The selector-level fingerprint of the failure, if any.
    /// @return result The first return word of a successful call.
    /// @return gasExhausted Whether a failed call consumed its complete forwarded budget with no error data.
    function _boundedCall(
        address target,
        uint256 value,
        uint256 gasLimit,
        bytes memory data
    )
        internal
        returns (bool success, bytes32 errorHash, uint256 result, bool gasExhausted)
    {
        // Assembly keeps the callee's return data from being copied into memory wholesale, so a failing route cannot
        // inflate this frame's memory cost and consume the reserve that the failure accounting depends on.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            let gasBefore := gas()

            // Bound the call so a route that runs away on gas fails here rather than taking the whole transaction.
            success := call(gasLimit, target, value, add(data, 0x20), mload(data), ptr, 0x20)
            let gasSpent := sub(gasBefore, gas())

            // Only a full word is a usable `pay` result; a shorter return cannot be a token count.
            let size := returndatasize()
            if and(success, gt(size, 0x1f)) { result := mload(ptr) }

            // A failed call with no error data which consumed its complete budget is an unqualified gas exhaustion.
            gasExhausted := and(iszero(success), and(iszero(size), iszero(lt(gasSpent, gasLimit))))

            // Fingerprint only the selector. Custom errors embed dynamic arguments — amounts, addresses, block
            // numbers — that differ between otherwise identical failures, and hashing those would make every attempt
            // look like a new failure class and reset the streak forever.
            let copySize := size
            if gt(copySize, 4) { copySize := 4 }

            returndatacopy(ptr, 0, copySize)
            errorHash := keccak256(ptr, copySize)
            mstore(0x40, add(ptr, 0x20))
        }
    }

    /// @notice Derive the largest call budget which preserves the transaction's accounting reserves.
    /// @dev Bounds the block limit by the EIP-7825 per-transaction cap, reserves gas for transaction overhead and
    /// failure accounting, then applies the EIP-150 forwarding ratio.
    /// @param blockGasLimit The block gas limit from which to derive an executable call budget.
    /// @return gasLimit The maximum call budget supported by `blockGasLimit`.
    function _maximumQualifiedCallGas(uint256 blockGasLimit) internal pure returns (uint256 gasLimit) {
        // A block larger than one transaction can carry does not make a larger attempt executable.
        if (blockGasLimit > _TRANSACTION_GAS_CAP) blockGasLimit = _TRANSACTION_GAS_CAP;

        // A chain whose whole block cannot cover the reserve can execute no qualified attempt at all.
        if (blockGasLimit <= _TRANSACTION_GAS_RESERVE) return 0;

        // Reserve room for transaction overhead and durable failure accounting, then apply the 63/64 rule so the
        // remainder is gas a `CALL` can actually forward rather than gas the caller merely holds.
        return (blockGasLimit - _TRANSACTION_GAS_RESERVE) * 63 / 64;
    }

    /// @notice Resolve the minimum escalating gas budget for a qualified attempt on the live chain.
    /// @dev Consecutive gas exhaustion targets 5M, 10M, 15M, then 20M gas, capped by the executable transaction budget.
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
        // Without room for the base budget there is no such thing as a qualified attempt on this chain, so refuse
        // rather than let an underpowered call masquerade as evidence the route is broken.
        if (maximumGasLimit < QUALIFIED_CALL_GAS) {
            revert JBRouterTerminalGateway_BlockGasLimitTooLow({maximum: maximumGasLimit, minimum: QUALIFIED_CALL_GAS});
        }

        // Repeating a budget that already ran out proves nothing new, so each consecutive exhaustion demands a step
        // larger one. Other failure classes are about the route itself and stay at the base budget.
        uint256 minimum = QUALIFIED_CALL_GAS;
        if (failure.errorHash == _GAS_EXHAUSTED_ERROR_HASH) minimum *= uint256(failure.count) + 1;

        // The ladder stops at whatever the chain can actually execute; demanding more would strand the call.
        if (minimum > maximumGasLimit) minimum = maximumGasLimit;

        // Zero means the caller wants whatever the failure state currently requires.
        if (requestedGasLimit == 0) return minimum;

        // Floor and ceiling both matter: below the minimum an attempt is not a fair test of the route, and above the
        // executable maximum it can never be included in a block.
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

    /// @notice Hash a retained call together with its original memo and metadata into its stored commitment.
    /// @param call The retained call.
    /// @param memo The original memo bound by the pending call.
    /// @param metadata The original metadata bound by the pending call.
    /// @return commitment The commitment binding the call, memo, and metadata.
    function _commitmentOf(
        JBPendingRouterTerminalCall memory call,
        string calldata memo,
        bytes calldata metadata
    )
        internal
        pure
        returns (bytes32 commitment)
    {
        return keccak256(abi.encode(call, memo, metadata));
    }

    /// @notice Require a pending call and authenticate the supplied call, memo, and metadata against its commitment.
    /// @param id The pending call identifier.
    /// @param call The retained call as supplied by the retrier.
    /// @param memo The memo which must match the memo bound into the commitment.
    /// @param metadata The metadata which must match the metadata bound into the commitment.
    /// @return commitment The authenticated commitment stored under `id`.
    function _requirePendingCall(
        bytes32 id,
        JBPendingRouterTerminalCall calldata call,
        string calldata memo,
        bytes calldata metadata
    )
        internal
        view
        returns (bytes32 commitment)
    {
        // A zero commitment means nothing is pending here: never queued, already settled, or already refunded.
        commitment = _pendingCallCommitmentOf[id];
        if (commitment == bytes32(0)) revert JBRouterTerminalGateway_PendingCallNotFound(id);

        // Everything about the call arrived from an untrusted caller, so re-derive the hash and require an exact
        // match. This is what stops a retrier from redirecting the beneficiary, the amount, or the refund creditor.
        bytes32 actualCommitment = _commitmentOf({call: call, memo: memo, metadata: metadata});
        if (actualCommitment != commitment) {
            revert JBRouterTerminalGateway_CallDataMismatch({
                expectedCommitment: commitment, actualCommitment: actualCommitment
            });
        }
    }

    /// @notice Require the retry delay to have elapsed.
    /// @param id The pending call identifier.
    /// @param lastFailureAt The timestamp of the pending call's latest qualified failure.
    function _requireReady(bytes32 id, uint48 lastFailureAt) internal view {
        uint256 nextAttemptAt = uint256(lastFailureAt) + RETRY_DELAY;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < nextAttemptAt) {
            revert JBRouterTerminalGateway_PendingCallNotReady({id: id, nextAttemptAt: nextAttemptAt});
        }
    }

    /// @notice Require enough gas to forward a qualified attempt while retaining the failure-accounting reserve.
    /// @param gasLimit The gas which must be forwardable by `CALL` after the EIP-150 withholding margin.
    function _requireRetryGas(uint256 gasLimit) internal view {
        uint256 available = gasleft();
        // Include the EIP-150 withholding margin so the requested amount is actually forwarded by `CALL`.
        uint256 required = gasLimit + (gasLimit + 62) / 63 + _FAILURE_GAS_RESERVE;
        if (available < required) {
            revert JBRouterTerminalGateway_InsufficientRetryGas({available: available, required: required});
        }
    }

    /// @notice Resolve an upstream payer exposed by a forwarding caller.
    /// @param fallback_ The payer to use when the caller does not expose an upstream payer.
    /// @return payer The forwarding caller's `originalPayer` when nonzero, otherwise `fallback_`.
    function _resolveOriginalPayer(address fallback_) internal view returns (address payer) {
        // The Registry forwards on a payer's behalf, so asking it who it is acting for recovers the terminal or
        // protocol payer that actually funded the input. Probe defensively: most callers are not forwarders, and a
        // caller that answers badly must degrade to itself rather than take the payment down.
        if (msg.sender.code.length != 0) {
            try IJBPayerTracker(msg.sender).originalPayer() returns (address original) {
                if (original != address(0)) return original;
            } catch {}
        }
        return fallback_;
    }

    /// @notice Decide whether a failed call carrying the source-project opt-in should be retained rather than reverted.
    /// @dev The opt-in metadata shape is also what core's own infrastructure sends when it pays on a project's behalf.
    /// Those callers already catch a synchronous failure and restore the input to the right party without fees:
    /// `JBController` hands undeliverable reserved-token splits to the split beneficiary, and `JBMultiTerminal`
    /// restores a failed payout split fee-free. Custody would only turn that into a delayed, fee-charged refund, or,
    /// for reserved project tokens the source cannot hold, a permanent lock. So the source project's controller never
    /// retains, and its terminals retain only protocol fees to the fee project, which is the forgiveness this
    /// contract exists to close. Any other payer, such as a protocol contract with its own catch boundary, retains.
    /// @param call The failed call.
    /// @return shouldRetain Whether the call should be queued for permissionless recovery.
    function _shouldRetain(JBPendingRouterTerminalCall memory call) internal view returns (bool shouldRetain) {
        // Zero means this caller never asked for custody and expects a synchronous revert.
        if (call.sourceProjectId == 0) return false;

        // `refundTo` is the resolved upstream payer: the contract acting for the source project, if any.
        if (address(DIRECTORY.controllerOf(call.sourceProjectId)) == call.refundTo) return false;
        if (DIRECTORY.isTerminalOf({projectId: call.sourceProjectId, terminal: IJBTerminal(call.refundTo)})) {
            return call.projectId == JBConstants.FEE_BENEFICIARY_PROJECT_ID;
        }
        return true;
    }

    /// @notice Decode the raw source-project metadata used by core terminal fees and project payouts.
    /// @dev Core's fee and payout paths send exactly `abi.encodePacked(sourceProjectId)`, so anything of another
    /// length was never an opt-in. `JBMetadataResolver`-formatted metadata is longer and is therefore ignored here.
    /// @param metadata The metadata to decode, which opts in only when it is exactly 32 bytes.
    /// @return sourceProjectId The decoded source project ID, or zero when the metadata is not an opt-in.
    function _sourceProjectIdFrom(bytes calldata metadata) internal pure returns (uint256 sourceProjectId) {
        if (metadata.length != 32) return 0;

        assembly ("memory-safe") {
            sourceProjectId := calldataload(metadata.offset)
        }

        // A word too large to be an issued project ID is a coincidence — a hash, a packed address, a bitfield — not
        // a
        // request for custody. Reject it so such calls keep synchronous failure semantics instead of escrowing funds
        // against a project that can never be minted to receive them. `uint64` is core's own project-ID width.
        if (sourceProjectId > type(uint64).max) return 0;
    }
}
