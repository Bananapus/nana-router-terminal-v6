// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Models an immutable protocol contract that catches and forgives a failed fee payment.
contract GatewayProtocolFeePayer {
    /// @notice Whether the most recent fee payment reverted and was forgiven.
    bool public feeWasForgiven;

    /// @notice Attempt a protocol-fee payment and record whether its failure was forgiven.
    /// @param feeTerminal The terminal receiving the fee.
    /// @param token The fee token.
    /// @param amount The amount to pay.
    /// @param sourceProjectId The source project encoded in the payment metadata.
    function payFee(IJBTerminal feeTerminal, address token, uint256 amount, uint256 sourceProjectId) external {
        // ERC20 payment funds are pulled by the terminal, while native funds travel with the call.
        if (token != JBConstants.NATIVE_TOKEN) IERC20(token).approve({spender: address(feeTerminal), value: amount});

        // Catch destination failure so the originating protocol action can complete without its fee payment.
        try feeTerminal.pay{value: token == JBConstants.NATIVE_TOKEN ? amount : 0}({
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
}
