// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";

/// @notice Regression test for L-29: lockTerminalFor should revert if current terminal doesn't match expected.
contract L29_LockTerminalRaceTest is Test {
    JBRouterTerminalRegistry registry;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IPermit2 permit2 = IPermit2(makeAddr("permit2"));
    address owner = makeAddr("owner");
    address trustedForwarder = makeAddr("trustedForwarder");

    IJBTerminal terminalA = IJBTerminal(makeAddr("terminalA"));
    IJBTerminal terminalB = IJBTerminal(makeAddr("terminalB"));

    uint256 projectId = 1;
    address projectOwner = makeAddr("projectOwner");

    function setUp() public {
        registry = new JBRouterTerminalRegistry(permissions, projects, permit2, owner, trustedForwarder);

        // Allow both terminals.
        vm.startPrank(owner);
        registry.setDefaultTerminal(terminalA);
        registry.allowTerminal(terminalB);
        vm.stopPrank();

        // Mock permissions.
        vm.mockCall(address(projects), abi.encodeCall(IERC721.ownerOf, (projectId)), abi.encode(projectOwner));
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature(
                "hasPermission(address,address,uint256,uint256,bool,bool)",
                projectOwner,
                projectOwner,
                projectId,
                JBPermissionIds.SET_ROUTER_TERMINAL,
                true,
                true
            ),
            abi.encode(true)
        );
    }

    /// @notice Locking with the correct expected terminal should succeed.
    function test_lockTerminalFor_succeedsWithCorrectExpected() public {
        vm.prank(projectOwner);
        registry.lockTerminalFor(projectId, terminalA);

        assertTrue(registry.hasLockedTerminal(projectId));
    }

    /// @notice Locking with the wrong expected terminal should revert.
    function test_lockTerminalFor_revertsWithWrongExpected() public {
        // Project has no explicit terminal, so it resolves to defaultTerminal (terminalA).
        // Trying to lock with terminalB should revert.
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalRegistry.JBRouterTerminalRegistry_TerminalMismatch.selector, terminalA, terminalB
            )
        );
        registry.lockTerminalFor(projectId, terminalB);
    }

    /// @notice If a project has an explicit terminal set, locking with the wrong one reverts.
    function test_lockTerminalFor_revertsWhenExplicitTerminalMismatch() public {
        // Set terminalB for the project.
        vm.prank(projectOwner);
        registry.setTerminalFor(projectId, terminalB);

        // Try to lock expecting terminalA -- should revert.
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalRegistry.JBRouterTerminalRegistry_TerminalMismatch.selector, terminalB, terminalA
            )
        );
        registry.lockTerminalFor(projectId, terminalA);
    }
}
