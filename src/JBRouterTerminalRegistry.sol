// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPermitTerminal} from "@bananapus/core-v6/src/interfaces/IJBPermitTerminal.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";

import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBPayerTracker} from "./interfaces/IJBPayerTracker.sol";
import {IJBRouterTerminalRegistry} from "./interfaces/IJBRouterTerminalRegistry.sol";

contract JBRouterTerminalRegistry is IJBRouterTerminalRegistry, JBPermissioned, Ownable, ERC2771Context {
    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBRouterTerminalRegistry_AmountOverflow();
    error JBRouterTerminalRegistry_CannotDisallowDefaultTerminal(IJBTerminal terminal);
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

    /// @notice Whether the terminal for the given project is locked.
    /// @custom:param projectId The ID of the project to get the locked terminal for.
    mapping(uint256 projectId => bool) public override hasLockedTerminal;

    /// @notice Whether the given terminal is allowed to be set for projects.
    /// @custom:param terminal The terminal to check.
    mapping(IJBTerminal terminal => bool) public override isTerminalAllowed;

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice The terminal explicitly set for the given project.
    /// @custom:param projectId The ID of the project to get the terminal for.
    mapping(uint256 projectId => IJBTerminal) internal _terminalOf;

    //*********************************************************************//
    // -------------------- transient stored properties ------------------ //
    //*********************************************************************//

    /// @inheritdoc IJBPayerTracker
    address public transient override originalPayer;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

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
    // ------------------------- receive -------------------------------- //
    //*********************************************************************//

    /// @notice Accept native token refunds from the router on partial swap fills.
    receive() external payable {}

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

    /// @notice Empty implementation to satisfy the interface. This terminal has no surplus.
    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external pure override returns (uint256) {}

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

    /// @notice The terminal for the given project, or the default terminal if none is set.
    /// @param projectId The ID of the project to get the terminal for.
    /// @return terminal The terminal for the project.
    function terminalOf(uint256 projectId) external view override returns (IJBTerminal terminal) {
        terminal = _terminalOf[projectId];
        if (terminal == IJBTerminal(address(0))) terminal = defaultTerminal;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBRouterTerminalRegistry).interfaceId
            || interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
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

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Empty implementation to satisfy the interface.
    function addAccountingContextsFor(
        uint256 projectId,
        JBAccountingContext[] calldata accountingContexts
    )
        external
        override
    {}

    /// @notice Accepts funds for a given project and adds them to the project's balance in the resolved terminal.
    /// @param projectId The ID of the project for which funds are being accepted.
    /// @param token The address of the token being paid in.
    /// @param amount The amount of tokens being paid in.
    /// @param shouldReturnHeldFees A boolean to indicate whether held fees should be returned.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes in `JBMetadataResolver`'s format.
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
        // Get the terminal for the project (falls back to default).
        IJBTerminal terminal = _terminalOf[projectId];
        if (terminal == IJBTerminal(address(0))) terminal = defaultTerminal;

        // Accept the funds for the token.
        amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});

        // Trigger any pre-transfer logic.
        uint256 payValue = _beforeTransferFor({to: address(terminal), token: token, amount: amount});

        // Store the original payer in transient storage so downstream router terminals can refund partial-fill
        // leftovers to the true payer.
        _setOriginalPayer(_msgSender());

        // Forward to the resolved terminal.
        terminal.addToBalanceOf{value: payValue}({
            projectId: projectId,
            token: token,
            amount: amount,
            shouldReturnHeldFees: shouldReturnHeldFees,
            memo: memo,
            metadata: metadata
        });

        // Clear transient storage.
        _setOriginalPayer(address(0));
    }

    /// @notice Allow a terminal.
    /// @dev Only the owner can allow a terminal.
    /// @param terminal The terminal to allow.
    function allowTerminal(IJBTerminal terminal) external onlyOwner {
        isTerminalAllowed[terminal] = true;

        emit JBRouterTerminalRegistry_AllowTerminal(terminal, _msgSender());
    }

    /// @notice Disallow a terminal.
    /// @dev Only the owner can disallow a terminal. Cannot disallow the current default terminal — call
    /// `setDefaultTerminal` to change the default first.
    /// @param terminal The terminal to disallow.
    function disallowTerminal(IJBTerminal terminal) external onlyOwner {
        // Prevent disallowing the current default terminal to avoid leaving the registry in a broken state.
        if (terminal == defaultTerminal) {
            revert JBRouterTerminalRegistry_CannotDisallowDefaultTerminal(terminal);
        }

        isTerminalAllowed[terminal] = false;

        emit JBRouterTerminalRegistry_DisallowTerminal(terminal, _msgSender());
    }

    /// @notice Lock a terminal for a project.
    /// @dev Only the project's owner or an address with the `JBPermissionIds.SET_ROUTER_TERMINAL` permission can lock.
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

        hasLockedTerminal[projectId] = true;

        emit JBRouterTerminalRegistry_LockTerminal(projectId, _msgSender());
    }

    /// @notice Empty implementation to satisfy the interface.
    function migrateBalanceOf(
        uint256 projectId,
        address token,
        IJBTerminal to
    )
        external
        override
        returns (uint256 balance)
    {}

    /// @notice Pay a project by forwarding the payment to the resolved terminal.
    /// @param projectId The ID of the project being paid.
    /// @param token The address of the token being paid in.
    /// @param amount The amount of tokens being paid in.
    /// @param beneficiary The beneficiary address to pass along.
    /// @param minReturnedTokens The minimum number of project tokens expected in return.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes in `JBMetadataResolver`'s format.
    /// @return result The number of tokens received.
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
        // Get the terminal for the project (falls back to default).
        IJBTerminal terminal = _terminalOf[projectId];
        if (terminal == IJBTerminal(address(0))) terminal = defaultTerminal;

        // Accept the funds for the token.
        amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});

        // Trigger any pre-transfer logic.
        uint256 payValue = _beforeTransferFor({to: address(terminal), token: token, amount: amount});

        // Store the original payer in transient storage so downstream router terminals can refund partial-fill
        // leftovers to the true payer.
        _setOriginalPayer(_msgSender());

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

        // Clear transient storage.
        _setOriginalPayer(address(0));
    }

    /// @notice Set the default terminal.
    /// @dev Only the owner can set the default terminal.
    /// @param terminal The terminal to set as the default.
    function setDefaultTerminal(IJBTerminal terminal) external onlyOwner {
        if (address(terminal) == address(0)) revert JBRouterTerminalRegistry_ZeroAddress();

        defaultTerminal = terminal;

        // Allow the default terminal.
        isTerminalAllowed[terminal] = true;

        emit JBRouterTerminalRegistry_SetDefaultTerminal(terminal, _msgSender());
    }

    /// @notice Set the terminal for a project.
    /// @dev Only the project's owner or an address with the `JBPermissionIds.SET_ROUTER_TERMINAL` permission can set.
    /// @param projectId The ID of the project to set the terminal for.
    /// @param terminal The terminal to set for the project.
    function setTerminalFor(uint256 projectId, IJBTerminal terminal) external {
        // Make sure the terminal is not locked.
        if (hasLockedTerminal[projectId]) revert JBRouterTerminalRegistry_TerminalLocked(projectId);

        if (!isTerminalAllowed[terminal]) revert JBRouterTerminalRegistry_TerminalNotAllowed(terminal);

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

    /// @notice Write the original payer to transient storage.
    /// @param payer The address to store, or `address(0)` to clear.
    function _setOriginalPayer(address payer) internal {
        originalPayer = payer;
    }

    /// @notice Accepts a token being paid in.
    /// @dev Fee-on-transfer tokens are not supported. The returned amount assumes 1:1 transfer without fees.
    /// @param token The address of the token being paid in.
    /// @param amount The amount of tokens being paid in.
    /// @param metadata The metadata in which `permit2` context is provided.
    /// @return amount The amount of tokens that have been accepted.
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

        // Fee-on-transfer tokens are not supported by design. The router uses balance-delta
        // checks for its own accounting but relies on underlying terminal behavior for FoT tokens. Projects
        // should avoid configuring FoT tokens.
        // Transfer the tokens from the `_msgSender()` to this terminal.
        _transferFrom({from: _msgSender(), to: payable(address(this)), token: token, amount: amount});

        return amount;
    }

    /// @notice Logic to be triggered before transferring tokens from this terminal.
    /// @param to The address to transfer tokens to.
    /// @param token The token being transferred.
    /// @param amount The amount of tokens to transfer.
    /// @return payValue The amount that'll be paid as a `msg.value`.
    function _beforeTransferFor(address to, address token, uint256 amount) internal virtual returns (uint256) {
        // If the token is the native token, return early.
        if (token == JBConstants.NATIVE_TOKEN) return amount;

        // Otherwise, set the appropriate allowance for the recipient.
        IERC20(token).safeIncreaseAllowance({spender: to, value: amount});

        return 0;
    }

    /// @notice Transfers tokens.
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
