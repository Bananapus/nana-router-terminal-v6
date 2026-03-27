// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";
import {IJBPayerTracker} from "../../src/interfaces/IJBPayerTracker.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract RefundToBeneficiaryTest is Test {
    uint256 internal constant LEFTOVER = 40 ether;

    HarnessRouterTerminal internal router;
    MockERC20 internal token;

    address internal payer = makeAddr("payer");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        token = new MockERC20("Input", "IN");
        router = new HarnessRouterTerminal();

        token.mint(address(router), LEFTOVER);
    }

    function test_directCallerRefundsToBeneficiary() public {
        vm.prank(payer);
        router.simulatePayLeftoverRefund(address(token), beneficiary, LEFTOVER);

        assertEq(token.balanceOf(beneficiary), LEFTOVER, "beneficiary receives leftover");
        assertEq(token.balanceOf(payer), 0, "payer receives nothing");
    }

    function test_registryStyleCallerRefundsToOriginalPayer() public {
        MockPayerTracker intermediary = new MockPayerTracker(payer);

        vm.prank(address(intermediary));
        router.simulatePayLeftoverRefund(address(token), beneficiary, LEFTOVER);

        assertEq(token.balanceOf(payer), LEFTOVER, "intermediary path refunds payer");
        assertEq(token.balanceOf(beneficiary), 0, "beneficiary receives nothing");
    }
}

contract HarnessRouterTerminal is JBRouterTerminal {
    constructor()
        JBRouterTerminal(
            IJBDirectory(address(0)),
            IJBPermissions(address(0)),
            IJBProjects(address(0)),
            IJBTokens(address(0)),
            IPermit2(address(0)),
            address(this),
            IWETH9(address(new MockWETH())),
            IUniswapV3Factory(address(0)),
            IPoolManager(address(0)),
            address(0)
        )
    {}

    function simulatePayLeftoverRefund(address token, address beneficiary, uint256 leftover) external {
        address payable refundTo = _resolveRefundWithBackupRecipient(payable(beneficiary));
        _transferFrom({from: address(this), to: refundTo, token: token, amount: leftover});
    }
}

contract MockPayerTracker is IJBPayerTracker {
    address public override originalPayer;

    constructor(address payer) {
        originalPayer = payer;
    }
}

    contract MockERC20 is ERC20 {
        constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

        function mint(address account, uint256 amount) external {
            _mint(account, amount);
        }
    }

    contract MockWETH is MockERC20, IWETH9 {
        constructor() MockERC20("Wrapped ETH", "WETH") {}

        function deposit() external payable {
            _mint(msg.sender, msg.value);
        }

        function withdraw(uint256 wad) external {
            _burn(msg.sender, wad);
            payable(msg.sender).transfer(wad);
        }
    }
