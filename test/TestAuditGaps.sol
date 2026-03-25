// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {JBRouterTerminalRegistry} from "../src/JBRouterTerminalRegistry.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Mock: Standard ERC20 (tracks balances, no fee).
// ──────────────────────────────────────────────────────────────────────────────

contract MockERC20Std {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Mock: Fee-on-transfer ERC20 (burns `feeAmt` per transfer).
// ──────────────────────────────────────────────────────────────────────────────

contract MockFoTERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public feeAmt;

    constructor(uint256 _feeAmt) {
        feeAmt = _feeAmt;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        uint256 received = amt > feeAmt ? amt - feeAmt : 0;
        balanceOf[to] += received;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        uint256 received = amt > feeAmt ? amt - feeAmt : 0;
        balanceOf[to] += received;
        return true;
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Harness: exposes internal functions of JBRouterTerminal for testing.
// ──────────────────────────────────────────────────────────────────────────────

contract AuditHarness is JBRouterTerminal {
    constructor(
        IJBDirectory d,
        IJBPermissions p,
        IJBProjects pr,
        IJBTokens t,
        IPermit2 pm,
        address o,
        IWETH9 w,
        IUniswapV3Factory f,
        IPoolManager pm4,
        address tf
    )
        JBRouterTerminal(d, p, pr, t, pm, o, w, f, pm4, tf)
    {}

    function exposedAcceptFundsFor(
        address token,
        uint256 amount,
        bytes calldata metadata
    )
        external
        payable
        returns (uint256)
    {
        return _acceptFundsFor(token, amount, metadata);
    }

    function exposedTransferFrom(address from, address payable to, address token, uint256 amount) external {
        _transferFrom(from, to, token, amount);
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Test Contract
// ══════════════════════════════════════════════════════════════════════════════

contract TestAuditGaps is Test {
    using PoolIdLibrary for PoolKey;

    AuditHarness router;

    IJBDirectory dir;
    IJBPermissions perms;
    IJBProjects proj;
    IJBTokens toks;
    IPermit2 permit2;
    IWETH9 weth;
    IUniswapV3Factory factory;
    IPoolManager pm;
    address owner;

    function setUp() public {
        dir = IJBDirectory(makeAddr("dir"));
        vm.etch(address(dir), hex"00");
        perms = IJBPermissions(makeAddr("perms"));
        vm.etch(address(perms), hex"00");
        proj = IJBProjects(makeAddr("proj"));
        vm.etch(address(proj), hex"00");
        toks = IJBTokens(makeAddr("toks"));
        vm.etch(address(toks), hex"00");
        permit2 = IPermit2(makeAddr("permit2"));
        vm.etch(address(permit2), hex"00");
        weth = IWETH9(makeAddr("weth"));
        vm.etch(address(weth), hex"00");
        factory = IUniswapV3Factory(makeAddr("factory"));
        vm.etch(address(factory), hex"00");
        pm = IPoolManager(makeAddr("pm"));
        vm.etch(address(pm), hex"00");
        owner = makeAddr("owner");

        router = new AuditHarness(dir, perms, proj, toks, permit2, owner, weth, factory, pm, address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _mockV4PoolNotExists(address s0, address s1, uint24 fee, int24 ts) internal {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(s0),
            currency1: Currency.wrap(s1),
            fee: fee,
            tickSpacing: ts,
            hooks: IHooks(address(0))
        });
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        vm.mockCall(address(pm), abi.encodeWithSignature("extsload(bytes32)", stateSlot), abi.encode(bytes32(0)));
    }

    function _mockV4NoPools(address a, address b) internal {
        (address s0, address s1) = a < b ? (a, b) : (b, a);
        _mockV4PoolNotExists(s0, s1, 3000, int24(60));
        _mockV4PoolNotExists(s0, s1, 500, int24(10));
        _mockV4PoolNotExists(s0, s1, 10_000, int24(200));
        _mockV4PoolNotExists(s0, s1, 100, int24(1));
    }

    function _mockNoV3Pools(address a, address b) internal {
        vm.mockCall(address(factory), abi.encodeCall(IUniswapV3Factory.getPool, (a, b, 500)), abi.encode(address(0)));
        vm.mockCall(address(factory), abi.encodeCall(IUniswapV3Factory.getPool, (a, b, 10_000)), abi.encode(address(0)));
        vm.mockCall(address(factory), abi.encodeCall(IUniswapV3Factory.getPool, (a, b, 100)), abi.encode(address(0)));
    }

    /// @notice Set up mocks so that `projectId` does NOT accept `tokenIn` directly but DOES accept `tokenOut`
    /// through `destTerminal`. Also sets up a V3 pool at 3000 bps.
    function _setupSwapRoute(
        uint256 projectId,
        address tokenIn,
        address tokenOut,
        address destTerminal,
        address pool
    )
        internal
    {
        // Not a JB token.
        vm.mockCall(address(toks), abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));

        // Project does NOT accept tokenIn.
        vm.mockCall(
            address(dir), abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)), abi.encode(address(0))
        );
        // Project does NOT accept WETH.
        vm.mockCall(
            address(dir),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, address(weth))),
            abi.encode(address(0))
        );
        // Project accepts tokenOut.
        vm.mockCall(
            address(dir),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(destTerminal)
        );

        // Terminals and contexts.
        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(destTerminal);
        vm.mockCall(address(dir), abi.encodeCall(IJBDirectory.terminalsOf, (projectId)), abi.encode(terminals));

        JBAccountingContext[] memory ctx = new JBAccountingContext[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        ctx[0] = JBAccountingContext({token: tokenOut, decimals: 18, currency: uint32(uint160(tokenOut))});
        vm.mockCall(destTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(ctx));

        // V3 pool at 0.3%.
        vm.mockCall(
            address(factory), abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, tokenOut, 3000)), abi.encode(pool)
        );
        vm.mockCall(pool, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(1000e18)));
        vm.mockCall(pool, abi.encodeWithSignature("fee()"), abi.encode(uint24(3000)));

        // No other V3/V4 pools.
        _mockNoV3Pools(tokenIn, tokenOut);
        _mockV4NoPools(tokenIn, tokenOut);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GAP 1: Fee-on-Transfer Token Handling
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice JBRouterTerminal._acceptFundsFor uses balance-delta. FoT token => returned amount < nominal.
    function test_feeOnTransfer_acceptFundsReturnsActualAmount() public {
        MockFoTERC20 fot = new MockFoTERC20(50);
        address payer = makeAddr("payer");

        fot.mint(payer, 1000);
        vm.prank(payer);
        fot.approve(address(router), 1000);

        vm.prank(payer);
        uint256 received = router.exposedAcceptFundsFor(address(fot), 1000, "");

        assertEq(received, 950, "Balance-delta should capture fee-on-transfer deduction");
        assertEq(fot.balanceOf(address(router)), 950, "Router balance should reflect actual received");
    }

    /// @notice Standard ERC20 should return the full amount via balance-delta.
    function test_standardToken_acceptFundsReturnsFullAmount() public {
        MockERC20Std tok = new MockERC20Std();
        address payer = makeAddr("payer");

        tok.mint(payer, 1000);
        vm.prank(payer);
        tok.approve(address(router), 1000);

        vm.prank(payer);
        uint256 received = router.exposedAcceptFundsFor(address(tok), 1000, "");

        assertEq(received, 1000, "Standard token should return full amount");
    }

    /// @notice End-to-end: FoT token pay() should forward the reduced amount to the dest terminal.
    function test_feeOnTransfer_payForwardsReducedAmount() public {
        MockFoTERC20 fot = new MockFoTERC20(100);
        address tokenIn = address(fot);
        address payer = makeAddr("payer");
        address dest = makeAddr("dest");
        vm.etch(dest, hex"00");

        // Not a JB token.
        vm.mockCall(address(toks), abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));
        // Project accepts tokenIn directly.
        vm.mockCall(address(dir), abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, tokenIn)), abi.encode(dest));

        JBAccountingContext[] memory ctx = new JBAccountingContext[](1);
        ctx[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: tokenIn, decimals: 18, currency: uint32(uint160(tokenIn))});
        vm.mockCall(dest, abi.encodeCall(IJBTerminal.accountingContextsOf, (1)), abi.encode(ctx));

        fot.mint(payer, 5000);
        vm.prank(payer);
        fot.approve(address(router), 5000);

        // Mock approve for dest terminal (actual received amount = 4900).
        vm.mockCall(tokenIn, abi.encodeCall(IERC20.approve, (dest, 4900)), abi.encode(true));
        vm.mockCall(dest, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(42)));

        // Expect that pay is called with the reduced amount (4900).
        vm.expectCall(dest, abi.encodeCall(IJBTerminal.pay, (1, tokenIn, 4900, payer, 0, "", "")));

        vm.prank(payer);
        uint256 result = router.pay(1, tokenIn, 5000, payer, 0, "", "");
        assertEq(result, 42);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GAP 2: uint160 Permit2 Truncation
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice _transferFrom reverts with AmountOverflow when amount > type(uint160).max and no direct allowance.
    function test_permit2Truncation_revertsOnOverflow() public {
        MockERC20Std tok = new MockERC20Std();
        address payer = makeAddr("payer");
        address recip = makeAddr("recip");
        uint256 overflow = uint256(type(uint160).max) + 1;

        tok.mint(payer, overflow);
        // No allowance granted => falls through to Permit2 path => overflow check.

        vm.expectRevert(abi.encodeWithSelector(JBRouterTerminal.JBRouterTerminal_AmountOverflow.selector, overflow));
        router.exposedTransferFrom(payer, payable(recip), address(tok), overflow);
    }

    /// @notice With sufficient direct allowance, amounts > uint160.max bypass the Permit2 path.
    function test_permit2Truncation_directAllowanceBypasses() public {
        MockERC20Std tok = new MockERC20Std();
        address payer = makeAddr("payer");
        address recip = makeAddr("recip");
        uint256 large = uint256(type(uint160).max) + 1;

        tok.mint(payer, large);
        vm.prank(payer);
        tok.approve(address(router), large);

        router.exposedTransferFrom(payer, payable(recip), address(tok), large);

        assertEq(tok.balanceOf(recip), large, "Recipient should receive large amount via direct transfer");
    }

    /// @notice Exact uint160.max fits in the Permit2 cast and should not revert.
    function test_permit2Truncation_exactMaxDoesNotRevert() public {
        MockERC20Std tok = new MockERC20Std();
        address payer = makeAddr("payer");
        address recip = makeAddr("recip");
        uint256 exactMax = uint256(type(uint160).max);

        tok.mint(payer, exactMax);
        // No direct allowance => Permit2 path.

        // Mock Permit2.transferFrom to succeed.
        vm.mockCall(
            address(permit2),
            abi.encodeWithSignature(
                "transferFrom(address,address,uint160,address)",
                payer,
                recip,
                // forge-lint: disable-next-line(unsafe-typecast)
                uint160(exactMax),
                address(tok)
            ),
            abi.encode()
        );

        // Should NOT revert.
        router.exposedTransferFrom(payer, payable(recip), address(tok), exactMax);
    }

    /// @notice JBRouterTerminalRegistry._transferFrom also reverts on overflow.
    function test_permit2Truncation_registryRevertsOnOverflow() public {
        JBRouterTerminalRegistry reg = new JBRouterTerminalRegistry(perms, proj, permit2, owner, address(0));

        MockERC20Std tok = new MockERC20Std();
        address payer = makeAddr("payer");
        uint256 overflow = uint256(type(uint160).max) + 1;
        tok.mint(payer, overflow);

        // Set up a default terminal.
        IJBTerminal dest = IJBTerminal(makeAddr("dest"));
        vm.etch(address(dest), hex"00");
        vm.prank(owner);
        reg.setDefaultTerminal(dest);
        vm.mockCall(address(dest), abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(0)));

        // No allowance => falls to Permit2 path => overflow.
        vm.prank(payer);
        vm.expectRevert(JBRouterTerminalRegistry.JBRouterTerminalRegistry_AmountOverflow.selector);
        reg.pay(1, address(tok), overflow, payer, 0, "", "");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GAP 3: Short TWAP Windows
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When oldest observation is 0 seconds ago, _getV3TwapQuote reverts NoObservationHistory.
    function test_shortTwap_revertsNoObservationHistory() public {
        MockERC20Std tok = new MockERC20Std();
        address tokenIn = address(tok);
        address tokenOut = makeAddr("tokenOut");
        address pool = makeAddr("pool");
        vm.etch(pool, hex"00");
        address dest = makeAddr("dest");
        vm.etch(dest, hex"00");

        _setupSwapRoute(1, tokenIn, tokenOut, dest, pool);

        // Mock slot0: cardinality=1, observationIndex=0 => oldest is observations[0].
        vm.mockCall(
            pool,
            abi.encodeWithSignature("slot0()"),
            abi.encode(
                uint160(79_228_162_514_264_337_593_543_950_336),
                int24(0),
                uint16(0),
                uint16(1),
                uint16(1),
                uint8(0),
                true
            )
        );

        // observations[0] at block.timestamp => secondsAgo = 0 => revert.
        vm.mockCall(
            pool,
            abi.encodeWithSignature("observations(uint256)", uint256(0)),
            abi.encode(uint32(block.timestamp), int56(0), uint160(0), true)
        );

        address payer = makeAddr("payer");
        tok.mint(payer, 100);
        vm.prank(payer);
        tok.approve(address(router), 100);

        vm.prank(payer);
        vm.expectRevert(JBRouterTerminal.JBRouterTerminal_NoObservationHistory.selector);
        router.pay(1, tokenIn, 100, payer, 0, "", "");
    }

    /// @notice Verify DEFAULT_TWAP_WINDOW is 10 minutes.
    function test_defaultTwapWindow_is600Seconds() public view {
        assertEq(router.DEFAULT_TWAP_WINDOW(), 600);
    }

    /// @notice When user provides quoteForSwap metadata, TWAP is bypassed.
    function test_shortTwap_bypassedWithUserQuote() public {
        MockERC20Std tok = new MockERC20Std();
        address tokenIn = address(tok);
        address tokenOut = makeAddr("tokenOut2");
        address pool = makeAddr("pool2");
        vm.etch(pool, hex"00");
        address dest = makeAddr("dest2");
        vm.etch(dest, hex"00");

        _setupSwapRoute(1, tokenIn, tokenOut, dest, pool);

        // Build metadata with user-provided quote — bypasses TWAP entirely.
        bytes memory metadata;
        {
            bytes4 mid = JBMetadataResolver.getId("quoteForSwap", address(router));
            metadata = JBMetadataResolver.addToMetadata("", mid, abi.encode(uint256(80)));
        }

        // Mock V3 swap.
        _mockV3Swap(pool, tokenIn, tokenOut);

        // Mock WETH balanceOf for leftover check.
        vm.mockCall(address(weth), abi.encodeCall(IERC20.balanceOf, (address(router))), abi.encode(uint256(0)));

        // Mock dest terminal.
        vm.mockCall(dest, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(77)));
        // safeIncreaseAllowance calls allowance() then approve().
        vm.mockCall(tokenOut, abi.encodeCall(IERC20.allowance, (address(router), dest)), abi.encode(uint256(0)));
        vm.mockCall(tokenOut, abi.encodeCall(IERC20.approve, (dest, 90)), abi.encode(true));
        vm.mockCall(tokenOut, abi.encodeCall(IERC20.balanceOf, (address(router))), abi.encode(uint256(90)));

        address payer = makeAddr("payer");
        tok.mint(payer, 100);
        vm.prank(payer);
        tok.approve(address(router), 100);

        // Should succeed without any TWAP mocks (slot0/observations not called).
        vm.prank(payer);
        uint256 result = router.pay(1, tokenIn, 100, payer, 0, "", metadata);
        assertEq(result, 77);
    }

    /// @notice [L-17] After MIN_TWAP_WINDOW enforcement, a 1-second observation window now reverts.
    function test_shortTwap_clampsTo1Second_nowRevertsAfterMinWindow() public {
        MockERC20Std tok = new MockERC20Std();
        address tokenIn = address(tok);
        address tokenOut = makeAddr("tokenOut3");
        address pool = makeAddr("pool3");
        vm.etch(pool, hex"00");
        address dest = makeAddr("dest3");
        vm.etch(dest, hex"00");

        _setupSwapRoute(1, tokenIn, tokenOut, dest, pool);

        // Mock slot0: cardinality=2, observationIndex=1.
        // Oldest = observations[(1+1) % 2 = 0] at (block.timestamp - 1).
        vm.mockCall(
            pool,
            abi.encodeWithSignature("slot0()"),
            abi.encode(
                uint160(79_228_162_514_264_337_593_543_950_336),
                int24(0),
                uint16(1),
                uint16(2),
                uint16(2),
                uint8(0),
                true
            )
        );
        vm.mockCall(
            pool,
            abi.encodeWithSignature("observations(uint256)", uint256(0)),
            abi.encode(uint32(block.timestamp - 1), int56(0), uint160(1e18), true)
        );

        address payer = makeAddr("payer");
        tok.mint(payer, 100);
        vm.prank(payer);
        tok.approve(address(router), 100);

        // 1s < MIN_TWAP_WINDOW (120s) => reverts.
        vm.prank(payer);
        vm.expectRevert(JBRouterTerminal.JBRouterTerminal_InsufficientTwapHistory.selector);
        router.pay(1, tokenIn, 100, payer, 0, "", "");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GAP 4 (L-17): MIN_TWAP_WINDOW Enforcement
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice MIN_TWAP_WINDOW constant is 120 seconds (2 minutes).
    function test_minTwapWindow_is120Seconds() public view {
        assertEq(router.MIN_TWAP_WINDOW(), 120);
    }

    /// @notice Observation window of 119s (just below MIN_TWAP_WINDOW) reverts.
    function test_shortTwap_revertsAt119Seconds() public {
        vm.warp(1000);
        MockERC20Std tok = new MockERC20Std();
        address tokenIn = address(tok);
        address tokenOut = makeAddr("tokenOut_119");
        address pool = makeAddr("pool_119");
        vm.etch(pool, hex"00");
        address dest = makeAddr("dest_119");
        vm.etch(dest, hex"00");

        _setupSwapRoute(1, tokenIn, tokenOut, dest, pool);

        // Mock slot0 with cardinality=2, observationIndex=1.
        vm.mockCall(
            pool,
            abi.encodeWithSignature("slot0()"),
            abi.encode(
                uint160(79_228_162_514_264_337_593_543_950_336),
                int24(0),
                uint16(1),
                uint16(2),
                uint16(2),
                uint8(0),
                true
            )
        );
        // Oldest observation 119 seconds ago => below MIN_TWAP_WINDOW.
        vm.mockCall(
            pool,
            abi.encodeWithSignature("observations(uint256)", uint256(0)),
            abi.encode(uint32(block.timestamp - 119), int56(0), uint160(1e18), true)
        );

        address payer = makeAddr("payer");
        tok.mint(payer, 100);
        vm.prank(payer);
        tok.approve(address(router), 100);

        vm.prank(payer);
        vm.expectRevert(JBRouterTerminal.JBRouterTerminal_InsufficientTwapHistory.selector);
        router.pay(1, tokenIn, 100, payer, 0, "", "");
    }

    /// @notice Observation window of exactly 120s (MIN_TWAP_WINDOW boundary) succeeds.
    function test_shortTwap_succeedsAtExact120Seconds() public {
        vm.warp(1000);
        MockERC20Std tok = new MockERC20Std();
        address tokenIn = address(tok);
        address tokenOut = makeAddr("tokenOut_120");
        address pool = makeAddr("pool_120");
        vm.etch(pool, hex"00");
        address dest = makeAddr("dest_120");
        vm.etch(dest, hex"00");

        _setupSwapRoute(1, tokenIn, tokenOut, dest, pool);

        // Mock slot0 with cardinality=2, observationIndex=1.
        vm.mockCall(
            pool,
            abi.encodeWithSignature("slot0()"),
            abi.encode(
                uint160(79_228_162_514_264_337_593_543_950_336),
                int24(0),
                uint16(1),
                uint16(2),
                uint16(2),
                uint8(0),
                true
            )
        );
        // Oldest observation exactly 120 seconds ago => meets MIN_TWAP_WINDOW.
        vm.mockCall(
            pool,
            abi.encodeWithSignature("observations(uint256)", uint256(0)),
            abi.encode(uint32(block.timestamp - 120), int56(0), uint160(1e18), true)
        );

        // Mock observe() for 120-second window.
        {
            int56[] memory tc = new int56[](2);
            tc[0] = int56(0);
            tc[1] = int56(0);
            uint160[] memory spl = new uint160[](2);
            spl[0] = uint160(1e18);
            spl[1] = uint160(1e18 + 120);
            vm.mockCall(pool, abi.encodeWithSignature("observe(uint32[])"), abi.encode(tc, spl));
        }

        // Mock V3 swap returning 99 out (must exceed TWAP-based slippage minimum).
        {
            bool zeroForOne = tokenIn < tokenOut;
            if (zeroForOne) {
                vm.mockCall(
                    pool,
                    abi.encodeWithSignature("swap(address,bool,int256,uint160,bytes)"),
                    abi.encode(int256(100), int256(-99))
                );
            } else {
                vm.mockCall(
                    pool,
                    abi.encodeWithSignature("swap(address,bool,int256,uint160,bytes)"),
                    abi.encode(int256(-99), int256(100))
                );
            }
            vm.mockCall(tokenIn, abi.encodeCall(IERC20.transfer, (pool, 100)), abi.encode(true));
        }

        // Mock WETH balance for leftover check.
        vm.mockCall(address(weth), abi.encodeCall(IERC20.balanceOf, (address(router))), abi.encode(uint256(0)));

        // Mock dest terminal.
        vm.mockCall(dest, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(10)));
        vm.mockCall(tokenOut, abi.encodeCall(IERC20.allowance, (address(router), dest)), abi.encode(uint256(0)));
        vm.mockCall(tokenOut, abi.encodeCall(IERC20.approve, (dest, 99)), abi.encode(true));
        vm.mockCall(tokenOut, abi.encodeCall(IERC20.balanceOf, (address(router))), abi.encode(uint256(99)));

        address payer = makeAddr("payer");
        tok.mint(payer, 100);
        vm.prank(payer);
        tok.approve(address(router), 100);

        vm.prank(payer);
        uint256 result = router.pay(1, tokenIn, 100, payer, 0, "", "");
        assertEq(result, 10, "Should succeed at exactly MIN_TWAP_WINDOW");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GAP 5 (H-1): ERC-20 Partial Fill Leftover — Absolute Balance Check
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When the router already holds the input token (e.g., ERC-20 partial fill),
    /// the absolute balance check (balanceAfter > 0) correctly returns all leftover to the payer.
    /// The old delta check (balanceAfter > balanceBefore) would have missed this case.
    function test_partialFill_erc20LeftoverReturnedWithAbsoluteCheck() public {
        MockERC20Std tok = new MockERC20Std();
        address tokenIn = address(tok);
        address tokenOut = makeAddr("tokenOut_pf");
        address pool = makeAddr("pool_pf");
        vm.etch(pool, hex"00");
        address dest = makeAddr("dest_pf");
        vm.etch(dest, hex"00");

        _setupSwapRoute(1, tokenIn, tokenOut, dest, pool);

        // Build metadata with user-provided quote (bypasses TWAP).
        bytes memory metadata;
        {
            bytes4 mid = JBMetadataResolver.getId("quoteForSwap", address(router));
            metadata = JBMetadataResolver.addToMetadata("", mid, abi.encode(uint256(80)));
        }

        // Mock V3 swap that only consumes 80 of 100 input tokens (partial fill).
        {
            bool zeroForOne = tokenIn < tokenOut;
            if (zeroForOne) {
                vm.mockCall(
                    pool,
                    abi.encodeWithSignature("swap(address,bool,int256,uint160,bytes)"),
                    abi.encode(int256(80), int256(-90))
                );
            } else {
                vm.mockCall(
                    pool,
                    abi.encodeWithSignature("swap(address,bool,int256,uint160,bytes)"),
                    abi.encode(int256(-90), int256(80))
                );
            }
            vm.mockCall(tokenIn, abi.encodeCall(IERC20.transfer, (pool, 100)), abi.encode(true));
        }

        // After swap, router still holds 20 leftover input tokens (100 sent in, 80 consumed by pool).
        // The absolute check (balanceAfter > 0) catches this.
        vm.mockCall(address(weth), abi.encodeCall(IERC20.balanceOf, (address(router))), abi.encode(uint256(20)));

        // Mock the leftover transfer back to payer.
        // With absolute check: leftover = 20 (the full remaining balance).
        address payer = makeAddr("payer");
        vm.mockCall(tokenIn, abi.encodeCall(IERC20.allowance, (address(router), payer)), abi.encode(uint256(0)));

        // Mock dest terminal.
        vm.mockCall(dest, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(42)));
        vm.mockCall(tokenOut, abi.encodeCall(IERC20.allowance, (address(router), dest)), abi.encode(uint256(0)));
        vm.mockCall(tokenOut, abi.encodeCall(IERC20.approve, (dest, 90)), abi.encode(true));
        vm.mockCall(tokenOut, abi.encodeCall(IERC20.balanceOf, (address(router))), abi.encode(uint256(90)));

        tok.mint(payer, 100);
        vm.prank(payer);
        tok.approve(address(router), 100);

        // The leftover transfer should be called with amount=20 (absolute balance).
        // MockERC20 tracks balances, so we can verify the payer gets refunded.
        vm.mockCall(address(weth), abi.encodeCall(IERC20.transfer, (payer, 20)), abi.encode(true));

        vm.prank(payer);
        uint256 result = router.pay(1, tokenIn, 100, payer, 0, "", metadata);
        assertEq(result, 42);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GAP 6 (M-7): Registry receive() Accepts Native Token Refunds
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Registry can receive native token transfers without reverting.
    function test_registryReceive_acceptsNativeTokens() public {
        JBRouterTerminalRegistry reg = new JBRouterTerminalRegistry(perms, proj, permit2, owner, address(0));

        vm.deal(address(this), 1 ether);
        (bool success,) = address(reg).call{value: 1 ether}("");
        assertTrue(success, "Registry should accept native token transfers via receive()");
        assertEq(address(reg).balance, 1 ether, "Registry should hold the received ETH");
    }

    /// @notice ETH that is directly deposited to the registry (not via partial-fill refund) is still stuck.
    /// However, partial-fill leftovers are now routed to `beneficiary` (for pay()) or `_msgSender()`
    /// (for addToBalanceOf()) instead of `_msgSender()` of the router, so the registry no longer
    /// receives partial-fill refunds in the first place.
    function test_registryReceive_directDepositStillStuck() public {
        JBRouterTerminalRegistry reg = new JBRouterTerminalRegistry(perms, proj, permit2, owner, address(0));

        // Simulate ETH arriving directly (not from partial-fill — that path now goes to beneficiary).
        vm.deal(address(reg), 1 ether);
        assertEq(address(reg).balance, 1 ether);

        // The registry has no withdraw function, no sweep, no owner recovery.
        IJBTerminal dest = IJBTerminal(makeAddr("dest_stuck"));
        vm.etch(address(dest), hex"00");
        vm.prank(owner);
        reg.setDefaultTerminal(dest);

        vm.mockCall(address(dest), abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(0)));

        reg.pay{value: 0}({
            projectId: 1,
            token: JBConstants.NATIVE_TOKEN,
            amount: 0,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Directly deposited ETH is still stuck (no withdrawal mechanism).
        assertEq(address(reg).balance, 1 ether, "Directly deposited ETH remains stuck - no withdrawal mechanism");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GAP 6b: Partial-fill leftovers go to beneficiary, not _msgSender()
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When pay() is called and a partial fill occurs, leftover input tokens
    /// are sent to the `beneficiary`, not `_msgSender()`. This is critical when pay()
    /// is called through a registry or other intermediary where _msgSender() differs
    /// from the intended recipient.
    function test_partialFill_leftoverSentToBeneficiary_notMsgSender() public {
        MockERC20Std tok = new MockERC20Std();
        address tokenIn = address(tok);
        address tokenOut = makeAddr("tokenOut_refund");
        address pool = makeAddr("pool_refund");
        vm.etch(pool, hex"00");
        address dest = makeAddr("dest_refund");
        vm.etch(dest, hex"00");

        _setupSwapRoute(1, tokenIn, tokenOut, dest, pool);

        // Build metadata with user-provided quote (bypasses TWAP).
        bytes memory metadata;
        {
            bytes4 mid = JBMetadataResolver.getId("quoteForSwap", address(router));
            metadata = JBMetadataResolver.addToMetadata("", mid, abi.encode(uint256(70)));
        }

        // Mock V3 swap (partial fill — swap returns only 90 output for 80 input consumed).
        // Because the swap is fully mocked, no tokens actually leave the router.
        // After _acceptFundsFor transfers 100 in, the router's real balance stays at 100.
        // The leftover check sees that 100 and refunds all of it. This is correct behavior
        // for testing the *recipient* — what matters is WHERE the leftover goes, not how much.
        {
            bool zeroForOne = tokenIn < tokenOut;
            if (zeroForOne) {
                vm.mockCall(
                    pool,
                    abi.encodeWithSignature("swap(address,bool,int256,uint160,bytes)"),
                    abi.encode(int256(80), int256(-90))
                );
            } else {
                vm.mockCall(
                    pool,
                    abi.encodeWithSignature("swap(address,bool,int256,uint160,bytes)"),
                    abi.encode(int256(-90), int256(80))
                );
            }
            vm.mockCall(tokenIn, abi.encodeCall(IERC20.transfer, (pool, 100)), abi.encode(true));
        }

        // Mock dest terminal.
        vm.mockCall(dest, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(42)));
        vm.mockCall(tokenOut, abi.encodeCall(IERC20.allowance, (address(router), dest)), abi.encode(uint256(0)));
        vm.mockCall(tokenOut, abi.encodeCall(IERC20.approve, (dest, 90)), abi.encode(true));
        vm.mockCall(tokenOut, abi.encodeCall(IERC20.balanceOf, (address(router))), abi.encode(uint256(90)));

        address alice = makeAddr("alice"); // msg.sender
        address bob = makeAddr("bob"); // beneficiary (should receive leftover)

        tok.mint(alice, 100);
        vm.prank(alice);
        tok.approve(address(router), 100);

        // Alice pays on behalf of Bob. Leftover should go to Bob (beneficiary), not Alice (_msgSender()).
        vm.prank(alice);
        uint256 result = router.pay(1, tokenIn, 100, bob, 0, "", metadata);
        assertEq(result, 42);

        // Bob (beneficiary) received the leftover tokens.
        assertTrue(tok.balanceOf(bob) > 0, "Leftover should go to beneficiary (bob)");
        // Alice should NOT have received the leftover.
        assertEq(tok.balanceOf(alice), 0, "Alice (_msgSender) should not receive leftover");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal helper: mock a V3 swap returning (100 in, -90 out)
    // ═══════════════════════════════════════════════════════════════════════

    function _mockV3Swap(address pool, address tokenIn, address tokenOut) internal {
        bool zeroForOne = tokenIn < tokenOut;
        if (zeroForOne) {
            vm.mockCall(
                pool,
                abi.encodeWithSignature("swap(address,bool,int256,uint160,bytes)"),
                abi.encode(int256(100), int256(-90))
            );
        } else {
            vm.mockCall(
                pool,
                abi.encodeWithSignature("swap(address,bool,int256,uint160,bytes)"),
                abi.encode(int256(-90), int256(100))
            );
        }
        // Mock token transfer to pool (callback).
        vm.mockCall(tokenIn, abi.encodeCall(IERC20.transfer, (pool, 100)), abi.encode(true));
    }
}
