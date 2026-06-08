// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {IJBForwardingTerminal} from "./interfaces/IJBForwardingTerminal.sol";
import {IJBPayerTracker} from "./interfaces/IJBPayerTracker.sol";
import {IJBRouterTerminalRegistry} from "./interfaces/IJBRouterTerminalRegistry.sol";

import {JBForwardingCheck} from "./libraries/JBForwardingCheck.sol";

import {DefaultTerminalSegment} from "./structs/DefaultTerminalSegment.sol";

/// @notice A forwarding layer that lets each project choose which router terminal receives its payments, with an
/// owner-managed default for projects that have not opted in. Projects can lock their choice to guarantee permanence.
contract JBRouterTerminalRegistry is IJBRouterTerminalRegistry, JBPermissioned, Ownable, ERC2771Context {
    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when an amount exceeds the maximum width a forwarded terminal call can represent.
    error JBRouterTerminalRegistry_AmountOverflow(uint256 amount);

    /// @notice Thrown when attempting to disallow the terminal that is currently set as the default.
    error JBRouterTerminalRegistry_CannotDisallowDefaultTerminal(IJBTerminal terminal);

    /// @notice Thrown when a terminal would forward a project back into this registry, directly or transitively.
    error JBRouterTerminalRegistry_CircularForward(IJBTerminal terminal);

    /// @notice Thrown when native tokens are sent on a call that does not accept them.
    error JBRouterTerminalRegistry_NoMsgValueAllowed(uint256 value);

    /// @notice Thrown when the payment amount exceeds the Permit2 allowance provided in the metadata.
    error JBRouterTerminalRegistry_PermitAllowanceNotEnough(uint256 amount, uint256 allowanceAmount);

    /// @notice Thrown when changing a project's terminal after its terminal choice has been permanently locked.
    error JBRouterTerminalRegistry_TerminalLocked(uint256 projectId);

    /// @notice Thrown when the project's resolved terminal does not match the terminal the caller expected to lock.
    error JBRouterTerminalRegistry_TerminalMismatch(IJBTerminal currentTerminal, IJBTerminal expectedTerminal);

    /// @notice Thrown when selecting a terminal that is not on the registry allowlist.
    error JBRouterTerminalRegistry_TerminalNotAllowed(IJBTerminal terminal);

    /// @notice Thrown when a project has no explicit terminal and no default terminal has ever been set.
    error JBRouterTerminalRegistry_TerminalNotSet(uint256 projectId);

    /// @notice Thrown when setting the default terminal to the zero address.
    error JBRouterTerminalRegistry_ZeroAddress(address terminal);

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The Juicebox project registry used to verify project existence and ownership.
    IJBProjects public immutable override PROJECTS;

    /// @notice The Permit2 contract used for token approvals and transfers.
    IPermit2 public immutable override PERMIT2;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The current default terminal — applied to projects with ID strictly greater than
    /// `defaultTerminalProjectIdThreshold`. Existing projects (ID <= threshold) without an explicit
    /// terminal continue to resolve against the historical default that was current at the time
    /// their project ID range was active (see `_defaultTerminalHistory`).
    IJBTerminal public override defaultTerminal;

    /// @notice The `PROJECTS.count()` snapshot at the moment of the last `setDefaultTerminal` call.
    /// Projects with `ID <= defaultTerminalProjectIdThreshold` (i.e. already existing when the most
    /// recent default was set) DO NOT pick up `defaultTerminal` on fall-through; instead they
    /// resolve against the historical entry in `_defaultTerminalHistory` that covers their ID. The
    /// first default's segment covers every project that already existed when it was set (so those
    /// projects route through it), while later segments pin each outgoing default to its own cohort.
    /// This prevents the registry owner from silently rerouting payments for already-deployed
    /// projects via a later default change.
    uint256 public override defaultTerminalProjectIdThreshold;

    /// @notice Whether the terminal for a given project has been locked against future updates.
    /// @custom:param projectId The ID of the project to check lock state for.
    mapping(uint256 projectId => bool) public override hasLockedTerminal;

    /// @notice Whether a terminal is allowlisted for project-level selection.
    /// @custom:param terminal The terminal to check allowlist status for.
    mapping(IJBTerminal terminal => bool) public override isTerminalAllowed;

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice Append-only history of default-terminal cohorts captured at each `setDefaultTerminal` call. Each
    /// `segment[i]` applies to projectIds in `[<previous threshold> + 1, segment[i].maxProjectId]`. Resolution walks
    /// the array forward and returns the first segment whose `maxProjectId` covers the queried `projectId`. The first
    /// call records the projects that already existed mapped to the new default; later calls push the outgoing default
    /// onto this history before updating `defaultTerminal`.
    DefaultTerminalSegment[] internal _defaultTerminalHistory;

    /// @notice The terminal explicitly configured for a project before default-terminal fallback is applied.
    /// @custom:param projectId The ID of the project to look up the explicit terminal for.
    mapping(uint256 projectId => IJBTerminal) internal _terminalOf;

    //*********************************************************************//
    // -------------------- transient stored properties ------------------ //
    //*********************************************************************//

    /// @notice The original payer of the current transaction.
    address public transient override originalPayer;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @notice Construct a router-terminal registry.
    /// @param permissions The permissions contract.
    /// @param projects The project registry.
    /// @param permit2 The permit2 utility.
    /// @param owner The owner of the contract.
    /// @param trustedForwarder The trusted forwarder for the contract.
    constructor(
        IJBPermissions permissions,
        IJBProjects projects,
        IPermit2 permit2,
        address owner,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
        Ownable(owner)
    {
        PROJECTS = projects;
        PERMIT2 = permit2;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Get the accounting context for the specified project ID and token.
    /// @param projectId The ID of the project to get the accounting context for.
    /// @param token The address of the token to get the accounting context for.
    /// @return context A `JBAccountingContext` containing the accounting context for the project ID and token.
    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        override
        returns (JBAccountingContext memory context)
    {
        // Discovery view, fail-open: resolve the project's effective terminal WITHOUT reverting. When no terminal can
        // be resolved (e.g. no default terminal has been set on this chain yet), return an empty context
        // (`token == address(0)`) rather than reverting. Callers such as `JBDirectory.primaryTerminalOf` read this to
        // decide whether the registry accepts the token; an empty context means "not accepted", letting them fall
        // through to `address(0)` instead of propagating a revert that would brick the originating operation (e.g. a
        // protocol-fee cash out/payout routed to project #1). Transactional paths keep `_requireResolvedTerminalOf`
        // and still revert before accepting funds or forwarding into `address(0)`.
        IJBTerminal terminal = _resolvedTerminalOf(projectId);
        if (terminal == IJBTerminal(address(0))) return context;

        // Get the accounting context for the token.
        return terminal.accountingContextForTokenOf({projectId: projectId, token: token});
    }

    /// @notice Return all the accounting contexts for a specified project ID.
    /// @param projectId The ID of the project to get the accounting contexts for.
    /// @return contexts An array of `JBAccountingContext` containing the accounting contexts for the project ID.
    function accountingContextsOf(uint256 projectId)
        external
        view
        override
        returns (JBAccountingContext[] memory contexts)
    {
        // Discovery view, fail-open: resolve WITHOUT reverting and return an empty array when no terminal can be
        // resolved on this chain (see `accountingContextForTokenOf`). Transactional paths keep
        // `_requireResolvedTerminalOf` and still revert.
        IJBTerminal terminal = _resolvedTerminalOf(projectId);
        if (terminal == IJBTerminal(address(0))) return contexts;

        // Get the accounting contexts.
        return terminal.accountingContextsOf(projectId);
    }

    /// @notice Always returns 0 because the registry only forwards funds and does not hold project balances.
    /// @param projectId Unused.
    /// @param tokens Unused.
    /// @param decimals Unused.
    /// @param currency Unused.
    /// @return currentSurplus Always 0.
    function currentSurplusOf(
        uint256 projectId,
        address[] calldata tokens,
        uint256 decimals,
        uint256 currency
    )
        external
        pure
        override
        returns (uint256)
    {
        projectId;
        tokens;
        decimals;
        currency;
        return 0;
    }

    /// @notice The default terminal that applies to a given project on fall-through, accounting for the threshold
    /// and the snapshot history. Returns zero if no default ever applied to the project's ID range.
    /// @param projectId The ID of the project to resolve the default for.
    /// @return terminal The default terminal applicable to this project (zero if none).
    function defaultTerminalFor(uint256 projectId) external view override returns (IJBTerminal terminal) {
        return _defaultTerminalFor(projectId);
    }

    /// @notice Read a default-terminal history entry. Exposes the internal append-only history.
    /// @param index The history index (0 is the oldest captured snapshot).
    /// @return segment The `maxProjectId + terminal` pair for that history slot.
    function defaultTerminalHistoryAt(uint256 index)
        external
        view
        override
        returns (DefaultTerminalSegment memory segment)
    {
        return _defaultTerminalHistory[index];
    }

    /// @notice The total number of historical default-terminal snapshots captured (= number of `setDefaultTerminal`
    /// calls after the very first one).
    /// @return length The number of entries in the default-terminal history.
    function defaultTerminalHistoryLength() external view override returns (uint256 length) {
        return _defaultTerminalHistory.length;
    }

    /// @notice Preview a payment by forwarding the call to the terminal currently resolved for the project.
    /// @dev Uses the project-specific terminal when set, otherwise falls back to `defaultTerminal`.
    /// @param projectId The ID of the project to pay.
    /// @param token The token to pay into the resolved terminal.
    /// @param amount The amount of the input token to preview.
    /// @param beneficiary The address that would receive any minted project tokens.
    /// @param metadata Extra data to forward unchanged to the resolved terminal preview.
    /// @return ruleset The ruleset the resolved terminal would use for the preview.
    /// @return beneficiaryTokenCount The number of project tokens the beneficiary would receive.
    /// @return reservedTokenCount The number of project tokens that would be reserved.
    /// @return hookSpecifications Any pay hook specifications returned by the resolved terminal.
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
        // Read the terminal explicitly configured for this project, falling back to the
        // threshold-resolved default if none is pinned.
        IJBTerminal terminal = _requireResolvedTerminalOf(projectId);

        // Forward the preview request unchanged to whichever terminal was resolved above.
        return terminal.previewPayFor({
            projectId: projectId, token: token, amount: amount, beneficiary: beneficiary, metadata: metadata
        });
    }

    /// @notice The concrete terminal this forwarding layer would route a project's payment into.
    /// @param projectId The project whose downstream terminal should be resolved.
    /// @return terminal The concrete terminal the forwarder would call for `projectId`.
    function terminalOf(uint256 projectId) external view override returns (IJBTerminal terminal) {
        return _resolvedTerminalOf(projectId);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Check whether the registry supports a given interface ID.
    /// @param interfaceId The interface ID to check.
    /// @return supported Whether `interfaceId` is implemented.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool supported) {
        supported = interfaceId == type(IJBRouterTerminalRegistry).interfaceId
            || interfaceId == type(IJBForwardingTerminal).interfaceId || interfaceId == type(IJBTerminal).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    /// @notice Prevent the registry from forwarding straight back into its immediate caller.
    /// @param terminal The terminal to check for circular forwarding.
    function _enforceNoCircularForward(IJBTerminal terminal) internal view {
        // Reject immediate caller cycles so router -> registry -> same router cannot recurse indefinitely.
        if (msg.sender == address(terminal)) revert JBRouterTerminalRegistry_CircularForward(terminal);
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    /// @return calldata The `msg.data` of this call.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    /// @return sender The address which sent this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    /// @notice Returns the original payer to record in transient storage. If `_msgSender()` is a
    /// contract that exposes `IJBPayerTracker.originalPayer()` and that getter returns a non-zero
    /// value, the upstream payer is propagated so a forwarding chain (project payer -> registry
    /// -> router) refunds the true originator instead of the intermediary. Otherwise the direct
    /// caller is recorded — the common direct-call case.
    /// @return originalPayerOrSender The upstream payer if the resolved sender is a forwarding
    /// tracker that returns a non-zero address; otherwise the resolved sender itself.
    function _originalPayerOrSender() internal view returns (address originalPayerOrSender) {
        // Resolve through ERC-2771 so a trusted meta-tx forwarder is transparently unwrapped.
        address sender = _msgSender();

        // EOAs and contracts without code can't implement IJBPayerTracker — record them directly.
        if (sender.code.length == 0) return sender;

        // Probe the caller for IJBPayerTracker.originalPayer() via staticcall so a reverting or
        // non-conformant caller does not bubble up — fall back to the resolved sender on failure.
        (bool ok, bytes memory data) = sender.staticcall(abi.encodeWithSelector(IJBPayerTracker.originalPayer.selector));

        // Caller doesn't implement the interface (revert) or returned a truncated payload — treat
        // it as a direct payment from the caller itself.
        if (!ok || data.length < 32) return sender;

        // Decode the upstream payer the caller advertised. A zero value means "no upstream tracked",
        // which only happens when the caller is itself receiving a direct call — record the caller.
        address upstream = abi.decode(data, (address));
        return upstream == address(0) ? sender : upstream;
    }

    /// @notice Reject terminal choices that would forward the project back into this registry,
    /// directly or transitively. Walks up to the depth limit `JBForwardingCheck` enforces so a
    /// chain registry -> A -> B -> registry is caught (the previous one-hop probe missed those
    /// transitive cycles, letting a project lock itself into a route that always loops).
    /// @param projectId The project to validate forwarding for.
    /// @param terminal The terminal to validate.
    function _requireNonCircularTerminalFor(uint256 projectId, IJBTerminal terminal) internal view {
        // Reject direct self-selection so the registry cannot forward a project to itself.
        if (address(terminal) == address(this)) revert JBRouterTerminalRegistry_CircularForward(terminal);
        if (JBForwardingCheck.isCircularTerminal({target: address(this), projectId: projectId, terminal: terminal})) {
            revert JBRouterTerminalRegistry_CircularForward({terminal: terminal});
        }
    }

    /// @notice The default terminal that applies to a project on fall-through, taking the historical
    /// setDefaultTerminal snapshots into account so existing projects are not silently rerouted by a later default
    /// change.
    /// @param projectId The project to resolve the default for.
    /// @return terminal The default terminal applicable to this project (zero if none).
    function _defaultTerminalFor(uint256 projectId) internal view returns (IJBTerminal terminal) {
        // New projects (created after the most recent setDefaultTerminal) get the current default.
        if (projectId > defaultTerminalProjectIdThreshold) return defaultTerminal;

        // Older projects walk the history. Each segment covers a half-open range
        // `(minProjectIdExclusive, maxProjectId]`. The first segment covers every project that already existed when the
        // first default was set (mapped to that first default, so they route through it); later segments each cover the
        // cohort issued while their terminal was the active default. A project only resolves to `address(0)` here when
        // no default has ever been set.
        uint256 len = _defaultTerminalHistory.length;
        for (uint256 i; i < len; ++i) {
            DefaultTerminalSegment storage segment = _defaultTerminalHistory[i];
            if (projectId > segment.minProjectIdExclusive && projectId <= segment.maxProjectId) {
                return segment.terminal;
            }
        }
        return IJBTerminal(address(0));
    }

    /// @notice Resolve the effective terminal for a project. Falls back to the default that was current at the time
    /// the project ID range was active (NOT necessarily the registry-wide `defaultTerminal`, which only applies to
    /// projects with ID > `defaultTerminalProjectIdThreshold`).
    /// @param projectId The project to resolve the terminal for.
    /// @return terminal The project-specific terminal, or the threshold-resolved default.
    function _resolvedTerminalOf(uint256 projectId) internal view returns (IJBTerminal terminal) {
        // Start from the project-specific override, if one was configured.
        terminal = _terminalOf[projectId];

        // Fall back to the appropriate default for this project's ID cohort.
        if (terminal == IJBTerminal(address(0))) terminal = _defaultTerminalFor(projectId);
    }

    /// @notice Resolve the effective terminal for call paths that need to forward into a real terminal.
    /// @dev `terminalOf`/`defaultTerminalFor` return zero only when no default has ever been set. Transactional
    /// and passthrough view paths must fail before accepting funds or calling address(0).
    /// @param projectId The project to resolve the terminal for.
    /// @return terminal The project-specific terminal or threshold-resolved default.
    function _requireResolvedTerminalOf(uint256 projectId) internal view returns (IJBTerminal terminal) {
        terminal = _resolvedTerminalOf(projectId);
        if (terminal == IJBTerminal(address(0))) revert JBRouterTerminalRegistry_TerminalNotSet(projectId);
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Empty implementation to satisfy the interface.
    /// @param projectId The ID of the project whose contexts would otherwise be updated.
    /// @param accountingContexts Ignored because the registry delegates accounting contexts to the resolved terminal.
    function addAccountingContextsFor(
        uint256 projectId,
        JBAccountingContext[] calldata accountingContexts
    )
        external
        override
    {}

    /// @notice Add funds to a project's balance by forwarding them through the project's resolved router terminal.
    /// @dev Uses the project-specific terminal when set, otherwise falls back to `defaultTerminal`.
    /// @param projectId The ID of the project to add balance to.
    /// @param token The address of the token to pay in.
    /// @param amount The amount of tokens to send.
    /// @param shouldReturnHeldFees Whether held fees should be returned based on the amount added.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes in `JBMetadataResolver`'s format (may include `permit2` allowance data).
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
        // Resolve the terminal that should receive this forwarded add-to-balance call before accepting funds.
        IJBTerminal terminal = _requireResolvedTerminalOf(projectId);

        // Accept the funds for the token.
        amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});

        // Trigger any pre-transfer logic.
        uint256 payValue = _beforeTransferFor({to: address(terminal), token: token, amount: amount});

        // Save any previous payer so nested reentrant calls through pay hooks restore correctly.
        address previousPayer = originalPayer;

        // Store the original payer in transient storage so downstream router terminals can refund partial-fill
        // leftovers to the true payer. If the immediate caller is itself a forwarding intermediary that exposes
        // its own original payer, propagate that — otherwise refunds in nested forwards stop at the intermediary.
        originalPayer = _originalPayerOrSender();

        // Reject forwards that would bounce straight back into this call's immediate caller.
        _enforceNoCircularForward(terminal);

        // Forward to the resolved terminal.
        terminal.addToBalanceOf{value: payValue}({
            projectId: projectId,
            token: token,
            amount: amount,
            shouldReturnHeldFees: shouldReturnHeldFees,
            memo: memo,
            metadata: metadata
        });

        // Revoke any leftover allowance the terminal did not pull.
        if (token != JBConstants.NATIVE_TOKEN) IERC20(token).forceApprove({spender: address(terminal), value: 0});

        // Restore the previous payer (supports nested reentrant calls through pay hooks).
        originalPayer = previousPayer;
    }

    /// @notice Add a terminal to the allowlist so projects can select it as their router.
    /// @dev Only the registry owner can call this.
    /// @param terminal The terminal to allow.
    function allowTerminal(IJBTerminal terminal) external onlyOwner {
        // Mark the terminal as selectable for future project-level configuration.
        isTerminalAllowed[terminal] = true;

        // Emit the allowlist update for off-chain consumers and activity logs.
        emit JBRouterTerminalRegistry_AllowTerminal({terminal: terminal, caller: _msgSender()});
    }

    /// @notice Remove a terminal from the allowlist so no new projects can select it.
    /// @dev Only the registry owner can call this. Cannot disallow the current default terminal — call
    /// `setDefaultTerminal` to change the default first.
    /// @param terminal The terminal to disallow.
    function disallowTerminal(IJBTerminal terminal) external onlyOwner {
        // Prevent disallowing the current default terminal to avoid leaving the registry in a broken state.
        if (terminal == defaultTerminal) {
            revert JBRouterTerminalRegistry_CannotDisallowDefaultTerminal({terminal: terminal});
        }

        // Remove the terminal from the allowlist so future projects cannot select it.
        isTerminalAllowed[terminal] = false;

        // Emit the allowlist update for off-chain consumers and activity logs.
        emit JBRouterTerminalRegistry_DisallowTerminal({terminal: terminal, caller: _msgSender()});
    }

    /// @notice Permanently lock a project's router terminal choice so it can never be changed again.
    /// @dev Only the project's owner or an address with the `JBPermissionIds.SET_ROUTER_TERMINAL` permission can lock.
    /// @dev Circular or self-referential terminals are rejected before the irreversible lock is written.
    /// @param projectId The ID of the project to lock the terminal for.
    /// @param expectedTerminal The terminal the caller expects to lock. Prevents race conditions where the default
    /// changes between transaction submission and execution.
    function lockTerminalFor(uint256 projectId, IJBTerminal expectedTerminal) external {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_ROUTER_TERMINAL
        });

        // Require a non-zero terminal before locking. When no explicit override is set, snapshot
        // the THRESHOLD-RESOLVED default into _terminalOf so the lock captures the default that
        // currently applies to this specific project (NOT necessarily the registry-wide default).
        IJBTerminal terminal = _terminalOf[projectId];
        if (terminal == IJBTerminal(address(0))) {
            terminal = _defaultTerminalFor(projectId);
            if (terminal == IJBTerminal(address(0))) revert JBRouterTerminalRegistry_TerminalNotSet(projectId);
            _terminalOf[projectId] = terminal;
        }

        // Verify the resolved terminal matches what the caller expects to lock.
        if (terminal != expectedTerminal) {
            revert JBRouterTerminalRegistry_TerminalMismatch({
                currentTerminal: terminal, expectedTerminal: expectedTerminal
            });
        }

        // Reject a terminal that would make this irreversible lock forward back into the registry.
        _requireNonCircularTerminalFor({projectId: projectId, terminal: terminal});

        hasLockedTerminal[projectId] = true;

        emit JBRouterTerminalRegistry_LockTerminal({projectId: projectId, caller: _msgSender()});
    }

    /// @notice Always returns 0 because the registry holds no project balances to migrate.
    /// @param projectId Unused.
    /// @param token Unused.
    /// @param to Unused.
    /// @return balance Always 0.
    function migrateBalanceOf(
        uint256 projectId,
        address token,
        IJBTerminal to
    )
        external
        pure
        override
        returns (uint256)
    {
        projectId;
        token;
        to;
        return 0;
    }

    /// @notice Pay a project by accepting the caller's tokens and forwarding them to the project's resolved router
    /// terminal.
    /// @dev Uses the project-specific terminal when set, otherwise falls back to `defaultTerminal`.
    /// @param projectId The ID of the project to pay.
    /// @param token The address of the token to pay with.
    /// @param amount The amount of tokens to send.
    /// @param beneficiary The address that will receive any project tokens minted by the destination.
    /// @param minReturnedTokens The minimum number of project tokens expected in return.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes in `JBMetadataResolver`'s format (may include `permit2` allowance data).
    /// @return result The number of project tokens minted for the beneficiary.
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
        virtual
        override
        returns (uint256 result)
    {
        // Resolve the terminal that should receive this forwarded payment before accepting funds.
        IJBTerminal terminal = _requireResolvedTerminalOf(projectId);

        // Accept the funds for the token.
        amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});

        // Trigger any pre-transfer logic.
        uint256 payValue = _beforeTransferFor({to: address(terminal), token: token, amount: amount});

        // Save any previous payer so nested reentrant calls through pay hooks restore correctly.
        address previousPayer = originalPayer;

        // Store the original payer in transient storage so downstream router terminals can refund partial-fill
        // leftovers to the true payer. If the immediate caller is itself a forwarding intermediary that exposes
        // its own original payer, propagate that — otherwise refunds in nested forwards stop at the intermediary.
        originalPayer = _originalPayerOrSender();

        // Reject forwards that would bounce straight back into this call's immediate caller.
        _enforceNoCircularForward(terminal);

        // Forward the payment to the terminal.
        result = terminal.pay{value: payValue}({
            projectId: projectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: minReturnedTokens,
            memo: memo,
            metadata: metadata
        });

        // Revoke any leftover allowance the terminal did not pull.
        if (token != JBConstants.NATIVE_TOKEN) IERC20(token).forceApprove({spender: address(terminal), value: 0});

        // Restore the previous payer (supports nested reentrant calls through pay hooks).
        originalPayer = previousPayer;
    }

    /// @notice Change the registry-wide default terminal for projects created AFTER this call.
    /// @dev Only the registry owner can call this. Automatically allowlists the new default.
    /// The very first call also maps every project that already existed onto the new default (via a
    /// history segment) so those pre-existing projects — including the canonical fee project (ID 1) —
    /// can route tokens through it. Existing projects (ID <= current `PROJECTS.count()` at call time)
    /// keep their historical default on later changes — the previous `defaultTerminal` is pushed onto
    /// `_defaultTerminalHistory` so fall-through resolution for those projects continues to return what
    /// was current when their cohort was last addressed. This means a later default change never
    /// silently reroutes payments for already-deployed projects that never set an explicit
    /// `_terminalOf` override.
    /// @param terminal The terminal to set as the default for future projects.
    function setDefaultTerminal(IJBTerminal terminal) external onlyOwner {
        if (address(terminal) == address(0)) revert JBRouterTerminalRegistry_ZeroAddress(address(terminal));
        if (address(terminal) == address(this)) revert JBRouterTerminalRegistry_CircularForward(terminal);

        uint256 count = PROJECTS.count();

        // Reject defaults that would route any current project back into the registry through a
        // transitive forwarding chain. Probed at the current project-count snapshot since the
        // default is what unconfigured (and all-future) projects will resolve to.
        _requireNonCircularTerminalFor({projectId: count, terminal: terminal});

        // Record a history segment for the cohort whose IDs fall in the half-open range `(prevThreshold,
        // currentCount]`. On the first call ever (`defaultTerminal == 0`) the segment maps the projects that already
        // existed — including the canonical fee project (ID 1) — onto the NEW default so they can route tokens
        // through
        // it instead of resolving to nothing. On every later call the segment instead pins the OUTGOING default to its
        // own cohort, so projects whose IDs were issued while it was active keep resolving to it and a default change
        // never silently reroutes an already-deployed project.
        _defaultTerminalHistory.push(
            DefaultTerminalSegment({
                minProjectIdExclusive: defaultTerminalProjectIdThreshold,
                maxProjectId: count,
                terminal: address(defaultTerminal) != address(0) ? defaultTerminal : terminal
            })
        );

        defaultTerminal = terminal;
        defaultTerminalProjectIdThreshold = count;

        // Allow the default terminal.
        isTerminalAllowed[terminal] = true;

        emit JBRouterTerminalRegistry_SetDefaultTerminal({terminal: terminal, caller: _msgSender()});
    }

    /// @notice Choose which router terminal a project's payments are forwarded through.
    /// @dev Only the project's owner or an address with the `JBPermissionIds.SET_ROUTER_TERMINAL` permission can set.
    /// @param projectId The ID of the project to set the terminal for.
    /// @param terminal The terminal to set for the project.
    function setTerminalFor(uint256 projectId, IJBTerminal terminal) external {
        // Make sure the terminal is not locked.
        if (hasLockedTerminal[projectId]) revert JBRouterTerminalRegistry_TerminalLocked(projectId);

        if (!isTerminalAllowed[terminal]) revert JBRouterTerminalRegistry_TerminalNotAllowed(terminal);

        // Reject a terminal that would forward this project back into the registry before saving it.
        _requireNonCircularTerminalFor({projectId: projectId, terminal: terminal});

        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_ROUTER_TERMINAL
        });

        _terminalOf[projectId] = terminal;

        emit JBRouterTerminalRegistry_SetTerminal({projectId: projectId, terminal: terminal, caller: _msgSender()});
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Accept a token paid in by the caller.
    /// @dev Measures the actual received balance so forwarded amounts stay in sync with lossy ERC-20 transfers.
    /// @param token The address of the token to accept.
    /// @param amount The amount of tokens to accept.
    /// @param metadata The metadata in which `permit2` context is provided.
    /// @return amount The amount of tokens accepted.
    function _acceptFundsFor(address token, uint256 amount, bytes calldata metadata) internal returns (uint256) {
        // If native tokens are being paid in, return the `msg.value`.
        if (token == JBConstants.NATIVE_TOKEN) return msg.value;

        // Otherwise, the `msg.value` should be 0.
        if (msg.value != 0) revert JBRouterTerminalRegistry_NoMsgValueAllowed(msg.value);

        // Unpack the `JBSingleAllowance` to use given by the frontend.
        (bool exists, bytes memory parsedMetadata) =
            JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("permit2"), metadata: metadata});

        // If the metadata contained permit data, use it to set the allowance.
        if (exists) {
            // Keep a reference to the allowance context parsed from the metadata.
            (JBSingleAllowance memory allowance) = abi.decode(parsedMetadata, (JBSingleAllowance));

            // Make sure the permit allowance is enough for this payment.
            if (amount > allowance.amount) {
                revert JBRouterTerminalRegistry_PermitAllowanceNotEnough({
                    amount: amount, allowanceAmount: allowance.amount
                });
            }

            // Keep a reference to the permit rules.
            IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
                details: IAllowanceTransfer.PermitDetails({
                    token: token, amount: allowance.amount, expiration: allowance.expiration, nonce: allowance.nonce
                }),
                spender: address(this),
                sigDeadline: allowance.sigDeadline
            });

            try PERMIT2.permit({owner: _msgSender(), permitSingle: permitSingle, signature: allowance.signature}) {}
            catch (bytes memory reason) {
                // Emit a failure event so callers can surface the permit2 error reason.
                emit Permit2AllowanceFailed({token: token, owner: _msgSender(), reason: reason, caller: _msgSender()});
            }
        }

        // Measure the actual received balance so downstream forwarding uses what arrived, not the caller's nominal
        // amount.
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // Transfer the tokens from the `_msgSender()` to this terminal.
        _transferFrom({from: _msgSender(), to: payable(address(this)), token: token, amount: amount});

        return IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    /// @notice Logic to trigger before transferring tokens from this terminal.
    /// @param to The address to transfer tokens to.
    /// @param token The token to transfer.
    /// @param amount The amount of tokens to transfer.
    /// @return payValue The amount that will be paid as a `msg.value`.
    function _beforeTransferFor(address to, address token, uint256 amount) internal virtual returns (uint256) {
        // If the token is the native token, return early.
        if (token == JBConstants.NATIVE_TOKEN) return amount;

        // Reset-then-set: avoid reverts from tokens that disallow non-zero to non-zero approval changes.
        IERC20(token).forceApprove({spender: to, value: amount});

        return 0;
    }

    /// @notice Transfer tokens from one address to another using direct approval, `safeTransfer`, or Permit2 fallback.
    /// @param from The address to transfer tokens from.
    /// @param to The address to transfer tokens to.
    /// @param token The address of the token to transfer.
    /// @param amount The amount of tokens to transfer.
    function _transferFrom(address from, address payable to, address token, uint256 amount) internal virtual {
        if (from == address(this)) {
            // If the token is native token, assume the `sendValue` standard.
            if (token == JBConstants.NATIVE_TOKEN) return Address.sendValue({recipient: to, amount: amount});

            // If the transfer is from this terminal, use `safeTransfer`.
            return IERC20(token).safeTransfer({to: to, value: amount});
        }

        // If there's sufficient approval, transfer normally.
        if (IERC20(token).allowance({owner: address(from), spender: address(this)}) >= amount) {
            return IERC20(token).safeTransferFrom({from: from, to: to, value: amount});
        }

        // Otherwise, attempt to use the `permit2` method.
        if (amount > type(uint160).max) revert JBRouterTerminalRegistry_AmountOverflow(amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        PERMIT2.transferFrom({from: from, to: to, amount: uint160(amount), token: token});
    }
}
