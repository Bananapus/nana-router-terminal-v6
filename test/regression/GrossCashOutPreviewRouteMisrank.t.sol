// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {RouterTerminalTest, MockConfigurableCashOutTerminal, MockERC20} from "../RouterTerminal.t.sol";

contract ProportionalRouteTerminal {
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
        if (token == JBConstants.NATIVE_TOKEN) require(msg.value == amount, "ProportionalRouteTerminal: ETH mismatch");
        else require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");

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
            id: 91,
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

contract FeeAwareCashOutTerminal {
    MockERC20 public immutable TOKEN;
    address public immutable RECLAIM_TOKEN;
    uint256 public immutable PREVIEW_RECLAIM_AMOUNT;
    uint256 public immutable EXECUTION_TRANSFER_AMOUNT;
    uint256 public immutable EXECUTION_RETURN_AMOUNT;

    constructor(
        MockERC20 token_,
        address reclaimToken_,
        uint256 previewReclaimAmount_,
        uint256 executionTransferAmount_,
        uint256 executionReturnAmount_
    )
        payable {
        TOKEN = token_;
        RECLAIM_TOKEN = reclaimToken_;
        PREVIEW_RECLAIM_AMOUNT = previewReclaimAmount_;
        EXECUTION_TRANSFER_AMOUNT = executionTransferAmount_;
        EXECUTION_RETURN_AMOUNT = executionReturnAmount_;
    }

    function cashOutTokensOf(
        address holder,
        uint256,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256,
        address payable beneficiary,
        bytes calldata,
        uint256 /* referralProjectId */
    )
        external
        returns (uint256)
    {
        require(tokenToReclaim == RECLAIM_TOKEN, "FeeAwareCashOutTerminal: wrong reclaim token");
        TOKEN.burn(holder, cashOutCount);

        if (tokenToReclaim == JBConstants.NATIVE_TOKEN) {
            (bool success,) = beneficiary.call{value: EXECUTION_TRANSFER_AMOUNT}("");
            require(success, "FeeAwareCashOutTerminal: ETH send failed");
        } else {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(tokenToReclaim).transfer(beneficiary, EXECUTION_TRANSFER_AMOUNT);
        }

        return EXECUTION_RETURN_AMOUNT;
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
            id: 3,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        hookSpecifications = new JBCashOutHookSpecification[](0);
        return (ruleset, PREVIEW_RECLAIM_AMOUNT, 0, hookSpecifications);
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

    receive() external payable {}
}

/// @title GrossCashOutPreviewRouteMisrankTest
/// @notice Source-project cashout previews use raw reclaim amounts because deployment makes the router feeless.
contract GrossCashOutPreviewRouteMisrankTest is RouterTerminalTest {
    function test_feelessCashOutPreviewUsesRawReclaim() public {
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;
        uint256 amount = 100;
        address payer = makeAddr("payer");
        address beneficiary = makeAddr("beneficiary");

        MockERC20 jbToken = new MockERC20();
        MockERC20 tokenB = new MockERC20();

        ProportionalRouteTerminal nativeTerminal = new ProportionalRouteTerminal(JBConstants.NATIVE_TOKEN);
        ProportionalRouteTerminal tokenBTerminal = new ProportionalRouteTerminal(address(tokenB));

        FeeAwareCashOutTerminal nativeCashOut =
            new FeeAwareCashOutTerminal{value: 200}(jbToken, JBConstants.NATIVE_TOKEN, 100, 100, 100);
        MockConfigurableCashOutTerminal tokenBCashOut =
            new MockConfigurableCashOutTerminal(jbToken, address(tokenB), 99, 99, 99);

        tokenB.mint(address(tokenBCashOut), 99);
        jbToken.mint(payer, amount * 2);

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

        (, uint256 optimisticPreview,,) =
            routerTerminal.previewPayFor(destProjectId, address(jbToken), amount, beneficiary, "");
        uint256 chosenRouteMinted =
            routerTerminal.pay(destProjectId, address(jbToken), amount, beneficiary, 0, "chosen", "");

        bytes4 routeId = JBMetadataResolver.getId("routeTokenOut", address(routerTerminal));
        bytes memory forceNativeMetadata =
            JBMetadataResolver.addToMetadata("", routeId, abi.encode(JBConstants.NATIVE_TOKEN));
        uint256 forcedNativeMinted =
            routerTerminal.pay(destProjectId, address(jbToken), amount, beneficiary, 0, "forced", forceNativeMetadata);
        vm.stopPrank();

        assertEq(optimisticPreview, 100, "preview should choose the raw native reclaim route");
        assertEq(chosenRouteMinted, 100, "chosen route should settle through the raw native route");
        assertEq(forcedNativeMinted, 100, "forced native route should expose the same feeless reclaim");
        assertEq(nativeTerminal.totalReceived(), 200, "both native routes should fund the destination terminal");
        assertEq(tokenBTerminal.totalReceived(), 0, "default route should not use the lower tokenB route");
    }
}
