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

contract RegistrySelfLockForwarder {
    IJBTerminal internal immutable _downstream;

    constructor(IJBTerminal downstream) {
        _downstream = downstream;
    }

    function terminalOf(uint256) external view returns (IJBTerminal) {
        return _downstream;
    }
}

contract RegistrySelfLockDoSTest is Test {
    JBRouterTerminalRegistry internal registry;

    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IPermit2 internal permit2 = IPermit2(makeAddr("permit2"));

    address internal owner = makeAddr("owner");
    address internal projectOwner = makeAddr("projectOwner");

    uint256 internal constant PROJECT_ID = 1;

    function setUp() public {
        registry = new JBRouterTerminalRegistry(permissions, projects, permit2, owner, address(0));

        // PR #108: setDefaultTerminal now reads PROJECTS.count(). Mock it to 0 (fresh chain).
        vm.mockCall(address(projects), abi.encodeCall(IJBProjects.count, ()), abi.encode(uint256(0)));
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

    function test_setDefaultTerminal_rejectsRegistryItself() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(JBRouterTerminalRegistry.JBRouterTerminalRegistry_CircularForward.selector, registry)
        );
        registry.setDefaultTerminal(registry);
    }

    function test_setDefaultTerminalRejectsForwarderThatResolvesToRegistry() public {
        IJBTerminal forwarder = IJBTerminal(address(new RegistrySelfLockForwarder(registry)));

        // The registry now walks the forwarding chain (forwarder -> registry) and rejects the
        // default before it can ever be installed, so a locking attempt is never reachable.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalRegistry.JBRouterTerminalRegistry_CircularForward.selector, forwarder
            )
        );
        registry.setDefaultTerminal(forwarder);

        assertFalse(registry.hasLockedTerminal(PROJECT_ID), "bad route is not locked");
    }
}
