// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

import {IJBRouterTerminalRegistry} from "../../../src/interfaces/IJBRouterTerminalRegistry.sol";

import {RouterTerminalMigrationLib} from "../../../script/helpers/RouterTerminalMigrationLib.sol";

/// @notice Records migration writes and rejects a configured project to model registry permission failures.
contract RouterTerminalMigrationRegistry {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a write targets the configured rejected project, modeling an unauthorized migration.
    /// @param projectId The project whose terminal cannot be changed.
    error RouterTerminalMigrationRegistry_Rejected(uint256 projectId);

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The project whose terminal writes must fail.
    uint256 public rejectProjectId;

    /// @notice The terminal recorded for each project.
    /// @custom:param projectId The project whose selected terminal is recorded.
    mapping(uint256 projectId => IJBTerminal terminal) public terminalOf;

    /// @notice The number of successful terminal writes performed by the fixture.
    uint256 public writeCount;

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Configure the project whose terminal writes should revert.
    /// @param projectId The project to reject during migration.
    function setRejectProjectId(uint256 projectId) external {
        rejectProjectId = projectId;
    }

    /// @notice Record a terminal selection unless the project is configured to reject writes.
    /// @param projectId The project whose terminal is selected.
    /// @param terminal The terminal to select for the project.
    function setTerminalFor(uint256 projectId, IJBTerminal terminal) external {
        // Reject before counting writes so the tests can distinguish failed migrations from completed writes.
        if (projectId == rejectProjectId) revert RouterTerminalMigrationRegistry_Rejected(projectId);
        terminalOf[projectId] = terminal;
        writeCount++;
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Require a project to resolve through the expected terminal.
    /// @param terminal The terminal that must be selected for the project.
    /// @param projectId The project whose completed migration is required.
    function requireMigratedProject(IJBTerminal terminal, uint256 projectId) external view {
        RouterTerminalMigrationLib._requireMigratedProject({
            registry: IJBRouterTerminalRegistry(address(this)), terminal: terminal, projectId: projectId
        });
    }
}
