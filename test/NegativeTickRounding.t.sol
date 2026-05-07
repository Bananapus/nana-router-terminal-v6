// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Minimal harness that isolates the tick-rounding arithmetic from JBRouterTerminal._getV4Tick().
/// @dev The TWAP window is 120 seconds, matching `_TWAP_WINDOW` in production.
contract TickRoundingHarness {
    int56 public constant PERIOD = 120;

    /// @notice Old (buggy) logic: Solidity truncation toward zero.
    /// For negative non-exact deltas this rounds toward zero instead of toward negative infinity.
    function oldTick(int56 tickDelta) external pure returns (int24 tick) {
        // forge-lint: disable-next-line(unsafe-typecast)
        tick = int24(tickDelta / PERIOD);
    }

    /// @notice New (fixed) logic: explicit floor-division for negative ticks (Uniswap convention).
    function newTick(int56 tickDelta) external pure returns (int24 tick) {
        // forge-lint: disable-next-line(unsafe-typecast)
        tick = int24(tickDelta / PERIOD);
        // Round towards negative infinity for negative ticks (Uniswap convention).
        if (tickDelta < 0 && (tickDelta % PERIOD != 0)) tick--;
    }
}

/// @notice Regression tests proving the negative-tick rounding fix from regression Pass-12.
/// @dev Uniswap's arithmetic-mean tick must be floor-divided (rounded toward negative infinity).
///      Solidity integer division truncates toward zero, which is incorrect for negative non-exact values.
///      Example: -12001 / 120 in Solidity = -100 (truncation), but Uniswap expects -101 (floor).
contract NegativeTickRoundingTest is Test {
    TickRoundingHarness harness;

    function setUp() public {
        harness = new TickRoundingHarness();
    }

    // ------------------------------------------------------------------
    // Positive exact: tickDelta = 12000 (100 * 120) -> tick = 100
    // ------------------------------------------------------------------
    function test_positiveExact() public view {
        int56 tickDelta = 12_000; // 100 * 120, divides evenly.

        assertEq(harness.oldTick(tickDelta), 100, "old: positive exact");
        assertEq(harness.newTick(tickDelta), 100, "new: positive exact");
    }

    // ------------------------------------------------------------------
    // Positive non-exact: tickDelta = 12001 -> tick = 100
    // Truncation equals floor for positive values, so both are correct.
    // ------------------------------------------------------------------
    function test_positiveNonExact() public view {
        int56 tickDelta = 12_001;

        assertEq(harness.oldTick(tickDelta), 100, "old: positive non-exact");
        assertEq(harness.newTick(tickDelta), 100, "new: positive non-exact");
    }

    // ------------------------------------------------------------------
    // Negative exact: tickDelta = -12000 -> tick = -100
    // Exact division — no rounding difference.
    // ------------------------------------------------------------------
    function test_negativeExact() public view {
        int56 tickDelta = -12_000; // -100 * 120, divides evenly.

        assertEq(harness.oldTick(tickDelta), -100, "old: negative exact");
        assertEq(harness.newTick(tickDelta), -100, "new: negative exact");
    }

    // ------------------------------------------------------------------
    // Negative non-exact (THE BUG CASE): tickDelta = -12001 -> tick should be -101
    // Old logic: -12001 / 120 = -100 (truncation toward zero — WRONG).
    // New logic: -12001 / 120 = -100, then tick-- = -101 (floor — CORRECT).
    // ------------------------------------------------------------------
    function test_negativeNonExact_bugCase() public view {
        int56 tickDelta = -12_001;

        // Old logic truncates toward zero: WRONG for Uniswap.
        assertEq(harness.oldTick(tickDelta), -100, "old: negative non-exact truncates toward zero");

        // New logic floors toward negative infinity: CORRECT for Uniswap.
        assertEq(harness.newTick(tickDelta), -101, "new: negative non-exact floors toward -inf");
    }

    // ------------------------------------------------------------------
    // Zero: tickDelta = 0 -> tick = 0
    // ------------------------------------------------------------------
    function test_zero() public view {
        int56 tickDelta = 0;

        assertEq(harness.oldTick(tickDelta), 0, "old: zero");
        assertEq(harness.newTick(tickDelta), 0, "new: zero");
    }

    // ------------------------------------------------------------------
    // Small negative: tickDelta = -1 -> floor(-1/120) = -1, NOT 0
    // Old logic: -1 / 120 = 0 (truncation toward zero — WRONG).
    // New logic: -1 / 120 = 0, then tick-- = -1 (floor — CORRECT).
    // ------------------------------------------------------------------
    function test_smallNegative() public view {
        int56 tickDelta = -1;

        // Old logic truncates toward zero: WRONG for Uniswap.
        assertEq(harness.oldTick(tickDelta), 0, "old: small negative truncates to zero");

        // New logic floors toward negative infinity: CORRECT for Uniswap.
        assertEq(harness.newTick(tickDelta), -1, "new: small negative floors to -1");
    }

    // ------------------------------------------------------------------
    // Additional edge case: tickDelta = -120 (exactly -1 tick period).
    // Exact division — both should agree at -1.
    // ------------------------------------------------------------------
    function test_negativeExactOnePeriod() public view {
        int56 tickDelta = -120;

        assertEq(harness.oldTick(tickDelta), -1, "old: -120 exact");
        assertEq(harness.newTick(tickDelta), -1, "new: -120 exact");
    }

    // ------------------------------------------------------------------
    // Additional edge case: tickDelta = -119 -> floor(-119/120) = -1
    // Old logic: -119 / 120 = 0 (truncation — WRONG).
    // New logic: 0, then tick-- = -1 (floor — CORRECT).
    // ------------------------------------------------------------------
    function test_negativeAlmostOnePeriod() public view {
        int56 tickDelta = -119;

        assertEq(harness.oldTick(tickDelta), 0, "old: -119 truncates to 0");
        assertEq(harness.newTick(tickDelta), -1, "new: -119 floors to -1");
    }
}
