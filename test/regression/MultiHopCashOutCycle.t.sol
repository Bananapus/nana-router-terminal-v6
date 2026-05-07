// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IJBForwardingTerminal} from "../../src/interfaces/IJBForwardingTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

contract MockCycleToken {
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

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }
}

contract MockNoV3Factory {
    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

contract MockForwarderA is IJBForwardingTerminal {
    IJBTerminal internal immutable _next;

    constructor(IJBTerminal next_) {
        _next = next_;
    }

    function terminalOf(uint256) external view returns (IJBTerminal) {
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

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}
}

contract MockForwarderB is IJBForwardingTerminal {
    error CycleReached();

    IJBTerminal internal immutable _router;

    constructor(IJBTerminal router_) {
        _router = router_;
    }

    function terminalOf(uint256) external view returns (IJBTerminal) {
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

contract MockCashOutTerminal {
    MockCycleToken public immutable TOKEN_TO_BURN;
    MockCycleToken public immutable RECLAIM_TOKEN;
    uint256 public immutable RECLAIM_AMOUNT;

    constructor(MockCycleToken tokenToBurn_, MockCycleToken reclaimToken_, uint256 reclaimAmount_) {
        TOKEN_TO_BURN = tokenToBurn_;
        RECLAIM_TOKEN = reclaimToken_;
        RECLAIM_AMOUNT = reclaimAmount_;
    }

    function cashOutTokensOf(
        address holder,
        uint256,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256,
        address payable beneficiary,
        bytes calldata
    )
        external
        returns (uint256)
    {
        require(tokenToReclaim == address(RECLAIM_TOKEN), "wrong reclaim token");
        TOKEN_TO_BURN.burn(holder, cashOutCount);
        require(RECLAIM_TOKEN.transfer(beneficiary, RECLAIM_AMOUNT), "transfer failed");
        return RECLAIM_AMOUNT;
    }

    function previewCashOutFrom(
        address,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata
    )
        external
        view
        returns (JBRuleset memory ruleset, uint256, uint256, JBCashOutHookSpecification[] memory hookSpecifications)
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
        hookSpecifications = new JBCashOutHookSpecification[](0);
        return (ruleset, RECLAIM_AMOUNT, 0, hookSpecifications);
    }

    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: address(RECLAIM_TOKEN), decimals: 18, currency: uint32(uint160(address(RECLAIM_TOKEN)))
        });
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBCashOutTerminal).interfaceId || interfaceId == type(IJBTerminal).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

contract MockDestinationTerminal {
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
        require(MockCycleToken(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
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
            id: 2,
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

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

contract MultiHopCashOutCycleTest is Test {
    uint256 internal constant DEST_PROJECT_ID = 1;
    uint256 internal constant SOURCE_PROJECT_ID = 2;
    uint256 internal constant AMOUNT = 100e18;

    JBRouterTerminal internal router;
    IJBDirectory internal directory;
    IJBTokens internal tokens;

    MockCycleToken internal sourceToken;
    MockCycleToken internal reclaimToken;
    MockCashOutTerminal internal cashOutTerminal;
    MockDestinationTerminal internal destinationTerminal;
    MockForwarderA internal forwarderA;
    MockForwarderB internal forwarderB;

    address internal payer = makeAddr("payer");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        tokens = IJBTokens(makeAddr("tokens"));
        vm.etch(address(directory), hex"00");
        vm.etch(address(tokens), hex"00");
        vm.etch(address(makeAddr("permit2")), hex"00");
        vm.etch(address(makeAddr("weth")), hex"00");

        router = new JBRouterTerminal({
            directory: directory,
            tokens: tokens,
            permit2: IPermit2(makeAddr("permit2")),
            weth: IWETH9(makeAddr("weth")),
            factory: IUniswapV3Factory(address(new MockNoV3Factory())),
            poolManager: IPoolManager(address(0)),
            buybackHook: address(0),
            univ4Hook: address(0),
            trustedForwarder: address(0)
        });

        sourceToken = new MockCycleToken();
        reclaimToken = new MockCycleToken();
        cashOutTerminal = new MockCashOutTerminal(sourceToken, reclaimToken, AMOUNT / 2);
        destinationTerminal = new MockDestinationTerminal();
        forwarderB = new MockForwarderB(IJBTerminal(address(router)));
        forwarderA = new MockForwarderA(IJBTerminal(address(forwarderB)));

        sourceToken.mint(payer, AMOUNT);
        reclaimToken.mint(address(cashOutTerminal), AMOUNT / 2);

        vm.prank(payer);
        sourceToken.approve(address(router), AMOUNT);

        vm.mockCall(
            address(tokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(sourceToken)))),
            abi.encode(SOURCE_PROJECT_ID)
        );
        vm.mockCall(
            address(tokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(reclaimToken)))),
            abi.encode(uint256(0))
        );

        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(sourceToken))),
            abi.encode(address(forwarderA))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(reclaimToken))),
            abi.encode(address(destinationTerminal))
        );

        IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
        sourceTerminals[0] = IJBTerminal(address(cashOutTerminal));
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.terminalsOf, (SOURCE_PROJECT_ID)),
            abi.encode(sourceTerminals)
        );

        IJBTerminal[] memory destTerminals = new IJBTerminal[](1);
        destTerminals[0] = IJBTerminal(address(forwarderA));
        vm.mockCall(
            address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (DEST_PROJECT_ID)), abi.encode(destTerminals)
        );
    }

    function test_projectTokenPayRevertsOnMultiHopCircularTerminalBeforeTryingUsableCashOutPath() public {
        // The router now previews all candidate routes and selects the best one. When the circular
        // forwarding terminal is detected, the router falls back to the cash-out path which
        // successfully converts sourceToken -> reclaimToken -> destinationTerminal.
        vm.prank(payer);
        uint256 result = router.pay(DEST_PROJECT_ID, address(sourceToken), AMOUNT, beneficiary, 0, "", "");

        assertGt(result, 0, "cash-out route should succeed");
        assertEq(destinationTerminal.totalReceived(), AMOUNT / 2, "destination should receive the reclaimed tokens");
    }
}
