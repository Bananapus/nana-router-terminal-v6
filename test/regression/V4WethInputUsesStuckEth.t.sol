// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

contract SubsidyToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SubsidyWETH is IWETH9 {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function deposit() external payable override {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    function withdraw(uint256 amount) external override {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {}
}

contract NoV3Factory {
    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

contract SubsidyDestTerminal {
    uint256 public totalReceived;

    function pay(
        uint256,
        address token,
        uint256 amount,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        returns (uint256)
    {
        require(SubsidyToken(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        totalReceived += amount;
        return amount;
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
        returns (JBRuleset memory ruleset, uint256, uint256, JBPayHookSpecification[] memory hookSpecifications)
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
        hookSpecifications = new JBPayHookSpecification[](0);
        return (ruleset, amount, 0, hookSpecifications);
    }

    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](0);
    }

    function accountingContextForTokenOf(
        uint256,
        address token
    )
        external
        pure
        returns (JBAccountingContext memory context)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        context = JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

contract SubsidyPoolManager {
    using PoolIdLibrary for PoolKey;

    bytes32 internal immutable _SLOT0_SLOT;
    bytes32 internal immutable _LIQUIDITY_SLOT;
    SubsidyToken internal immutable _TOKEN_OUT;

    uint256 public totalSettledEth;
    uint256 public constant INPUT_USED = 60 ether;
    uint256 public constant OUTPUT_GIVEN = 100 ether;

    constructor(PoolId supportedPoolId, SubsidyToken tokenOut) {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(supportedPoolId), StateLibrary.POOLS_SLOT));
        _SLOT0_SLOT = stateSlot;
        _LIQUIDITY_SLOT = bytes32(uint256(stateSlot) + StateLibrary.LIQUIDITY_OFFSET);
        _TOKEN_OUT = tokenOut;
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

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey memory, SwapParams memory params, bytes calldata) external pure returns (BalanceDelta) {
        require(params.zeroForOne, "unexpected direction");
        // forge-lint: disable-next-line(unsafe-typecast)
        // forge-lint: disable-next-line(unsafe-typecast)
        // forge-lint: disable-next-line(unsafe-typecast)
        // forge-lint: disable-next-line(unsafe-typecast)
        return toBalanceDelta(-int128(int256(INPUT_USED)), int128(int256(OUTPUT_GIVEN)));
    }

    function sync(Currency) external {}

    function take(Currency currency, address to, uint256 amount) external {
        require(Currency.unwrap(currency) == address(_TOKEN_OUT), "unexpected token");
        _TOKEN_OUT.mint(to, amount);
    }

    function settle() external payable returns (uint256 paid) {
        totalSettledEth += msg.value;
        return msg.value;
    }

    receive() external payable {}
}

contract V4WethInputUsesStuckEthTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant STUCK_ETH = 50 ether;
    uint256 internal constant WETH_INPUT = 100 ether;

    JBRouterTerminal internal router;
    IJBDirectory internal directory;
    IJBTokens internal tokens;
    SubsidyWETH internal weth;
    SubsidyToken internal tokenOut;
    SubsidyDestTerminal internal destTerminal;
    SubsidyPoolManager internal poolManager;

    address internal payer = makeAddr("payer");

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        tokens = IJBTokens(makeAddr("tokens"));
        vm.etch(address(directory), hex"00");
        vm.etch(address(tokens), hex"00");

        weth = new SubsidyWETH();
        tokenOut = new SubsidyToken();
        destTerminal = new SubsidyDestTerminal();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenOut)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolManager = new SubsidyPoolManager(key.toId(), tokenOut);

        router = new JBRouterTerminal({
            directory: directory,
            tokens: tokens,
            permit2: IPermit2(address(0)),
            weth: weth,
            factory: IUniswapV3Factory(address(new NoV3Factory())),
            poolManager: IPoolManager(address(poolManager)),
            buybackHook: address(0),
            univ4Hook: address(0),
            trustedForwarder: address(0)
        });

        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(weth))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(tokenOut))),
            abi.encode(address(destTerminal))
        );
        vm.mockCall(
            address(tokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(weth)))), abi.encode(uint256(0))
        );

        vm.deal(payer, WETH_INPUT);
        vm.prank(payer);
        weth.deposit{value: WETH_INPUT}();
        vm.prank(payer);
        weth.approve(address(router), type(uint256).max);

        vm.deal(address(router), STUCK_ETH);
    }

    function test_wethInputV4SwapDoesNotConsumeUnrelatedStuckEth() public {
        bytes memory metadata = JBMetadataResolver.addToMetadata(
            "", JBMetadataResolver.getId("routeTokenOut", address(router)), abi.encode(address(tokenOut))
        );
        metadata = JBMetadataResolver.addToMetadata(metadata, JBMetadataResolver.getId("quoteForSwap"), abi.encode(1));

        uint256 payerWethBefore = weth.balanceOf(payer);

        vm.prank(payer);
        router.pay(PROJECT_ID, address(weth), WETH_INPUT, payer, 0, "", metadata);

        assertEq(poolManager.totalSettledEth(), 60 ether, "pool manager settled native ETH");
        assertEq(destTerminal.totalReceived(), 100 ether, "destination received full output");
        assertEq(
            weth.balanceOf(payer),
            payerWethBefore - 60 ether,
            "payer should spend the full native input from WETH when the route is WETH-funded"
        );
        assertEq(address(router).balance, STUCK_ETH, "unrelated stuck ETH should remain untouched");
        assertEq(weth.balanceOf(address(router)), 0, "router does not retain leftover WETH after refund");
    }
}
