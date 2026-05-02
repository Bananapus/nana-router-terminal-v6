// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";

contract RegistryDefaultRetargetsExistingProjectsTest is Test {
    JBRouterTerminalRegistry internal registry;

    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IPermit2 internal permit2 = IPermit2(makeAddr("permit2"));

    address internal owner = makeAddr("owner");
    address internal projectOwner = makeAddr("projectOwner");

    IJBTerminal internal terminalA = IJBTerminal(makeAddr("terminalA"));
    IJBTerminal internal terminalB = IJBTerminal(makeAddr("terminalB"));

    uint256 internal constant PROJECT_ID_ONE = 1;
    uint256 internal constant PROJECT_ID_TWO = 2;

    function setUp() public {
        registry = new JBRouterTerminalRegistry(permissions, projects, permit2, owner, address(0));

        vm.mockCall(address(projects), abi.encodeCall(IERC721.ownerOf, (PROJECT_ID_ONE)), abi.encode(projectOwner));
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature(
                "hasPermission(address,address,uint256,uint256,bool,bool)",
                projectOwner,
                projectOwner,
                PROJECT_ID_ONE,
                JBPermissionIds.SET_ROUTER_TERMINAL,
                true,
                true
            ),
            abi.encode(true)
        );
    }

    function test_existingProjectsFollowNewDefaultUntilExplicitlyLocked() public {
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        assertEq(address(registry.terminalOf(PROJECT_ID_ONE)), address(terminalA), "project one starts on default");
        assertEq(address(registry.terminalOf(PROJECT_ID_TWO)), address(terminalA), "project two starts on default");

        vm.prank(projectOwner);
        registry.lockTerminalFor(PROJECT_ID_ONE, terminalA);

        vm.prank(owner);
        registry.setDefaultTerminal(terminalB);

        assertEq(
            address(registry.terminalOf(PROJECT_ID_ONE)),
            address(terminalA),
            "locked project snapshots the old default"
        );
        assertEq(
            address(registry.terminalOf(PROJECT_ID_TWO)),
            address(terminalB),
            "unlocked project silently follows the new default"
        );
    }
}
