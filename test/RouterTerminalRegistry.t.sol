// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {JBRouterTerminalRegistry} from "../src/JBRouterTerminalRegistry.sol";
import {IJBRouterTerminalRegistry} from "../src/interfaces/IJBRouterTerminalRegistry.sol";

contract RouterTerminalRegistryTest is Test {
    JBRouterTerminalRegistry registry;

    // Mocked dependencies.
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IPermit2 permit2 = IPermit2(makeAddr("permit2"));
    address owner = makeAddr("owner");
    address trustedForwarder = makeAddr("trustedForwarder");

    // Mocked terminals.
    IJBTerminal terminalA = IJBTerminal(makeAddr("terminalA"));
    IJBTerminal terminalB = IJBTerminal(makeAddr("terminalB"));

    // Test constants.
    uint256 projectId = 1;
    address projectOwner = makeAddr("projectOwner");

    function setUp() public {
        registry = new JBRouterTerminalRegistry(permissions, projects, permit2, owner, trustedForwarder);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Constructor / immutables
    // ──────────────────────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(registry.PROJECTS()), address(projects));
        assertEq(address(registry.PERMIT2()), address(permit2));
        assertEq(address(registry.defaultTerminal()), address(0));
    }

    // ──────────────────────────────────────────────────────────────────────
    // allowTerminal / disallowTerminal
    // ──────────────────────────────────────────────────────────────────────

    function test_allowTerminal() public {
        vm.prank(owner);
        registry.allowTerminal(terminalA);

        assertTrue(registry.isTerminalAllowed(terminalA));
    }

    function test_allowTerminal_revertsIfNotOwner() public {
        vm.expectRevert();
        registry.allowTerminal(terminalA);
    }

    function test_disallowTerminal() public {
        vm.startPrank(owner);
        registry.allowTerminal(terminalA);
        registry.disallowTerminal(terminalA);
        vm.stopPrank();

        assertFalse(registry.isTerminalAllowed(terminalA));
    }

    function test_disallowTerminal_clearsDefault() public {
        vm.startPrank(owner);
        registry.setDefaultTerminal(terminalA);
        registry.disallowTerminal(terminalA);
        vm.stopPrank();

        assertEq(address(registry.defaultTerminal()), address(0));
    }

    // ──────────────────────────────────────────────────────────────────────
    // setDefaultTerminal
    // ──────────────────────────────────────────────────────────────────────

    function test_setDefaultTerminal() public {
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        assertEq(address(registry.defaultTerminal()), address(terminalA));
        assertTrue(registry.isTerminalAllowed(terminalA));
    }

    function test_setDefaultTerminal_revertsIfNotOwner() public {
        vm.expectRevert();
        registry.setDefaultTerminal(terminalA);
    }

    // ──────────────────────────────────────────────────────────────────────
    // terminalOf
    // ──────────────────────────────────────────────────────────────────────

    function test_terminalOf_fallsBackToDefault() public {
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        assertEq(address(registry.terminalOf(projectId)), address(terminalA));
    }

    function test_terminalOf_returnsProjectSpecific() public {
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        // Allow terminalB and set it for the project.
        vm.prank(owner);
        registry.allowTerminal(terminalB);

        // Mock the project owner.
        vm.mockCall(address(projects), abi.encodeCall(IERC721.ownerOf, (projectId)), abi.encode(projectOwner));
        // Mock the permission check.
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

        vm.prank(projectOwner);
        registry.setTerminalFor(projectId, terminalB);

        assertEq(address(registry.terminalOf(projectId)), address(terminalB));
    }

    // ──────────────────────────────────────────────────────────────────────
    // setTerminalFor
    // ──────────────────────────────────────────────────────────────────────

    function test_setTerminalFor_revertsIfNotAllowed() public {
        // Mock the project owner.
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

        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalRegistry.JBRouterTerminalRegistry_TerminalNotAllowed.selector, terminalA
            )
        );
        registry.setTerminalFor(projectId, terminalA);
    }

    function test_setTerminalFor_revertsIfLocked() public {
        // Set up: allow terminal, set it, lock it.
        vm.prank(owner);
        registry.allowTerminal(terminalA);

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

        vm.prank(projectOwner);
        registry.setTerminalFor(projectId, terminalA);

        vm.prank(projectOwner);
        registry.lockTerminalFor(projectId);

        // Try to change.
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(JBRouterTerminalRegistry.JBRouterTerminalRegistry_TerminalLocked.selector, projectId)
        );
        registry.setTerminalFor(projectId, terminalA);
    }

    // ──────────────────────────────────────────────────────────────────────
    // lockTerminalFor
    // ──────────────────────────────────────────────────────────────────────

    function test_lockTerminalFor_snapshotsDefault() public {
        // Set up default, no project-specific terminal.
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

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

        vm.prank(projectOwner);
        registry.lockTerminalFor(projectId);

        assertTrue(registry.hasLockedTerminal(projectId));
        // Should have snapshotted the default as the project's terminal.
        assertEq(address(registry.terminalOf(projectId)), address(terminalA));
    }

    function test_lockTerminalFor_revertsIfNoTerminal() public {
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

        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(JBRouterTerminalRegistry.JBRouterTerminalRegistry_TerminalNotSet.selector, projectId)
        );
        registry.lockTerminalFor(projectId);
    }

    // ──────────────────────────────────────────────────────────────────────
    // supportsInterface
    // ──────────────────────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(registry.supportsInterface(type(IJBRouterTerminalRegistry).interfaceId));
        assertTrue(registry.supportsInterface(type(IJBTerminal).interfaceId));
        assertTrue(registry.supportsInterface(type(IERC165).interfaceId));
        assertFalse(registry.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ──────────────────────────────────────────────────────────────────────
    // pay (forwarding)
    // ──────────────────────────────────────────────────────────────────────

    function test_pay_forwardsToDefault() public {
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        // Mock the terminal's pay to return 100.
        vm.mockCall(address(terminalA), abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(100)));

        // Send native tokens.
        vm.deal(address(this), 1 ether);
        uint256 returned = registry.pay{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        assertEq(returned, 100);
    }

    // ──────────────────────────────────────────────────────────────────────
    // addToBalanceOf (forwarding)
    // ──────────────────────────────────────────────────────────────────────

    function test_addToBalanceOf_forwardsToDefault() public {
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        // Mock the terminal's addToBalanceOf.
        vm.mockCall(address(terminalA), abi.encodeWithSelector(IJBTerminal.addToBalanceOf.selector), abi.encode());

        // Send native tokens.
        vm.deal(address(this), 1 ether);
        registry.addToBalanceOf{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: ""
        });
    }
}
