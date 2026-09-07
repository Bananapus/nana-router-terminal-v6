// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Forwards calls with an appended sender address for ERC2771 gateway fixtures.
contract GatewayTestTrustedForwarder {
    /// @notice Forward a call with its original sender appended to the calldata.
    /// @dev Propagates the exact target revert data so forwarding preserves the gateway's failure behavior.
    /// @param target The contract receiving the forwarded call.
    /// @param data The call data without the sender suffix.
    /// @param originalSender The sender to append in ERC2771 format.
    /// @return result The data returned by the target.
    function forward(
        address target,
        bytes calldata data,
        address originalSender
    )
        external
        payable
        returns (bytes memory result)
    {
        // The suffix lets the gateway recover the payer while the forwarder remains the immediate caller.
        (bool success, bytes memory returnData) = target.call{value: msg.value}(abi.encodePacked(data, originalSender));
        if (!success) {
            // Preserve the original revert payload rather than wrapping it in a forwarder-specific error.
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return returnData;
    }
}
