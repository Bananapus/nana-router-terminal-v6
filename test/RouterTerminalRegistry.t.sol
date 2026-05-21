// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {JBRouterTerminalRegistry} from "../src/JBRouterTerminalRegistry.sol";
import {IJBRouterTerminalRegistry} from "../src/interfaces/IJBRouterTerminalRegistry.sol";

contract RegistryTestERC20 {
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

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
        // Mock `PROJECTS.count()` for tests that don't override it. `setDefaultTerminal` reads
        // the current count to record the threshold + snapshot. Default to 0 (fresh chain).
        vm.mockCall(address(projects), abi.encodeCall(IJBProjects.count, ()), abi.encode(uint256(0)));
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

    function test_disallowTerminal_revertsIfDefault() public {
        vm.startPrank(owner);
        registry.setDefaultTerminal(terminalA);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalRegistry.JBRouterTerminalRegistry_CannotDisallowDefaultTerminal.selector, terminalA
            )
        );
        registry.disallowTerminal(terminalA);
        vm.stopPrank();
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

    function test_accountingContext_passthroughDoesNotCorrectTerminalDecimals() public {
        address usdcLike = makeAddr("usdcLike");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 usdcCurrency = uint32(uint160(usdcLike));
        JBAccountingContext memory expected =
            JBAccountingContext({token: usdcLike, decimals: 18, currency: usdcCurrency});

        vm.mockCall(
            address(terminalA),
            abi.encodeCall(IJBTerminal.accountingContextForTokenOf, (projectId, usdcLike)),
            abi.encode(expected)
        );

        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        JBAccountingContext memory context = registry.accountingContextForTokenOf(projectId, usdcLike);
        assertEq(context.token, usdcLike);
        assertEq(context.decimals, 18);
        assertEq(context.currency, expected.currency);
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
        registry.lockTerminalFor(projectId, terminalA);

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
        registry.lockTerminalFor(projectId, terminalA);

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
        registry.lockTerminalFor(projectId, terminalA);
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

    function test_pay_revertsBeforeAcceptingErc20WhenResolvedTerminalIsZero() public {
        _mockProjectsCount({count: 50});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        RegistryTestERC20 token = new RegistryTestERC20();
        token.mint(address(this), 1 ether);
        token.approve(address(registry), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(JBRouterTerminalRegistry.JBRouterTerminalRegistry_TerminalNotSet.selector, projectId)
        );
        registry.pay({
            projectId: projectId,
            token: address(token),
            amount: 1 ether,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        assertEq(token.balanceOf(address(this)), 1 ether);
        assertEq(token.balanceOf(address(registry)), 0);
    }

    function test_previewPayFor_forwardsToDefault() public {
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        JBRuleset memory expectedRuleset = JBRuleset({
            cycleNumber: 1,
            id: 2,
            basedOnId: 3,
            start: 4,
            duration: 5,
            weight: 6,
            weightCutPercent: 7,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 8
        });
        JBPayHookSpecification[] memory expectedSpecs = new JBPayHookSpecification[](0);

        vm.mockCall(
            address(terminalA),
            abi.encodeCall(
                IJBTerminal.previewPayFor, (projectId, JBConstants.NATIVE_TOKEN, 1 ether, address(this), bytes(""))
            ),
            abi.encode(expectedRuleset, uint256(9), uint256(10), expectedSpecs)
        );

        (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        ) = registry.previewPayFor(projectId, JBConstants.NATIVE_TOKEN, 1 ether, address(this), "");

        assertEq(ruleset.id, expectedRuleset.id);
        assertEq(beneficiaryTokenCount, 9);
        assertEq(reservedTokenCount, 10);
        assertEq(hookSpecifications.length, 0);
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

    function test_addToBalanceOf_revertsBeforeForwardingNativeWhenResolvedTerminalIsZero() public {
        _mockProjectsCount({count: 50});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        vm.deal(address(this), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(JBRouterTerminalRegistry.JBRouterTerminalRegistry_TerminalNotSet.selector, projectId)
        );
        registry.addToBalanceOf{value: 1 ether}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: ""
        });

        assertEq(address(registry).balance, 0);
        assertEq(address(this).balance, 1 ether);
    }

    // ──────────────────────────────────────────────────────────────────────
    // setDefaultTerminal — threshold protection for existing projects
    //
    // The threshold + snapshot history ensure the registry owner cannot
    // silently reroute payments for already-deployed projects via a default
    // change. Each setDefaultTerminal call:
    //   - records the *outgoing* default into _defaultTerminalHistory keyed
    //     by the current PROJECTS.count() as the segment's maxProjectId, and
    //   - updates defaultTerminal + defaultTerminalProjectIdThreshold for
    //     the next cohort of projects (ID > the snapshot count).
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Mock PROJECTS.count() to control which cohort a project ID falls into.
    function _mockProjectsCount(uint256 count) internal {
        vm.mockCall(address(projects), abi.encodeCall(IJBProjects.count, ()), abi.encode(count));
    }

    function test_setDefaultTerminal_firstCallNoHistory() public {
        // count == 0 at deploy; the first setDefaultTerminal has no outgoing default to snapshot.
        _mockProjectsCount({count: 0});

        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        assertEq(registry.defaultTerminalProjectIdThreshold(), 0);
        assertEq(registry.defaultTerminalHistoryLength(), 0);
        // Every projectId > 0 (i.e. every real project) resolves to terminalA.
        assertEq(address(registry.defaultTerminalFor({projectId: 1})), address(terminalA));
        assertEq(address(registry.defaultTerminalFor({projectId: 1000})), address(terminalA));
    }

    function test_setDefaultTerminal_existingProjectsKeepOldDefault() public {
        // T1 set when count = 0, so all current projects (1..) resolve to T1.
        _mockProjectsCount({count: 0});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        // 5 projects exist. Owner pushes a new default; should NOT reroute the first 5.
        _mockProjectsCount({count: 5});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalB);

        // Threshold = 5, history has one entry {maxProjectId: 5, terminal: terminalA}.
        assertEq(registry.defaultTerminalProjectIdThreshold(), 5);
        assertEq(registry.defaultTerminalHistoryLength(), 1);

        // Existing projects (ID <= 5) keep terminalA on fall-through.
        for (uint256 i = 1; i <= 5; ++i) {
            assertEq(address(registry.defaultTerminalFor({projectId: i})), address(terminalA), "legacy cohort");
        }

        // New projects (ID > 5) get terminalB.
        assertEq(address(registry.defaultTerminalFor({projectId: 6})), address(terminalB));
        assertEq(address(registry.defaultTerminalFor({projectId: 100})), address(terminalB));
    }

    function test_setDefaultTerminal_multiCohortHistory() public {
        // Three cohorts: T1 for projects 1..5, T2 for 6..10, T3 for 11+.
        IJBTerminal terminalC = IJBTerminal(makeAddr("terminalC"));

        _mockProjectsCount({count: 0});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        _mockProjectsCount({count: 5});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalB);

        _mockProjectsCount({count: 10});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalC);

        // Threshold reflects the most recent setDefaultTerminal call.
        assertEq(registry.defaultTerminalProjectIdThreshold(), 10);
        // History has 2 entries (no snapshot for first-ever default).
        assertEq(registry.defaultTerminalHistoryLength(), 2);

        // History[0] covers projects 1..5 with terminalA.
        assertEq(registry.defaultTerminalHistoryAt({index: 0}).maxProjectId, 5);
        assertEq(address(registry.defaultTerminalHistoryAt({index: 0}).terminal), address(terminalA));
        // History[1] covers projects 6..10 with terminalB.
        assertEq(registry.defaultTerminalHistoryAt({index: 1}).maxProjectId, 10);
        assertEq(address(registry.defaultTerminalHistoryAt({index: 1}).terminal), address(terminalB));

        // Each cohort resolves to its correct historical default.
        assertEq(address(registry.defaultTerminalFor({projectId: 3})), address(terminalA), "cohort 1");
        assertEq(address(registry.defaultTerminalFor({projectId: 5})), address(terminalA), "cohort 1 boundary");
        assertEq(address(registry.defaultTerminalFor({projectId: 6})), address(terminalB), "cohort 2 start");
        assertEq(address(registry.defaultTerminalFor({projectId: 10})), address(terminalB), "cohort 2 boundary");
        assertEq(address(registry.defaultTerminalFor({projectId: 11})), address(terminalC), "cohort 3 start");
        assertEq(address(registry.defaultTerminalFor({projectId: 999})), address(terminalC), "cohort 3 far");
    }

    function test_terminalOf_legacyProjectKeepsCohortDefault() public {
        // terminalOf is the public consumer-facing accessor — it must also honor
        // the threshold (mirrors the same fall-through code path internally).
        _mockProjectsCount({count: 0});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        _mockProjectsCount({count: 5});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalB);

        // Legacy project with no explicit terminal resolves via terminalOf to terminalA.
        assertEq(address(registry.terminalOf({projectId: 3})), address(terminalA));
        // New project resolves to terminalB.
        assertEq(address(registry.terminalOf({projectId: 7})), address(terminalB));
    }

    function test_terminalOf_legacyProjectExplicitOverridesCohort() public {
        // Explicit setTerminalFor wins over the threshold-resolved default.
        _mockProjectsCount({count: 0});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        _mockProjectsCount({count: 5});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalB);

        // Project 3 (legacy cohort) explicitly opts into terminalB.
        vm.mockCall(address(projects), abi.encodeCall(IERC721.ownerOf, (3)), abi.encode(projectOwner));
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature(
                "hasPermission(address,address,uint256,uint256,bool,bool)",
                projectOwner,
                projectOwner,
                uint256(3),
                JBPermissionIds.SET_ROUTER_TERMINAL,
                true,
                true
            ),
            abi.encode(true)
        );
        vm.prank(projectOwner);
        registry.setTerminalFor({projectId: 3, terminal: terminalB});

        // Project 3 now resolves to terminalB despite being in the legacy cohort.
        assertEq(address(registry.terminalOf({projectId: 3})), address(terminalB));
    }

    function test_lockTerminalFor_snapshotsCohortDefault() public {
        // The lock-snapshot path must capture the cohort-correct default, not the
        // registry-wide current default. Project 3 (legacy) locked AFTER a default
        // change should freeze terminalA, not terminalB.
        _mockProjectsCount({count: 0});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        _mockProjectsCount({count: 5});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalB);

        // Lock project 3 (legacy cohort). Caller is project owner.
        vm.mockCall(address(projects), abi.encodeCall(IERC721.ownerOf, (3)), abi.encode(projectOwner));
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature(
                "hasPermission(address,address,uint256,uint256,bool,bool)",
                projectOwner,
                projectOwner,
                uint256(3),
                JBPermissionIds.SET_ROUTER_TERMINAL,
                true,
                true
            ),
            abi.encode(true)
        );

        vm.prank(projectOwner);
        registry.lockTerminalFor({projectId: 3, expectedTerminal: terminalA});

        assertTrue(registry.hasLockedTerminal(3));
        // After lock, project 3 still resolves to its cohort's terminal (terminalA),
        // never to the registry-wide current default (terminalB).
        assertEq(address(registry.terminalOf({projectId: 3})), address(terminalA));
    }

    function test_lockTerminalFor_revertsOnExpectedTerminalMismatch() public {
        // lockTerminalFor takes an `expectedTerminal` arg that must match the
        // resolved default. Locking a legacy project while expecting the NEW
        // default should revert — this is a guard against operator confusion.
        _mockProjectsCount({count: 0});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        _mockProjectsCount({count: 5});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalB);

        vm.mockCall(address(projects), abi.encodeCall(IERC721.ownerOf, (3)), abi.encode(projectOwner));
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature(
                "hasPermission(address,address,uint256,uint256,bool,bool)",
                projectOwner,
                projectOwner,
                uint256(3),
                JBPermissionIds.SET_ROUTER_TERMINAL,
                true,
                true
            ),
            abi.encode(true)
        );

        // Caller expects terminalB (current default) but cohort default is terminalA.
        vm.prank(projectOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalRegistry.JBRouterTerminalRegistry_TerminalMismatch.selector, terminalA, terminalB
            )
        );
        registry.lockTerminalFor({projectId: 3, expectedTerminal: terminalB});
    }

    function test_disallowTerminal_currentDefaultRevertsAfterUpdate() public {
        // Regression: disallowTerminal must always check against the registry-wide
        // current `defaultTerminal`, not historical ones — operator can disallow an
        // old default once it has been replaced.
        _mockProjectsCount({count: 0});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalA);

        _mockProjectsCount({count: 5});
        vm.prank(owner);
        registry.setDefaultTerminal(terminalB);

        // Disallowing the CURRENT default (terminalB) reverts.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalRegistry.JBRouterTerminalRegistry_CannotDisallowDefaultTerminal.selector, terminalB
            )
        );
        registry.disallowTerminal(terminalB);

        // Disallowing the previous default (terminalA) is allowed even though it's
        // still the cohort default for projects 1..5 in the history. (Those legacy
        // projects retain their fallback through the history snapshot; the allowlist
        // governs whether NEW projects can opt into the terminal via setTerminalFor.)
        vm.prank(owner);
        registry.disallowTerminal(terminalA);
        assertFalse(registry.isTerminalAllowed(terminalA));

        // Legacy cohort still resolves to terminalA via the history.
        assertEq(address(registry.defaultTerminalFor({projectId: 3})), address(terminalA));
    }

    function test_defaultTerminalFor_returnsZeroWhenNoDefaultEverSet() public view {
        // Edge: registry deployed, no setDefaultTerminal ever called → fall-through
        // resolves to zero. Production deploy script calls setDefaultTerminal at
        // construction time, so this case should not occur on-chain, but the
        // helper still needs to return a defined value.
        assertEq(address(registry.defaultTerminalFor({projectId: 0})), address(0));
        assertEq(address(registry.defaultTerminalFor({projectId: 1})), address(0));
        assertEq(address(registry.defaultTerminalFor({projectId: 1_000_000})), address(0));
    }
}
