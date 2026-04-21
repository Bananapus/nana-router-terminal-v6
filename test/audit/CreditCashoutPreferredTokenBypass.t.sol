// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

/// @title M26_CreditCashoutPreferredTokenBypass
/// @notice Before the fix, when sourceProjectIdOverride != 0 and preferredToken matched the
///         current token, the _cashOutLoop would short-circuit on the first iteration — returning
///         without cashing out. This test verifies the fix: the forced first cashout must happen.
contract M26_CreditCashoutPreferredTokenBypass is Test {
    JBRouterTerminal routerTerminal;

    IJBDirectory mockDirectory;
    IJBTokens mockTokens;

    address payer = makeAddr("payer");
    address controller = makeAddr("controller");
    address mockDestTerminal = makeAddr("destTerminal");
    address mockCashOutTerminal = makeAddr("cashOutTerminal");

    uint256 destProjectId = 1;
    uint256 sourceProjectId = 2;
    uint256 creditAmount = 100e18;

    function setUp() public {
        mockDirectory = IJBDirectory(makeAddr("mockDirectory"));
        vm.etch(address(mockDirectory), hex"00");
        mockTokens = IJBTokens(makeAddr("mockTokens"));
        vm.etch(address(mockTokens), hex"00");
        vm.etch(controller, hex"00");
        vm.etch(mockDestTerminal, hex"00");
        vm.etch(mockCashOutTerminal, hex"00");

        IPermit2 mockPermit2 = IPermit2(makeAddr("mockPermit2"));
        vm.etch(address(mockPermit2), hex"00");
        IWETH9 mockWeth = IWETH9(makeAddr("mockWeth"));
        vm.etch(address(mockWeth), hex"00");
        IUniswapV3Factory mockFactory = IUniswapV3Factory(makeAddr("mockFactory"));
        vm.etch(address(mockFactory), hex"00");
        IPoolManager mockPoolManager = IPoolManager(makeAddr("mockPoolManager"));
        vm.etch(address(mockPoolManager), hex"00");

        routerTerminal = new JBRouterTerminal(
            mockDirectory,
            mockTokens,
            mockPermit2,
            mockWeth,
            mockFactory,
            mockPoolManager,
            address(0),
            address(0),
            address(0)
        );
    }

    /// @notice With the fix, credit cashout with sourceProjectIdOverride and a preferred token
    ///         that matches the token must still perform at least one cashout hop.
    function test_creditCashout_forcedHopWithPreferredToken() public {
        // Build metadata: cashOutSource with sourceProjectId + creditAmount,
        // and cashOutPreferredToken with NATIVE_TOKEN.
        bytes memory metadata;
        {
            bytes4 cashOutSourceId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
            metadata = JBMetadataResolver.addToMetadata("", cashOutSourceId, abi.encode(sourceProjectId, creditAmount));

            bytes4 preferredTokenId = JBMetadataResolver.getId("cashOutPreferredToken", address(routerTerminal));
            metadata =
                JBMetadataResolver.addToMetadata(metadata, preferredTokenId, abi.encode(JBConstants.NATIVE_TOKEN));
        }

        // Mock: controller lookup for sourceProjectId.
        vm.mockCall(
            address(mockDirectory), abi.encodeCall(IJBDirectory.controllerOf, (sourceProjectId)), abi.encode(controller)
        );

        // Mock: controller.transferCreditsFrom.
        vm.mockCall(
            controller,
            abi.encodeCall(
                IJBController.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), creditAmount)
            ),
            abi.encode()
        );

        // Dest project accepts NATIVE_TOKEN.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(mockDestTerminal)
        );

        // Source project's terminal list.
        {
            IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
            sourceTerminals[0] = IJBTerminal(mockCashOutTerminal);
            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
                abi.encode(sourceTerminals)
            );
        }

        // Mock supportsInterface for IJBCashOutTerminal.
        vm.mockCall(
            mockCashOutTerminal,
            abi.encodeCall(IERC165.supportsInterface, (type(IJBCashOutTerminal).interfaceId)),
            abi.encode(true)
        );

        // Accounting context: source project terminal accepts NATIVE_TOKEN.
        {
            JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
            contexts[0] = JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });
            vm.mockCall(
                mockCashOutTerminal,
                abi.encodeCall(IJBTerminal.accountingContextsOf, (sourceProjectId)),
                abi.encode(contexts)
            );
        }

        // Mock cashOutTokensOf: returns 60 ETH reclaimed.
        vm.mockCall(
            mockCashOutTerminal,
            abi.encodeWithSelector(IJBCashOutTerminal.cashOutTokensOf.selector),
            abi.encode(uint256(60e18))
        );

        // The cashout terminal sends ETH to the router.
        vm.deal(address(routerTerminal), 60e18);

        // Mock dest terminal pay.
        vm.mockCall(mockDestTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(500)));

        // The key assertion: cashOutTokensOf MUST be called on the source terminal.
        // Before the fix, the preferred-token short-circuit would skip this call entirely.
        vm.expectCall(mockCashOutTerminal, abi.encodeWithSelector(IJBCashOutTerminal.cashOutTokensOf.selector));

        vm.prank(payer);
        uint256 result = routerTerminal.pay(destProjectId, JBConstants.NATIVE_TOKEN, 0, payer, 0, "", metadata);

        assertEq(result, 500, "pay should return dest terminal token count");
    }
}
