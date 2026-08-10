// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {Test} from "forge-std/Test.sol";

import {RouterTerminalMigrationLib} from "../script/helpers/RouterTerminalMigrationLib.sol";
import {IJBRouterTerminalRegistry} from "../src/interfaces/IJBRouterTerminalRegistry.sol";

contract RouterTerminalMigrationRegistry {
    mapping(uint256 projectId => IJBTerminal terminal) public terminalOf;
    uint256 public writeCount;

    function setTerminalFor(uint256 projectId, IJBTerminal terminal) external {
        terminalOf[projectId] = terminal;
        writeCount++;
    }
}

contract RouterTerminalMigrationLibTest is Test {
    function test_migratesOnlyIssuedProjectsWhichDoNotAlreadyResolveThroughGateway() public {
        RouterTerminalMigrationRegistry registry = new RouterTerminalMigrationRegistry();
        IJBTerminal gateway = IJBTerminal(makeAddr("gateway"));
        IJBTerminal router = IJBTerminal(makeAddr("router"));

        registry.setTerminalFor({projectId: 1, terminal: router});
        registry.setTerminalFor({projectId: 2, terminal: gateway});
        uint256 writesBefore = registry.writeCount();

        uint256[] memory projectIds = new uint256[](4);
        projectIds[0] = 0;
        projectIds[1] = 1;
        projectIds[2] = 2;
        projectIds[3] = 3;

        RouterTerminalMigrationLib.migrateProjects({
            registry: IJBRouterTerminalRegistry(address(registry)),
            terminal: gateway,
            projectCount: 2,
            projectIds: projectIds
        });

        assertEq(address(registry.terminalOf(1)), address(gateway), "existing raw-router cohort must migrate");
        assertEq(address(registry.terminalOf(2)), address(gateway), "gateway cohort must remain unchanged");
        assertEq(address(registry.terminalOf(3)), address(0), "unissued project must be ignored");
        assertEq(registry.writeCount() - writesBefore, 1, "only the vulnerable issued cohort should be written");
    }
}
