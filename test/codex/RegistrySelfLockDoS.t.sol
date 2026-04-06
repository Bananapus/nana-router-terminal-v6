// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";

contract RegistrySelfLockDoSTest is Test {
    JBRouterTerminalRegistry internal registry;

    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IPermit2 internal permit2 = IPermit2(makeAddr("permit2"));

    address internal owner = makeAddr("owner");
    address internal projectOwner = makeAddr("projectOwner");
    address internal payer = makeAddr("payer");

    uint256 internal constant PROJECT_ID = 1;

    function setUp() public {
        registry = new JBRouterTerminalRegistry(permissions, projects, permit2, owner, address(0));

        vm.mockCall(address(projects), abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(projectOwner));
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature(
                "hasPermission(address,address,uint256,uint256,bool,bool)",
                projectOwner,
                projectOwner,
                PROJECT_ID,
                JBPermissionIds.SET_ROUTER_TERMINAL,
                true,
                true
            ),
            abi.encode(true)
        );
    }

    function test_lockingRegistryAsDefaultTerminalPermanentlyBricksProjectRouting() public {
        vm.prank(owner);
        registry.setDefaultTerminal(registry);

        vm.prank(projectOwner);
        registry.lockTerminalFor(PROJECT_ID, registry);

        assertEq(address(registry.terminalOf(PROJECT_ID)), address(registry), "project snapshots the registry itself");
        assertTrue(registry.hasLockedTerminal(PROJECT_ID), "lock is permanent");

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(JBRouterTerminalRegistry.JBRouterTerminalRegistry_CircularForward.selector, registry)
        );
        registry.pay{value: 1 ether}(PROJECT_ID, JBConstants.NATIVE_TOKEN, 1 ether, payer, 0, "", "");

        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalRegistry.JBRouterTerminalRegistry_TerminalLocked.selector, PROJECT_ID
            )
        );
        registry.setTerminalFor(PROJECT_ID, registry);
    }
}
