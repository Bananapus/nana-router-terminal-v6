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
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

contract NoV3Factory {
    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

contract CircularCashOutToken {
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

contract CircularCashOutTerminal {
    CircularCashOutToken public immutable TOKEN_TO_BURN;
    address public immutable RECLAIM_TOKEN;
    uint256 public immutable RECLAIM_AMOUNT;

    constructor(CircularCashOutToken tokenToBurn_, address reclaimToken_, uint256 reclaimAmount_) {
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
        require(tokenToReclaim == RECLAIM_TOKEN, "wrong reclaim token");
        TOKEN_TO_BURN.burn(holder, cashOutCount);
        require(CircularCashOutToken(tokenToReclaim).transfer(beneficiary, RECLAIM_AMOUNT), "transfer failed");
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
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: RECLAIM_TOKEN, decimals: 18, currency: uint32(uint160(RECLAIM_TOKEN))});
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBCashOutTerminal).interfaceId || interfaceId == type(IJBTerminal).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

contract CircularPreviewTerminal {
    address public immutable ACCEPTED_TOKEN;
    uint256 public totalReceived;

    constructor(address acceptedToken_) {
        ACCEPTED_TOKEN = acceptedToken_;
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
        returns (uint256)
    {
        require(CircularCashOutToken(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        totalReceived += amount;
        return amount;
    }

    function addToBalanceOf(uint256, address token, uint256 amount, bool, string calldata, bytes calldata) external {
        require(CircularCashOutToken(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        totalReceived += amount;
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

    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: ACCEPTED_TOKEN, decimals: 18, currency: uint32(uint160(ACCEPTED_TOKEN))});
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

contract CashOutCircularPrimaryTerminalTest is Test {
    uint256 internal constant DEST_PROJECT_ID = 1;
    uint256 internal constant SOURCE_PROJECT_ID = 2;
    uint256 internal constant AMOUNT = 100e18;

    JBRouterTerminal internal router;
    IJBDirectory internal directory;
    IJBTokens internal tokens;

    CircularCashOutToken internal sourceToken;
    CircularCashOutToken internal circularReclaimToken;
    CircularCashOutToken internal goodReclaimToken;
    CircularCashOutTerminal internal circularCashOutTerminal;
    CircularCashOutTerminal internal goodCashOutTerminal;
    CircularPreviewTerminal internal goodTerminal;

    address internal payer = makeAddr("payer");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        tokens = IJBTokens(makeAddr("tokens"));

        vm.etch(address(directory), hex"00");
        vm.etch(address(tokens), hex"00");
        vm.etch(address(makeAddr("permit2")), hex"00");
        vm.etch(address(makeAddr("weth")), hex"00");

        IPermit2 permit2 = IPermit2(makeAddr("permit2"));
        IWETH9 weth = IWETH9(makeAddr("weth"));
        IUniswapV3Factory factory = IUniswapV3Factory(address(new NoV3Factory()));

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

        sourceToken = new CircularCashOutToken();
        circularReclaimToken = new CircularCashOutToken();
        goodReclaimToken = new CircularCashOutToken();

        circularCashOutTerminal = new CircularCashOutTerminal(sourceToken, address(circularReclaimToken), AMOUNT / 2);
        goodCashOutTerminal = new CircularCashOutTerminal(sourceToken, address(goodReclaimToken), AMOUNT / 2);
        goodTerminal = new CircularPreviewTerminal(address(goodReclaimToken));

        sourceToken.mint(payer, AMOUNT);
        circularReclaimToken.mint(address(circularCashOutTerminal), AMOUNT / 2);
        goodReclaimToken.mint(address(goodCashOutTerminal), AMOUNT / 2);

        vm.prank(payer);
        sourceToken.approve(address(router), AMOUNT);

        vm.mockCall(
            address(tokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(sourceToken)))),
            abi.encode(SOURCE_PROJECT_ID)
        );
        vm.mockCall(
            address(tokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(circularReclaimToken)))),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            address(tokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(goodReclaimToken)))),
            abi.encode(uint256(0))
        );

        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(sourceToken))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(circularReclaimToken))),
            abi.encode(address(router))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(goodReclaimToken))),
            abi.encode(address(goodTerminal))
        );

        IJBTerminal[] memory sourceTerminals = new IJBTerminal[](2);
        sourceTerminals[0] = IJBTerminal(address(circularCashOutTerminal));
        sourceTerminals[1] = IJBTerminal(address(goodCashOutTerminal));
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.terminalsOf, (SOURCE_PROJECT_ID)),
            abi.encode(sourceTerminals)
        );

        IJBTerminal[] memory destTerminals = new IJBTerminal[](2);
        destTerminals[0] = IJBTerminal(address(router));
        destTerminals[1] = IJBTerminal(address(goodTerminal));
        vm.mockCall(
            address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (DEST_PROJECT_ID)), abi.encode(destTerminals)
        );
    }

    function test_addToBalance_skipsCircularPrimaryTerminalAndUsesUsableCashOutPath() public {
        vm.prank(payer);
        router.addToBalanceOf(DEST_PROJECT_ID, address(sourceToken), AMOUNT, false, "", "");

        assertEq(goodTerminal.totalReceived(), AMOUNT / 2, "good terminal should receive the usable cash-out proceeds");
    }

    function test_addToBalance_succeedsWhenCircularPrimaryTerminalIsRemoved() public {
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(circularReclaimToken))),
            abi.encode(address(0))
        );

        vm.prank(payer);
        router.addToBalanceOf(DEST_PROJECT_ID, address(sourceToken), AMOUNT, false, "", "");

        assertEq(goodTerminal.totalReceived(), AMOUNT / 2, "good terminal should receive the cash-out proceeds");
    }
}
