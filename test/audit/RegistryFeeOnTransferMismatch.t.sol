// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";

contract RegistryFoTToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 internal immutable _FEE;

    constructor(uint256 fee) {
        _FEE = fee;
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
        uint256 received = amount > _FEE ? amount - _FEE : 0;
        balanceOf[to] += received;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        uint256 received = amount > _FEE ? amount - _FEE : 0;
        balanceOf[to] += received;
        return true;
    }
}

contract PullingTerminal {
    uint256 public lastAmount;

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
        lastAmount = amount;
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        RegistryFoTToken(token).transferFrom(msg.sender, address(this), amount);
        return amount;
    }
}

contract RegistryFeeOnTransferMismatchTest is Test {
    JBRouterTerminalRegistry internal registry;

    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IPermit2 internal permit2 = IPermit2(makeAddr("permit2"));

    RegistryFoTToken internal token;
    PullingTerminal internal terminal;

    address internal owner = makeAddr("owner");
    address internal payer = makeAddr("payer");

    function setUp() public {
        registry = new JBRouterTerminalRegistry(permissions, projects, permit2, owner, address(0));
        token = new RegistryFoTToken(10);
        terminal = new PullingTerminal();

        vm.prank(owner);
        registry.setDefaultTerminal(IJBTerminal(address(terminal)));

        token.mint(payer, 100);
        vm.prank(payer);
        token.approve(address(registry), type(uint256).max);
    }

    function test_registryPay_revertsForNonStandardTerminalToken() public {
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalRegistry.JBRouterTerminalRegistry_NonStandardTerminalToken.selector,
                address(token),
                IJBTerminal(address(terminal)),
                80,
                90
            )
        );
        registry.pay(1, address(token), 100, payer, 0, "", "");
    }
}
