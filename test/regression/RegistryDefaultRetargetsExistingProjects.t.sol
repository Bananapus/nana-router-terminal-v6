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

    /// @notice Regression: existing projects MUST keep their cohort's default after a
    /// `setDefaultTerminal` change, even if they never explicitly locked. The previous
    /// (vulnerable) behavior — where unlocked projects silently followed the new default —
    /// was the exact admin-key reroute vector this regression is named for. The threshold +
    /// snapshot history in `JBRouterTerminalRegistry` removes that vector.
    function test_existingProjectsKeepOldDefaultAcrossDefaultChange() public {
        // First default applies to both projects (they exist within the initial cohort).
        // PROJECTS.count() is mocked to 0 at this point — both project IDs fall into the
        // initial cohort because projectId > defaultTerminalProjectIdThreshold (0).
        vm.mockCall(address(projects), abi.encodeCall(IJBProjects.count, ()), abi.encode(uint256(0)));
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        assertEq(address(registry.terminalOf(PROJECT_ID_ONE)), address(terminalA), "project one starts on default");
        assertEq(address(registry.terminalOf(PROJECT_ID_TWO)), address(terminalA), "project two starts on default");

        vm.prank(projectOwner);
        registry.lockTerminalFor(PROJECT_ID_ONE, terminalA);

        // Owner sets a new default after both projects exist. count() = 2 captures both
        // existing projects in the legacy cohort's history segment.
        vm.mockCall(address(projects), abi.encodeCall(IJBProjects.count, ()), abi.encode(uint256(2)));
        vm.prank(owner);
        registry.setDefaultTerminal(terminalB);

        // Locked project keeps the old default (already-snapshotted into _terminalOf).
        assertEq(
            address(registry.terminalOf(PROJECT_ID_ONE)), address(terminalA), "locked project keeps the old default"
        );
        // Unlocked legacy project also keeps the old default, resolved via history rather than silent fall-through to
        // the registry's new defaultTerminal.
        assertEq(
            address(registry.terminalOf(PROJECT_ID_TWO)),
            address(terminalA),
            "unlocked legacy project keeps the cohort default (no silent retarget)"
        );

        // Any project created AFTER the second setDefaultTerminal call gets terminalB.
        assertEq(
            address(registry.terminalOf({projectId: 3})),
            address(terminalB),
            "new project (ID > threshold) follows the new default"
        );
    }
}
