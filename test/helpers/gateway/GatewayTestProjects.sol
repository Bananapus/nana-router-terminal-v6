// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Provides the issued-project count required by the two-project registry fixture.
contract GatewayTestProjects {
    /// @notice Returns the number of projects represented by the source and fee fixtures.
    /// @return projectCount The two fixture projects.
    function count() external pure returns (uint256 projectCount) {
        return 2;
    }
}
