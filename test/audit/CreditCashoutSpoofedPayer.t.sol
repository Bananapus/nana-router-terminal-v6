// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
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
import {IJBPayerTracker} from "../../src/interfaces/IJBPayerTracker.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

/// @notice Attacker contract that spoofs originalPayer() to point at a victim.
contract AttackerSpoofingPayer is IJBPayerTracker {
    address public override originalPayer;

    constructor(address victim) {
        originalPayer = victim;
    }

    function attackViaPay(
        JBRouterTerminal router,
        uint256 projectId,
        bytes calldata metadata
    )
        external
        returns (uint256)
    {
        return router.pay(projectId, JBConstants.NATIVE_TOKEN, 0, address(this), 0, "", metadata);
    }
}

    /// @notice H-24: Verify that spoofing originalPayer() cannot steal another user's credits.
    contract CreditCashoutSpoofedPayerTest is Test {
        JBRouterTerminal routerTerminal;

        IJBDirectory mockDirectory;
        IJBPermissions mockPermissions;
        IJBTokens mockTokens;
        IPermit2 mockPermit2;
        IWETH9 mockWeth;
        IUniswapV3Factory mockFactory;
        IPoolManager mockPoolManager;

        function setUp() public {
            mockDirectory = IJBDirectory(makeAddr("mockDirectory"));
            vm.etch(address(mockDirectory), hex"00");
            mockPermissions = IJBPermissions(makeAddr("mockPermissions"));
            vm.etch(address(mockPermissions), hex"00");
            mockTokens = IJBTokens(makeAddr("mockTokens"));
            vm.etch(address(mockTokens), hex"00");
            mockPermit2 = IPermit2(makeAddr("mockPermit2"));
            vm.etch(address(mockPermit2), hex"00");
            mockWeth = IWETH9(makeAddr("mockWeth"));
            vm.etch(address(mockWeth), hex"00");
            mockFactory = IUniswapV3Factory(makeAddr("mockFactory"));
            vm.etch(address(mockFactory), hex"00");
            mockPoolManager = IPoolManager(makeAddr("mockPoolManager"));
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

        /// @notice An attacker contract spoofing originalPayer() should have its own credits debited, not the victim's.
        function test_spoofedOriginalPayer_debitsAttackerNotVictim() public {
            address victim = makeAddr("victim");
            address controller = makeAddr("controller");
            uint256 destProjectId = 1;
            uint256 sourceProjectId = 2;
            uint256 creditAmount = 100e18;
            address mockDestTerminal = makeAddr("destTerminal");
            address mockCashOutTerminal = makeAddr("cashOutTerminal");
            vm.etch(controller, hex"00");
            vm.etch(mockDestTerminal, hex"00");
            vm.etch(mockCashOutTerminal, hex"00");

            // Attacker contract spoofs originalPayer() to return victim's address.
            AttackerSpoofingPayer attacker = new AttackerSpoofingPayer(victim);

            bytes4 metadataId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
            bytes memory metadata =
                JBMetadataResolver.addToMetadata("", metadataId, abi.encode(sourceProjectId, creditAmount));

            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.controllerOf, (sourceProjectId)),
                abi.encode(controller)
            );

            // The key assertion: transferCreditsFrom is called with the ATTACKER as holder, NOT the victim.
            vm.mockCall(
                controller,
                abi.encodeCall(
                    IJBController.transferCreditsFrom,
                    (address(attacker), sourceProjectId, address(routerTerminal), creditAmount)
                ),
                abi.encode()
            );
            vm.expectCall(
                controller,
                abi.encodeCall(
                    IJBController.transferCreditsFrom,
                    (address(attacker), sourceProjectId, address(routerTerminal), creditAmount)
                )
            );

            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
                abi.encode(mockDestTerminal)
            );

            IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
            sourceTerminals[0] = IJBTerminal(mockCashOutTerminal);
            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
                abi.encode(sourceTerminals)
            );

            vm.mockCall(
                mockCashOutTerminal,
                abi.encodeCall(IERC165.supportsInterface, (type(IJBCashOutTerminal).interfaceId)),
                abi.encode(true)
            );

            JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
            contexts[0] = JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });
            vm.mockCall(
                mockCashOutTerminal,
                abi.encodeCall(IJBTerminal.accountingContextsOf, (sourceProjectId)),
                abi.encode(contexts)
            );

            vm.mockCall(
                mockCashOutTerminal,
                abi.encodeWithSelector(IJBCashOutTerminal.cashOutTokensOf.selector),
                abi.encode(uint256(60e18))
            );
            vm.deal(address(routerTerminal), 60e18);
            vm.mockCall(mockDestTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(500)));

            attacker.attackViaPay(routerTerminal, destProjectId, metadata);
        }

        /// @notice Direct EOA credit cashouts still work — the holder is the EOA itself.
        function test_directCreditCashout_stillWorks() public {
            address payer = makeAddr("payer");
            address controller = makeAddr("controller");
            uint256 destProjectId = 1;
            uint256 sourceProjectId = 2;
            uint256 creditAmount = 50e18;
            address mockDestTerminal = makeAddr("destTerminal");
            address mockCashOutTerminal = makeAddr("cashOutTerminal");
            vm.etch(controller, hex"00");
            vm.etch(mockDestTerminal, hex"00");
            vm.etch(mockCashOutTerminal, hex"00");

            bytes4 metadataId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
            bytes memory metadata =
                JBMetadataResolver.addToMetadata("", metadataId, abi.encode(sourceProjectId, creditAmount));

            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.controllerOf, (sourceProjectId)),
                abi.encode(controller)
            );

            // EOA payer is the holder — direct call, no intermediary.
            vm.mockCall(
                controller,
                abi.encodeCall(
                    IJBController.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), creditAmount)
                ),
                abi.encode()
            );
            vm.expectCall(
                controller,
                abi.encodeCall(
                    IJBController.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), creditAmount)
                )
            );

            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
                abi.encode(mockDestTerminal)
            );

            IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
            sourceTerminals[0] = IJBTerminal(mockCashOutTerminal);
            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
                abi.encode(sourceTerminals)
            );

            vm.mockCall(
                mockCashOutTerminal,
                abi.encodeCall(IERC165.supportsInterface, (type(IJBCashOutTerminal).interfaceId)),
                abi.encode(true)
            );

            JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
            contexts[0] = JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });
            vm.mockCall(
                mockCashOutTerminal,
                abi.encodeCall(IJBTerminal.accountingContextsOf, (sourceProjectId)),
                abi.encode(contexts)
            );

            vm.mockCall(
                mockCashOutTerminal,
                abi.encodeWithSelector(IJBCashOutTerminal.cashOutTokensOf.selector),
                abi.encode(uint256(30e18))
            );
            vm.deal(address(routerTerminal), 30e18);
            vm.mockCall(mockDestTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(200)));

            vm.prank(payer);
            uint256 result = routerTerminal.pay(destProjectId, JBConstants.NATIVE_TOKEN, 0, payer, 0, "", metadata);
            assertEq(result, 200);
        }
    }
