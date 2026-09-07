// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Models a source terminal that forgives failed fees and nullifies failed project payouts.
contract GatewayTestSourceTerminal {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the native value differs from the reported refund amount.
    /// @param value The native value received.
    /// @param amount The reported refund amount.
    error GatewayTestSourceTerminal_NativeAmountMismatch(uint256 value, uint256 amount);

    /// @notice Thrown when refunds are disabled to model a source terminal rejecting recovery.
    error GatewayTestSourceTerminal_RefundRejected();

    /// @notice Thrown when the refund token declines the source terminal's transfer.
    /// @param token The refund token.
    /// @param amount The requested refund amount.
    error GatewayTestSourceTerminal_TransferFailed(address token, uint256 amount);

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The amount credited to each project for each token.
    /// @dev Credited only after the terminal accepts the corresponding refund funds.
    /// @custom:param projectId The project receiving the credit.
    /// @custom:param token The credited token.
    mapping(uint256 projectId => mapping(address token => uint256 amount)) public credited;

    /// @notice Whether the most recent protocol-fee payment reverted and was forgiven.
    bool public feeWasForgiven;

    /// @notice Whether the most recent project payout reverted and was nullified.
    bool public payoutWasNullified;

    /// @notice Whether the terminal rejects incoming refund credits.
    bool public rejectRefund;

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Accept native funds used by the payout and fee fixtures.
    receive() external payable {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Accept a refund and credit its value to the source project.
    /// @dev The fourth, fifth, and sixth arguments are the unused held-fee preference, memo, and metadata.
    /// Their ABI positions match the terminal interface.
    /// @param projectId The project receiving the refund credit.
    /// @param token The refunded token.
    /// @param amount The amount to accept and credit.
    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
    {
        // Reject before accepting funds so the gateway retains custody when this recovery destination is unavailable.
        if (rejectRefund) revert GatewayTestSourceTerminal_RefundRejected();

        // Require actual custody before crediting the project ledger.
        if (token == JBConstants.NATIVE_TOKEN) {
            if (msg.value != amount) revert GatewayTestSourceTerminal_NativeAmountMismatch(msg.value, amount);
        } else {
            if (!IERC20(token).transferFrom({from: msg.sender, to: address(this), value: amount})) {
                revert GatewayTestSourceTerminal_TransferFailed(token, amount);
            }
        }
        credited[projectId][token] += amount;
    }

    /// @notice Attempt a protocol-fee payment and record whether the fee was forgiven.
    /// @param feeTerminal The terminal receiving the protocol fee.
    /// @param token The fee token.
    /// @param amount The amount to pay.
    /// @param sourceProjectId The source project encoded in the payment metadata.
    function payFee(IJBTerminal feeTerminal, address token, uint256 amount, uint256 sourceProjectId) external {
        uint256 value = _beforeCall({terminal: feeTerminal, token: token, amount: amount});

        // Catch the external payment so a failing fee does not revert its originating protocol operation.
        try feeTerminal.pay{value: value}({
            projectId: JBConstants.FEE_BENEFICIARY_PROJECT_ID,
            token: token,
            amount: amount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(sourceProjectId)
        }) returns (
            uint256
        ) {
            feeWasForgiven = false;
        } catch {
            feeWasForgiven = true;
        }
    }

    /// @notice Attempt a project payout and record whether its failure nullified the payout.
    /// @param terminal The terminal receiving the payout.
    /// @param destinationProjectId The project receiving the payout.
    /// @param token The payout token.
    /// @param amount The amount to pay.
    /// @param sourceProjectId The source project encoded in the payout metadata.
    /// @param preferAddToBalance Whether the payout should credit the destination balance without minting tokens.
    function sendPayout(
        IJBTerminal terminal,
        uint256 destinationProjectId,
        address token,
        uint256 amount,
        uint256 sourceProjectId,
        bool preferAddToBalance
    )
        external
    {
        uint256 value = _beforeCall({terminal: terminal, token: token, amount: amount});

        // Both payout shapes catch destination failure to model the source terminal's payout recovery boundary.
        if (preferAddToBalance) {
            try terminal.addToBalanceOf{value: value}({
                projectId: destinationProjectId,
                token: token,
                amount: amount,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: abi.encodePacked(sourceProjectId)
            }) {
                payoutWasNullified = false;
            } catch {
                payoutWasNullified = true;
            }
        } else {
            try terminal.pay{value: value}({
                projectId: destinationProjectId,
                token: token,
                amount: amount,
                beneficiary: address(this),
                minReturnedTokens: 0,
                memo: "",
                metadata: abi.encodePacked(sourceProjectId)
            }) returns (
                uint256
            ) {
                payoutWasNullified = false;
            } catch {
                payoutWasNullified = true;
            }
        }
    }

    /// @notice Configure whether the terminal accepts refund credits.
    /// @param flag Whether refund calls should revert.
    function setRejectRefund(bool flag) external {
        rejectRefund = flag;
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Whether this fixture advertises the requested interface.
    /// @param interfaceId The interface identifier to check.
    /// @return flag Whether the identifier is the terminal or ERC165 interface.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool flag) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Prepare payment funds for a terminal call.
    /// @param terminal The terminal receiving the funds.
    /// @param token The payment token.
    /// @param amount The amount to make available.
    /// @return value The native value to attach to the call, or zero for an ERC20 payment.
    function _beforeCall(IJBTerminal terminal, address token, uint256 amount) internal returns (uint256 value) {
        // Native funds travel with the call; ERC20 funds are pulled by the destination terminal.
        if (token == JBConstants.NATIVE_TOKEN) return amount;
        IERC20(token).approve({spender: address(terminal), value: amount});
    }
}
