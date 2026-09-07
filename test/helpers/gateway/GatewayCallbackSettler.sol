// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBRouterTerminalGateway} from "../../../src/JBRouterTerminalGateway.sol";

import {JBPendingRouterTerminalCall} from "../../../src/structs/JBPendingRouterTerminalCall.sol";

import {GatewayCallbackToken} from "./GatewayCallbackToken.sol";

import {IGatewayTokenTransferCallback} from "./IGatewayTokenTransferCallback.sol";

/// @notice Attempts to settle a pending call while a token callback interrupts a separate gateway intake.
contract GatewayCallbackSettler is IGatewayTokenTransferCallback {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the callback comes from any caller except the configured payment token.
    /// @param caller The account invoking the callback.
    /// @param expectedToken The payment token permitted to invoke the callback.
    error GatewayCallbackSettler_UnauthorizedCallback(address caller, address expectedToken);

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The project authenticated by the pending call's fee metadata.
    uint256 internal constant _SOURCE_PROJECT_ID = 2;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The gateway holding the pending call and accepting the separate incoming payment.
    JBRouterTerminalGateway public gateway;

    /// @notice The authenticated pending operation whose custody the callback attempts to spend.
    JBPendingRouterTerminalCall public pending;

    /// @notice Whether the gateway rejected settlement inside token intake.
    bool public settlementReverted;

    /// @notice The payment token shared by the pending claim and the incoming payment.
    GatewayCallbackToken public token;

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Attempts to spend existing custody before the incoming token transfer changes balances.
    /// @dev The failure is caught so the incoming deposit can complete independently of the rejected settlement.
    function beforeGatewayTokenTransfer() external {
        if (msg.sender != address(token)) {
            revert GatewayCallbackSettler_UnauthorizedCallback({caller: msg.sender, expectedToken: address(token)});
        }

        // Spending pending custody here would understate the balance delta attributed to the separate deposit.
        try gateway.processPendingCall({
            id: bytes32(uint256(1)), call: pending, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)
        }) returns (
            uint256
        ) {}
        catch {
            settlementReverted = true;
        }
    }

    /// @notice Starts a payment whose token callback tries to settle a separate pending claim.
    /// @param gatewayToUse The gateway holding and accepting the payment token.
    /// @param tokenToUse The payment token invoking the intake callback.
    /// @param pendingCall The first pending operation authenticated by the fixture's source-project metadata.
    /// @param amount The number of tokens to pay in the separate incoming payment.
    function deposit(
        JBRouterTerminalGateway gatewayToUse,
        GatewayCallbackToken tokenToUse,
        JBPendingRouterTerminalCall calldata pendingCall,
        uint256 amount
    )
        external
    {
        gateway = gatewayToUse;
        token = tokenToUse;
        pending = pendingCall;

        // Fund the full incoming payment so only the intake guard can prevent the callback's custody outflow.
        tokenToUse.approve({spender: address(gatewayToUse), value: amount});
        gatewayToUse.pay({
            projectId: 1,
            token: address(tokenToUse),
            amount: amount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(_SOURCE_PROJECT_ID)
        });
    }
}
