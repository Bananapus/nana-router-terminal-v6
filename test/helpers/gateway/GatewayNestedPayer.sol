// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBRouterTerminalGateway} from "../../../src/JBRouterTerminalGateway.sol";

import {GatewayTestRouter} from "./GatewayTestRouter.sol";
import {GatewayTestToken} from "./GatewayTestToken.sol";

import {IGatewayRouterCallback} from "./IGatewayRouterCallback.sol";

/// @notice Starts a nested gateway payment before the router pulls an outer payment's tokens.
contract GatewayNestedPayer is IGatewayRouterCallback {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a callback comes from any caller except the configured router.
    /// @param caller The account invoking the callback.
    /// @param expectedRouter The router permitted to start a nested payment.
    error GatewayNestedPayer_UnauthorizedCallback(address caller, address expectedRouter);

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The project whose metadata opts the nested fee into retention.
    uint256 internal constant _SOURCE_PROJECT_ID = 2;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The input amount paid by the nested call.
    uint256 public amount;

    /// @notice The gateway receiving the nested payment.
    JBRouterTerminalGateway public gateway;

    /// @notice The router allowed to request the nested payment.
    GatewayTestRouter public router;

    /// @notice The payment asset shared by the outer and nested route.
    GatewayTestToken public token;

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Submits a nested fee while the outer router still needs its allowance.
    /// @dev Only the configured router can trigger this boundary so the nested payment has a known outer call.
    function beforeGatewayRouterPull() external {
        if (msg.sender != address(router)) {
            revert GatewayNestedPayer_UnauthorizedCallback({caller: msg.sender, expectedRouter: address(router)});
        }

        // Sharing the payment token forces the gateway to restore the outer allowance after this call completes.
        gateway.pay({
            projectId: 1,
            token: address(token),
            amount: amount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(_SOURCE_PROJECT_ID)
        });
    }

    /// @notice Configures and funds the allowance for the nested fee call.
    /// @param gatewayToUse The gateway receiving the nested payment.
    /// @param routerToUse The router triggering the callback.
    /// @param tokenToUse The input asset shared with the outer call.
    /// @param amountToUse The number of tokens to pay during the callback.
    function configure(
        JBRouterTerminalGateway gatewayToUse,
        GatewayTestRouter routerToUse,
        GatewayTestToken tokenToUse,
        uint256 amountToUse
    )
        external
    {
        amount = amountToUse;
        gateway = gatewayToUse;
        router = routerToUse;
        token = tokenToUse;
        tokenToUse.approve({spender: address(gatewayToUse), value: amountToUse});
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
