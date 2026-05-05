// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Interface for WETH9-compatible wrapped native token contracts.
interface IWETH9 is IERC20 {
    /// @notice Deposit native tokens to get wrapped native tokens.
    /// @dev Mints wrapped tokens 1:1 against the supplied `msg.value`.
    function deposit() external payable;

    /// @notice Withdraw wrapped native tokens to get native tokens.
    /// @param amount The amount of wrapped native tokens to unwrap.
    function withdraw(uint256 amount) external;
}
