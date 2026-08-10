// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {Test} from "forge-std/Test.sol";

import {RouterTerminalMigrationLib} from "../script/helpers/RouterTerminalMigrationLib.sol";
import {IJBRouterTerminalRegistry} from "../src/interfaces/IJBRouterTerminalRegistry.sol";

contract RouterTerminalMigrationRegistry {
    error RouterTerminalMigrationRegistry_Rejected(uint256 projectId);

    uint256 public rejectProjectId;
    mapping(uint256 projectId => IJBTerminal terminal) public terminalOf;
    uint256 public writeCount;

    function setRejectProjectId(uint256 projectId) external {
        rejectProjectId = projectId;
    }

    function setTerminalFor(uint256 projectId, IJBTerminal terminal) external {
        if (projectId == rejectProjectId) revert RouterTerminalMigrationRegistry_Rejected(projectId);
        terminalOf[projectId] = terminal;
        writeCount++;
    }
}

contract RouterTerminalMigrationLibTest is Test {
    function test_migrationContinuesAfterUnauthorizedProject() public {
        RouterTerminalMigrationRegistry registry = new RouterTerminalMigrationRegistry();
        IJBTerminal gateway = IJBTerminal(makeAddr("gateway"));

        uint256[] memory projectIds = new uint256[](2);
        projectIds[0] = 1;
        projectIds[1] = 2;
        registry.setRejectProjectId(1);

        uint256 failedCount = RouterTerminalMigrationLib.migrateProjects({
            registry: IJBRouterTerminalRegistry(address(registry)),
            terminal: gateway,
            projectCount: 2,
            projectIds: projectIds
        });

        assertEq(failedCount, 1, "the unauthorized project should be reported");
        assertEq(address(registry.terminalOf(1)), address(0), "the unauthorized project must remain unchanged");
        assertEq(address(registry.terminalOf(2)), address(gateway), "later authorized projects must still migrate");
    }

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

        uint256 failedCount = RouterTerminalMigrationLib.migrateProjects({
            registry: IJBRouterTerminalRegistry(address(registry)),
            terminal: gateway,
            projectCount: 2,
            projectIds: projectIds
        });

        assertEq(failedCount, 0, "every eligible project migration should succeed");
        assertEq(address(registry.terminalOf(1)), address(gateway), "existing raw-router cohort must migrate");
        assertEq(address(registry.terminalOf(2)), address(gateway), "gateway cohort must remain unchanged");
        assertEq(address(registry.terminalOf(3)), address(0), "unissued project must be ignored");
        assertEq(registry.writeCount() - writesBefore, 1, "only the vulnerable issued cohort should be written");
    }
}
