// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

/// @notice Mock PoolManager that captures the hookData argument from swap() calls.
/// It returns a valid BalanceDelta so the unlock callback can run to completion.
contract CapturingPoolManager {
    bytes public capturedHookData;
    bool public swapCalled;

    /// @notice Captures hookData and returns a delta representing a swap of 1000 in, 900 out (zeroForOne).
    function swap(PoolKey memory, SwapParams memory, bytes calldata hookData) external returns (BalanceDelta) {
        capturedHookData = hookData;
        swapCalled = true;
        // Return delta: amount0 = -1000 (input consumed), amount1 = +900 (output received)
        // zeroForOne: input is currency0 (negative delta), output is currency1 (positive delta)
        return toBalanceDelta(-1000, 900);
    }

    /// @notice No-op settle for ERC-20 path.
    function settle() external payable returns (uint256) {
        return 0;
    }

    /// @notice No-op sync for ERC-20 path.
    function sync(Currency) external {}

    /// @notice No-op take for output side.
    function take(Currency, address, uint256) external {}

    /// @notice Fallback so vm.etch and other calls don't revert.
    fallback() external payable {}
    receive() external payable {}
}

/// @notice When the V4 pool key has hooks != address(0), the hookData passed to PoolManager.swap()
/// must contain abi.encode(minAmountOut), not empty bytes. Otherwise hooks like JBUniswapV4Hook will revert.
contract HookDataEncodingTest is Test {
    JBRouterTerminal internal router;
    CapturingPoolManager internal poolManager;

    // Use distinct non-zero addresses for ERC-20 tokens (avoid native-ETH paths for simplicity).
    address internal tokenA = address(0xAAAA);
    address internal tokenB = address(0xBBBB);
    // Hook address — any non-zero address.
    address internal hook = address(0xCC01);

    function setUp() public {
        poolManager = new CapturingPoolManager();

        // Deploy the router with the capturing pool manager.
        router = new JBRouterTerminal({
            directory: IJBDirectory(address(1)),
            tokens: IJBTokens(address(2)),
            permit2: IPermit2(address(3)),
            weth: IWETH9(address(4)),
            factory: IUniswapV3Factory(address(5)),
            poolManager: IPoolManager(address(poolManager)),
            buybackHook: address(0),
            univ4Hook: hook,
            trustedForwarder: address(0)
        });

        // Mock the IERC20.transfer call that _settleV4 makes (safeTransfer to pool manager).
        vm.mockCall(
            tokenA,
            abi.encodeWithSignature("transfer(address,uint256)", address(poolManager), uint256(1000)),
            abi.encode(true)
        );
        // Mock the IERC20.transfer for output side _takeV4 (not actually called since take is no-op, but be safe).
        vm.mockCall(
            tokenB,
            abi.encodeWithSignature("transfer(address,uint256)", address(router), uint256(900)),
            abi.encode(true)
        );
    }

    /// @notice When a hooked V4 pool is used, hookData must contain abi.encode(minAmountOut).
    function test_hookData_containsMinAmountOut_whenHooksConfigured() public {
        // Build a pool key with hooks.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(tokenA),
            currency1: Currency.wrap(tokenB),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        uint256 minAmountOut = 800;
        bool zeroForOne = true;
        int256 amountSpecified = -1000; // exact input of 1000
        uint160 sqrtPriceLimitX96 = 4_295_128_740; // TickMath.MIN_SQRT_RATIO + 1
        bool canUseExistingNativeBalance = false;

        // Encode the callback data exactly as _executeV4Swap does.
        bytes memory callbackData =
            abi.encode(key, zeroForOne, amountSpecified, sqrtPriceLimitX96, minAmountOut, canUseExistingNativeBalance);

        // Call unlockCallback as the PoolManager (required by the msg.sender check).
        vm.prank(address(poolManager));
        router.unlockCallback(callbackData);

        // Verify swap was called.
        assertTrue(poolManager.swapCalled(), "swap should have been called");

        // The key assertion: hookData should contain abi.encode(minAmountOut), not be empty.
        bytes memory expectedHookData = abi.encode(minAmountOut);
        assertEq(poolManager.capturedHookData(), expectedHookData, "hookData must encode minAmountOut for hooked pools");
    }

    /// @notice When a pool has no hooks (address(0)), hookData should remain empty.
    function test_hookData_isEmpty_whenNoHooks() public {
        // Build a pool key WITHOUT hooks.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(tokenA),
            currency1: Currency.wrap(tokenB),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        uint256 minAmountOut = 800;
        bool zeroForOne = true;
        int256 amountSpecified = -1000;
        uint160 sqrtPriceLimitX96 = 4_295_128_740;
        bool canUseExistingNativeBalance = false;

        bytes memory callbackData =
            abi.encode(key, zeroForOne, amountSpecified, sqrtPriceLimitX96, minAmountOut, canUseExistingNativeBalance);

        vm.prank(address(poolManager));
        router.unlockCallback(callbackData);

        assertTrue(poolManager.swapCalled(), "swap should have been called");

        // With no hooks, hookData should be empty.
        assertEq(poolManager.capturedHookData(), "", "hookData must be empty when no hooks configured");
    }
}
