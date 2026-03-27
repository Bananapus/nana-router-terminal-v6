// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import "../../src/JBRouterTerminal.sol";
import "../../src/interfaces/IJBPayerTracker.sol";

// ---------------------------------------------------------------------------
// Harness – exposes the internal `_resolveRefundTo` for direct testing.
// ---------------------------------------------------------------------------

contract PayerTrackerRefundHarness is JBRouterTerminal {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBProjects projects,
        IJBTokens tokens,
        IPermit2 permit2,
        address owner,
        IWETH9 weth,
        IUniswapV3Factory factory,
        IPoolManager poolManager,
        address trustedForwarder
    )
        JBRouterTerminal(
            directory, permissions, projects, tokens, permit2, owner, weth, factory, poolManager, trustedForwarder
        )
    {}

    /// @notice Public wrapper so tests can call `_resolveRefundWithBackupRecipient` directly.
    function resolveRefundTo(address payable fallback_) external view returns (address payable) {
        return _resolveRefundWithBackupRecipient(fallback_);
    }
}

// ---------------------------------------------------------------------------
// Mock – contract that implements IJBPayerTracker with a configurable payer.
// ---------------------------------------------------------------------------

contract MockPayerTracker is IJBPayerTracker {
    address private _payer;

    function setOriginalPayer(address payer) external {
        _payer = payer;
    }

    function originalPayer() external view override returns (address) {
        return _payer;
    }

    /// @notice Calls `resolveRefundTo` on the harness so that `msg.sender` is this contract.
    function callResolveRefundTo(
        PayerTrackerRefundHarness harness,
        address payable fallback_
    )
        external
        view
        returns (address payable)
    {
        return harness.resolveRefundTo(fallback_);
    }
}

// ---------------------------------------------------------------------------
// Mock – contract that does NOT implement IJBPayerTracker.
// ---------------------------------------------------------------------------

contract MockNonTracker {
    /// @notice Calls `resolveRefundTo` on the harness so that `msg.sender` is this contract.
    function callResolveRefundTo(
        PayerTrackerRefundHarness harness,
        address payable fallback_
    )
        external
        view
        returns (address payable)
    {
        return harness.resolveRefundTo(fallback_);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

contract PayerTrackerRefundTest is Test {
    PayerTrackerRefundHarness harness;
    MockPayerTracker tracker;
    MockNonTracker nonTracker;

    address payable constant FALLBACK = payable(address(0xFACA));
    address constant ORIGINAL_PAYER = address(0xBEEF);

    function setUp() public {
        // Deploy the harness with zero/mock addresses – we never exercise anything
        // beyond `_resolveRefundTo`, so these values are irrelevant.
        harness = new PayerTrackerRefundHarness(
            IJBDirectory(address(0)),
            IJBPermissions(address(0)),
            IJBProjects(address(0)),
            IJBTokens(address(0)),
            IPermit2(address(0)),
            address(this), // owner
            IWETH9(address(0)),
            IUniswapV3Factory(address(0)),
            IPoolManager(address(0)),
            address(0) // trustedForwarder
        );

        tracker = new MockPayerTracker();
        nonTracker = new MockNonTracker();
    }

    // -----------------------------------------------------------------------
    // 1. When msg.sender implements IJBPayerTracker and returns a non-zero
    //    payer, the refund address should be the original payer.
    // -----------------------------------------------------------------------

    function test_resolveRefundTo_returnsOriginalPayer_whenTrackerSet() public {
        tracker.setOriginalPayer(ORIGINAL_PAYER);

        address payable result = tracker.callResolveRefundTo(harness, FALLBACK);

        assertEq(result, payable(ORIGINAL_PAYER), "Should return the original payer from IJBPayerTracker");
    }

    // -----------------------------------------------------------------------
    // 2. When msg.sender implements IJBPayerTracker but originalPayer()
    //    returns address(0), the fallback address should be returned.
    // -----------------------------------------------------------------------

    function test_resolveRefundTo_returnsFallback_whenTrackerReturnsZero() public view {
        // Default _payer is address(0); no call to setOriginalPayer needed.
        address payable result = tracker.callResolveRefundTo(harness, FALLBACK);

        assertEq(result, FALLBACK, "Should fall back when originalPayer is address(0)");
    }

    // -----------------------------------------------------------------------
    // 3. When msg.sender is a contract that does NOT implement
    //    IJBPayerTracker, the fallback address should be returned.
    // -----------------------------------------------------------------------

    function test_resolveRefundTo_returnsFallback_whenSenderDoesNotImplementTracker() public view {
        address payable result = nonTracker.callResolveRefundTo(harness, FALLBACK);

        assertEq(result, FALLBACK, "Should fall back when sender has no IJBPayerTracker");
    }

    // -----------------------------------------------------------------------
    // 4. When msg.sender is an EOA (no code), the fallback should be returned.
    // -----------------------------------------------------------------------

    function test_resolveRefundTo_returnsFallback_whenSenderIsEOA() public {
        // Calling directly from this test contract would make msg.sender a
        // contract. Instead we prank as an EOA with no code.
        address eoa = makeAddr("eoa");
        vm.prank(eoa);
        address payable result = harness.resolveRefundTo(FALLBACK);

        assertEq(result, FALLBACK, "Should fall back when sender is an EOA");
    }

    // -----------------------------------------------------------------------
    // 5. Fuzz: any non-zero originalPayer should be forwarded.
    // -----------------------------------------------------------------------

    function testFuzz_resolveRefundTo_forwardsAnyNonZeroPayer(address payer) public {
        vm.assume(payer != address(0));

        tracker.setOriginalPayer(payer);
        address payable result = tracker.callResolveRefundTo(harness, FALLBACK);

        assertEq(result, payable(payer), "Should always forward a non-zero originalPayer");
    }
}
