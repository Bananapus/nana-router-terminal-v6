// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Interface for WETH9.
interface IWETH9 is IERC20 {
    /// @notice Deposit ether to get wrapped ether.
    /// @dev Mints WETH 1:1 against the supplied `msg.value`.
    function deposit() external payable;

    /// @notice Withdraw wrapped ether to get ether.
    /// @param amount The amount of WETH to unwrap into native ETH.
    function withdraw(uint256 amount) external;
}
