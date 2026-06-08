// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";
import {DefaultTerminalSegment} from "../../src/structs/DefaultTerminalSegment.sol";

/// @notice Stateful functional-correctness harness for `JBRouterTerminalRegistry` default-terminal resolution.
/// @dev The load-bearing spec (NatSpec on `defaultTerminalProjectIdThreshold` / `setDefaultTerminal`):
///   "This prevents the registry owner from silently rerouting payments for already-deployed projects."
/// We exercise an owner who repeatedly grows the project count and changes the default, recording — at the moment
/// each project ID becomes "deployed" — what terminal the registry resolves for it. The invariants below assert
/// that a later default change can NEVER move an already-deployed project that never set an explicit override.
contract RouterRegistryResolutionHandler is Test {
    JBRouterTerminalRegistry public registry;
    address public projects;
    address public owner;

    /// @notice The simulated `PROJECTS.count()`. Monotonically non-decreasing, like real project minting.
    uint256 public projectCount;

    /// @notice Distinct terminal addresses the owner can rotate between as defaults.
    address[5] public terminals;

    /// @notice For each project ID we have "observed" (resolved at least once while deployed), the terminal it
    /// FIRST resolved to. Resolution must be permanent for unconfigured projects across later default changes.
    mapping(uint256 => address) public firstResolved;
    mapping(uint256 => bool) public observed;

    /// @notice The list of project IDs we have observed, so the invariant can re-check all of them.
    uint256[] public observedIds;

    /// @notice Count of default changes performed (sanity / coverage).
    uint256 public defaultChangeCount;

    constructor(JBRouterTerminalRegistry _registry, address _projects, address _owner, address[5] memory _terminals) {
        registry = _registry;
        projects = _projects;
        owner = _owner;
        terminals = _terminals;
    }

    /// @notice Mint some new projects (grow the count). Then observe the freshly-created IDs so the invariant has a
    /// baseline of what they resolved to at deploy time.
    function mintProjects(uint8 howMany) external {
        uint256 add = bound(howMany, 1, 4);
        uint256 startId = projectCount + 1;
        projectCount += add;
        _mockCount();

        // Observe each new project's deploy-time resolution.
        for (uint256 id = startId; id <= projectCount; ++id) {
            _observe(id);
        }
    }

    /// @notice The owner rotates the default terminal. After the change, re-observe (record-if-new) every project
    /// so the invariant can compare against the deploy-time snapshot.
    function changeDefault(uint8 termIdx) external {
        // Pick one of the candidate terminals (all distinct, none is address(0) or the registry itself).
        address term = terminals[bound(termIdx, 0, terminals.length - 1)];

        // PROJECTS.count() is read inside setDefaultTerminal; keep the mock fresh.
        _mockCount();

        vm.prank(owner);
        registry.setDefaultTerminal(IJBTerminal(term));
        defaultChangeCount++;

        // Re-observe every already-known project; first-seen wins (records deploy-time terminal).
        for (uint256 i; i < observedIds.length; ++i) {
            _recheckNoChange(observedIds[i]);
        }
    }

    /// @notice Record the current resolution for a project the first time we see it.
    function _observe(uint256 id) internal {
        address resolved = address(registry.terminalOf(id));
        if (!observed[id]) {
            observed[id] = true;
            firstResolved[id] = resolved;
            observedIds.push(id);
        }
    }

    /// @notice Assert (during the handler call, so a counterexample shrinks nicely) that an already-observed,
    /// unconfigured project still resolves to exactly what it first resolved to.
    function _recheckNoChange(uint256 id) internal view {
        if (!observed[id]) return;
        address nowResolved = address(registry.terminalOf(id));
        assertEq(nowResolved, firstResolved[id], "deployed project's default resolution changed");
    }

    function _mockCount() internal {
        vm.mockCall(projects, abi.encodeCall(IJBProjects.count, ()), abi.encode(projectCount));
    }

    function observedIdsLength() external view returns (uint256) {
        return observedIds.length;
    }
}

contract RouterRegistryResolutionInvariant is Test {
    JBRouterTerminalRegistry internal registry;
    RouterRegistryResolutionHandler internal handler;

    address internal projects = makeAddr("projects");
    address internal permissions = makeAddr("permissions");
    address internal permit2 = makeAddr("permit2");
    address internal owner = makeAddr("owner");

    address[5] internal terminals;

    function setUp() public {
        // Five distinct, non-zero terminal addresses, none equal to the registry (it rejects self-forwarding).
        terminals[0] = makeAddr("terminal0");
        terminals[1] = makeAddr("terminal1");
        terminals[2] = makeAddr("terminal2");
        terminals[3] = makeAddr("terminal3");
        terminals[4] = makeAddr("terminal4");

        registry = new JBRouterTerminalRegistry(
            IJBPermissions(permissions), IJBProjects(projects), IPermit2(permit2), owner, address(0)
        );

        // The terminals are plain addresses with no code; `JBForwardingCheck.isCircularTerminal` staticcalls
        // `terminalOf` on them, which fails for codeless addresses -> treated as non-forwarding (not circular).
        // `setDefaultTerminal` also reads `PROJECTS.count()`; start at zero.
        vm.mockCall(projects, abi.encodeCall(IJBProjects.count, ()), abi.encode(uint256(0)));

        handler = new RouterRegistryResolutionHandler(registry, projects, owner, terminals);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = RouterRegistryResolutionHandler.mintProjects.selector;
        selectors[1] = RouterRegistryResolutionHandler.changeDefault.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice CROWN JEWEL: every project, once deployed, keeps resolving to the SAME terminal forever (for
    /// projects that never set an explicit override). A later `setDefaultTerminal` must not silently reroute it.
    function invariant_deployedProjectResolutionIsStable() public view {
        uint256 n = handler.observedIdsLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.observedIds(i);
            address nowResolved = address(registry.terminalOf(id));
            assertEq(nowResolved, handler.firstResolved(id), "deployed project resolution drifted after default change");
        }
    }

    /// @notice The history is a clean, sorted, gap-free, non-overlapping partition of the project-id space:
    ///   segment[0].minProjectIdExclusive == 0, each segment.maxProjectId == next.minProjectIdExclusive,
    ///   and every segment is non-empty (min < max OR the first segment covers an empty initial cohort). This is
    ///   what makes the forward walk in `_defaultTerminalFor` return exactly one segment per project ID.
    function invariant_historyIsContiguousPartition() public view {
        uint256 len = registry.defaultTerminalHistoryLength();
        if (len == 0) return;

        DefaultTerminalSegment memory prev = registry.defaultTerminalHistoryAt(0);
        // The very first segment must start the partition at 0.
        assertEq(prev.minProjectIdExclusive, 0, "history does not start at 0");

        for (uint256 i = 1; i < len; ++i) {
            DefaultTerminalSegment memory seg = registry.defaultTerminalHistoryAt(i);
            // Contiguity: this segment picks up exactly where the previous one left off.
            assertEq(seg.minProjectIdExclusive, prev.maxProjectId, "history segments are not contiguous");
            // Monotonic, non-decreasing upper bounds (count() never shrinks).
            assertGe(seg.maxProjectId, prev.maxProjectId, "history maxProjectId went backwards");
            prev = seg;
        }
    }

    /// @notice The current threshold always equals the upper bound of the most recent history segment, and the
    /// current `defaultTerminal` applies to every project ID strictly above it.
    function invariant_thresholdMatchesHistoryTail() public view {
        uint256 len = registry.defaultTerminalHistoryLength();
        if (len == 0) {
            // No default ever set: threshold is 0 and default is the zero terminal.
            assertEq(registry.defaultTerminalProjectIdThreshold(), 0, "threshold nonzero before any default");
            assertEq(address(registry.defaultTerminal()), address(0), "default nonzero before any default");
            return;
        }
        DefaultTerminalSegment memory tail = registry.defaultTerminalHistoryAt(len - 1);
        assertEq(registry.defaultTerminalProjectIdThreshold(), tail.maxProjectId, "threshold != history tail max");

        // A project just above the threshold resolves to the live default terminal.
        uint256 aboveThreshold = registry.defaultTerminalProjectIdThreshold() + 1;
        assertEq(
            address(registry.terminalOf(aboveThreshold)),
            address(registry.defaultTerminal()),
            "above-threshold project does not resolve to live default"
        );
    }
}
