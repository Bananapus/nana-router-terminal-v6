// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

import {JBForwardingCheck} from "../../src/libraries/JBForwardingCheck.sol";

/// @notice A configurable forwarding terminal: `terminalOf(projectId)` returns a fixed next hop. With `next ==
/// address(0)` it is a terminal (non-forwarding) endpoint.
contract MockForwardingTerminal {
    address public next;

    function setNext(address _next) external {
        next = _next;
    }

    function terminalOf(uint256) external view returns (IJBTerminal) {
        return IJBTerminal(next);
    }
}

/// @notice A terminal whose `terminalOf` always reverts — models a plain (non-forwarding) terminal that does not
/// implement `IJBForwardingTerminal`. The check must treat it as a chain endpoint, not a cycle.
contract MockRevertingTerminal {
    function terminalOf(uint256) external pure returns (IJBTerminal) {
        revert("not a forwarding terminal");
    }
}

/// @notice Functional-correctness properties for `JBForwardingCheck.isCircularTerminal`.
/// @dev The library is `view` and probes external terminals via staticcall, so these are FUZZ/UNIT properties
/// (not Halmos — symbolic execution of arbitrary external staticcall topologies is intractable). The spec
/// (NatSpec): walk up to 5 hops; return true iff the chain reaches `target`; a non-forwarding hop (revert / zero /
/// truncated return) ENDS the chain (not circular); 5 hops without resolution is treated as circular (fail-safe).
contract JBForwardingCheckProperties is Test {
    uint256 internal constant PID = 7;

    /// @notice Helper that exposes the internal library through an external call so it can be fuzzed.
    function _isCircular(address target, IJBTerminal terminal) external view returns (bool) {
        return JBForwardingCheck.isCircularTerminal({target: target, projectId: PID, terminal: terminal});
    }

    /// @notice Property: a terminal that IS the target is immediately circular (hop 0).
    function test_selfIsCircular() public {
        address target = makeAddr("target");
        assertTrue(this._isCircular(target, IJBTerminal(target)), "target itself must be circular");
    }

    /// @notice Property: an endpoint terminal (forwards to zero) is NOT circular.
    function test_endpointTerminalNotCircular() public {
        MockForwardingTerminal t = new MockForwardingTerminal();
        t.setNext(address(0));
        assertFalse(this._isCircular(makeAddr("target"), IJBTerminal(address(t))), "zero-next endpoint not circular");
    }

    /// @notice Property: a non-forwarding terminal (terminalOf reverts) is NOT circular — the staticcall fails and
    /// the chain ends cleanly.
    function test_revertingTerminalNotCircular() public {
        MockRevertingTerminal t = new MockRevertingTerminal();
        assertFalse(this._isCircular(makeAddr("target"), IJBTerminal(address(t))), "reverting terminal not circular");
    }

    /// @notice Property: a codeless address is NOT circular (staticcall to no-code succeeds with empty return,
    /// which is < 32 bytes -> chain ends).
    function test_codelessAddressNotCircular() public {
        address codeless = makeAddr("codeless");
        assertFalse(this._isCircular(makeAddr("target"), IJBTerminal(codeless)), "codeless address not circular");
    }

    /// @notice Property: a finite chain that loops back to the target within the hop budget is detected as
    /// circular. We build target <- ... where the last forwarding hop points at `target`.
    /// @dev chainLen is the number of forwarding hops (1..4) before the pointer reaches `target`.
    function testFuzz_chainBackToTargetIsCircular(uint8 chainLenRaw) public {
        uint256 chainLen = bound(chainLenRaw, 1, 4);
        address target = makeAddr("target");

        // Build chain[0] -> chain[1] -> ... -> chain[chainLen-1] -> target.
        MockForwardingTerminal[] memory chain = new MockForwardingTerminal[](chainLen);
        for (uint256 i; i < chainLen; ++i) {
            chain[i] = new MockForwardingTerminal();
        }
        for (uint256 i; i < chainLen; ++i) {
            address nextHop = (i + 1 < chainLen) ? address(chain[i + 1]) : target;
            chain[i].setNext(nextHop);
        }

        assertTrue(this._isCircular(target, IJBTerminal(address(chain[0]))), "chain back to target must be circular");
    }

    /// @notice Property: a chain that terminates at an endpoint within budget (never touching target) is NOT
    /// circular. chainLen forwarding hops, last one points at zero.
    function testFuzz_chainToEndpointNotCircular(uint8 chainLenRaw) public {
        uint256 chainLen = bound(chainLenRaw, 1, 4);
        address target = makeAddr("target");

        MockForwardingTerminal[] memory chain = new MockForwardingTerminal[](chainLen);
        for (uint256 i; i < chainLen; ++i) {
            chain[i] = new MockForwardingTerminal();
        }
        for (uint256 i; i < chainLen; ++i) {
            address nextHop = (i + 1 < chainLen) ? address(chain[i + 1]) : address(0);
            chain[i].setNext(nextHop);
        }

        assertFalse(
            this._isCircular(target, IJBTerminal(address(chain[0]))), "endpoint-terminated chain must not be circular"
        );
    }

    /// @notice Property (fail-safe): an unresolved chain longer than the 5-hop budget that never reaches the target
    /// and never ends is conservatively treated as circular. We build a self-referential 2-cycle that the target is
    /// NOT part of; the walk exhausts its budget and returns true.
    function test_unboundedCycleNotContainingTargetIsCircularBySafety() public {
        address target = makeAddr("target");
        MockForwardingTerminal a = new MockForwardingTerminal();
        MockForwardingTerminal b = new MockForwardingTerminal();
        // a -> b -> a -> b ... never hits target, never ends.
        a.setNext(address(b));
        b.setNext(address(a));

        assertTrue(
            this._isCircular(target, IJBTerminal(address(a))),
            "budget-exhausting cycle must be treated as circular (fail-safe)"
        );
    }
}
