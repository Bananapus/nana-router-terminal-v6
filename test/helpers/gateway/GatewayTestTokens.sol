// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Maps token addresses to issuing projects for source-project token retention checks.
contract GatewayTestTokens {
    /// @notice The issuing project of a token, or zero for an external asset.
    /// @custom:param token The token whose issuing project is configured.
    mapping(address token => uint256 projectId) public projectIdOf;

    /// @notice Configures the issuing project associated with a payment token.
    /// @param token The token to associate with a project.
    /// @param projectId The issuing project's identifier, or zero to represent an external asset.
    function setProjectIdOf(address token, uint256 projectId) external {
        projectIdOf[token] = projectId;
    }
}
