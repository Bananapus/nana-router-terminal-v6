// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Records permit ownership and performs token pulls for gateway authorization fixtures.
/// @dev Signature validation is outside the fixture; the gateway's owner and spender propagation is under test.
contract GatewayTestPermit2 {
    /// @notice The owner supplied in the most recent permit.
    address public lastOwner;

    /// @notice The spender supplied in the most recent permit.
    address public lastSpender;

    /// @notice Record the owner and spender of a permit request.
    /// @dev The third argument is the unused signature, retained in its Permit2 ABI position.
    /// @param owner The permit owner.
    /// @param permitSingle The permit containing the authorized spender.
    function permit(address owner, IAllowanceTransfer.PermitSingle calldata permitSingle, bytes calldata) external {
        lastOwner = owner;
        lastSpender = permitSingle.spender;
    }

    /// @notice Pull tokens on behalf of a gateway call.
    /// @param from The address providing the tokens.
    /// @param to The address receiving the tokens.
    /// @param amount The amount to transfer.
    /// @param token The token to transfer.
    function transferFrom(address from, address to, uint160 amount, address token) external {
        IERC20(token).transferFrom({from: from, to: to, value: amount});
    }
}
