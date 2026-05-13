// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";
import {MockERC20} from "../RouterTerminal.t.sol";

contract SellFallbackLikeCashOutTerminal {
    MockERC20 public immutable SOURCE_TOKEN;
    address public immutable RECLAIM_TOKEN;

    constructor(MockERC20 sourceToken_, address reclaimToken_) {
        SOURCE_TOKEN = sourceToken_;
        RECLAIM_TOKEN = reclaimToken_;
    }

    function cashOutTokensOf(
        address holder,
        uint256,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256,
        address payable,
        bytes calldata
    )
        external
        returns (uint256)
    {
        require(tokenToReclaim == RECLAIM_TOKEN, "SellFallbackLikeCashOutTerminal: wrong reclaim token");

        // Mimic the buyback hook's sell-side fallback shape:
        // the terminal burns the source project tokens, the hook remints them back to the holder,
        // and no reclaim token is delivered.
        SOURCE_TOKEN.burn(holder, cashOutCount);
        SOURCE_TOKEN.mint(holder, cashOutCount);
        return 0;
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
        pure
        returns (JBRuleset memory ruleset, uint256, uint256, JBCashOutHookSpecification[] memory hookSpecifications)
    {
        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 777,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        hookSpecifications = new JBCashOutHookSpecification[](0);
        return (ruleset, 0, 0, hookSpecifications);
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

contract ZeroValueDestinationTerminal {
    uint256 public lastAmount;

    function pay(
        uint256,
        address,
        uint256 amount,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
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
        returns (JBRuleset memory ruleset, uint256, uint256, JBPayHookSpecification[] memory hookSpecifications)
    {
        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 888,
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

contract BuybackSellFallbackStrandsSourceTokensTest is Test {
    uint256 internal constant DEST_PROJECT_ID = 1;
    uint256 internal constant SOURCE_PROJECT_ID = 2;
    uint256 internal constant AMOUNT = 100e18;

    JBRouterTerminal internal router;
    IJBDirectory internal directory;
    IJBTokens internal tokens;

    MockERC20 internal sourceToken;
    SellFallbackLikeCashOutTerminal internal sourceTerminal;
    ZeroValueDestinationTerminal internal destTerminal;

    address internal payer = makeAddr("payer");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        tokens = IJBTokens(makeAddr("tokens"));

        vm.etch(address(directory), hex"00");
        vm.etch(address(tokens), hex"00");
        vm.etch(address(makeAddr("permit2")), hex"00");
        vm.etch(address(makeAddr("weth")), hex"00");
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
            wrappedNativeToken: IWETH9(makeAddr("weth")),
            factory: IUniswapV3Factory(makeAddr("factory")),
            poolManager: IPoolManager(address(0)),
            univ4Hook: address(0)
        });

        sourceToken = new MockERC20();
        sourceTerminal = new SellFallbackLikeCashOutTerminal(sourceToken, JBConstants.NATIVE_TOKEN);
        destTerminal = new ZeroValueDestinationTerminal();

        sourceToken.mint(payer, AMOUNT);
        vm.prank(payer);
        sourceToken.approve(address(router), AMOUNT);

        vm.mockCall(
            address(tokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(sourceToken)))),
            abi.encode(SOURCE_PROJECT_ID)
        );

        IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
        sourceTerminals[0] = IJBTerminal(address(sourceTerminal));
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.terminalsOf, (SOURCE_PROJECT_ID)),
            abi.encode(sourceTerminals)
        );

        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.terminalsOf, (DEST_PROJECT_ID)),
            abi.encode(new IJBTerminal[](0))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(sourceToken))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(destTerminal))
        );
    }

    function test_sellFallbackDuringSourceCashOutRevertsInsteadOfStrandingProjectTokens() public {
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminal.JBRouterTerminal_CashOutDidNotDeliver.selector,
                address(sourceToken),
                JBConstants.NATIVE_TOKEN,
                AMOUNT
            )
        );
        router.pay(DEST_PROJECT_ID, address(sourceToken), AMOUNT, beneficiary, 0, "", "");

        assertEq(destTerminal.lastAmount(), 0, "router forwards a zero-value payment downstream");
        assertEq(sourceToken.balanceOf(address(router)), 0, "source project tokens should not remain on the router");
        assertEq(sourceToken.balanceOf(payer), AMOUNT, "payer should keep the original source tokens");
        assertEq(sourceToken.balanceOf(beneficiary), 0, "beneficiary does not receive the reminted source tokens");
    }
}
