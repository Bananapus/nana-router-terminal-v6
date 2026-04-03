// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdJson} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {NetworkInfo, SphinxConstants} from "@sphinx-labs/contracts/contracts/foundry/SphinxConstants.sol";

import {IJBRouterTerminal} from "../../src/interfaces/IJBRouterTerminal.sol";
import {IJBRouterTerminalRegistry} from "../../src/interfaces/IJBRouterTerminalRegistry.sol";

/// @custom:member terminal The deployed router terminal for the selected network.
/// @custom:member registry The deployed router-terminal registry for the selected network.
struct RouterTerminalDeployment {
    IJBRouterTerminal terminal;
    IJBRouterTerminalRegistry registry;
}

/// @notice Reads router-terminal deployment artifacts emitted by the repo's Sphinx deployment flow.
library RouterTerminalDeploymentLib {
    // Cheat code address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    // forge-lint: disable-next-line(screaming-snake-case-const)
    Vm internal constant vm = Vm(VM_ADDRESS);

    /// @notice Read the router-terminal deployment for the current chain.
    /// @param path The root path containing Sphinx deployment artifacts.
    /// @return deployment The deployment addresses for the current chain.
    function getDeployment(string memory path) internal returns (RouterTerminalDeployment memory deployment) {
        // Read the current chain ID so the helper can select the matching Sphinx network entry.
        uint256 chainId = block.chainid;

        // Deploy the Sphinx constants helper so the script can reuse its canonical network-name mapping.
        SphinxConstants sphinxConstants = new SphinxConstants();

        // Materialize the supported network list once so the current chain can be matched below.
        NetworkInfo[] memory networks = sphinxConstants.getNetworkInfoArray();

        for (uint256 _i; _i < networks.length; _i++) {
            // Return as soon as the helper finds the network entry matching the active chain.
            if (networks[_i].chainId == chainId) {
                return getDeployment({path: path, networkName: networks[_i].name});
            }
        }

        // Abort when Sphinx has no network metadata for the active chain.
        revert("ChainID is not (currently) supported by Sphinx.");
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
        // Read the router terminal address from its Sphinx deployment artifact.
        deployment.terminal = IJBRouterTerminal(
            _getDeploymentAddress({
                path: path,
                projectName: "nana-router-terminal-v6",
                networkName: networkName,
                contractName: "JBRouterTerminal"
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
        // Read the raw deployment artifact so the `.address` field can be decoded below.
        string memory deploymentJson =
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.readFile(string.concat(path, projectName, "/", networkName, "/", contractName, ".json"));

        // Decode and return the deployed contract address from the Sphinx artifact payload.
        deploymentAddress = stdJson.readAddress({json: deploymentJson, key: ".address"});
    }
}
