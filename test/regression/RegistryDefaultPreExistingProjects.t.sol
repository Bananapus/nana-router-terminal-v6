// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";

/// @notice Projects that already existed when the registry's first default terminal was set (the pre-existing cohort,
/// including the canonical fee project ID 1) must resolve to that first default so they can route tokens through it.
/// They keep that first default across later default changes — only a project that explicitly calls `setTerminalFor`
/// moves off it.
/// @dev The first `setDefaultTerminal` records a `(0, count]` segment mapping the pre-existing cohort to the new
/// default. Later changes snapshot the outgoing default for its own cohort, so an existing project is never silently
/// rerouted by a default change.
contract RegistryDefaultPreExistingProjectsTest is Test {
    JBRouterTerminalRegistry internal registry;

    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IPermit2 internal permit2 = IPermit2(makeAddr("permit2"));

    address internal owner = makeAddr("owner");

    IJBTerminal internal terminalA = IJBTerminal(makeAddr("terminalA"));
    IJBTerminal internal terminalB = IJBTerminal(makeAddr("terminalB"));
    IJBTerminal internal terminalC = IJBTerminal(makeAddr("terminalC"));

    function setUp() public {
        registry = new JBRouterTerminalRegistry(permissions, projects, permit2, owner, address(0));
    }

    function _mockCount(uint256 count) internal {
        vm.mockCall(address(projects), abi.encodeCall(IJBProjects.count, ()), abi.encode(count));
    }

    function test_preExistingCohort_resolvesToFirstDefault() public {
        // 50 projects exist when the first default is set.
        _mockCount(50);
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        // Projects 1..50 pre-date the first default and now resolve to it so they can route tokens through it.
        for (uint256 id = 1; id <= 50; ++id) {
            assertEq(
                address(registry.terminalOf(id)), address(terminalA), "pre-existing cohort resolves to first default"
            );
        }

        // Projects created after the first default also get terminalA.
        assertEq(address(registry.terminalOf(51)), address(terminalA), "post-first-default resolves to A");
    }

    function test_preExistingCohort_keepsFirstDefault_acrossSubsequentDefaultChanges() public {
        // First default at count = 50.
        _mockCount(50);
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        // Projects 51..150 are created with A as their implicit default.
        // Second default at count = 150.
        _mockCount(150);
        vm.prank(owner);
        registry.setDefaultTerminal(terminalB);

        // Pre-existing cohort (1..50) keeps terminalA — never silently rerouted to B.
        for (uint256 id = 1; id <= 50; ++id) {
            assertEq(address(registry.terminalOf(id)), address(terminalA), "pre-existing keeps A through default churn");
        }

        // The 51..150 cohort keeps A.
        assertEq(address(registry.terminalOf(75)), address(terminalA), "A's cohort keeps A");
        assertEq(address(registry.terminalOf(150)), address(terminalA), "A's cohort upper edge");

        // 151+ gets B.
        assertEq(address(registry.terminalOf(151)), address(terminalB), "B's cohort");
        assertEq(address(registry.terminalOf(500)), address(terminalB), "future projects on B");
    }

    function test_threeDefaultChanges_eachCohortKeepsItsTerminal() public {
        _mockCount(50);
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        _mockCount(150);
        vm.prank(owner);
        registry.setDefaultTerminal(terminalB);

        _mockCount(300);
        vm.prank(owner);
        registry.setDefaultTerminal(terminalC);

        // Pre-existing cohort resolves to the first default (terminalA).
        assertEq(address(registry.terminalOf(25)), address(terminalA), "pre-existing to A");
        // A's cohort
        assertEq(address(registry.terminalOf(75)), address(terminalA), "A's cohort to A");
        assertEq(address(registry.terminalOf(150)), address(terminalA), "A's upper edge to A");
        // B's cohort
        assertEq(address(registry.terminalOf(151)), address(terminalB), "B's lower edge to B");
        assertEq(address(registry.terminalOf(225)), address(terminalB), "B's cohort to B");
        assertEq(address(registry.terminalOf(300)), address(terminalB), "B's upper edge to B");
        // C (current)
        assertEq(address(registry.terminalOf(301)), address(terminalC), "C's lower edge to C");
        assertEq(address(registry.terminalOf(999)), address(terminalC), "future to C");

        // Three segments: the pre-existing (0, 50] plus one per later change.
        assertEq(registry.defaultTerminalHistoryLength(), 3, "three history segments");

        // Segment 0 records the pre-existing cohort (0, 50] on terminalA.
        assertEq(registry.defaultTerminalHistoryAt(0).minProjectIdExclusive, 0, "pre-existing min");
        assertEq(registry.defaultTerminalHistoryAt(0).maxProjectId, 50, "pre-existing max");
        assertEq(address(registry.defaultTerminalHistoryAt(0).terminal), address(terminalA), "pre-existing terminal");

        // Segment 1 records A's cohort (50, 150]
        assertEq(registry.defaultTerminalHistoryAt(1).minProjectIdExclusive, 50, "A min");
        assertEq(registry.defaultTerminalHistoryAt(1).maxProjectId, 150, "A max");
        assertEq(address(registry.defaultTerminalHistoryAt(1).terminal), address(terminalA), "A terminal");

        // Segment 2 records B's cohort (150, 300]
        assertEq(registry.defaultTerminalHistoryAt(2).minProjectIdExclusive, 150, "B min");
        assertEq(registry.defaultTerminalHistoryAt(2).maxProjectId, 300, "B max");
        assertEq(address(registry.defaultTerminalHistoryAt(2).terminal), address(terminalB), "B terminal");
    }
}
