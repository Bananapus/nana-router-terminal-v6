// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Provides a freely mintable ERC-20 for checking original-input custody.
contract GatewayTestToken is ERC20 {
    /// @notice Initializes the test payment token.
    constructor() ERC20("Test", "TST") {}

    /// @notice Funds an account with payment tokens for a custody scenario.
    /// @param account The account receiving tokens.
    /// @param amount The number of tokens to create.
    function mint(address account, uint256 amount) external {
        _mint({account: account, value: amount});
    }
}
