// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {Test} from "forge-std/Test.sol";

import {IJBRouterTerminalRegistry} from "../src/interfaces/IJBRouterTerminalRegistry.sol";

import {RouterTerminalMigrationLib} from "../script/helpers/RouterTerminalMigrationLib.sol";

import {RouterTerminalMigrationRegistry} from "./helpers/deployment/RouterTerminalMigrationRegistry.sol";

/// @notice Tests selective project migration, failure isolation, and required-project validation.
contract RouterTerminalMigrationLibTest is Test {
    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Migration writes only issued projects that do not already resolve through the selected gateway.
    function test_migratesOnlyIssuedProjectsWhichDoNotAlreadyResolveThroughGateway() public {
        RouterTerminalMigrationRegistry registry = new RouterTerminalMigrationRegistry();
        IJBTerminal gateway = IJBTerminal(makeAddr("gateway"));
        IJBTerminal router = IJBTerminal(makeAddr("router"));

        // Only the raw-router project requires a write; the selected gateway must remain untouched.
        registry.setTerminalFor({projectId: 1, terminal: router});
        registry.setTerminalFor({projectId: 2, terminal: gateway});
        uint256 writesBefore = registry.writeCount();

        // Include invalid and unissued IDs to verify that a shared migration list cannot create project entries.
        uint256[] memory projectIds = new uint256[](4);
        projectIds[0] = 0;
        projectIds[1] = 1;
        projectIds[2] = 2;
        projectIds[3] = 3;

        uint256 failedCount = RouterTerminalMigrationLib._migrateProjects({
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
        RouterTerminalMigrationLib._requireMigratedProject({
            registry: IJBRouterTerminalRegistry(address(registry)), terminal: gateway, projectId: 1
        });
    }

    /// @notice An unauthorized project does not prevent a later authorized project from migrating.
    function test_migrationContinuesAfterUnauthorizedProject() public {
        RouterTerminalMigrationRegistry registry = new RouterTerminalMigrationRegistry();
        IJBTerminal gateway = IJBTerminal(makeAddr("gateway"));

        // Put the rejected project first so successful migration requires continuing after the failure.
        uint256[] memory projectIds = new uint256[](2);
        projectIds[0] = 1;
        projectIds[1] = 2;
        registry.setRejectProjectId(1);

        uint256 failedCount = RouterTerminalMigrationLib._migrateProjects({
            registry: IJBRouterTerminalRegistry(address(registry)),
            terminal: gateway,
            projectCount: 2,
            projectIds: projectIds
        });

        assertEq(failedCount, 1, "the unauthorized project should be reported");
        assertEq(address(registry.terminalOf(1)), address(0), "the unauthorized project must remain unchanged");
        assertEq(address(registry.terminalOf(2)), address(gateway), "later authorized projects must still migrate");
    }

    /// @notice Required-project validation reverts when an isolated migration failure leaves its terminal unchanged.
    function test_requiredProjectMigrationCannotSilentlyFail() public {
        RouterTerminalMigrationRegistry registry = new RouterTerminalMigrationRegistry();
        IJBTerminal gateway = IJBTerminal(makeAddr("gateway"));
        registry.setRejectProjectId(1);

        uint256[] memory projectIds = new uint256[](1);
        projectIds[0] = 1;
        // A best-effort migration reports failure without reverting, so required projects need a separate
        // postcondition.
        RouterTerminalMigrationLib._migrateProjects({
            registry: IJBRouterTerminalRegistry(address(registry)),
            terminal: gateway,
            projectCount: 1,
            projectIds: projectIds
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                RouterTerminalMigrationLib.RouterTerminalMigrationLib_RequiredProjectMigrationFailed.selector,
                uint256(1),
                IJBTerminal(address(0)),
                gateway
            )
        );
        registry.requireMigratedProject({terminal: gateway, projectId: 1});
    }
}
