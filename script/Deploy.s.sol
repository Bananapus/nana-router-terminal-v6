// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    BuybackDeployment,
    BuybackDeploymentLib
} from "@bananapus/buyback-hook-v6/script/helpers/BuybackDeploymentLib.sol";
import {CoreDeployment, CoreDeploymentLib} from "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import {
    Univ4RouterDeployment,
    Univ4RouterDeploymentLib
} from "@bananapus/univ4-router-v6/script/helpers/Univ4RouterDeploymentLib.sol";
import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {JBRouterTerminalRegistry} from "../src/JBRouterTerminalRegistry.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

/// @notice Deploys the router terminal and registry with network-specific dependency addresses.
contract DeployScript is Script, Sphinx {
    //*********************************************************************//
    // ------------------------ internal constants ----------------------- //
    //*********************************************************************//

    /// @notice The CREATE2 salt used for the router terminal deployment.
    bytes32 constant ROUTER_TERMINAL = "JBRouterTerminalV6";

    /// @notice The CREATE2 salt used for the router-terminal registry deployment.
    bytes32 constant ROUTER_TERMINAL_REGISTRY = "JBRouterTerminalRegistryV6";

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice Tracks the deployment of the core contracts for the chain being deployed to.
    CoreDeployment core;

    /// @notice Tracks the deployment of the buyback-hook contracts for the chain being deployed to.
    BuybackDeployment buyback;

    /// @notice Tracks the deployment of the canonical Uniswap V4 router hook for the chain being deployed to.
    Univ4RouterDeployment univ4Router;

    /// @notice The wrapped native token address for the active deployment network.
    address weth;

    /// @notice The Uniswap V3 factory address for the active deployment network.
    address factory;

    /// @notice The Uniswap V4 pool manager address for the active deployment network.
    address poolManager;

    /// @notice The Permit2 singleton address for the active deployment network.
    address permit2;

    /// @notice The trusted forwarder inherited from the core deployment.
    address trustedForwarder;

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Configure the Sphinx deployment metadata for this repo.
    function configureSphinx() public override {
        // Name the Sphinx project so deployments reuse the canonical artifact tree.
        sphinxConfig.projectName = "nana-router-terminal-v6";

        // Declare the supported mainnet targets for the deployment bundle.
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];

        // Declare the supported testnet targets for the deployment bundle.
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    /// @notice Resolve network-specific dependencies and then execute the Sphinx deployment.
    function run() public {
        // Read the core deployment bundle outside the `sphinx` modifier so address resolution stays pure setup.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr({
                name: "NANA_CORE_DEPLOYMENT_PATH", defaultValue: string("node_modules/@bananapus/core-v6/deployments/")
            })
        );

        // Read the buyback-hook deployment bundle that the router will use for buyback-aware preview logic.
        buyback = BuybackDeploymentLib.getDeployment(
            vm.envOr({
                name: "NANA_BUYBACK_HOOK_DEPLOYMENT_PATH",
                defaultValue: string("node_modules/@bananapus/buyback-hook-v6/deployments/")
            })
        );

        // Read the canonical Uniswap V4 router-hook deployment bundle used by supported hooked pools.
        univ4Router = Univ4RouterDeploymentLib.getDeployment(
            vm.envOr({
                name: "NANA_UNIV4_ROUTER_DEPLOYMENT_PATH",
                defaultValue: string("node_modules/@bananapus/univ4-router-v6/deployments/")
            })
        );

        // Reuse the trusted forwarder from core so router meta-transactions match the rest of the stack.
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
            // https://docs.uniswap.org/contracts/v4/deployments
            poolManager = 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
            // Base Mainnet
        } else if (block.chainid == 8453) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
            // https://docs.uniswap.org/contracts/v4/deployments
            poolManager = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
            // Optimism Sepolia
        } else if (block.chainid == 11_155_420) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
            // https://docs.uniswap.org/contracts/v4/deployments
            poolManager = 0x1390B1276c3C0dd59E0e666d4cF97e30267E72E0;
            // BASE Sepolia
        } else if (block.chainid == 84_532) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
            // https://docs.uniswap.org/contracts/v4/deployments
            poolManager = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
            // Arbitrum Mainnet
        } else if (block.chainid == 42_161) {
            weth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            // https://docs.uniswap.org/contracts/v4/deployments
            poolManager = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
            // Arbitrum Sepolia
        } else if (block.chainid == 421_614) {
            weth = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
            factory = 0x248AB79Bbb9bC29bB72f7Cd42F17e054Fc40188e;
            // https://docs.uniswap.org/contracts/v4/deployments
            poolManager = 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;
        } else {
            revert("Invalid RPC / no juice contracts deployed on this network");
        }

        // Perform the deployment transactions.
        deploy();
    }

    /// @notice Deploy the registry and router terminal through Sphinx for the already-configured network addresses.
    function deploy() public sphinx {
        // Deploy the registry first so the router can be assigned as its default terminal immediately after.
        JBRouterTerminalRegistry registry = new JBRouterTerminalRegistry{salt: ROUTER_TERMINAL_REGISTRY}({
            permissions: core.permissions,
            projects: core.projects,
            permit2: IPermit2(permit2),
            owner: safeAddress(),
            trustedForwarder: trustedForwarder
        });

        // Deploy the router terminal with chain-same CREATE2 inputs; chain-specific constants
        // (WETH + Uniswap V3 factory + V4 PoolManager + V4 hook) are wired afterwards via the
        // DEPLOYER-gated one-shot setChainSpecificConstants setter on the terminal.
        require(address(buyback.hook) != address(0), "RouterTerminal: missing buyback hook");
        require(address(univ4Router.hook) != address(0), "RouterTerminal: missing v4 hook");
        JBRouterTerminal terminal = new JBRouterTerminal{salt: ROUTER_TERMINAL}({
            directory: core.directory,
            tokens: core.tokens,
            permit2: IPermit2(permit2),
            buybackHook: address(buyback.hook),
            trustedForwarder: trustedForwarder,
            deployer: safeAddress()
        });
        terminal.setChainSpecificConstants({
            weth: IWETH9(weth),
            factory: IUniswapV3Factory(factory),
            poolManager: IPoolManager(poolManager),
            univ4Hook: address(univ4Router.hook)
        });

        // Set the terminal as the default for the registry.
        registry.setDefaultTerminal(terminal);
    }

    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    /// @notice Compute whether a CREATE2 deployment would already exist at its deterministic address.
    /// @dev This helper is retained for manual deployment flows even though Sphinx does not call it directly.
    /// @param salt The CREATE2 salt that would be used for the deployment.
    /// @param creationCode The contract creation code.
    /// @param arguments The ABI-encoded constructor arguments.
    /// @return isDeployed A flag indicating whether code already exists at the computed deployment address.
    function _isDeployed(bytes32 salt, bytes memory creationCode, bytes memory arguments) internal view returns (bool) {
        // Derive the deterministic deployment address using the canonical Arachnid CREATE2 deployer.
        address _deployedTo = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            // Arachnid/deterministic-deployment-proxy address.
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });

        // Report whether a contract is already deployed at the computed CREATE2 address.
        return address(_deployedTo).code.length != 0;
    }
}
