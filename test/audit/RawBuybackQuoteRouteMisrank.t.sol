// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {RouterTerminalTest, MockConfigurableCashOutTerminal, MockERC20} from "../RouterTerminal.t.sol";

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
        if (token == JBConstants.NATIVE_TOKEN) require(msg.value == amount, "ProportionalPreviewTerminal: ETH mismatch");
        else IERC20(token).transferFrom(msg.sender, address(this), amount);

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

/// @title RawBuybackQuoteRouteMisrankTest
/// @notice The router ranks cashout candidates by executable buyback floors, not optimistic raw diagnostics.
contract RawBuybackQuoteRouteMisrankTest is RouterTerminalTest {
    function test_rawBuybackQuoteCannotOutrankBetterExecutableRoute() public {
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;
        uint256 amount = 100;
        address payer = makeAddr("payer");
        address beneficiary = makeAddr("beneficiary");

        MockERC20 jbToken = new MockERC20();
        MockERC20 tokenB = new MockERC20();

        ProportionalPreviewTerminal nativeTerminal = new ProportionalPreviewTerminal(JBConstants.NATIVE_TOKEN);
        ProportionalPreviewTerminal tokenBTerminal = new ProportionalPreviewTerminal(address(tokenB));

        MockConfigurableCashOutTerminal nativeCashOut =
            new MockConfigurableCashOutTerminal{value: 60}(jbToken, JBConstants.NATIVE_TOKEN, 60, 60, 60);
        MockConfigurableCashOutTerminal tokenBCashOut =
            new MockConfigurableCashOutTerminal(jbToken, address(tokenB), 0, 40, 0);

        tokenB.mint(address(tokenBCashOut), 40);
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
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.terminalsOf, (destProjectId)),
            abi.encode(destTerminals)
        );

        bytes4 buybackInterfaceId = bytes4(keccak256("MAX_TWAP_WINDOW()"));
        vm.mockCall(buybackHook, abi.encodeCall(IERC165.supportsInterface, (buybackInterfaceId)), abi.encode(true));

        vm.mockCall(
            address(tokenBCashOut),
            abi.encodeCall(
                IJBCashOutTerminal.previewCashOutFrom,
                (
                    address(routerTerminal),
                    sourceProjectId,
                    amount,
                    address(tokenB),
                    payable(address(routerTerminal)),
                    bytes("")
                )
            ),
            abi.encode(
                JBRuleset({
                    cycleNumber: 1,
                    id: 333,
                    basedOnId: 0,
                    start: 0,
                    duration: 0,
                    weight: 0,
                    weightCutPercent: 0,
                    approvalHook: IJBRulesetApprovalHook(address(0)),
                    metadata: 0
                }),
                uint256(0),
                uint256(0),
                _buybackCashOutHookSpecifications(buybackHook, 40, 75)
            )
        );

        vm.startPrank(payer);
        jbToken.approve(address(routerTerminal), type(uint256).max);

        (, uint256 defaultPreview,,) =
            routerTerminal.previewPayFor(destProjectId, address(jbToken), amount, beneficiary, "");
        uint256 defaultRouteMinted =
            routerTerminal.pay(destProjectId, address(jbToken), amount, beneficiary, 0, "default", "");

        bytes4 routeId = JBMetadataResolver.getId("routeTokenOut", address(routerTerminal));
        bytes memory forceTokenBMetadata = JBMetadataResolver.addToMetadata("", routeId, abi.encode(address(tokenB)));
        uint256 forcedTokenBMinted =
            routerTerminal.pay(destProjectId, address(jbToken), amount, beneficiary, 0, "forced", forceTokenBMetadata);
        vm.stopPrank();

        assertEq(defaultPreview, 60, "preview should choose the higher executable native route");
        assertEq(defaultRouteMinted, 60, "default route should settle through the executable native route");
        assertEq(forcedTokenBMinted, 40, "forced tokenB route should expose the lower executable route");
        assertEq(tokenBTerminal.totalReceived(), 40, "forced route should send tokenB");
        assertEq(nativeTerminal.totalReceived(), 60, "default route should send native value once");
    }

    function _buybackCashOutHookSpecifications(
        address hook,
        uint256 minimumSwapAmountOut,
        uint256 rawSwapQuote
    )
        internal
        pure
        returns (JBCashOutHookSpecification[] memory specifications)
    {
        specifications = new JBCashOutHookSpecification[](1);
        specifications[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(hook),
            noop: false,
            amount: 0,
            metadata: abi.encode(
                minimumSwapAmountOut,
                uint256(0),
                uint256(0),
                int24(0),
                uint128(0),
                PoolId.wrap(bytes32(0)),
                rawSwapQuote
            )
        });
    }
}
