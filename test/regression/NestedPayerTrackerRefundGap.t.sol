// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";
import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";

contract NestedRefundToken is ERC20 {
    constructor() ERC20("Nested Refund Token", "NRT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NestedRefundingTerminal is IJBTerminal {
    using SafeERC20 for IERC20;

    address public lastRefundTo;

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
        _pullAndRefundHalf({token: token, amount: amount});
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
        contexts = new JBAccountingContext[](0);
    }

    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

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
        _pullAndRefundHalf({token: token, amount: amount});
        return 0;
    }

    function previewPayFor(
        uint256,
        address,
        uint256,
        address,
        bytes calldata
    )
        external
        pure
        override
        returns (JBRuleset memory ruleset, uint256, uint256, JBPayHookSpecification[] memory hookSpecifications)
    {
        hookSpecifications = new JBPayHookSpecification[](0);
        ruleset = JBRuleset({
            cycleNumber: 0,
            id: 0,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        return (ruleset, 0, 0, hookSpecifications);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function _pullAndRefundHalf(address token, uint256 amount) internal {
        if (token == JBConstants.NATIVE_TOKEN) {
            address nativeRefundTo = _refundTo();
            lastRefundTo = nativeRefundTo;

            (bool success,) = payable(nativeRefundTo).call{value: amount / 2}("");
            require(success, "NATIVE_REFUND_FAILED");
            return;
        }

        IERC20(token).safeTransferFrom({from: msg.sender, to: address(this), value: amount});

        address refundTo = _refundTo();
        lastRefundTo = refundTo;
        IERC20(token).safeTransfer({to: refundTo, value: amount / 2});
    }

    function _refundTo() internal view returns (address refundTo) {
        refundTo = msg.sender;
        if (msg.sender.code.length > 0) {
            try IJBPayerTracker(msg.sender).originalPayer() returns (address payer) {
                if (payer != address(0)) refundTo = payer;
            } catch {}
        }
    }
}

contract NestedForwarder is IJBPayerTracker {
    using SafeERC20 for IERC20;

    address public transient override originalPayer;

    receive() external payable {}

    function forwardPay(
        JBRouterTerminalRegistry registry,
        uint256 projectId,
        IERC20 token,
        uint256 amount,
        address beneficiary
    )
        external
    {
        token.safeTransferFrom({from: msg.sender, to: address(this), value: amount});
        token.forceApprove({spender: address(registry), value: amount});

        address previousPayer = originalPayer;
        originalPayer = msg.sender;

        registry.pay({
            projectId: projectId,
            token: address(token),
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        originalPayer = previousPayer;
    }

    function forwardNativePay(
        JBRouterTerminalRegistry registry,
        uint256 projectId,
        address beneficiary
    )
        external
        payable
    {
        address previousPayer = originalPayer;
        originalPayer = msg.sender;

        registry.pay{value: msg.value}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 0,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        originalPayer = previousPayer;
    }
}

    contract NestedPayerTrackerRefundGapTest is Test {
        uint256 internal constant PROJECT_ID = 1;

        address internal owner = makeAddr("owner");
        address internal user = makeAddr("user");

        JBRouterTerminalRegistry internal registry;
        NestedRefundingTerminal internal terminal;
        NestedForwarder internal forwarder;
        NestedRefundToken internal token;

        function setUp() public {
            IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
            IJBProjects projects = IJBProjects(makeAddr("projects"));
            IPermit2 permit2 = IPermit2(makeAddr("permit2"));

            vm.etch(address(permissions), hex"00");
            vm.etch(address(projects), hex"00");
            vm.etch(address(permit2), hex"00");
            vm.mockCall(address(projects), abi.encodeCall(IJBProjects.count, ()), abi.encode(uint256(0)));

            registry = new JBRouterTerminalRegistry({
                permissions: permissions,
                projects: projects,
                permit2: permit2,
                owner: owner,
                trustedForwarder: address(0)
            });

            terminal = new NestedRefundingTerminal();
            forwarder = new NestedForwarder();
            token = new NestedRefundToken();

            vm.prank(owner);
            registry.setDefaultTerminal(IJBTerminal(address(terminal)));
        }

        function test_nestedForwarderRefundPropagatesToUpstreamPayer() public {
            uint256 amount = 100 ether;
            token.mint(user, amount);

            vm.startPrank(user);
            token.approve(address(forwarder), amount);
            forwarder.forwardPay({
                registry: registry, projectId: PROJECT_ID, token: token, amount: amount, beneficiary: user
            });
            vm.stopPrank();

            // The registry reads the forwarder's IJBPayerTracker.originalPayer() and stores
            // the upstream user, so the downstream terminal refunds the true originator.
            assertEq(terminal.lastRefundTo(), user, "registry propagates upstream payer for refund");
            assertEq(token.balanceOf(user), amount / 2, "true upstream payer receives leftover refund");
            assertEq(token.balanceOf(address(forwarder)), 0, "no leftover stranded on intermediary");
        }

        function test_nestedForwarderNativeRefundPropagatesToUpstreamPayer() public {
            uint256 amount = 1 ether;
            vm.deal(user, amount);

            vm.prank(user);
            forwarder.forwardNativePay{value: amount}({registry: registry, projectId: PROJECT_ID, beneficiary: user});

            assertEq(terminal.lastRefundTo(), user, "registry propagates upstream payer for native refund");
            assertEq(user.balance, amount / 2, "true upstream payer receives native leftover");
            assertEq(address(forwarder).balance, 0, "no native leftover stranded on intermediary");
        }
    }
