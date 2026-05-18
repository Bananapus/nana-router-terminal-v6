// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IJBForwardingTerminal} from "../../src/interfaces/IJBForwardingTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

contract CycleMockWETH is IWETH9 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

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
}

contract ForwarderA is IJBForwardingTerminal {
    IJBTerminal internal immutable _next;

    constructor(IJBTerminal next_) {
        _next = next_;
    }

    function terminalOf(uint256) external view override returns (IJBTerminal terminal) {
        return _next;
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        returns (uint256)
    {
        return _next.pay{value: msg.value}(projectId, token, amount, beneficiary, minReturnedTokens, memo, metadata);
    }

    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool shouldReturnHeldFees,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
    {
        _next.addToBalanceOf{value: msg.value}(projectId, token, amount, shouldReturnHeldFees, memo, metadata);
    }
}

contract ForwarderB is IJBForwardingTerminal {
    error CycleReached();

    IJBTerminal internal immutable _router;

    constructor(IJBTerminal router_) {
        _router = router_;
    }

    function terminalOf(uint256) external view override returns (IJBTerminal terminal) {
        return _router;
    }

    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        revert CycleReached();
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {
        revert CycleReached();
    }
}

contract MultiHopForwardCycleTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant AMOUNT = 1 ether;

    JBRouterTerminal internal router;
    IJBDirectory internal directory;
    IJBTokens internal tokens;
    CycleMockWETH internal weth;
    ForwarderA internal forwarderA;
    ForwarderB internal forwarderB;

    address internal payer = makeAddr("payer");

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        tokens = IJBTokens(makeAddr("tokens"));
        weth = new CycleMockWETH();

        vm.etch(address(directory), hex"00");
        vm.etch(address(tokens), hex"00");
        vm.etch(address(makeAddr("permit2")), hex"00");
        vm.etch(address(makeAddr("factory")), hex"00");

        router = new JBRouterTerminal({
            directory: directory,
            tokens: tokens,
            permit2: IPermit2(makeAddr("permit2")),
            buybackHook: address(0),
            trustedForwarder: address(0),
            deployer: address(this)
        });
        router.setChainSpecificConstants({
            newWrappedNativeToken: weth,
            newFactory: IUniswapV3Factory(makeAddr("factory")),
            newPoolManager: IPoolManager(address(0)),
            newUniv4Hook: address(0)
        });

        forwarderB = new ForwarderB(IJBTerminal(address(router)));
        forwarderA = new ForwarderA(IJBTerminal(address(forwarderB)));

        vm.mockCall(
            address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(new IJBTerminal[](0))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(forwarderA))
        );
    }

    /// @notice With 5-hop bounded loop detection, a 2-hop cycle (ForwarderA -> ForwarderB -> router) IS detected
    /// and rejected during route resolution, preventing funds from ever reaching ForwarderB.
    function test_routerRejectsTwoHopForwardCycle() public {
        vm.deal(payer, AMOUNT);

        vm.prank(payer);
        vm.expectRevert();
        router.pay{value: AMOUNT}(PROJECT_ID, JBConstants.NATIVE_TOKEN, AMOUNT, payer, 0, "", "");
    }
}
