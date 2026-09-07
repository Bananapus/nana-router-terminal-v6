// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdJson} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {IJBRouterTerminal} from "../../src/interfaces/IJBRouterTerminal.sol";
import {IJBRouterTerminalGateway} from "../../src/interfaces/IJBRouterTerminalGateway.sol";
import {IJBRouterTerminalRegistry} from "../../src/interfaces/IJBRouterTerminalRegistry.sol";

/// @custom:member gateway The fail-closed router gateway selected by the registry.
/// @custom:member registry The deployed router-terminal registry for the selected network.
/// @custom:member terminal The deployed route-executing terminal wrapped by `gateway`.
struct RouterTerminalDeployment {
    IJBRouterTerminalGateway gateway;
    IJBRouterTerminalRegistry registry;
    IJBRouterTerminal terminal;
}

/// @notice Reads router-terminal deployment artifacts emitted by the repo's Sphinx deployment flow.
library RouterTerminalDeploymentLib {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a chain has no supported artifact directory, so deployment addresses cannot be resolved.
    error RouterTerminalDeploymentLib_UnsupportedChain(uint256 chainId);

    //*********************************************************************//
    // ------------------------ internal constants ----------------------- //
    //*********************************************************************//

    /// @notice The Foundry cheatcode interface used to read deployment artifacts.
    Vm internal constant _VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    /// @notice Read the router-terminal deployment for the current chain.
    /// @param path The root path containing Sphinx deployment artifacts.
    /// @return deployment The deployment addresses for the current chain.
    function getDeployment(string memory path) internal view returns (RouterTerminalDeployment memory deployment) {
        // Resolve the active chain to the same directory used by package and shared deployment artifacts.
        return getDeployment({path: path, networkName: _networkNameOf(block.chainid)});
    }

    /// @notice Read the router-terminal deployment for an explicit Sphinx network name.
    /// @param path The root path containing Sphinx deployment artifacts.
    /// @param networkName The Sphinx network name to read from.
    /// @return deployment The deployment addresses for `networkName`.
    function getDeployment(
        string memory path,
        string memory networkName
    )
        internal
        view
        returns (RouterTerminalDeployment memory deployment)
    {
        // Read the router gateway address from its Sphinx deployment artifact.
        deployment.gateway = IJBRouterTerminalGateway(
            _getDeploymentAddressOrZero({
                path: path,
                projectName: "nana-router-terminal-v6",
                networkName: networkName,
                contractName: "JBRouterTerminalGateway"
            })
        );

        // Read the registry address from its Sphinx deployment artifact.
        deployment.registry = IJBRouterTerminalRegistry(
            _getDeploymentAddress({
                path: path,
                projectName: "nana-router-terminal-v6",
                networkName: networkName,
                contractName: "JBRouterTerminalRegistry"
            })
        );

        // Read the route-executing terminal address from its Sphinx deployment artifact.
        deployment.terminal = IJBRouterTerminal(
            _getDeploymentAddress({
                path: path,
                projectName: "nana-router-terminal-v6",
                networkName: networkName,
                contractName: "JBRouterTerminal"
            })
        );
    }

    /// @notice Get the address of a contract that was deployed by the Deploy script.
    /// @dev Reverts if the contract was not found.
    /// @param path The path to the deployment file.
    /// @param projectName The Sphinx project name containing the deployment artifact.
    /// @param networkName The Sphinx network name containing the deployment artifact.
    /// @param contractName The name of the contract to get the address of.
    /// @return deploymentAddress The deployed contract address.
    function _getDeploymentAddress(
        string memory path,
        string memory projectName,
        string memory networkName,
        string memory contractName
    )
        internal
        view
        returns (address deploymentAddress)
    {
        string memory deploymentPath = _resolveDeploymentPath({
            path: path, projectName: projectName, networkName: networkName, contractName: contractName
        });

        // Read the raw deployment artifact so the `.address` field can be decoded below.
        string memory deploymentJson =
        // forge-lint: disable-next-line(unsafe-cheatcode)
        _VM.readFile(deploymentPath);

        // Decode and return the deployed contract address from the Sphinx artifact payload.
        deploymentAddress = stdJson.readAddress({json: deploymentJson, key: ".address"});
    }

    /// @notice Get a deployment address, returning zero when the artifact does not exist.
    /// @param path The path to the deployment file.
    /// @param projectName The Sphinx project name containing the deployment artifact.
    /// @param networkName The Sphinx network name containing the deployment artifact.
    /// @param contractName The name of the contract to get the address of.
    /// @return deploymentAddress The deployed contract address, or zero when no artifact exists.
    function _getDeploymentAddressOrZero(
        string memory path,
        string memory projectName,
        string memory networkName,
        string memory contractName
    )
        internal
        view
        returns (address deploymentAddress)
    {
        string memory deploymentPath = _resolveDeploymentPath({
            path: path, projectName: projectName, networkName: networkName, contractName: contractName
        });

        // An absent optional artifact means the contract has not been deployed for this network.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        if (!_VM.exists(deploymentPath)) return address(0);

        // Read and decode the artifact only after establishing that it exists.
        string memory deploymentJson =
        // forge-lint: disable-next-line(unsafe-cheatcode)
        _VM.readFile(deploymentPath);
        deploymentAddress = stdJson.readAddress({json: deploymentJson, key: ".address"});
    }

    /// @notice Return the canonical artifact directory name for a supported chain ID.
    /// @dev Rejects unsupported chains rather than reading an unrelated deployment directory.
    /// @param chainId The chain ID to resolve.
    /// @return networkName The deployment artifact network name.
    function _networkNameOf(uint256 chainId) internal pure returns (string memory networkName) {
        // Match package artifact directory names so callers can share the same deployment root across chains.
        if (chainId == 1) return "ethereum";
        if (chainId == 10) return "optimism";
        if (chainId == 8453) return "base";
        if (chainId == 42_161) return "arbitrum";
        if (chainId == 84_532) return "base_sepolia";
        if (chainId == 421_614) return "arbitrum_sepolia";
        if (chainId == 11_155_111) return "sepolia";
        if (chainId == 11_155_420) return "optimism_sepolia";
        revert RouterTerminalDeploymentLib_UnsupportedChain(chainId);
    }

    /// @notice Resolve either a package-local or Sphinx-project deployment artifact path.
    /// @param path The root deployment path.
    /// @param projectName The Sphinx project name.
    /// @param networkName The Sphinx network name.
    /// @param contractName The deployment contract name.
    /// @return deploymentPath The artifact path to read.
    function _resolveDeploymentPath(
        string memory path,
        string memory projectName,
        string memory networkName,
        string memory contractName
    )
        internal
        view
        returns (string memory deploymentPath)
    {
        string memory packagePath = string.concat(path, networkName, "/", contractName, ".json");

        // Prefer package-local artifacts because deployment packages expose their own `deployments/` directory.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        if (_VM.exists(packagePath)) return packagePath;

        // A shared artifact root groups deployments under their Sphinx project name.
        return string.concat(path, projectName, "/", networkName, "/", contractName, ".json");
    }
}
