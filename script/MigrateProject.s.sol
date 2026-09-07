// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {Script} from "forge-std/Script.sol";

import {IJBRouterTerminalRegistry} from "../src/interfaces/IJBRouterTerminalRegistry.sol";

/// @notice Migrates one existing project after its owner or operator authorizes the registry update.
contract MigrateProjectScript is Script {
    /// @notice Point one project at a deployed gateway using the configured broadcast account.
    /// @dev Run once per project so an unauthorized cohort cannot block an authorized migration.
    function run() public {
        IJBTerminal gateway = IJBTerminal(vm.envAddress("NANA_ROUTER_TERMINAL_GATEWAY"));
        uint256 projectId = vm.envUint("NANA_ROUTER_TERMINAL_MIGRATION_PROJECT_ID");
        IJBRouterTerminalRegistry registry = IJBRouterTerminalRegistry(vm.envAddress("NANA_ROUTER_TERMINAL_REGISTRY"));

        vm.startBroadcast();
        registry.setTerminalFor({projectId: projectId, terminal: gateway});
        vm.stopBroadcast();
    }
}
