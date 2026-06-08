// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {RouterTerminalTest, MockConfigurableCashOutTerminal, MockERC20} from "../RouterTerminal.t.sol";

contract ConservativeBuybackPreviewTerminal {
    address public immutable ACCEPTED_TOKEN;
    address public immutable BUYBACK_HOOK;
    uint256 public immutable MINIMUM_BENEFICIARY_TOKEN_COUNT;
    uint256 public immutable RAW_SWAP_QUOTE;
    uint256 public totalReceived;

    constructor(
        address acceptedToken_,
        address buybackHook_,
        uint256 minimumBeneficiaryTokenCount_,
        uint256 rawSwapQuote_
    ) {
        ACCEPTED_TOKEN = acceptedToken_;
        BUYBACK_HOOK = buybackHook_;
        MINIMUM_BENEFICIARY_TOKEN_COUNT = minimumBeneficiaryTokenCount_;
        RAW_SWAP_QUOTE = rawSwapQuote_;
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
        if (token == JBConstants.NATIVE_TOKEN) {
            require(msg.value == amount, "ConservativeBuybackPreviewTerminal: ETH mismatch");
        } else {
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        }

        totalReceived += amount;
        return RAW_SWAP_QUOTE;
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}

    function previewPayFor(
        uint256,
        address,
        uint256,
        address,
        bytes calldata
    )
        external
        view
        returns (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        )
    {
        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 444,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        beneficiaryTokenCount = 0;
        reservedTokenCount = 0;
        hookSpecifications = new JBPayHookSpecification[](1);
        hookSpecifications[0] = JBPayHookSpecification({
            hook: IJBPayHook(BUYBACK_HOOK),
            noop: false,
            amount: 0,
            metadata: abi.encode(
                false,
                uint256(0),
                uint256(0),
                false,
                address(0),
                uint256(0),
                uint256(0),
                uint256(0),
                int24(0),
                uint128(0),
                PoolId.wrap(bytes32(0)),
                MINIMUM_BENEFICIARY_TOKEN_COUNT,
                uint256(0),
                RAW_SWAP_QUOTE
            )
        });
    }

    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: ACCEPTED_TOKEN, decimals: 18, currency: uint32(uint160(ACCEPTED_TOKEN))});
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    receive() external payable {}
}

/// @title ConservativeBuybackPreviewRouteMisrankTest
/// @notice The router scores buyback-hooked buy routes by the live raw quote surfaced in canonical buyback metadata
///         instead of underranking them by their conservative minimum.
contract ConservativeBuybackPreviewRouteMisrankTest is RouterTerminalTest {
    function test_rawBuybackQuoteCanRankBetterBuybackBuyRoute() public {
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;
        uint256 amount = 100;
        address payer = makeAddr("payer");
        address beneficiary = makeAddr("beneficiary");

        MockERC20 jbToken = new MockERC20();
        MockERC20 tokenB = new MockERC20();

        ProportionalPreviewTerminal nativeTerminal = new ProportionalPreviewTerminal(JBConstants.NATIVE_TOKEN);
        ConservativeBuybackPreviewTerminal tokenBTerminal =
            new ConservativeBuybackPreviewTerminal(address(tokenB), buybackHook, 50, 100);

        MockConfigurableCashOutTerminal nativeCashOut =
            new MockConfigurableCashOutTerminal{value: 60}(jbToken, JBConstants.NATIVE_TOKEN, 60, 60, 60);
        MockConfigurableCashOutTerminal tokenBCashOut =
            new MockConfigurableCashOutTerminal(jbToken, address(tokenB), 50, 50, 50);

        tokenB.mint(address(tokenBCashOut), 100);
        jbToken.mint(payer, amount * 2);

        vm.etch(buybackHook, hex"00");
        vm.mockCall(
            address(mockTokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(jbToken)))),
            abi.encode(sourceProjectId)
        );
        vm.mockCall(
            address(mockTokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(tokenB)))),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, address(jbToken))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(nativeTerminal))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, address(tokenB))),
            abi.encode(address(tokenBTerminal))
        );

        IJBTerminal[] memory sourceTerminals = new IJBTerminal[](2);
        sourceTerminals[0] = IJBTerminal(address(nativeCashOut));
        sourceTerminals[1] = IJBTerminal(address(tokenBCashOut));
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
            abi.encode(sourceTerminals)
        );

        IJBTerminal[] memory destTerminals = new IJBTerminal[](2);
        destTerminals[0] = IJBTerminal(address(nativeTerminal));
        destTerminals[1] = IJBTerminal(address(tokenBTerminal));
        vm.mockCall(
            address(mockDirectory), abi.encodeCall(IJBDirectory.terminalsOf, (destProjectId)), abi.encode(destTerminals)
        );

        vm.startPrank(payer);
        jbToken.approve(address(routerTerminal), type(uint256).max);

        (, uint256 previewTokenCount,,) =
            routerTerminal.previewPayFor(destProjectId, address(jbToken), amount, beneficiary, "");
        uint256 chosenRouteMinted =
            routerTerminal.pay(destProjectId, address(jbToken), amount, beneficiary, 0, "chosen", "");

        bytes4 routeId = JBMetadataResolver.getId("routeTokenOut", address(routerTerminal));
        bytes memory forceTokenBMetadata = JBMetadataResolver.addToMetadata("", routeId, abi.encode(address(tokenB)));
        uint256 forcedTokenBMinted =
            routerTerminal.pay(destProjectId, address(jbToken), amount, beneficiary, 0, "forced", forceTokenBMetadata);
        vm.stopPrank();

        assertEq(previewTokenCount, 100, "preview should prefer the higher live buyback route");
        assertEq(chosenRouteMinted, 100, "actual default route should settle through the better buyback candidate");
        assertEq(forcedTokenBMinted, 100, "forced tokenB route proves a better live buyback path existed");
        assertEq(nativeTerminal.totalReceived(), 0, "default route should not send native value");
        assertEq(
            tokenBTerminal.totalReceived(), 100, "both tokenB routes should deliver tokenB into the buyback terminal"
        );
    }
}

contract ProportionalPreviewTerminal {
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
        payable
        returns (uint256)
    {
        if (token == JBConstants.NATIVE_TOKEN) {
            require(msg.value == amount, "ProportionalPreviewTerminal: ETH mismatch");
        } else {
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        }

        totalReceived += amount;
        return amount;
    }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}

    function previewPayFor(
        uint256,
        address,
        uint256 amount,
        address,
        bytes calldata
    )
        external
        pure
        returns (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        )
    {
        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 88,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        beneficiaryTokenCount = amount;
        reservedTokenCount = 0;
        hookSpecifications = new JBPayHookSpecification[](0);
    }

    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: ACCEPTED_TOKEN, decimals: 18, currency: uint32(uint160(ACCEPTED_TOKEN))});
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    receive() external payable {}
}
