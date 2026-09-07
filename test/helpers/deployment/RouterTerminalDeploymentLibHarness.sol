// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    RouterTerminalDeployment,
    RouterTerminalDeploymentLib
} from "../../../script/helpers/RouterTerminalDeploymentLib.sol";

/// @notice Exposes deployment artifact readers and network-name resolution for tests.
contract RouterTerminalDeploymentLibHarness {
    /// @notice Read the router-terminal deployment for a Sphinx network name.
    /// @param path The root path containing the deployment artifacts.
    /// @param networkName The network directory to read.
    /// @return deployment The deployment addresses recorded for the network.
    function getDeployment(
        string memory path,
        string memory networkName
    )
        external
        view
        returns (RouterTerminalDeployment memory deployment)
    {
        return RouterTerminalDeploymentLib.getDeployment({path: path, networkName: networkName});
    }

    /// @notice Resolve the artifact directory name for a supported chain.
    /// @param chainId The chain ID whose directory is requested.
    /// @return networkName The directory name used by the deployment artifacts.
    function networkNameOf(uint256 chainId) external pure returns (string memory networkName) {
        return RouterTerminalDeploymentLib._networkNameOf(chainId);
    }
}
