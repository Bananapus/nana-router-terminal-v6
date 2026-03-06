// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {IJBRouterTerminal, PoolInfo} from "../src/interfaces/IJBRouterTerminal.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

/// @notice A harness that exposes internal functions for testing.
contract RouterTerminalHarness is JBRouterTerminal {
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

    function exposed_resolveTokenOut(
        uint256 projectId,
        address tokenIn,
        bytes calldata metadata
    )
        external
        view
        returns (address tokenOut, IJBTerminal destTerminal)
    {
        return _resolveTokenOut(projectId, tokenIn, metadata);
    }

    function exposed_discoverPool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        external
        view
        returns (PoolInfo memory)
    {
        return _discoverPool(normalizedTokenIn, normalizedTokenOut);
    }
}

contract RouterTerminalTest is Test {
    using PoolIdLibrary for PoolKey;

    RouterTerminalHarness routerTerminal;

    // Mocked dependencies
    IJBDirectory mockDirectory;
    IJBPermissions mockPermissions;
    IJBProjects mockProjects;
    IJBTokens mockTokens;
    IPermit2 mockPermit2;
    IWETH9 mockWeth;
    IUniswapV3Factory mockFactory;
    IPoolManager mockPoolManager;

    address terminalOwner;

    function setUp() public {
        mockDirectory = IJBDirectory(makeAddr("mockDirectory"));
        vm.etch(address(mockDirectory), hex"00");
        mockPermissions = IJBPermissions(makeAddr("mockPermissions"));
        vm.etch(address(mockPermissions), hex"00");
        mockProjects = IJBProjects(makeAddr("mockProjects"));
        vm.etch(address(mockProjects), hex"00");
        mockTokens = IJBTokens(makeAddr("mockTokens"));
        vm.etch(address(mockTokens), hex"00");
        mockPermit2 = IPermit2(makeAddr("mockPermit2"));
        vm.etch(address(mockPermit2), hex"00");
        mockWeth = IWETH9(makeAddr("mockWeth"));
        vm.etch(address(mockWeth), hex"00");
        mockFactory = IUniswapV3Factory(makeAddr("mockFactory"));
        vm.etch(address(mockFactory), hex"00");
        mockPoolManager = IPoolManager(makeAddr("mockPoolManager"));
        vm.etch(address(mockPoolManager), hex"00");

        terminalOwner = makeAddr("terminalOwner");

        routerTerminal = new RouterTerminalHarness(
            mockDirectory,
            mockPermissions,
            mockProjects,
            mockTokens,
            mockPermit2,
            terminalOwner,
            mockWeth,
            mockFactory,
            mockPoolManager,
            address(0)
        );
    }

    //*********************************************************************//
    // -------------------- accounting context tests -------------------- //
    //*********************************************************************//

    function test_accountingContext_dynamic() public {
        address token = makeAddr("someToken");
        JBAccountingContext memory ctx = routerTerminal.accountingContextForTokenOf(1, token);
        assertEq(ctx.token, token);
        assertEq(ctx.decimals, 18);
        assertEq(ctx.currency, uint32(uint160(token)));
    }

    function test_accountingContexts_empty() public {
        JBAccountingContext[] memory ctxs = routerTerminal.accountingContextsOf(1);
        assertEq(ctxs.length, 0);
    }

    function test_currentSurplus_zero() public {
        assertEq(routerTerminal.currentSurplusOf(1, new JBAccountingContext[](0), 18, 1), 0);
    }

    //*********************************************************************//
    // -------------------- resolve token out tests --------------------- //
    //*********************************************************************//

    function test_resolveTokenOut_directAcceptance() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");
        address mockTerminal = makeAddr("destTerminal");
        vm.etch(mockTerminal, hex"00");

        // Project accepts tokenIn directly.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)),
            abi.encode(mockTerminal)
        );

        (address tokenOut, IJBTerminal destTerminal) =
            routerTerminal.exposed_resolveTokenOut(projectId, tokenIn, "");

        assertEq(tokenOut, tokenIn);
        assertEq(address(destTerminal), mockTerminal);
    }

    function test_resolveTokenOut_metadataOverride() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");
        address desiredTokenOut = makeAddr("desiredOut");
        address mockTerminal = makeAddr("destTerminal");
        vm.etch(mockTerminal, hex"00");

        // Build metadata with routeTokenOut.
        bytes4 metadataId = JBMetadataResolver.getId("routeTokenOut", address(routerTerminal));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(desiredTokenOut));

        // Mock: project accepts the desired token.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, desiredTokenOut)),
            abi.encode(mockTerminal)
        );

        (address tokenOut, IJBTerminal destTerminal) =
            routerTerminal.exposed_resolveTokenOut(projectId, tokenIn, metadata);

        assertEq(tokenOut, desiredTokenOut);
        assertEq(address(destTerminal), mockTerminal);
    }

    function test_resolveTokenOut_discoversAcceptedToken() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");
        address acceptedToken = makeAddr("acceptedToken");
        address mockTerminal = makeAddr("destTerminal");
        address mockPool = makeAddr("mockPool");
        vm.etch(mockTerminal, hex"00");
        vm.etch(mockPool, hex"00");

        // Project doesn't accept tokenIn directly.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)),
            abi.encode(address(0))
        );

        // Set up terminals with accounting contexts.
        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(mockTerminal);
        vm.mockCall(
            address(mockDirectory), abi.encodeCall(IJBDirectory.terminalsOf, (projectId)), abi.encode(terminals)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] =
            JBAccountingContext({token: acceptedToken, decimals: 18, currency: uint32(uint160(acceptedToken))});
        vm.mockCall(
            mockTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(contexts)
        );

        // Mock V3 pool discovery: pool exists at 0.3% fee tier with liquidity.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, acceptedToken, 3000)),
            abi.encode(mockPool)
        );
        vm.mockCall(mockPool, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(1000e18)));

        // Mock no V3 pools at other fee tiers.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, acceptedToken, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, acceptedToken, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, acceptedToken, 100)),
            abi.encode(address(0))
        );

        // Mock V4 — no pools found (extsload returns 0 for all).
        _mockV4NoPools(tokenIn, acceptedToken);

        (address tokenOut, IJBTerminal destTerminal) =
            routerTerminal.exposed_resolveTokenOut(projectId, tokenIn, "");

        assertEq(tokenOut, acceptedToken);
        assertEq(address(destTerminal), mockTerminal);
    }

    function test_resolveTokenOut_revertsNoRoute() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");

        // Project doesn't accept tokenIn.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)),
            abi.encode(address(0))
        );

        // No terminals.
        IJBTerminal[] memory terminals = new IJBTerminal[](0);
        vm.mockCall(
            address(mockDirectory), abi.encodeCall(IJBDirectory.terminalsOf, (projectId)), abi.encode(terminals)
        );

        vm.expectRevert(
            abi.encodeWithSelector(IJBRouterTerminal.JBRouterTerminal_NoRouteFound.selector, projectId, tokenIn)
        );
        routerTerminal.exposed_resolveTokenOut(projectId, tokenIn, "");
    }

    //*********************************************************************//
    // ----------------------- pay direct forward ----------------------- //
    //*********************************************************************//

    function test_pay_directForward() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");
        uint256 amount = 1000;
        address beneficiary = makeAddr("beneficiary");
        address payer = makeAddr("payer");
        address mockTerminal = makeAddr("destTerminal");
        vm.etch(mockTerminal, hex"00");
        vm.etch(tokenIn, hex"00");

        // Not a JB token.
        vm.mockCall(
            address(mockTokens),
            abi.encodeWithSelector(IJBTokens.projectIdOf.selector),
            abi.encode(uint256(0))
        );

        // Project accepts tokenIn directly.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)),
            abi.encode(mockTerminal)
        );

        // Mock token transfer from payer.
        vm.mockCall(
            tokenIn, abi.encodeCall(IERC20.allowance, (payer, address(routerTerminal))), abi.encode(amount)
        );
        vm.mockCall(
            tokenIn, abi.encodeCall(IERC20.transferFrom, (payer, address(routerTerminal), amount)), abi.encode(true)
        );

        // Mock safeIncreaseAllowance: allowance check + approve.
        vm.mockCall(
            tokenIn,
            abi.encodeCall(IERC20.allowance, (address(routerTerminal), mockTerminal)),
            abi.encode(uint256(0))
        );
        vm.mockCall(tokenIn, abi.encodeCall(IERC20.approve, (mockTerminal, amount)), abi.encode(true));

        // Mock dest terminal pay.
        vm.mockCall(mockTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(100)));

        vm.prank(payer);
        uint256 result = routerTerminal.pay(projectId, tokenIn, amount, beneficiary, 0, "", "");
        assertEq(result, 100);
    }

    //*********************************************************************//
    // -------------------- pay with native tokens ---------------------- //
    //*********************************************************************//

    function test_pay_nativeTokenDirectForward() public {
        uint256 projectId = 1;
        uint256 amount = 1 ether;
        address beneficiary = makeAddr("beneficiary");
        address payer = makeAddr("payer");
        address mockTerminal = makeAddr("destTerminal");
        vm.etch(mockTerminal, hex"00");

        // Project accepts NATIVE_TOKEN directly.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(mockTerminal)
        );

        // Mock dest terminal pay (should receive msg.value).
        vm.mockCall(mockTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(50)));

        vm.deal(payer, amount);
        vm.prank(payer);
        uint256 result =
            routerTerminal.pay{value: amount}(projectId, JBConstants.NATIVE_TOKEN, amount, beneficiary, 0, "", "");
        assertEq(result, 50);
    }

    //*********************************************************************//
    // ----------------------- callback tests --------------------------- //
    //*********************************************************************//

    function test_callback_factoryVerified() public {
        address tokenIn = makeAddr("tokenIn");
        address tokenOut = makeAddr("tokenOut");
        address realPool = makeAddr("realPool");
        vm.etch(realPool, hex"00");
        vm.etch(tokenIn, hex"00");

        // The pool reports fee 3000.
        vm.mockCall(realPool, abi.encodeWithSignature("fee()"), abi.encode(uint24(3000)));

        // Factory confirms this pool.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, tokenOut, 3000)),
            abi.encode(realPool)
        );

        // Mock token transfer.
        vm.mockCall(tokenIn, abi.encodeCall(IERC20.transfer, (realPool, 100)), abi.encode(true));

        bytes memory data = abi.encode(uint256(1), tokenIn, tokenOut);

        // Call from the real pool — should succeed.
        vm.prank(realPool);
        routerTerminal.uniswapV3SwapCallback(int256(-200), int256(100), data);
    }

    function test_callback_rejectsUnverified() public {
        address tokenIn = makeAddr("tokenIn");
        address tokenOut = makeAddr("tokenOut");
        address fakePool = makeAddr("fakePool");
        address realPool = makeAddr("realPool");
        vm.etch(fakePool, hex"00");

        // Fake pool reports fee 3000.
        vm.mockCall(fakePool, abi.encodeWithSignature("fee()"), abi.encode(uint24(3000)));

        // Factory returns a different pool address.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, tokenOut, 3000)),
            abi.encode(realPool)
        );

        bytes memory data = abi.encode(uint256(1), tokenIn, tokenOut);

        vm.prank(fakePool);
        vm.expectRevert(
            abi.encodeWithSelector(IJBRouterTerminal.JBRouterTerminal_CallerNotPool.selector, fakePool)
        );
        routerTerminal.uniswapV3SwapCallback(int256(-200), int256(100), data);
    }

    //*********************************************************************//
    // -------------------- addToBalanceOf tests ------------------------ //
    //*********************************************************************//

    function test_addToBalanceOf_directForward() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");
        uint256 amount = 500;
        address payer = makeAddr("payer");
        address mockTerminal = makeAddr("destTerminal");
        vm.etch(mockTerminal, hex"00");
        vm.etch(tokenIn, hex"00");

        // Not a JB token.
        vm.mockCall(
            address(mockTokens),
            abi.encodeWithSelector(IJBTokens.projectIdOf.selector),
            abi.encode(uint256(0))
        );

        // Project accepts tokenIn.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)),
            abi.encode(mockTerminal)
        );

        // Mock token transfer.
        vm.mockCall(
            tokenIn, abi.encodeCall(IERC20.allowance, (payer, address(routerTerminal))), abi.encode(amount)
        );
        vm.mockCall(
            tokenIn, abi.encodeCall(IERC20.transferFrom, (payer, address(routerTerminal), amount)), abi.encode(true)
        );

        // Mock safeIncreaseAllowance.
        vm.mockCall(
            tokenIn,
            abi.encodeCall(IERC20.allowance, (address(routerTerminal), mockTerminal)),
            abi.encode(uint256(0))
        );
        vm.mockCall(tokenIn, abi.encodeCall(IERC20.approve, (mockTerminal, amount)), abi.encode(true));

        // Mock dest terminal addToBalanceOf.
        vm.mockCall(mockTerminal, abi.encodeWithSelector(IJBTerminal.addToBalanceOf.selector), abi.encode());

        vm.prank(payer);
        routerTerminal.addToBalanceOf(projectId, tokenIn, amount, false, "", "");
    }

    //*********************************************************************//
    // -------------------- discover pool tests ------------------------- //
    //*********************************************************************//

    function test_discoverPool_findsBestLiquidity() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        address pool3000 = makeAddr("pool3000");
        address pool500 = makeAddr("pool500");
        vm.etch(pool3000, hex"00");
        vm.etch(pool500, hex"00");

        // Pool at 0.3% has lower liquidity.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 3000)),
            abi.encode(pool3000)
        );
        vm.mockCall(pool3000, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(100e18)));

        // Pool at 0.05% has higher liquidity.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 500)),
            abi.encode(pool500)
        );
        vm.mockCall(pool500, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(500e18)));

        // No pools at other tiers.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 100)),
            abi.encode(address(0))
        );

        // Mock V4 — no pools.
        _mockV4NoPools(tokenA, tokenB);

        PoolInfo memory result = routerTerminal.exposed_discoverPool(tokenA, tokenB);
        assertFalse(result.isV4);
        assertEq(address(result.v3Pool), pool500);
    }

    function test_discoverPool_revertsNoPool() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");

        // No V3 pools at any tier.
        vm.mockCall(
            address(mockFactory), abi.encodeWithSelector(IUniswapV3Factory.getPool.selector), abi.encode(address(0))
        );

        // No V4 pools.
        _mockV4NoPools(tokenA, tokenB);

        vm.expectRevert(
            abi.encodeWithSelector(IJBRouterTerminal.JBRouterTerminal_NoPoolFound.selector, tokenA, tokenB)
        );
        routerTerminal.exposed_discoverPool(tokenA, tokenB);
    }

    //*********************************************************************//
    // -------------------- supports interface tests -------------------- //
    //*********************************************************************//

    function test_supportsInterface() public {
        assertTrue(routerTerminal.supportsInterface(type(IJBTerminal).interfaceId));
        assertTrue(routerTerminal.supportsInterface(type(IERC165).interfaceId));
    }

    //*********************************************************************//
    // ----------------------- no-op tests ------------------------------ //
    //*********************************************************************//

    function test_migrateBalanceOf_returnsZero() public {
        assertEq(
            routerTerminal.migrateBalanceOf(1, makeAddr("token"), IJBTerminal(makeAddr("terminal"))),
            0
        );
    }

    function test_addAccountingContextsFor_noOp() public {
        // Should not revert.
        routerTerminal.addAccountingContextsFor(1, new JBAccountingContext[](0));
    }

    //*********************************************************************//
    // ----------------------- V4 pool discovery tests ------------------ //
    //*********************************************************************//

    function test_discoverPool_v4WinsOverV3() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        address v3Pool = makeAddr("v3Pool");
        vm.etch(v3Pool, hex"00");

        // V3 pool with moderate liquidity.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 3000)),
            abi.encode(v3Pool)
        );
        vm.mockCall(v3Pool, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(100e18)));

        // No other V3 pools.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 100)),
            abi.encode(address(0))
        );

        // V4 pool with higher liquidity at 0.3%/60 tick spacing.
        // Sort currencies.
        (address sorted0, address sorted1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        PoolKey memory v4Key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: 3000,
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });
        PoolId v4Id = v4Key.toId();

        // Mock getSlot0 via extsload — pool exists (sqrtPriceX96 != 0).
        _mockV4PoolExists(v4Id, uint160(79228162514264337593543950336), 500e18);

        // Mock other V4 fee tiers as non-existent.
        _mockV4PoolNotExists(sorted0, sorted1, 500, int24(10));
        _mockV4PoolNotExists(sorted0, sorted1, 10_000, int24(200));
        _mockV4PoolNotExists(sorted0, sorted1, 100, int24(1));

        PoolInfo memory result = routerTerminal.exposed_discoverPool(tokenA, tokenB);
        assertTrue(result.isV4);
        assertEq(Currency.unwrap(result.v4Key.currency0), sorted0);
        assertEq(Currency.unwrap(result.v4Key.currency1), sorted1);
        assertEq(result.v4Key.fee, 3000);
    }

    function test_discoverPool_v3WinsOverV4() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        address v3Pool = makeAddr("v3Pool");
        vm.etch(v3Pool, hex"00");

        // V3 pool with high liquidity.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 3000)),
            abi.encode(v3Pool)
        );
        vm.mockCall(v3Pool, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(1000e18)));

        // No other V3 pools.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 100)),
            abi.encode(address(0))
        );

        // V4 pool with lower liquidity.
        (address sorted0, address sorted1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        PoolKey memory v4Key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: 3000,
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });
        PoolId v4Id = v4Key.toId();

        _mockV4PoolExists(v4Id, uint160(79228162514264337593543950336), 50e18);

        _mockV4PoolNotExists(sorted0, sorted1, 500, int24(10));
        _mockV4PoolNotExists(sorted0, sorted1, 10_000, int24(200));
        _mockV4PoolNotExists(sorted0, sorted1, 100, int24(1));

        PoolInfo memory result = routerTerminal.exposed_discoverPool(tokenA, tokenB);
        assertFalse(result.isV4);
        assertEq(address(result.v3Pool), v3Pool);
    }

    function test_discoverPool_v4OnlyNoV3() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");

        // No V3 pools.
        vm.mockCall(
            address(mockFactory), abi.encodeWithSelector(IUniswapV3Factory.getPool.selector), abi.encode(address(0))
        );

        // V4 pool exists.
        (address sorted0, address sorted1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        PoolKey memory v4Key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: 500,
            tickSpacing: int24(10),
            hooks: IHooks(address(0))
        });
        PoolId v4Id = v4Key.toId();

        // First fee tier (3000/60) doesn't exist.
        _mockV4PoolNotExists(sorted0, sorted1, 3000, int24(60));
        // Second fee tier (500/10) exists.
        _mockV4PoolExists(v4Id, uint160(79228162514264337593543950336), 200e18);
        // Other tiers don't exist.
        _mockV4PoolNotExists(sorted0, sorted1, 10_000, int24(200));
        _mockV4PoolNotExists(sorted0, sorted1, 100, int24(1));

        PoolInfo memory result = routerTerminal.exposed_discoverPool(tokenA, tokenB);
        assertTrue(result.isV4);
        assertEq(result.v4Key.fee, 500);
        assertEq(result.v4Key.tickSpacing, int24(10));
    }

    function test_discoverPool_noPoolManager() public {
        // Deploy a router with address(0) as PoolManager.
        RouterTerminalHarness noV4Router = new RouterTerminalHarness(
            mockDirectory,
            mockPermissions,
            mockProjects,
            mockTokens,
            mockPermit2,
            terminalOwner,
            mockWeth,
            mockFactory,
            IPoolManager(address(0)),
            address(0)
        );

        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        address v3Pool = makeAddr("v3Pool");
        vm.etch(v3Pool, hex"00");

        // V3 pool exists.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 3000)),
            abi.encode(v3Pool)
        );
        vm.mockCall(v3Pool, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(100e18)));

        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 100)),
            abi.encode(address(0))
        );

        // V4 is skipped (POOL_MANAGER = address(0)), should find V3 pool.
        PoolInfo memory result = noV4Router.exposed_discoverPool(tokenA, tokenB);
        assertFalse(result.isV4);
        assertEq(address(result.v3Pool), v3Pool);
    }

    //*********************************************************************//
    // -------------------- V4 unlock callback test --------------------- //
    //*********************************************************************//

    function test_unlockCallback_rejectsNonPoolManager() public {
        address notPoolManager = makeAddr("notPoolManager");

        vm.prank(notPoolManager);
        vm.expectRevert(
            abi.encodeWithSelector(IJBRouterTerminal.JBRouterTerminal_CallerNotPoolManager.selector, notPoolManager)
        );
        routerTerminal.unlockCallback("");
    }

    //*********************************************************************//
    // -------------------- V4 spot quote test -------------------------- //
    //*********************************************************************//

    function test_discoverBestPool_returnsV4() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");

        // No V3 pools.
        vm.mockCall(
            address(mockFactory), abi.encodeWithSelector(IUniswapV3Factory.getPool.selector), abi.encode(address(0))
        );

        // V4 pool exists at 3000/60.
        (address sorted0, address sorted1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        PoolKey memory v4Key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: 3000,
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });
        PoolId v4Id = v4Key.toId();
        _mockV4PoolExists(v4Id, uint160(79228162514264337593543950336), 300e18);

        _mockV4PoolNotExists(sorted0, sorted1, 500, int24(10));
        _mockV4PoolNotExists(sorted0, sorted1, 10_000, int24(200));
        _mockV4PoolNotExists(sorted0, sorted1, 100, int24(1));

        PoolInfo memory result = routerTerminal.discoverBestPool(tokenA, tokenB);
        assertTrue(result.isV4);
        assertEq(result.v4Key.fee, 3000);
    }

    //*********************************************************************//
    // ----------------------- V4 mock helpers -------------------------- //
    //*********************************************************************//

    /// @notice Mock V4 pool as existing with given sqrtPriceX96 and liquidity.
    function _mockV4PoolExists(PoolId id, uint160 sqrtPriceX96, uint256 liquidity) internal {
        // StateLibrary uses extsload to read pool state.
        // Slot0 is at the pool state slot.
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(id), bytes32(uint256(6))));

        // Pack slot0: sqrtPriceX96 (160 bits) | tick (24 bits) | protocolFee (24 bits) | lpFee (24 bits)
        bytes32 slot0Data = bytes32(uint256(sqrtPriceX96));
        vm.mockCall(
            address(mockPoolManager),
            abi.encodeWithSignature("extsload(bytes32)", stateSlot),
            abi.encode(slot0Data)
        );

        // Liquidity is at stateSlot + 3.
        bytes32 liquiditySlot = bytes32(uint256(stateSlot) + 3);
        vm.mockCall(
            address(mockPoolManager),
            abi.encodeWithSignature("extsload(bytes32)", liquiditySlot),
            abi.encode(bytes32(liquidity))
        );
    }

    /// @notice Mock a V4 pool as non-existent (sqrtPriceX96 = 0).
    function _mockV4PoolNotExists(address sorted0, address sorted1, uint24 fee, int24 tickSpacing) internal {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
        PoolId id = key.toId();
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(id), bytes32(uint256(6))));

        vm.mockCall(
            address(mockPoolManager),
            abi.encodeWithSignature("extsload(bytes32)", stateSlot),
            abi.encode(bytes32(0))
        );
    }

    /// @notice Mock all V4 pools as non-existent for a token pair.
    function _mockV4NoPools(address tokenA, address tokenB) internal {
        (address sorted0, address sorted1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        _mockV4PoolNotExists(sorted0, sorted1, 3000, int24(60));
        _mockV4PoolNotExists(sorted0, sorted1, 500, int24(10));
        _mockV4PoolNotExists(sorted0, sorted1, 10_000, int24(200));
        _mockV4PoolNotExists(sorted0, sorted1, 100, int24(1));
    }
}
