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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

/// @notice Contract that cannot receive ETH — triggers the WETH fallback path.
contract ETHRejecter {
    // No receive() or fallback() — any ETH transfer reverts.
}

/// @notice Minimal ERC20 mock.
contract RefundMockERC20 {
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

/// @notice Mock WETH that tracks balances and sends ETH on withdraw.
contract RefundMockWETH is IWETH9 {
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

/// @notice Destination terminal that accepts native payments.
contract RefundDestTerminal is IJBTerminal {
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
        if (token != JBConstants.NATIVE_TOKEN) {
            require(
                RefundMockERC20(token).transferFrom(msg.sender, address(this), amount),
                "RefundDestTerminal: transferFrom failed"
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
        if (token != JBConstants.NATIVE_TOKEN) {
            require(
                RefundMockERC20(token).transferFrom(msg.sender, address(this), amount),
                "RefundDestTerminal: transferFrom failed"
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

    receive() external payable {}
}

/// @notice Partial-fill V3 pool mock that only uses a portion of the input.
contract RefundPartialFillPool is IUniswapV3Pool {
    address internal immutable _TOKEN0;
    address internal immutable _TOKEN1;
    RefundMockERC20 internal immutable _OUTPUT_TOKEN;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint24 public immutable override fee = 3000;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint128 public immutable override liquidity = 1_000_000;

    uint256 public immutable AMOUNT_IN_USED;
    uint256 public immutable AMOUNT_OUT_GIVEN;

    constructor(
        address token0_,
        address token1_,
        RefundMockERC20 outputToken_,
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

/// @notice Tests for the native-token refund WETH fallback.
contract NativeRefundFallbackTest is Test {
    JBRouterTerminal internal router;
    IJBDirectory internal directory;
    IJBPermissions internal permissions;
    IJBTokens internal tokens;
    IPermit2 internal permit2;
    IUniswapV3Factory internal factory;
    RefundMockWETH internal weth;

    uint256 internal constant PROJECT_ID = 1;

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        permissions = IJBPermissions(makeAddr("permissions"));
        tokens = IJBTokens(makeAddr("tokens"));
        permit2 = IPermit2(makeAddr("permit2"));
        factory = IUniswapV3Factory(makeAddr("factory"));
        weth = new RefundMockWETH();

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
            newWrappedNativeToken: IWETH9(address(weth)),
            newFactory: factory,
            newPoolManager: IPoolManager(address(0)),
            newUniv4Hook: address(0)
        });
    }

    /// @notice When the refund recipient can accept ETH, the partial-fill leftover is sent as native ETH.
    function test_nativeRefundSucceedsForEOA() public {
        RefundMockERC20 tokenOut = new RefundMockERC20();
        RefundDestTerminal destTerminal = new RefundDestTerminal();
        RefundPartialFillPool pool = _deployNativePool(tokenOut, 600 ether, 100 ether);
        _mockSimpleNativeSwapRoute(tokenOut, destTerminal, pool);

        address payer = makeAddr("payer");
        vm.deal(payer, 1000 ether);

        vm.prank(payer);
        router.pay{value: 1000 ether}(
            PROJECT_ID, JBConstants.NATIVE_TOKEN, 1000 ether, payer, 0, "", _metadata(tokenOut)
        );

        assertEq(payer.balance, 400 ether, "payer should receive native ETH refund");
        assertEq(weth.balanceOf(payer), 0, "payer should not receive WETH when ETH succeeds");
    }

    /// @notice When the refund recipient cannot accept ETH, the leftover is sent as WETH instead of reverting.
    function test_nativeRefundFallsBackToWETHForETHRejecter() public {
        RefundMockERC20 tokenOut = new RefundMockERC20();
        RefundDestTerminal destTerminal = new RefundDestTerminal();
        RefundPartialFillPool pool = _deployNativePool(tokenOut, 600 ether, 100 ether);
        _mockSimpleNativeSwapRoute(tokenOut, destTerminal, pool);

        // Deploy an ETH-rejecting contract as the payer.
        ETHRejecter rejecter = new ETHRejecter();
        vm.deal(address(rejecter), 1000 ether);

        vm.prank(address(rejecter));
        router.pay{value: 1000 ether}(
            PROJECT_ID, JBConstants.NATIVE_TOKEN, 1000 ether, address(rejecter), 0, "", _metadata(tokenOut)
        );

        assertEq(address(rejecter).balance, 0, "rejecter should not hold raw ETH");
        assertEq(weth.balanceOf(address(rejecter)), 400 ether, "rejecter should receive WETH as fallback");
        assertEq(destTerminal.lastAmount(), 100 ether, "destination received the swap output");
    }

    function _deployNativePool(
        RefundMockERC20 tokenOut,
        uint256 amountInUsed,
        uint256 amountOutGiven
    )
        internal
        returns (RefundPartialFillPool pool)
    {
        (address token0, address token1) =
            address(weth) < address(tokenOut) ? (address(weth), address(tokenOut)) : (address(tokenOut), address(weth));
        pool = new RefundPartialFillPool(token0, token1, tokenOut, amountInUsed, amountOutGiven);
    }

    function _metadata(RefundMockERC20 tokenOut) internal view returns (bytes memory metadata) {
        metadata = JBMetadataResolver.addToMetadata(
            "", JBMetadataResolver.getId("routeTokenOut", address(router)), abi.encode(address(tokenOut))
        );
        metadata = JBMetadataResolver.addToMetadata(
            metadata, JBMetadataResolver.getId("pay", address(router)), abi.encode(address(tokenOut), 100 ether)
        );
    }

    function _mockSimpleNativeSwapRoute(
        RefundMockERC20 tokenOut,
        RefundDestTerminal destTerminal,
        RefundPartialFillPool pool
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
