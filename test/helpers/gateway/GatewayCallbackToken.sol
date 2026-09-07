// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IGatewayTokenTransferCallback} from "./IGatewayTokenTransferCallback.sol";

/// @notice Calls a configured payer before its payment token enters gateway custody.
contract GatewayCallbackToken is ERC20 {
    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The payer receiving the intake callback.
    address public callback;

    /// @notice The gateway whose incoming transfer triggers the callback.
    address public gateway;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Whether an intake callback is already executing.
    /// @dev Prevents the mock token from recursively calling itself without reaching the gateway guard.
    bool internal _callingBack;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Initializes the payment token with an intake callback.
    constructor() ERC20("Callback", "CBK") {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Selects the gateway and payer whose incoming transfer should trigger a callback.
    /// @param gatewayAddress The gateway accepting the transfer.
    /// @param callbackAddress The payer whose transfer should trigger reentry.
    function configure(address gatewayAddress, address callbackAddress) external {
        callback = callbackAddress;
        gateway = gatewayAddress;
    }

    /// @notice Funds an account with tokens for an intake scenario.
    /// @param account The account receiving tokens.
    /// @param amount The number of tokens to create.
    function mint(address account, uint256 amount) external {
        _mint({account: account, value: amount});
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Runs the configured intake callback before completing an ERC-20 transfer.
    /// @dev The callback occurs before balances change so nested custody changes affect the intake measurement.
    /// @param from The account supplying tokens.
    /// @param to The account receiving tokens.
    /// @param amount The number of tokens to transfer.
    /// @return success Whether the ERC-20 transfer completed.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool success) {
        // Only the selected incoming transfer should exercise reentry; routing and refund transfers remain ordinary.
        if (msg.sender == gateway && from == callback && to == gateway && !_callingBack) {
            _callingBack = true;
            IGatewayTokenTransferCallback(callback).beforeGatewayTokenTransfer();
            _callingBack = false;
        }

        return super.transferFrom({from: from, to: to, value: amount});
    }
}
