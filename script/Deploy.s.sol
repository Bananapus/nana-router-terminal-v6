// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";

import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";

import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {JBRouterTerminalRegistry} from "../src/JBRouterTerminalRegistry.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

contract DeployScript is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    /// @notice the salts that are used to deploy the contracts.
    bytes32 ROUTER_TERMINAL = "JBRouterTerminalV6";
    bytes32 ROUTER_TERMINAL_REGISTRY = "JBRouterTerminalRegistryV6";

    /// @notice tracks the addresses that are required for the chain we are deploying to.
    address weth;
    address factory;
    address poolManager;
    address permit2;
    address trustedForwarder;

    function configureSphinx() public override {
        sphinxConfig.projectName = "nana-router-terminal-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    function run() public {
        // Get the deployment addresses for the nana CORE for this chain.
        // We want to do this outside of the `sphinx` modifier.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr({
                name: "NANA_CORE_DEPLOYMENT_PATH", defaultValue: string("node_modules/@bananapus/core-v6/deployments/")
            })
        );

        trustedForwarder = core.permissions.trustedForwarder();

        // Permit2 is deployed at the same address on all chains.
        permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

        // Ethereum Mainnet
        if (block.chainid == 1) {
            weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
            // Ethereum Sepolia
        } else if (block.chainid == 11_155_111) {
            weth = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
            factory = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
            poolManager = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
            // Optimism Mainnet
        } else if (block.chainid == 10) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
            // Base Mainnet
        } else if (block.chainid == 8453) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
            // Optimism Sepolia
        } else if (block.chainid == 11_155_420) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
            poolManager = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
            // BASE Sepolia
        } else if (block.chainid == 84_532) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
            poolManager = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
            // Arbitrum Mainnet
        } else if (block.chainid == 42_161) {
            weth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
            // Arbitrum Sepolia
        } else if (block.chainid == 421_614) {
            weth = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
            factory = 0x248AB79Bbb9bC29bB72f7Cd42F17e054Fc40188e;
            poolManager = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
        } else {
            revert("Invalid RPC / no juice contracts deployed on this network");
        }

        // Perform the deployment transactions.
        deploy();
    }

    function deploy() public sphinx {
        JBRouterTerminalRegistry registry = new JBRouterTerminalRegistry{salt: ROUTER_TERMINAL_REGISTRY}({
            permissions: core.permissions,
            projects: core.projects,
            permit2: IPermit2(permit2),
            owner: safeAddress(),
            trustedForwarder: trustedForwarder
        });

        JBRouterTerminal terminal = new JBRouterTerminal{salt: ROUTER_TERMINAL}({
            directory: core.directory,
            permissions: core.permissions,
            projects: core.projects,
            tokens: core.tokens,
            permit2: IPermit2(permit2),
            owner: safeAddress(),
            weth: IWETH9(weth),
            factory: IUniswapV3Factory(factory),
            poolManager: IPoolManager(poolManager),
            trustedForwarder: trustedForwarder
        });

        // Set the terminal as the default for the registry.
        registry.setDefaultTerminal(terminal);
    }

    function _isDeployed(bytes32 salt, bytes memory creationCode, bytes memory arguments) internal view returns (bool) {
        address _deployedTo = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            // Arachnid/deterministic-deployment-proxy address.
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });

        // Return if code is already present at this address.
        return address(_deployedTo).code.length != 0;
    }
}
