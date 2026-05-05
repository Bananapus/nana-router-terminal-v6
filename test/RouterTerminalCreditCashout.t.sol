// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {IJBPayerTracker} from "../src/interfaces/IJBPayerTracker.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

// ══════════════════════════════════════════════════════════════════════════════
// Test Contract: Credit cashout flow in JBRouterTerminal
// ══════════════════════════════════════════════════════════════════════════════

contract CreditCashoutHarnessTerminal {
    uint256 public immutable RECLAIM_AMOUNT;
    address public immutable ACCEPTED_TOKEN;
    uint256 public lastMinTokensReclaimed;

    constructor(uint256 reclaimAmount_, address acceptedToken_) payable {
        RECLAIM_AMOUNT = reclaimAmount_;
        ACCEPTED_TOKEN = acceptedToken_;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBCashOutTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: ACCEPTED_TOKEN, decimals: 18, currency: uint32(uint160(ACCEPTED_TOKEN))});
    }

    function cashOutTokensOf(
        address,
        uint256,
        uint256,
        address,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata
    )
        external
        returns (uint256)
    {
        lastMinTokensReclaimed = minTokensReclaimed;
        if (RECLAIM_AMOUNT != 0) beneficiary.transfer(RECLAIM_AMOUNT);
        return RECLAIM_AMOUNT;
    }

    receive() external payable {}
}

contract CreditCashoutHarnessDestinationTerminal {
    uint256 public lastAmount;
    uint256 public lastValue;
    uint256 public payReturnValue;

    constructor(uint256 payReturnValue_) {
        payReturnValue = payReturnValue_;
    }

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
        lastValue = msg.value;
        return payReturnValue;
    }

    function addToBalanceOf(uint256, address, uint256 amount, bool, string calldata, bytes calldata) external payable {
        lastAmount = amount;
        lastValue = msg.value;
    }
}

contract CreditCashoutSpoofingIntermediary is IJBPayerTracker {
    address public override originalPayer;

    constructor(address originalPayer_) {
        originalPayer = originalPayer_;
    }

    function payThroughRouter(
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

    contract RouterTerminalCreditCashoutTest is Test {
        JBRouterTerminal routerTerminal;

        // Mocked dependencies.
        IJBDirectory mockDirectory;
        IJBPermissions mockPermissions;
        IJBTokens mockTokens;
        IPermit2 mockPermit2;
        IWETH9 mockWeth;
        IUniswapV3Factory mockFactory;
        IPoolManager mockPoolManager;

        address terminalOwner;

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

            terminalOwner = makeAddr("terminalOwner");

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

        // ═══════════════════════════════════════════════════════════════════════
        // Test 1: Credit cashout happy path — pay via credits
        // ═══════════════════════════════════════════════════════════════════════

        /// @notice Tests the full credit cashout flow:
        /// 1. User encodes cashOutSource metadata with (sourceProjectId, creditAmount)
        /// 2. Router resolves the source project's controller and calls transferCreditsFrom on it
        /// 3. Router uses the credit amount through the cashout loop
        /// 4. Final token is paid to the destination project
        function test_creditCashout_happyPath() public {
            address payer = makeAddr("payer");
            address controller = makeAddr("controller");
            uint256 destProjectId = 1;
            uint256 sourceProjectId = 2;
            uint256 creditAmount = 100e18;
            vm.etch(controller, hex"00");
            CreditCashoutHarnessDestinationTerminal destTerminal = new CreditCashoutHarnessDestinationTerminal(500);
            CreditCashoutHarnessTerminal cashOutTerminal =
                new CreditCashoutHarnessTerminal{value: 60e18}(60e18, JBConstants.NATIVE_TOKEN);

            // Build metadata with cashOutSource. Note: getId("cashOutSource") inside the router
            // uses address(this) = address(routerTerminal), so we use the two-arg form here.
            bytes memory metadata;
            {
                bytes4 metadataId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
                metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(sourceProjectId, creditAmount));
            }

            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.controllerOf, (sourceProjectId)),
                abi.encode(controller)
            );

            // Mock: controller.transferCreditsFrom should be called with correct params.
            vm.mockCall(
                controller,
                abi.encodeCall(
                    IJBController.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), creditAmount)
                ),
                abi.encode()
            );

            // Expect the exact controller hop.
            vm.expectCall(address(mockDirectory), abi.encodeCall(IJBDirectory.controllerOf, (sourceProjectId)));
            vm.expectCall(
                controller,
                abi.encodeCall(
                    IJBController.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), creditAmount)
                )
            );

            // The route function will look up cashOutSource in metadata again and get sourceProjectIdOverride.
            // So it skips the projectIdOf lookup and goes into _cashOutLoop with override.

            // Dest project (1) accepts NATIVE_TOKEN.
            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
                abi.encode(address(destTerminal))
            );

            // Source project's terminal list (for _findCashOutPath).
            {
                IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
                sourceTerminals[0] = IJBTerminal(address(cashOutTerminal));
                vm.mockCall(
                    address(mockDirectory),
                    abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
                    abi.encode(sourceTerminals)
                );
            }

            // token param is arbitrary for credit cashouts — the _acceptFundsFor short-circuits before using it.
            vm.prank(payer);
            uint256 result = routerTerminal.pay(destProjectId, JBConstants.NATIVE_TOKEN, 0, payer, 0, "", metadata);

            assertEq(result, 500, "pay should return dest terminal token count");
        }

        // ═══════════════════════════════════════════════════════════════════════
        // Test 2: Credit cashout reverts when ETH sent alongside credits
        // ═══════════════════════════════════════════════════════════════════════

        /// @notice Sending msg.value alongside cashOutSource credit metadata should revert
        /// to prevent ETH from being trapped in the router.
        function test_creditCashout_revertsWithETH() public {
            address payer = makeAddr("payer");
            uint256 destProjectId = 1;
            uint256 sourceProjectId = 2;
            uint256 creditAmount = 100e18;

            // Build metadata with cashOutSource.
            bytes memory metadata;
            {
                bytes4 metadataId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
                metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(sourceProjectId, creditAmount));
            }

            vm.deal(payer, 1 ether);
            vm.prank(payer);
            vm.expectRevert(
                abi.encodeWithSelector(JBRouterTerminal.JBRouterTerminal_NoMsgValueAllowed.selector, 1 ether)
            );
            routerTerminal.pay{value: 1 ether}(destProjectId, JBConstants.NATIVE_TOKEN, 1 ether, payer, 0, "", metadata);
        }

        // ═══════════════════════════════════════════════════════════════════════
        // Test 3: Credit cashout with addToBalanceOf
        // ═══════════════════════════════════════════════════════════════════════

        /// @notice Credit cashout also works via addToBalanceOf (same _acceptFundsFor path).
        function test_creditCashout_addToBalanceOf() public {
            address payer = makeAddr("payer");
            address controller = makeAddr("controller");
            uint256 destProjectId = 1;
            uint256 sourceProjectId = 2;
            uint256 creditAmount = 50e18;
            vm.etch(controller, hex"00");
            CreditCashoutHarnessDestinationTerminal destTerminal = new CreditCashoutHarnessDestinationTerminal(0);
            CreditCashoutHarnessTerminal cashOutTerminal =
                new CreditCashoutHarnessTerminal{value: 30e18}(30e18, JBConstants.NATIVE_TOKEN);

            // Build metadata with cashOutSource.
            bytes memory metadata;
            {
                bytes4 metadataId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
                metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(sourceProjectId, creditAmount));
            }

            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.controllerOf, (sourceProjectId)),
                abi.encode(controller)
            );

            // Mock: controller.transferCreditsFrom.
            vm.mockCall(
                controller,
                abi.encodeCall(
                    IJBController.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), creditAmount)
                ),
                abi.encode()
            );

            // Expect the controller lookup and transferCreditsFrom call.
            vm.expectCall(address(mockDirectory), abi.encodeCall(IJBDirectory.controllerOf, (sourceProjectId)));
            vm.expectCall(
                controller,
                abi.encodeCall(
                    IJBController.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), creditAmount)
                )
            );

            // Dest project (1) accepts NATIVE_TOKEN.
            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
                abi.encode(address(destTerminal))
            );

            // Source project's terminal list (for _findCashOutPath).
            {
                IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
                sourceTerminals[0] = IJBTerminal(address(cashOutTerminal));
                vm.mockCall(
                    address(mockDirectory),
                    abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
                    abi.encode(sourceTerminals)
                );
            }

            // Execute.
            vm.prank(payer);
            routerTerminal.addToBalanceOf(destProjectId, JBConstants.NATIVE_TOKEN, 0, false, "", metadata);

            assertEq(destTerminal.lastAmount(), 30e18, "dest terminal should receive the reclaimed amount");
            assertEq(destTerminal.lastValue(), 30e18, "dest terminal should receive ETH value");
        }

        // ═══════════════════════════════════════════════════════════════════════
        // Test 4: Credit cashout metadata parsing — correct sourceProjectId + amount
        // ═══════════════════════════════════════════════════════════════════════

        /// @notice Verify the metadata encoding/decoding is consistent between test and contract.
        /// The cashOutSource metadata key encodes (sourceProjectId, creditAmount).
        function test_creditCashout_metadataParsing() public view {
            uint256 sourceProjectId = 42;
            uint256 creditAmount = 123e18;

            // Build metadata the same way the frontend would.
            bytes4 metadataId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
            bytes memory metadata =
                JBMetadataResolver.addToMetadata("", metadataId, abi.encode(sourceProjectId, creditAmount));

            // Verify we can decode it.
            (bool exists, bytes memory data) = JBMetadataResolver.getDataFor(metadataId, metadata);
            assertTrue(exists, "cashOutSource metadata should exist");

            (uint256 decodedProjectId, uint256 decodedAmount) = abi.decode(data, (uint256, uint256));
            assertEq(decodedProjectId, sourceProjectId, "decoded project ID should match");
            assertEq(decodedAmount, creditAmount, "decoded amount should match");
        }

        /// @notice After H-24 fix: credit cashouts through a payer tracker debit the intermediary (msg.sender),
        /// not the spoofed originalPayer. This prevents credit theft.
        function test_creditCashout_debitsIntermediaryNotSpoofedPayer() public {
            address victim = makeAddr("victim");
            address controller = makeAddr("controller");
            uint256 destProjectId = 1;
            uint256 sourceProjectId = 2;
            uint256 creditAmount = 100e18;
            vm.etch(controller, hex"00");
            CreditCashoutHarnessDestinationTerminal destTerminal = new CreditCashoutHarnessDestinationTerminal(500);
            CreditCashoutHarnessTerminal cashOutTerminal =
                new CreditCashoutHarnessTerminal{value: 60e18}(60e18, JBConstants.NATIVE_TOKEN);

            CreditCashoutSpoofingIntermediary intermediary = new CreditCashoutSpoofingIntermediary(victim);

            bytes4 metadataId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
            bytes memory metadata =
                JBMetadataResolver.addToMetadata("", metadataId, abi.encode(sourceProjectId, creditAmount));

            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.controllerOf, (sourceProjectId)),
                abi.encode(controller)
            );

            // After fix: transferCreditsFrom is called with the intermediary as holder, NOT the victim.
            vm.mockCall(
                controller,
                abi.encodeCall(
                    IJBController.transferCreditsFrom,
                    (address(intermediary), sourceProjectId, address(routerTerminal), creditAmount)
                ),
                abi.encode()
            );
            vm.expectCall(
                controller,
                abi.encodeCall(
                    IJBController.transferCreditsFrom,
                    (address(intermediary), sourceProjectId, address(routerTerminal), creditAmount)
                )
            );

            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
                abi.encode(address(destTerminal))
            );

            IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
            sourceTerminals[0] = IJBTerminal(address(cashOutTerminal));
            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
                abi.encode(sourceTerminals)
            );

            intermediary.payThroughRouter(routerTerminal, destProjectId, metadata);
        }

        // ═══════════════════════════════════════════════════════════════════════
        // Test 5: Credit cashout with cashOutMinReclaimed slippage protection
        // ═══════════════════════════════════════════════════════════════════════

        /// @notice When both cashOutSource and cashOutMinReclaimed are in the metadata,
        /// the router should apply the reclaim floor on the first cashout hop only.
        function test_creditCashout_withMinReclaimed() public {
            address payer = makeAddr("payer");
            address controller = makeAddr("controller");
            uint256 destProjectId = 1;
            uint256 sourceProjectId = 2;
            uint256 creditAmount = 100e18;
            uint256 minReclaimed = 50e18;
            vm.etch(controller, hex"00");
            CreditCashoutHarnessDestinationTerminal destTerminal = new CreditCashoutHarnessDestinationTerminal(200);
            CreditCashoutHarnessTerminal cashOutTerminal =
                new CreditCashoutHarnessTerminal{value: 60e18}(60e18, JBConstants.NATIVE_TOKEN);

            // Build metadata with both cashOutSource and cashOutMinReclaimed.
            bytes memory metadata;
            {
                bytes4 cashOutSourceId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
                metadata = JBMetadataResolver.addToMetadata(
                    "", cashOutSourceId, abi.encode(sourceProjectId, creditAmount)
                );

                bytes4 minReclaimedId = JBMetadataResolver.getId("cashOutMinReclaimed", address(routerTerminal));
                metadata = JBMetadataResolver.addToMetadata(metadata, minReclaimedId, abi.encode(minReclaimed));
            }

            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.controllerOf, (sourceProjectId)),
                abi.encode(controller)
            );

            // Mock: controller.transferCreditsFrom.
            vm.mockCall(
                controller,
                abi.encodeCall(
                    IJBController.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), creditAmount)
                ),
                abi.encode()
            );

            // Dest project (1) accepts NATIVE_TOKEN.
            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
                abi.encode(address(destTerminal))
            );

            // Source project's terminal list.
            {
                IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
                sourceTerminals[0] = IJBTerminal(address(cashOutTerminal));
                vm.mockCall(
                    address(mockDirectory),
                    abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
                    abi.encode(sourceTerminals)
                );
            }

            vm.prank(payer);
            uint256 result = routerTerminal.pay(destProjectId, JBConstants.NATIVE_TOKEN, 0, payer, 0, "", metadata);

            assertEq(result, 200, "pay should return dest terminal token count");
            // The router now passes minTokensReclaimed=0 to the terminal and enforces the user's
            // minimum via the balance-delta check instead (to support buyback-hook sell-side flows).
            assertEq(
                cashOutTerminal.lastMinTokensReclaimed(),
                0,
                "router should pass 0 to the terminal and enforce via balance-delta"
            );
            assertEq(destTerminal.lastAmount(), 60e18, "dest terminal should receive the reclaimed amount");
            assertEq(destTerminal.lastValue(), 60e18, "dest terminal should receive ETH value");
        }

        // ═══════════════════════════════════════════════════════════════════════
        // Test 6: Credit cashout with zero credit amount
        // ═══════════════════════════════════════════════════════════════════════

        /// @notice Passing creditAmount = 0 should still go through the credit path but with zero credits.
        function test_creditCashout_zeroCreditAmount() public {
            address payer = makeAddr("payer");
            address controller = makeAddr("controller");
            uint256 destProjectId = 1;
            uint256 sourceProjectId = 2;
            uint256 creditAmount = 0;
            address mockDestTerminal = makeAddr("destTerminal");
            address mockCashOutTerminal = makeAddr("cashOutTerminal");
            vm.etch(controller, hex"00");
            vm.etch(mockDestTerminal, hex"00");
            vm.etch(mockCashOutTerminal, hex"00");

            // Build metadata with cashOutSource and zero credits.
            bytes memory metadata;
            {
                bytes4 metadataId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
                metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(sourceProjectId, creditAmount));
            }

            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.controllerOf, (sourceProjectId)),
                abi.encode(controller)
            );

            // Mock: controller.transferCreditsFrom with zero amount.
            vm.mockCall(
                controller,
                abi.encodeCall(IJBController.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), 0)),
                abi.encode()
            );

            // Dest project (1) accepts NATIVE_TOKEN.
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

            // Mock supportsInterface.
            vm.mockCall(
                mockCashOutTerminal,
                abi.encodeCall(IERC165.supportsInterface, (type(IJBCashOutTerminal).interfaceId)),
                abi.encode(true)
            );

            // Accounting context.
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

            // Mock cashOutTokensOf returns 0 ETH reclaimed (since 0 credits cashed out).
            vm.mockCall(
                mockCashOutTerminal,
                abi.encodeWithSelector(IJBCashOutTerminal.cashOutTokensOf.selector),
                abi.encode(uint256(0))
            );

            // Mock dest terminal pay (0 ETH payment).
            vm.mockCall(mockDestTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(0)));

            vm.prank(payer);
            uint256 result = routerTerminal.pay(destProjectId, JBConstants.NATIVE_TOKEN, 0, payer, 0, "", metadata);

            assertEq(result, 0, "pay with zero credits should return zero tokens");
        }

        /// @notice Preview should mirror execution semantics when the credit cash-out amount is zero.
        function test_previewCreditCashout_zeroCreditAmount() public {
            uint256 destProjectId = 1;
            uint256 sourceProjectId = 2;
            address beneficiary = makeAddr("beneficiary");
            address mockDestTerminal = makeAddr("destTerminal");
            address mockCashOutTerminal = makeAddr("cashOutTerminal");
            vm.etch(mockDestTerminal, hex"00");
            vm.etch(mockCashOutTerminal, hex"00");

            bytes memory metadata;
            {
                bytes4 metadataId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
                metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(sourceProjectId, uint256(0)));
            }

            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
                abi.encode(mockDestTerminal)
            );

            {
                IJBTerminal[] memory destTerminals = new IJBTerminal[](1);
                destTerminals[0] = IJBTerminal(mockDestTerminal);
                vm.mockCall(
                    address(mockDirectory),
                    abi.encodeCall(IJBDirectory.terminalsOf, (destProjectId)),
                    abi.encode(destTerminals)
                );
            }

            {
                IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
                sourceTerminals[0] = IJBTerminal(mockCashOutTerminal);
                vm.mockCall(
                    address(mockDirectory),
                    abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
                    abi.encode(sourceTerminals)
                );
            }

            vm.mockCall(
                mockCashOutTerminal,
                abi.encodeCall(IERC165.supportsInterface, (type(IJBCashOutTerminal).interfaceId)),
                abi.encode(true)
            );

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
                vm.mockCall(
                    mockDestTerminal,
                    abi.encodeCall(IJBTerminal.accountingContextsOf, (destProjectId)),
                    abi.encode(contexts)
                );
            }

            vm.mockCall(
                mockCashOutTerminal,
                abi.encodeWithSelector(IJBCashOutTerminal.previewCashOutFrom.selector),
                abi.encode(
                    JBRuleset({
                        cycleNumber: 1,
                        id: 1,
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
                    new JBCashOutHookSpecification[](0)
                )
            );

            vm.mockCall(
                mockDestTerminal,
                abi.encodeWithSelector(IJBTerminal.previewPayFor.selector),
                abi.encode(
                    JBRuleset({
                        cycleNumber: 1,
                        id: 1,
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
                    new JBPayHookSpecification[](0)
                )
            );

            (JBRuleset memory ruleset, uint256 beneficiaryTokenCount, uint256 reservedTokenCount,) =
                routerTerminal.previewPayFor(destProjectId, JBConstants.NATIVE_TOKEN, 123e18, beneficiary, metadata);

            assertEq(ruleset.id, 1, "preview should still resolve destination terminal");
            assertEq(beneficiaryTokenCount, 0, "preview should treat zero credited amount as zero routed value");
            assertEq(reservedTokenCount, 0, "preview should not report minted tokens");
        }
    }
