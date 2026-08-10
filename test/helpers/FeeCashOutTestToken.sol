// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice An ERC-20 without a Router conversion route, used to exercise failed cash-out fee forwarding.
contract FeeCashOutTestToken is ERC20 {
    /// @notice Construct the test token.
    constructor() ERC20("Unroutable", "UNR") {}

    /// @notice Mint test tokens to an account.
    /// @param account The account receiving the tokens.
    /// @param amount The number of tokens to mint.
    function mint(address account, uint256 amount) external {
        _mint({account: account, value: amount});
    }
}
