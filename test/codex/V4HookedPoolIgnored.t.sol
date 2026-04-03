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
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";
import {PoolInfo} from "../../src/structs/PoolInfo.sol";

contract HookedOnlyV4PoolManager {
    bytes32 internal immutable _SLOT0_SLOT;
    bytes32 internal immutable _LIQUIDITY_SLOT;

    constructor(PoolId supportedPoolId) {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(supportedPoolId), StateLibrary.POOLS_SLOT));
        _SLOT0_SLOT = stateSlot;
        _LIQUIDITY_SLOT = bytes32(uint256(stateSlot) + StateLibrary.LIQUIDITY_OFFSET);
    }

    function extsload(bytes32 slot) external view returns (bytes32 value) {
        if (slot == _SLOT0_SLOT) {
            return bytes32((uint256(3000) << 208) | uint256(uint160(1 << 96)));
        }
        if (slot == _LIQUIDITY_SLOT) {
            return bytes32(uint256(1_000_000));
        }
        return bytes32(0);
    }

    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory values) {
        values = new bytes32[](nSlots);
        for (uint256 i; i < nSlots; i++) {
            values[i] = this.extsload(bytes32(uint256(startSlot) + i));
        }
    }

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; i++) {
            values[i] = this.extsload(slots[i]);
        }
    }
}

contract NoV3Factory {
    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

contract V4HookedPoolIgnoredTest is Test {
    using PoolIdLibrary for PoolKey;

    JBRouterTerminal internal router;
    address internal tokenIn = address(0x1001);
    address internal tokenOut = address(0x2002);
    address internal hook = address(0x3003);

    function setUp() public {
        PoolKey memory hookedKey = PoolKey({
            currency0: Currency.wrap(tokenIn),
            currency1: Currency.wrap(tokenOut),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        HookedOnlyV4PoolManager poolManager = new HookedOnlyV4PoolManager(hookedKey.toId());

        router = new JBRouterTerminal({
            directory: IJBDirectory(address(0)),
            tokens: IJBTokens(address(0)),
            permit2: IPermit2(address(0)),
            weth: IWETH9(address(0xBEEF)),
            factory: IUniswapV3Factory(address(new NoV3Factory())),
            poolManager: IPoolManager(address(poolManager)),
            buybackHook: address(0),
            univ4Hook: hook,
            trustedForwarder: address(0)
        });
    }

    function test_discoverBestPool_findsHookedV4PoolWhenConfigured() public view {
        PoolInfo memory pool = router.discoverBestPool(tokenIn, tokenOut);

        assertTrue(pool.isV4);
        assertEq(address(pool.v3Pool), address(0));
        assertEq(address(pool.v4Key.hooks), hook);
    }
}
