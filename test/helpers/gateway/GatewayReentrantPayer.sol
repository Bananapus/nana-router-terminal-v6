// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBRouterTerminalGateway} from "../../../src/JBRouterTerminalGateway.sol";

import {GatewayCallbackToken} from "./GatewayCallbackToken.sol";

import {IGatewayTokenTransferCallback} from "./IGatewayTokenTransferCallback.sol";

/// @notice Attempts a second payment while a token callback interrupts the first gateway intake.
contract GatewayReentrantPayer is IGatewayTokenTransferCallback {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the callback comes from any caller except the configured payment token.
    /// @param caller The account invoking the callback.
    /// @param expectedToken The payment token permitted to invoke the callback.
    error GatewayReentrantPayer_UnauthorizedCallback(address caller, address expectedToken);

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The project whose metadata opts both fee calls into retention.
    uint256 internal constant _SOURCE_PROJECT_ID = 2;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The gateway receiving both the outer payment and attempted nested intake.
    JBRouterTerminalGateway public gateway;

    /// @notice The input amount submitted by each payment call.
    uint256 public reentryAmount;

    /// @notice Whether the gateway rejected the nested intake during the token callback.
    bool public reentryReverted;

    /// @notice The payment token invoking the intake callback.
    GatewayCallbackToken public token;

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Starts a payment whose incoming token transfer attempts another retained payment.
    /// @param gatewayToUse The gateway accepting payment tokens.
    /// @param tokenToUse The payment token that invokes the intake callback.
    /// @param amount The input amount submitted by each of the two attempted payments.
    function attack(JBRouterTerminalGateway gatewayToUse, GatewayCallbackToken tokenToUse, uint256 amount) external {
        gateway = gatewayToUse;
        token = tokenToUse;
        reentryAmount = amount;

        // Approve both amounts so allowance failure cannot masquerade as protection against nested intake.
        tokenToUse.approve({spender: address(gatewayToUse), value: amount * 2});
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

    /// @notice Attempts a retained payment before the outer token transfer finishes.
    /// @dev Catches the gateway guard's failure so the outer transfer can finish and its custody can be measured.
    function beforeGatewayTokenTransfer() external {
        if (msg.sender != address(token)) {
            revert GatewayReentrantPayer_UnauthorizedCallback({caller: msg.sender, expectedToken: address(token)});
        }

        // A successful nested deposit would enter the balance delta measured for the outer deposit as well.
        try gateway.pay({
            projectId: 1,
            token: address(token),
            amount: reentryAmount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(_SOURCE_PROJECT_ID)
        }) returns (
            uint256
        ) {}
        catch {
            reentryReverted = true;
        }
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Identifies this payer as a terminal for gateway payer-resolution checks.
    /// @param interfaceId The interface being queried.
    /// @return supported Whether the query is for the terminal or ERC-165 interface.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool supported) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
