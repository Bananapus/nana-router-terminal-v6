// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

/// @title M30_PreviewCashOutShortcircuitDivergence
/// @notice Before the fix, `_previewCashOutLoop` could short-circuit on the preferred-token check even when
///         `sourceProjectIdOverride != 0`, skipping the forced first cashout hop. The execution path
///         (`_cashOutLoop`) correctly gates that short-circuit behind `sourceProjectIdOverride == 0`.
///         This test verifies that the preview now mirrors execution: the forced hop is taken before any
///         preferred-token early return.
contract M30_PreviewCashOutShortcircuitDivergence is Test {
    JBRouterTerminal internal router;

    IJBDirectory internal mockDirectory;
    IJBTokens internal mockTokens;

    address internal mockCashOutTerminal = makeAddr("cashOutTerminal");
    address internal mockDestTerminal = makeAddr("destTerminal");

    uint256 internal destProjectId = 1;
    uint256 internal sourceProjectId = 2;
    uint256 internal cashOutAmount = 100e18;
    uint256 internal reclaimAmount = 60e18;

    function setUp() public {
        mockDirectory = IJBDirectory(makeAddr("directory"));
        mockTokens = IJBTokens(makeAddr("tokens"));

        vm.etch(address(mockDirectory), hex"00");
        vm.etch(address(mockTokens), hex"00");
        vm.etch(mockCashOutTerminal, hex"00");
        vm.etch(mockDestTerminal, hex"00");

        IPermit2 mockPermit2 = IPermit2(makeAddr("permit2"));
        vm.etch(address(mockPermit2), hex"00");
        IWETH9 mockWeth = IWETH9(makeAddr("weth"));
        vm.etch(address(mockWeth), hex"00");
        IUniswapV3Factory mockFactory = IUniswapV3Factory(makeAddr("factory"));
        vm.etch(address(mockFactory), hex"00");
        IPoolManager mockPoolManager = IPoolManager(makeAddr("poolManager"));
        vm.etch(address(mockPoolManager), hex"00");

        router = new JBRouterTerminal({
            directory: mockDirectory,
            tokens: mockTokens,
            permit2: mockPermit2,
            weth: mockWeth,
            factory: mockFactory,
            poolManager: mockPoolManager,
            buybackHook: address(0),
            univ4Hook: address(0),
            trustedForwarder: address(0)
        });

        // --- Mock: source project terminal list ---
        IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
        sourceTerminals[0] = IJBTerminal(mockCashOutTerminal);
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
            abi.encode(sourceTerminals)
        );

        // --- Mock: IJBCashOutTerminal support ---
        vm.mockCall(
            mockCashOutTerminal,
            abi.encodeCall(IERC165.supportsInterface, (type(IJBCashOutTerminal).interfaceId)),
            abi.encode(true)
        );

        // --- Mock: source terminal accounting contexts (accepts NATIVE_TOKEN) ---
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        vm.mockCall(
            mockCashOutTerminal,
            abi.encodeCall(IJBTerminal.accountingContextsOf, (sourceProjectId)),
            abi.encode(contexts)
        );

        // --- Mock: dest project accepts NATIVE_TOKEN via destTerminal ---
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(mockDestTerminal)
        );

        // --- Mock: previewCashOutFrom returns reclaimAmount ---
        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        JBCashOutHookSpecification[] memory emptyHooks = new JBCashOutHookSpecification[](0);
        vm.mockCall(
            mockCashOutTerminal,
            abi.encodeWithSelector(IJBCashOutTerminal.previewCashOutFrom.selector),
            abi.encode(ruleset, reclaimAmount, uint256(0), emptyHooks)
        );

        // --- Mock: tokens.projectIdOf returns 0 for NATIVE_TOKEN (not a JB project token) ---
        vm.mockCall(
            address(mockTokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(JBConstants.NATIVE_TOKEN))),
            abi.encode(uint256(0))
        );
    }

    /// @notice When sourceProjectIdOverride is set and the preferred token matches the current token, the preview
    ///         must NOT short-circuit. It must take the forced cashout hop, then resolve the destination terminal.
    function test_previewDoesNotShortcircuitWithSourceOverride() public view {
        // The token being cashed out is a JB project token (represented by address(0xABC) for this test).
        // The preferred token is NATIVE_TOKEN, and the source terminal reclaims NATIVE_TOKEN.
        // With sourceProjectIdOverride != 0, the preview must NOT short-circuit even though preferredToken
        // matches the reclaim token. It must perform the hop first.

        // Call previewCashOutLoopOf with:
        //   - token = NATIVE_TOKEN (would match preferredToken immediately without the fix)
        //   - sourceProjectIdOverride = sourceProjectId (forces a cashout hop)
        //   - preferredToken = NATIVE_TOKEN
        (IJBTerminal destTerminal, address finalToken, uint256 finalAmount) = router.previewCashOutLoopOf({
            destProjectId: destProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: cashOutAmount,
            sourceProjectIdOverride: sourceProjectId,
            metadata: "",
            preferredToken: JBConstants.NATIVE_TOKEN
        });

        // The preview must have performed the cashout hop, so the final amount should be the reclaim amount,
        // not the original cashOutAmount.
        assertEq(finalAmount, reclaimAmount, "preview must perform the forced cashout hop, not short-circuit");
        assertEq(finalToken, JBConstants.NATIVE_TOKEN, "final token should be NATIVE_TOKEN after the hop");
        assertEq(address(destTerminal), mockDestTerminal, "preview should resolve the dest terminal after the hop");
    }

    /// @notice When sourceProjectIdOverride is 0 and the preferred token matches, the preview SHOULD
    ///         short-circuit immediately (no cashout hop needed).
    function test_previewShortcircuitsWithoutSourceOverride() public view {
        // With sourceProjectIdOverride == 0, the preferred-token check should fire immediately.
        (IJBTerminal destTerminal, address finalToken, uint256 finalAmount) = router.previewCashOutLoopOf({
            destProjectId: destProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: cashOutAmount,
            sourceProjectIdOverride: 0,
            metadata: "",
            preferredToken: JBConstants.NATIVE_TOKEN
        });

        // The preview should short-circuit: amount unchanged, terminal resolved directly.
        assertEq(finalAmount, cashOutAmount, "preview should short-circuit and return original amount");
        assertEq(finalToken, JBConstants.NATIVE_TOKEN, "final token should be the preferred token");
        assertEq(address(destTerminal), mockDestTerminal, "dest terminal should be resolved immediately");
    }

    /// @notice After sourceProjectIdOverride is consumed on the first hop, the second iteration should
    ///         be able to short-circuit via the preferred-token check.
    function test_previewShortcircuitsAfterOverrideConsumed() public view {
        // Set up a scenario where the first hop reclaims NATIVE_TOKEN, then the second iteration
        // should short-circuit because sourceProjectIdOverride is now 0 and preferredToken matches.
        // This is exactly the same as test_previewDoesNotShortcircuitWithSourceOverride — the forced
        // hop happens on iteration 0, then iteration 1 should short-circuit because the reclaimed
        // NATIVE_TOKEN matches the preferred NATIVE_TOKEN and sourceProjectIdOverride is now 0.

        (IJBTerminal destTerminal, address finalToken, uint256 finalAmount) = router.previewCashOutLoopOf({
            destProjectId: destProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: cashOutAmount,
            sourceProjectIdOverride: sourceProjectId,
            metadata: "",
            preferredToken: JBConstants.NATIVE_TOKEN
        });

        // After the forced hop (iteration 0), the override is consumed. On iteration 1, the reclaimed
        // NATIVE_TOKEN matches the preferred token, so the loop short-circuits with the reclaim amount.
        assertEq(finalAmount, reclaimAmount, "second iteration should short-circuit after override consumed");
        assertEq(address(destTerminal), mockDestTerminal, "should resolve dest terminal on second iteration");
        assertEq(finalToken, JBConstants.NATIVE_TOKEN, "final token should be the preferred token");
    }
}
