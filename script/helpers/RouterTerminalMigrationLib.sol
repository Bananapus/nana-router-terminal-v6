// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

import {IJBRouterTerminalRegistry} from "../../src/interfaces/IJBRouterTerminalRegistry.sol";

/// @notice Migrates configured project cohorts to a selected router-terminal implementation.
library RouterTerminalMigrationLib {
    /// @notice Point configured, existing projects at the selected registry implementation when needed.
    /// @dev Each project owner must own the registry call or authorize the deployment caller with
    /// `SET_ROUTER_TERMINAL`. A locked or unauthorized project reverts instead of silently remaining vulnerable.
    /// @param registry The registry whose project-specific terminal pointers are updated.
    /// @param terminal The selected terminal implementation.
    /// @param projectCount The current highest project ID.
    /// @param projectIds The project IDs which must resolve to `terminal` after migration.
    function migrateProjects(
        IJBRouterTerminalRegistry registry,
        IJBTerminal terminal,
        uint256 projectCount,
        uint256[] memory projectIds
    )
        internal
    {
        for (uint256 i; i < projectIds.length; i++) {
            uint256 projectId = projectIds[i];

            // Ignore zero and not-yet-issued IDs so one cross-chain migration list can be reused safely.
            if (projectId == 0 || projectId > projectCount) continue;

            // A cohort already resolving through the selected terminal needs no project-authorized write.
            if (registry.terminalOf(projectId) == terminal) continue;

            // Use the registry's project permission gate; failures abort deployment instead of leaving a partial fix.
            registry.setTerminalFor({projectId: projectId, terminal: terminal});
        }
    }
}
