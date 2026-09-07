// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

import {IJBRouterTerminalRegistry} from "../../src/interfaces/IJBRouterTerminalRegistry.sol";

/// @notice Migrates configured project cohorts to a selected router-terminal implementation.
library RouterTerminalMigrationLib {
    /// @notice Thrown when a required project still does not resolve through the selected terminal after migration.
    error RouterTerminalMigrationLib_RequiredProjectMigrationFailed(
        uint256 projectId, IJBTerminal currentTerminal, IJBTerminal expectedTerminal
    );

    /// @notice Emitted when a project-specific migration cannot pass the registry's permission or lock checks.
    /// @param projectId The project ID which remains on its existing terminal.
    event RouterTerminalMigrationFailed(uint256 indexed projectId);

    /// @notice Point configured, existing projects at the selected registry implementation when needed.
    /// @dev Each project owner must own the registry call or authorize the deployment caller with
    /// `SET_ROUTER_TERMINAL`. A locked or unauthorized project is reported without aborting unrelated deployment work.
    /// @param registry The registry whose project-specific terminal pointers are updated.
    /// @param terminal The selected terminal implementation.
    /// @param projectCount The current highest project ID.
    /// @param projectIds The project IDs which must resolve to `terminal` after migration.
    /// @return failedCount The number of eligible projects which could not be migrated.
    function migrateProjects(
        IJBRouterTerminalRegistry registry,
        IJBTerminal terminal,
        uint256 projectCount,
        uint256[] memory projectIds
    )
        internal
        returns (uint256 failedCount)
    {
        for (uint256 i; i < projectIds.length; i++) {
            uint256 projectId = projectIds[i];

            // Ignore zero and not-yet-issued IDs so one cross-chain migration list can be reused safely.
            if (projectId == 0 || projectId > projectCount) continue;

            // A cohort already resolving through the selected terminal needs no project-authorized write.
            if (registry.terminalOf(projectId) == terminal) continue;

            // Preserve the registry's project permission gate without letting one cohort abort unrelated deployment.
            try registry.setTerminalFor({projectId: projectId, terminal: terminal}) {}
            catch {
                failedCount++;
                emit RouterTerminalMigrationFailed({projectId: projectId});
            }
        }
    }

    /// @notice Require a project to resolve through the selected terminal after migration.
    /// @param registry The registry whose project-specific terminal pointer is checked.
    /// @param terminal The terminal the project must resolve through.
    /// @param projectId The project ID whose migration is mandatory.
    function requireMigratedProject(
        IJBRouterTerminalRegistry registry,
        IJBTerminal terminal,
        uint256 projectId
    )
        internal
        view
    {
        IJBTerminal currentTerminal = registry.terminalOf(projectId);
        if (currentTerminal != terminal) {
            revert RouterTerminalMigrationLib_RequiredProjectMigrationFailed({
                projectId: projectId, currentTerminal: currentTerminal, expectedTerminal: terminal
            });
        }
    }
}
