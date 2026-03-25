// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

// ══════════════════════════════════════════════════════════════════════════════
// Test Contract: Credit cashout flow in JBRouterTerminal
// ══════════════════════════════════════════════════════════════════════════════

contract RouterTerminalCreditCashoutTest is Test {
    JBRouterTerminal routerTerminal;

    // Mocked dependencies.
    IJBDirectory mockDirectory;
    IJBPermissions mockPermissions;
    IJBProjects mockProjects;
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
        mockProjects = IJBProjects(makeAddr("mockProjects"));
        vm.etch(address(mockProjects), hex"00");
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
            mockPermissions,
            mockProjects,
            mockTokens,
            mockPermit2,
            terminalOwner,
            mockWeth,
            mockFactory,
            mockPoolManager,
            address(0)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 1: Credit cashout happy path — pay via credits
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Tests the full credit cashout flow:
    /// 1. User encodes cashOutSource metadata with (sourceProjectId, creditAmount)
    /// 2. Router calls TOKENS.transferCreditsFrom(holder, sourceProjectId, router, creditAmount)
    /// 3. Router uses the credit amount through the cashout loop
    /// 4. Final token is paid to the destination project
    function test_creditCashout_happyPath() public {
        address payer = makeAddr("payer");
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;
        uint256 creditAmount = 100e18;
        address mockDestTerminal = makeAddr("destTerminal");
        address mockCashOutTerminal = makeAddr("cashOutTerminal");
        vm.etch(mockDestTerminal, hex"00");
        vm.etch(mockCashOutTerminal, hex"00");

        // Build metadata with cashOutSource. Note: getId("cashOutSource") inside the router
        // uses address(this) = address(routerTerminal), so we use the two-arg form here.
        bytes memory metadata;
        {
            bytes4 metadataId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
            metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(sourceProjectId, creditAmount));
        }

        // Mock: TOKENS.transferCreditsFrom should be called with correct params.
        vm.mockCall(
            address(mockTokens),
            abi.encodeCall(
                IJBTokens.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), creditAmount)
            ),
            abi.encode()
        );

        // Expect the exact transferCreditsFrom call.
        vm.expectCall(
            address(mockTokens),
            abi.encodeCall(
                IJBTokens.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), creditAmount)
            )
        );

        // The route function will look up cashOutSource in metadata again and get sourceProjectIdOverride.
        // So it skips the projectIdOf lookup and goes into _cashOutLoop with override.

        // Dest project (1) accepts NATIVE_TOKEN.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(mockDestTerminal)
        );

        // Source project's terminal list (for _findCashOutPath).
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

        // Fund the router with ETH to cover the cashout reclaim (NATIVE_TOKEN).
        vm.deal(address(routerTerminal), 60e18);

        // Mock dest terminal pay.
        vm.mockCall(mockDestTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(500)));

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
        vm.expectRevert(abi.encodeWithSelector(JBRouterTerminal.JBRouterTerminal_NoMsgValueAllowed.selector, 1 ether));
        routerTerminal.pay{value: 1 ether}(destProjectId, JBConstants.NATIVE_TOKEN, 1 ether, payer, 0, "", metadata);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 3: Credit cashout with addToBalanceOf
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Credit cashout also works via addToBalanceOf (same _acceptFundsFor path).
    function test_creditCashout_addToBalanceOf() public {
        address payer = makeAddr("payer");
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;
        uint256 creditAmount = 50e18;
        address mockDestTerminal = makeAddr("destTerminal");
        address mockCashOutTerminal = makeAddr("cashOutTerminal");
        vm.etch(mockDestTerminal, hex"00");
        vm.etch(mockCashOutTerminal, hex"00");

        // Build metadata with cashOutSource.
        bytes memory metadata;
        {
            bytes4 metadataId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
            metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(sourceProjectId, creditAmount));
        }

        // Mock: TOKENS.transferCreditsFrom.
        vm.mockCall(
            address(mockTokens),
            abi.encodeCall(
                IJBTokens.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), creditAmount)
            ),
            abi.encode()
        );

        // Expect the transferCreditsFrom call.
        vm.expectCall(
            address(mockTokens),
            abi.encodeCall(
                IJBTokens.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), creditAmount)
            )
        );

        // Dest project (1) accepts NATIVE_TOKEN.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(mockDestTerminal)
        );

        // Source project's terminal list (for _findCashOutPath).
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

        // Mock cashOutTokensOf: returns 30 ETH reclaimed.
        vm.mockCall(
            mockCashOutTerminal,
            abi.encodeWithSelector(IJBCashOutTerminal.cashOutTokensOf.selector),
            abi.encode(uint256(30e18))
        );

        // Fund the router with ETH for the cashout reclaim.
        vm.deal(address(routerTerminal), 30e18);

        // Mock dest terminal addToBalanceOf.
        vm.mockCall(mockDestTerminal, abi.encodeWithSelector(IJBTerminal.addToBalanceOf.selector), abi.encode());

        // Expect: addToBalanceOf is called with the reclaimed amount (30e18) on the dest terminal.
        // Note: vm.mockCall intercepts the call, so ETH is not actually transferred to the mock.
        // We verify correctness by checking the call was made with the right value.
        vm.expectCall(
            mockDestTerminal,
            30e18, // msg.value
            abi.encodeCall(
                IJBTerminal.addToBalanceOf, (destProjectId, JBConstants.NATIVE_TOKEN, 30e18, false, "", metadata)
            )
        );

        // Execute.
        vm.prank(payer);
        routerTerminal.addToBalanceOf(destProjectId, JBConstants.NATIVE_TOKEN, 0, false, "", metadata);
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

    // ═══════════════════════════════════════════════════════════════════════
    // Test 5: Credit cashout with cashOutMinReclaimed slippage protection
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When both cashOutSource and cashOutMinReclaimed are in the metadata,
    /// the minTokensReclaimed should be forwarded to the cashout terminal.
    function test_creditCashout_withMinReclaimed() public {
        address payer = makeAddr("payer");
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;
        uint256 creditAmount = 100e18;
        uint256 minReclaimed = 50e18;
        address mockDestTerminal = makeAddr("destTerminal");
        address mockCashOutTerminal = makeAddr("cashOutTerminal");
        vm.etch(mockDestTerminal, hex"00");
        vm.etch(mockCashOutTerminal, hex"00");

        // Build metadata with both cashOutSource and cashOutMinReclaimed.
        bytes memory metadata;
        {
            bytes4 cashOutSourceId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
            metadata = JBMetadataResolver.addToMetadata("", cashOutSourceId, abi.encode(sourceProjectId, creditAmount));

            bytes4 minReclaimedId = JBMetadataResolver.getId("cashOutMinReclaimed", address(routerTerminal));
            metadata = JBMetadataResolver.addToMetadata(metadata, minReclaimedId, abi.encode(minReclaimed));
        }

        // Mock: TOKENS.transferCreditsFrom.
        vm.mockCall(
            address(mockTokens),
            abi.encodeCall(
                IJBTokens.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), creditAmount)
            ),
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

        // Mock cashOutTokensOf — returns 60 ETH.
        vm.mockCall(
            mockCashOutTerminal,
            abi.encodeWithSelector(IJBCashOutTerminal.cashOutTokensOf.selector),
            abi.encode(uint256(60e18))
        );

        // Expect: cashOutTokensOf is called with minReclaimed = 50e18.
        vm.expectCall(
            mockCashOutTerminal,
            abi.encodeCall(
                IJBCashOutTerminal.cashOutTokensOf,
                (
                    address(routerTerminal),
                    sourceProjectId,
                    creditAmount,
                    JBConstants.NATIVE_TOKEN,
                    minReclaimed,
                    payable(address(routerTerminal)),
                    bytes("")
                )
            )
        );

        // Fund the router with ETH.
        vm.deal(address(routerTerminal), 60e18);

        // Mock dest terminal pay.
        vm.mockCall(mockDestTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(200)));

        vm.prank(payer);
        uint256 result = routerTerminal.pay(destProjectId, JBConstants.NATIVE_TOKEN, 0, payer, 0, "", metadata);

        assertEq(result, 200, "pay should return dest terminal token count");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 6: Credit cashout with zero credit amount
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Passing creditAmount = 0 should still go through the credit path but with zero credits.
    function test_creditCashout_zeroCreditAmount() public {
        address payer = makeAddr("payer");
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;
        uint256 creditAmount = 0;
        address mockDestTerminal = makeAddr("destTerminal");
        address mockCashOutTerminal = makeAddr("cashOutTerminal");
        vm.etch(mockDestTerminal, hex"00");
        vm.etch(mockCashOutTerminal, hex"00");

        // Build metadata with cashOutSource and zero credits.
        bytes memory metadata;
        {
            bytes4 metadataId = JBMetadataResolver.getId("cashOutSource", address(routerTerminal));
            metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(sourceProjectId, creditAmount));
        }

        // Mock: TOKENS.transferCreditsFrom with zero amount.
        vm.mockCall(
            address(mockTokens),
            abi.encodeCall(IJBTokens.transferCreditsFrom, (payer, sourceProjectId, address(routerTerminal), 0)),
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
}
