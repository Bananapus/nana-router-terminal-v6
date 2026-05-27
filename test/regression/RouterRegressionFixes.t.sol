// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

import {JBForwardingCheck} from "../../src/libraries/JBForwardingCheck.sol";
import {IJBForwardingTerminal} from "../../src/interfaces/IJBForwardingTerminal.sol";

/// @dev A forwarding terminal that always points to a fixed next hop.
contract MockForwarder is IJBForwardingTerminal {
    IJBTerminal internal immutable NEXT;

    constructor(IJBTerminal next_) {
        NEXT = next_;
    }

    function terminalOf(uint256) external view override returns (IJBTerminal) {
        return NEXT;
    }

    // Satisfy IJBTerminal — not called in these tests.
    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        return 0;
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}
}

/// @dev A plain terminal (non-forwarding).
contract MockPlainTerminal {
    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        return 0;
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}
}

/// @title Shared circular terminal check via JBForwardingCheck library
contract CircularTerminalRegressionTest is Test {
    address constant ROUTER = address(0x1234);
    uint256 constant PROJECT_ID = 1;

    /// @notice Direct cycle: terminal == router.
    function test_circularTerminal_directCycleDetected() public view {
        assertTrue(
            JBForwardingCheck.isCircularTerminal(ROUTER, PROJECT_ID, IJBTerminal(ROUTER)),
            "direct cycle should be detected"
        );
    }

    /// @notice 2-hop cycle: A -> B -> router.
    function test_circularTerminal_twoHopCycleDetected() public {
        MockForwarder b = new MockForwarder(IJBTerminal(ROUTER));
        MockForwarder a = new MockForwarder(IJBTerminal(address(b)));

        assertTrue(
            JBForwardingCheck.isCircularTerminal(ROUTER, PROJECT_ID, IJBTerminal(address(a))),
            "2-hop cycle should be detected"
        );
    }

    /// @notice Non-forwarding terminal: no cycle.
    function test_circularTerminal_nonForwardingTerminalNotCircular() public {
        MockPlainTerminal plain = new MockPlainTerminal();

        assertFalse(
            JBForwardingCheck.isCircularTerminal(ROUTER, PROJECT_ID, IJBTerminal(address(plain))),
            "non-forwarding terminal should not be circular"
        );
    }

    /// @notice Forwarding chain that ends at a non-router destination: no cycle.
    function test_circularTerminal_forwardChainToNonRouterNotCircular() public {
        MockPlainTerminal dest = new MockPlainTerminal();
        MockForwarder a = new MockForwarder(IJBTerminal(address(dest)));

        assertFalse(
            JBForwardingCheck.isCircularTerminal(ROUTER, PROJECT_ID, IJBTerminal(address(a))),
            "chain ending at non-router should not be circular"
        );
    }

    /// @notice 5-hop deep chain without hitting router — treated as circular for safety.
    function test_circularTerminal_deepChainTreatedAsCircular() public {
        // Create a 6-deep chain: f1 -> f2 -> f3 -> f4 -> f5 -> f6 (never hits router)
        MockPlainTerminal end = new MockPlainTerminal();
        MockForwarder f6 = new MockForwarder(IJBTerminal(address(end)));
        MockForwarder f5 = new MockForwarder(IJBTerminal(address(f6)));
        MockForwarder f4 = new MockForwarder(IJBTerminal(address(f5)));
        MockForwarder f3 = new MockForwarder(IJBTerminal(address(f4)));
        MockForwarder f2 = new MockForwarder(IJBTerminal(address(f3)));
        MockForwarder f1 = new MockForwarder(IJBTerminal(address(f2)));

        assertTrue(
            JBForwardingCheck.isCircularTerminal(ROUTER, PROJECT_ID, IJBTerminal(address(f1))),
            "6-deep chain should be treated as circular"
        );
    }
}
