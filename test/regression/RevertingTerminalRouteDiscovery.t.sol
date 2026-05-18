// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {JBPayRouteResolver} from "../../src/JBPayRouteResolver.sol";
import {IJBPayRoutePreviewer} from "../../src/interfaces/IJBPayRoutePreviewer.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Mock: Terminal that returns accounting contexts normally.
// ──────────────────────────────────────────────────────────────────────────────

contract GoodTerminal {
    address public immutable ACCEPTED_TOKEN;

    constructor(address token_) {
        ACCEPTED_TOKEN = token_;
    }

    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: ACCEPTED_TOKEN,
            decimals: 18,
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: uint32(uint160(ACCEPTED_TOKEN))
        });
    }

    function accountingContextForTokenOf(uint256, address token) external pure returns (JBAccountingContext memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function previewPayFor(
        uint256,
        address,
        uint256 amount,
        address,
        bytes calldata
    )
        external
        pure
        returns (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        )
    {
        ruleset = JBRuleset({
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
        beneficiaryTokenCount = amount;
        reservedTokenCount = 0;
        hookSpecifications = new JBPayHookSpecification[](0);
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Mock: Terminal that always reverts on accountingContextsOf.
// ──────────────────────────────────────────────────────────────────────────────

contract RevertingTerminal {
    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory) {
        revert("RevertingTerminal: broken");
    }

    function accountingContextForTokenOf(uint256, address) external pure returns (JBAccountingContext memory) {
        revert("RevertingTerminal: broken");
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Mock: Minimal WETH for constructor.
// ──────────────────────────────────────────────────────────────────────────────

contract MockWETH {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {}
}

// ──────────────────────────────────────────────────────────────────────────────
// Test contract
// ──────────────────────────────────────────────────────────────────────────────

contract RevertingTerminalRouteDiscoveryTest is Test {
    JBPayRouteResolver internal resolver;
    IJBDirectory internal directory;
    IWETH9 internal weth;
    IJBPayRoutePreviewer internal router;

    uint256 internal constant PROJECT_ID = 42;
    address internal tokenA;
    address internal tokenB;
    address internal tokenIn;

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        weth = IWETH9(address(new MockWETH()));
        router = IJBPayRoutePreviewer(makeAddr("router"));

        vm.etch(address(directory), hex"00");
        vm.etch(address(router), hex"00");

        resolver = new JBPayRouteResolver({directory: directory});

        // Create distinct token addresses for testing.
        tokenA = makeAddr("tokenA");
        tokenB = makeAddr("tokenB");
        tokenIn = makeAddr("tokenIn");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1: Route discovery succeeds when all terminals respond normally.
    // ─────────────────────────────────────────────────────────────────────────

    function test_resolveTokenOut_allTerminalsHealthy() public {
        GoodTerminal goodTerminal = new GoodTerminal(tokenA);

        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(address(goodTerminal));

        // Mock directory.terminalsOf -> returns the good terminal.
        vm.mockCall(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));

        // Mock directory.primaryTerminalOf for tokenIn -> address(0) (not directly accepted).
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, tokenIn)),
            abi.encode(address(0))
        );

        // Mock directory.primaryTerminalOf for tokenA -> goodTerminal.
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, tokenA)),
            abi.encode(address(goodTerminal))
        );

        // Mock router.wrappedNativeToken() -> our weth address.
        vm.mockCall(
            address(router), abi.encodeCall(IJBPayRoutePreviewer.wrappedNativeToken, ()), abi.encode(address(weth))
        );

        // Mock router.TOKENS() -> return a mock that says tokenIn is not a project token.
        address mockTokens = makeAddr("tokens");
        vm.etch(address(mockTokens), hex"00");
        vm.mockCall(address(router), abi.encodeCall(IJBPayRoutePreviewer.TOKENS, ()), abi.encode(mockTokens));
        vm.mockCall(mockTokens, abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));

        // Mock router.bestPoolLiquidityOf -> some liquidity for tokenIn/tokenA pair.
        vm.mockCall(
            address(router),
            abi.encodeCall(IJBPayRoutePreviewer.bestPoolLiquidityOf, (tokenIn, tokenA)),
            abi.encode(uint128(1_000_000))
        );

        // Mock WETH for native token check (no native terminal).
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(weth))),
            abi.encode(address(0))
        );

        (address resolvedTokenOut, IJBTerminal resolvedTerminal) = resolver.resolveTokenOut({
            router: router, wrappedNativeToken: address(weth), projectId: PROJECT_ID, tokenIn: tokenIn, metadata: ""
        });

        assertEq(resolvedTokenOut, tokenA, "should resolve to tokenA from the healthy terminal");
        assertEq(address(resolvedTerminal), address(goodTerminal), "should resolve to goodTerminal");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2: Route discovery still works when one terminal reverts -
    //          other terminals' tokens are still discovered.
    // ─────────────────────────────────────────────────────────────────────────

    function test_resolveTokenOut_revertingTerminalSkipped_otherTerminalDiscovered() public {
        RevertingTerminal revertingTerminal = new RevertingTerminal();
        GoodTerminal goodTerminal = new GoodTerminal(tokenA);

        IJBTerminal[] memory terminals = new IJBTerminal[](2);
        terminals[0] = IJBTerminal(address(revertingTerminal));
        terminals[1] = IJBTerminal(address(goodTerminal));

        // Mock directory.terminalsOf -> returns both terminals.
        vm.mockCall(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));

        // Mock directory.primaryTerminalOf for tokenIn -> address(0) (not directly accepted).
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, tokenIn)),
            abi.encode(address(0))
        );

        // Mock directory.primaryTerminalOf for tokenA -> goodTerminal.
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, tokenA)),
            abi.encode(address(goodTerminal))
        );

        // Mock router.wrappedNativeToken().
        vm.mockCall(
            address(router), abi.encodeCall(IJBPayRoutePreviewer.wrappedNativeToken, ()), abi.encode(address(weth))
        );

        // Mock router.TOKENS().
        address mockTokens = makeAddr("tokens");
        vm.etch(address(mockTokens), hex"00");
        vm.mockCall(address(router), abi.encodeCall(IJBPayRoutePreviewer.TOKENS, ()), abi.encode(mockTokens));
        vm.mockCall(mockTokens, abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));

        // Mock router.bestPoolLiquidityOf for tokenIn/tokenA pair.
        vm.mockCall(
            address(router),
            abi.encodeCall(IJBPayRoutePreviewer.bestPoolLiquidityOf, (tokenIn, tokenA)),
            abi.encode(uint128(500_000))
        );

        // Mock WETH for native token check.
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(weth))),
            abi.encode(address(0))
        );

        (address resolvedTokenOut, IJBTerminal resolvedTerminal) = resolver.resolveTokenOut({
            router: router, wrappedNativeToken: address(weth), projectId: PROJECT_ID, tokenIn: tokenIn, metadata: ""
        });

        // The reverting terminal is skipped; the good terminal's token is discovered.
        assertEq(resolvedTokenOut, tokenA, "should discover tokenA despite the reverting terminal");
        assertEq(address(resolvedTerminal), address(goodTerminal), "should resolve to goodTerminal");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3: Route discovery returns empty when the only terminal reverts.
    //          _discoverAcceptedToken returns (address(0), address(0)) and
    //          resolveTokenOut reverts with JBRouterTerminal_NoRouteFound.
    // ─────────────────────────────────────────────────────────────────────────

    function test_resolveTokenOut_onlyTerminalReverts_noRouteFound() public {
        RevertingTerminal revertingTerminal = new RevertingTerminal();

        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(address(revertingTerminal));

        // Mock directory.terminalsOf -> returns the single reverting terminal.
        vm.mockCall(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));

        // Mock directory.primaryTerminalOf for tokenIn -> address(0).
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, tokenIn)),
            abi.encode(address(0))
        );

        // Mock router.wrappedNativeToken().
        vm.mockCall(
            address(router), abi.encodeCall(IJBPayRoutePreviewer.wrappedNativeToken, ()), abi.encode(address(weth))
        );

        // Mock router.TOKENS().
        address mockTokens = makeAddr("tokens");
        vm.etch(address(mockTokens), hex"00");
        vm.mockCall(address(router), abi.encodeCall(IJBPayRoutePreviewer.TOKENS, ()), abi.encode(mockTokens));
        vm.mockCall(mockTokens, abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));

        // Mock WETH for native token check.
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(weth))),
            abi.encode(address(0))
        );

        // Should revert because the only terminal reverts, leaving no discovered route.
        vm.expectRevert();
        resolver.resolveTokenOut({
            router: router, wrappedNativeToken: address(weth), projectId: PROJECT_ID, tokenIn: tokenIn, metadata: ""
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 4: previewBestPayRoute works when one terminal reverts and another
    //          responds. Exercises _candidatePayRouteTokens.
    // ─────────────────────────────────────────────────────────────────────────

    function test_previewBestPayRoute_revertingTerminalSkipped() public {
        RevertingTerminal revertingTerminal = new RevertingTerminal();
        GoodTerminal goodTerminal = new GoodTerminal(tokenA);

        IJBTerminal[] memory terminals = new IJBTerminal[](2);
        terminals[0] = IJBTerminal(address(revertingTerminal));
        terminals[1] = IJBTerminal(address(goodTerminal));

        // Mock directory.terminalsOf.
        vm.mockCall(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));

        // Mock directory.primaryTerminalOf for tokenIn -> address(0) (not directly accepted).
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, tokenIn)),
            abi.encode(address(0))
        );

        // Mock directory.primaryTerminalOf for tokenA -> goodTerminal.
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, tokenA)),
            abi.encode(address(goodTerminal))
        );

        // Mock router.wrappedNativeToken().
        vm.mockCall(
            address(router), abi.encodeCall(IJBPayRoutePreviewer.wrappedNativeToken, ()), abi.encode(address(weth))
        );

        // Mock router.TOKENS() -> mock that says tokenIn is not a project token.
        address mockTokens = makeAddr("tokens");
        vm.etch(address(mockTokens), hex"00");
        vm.mockCall(address(router), abi.encodeCall(IJBPayRoutePreviewer.TOKENS, ()), abi.encode(mockTokens));
        vm.mockCall(mockTokens, abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));

        // Mock router.BUYBACK_HOOK() -> address(0).
        vm.mockCall(address(router), abi.encodeCall(IJBPayRoutePreviewer.BUYBACK_HOOK, ()), abi.encode(address(0)));

        // Mock router.bestPoolLiquidityOf -> 0 (no pool, triggers fallback route logic).
        vm.mockCall(
            address(router),
            abi.encodeCall(IJBPayRoutePreviewer.bestPoolLiquidityOf, (tokenIn, tokenA)),
            abi.encode(uint128(0))
        );

        // Mock WETH for native token check.
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(weth))),
            abi.encode(address(0))
        );

        // Mock router.previewSwapAmountOutOf -> returns amount (1:1 swap for simplicity).
        vm.mockCall(
            address(router),
            abi.encodeWithSelector(IJBPayRoutePreviewer.previewSwapAmountOutOf.selector),
            abi.encode(uint256(100 ether))
        );

        // Mock router.previewCashOutLoopOf -> returns no cashout (destTerminal=0, finalToken=tokenIn, amount
        // unchanged).
        vm.mockCall(
            address(router),
            abi.encodeWithSelector(IJBPayRoutePreviewer.previewCashOutLoopOf.selector),
            abi.encode(IJBTerminal(address(0)), tokenIn, uint256(100 ether))
        );

        // Mock router.previewTerminalPayOf -> return a valid preview.
        JBRuleset memory mockRuleset = JBRuleset({
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
        JBPayHookSpecification[] memory emptyHooks = new JBPayHookSpecification[](0);
        vm.mockCall(
            address(router),
            abi.encodeWithSelector(IJBPayRoutePreviewer.previewTerminalPayOf.selector),
            abi.encode(mockRuleset, uint256(100 ether), uint256(0), emptyHooks)
        );

        // Call previewBestPayRoute — should succeed despite the reverting terminal.
        (IJBTerminal destTerminal, address resolvedTokenOut,,, uint256 beneficiaryTokenCount,,) = resolver.previewBestPayRoute({
            router: router,
            wrappedNativeToken: address(weth),
            projectId: PROJECT_ID,
            tokenIn: tokenIn,
            amount: 100 ether,
            beneficiary: makeAddr("beneficiary"),
            metadata: ""
        });

        assertEq(address(destTerminal), address(goodTerminal), "should route to goodTerminal");
        assertEq(resolvedTokenOut, tokenA, "should route through tokenA");
        assertGt(beneficiaryTokenCount, 0, "should produce beneficiary tokens");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 5: previewBestPayRoute with only reverting terminals returns
    //          zero/empty values (fallback is wrapped in try/catch per the route fallback).
    // ─────────────────────────────────────────────────────────────────────────

    function test_previewBestPayRoute_allTerminalsRevert_noRoute() public {
        RevertingTerminal revertingTerminal = new RevertingTerminal();

        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(address(revertingTerminal));

        // Mock directory.terminalsOf.
        vm.mockCall(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));

        // Mock directory.primaryTerminalOf for tokenIn -> address(0).
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, tokenIn)),
            abi.encode(address(0))
        );

        // Mock router.wrappedNativeToken().
        vm.mockCall(
            address(router), abi.encodeCall(IJBPayRoutePreviewer.wrappedNativeToken, ()), abi.encode(address(weth))
        );

        // Mock router.TOKENS().
        address mockTokens = makeAddr("tokens");
        vm.etch(address(mockTokens), hex"00");
        vm.mockCall(address(router), abi.encodeCall(IJBPayRoutePreviewer.TOKENS, ()), abi.encode(mockTokens));
        vm.mockCall(mockTokens, abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));

        // Mock router.BUYBACK_HOOK().
        vm.mockCall(address(router), abi.encodeCall(IJBPayRoutePreviewer.BUYBACK_HOOK, ()), abi.encode(address(0)));

        // Mock WETH for native token check.
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(weth))),
            abi.encode(address(0))
        );

        // With the try/catch fallback in the route fallback, the function no longer reverts — it returns zero/empty
        // values.
        (IJBTerminal destTerminal, address resolvedTokenOut,,, uint256 beneficiaryTokenCount,,) = resolver.previewBestPayRoute({
            router: router,
            wrappedNativeToken: address(weth),
            projectId: PROJECT_ID,
            tokenIn: tokenIn,
            amount: 100 ether,
            beneficiary: makeAddr("beneficiary"),
            metadata: ""
        });

        assertEq(address(destTerminal), address(0), "destTerminal should be zero when no route is found");
        assertEq(resolvedTokenOut, address(0), "tokenOut should be zero when no route is found");
        assertEq(beneficiaryTokenCount, 0, "beneficiaryTokenCount should be zero when no route is found");
    }
}
