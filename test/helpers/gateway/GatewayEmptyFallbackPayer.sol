// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {JBRouterTerminalGateway} from "../../../src/JBRouterTerminalGateway.sol";

/// @notice Models a payer that accepts unknown selectors with empty return data.
/// @dev An `originalPayer()` probe succeeds without supplying an address, matching the shape of REVLoans.
contract GatewayEmptyFallbackPayer {
    /// @notice Accept unknown calls without returning data.
    fallback() external payable {}

    /// @notice Accept native funds without returning data.
    receive() external payable {}

    /// @notice Attempt a token payment through the gateway and report whether the call succeeds.
    /// @param gateway The gateway receiving the payment.
    /// @param token The payment token.
    /// @param amount The amount to pay.
    /// @param metadata The metadata forwarded with the payment.
    /// @return success Whether the gateway call completed successfully.
    function payThrough(
        JBRouterTerminalGateway gateway,
        address token,
        uint256 amount,
        bytes memory metadata
    )
        external
        returns (bool success)
    {
        // Approve the pull independently of the payment result so a caught failure remains observable.
        IERC20(token).approve({spender: address(gateway), value: amount});
        try gateway.pay({
            projectId: 3,
            token: token,
            amount: amount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        }) returns (
            uint256
        ) {
            success = true;
        } catch {}
    }
}
