// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

contract RegressionLeftoverMockERC20 {
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

contract RegressionLeftoverMockWETH is IWETH9 {
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

contract RegressionLeftoverDestTerminal is IJBTerminal {
    uint256 public lastAmount;

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function addToBalanceOf(
        uint256,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
        override
    {
        // Pull the ERC20 into the terminal so final-hop receipt enforcement observes real delivery.
        if (token != JBConstants.NATIVE_TOKEN) {
            require(
                RegressionLeftoverMockERC20(token).transferFrom(msg.sender, address(this), amount),
                "RegressionLeftoverDestTerminal: transferFrom failed"
            );
        }

        lastAmount = amount;
    }

    function accountingContextForTokenOf(
        uint256,
        address token
    )
        external
        pure
        override
        returns (JBAccountingContext memory)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        return JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: address(1), decimals: 18, currency: 1});
    }

    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external pure override returns (uint256) {}

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {}

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
        payable
        override
        returns (uint256)
    {
        // Pull the ERC20 into the terminal so final-hop receipt enforcement observes real delivery.
        if (token != JBConstants.NATIVE_TOKEN) {
            require(
                RegressionLeftoverMockERC20(token).transferFrom(msg.sender, address(this), amount),
                "RegressionLeftoverDestTerminal: transferFrom failed"
            );
        }

        lastAmount = amount;
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
        override
        returns (JBRuleset memory, uint256, uint256, JBPayHookSpecification[] memory hookSpecifications)
    {
        hookSpecifications = new JBPayHookSpecification[](0);
        return (
            JBRuleset({
                cycleNumber: 0,
                id: 0,
                basedOnId: 0,
                start: 0,
                duration: 0,
                weight: 0,
                weightCutPercent: 0,
                approvalHook: IJBRulesetApprovalHook(address(0)),
                metadata: 0
            }),
            amount,
            0,
            hookSpecifications
        );
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }
}

contract RegressionLeftoverPartialFillPool is IUniswapV3Pool {
    address internal immutable _TOKEN0;
    address internal immutable _TOKEN1;
    RegressionLeftoverMockERC20 internal immutable _OUTPUT_TOKEN;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint24 public immutable override fee = 3000;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint128 public immutable override liquidity = 1_000_000;

    uint256 public immutable AMOUNT_IN_USED;
    uint256 public immutable AMOUNT_OUT_GIVEN;

    constructor(
        address token0_,
        address token1_,
        RegressionLeftoverMockERC20 outputToken_,
        uint256 amountInUsed_,
        uint256 amountOutGiven_
    ) {
        _TOKEN0 = token0_;
        _TOKEN1 = token1_;
        _OUTPUT_TOKEN = outputToken_;
        AMOUNT_IN_USED = amountInUsed_;
        AMOUNT_OUT_GIVEN = amountOutGiven_;
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256,
        uint160,
        bytes calldata data
    )
        external
        override
        returns (int256 amount0, int256 amount1)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 signedIn = int256(AMOUNT_IN_USED);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 signedOut = int256(AMOUNT_OUT_GIVEN);

        if (zeroForOne) {
            JBRouterTerminal(payable(msg.sender)).uniswapV3SwapCallback(signedIn, -signedOut, data);
            _OUTPUT_TOKEN.mint(recipient, AMOUNT_OUT_GIVEN);
            return (signedIn, -signedOut);
        }

        JBRouterTerminal(payable(msg.sender)).uniswapV3SwapCallback(-signedOut, signedIn, data);
        _OUTPUT_TOKEN.mint(recipient, AMOUNT_OUT_GIVEN);
        return (-signedOut, signedIn);
    }

    function token0() external view override returns (address) {
        return _TOKEN0;
    }

    function token1() external view override returns (address) {
        return _TOKEN1;
    }

    function tickSpacing() external pure override returns (int24) {
        return 1;
    }

    function slot0() external pure override returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, 0, 0, 0, 0, 0, false);
    }

    function feeGrowthGlobal0X128() external pure override returns (uint256) {}
    function feeGrowthGlobal1X128() external pure override returns (uint256) {}
    function protocolFees() external pure override returns (uint128, uint128) {}
    function ticks(int24)
        external
        pure
        override
        returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool)
    {}
    function tickBitmap(int16) external pure override returns (uint256) {}
    function positions(bytes32) external pure override returns (uint128, uint256, uint256, uint128, uint128) {}
    function observations(uint256) external pure override returns (uint32, int56, uint160, bool) {}
    function observe(uint32[] calldata) external pure override returns (int56[] memory, uint160[] memory) {}
    function snapshotCumulativesInside(int24, int24) external pure override returns (int56, uint160, uint32) {}
    function increaseObservationCardinalityNext(uint16) external override {}
    function mint(address, int24, int24, uint128, bytes calldata) external pure override returns (uint256, uint256) {}
    function collect(address, int24, int24, uint128, uint128) external pure override returns (uint128, uint128) {}
    function burn(int24, int24, uint128) external pure override returns (uint256, uint256) {}
    function flash(address, uint256, uint256, bytes calldata) external override {}
    function initialize(uint160) external override {}
    function setFeeProtocol(uint8, uint8) external override {}
    function collectProtocol(address, uint128, uint128) external pure override returns (uint128, uint128) {}

    function factory() external pure override returns (address) {
        return address(0);
    }

    function maxLiquidityPerTick() external pure override returns (uint128) {
        return type(uint128).max;
    }
}

contract LeftoverRefundTest is Test {
    JBRouterTerminal internal router;
    IJBDirectory internal directory;
    IJBPermissions internal permissions;

    IJBTokens internal tokens;
    IPermit2 internal permit2;
    IUniswapV3Factory internal factory;
    IWETH9 internal weth;

    uint256 internal constant PROJECT_ID = 1;

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        permissions = IJBPermissions(makeAddr("permissions"));

        tokens = IJBTokens(makeAddr("tokens"));
        permit2 = IPermit2(makeAddr("permit2"));
        factory = IUniswapV3Factory(makeAddr("factory"));
        weth = IWETH9(address(new RegressionLeftoverMockWETH()));

        vm.etch(address(directory), hex"00");
        vm.etch(address(permissions), hex"00");
        vm.etch(address(tokens), hex"00");
        vm.etch(address(permit2), hex"00");
        vm.etch(address(factory), hex"00");

        router = new JBRouterTerminal({
            directory: directory,
            tokens: tokens,
            permit2: permit2,
            buybackHook: address(0),
            trustedForwarder: address(0),
            deployer: address(this)
        });
        router.setChainSpecificConstants({
            newWrappedNativeToken: weth,
            newFactory: factory,
            newPoolManager: IPoolManager(address(0)),
            newUniv4Hook: address(0)
        });
    }

    /// @notice Partial-fill leftovers from pay() are refunded to the original payer.
    function test_payPartialFillRefundsOriginalPayer() public {
        RegressionLeftoverMockERC20 tokenIn = new RegressionLeftoverMockERC20();
        RegressionLeftoverMockERC20 tokenOut = new RegressionLeftoverMockERC20();
        RegressionLeftoverDestTerminal destTerminal = new RegressionLeftoverDestTerminal();
        RegressionLeftoverPartialFillPool pool = _deployPool(tokenIn, tokenOut, 600 ether, 100 ether);

        _mockSimpleSwapRoute(tokenIn, tokenOut, destTerminal, pool);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        tokenIn.mint(alice, 1000 ether);
        vm.prank(alice);
        tokenIn.approve(address(router), type(uint256).max);

        vm.prank(alice);
        router.pay(PROJECT_ID, address(tokenIn), 1000 ether, bob, 0, "", _metadata(tokenOut));

        assertEq(destTerminal.lastAmount(), 100 ether, "destination only receives filled output");
        assertEq(tokenIn.balanceOf(bob), 0, "beneficiary should not receive leftover input");
        assertEq(tokenIn.balanceOf(alice), 400 ether, "original payer receives leftover input");
    }

    function test_addToBalanceRefundDoesNotLeakPreexistingRouterBalance() public {
        RegressionLeftoverMockERC20 tokenIn = new RegressionLeftoverMockERC20();
        RegressionLeftoverMockERC20 tokenOut = new RegressionLeftoverMockERC20();
        RegressionLeftoverDestTerminal destTerminal = new RegressionLeftoverDestTerminal();
        RegressionLeftoverPartialFillPool pool = _deployPool(tokenIn, tokenOut, 600 ether, 100 ether);

        _mockSimpleSwapRoute(tokenIn, tokenOut, destTerminal, pool);

        address donor = makeAddr("donor");
        address attacker = makeAddr("attacker");

        tokenIn.mint(donor, 50 ether);
        vm.prank(donor);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenIn.transfer(address(router), 50 ether);

        tokenIn.mint(attacker, 1000 ether);
        vm.prank(attacker);
        tokenIn.approve(address(router), type(uint256).max);

        vm.prank(attacker);
        router.addToBalanceOf(PROJECT_ID, address(tokenIn), 1000 ether, false, "", _metadata(tokenOut));

        assertEq(destTerminal.lastAmount(), 100 ether, "destination only receives filled output");
        assertEq(tokenIn.balanceOf(attacker), 400 ether, "attacker only receives this route's leftover");
        assertEq(tokenIn.balanceOf(address(router)), 50 ether, "preexisting router balance should remain untouched");
    }

    function test_payNativePartialFillDoesNotSweepPreexistingRouterEth() public {
        RegressionLeftoverMockERC20 tokenOut = new RegressionLeftoverMockERC20();
        RegressionLeftoverDestTerminal destTerminal = new RegressionLeftoverDestTerminal();
        RegressionLeftoverPartialFillPool pool = _deployNativePool(tokenOut, 600 ether, 100 ether);

        _mockSimpleNativeSwapRoute(tokenOut, destTerminal, pool);

        address payer = makeAddr("payer");
        vm.deal(address(router), 50 ether);
        vm.deal(payer, 1000 ether);

        vm.prank(payer);
        router.pay{value: 1000 ether}(
            PROJECT_ID, JBConstants.NATIVE_TOKEN, 1000 ether, payer, 0, "", _metadata(tokenOut)
        );

        assertEq(destTerminal.lastAmount(), 100 ether, "destination only receives filled output");
        assertEq(payer.balance, 400 ether, "payer only receives this route's leftover");
        assertEq(address(router).balance, 50 ether, "preexisting raw ETH should remain untouched");
    }

    function _deployPool(
        RegressionLeftoverMockERC20 tokenIn,
        RegressionLeftoverMockERC20 tokenOut,
        uint256 amountInUsed,
        uint256 amountOutGiven
    )
        internal
        returns (RegressionLeftoverPartialFillPool pool)
    {
        (address token0, address token1) = address(tokenIn) < address(tokenOut)
            ? (address(tokenIn), address(tokenOut))
            : (address(tokenOut), address(tokenIn));
        pool = new RegressionLeftoverPartialFillPool(token0, token1, tokenOut, amountInUsed, amountOutGiven);
    }

    function _deployNativePool(
        RegressionLeftoverMockERC20 tokenOut,
        uint256 amountInUsed,
        uint256 amountOutGiven
    )
        internal
        returns (RegressionLeftoverPartialFillPool pool)
    {
        (address token0, address token1) =
            address(weth) < address(tokenOut) ? (address(weth), address(tokenOut)) : (address(tokenOut), address(weth));
        pool = new RegressionLeftoverPartialFillPool(token0, token1, tokenOut, amountInUsed, amountOutGiven);
    }

    function _metadata(RegressionLeftoverMockERC20 tokenOut) internal view returns (bytes memory metadata) {
        metadata = JBMetadataResolver.addToMetadata(
            "", JBMetadataResolver.getId("routeTokenOut", address(router)), abi.encode(address(tokenOut))
        );
        metadata = JBMetadataResolver.addToMetadata(
            metadata, JBMetadataResolver.getId("pay", address(router)), abi.encode(address(tokenOut), 100 ether)
        );
    }

    function _mockSimpleSwapRoute(
        RegressionLeftoverMockERC20 tokenIn,
        RegressionLeftoverMockERC20 tokenOut,
        RegressionLeftoverDestTerminal destTerminal,
        RegressionLeftoverPartialFillPool pool
    )
        internal
    {
        vm.mockCall(address(tokens), abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(tokenIn))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(tokenOut))),
            abi.encode(address(destTerminal))
        );
        vm.mockCall(
            address(factory),
            abi.encodeCall(IUniswapV3Factory.getPool, (address(tokenIn), address(tokenOut), uint24(3000))),
            abi.encode(address(pool))
        );
        vm.mockCall(
            address(factory),
            abi.encodeCall(IUniswapV3Factory.getPool, (address(tokenIn), address(tokenOut), uint24(500))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(factory),
            abi.encodeCall(IUniswapV3Factory.getPool, (address(tokenIn), address(tokenOut), uint24(10_000))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(factory),
            abi.encodeCall(IUniswapV3Factory.getPool, (address(tokenIn), address(tokenOut), uint24(100))),
            abi.encode(address(0))
        );
    }

    function _mockSimpleNativeSwapRoute(
        RegressionLeftoverMockERC20 tokenOut,
        RegressionLeftoverDestTerminal destTerminal,
        RegressionLeftoverPartialFillPool pool
    )
        internal
    {
        vm.mockCall(address(tokens), abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(tokenOut))),
            abi.encode(address(destTerminal))
        );
        vm.mockCall(
            address(factory),
            abi.encodeCall(IUniswapV3Factory.getPool, (address(weth), address(tokenOut), uint24(3000))),
            abi.encode(address(pool))
        );
        vm.mockCall(
            address(factory),
            abi.encodeCall(IUniswapV3Factory.getPool, (address(weth), address(tokenOut), uint24(500))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(factory),
            abi.encodeCall(IUniswapV3Factory.getPool, (address(weth), address(tokenOut), uint24(10_000))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(factory),
            abi.encodeCall(IUniswapV3Factory.getPool, (address(weth), address(tokenOut), uint24(100))),
            abi.encode(address(0))
        );
    }
}
