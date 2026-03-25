// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
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
import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

contract AuditMockERC20 {
    string public name;
    string public symbol;
    // forge-lint: disable-next-line(screaming-snake-case-const)
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

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

contract AuditMockWETH is IWETH9 {
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant name = "Wrapped Ether";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant symbol = "WETH";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    uint8 public constant decimals = 18;
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

contract AuditMockDestTerminal is IJBTerminal {
    address public lastToken;
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
        lastToken = token;
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
        lastToken = token;
        lastAmount = amount;
        return amount;
    }

    function previewPayFor(
        uint256,
        address, /* token — unused in mock, required by IJBTerminal interface */
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
        // forge-lint: disable-next-line(named-struct-fields)
        return (JBRuleset(0, 0, 0, 0, 0, 0, 0, IJBRulesetApprovalHook(address(0)), 0), amount, 0, hookSpecifications);
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }
}

contract AuditPartialFillPool is IUniswapV3Pool {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address internal immutable _token0;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address internal immutable _token1;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    AuditMockERC20 internal immutable _zeroForOneOutputToken;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    AuditMockERC20 internal immutable _oneForZeroOutputToken;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint24 public immutable override fee = 3000;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint128 public immutable override liquidity = 1_000_000;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint256 public immutable amountInUsed;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint256 public immutable amountOutGiven;

    constructor(
        address token0_,
        address token1_,
        AuditMockERC20 zeroForOneOutputToken_,
        AuditMockERC20 oneForZeroOutputToken_,
        uint256 amountInUsed_,
        uint256 amountOutGiven_
    ) {
        _token0 = token0_;
        _token1 = token1_;
        _zeroForOneOutputToken = zeroForOneOutputToken_;
        _oneForZeroOutputToken = oneForZeroOutputToken_;
        amountInUsed = amountInUsed_;
        amountOutGiven = amountOutGiven_;
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
        if (zeroForOne) {
            JBRouterTerminal(payable(msg.sender)).
                // forge-lint: disable-next-line(unsafe-typecast)
                uniswapV3SwapCallback(int256(amountInUsed), -int256(amountOutGiven), data);
            _zeroForOneOutputToken.mint(recipient, amountOutGiven);
            // forge-lint: disable-next-line(unsafe-typecast)
            return (int256(amountInUsed), -int256(amountOutGiven));
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        JBRouterTerminal(payable(msg.sender)).uniswapV3SwapCallback(-int256(amountOutGiven), int256(amountInUsed), data);
        _oneForZeroOutputToken.mint(recipient, amountOutGiven);
        // forge-lint: disable-next-line(unsafe-typecast)
        return (-int256(amountOutGiven), int256(amountInUsed));
    }

    function token0() external view override returns (address) {
        return _token0;
    }

    function token1() external view override returns (address) {
        return _token1;
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

contract CodexRegistryAddToBalancePartialFillTest is Test {
    IJBDirectory directory;
    IJBPermissions permissions;
    IJBProjects projects;
    IJBTokens tokens;
    IPermit2 permit2;
    IUniswapV3Factory factory;
    IWETH9 weth;

    JBRouterTerminal router;
    JBRouterTerminalRegistry registry;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    uint256 projectId = 1;

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        permissions = IJBPermissions(makeAddr("permissions"));
        projects = IJBProjects(makeAddr("projects"));
        tokens = IJBTokens(makeAddr("tokens"));
        permit2 = IPermit2(makeAddr("permit2"));
        factory = IUniswapV3Factory(makeAddr("factory"));
        weth = IWETH9(address(new AuditMockWETH()));

        vm.etch(address(directory), hex"00");
        vm.etch(address(permissions), hex"00");
        vm.etch(address(projects), hex"00");
        vm.etch(address(tokens), hex"00");
        vm.etch(address(permit2), hex"00");
        vm.etch(address(factory), hex"00");

        router = new JBRouterTerminal(
            directory,
            permissions,
            projects,
            tokens,
            permit2,
            owner,
            weth,
            factory,
            IPoolManager(address(0)),
            address(0)
        );
        registry = new JBRouterTerminalRegistry(permissions, projects, permit2, owner, address(0));

        vm.prank(owner);
        registry.setDefaultTerminal(IJBTerminal(address(router)));
    }

    function test_registryAddToBalance_partialFillRefundsErc20ToOriginalPayer() public {
        AuditMockERC20 tokenIn = new AuditMockERC20("In", "IN");
        AuditMockERC20 tokenOut = new AuditMockERC20("Out", "OUT");
        AuditMockDestTerminal destTerminal = new AuditMockDestTerminal();
        AuditPartialFillPool pool = new AuditPartialFillPool(
            address(tokenIn) < address(tokenOut) ? address(tokenIn) : address(tokenOut),
            address(tokenIn) < address(tokenOut) ? address(tokenOut) : address(tokenIn),
            tokenOut,
            tokenOut,
            600 ether,
            100 ether
        );

        vm.mockCall(address(tokens), abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, address(tokenIn))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, address(tokenOut))),
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

        tokenIn.mint(user, 1000 ether);
        vm.prank(user);
        tokenIn.approve(address(registry), type(uint256).max);

        bytes memory metadata = JBMetadataResolver.addToMetadata(
            "", JBMetadataResolver.getId("routeTokenOut", address(router)), abi.encode(address(tokenOut))
        );
        metadata = JBMetadataResolver.addToMetadata(
            metadata, JBMetadataResolver.getId("quoteForSwap", address(router)), abi.encode(100 ether)
        );

        vm.prank(user);
        registry.addToBalanceOf(projectId, address(tokenIn), 1000 ether, false, "", metadata);

        assertEq(destTerminal.lastAmount(), 100 ether, "destination terminal should receive only the filled output");
        assertEq(tokenIn.balanceOf(address(registry)), 0, "registry should not retain leftover after fix");
        assertEq(tokenIn.balanceOf(address(router)), 0, "router should not retain the leftover");
        assertEq(tokenIn.balanceOf(user), 400 ether, "payer receives the leftover back via transient storage fix");
    }

    function test_registryAddToBalance_partialFillRefundsNativeToOriginalPayer() public {
        AuditMockERC20 tokenOut = new AuditMockERC20("Out", "OUT");
        AuditMockDestTerminal destTerminal = new AuditMockDestTerminal();
        address normalizedTokenIn = address(weth);
        AuditPartialFillPool pool = new AuditPartialFillPool(
            normalizedTokenIn < address(tokenOut) ? normalizedTokenIn : address(tokenOut),
            normalizedTokenIn < address(tokenOut) ? address(tokenOut) : normalizedTokenIn,
            tokenOut,
            tokenOut,
            600 ether,
            100 ether
        );

        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, address(tokenOut))),
            abi.encode(address(destTerminal))
        );
        vm.mockCall(
            address(factory),
            abi.encodeCall(IUniswapV3Factory.getPool, (normalizedTokenIn, address(tokenOut), uint24(3000))),
            abi.encode(address(pool))
        );
        vm.mockCall(
            address(factory),
            abi.encodeCall(IUniswapV3Factory.getPool, (normalizedTokenIn, address(tokenOut), uint24(500))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(factory),
            abi.encodeCall(IUniswapV3Factory.getPool, (normalizedTokenIn, address(tokenOut), uint24(10_000))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(factory),
            abi.encodeCall(IUniswapV3Factory.getPool, (normalizedTokenIn, address(tokenOut), uint24(100))),
            abi.encode(address(0))
        );

        bytes memory metadata = JBMetadataResolver.addToMetadata(
            "", JBMetadataResolver.getId("routeTokenOut", address(router)), abi.encode(address(tokenOut))
        );
        metadata = JBMetadataResolver.addToMetadata(
            metadata, JBMetadataResolver.getId("quoteForSwap", address(router)), abi.encode(100 ether)
        );

        vm.deal(user, 1000 ether);
        vm.prank(user);
        registry.addToBalanceOf{value: 1000 ether}(projectId, JBConstants.NATIVE_TOKEN, 1000 ether, false, "", metadata);

        assertEq(destTerminal.lastAmount(), 100 ether, "destination terminal should receive only the filled output");
        assertEq(address(registry).balance, 0, "registry should not retain leftover after fix");
        assertEq(address(router).balance, 0, "router should not retain raw ETH after refunding leftovers");
        assertEq(user.balance, 400 ether, "payer receives the native leftover back via transient storage fix");
    }
}
