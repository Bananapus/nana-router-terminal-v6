// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";
import {MockERC20} from "../RouterTerminal.t.sol";

contract PartialFillLikeCashOutTerminal {
    MockERC20 public immutable SOURCE_TOKEN;
    MockERC20 public immutable RECLAIM_TOKEN;
    uint256 public immutable UNSOLD_SOURCE_TOKEN_COUNT;
    uint256 public immutable RECLAIMED_TOKEN_COUNT;

    constructor(
        MockERC20 sourceToken_,
        MockERC20 reclaimToken_,
        uint256 unsoldSourceTokenCount_,
        uint256 reclaimedTokenCount_
    ) {
        SOURCE_TOKEN = sourceToken_;
        RECLAIM_TOKEN = reclaimToken_;
        UNSOLD_SOURCE_TOKEN_COUNT = unsoldSourceTokenCount_;
        RECLAIMED_TOKEN_COUNT = reclaimedTokenCount_;
    }

    function cashOutTokensOf(
        address holder,
        uint256,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256,
        address payable beneficiary,
        bytes calldata,
        uint256
    )
        external
        returns (uint256)
    {
        require(tokenToReclaim == address(RECLAIM_TOKEN), "PartialFillLikeCashOutTerminal: wrong reclaim token");

        SOURCE_TOKEN.burn(holder, cashOutCount);
        SOURCE_TOKEN.mint(holder, UNSOLD_SOURCE_TOKEN_COUNT);
        RECLAIM_TOKEN.mint(beneficiary, RECLAIMED_TOKEN_COUNT);

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
        // forge-lint: disable-next-line(unsafe-typecast)
        contexts[0] = JBAccountingContext({
            token: address(RECLAIM_TOKEN), decimals: 18, currency: uint32(uint160(address(RECLAIM_TOKEN)))
        });
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBCashOutTerminal).interfaceId || interfaceId == type(IJBTerminal).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

contract PullingDestinationTerminal {
    MockERC20 public immutable ACCEPTED_TOKEN;
    uint256 public totalReceived;

    constructor(MockERC20 acceptedToken_) {
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
        payable
        returns (uint256)
    {
        require(token == address(ACCEPTED_TOKEN), "PullingDestinationTerminal: wrong token");
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(token).transferFrom(msg.sender, address(this), amount);

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

contract BuybackPartialFillStrandsSourceTokensTest is Test {
    uint256 internal constant DEST_PROJECT_ID = 1;
    uint256 internal constant SOURCE_PROJECT_ID = 2;
    uint256 internal constant CASH_OUT_COUNT = 100e18;
    uint256 internal constant UNSOLD_SOURCE_TOKEN_COUNT = 40e18;
    uint256 internal constant RECLAIMED_TOKEN_COUNT = 60e18;

    JBRouterTerminal internal router;
    IJBDirectory internal directory;
    IJBTokens internal tokens;

    MockERC20 internal sourceToken;
    MockERC20 internal reclaimToken;
    PartialFillLikeCashOutTerminal internal sourceTerminal;
    PullingDestinationTerminal internal destTerminal;

    address internal payer = makeAddr("payer");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        tokens = IJBTokens(makeAddr("tokens"));

        vm.etch(address(directory), hex"00");
        vm.etch(address(tokens), hex"00");
        vm.mockCall(address(tokens), abi.encodeWithSelector(IJBTokens.creditBalanceOf.selector), abi.encode(0));
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
            newWrappedNativeToken: IWETH9(makeAddr("weth")),
            newFactory: IUniswapV3Factory(makeAddr("factory")),
            newPoolManager: IPoolManager(address(0)),
            newUniv4Hook: address(0)
        });

        sourceToken = new MockERC20();
        reclaimToken = new MockERC20();
        sourceTerminal = new PartialFillLikeCashOutTerminal({
            sourceToken_: sourceToken,
            reclaimToken_: reclaimToken,
            unsoldSourceTokenCount_: UNSOLD_SOURCE_TOKEN_COUNT,
            reclaimedTokenCount_: RECLAIMED_TOKEN_COUNT
        });
        destTerminal = new PullingDestinationTerminal(reclaimToken);

        sourceToken.mint(payer, CASH_OUT_COUNT);
        vm.prank(payer);
        sourceToken.approve(address(router), CASH_OUT_COUNT);

        vm.mockCall(
            address(tokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(sourceToken)))),
            abi.encode(SOURCE_PROJECT_ID)
        );
        vm.mockCall(
            address(tokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(reclaimToken)))), abi.encode(0)
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
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(reclaimToken))),
            abi.encode(address(destTerminal))
        );
    }

    // Regression for the partial-buyback-fill residue fix: the source cash-out hop now refunds the unsold source
    // project tokens to the original payer (the route's refund recipient) instead of stranding them on the router.
    function test_partialFillDuringSourceCashOutRefundsUnsoldProjectTokensToPayer() public {
        vm.prank(payer);
        router.pay(DEST_PROJECT_ID, address(sourceToken), CASH_OUT_COUNT, beneficiary, 0, "", "");

        assertEq(destTerminal.totalReceived(), RECLAIMED_TOKEN_COUNT, "partial proceeds are forwarded downstream");
        assertEq(reclaimToken.balanceOf(address(router)), 0, "router does not retain the reclaimed route token");
        // The fix: the router no longer strands the unsold source project tokens.
        assertEq(sourceToken.balanceOf(address(router)), 0, "router does not strand the unsold source project tokens");
        // They are refunded to the original payer (refundTo resolves to the EOA payer here).
        assertEq(
            sourceToken.balanceOf(payer), UNSOLD_SOURCE_TOKEN_COUNT, "payer receives the unsold project tokens back"
        );
        assertEq(sourceToken.balanceOf(beneficiary), 0, "beneficiary does not receive the unsold project tokens");
    }
}
