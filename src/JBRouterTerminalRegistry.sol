// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPermitTerminal} from "@bananapus/core-v6/src/interfaces/IJBPermitTerminal.sol";
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
import {IJBRouterTerminalRegistry} from "./interfaces/IJBRouterTerminalRegistry.sol";
import {IJBPayerTracker} from "./interfaces/IJBPayerTracker.sol";

/// @notice A forwarding layer that lets each project choose which router terminal receives its payments, with an
/// owner-managed default for projects that have not opted in. Projects can lock their choice to guarantee permanence.
contract JBRouterTerminalRegistry is IJBRouterTerminalRegistry, JBPermissioned, Ownable, ERC2771Context {
    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBRouterTerminalRegistry_AmountOverflow();
    error JBRouterTerminalRegistry_CannotDisallowDefaultTerminal(IJBTerminal terminal);
    error JBRouterTerminalRegistry_CircularForward(IJBTerminal terminal);
    error JBRouterTerminalRegistry_NoMsgValueAllowed(uint256 value);
    error JBRouterTerminalRegistry_PermitAllowanceNotEnough(uint256 amount, uint256 allowanceAmount);
    error JBRouterTerminalRegistry_TerminalLocked(uint256 projectId);
    error JBRouterTerminalRegistry_TerminalMismatch(IJBTerminal currentTerminal, IJBTerminal expectedTerminal);
    error JBRouterTerminalRegistry_TerminalNotAllowed(IJBTerminal terminal);
    error JBRouterTerminalRegistry_TerminalNotSet(uint256 projectId);
    error JBRouterTerminalRegistry_ZeroAddress();

    //*********************************************************************//
    // -------------------- public immutable properties ------------------ //
    //*********************************************************************//

    /// @notice The project registry.
    IJBProjects public immutable override PROJECTS;

    /// @notice The permit2 utility.
    IPermit2 public immutable override PERMIT2;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The default terminal to use.
    IJBTerminal public override defaultTerminal;

    /// @notice Whether the terminal for a given project has been locked against future updates.
    /// @custom:param projectId The ID of the project whose lock state is being tracked.
    mapping(uint256 projectId => bool) public override hasLockedTerminal;

    /// @notice Whether a terminal is allowlisted for project-level selection.
    /// @custom:param terminal The terminal whose allowlist status is being tracked.
    mapping(IJBTerminal terminal => bool) public override isTerminalAllowed;

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice The terminal explicitly configured for a project before default-terminal fallback is applied.
    /// @custom:param projectId The ID of the project whose explicit terminal assignment is being tracked.
    mapping(uint256 projectId => IJBTerminal) internal _terminalOf;

    //*********************************************************************//
    // -------------------- transient stored properties ------------------ //
    //*********************************************************************//

    /// @inheritdoc IJBPayerTracker
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
        // Get the terminal for the project (falls back to default).
        IJBTerminal terminal = _terminalOf[projectId];
        if (terminal == IJBTerminal(address(0))) terminal = defaultTerminal;

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
        // Get the terminal for the project (falls back to default).
        IJBTerminal terminal = _terminalOf[projectId];
        if (terminal == IJBTerminal(address(0))) terminal = defaultTerminal;

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

    /// @notice Preview a payment by forwarding the call to the terminal currently resolved for the project.
    /// @dev Uses the project-specific terminal when set, otherwise falls back to `defaultTerminal`.
    /// @param projectId The ID of the project being paid.
    /// @param token The token that would be paid into the resolved terminal.
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
        // Read the terminal explicitly configured for this project, if any.
        IJBTerminal terminal = _terminalOf[projectId];

        // If the project has not pinned a terminal, use the registry-wide default terminal instead.
        if (terminal == IJBTerminal(address(0))) terminal = defaultTerminal;

        // Forward the preview request unchanged to whichever terminal was resolved above.
        // slither-disable-next-line unused-return
        return terminal.previewPayFor({
            projectId: projectId, token: token, amount: amount, beneficiary: beneficiary, metadata: metadata
        });
    }

    /// @inheritdoc IJBForwardingTerminal
    function terminalOf(uint256 projectId) external view override returns (IJBTerminal terminal) {
        return _resolvedTerminalOf(projectId);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Whether the registry supports a given interface ID.
    /// @param interfaceId The interface ID to check.
    /// @return supported A flag indicating whether `interfaceId` is implemented.
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
    /// @param terminal The terminal the registry is about to forward into.
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

    /// @notice Reject terminal choices that would forward the project back into this registry.
    /// @param projectId The project whose forwarding target is being validated.
    /// @param terminal The terminal being configured or locked.
    function _requireNonCircularTerminalFor(uint256 projectId, IJBTerminal terminal) internal view {
        // Reject direct self-selection so the registry cannot forward a project to itself.
        if (address(terminal) == address(this)) revert JBRouterTerminalRegistry_CircularForward(terminal);

        // Externally owned accounts cannot implement `terminalOf`, so there is no forwarding route to inspect.
        if (address(terminal).code.length == 0) return;

        // If the candidate is another forwarding terminal, ask where this project would end up.
        try IJBForwardingTerminal(address(terminal)).terminalOf({projectId: projectId}) returns (
            IJBTerminal downstreamTerminal
        ) {
            // Reject one-hop forwarding cycles that bounce this project back into the registry.
            if (address(downstreamTerminal) == address(this)) {
                revert JBRouterTerminalRegistry_CircularForward(terminal);
            }
        } catch {
            // Non-forwarding terminals are valid choices; failed interface probes should not block them.
        }
    }

    /// @notice Resolve the effective terminal for a project, falling back to the default terminal when unset.
    /// @param projectId The project whose terminal should be resolved.
    /// @return terminal The project-specific terminal, or the default terminal if no override exists.
    function _resolvedTerminalOf(uint256 projectId) internal view returns (IJBTerminal terminal) {
        // Start from the project-specific override, if one was configured.
        terminal = _terminalOf[projectId];

        // Fall back to the default terminal when no project-specific terminal has been set.
        if (terminal == IJBTerminal(address(0))) terminal = defaultTerminal;
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
    /// @param projectId The ID of the project receiving the balance addition.
    /// @param token The address of the token being paid in.
    /// @param amount The amount of tokens being paid in.
    /// @param shouldReturnHeldFees Whether held fees should be returned based on the amount added.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes in `JBMetadataResolver`'s format (may include `permit2` allowance data).
    // slither-disable-next-line reentrancy-benign,reentrancy-eth
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
        // Resolve the terminal that should receive this forwarded add-to-balance call.
        IJBTerminal terminal = _resolvedTerminalOf(projectId);

        // Accept the funds for the token.
        amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});

        // Trigger any pre-transfer logic.
        uint256 payValue = _beforeTransferFor({to: address(terminal), token: token, amount: amount});

        // Save any previous payer so nested reentrant calls through pay hooks restore correctly.
        address previousPayer = originalPayer;

        // Store the original payer in transient storage so downstream router terminals can refund partial-fill
        // leftovers to the true payer.
        originalPayer = _msgSender();

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

        // Emit the allowlist update for off-chain consumers and audit trails.
        emit JBRouterTerminalRegistry_AllowTerminal(terminal, _msgSender());
    }

    /// @notice Remove a terminal from the allowlist so no new projects can select it.
    /// @dev Only the registry owner can call this. Cannot disallow the current default terminal — call
    /// `setDefaultTerminal` to change the default first.
    /// @param terminal The terminal to disallow.
    function disallowTerminal(IJBTerminal terminal) external onlyOwner {
        // Prevent disallowing the current default terminal to avoid leaving the registry in a broken state.
        if (terminal == defaultTerminal) {
            revert JBRouterTerminalRegistry_CannotDisallowDefaultTerminal(terminal);
        }

        // Remove the terminal from the allowlist so future projects cannot select it.
        isTerminalAllowed[terminal] = false;

        // Emit the allowlist update for off-chain consumers and audit trails.
        emit JBRouterTerminalRegistry_DisallowTerminal(terminal, _msgSender());
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

        // Require a non-zero terminal before locking.
        IJBTerminal terminal = _terminalOf[projectId];
        if (terminal == IJBTerminal(address(0))) {
            terminal = defaultTerminal;
            if (terminal == IJBTerminal(address(0))) revert JBRouterTerminalRegistry_TerminalNotSet(projectId);
            _terminalOf[projectId] = terminal;
        }

        // Verify the resolved terminal matches what the caller expects to lock.
        if (terminal != expectedTerminal) {
            revert JBRouterTerminalRegistry_TerminalMismatch(terminal, expectedTerminal);
        }

        // Reject a terminal that would make this irreversible lock forward back into the registry.
        _requireNonCircularTerminalFor({projectId: projectId, terminal: terminal});

        hasLockedTerminal[projectId] = true;

        emit JBRouterTerminalRegistry_LockTerminal(projectId, _msgSender());
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
    /// @param projectId The ID of the project being paid.
    /// @param token The address of the token being paid in.
    /// @param amount The amount of tokens being paid in.
    /// @param beneficiary The address that will receive any project tokens minted by the destination.
    /// @param minReturnedTokens The minimum number of project tokens expected in return.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes in `JBMetadataResolver`'s format (may include `permit2` allowance data).
    /// @return result The number of project tokens minted for the beneficiary.
    // slither-disable-next-line reentrancy-benign,reentrancy-eth
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
        // Resolve the terminal that should receive this forwarded payment.
        IJBTerminal terminal = _resolvedTerminalOf(projectId);

        // Accept the funds for the token.
        amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});

        // Trigger any pre-transfer logic.
        uint256 payValue = _beforeTransferFor({to: address(terminal), token: token, amount: amount});

        // Save any previous payer so nested reentrant calls through pay hooks restore correctly.
        address previousPayer = originalPayer;

        // Store the original payer in transient storage so downstream router terminals can refund partial-fill
        // leftovers to the true payer.
        originalPayer = _msgSender();

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

    /// @notice Change the registry-wide default terminal that all projects without an explicit override will use.
    /// @dev Only the registry owner can call this. Automatically allowlists the new default.
    /// @param terminal The terminal to set as the default.
    function setDefaultTerminal(IJBTerminal terminal) external onlyOwner {
        if (address(terminal) == address(0)) revert JBRouterTerminalRegistry_ZeroAddress();
        if (address(terminal) == address(this)) revert JBRouterTerminalRegistry_CircularForward(terminal);

        defaultTerminal = terminal;

        // Allow the default terminal.
        isTerminalAllowed[terminal] = true;

        emit JBRouterTerminalRegistry_SetDefaultTerminal(terminal, _msgSender());
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

        emit JBRouterTerminalRegistry_SetTerminal(projectId, terminal, _msgSender());
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Accepts a token being paid in.
    /// @dev Measures the actual received balance so forwarded amounts stay in sync with lossy ERC-20 transfers.
    /// @param token The address of the token being paid in.
    /// @param amount The amount of tokens being paid in.
    /// @param metadata The metadata in which `permit2` context is provided.
    /// @return amount The amount of tokens that have been accepted.
    // slither-disable-next-line reentrancy-events
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
                revert JBRouterTerminalRegistry_PermitAllowanceNotEnough(amount, allowance.amount);
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
                emit IJBPermitTerminal.Permit2AllowanceFailed(token, _msgSender(), reason);
            }
        }

        // Measure the actual received balance so downstream forwarding uses what arrived, not the caller's nominal
        // amount.
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // Transfer the tokens from the `_msgSender()` to this terminal.
        _transferFrom({from: _msgSender(), to: payable(address(this)), token: token, amount: amount});

        return IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    /// @notice Logic to be triggered before transferring tokens from this terminal.
    /// @param to The address to transfer tokens to.
    /// @param token The token being transferred.
    /// @param amount The amount of tokens to transfer.
    /// @return payValue The amount that'll be paid as a `msg.value`.
    function _beforeTransferFor(address to, address token, uint256 amount) internal virtual returns (uint256) {
        // If the token is the native token, return early.
        if (token == JBConstants.NATIVE_TOKEN) return amount;

        // Reset-then-set: avoid reverts from tokens that disallow non-zero to non-zero approval changes.
        IERC20(token).forceApprove({spender: to, value: amount});

        return 0;
    }

    /// @notice Transfer tokens from one address to another using direct approval, `safeTransfer`, or Permit2 as a
    /// fallback.
    /// @param from The address to transfer tokens from.
    /// @param to The address to transfer tokens to.
    /// @param token The address of the token being transferred.
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
        if (amount > type(uint160).max) revert JBRouterTerminalRegistry_AmountOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        PERMIT2.transferFrom({from: from, to: to, amount: uint160(amount), token: token});
    }
}
