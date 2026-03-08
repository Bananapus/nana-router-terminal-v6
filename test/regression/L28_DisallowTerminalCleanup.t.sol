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

/// @notice Regression test for L-28: disallowTerminal should invalidate existing project assignments.
contract L28_DisallowTerminalCleanupTest is Test {
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

        // Allow terminalA and set as default.
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        // Allow terminalB.
        vm.prank(owner);
        registry.allowTerminal(terminalB);

        // Mock permissions for project owner.
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

        // Set terminalB for the project.
        vm.prank(projectOwner);
        registry.setTerminalFor(projectId, terminalB);
    }

    /// @notice After disallowing terminalB, terminalOf should NOT return it.
    function test_terminalOf_doesNotReturnDisallowedTerminal() public {
        // Verify project currently resolves to terminalB.
        assertEq(address(registry.terminalOf(projectId)), address(terminalB));

        // Disallow terminalB.
        vm.prank(owner);
        registry.disallowTerminal(terminalB);

        // terminalOf should now fall back to the default (terminalA), NOT return the disallowed terminalB.
        assertEq(address(registry.terminalOf(projectId)), address(terminalA));
    }

    /// @notice After disallowing both terminals, terminalOf should return address(0).
    function test_terminalOf_returnsZeroWhenAllDisallowed() public {
        vm.startPrank(owner);
        registry.disallowTerminal(terminalB);
        registry.disallowTerminal(terminalA);
        vm.stopPrank();

        // Both disallowed, default is cleared. Should return address(0).
        assertEq(address(registry.terminalOf(projectId)), address(0));
    }
}
