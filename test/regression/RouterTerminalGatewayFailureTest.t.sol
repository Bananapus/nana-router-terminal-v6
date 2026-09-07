// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBFeelessAddresses} from "@bananapus/core-v6/src/interfaces/IJBFeelessAddresses.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPermitTerminal} from "@bananapus/core-v6/src/interfaces/IJBPermitTerminal.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBSplits} from "@bananapus/core-v6/src/interfaces/IJBSplits.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";

import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {JBRouterTerminalGateway} from "../../src/JBRouterTerminalGateway.sol";
import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";

import {IJBRouterTerminal} from "../../src/interfaces/IJBRouterTerminal.sol";

import {JBPendingRouterTerminalCall} from "../../src/structs/JBPendingRouterTerminalCall.sol";
import {JBPendingRouterTerminalCallFailure} from "../../src/structs/JBPendingRouterTerminalCallFailure.sol";

import {GatewayCallbackSettler} from "../helpers/gateway/GatewayCallbackSettler.sol";
import {GatewayCallbackToken} from "../helpers/gateway/GatewayCallbackToken.sol";
import {GatewayDirtyERC165Payer} from "../helpers/gateway/GatewayDirtyERC165Payer.sol";
import {GatewayEmptyFallbackPayer} from "../helpers/gateway/GatewayEmptyFallbackPayer.sol";
import {GatewayGasHarness} from "../helpers/gateway/GatewayGasHarness.sol";
import {GatewayMalformedProbeTerminal} from "../helpers/gateway/GatewayMalformedProbeTerminal.sol";
import {GatewayNestedPayer} from "../helpers/gateway/GatewayNestedPayer.sol";
import {GatewayProtocolFeePayer} from "../helpers/gateway/GatewayProtocolFeePayer.sol";
import {GatewayReentrantPayer} from "../helpers/gateway/GatewayReentrantPayer.sol";
import {GatewayTestDirectory} from "../helpers/gateway/GatewayTestDirectory.sol";
import {GatewayTestPermit2} from "../helpers/gateway/GatewayTestPermit2.sol";
import {GatewayTestProjects} from "../helpers/gateway/GatewayTestProjects.sol";
import {GatewayTestRouter} from "../helpers/gateway/GatewayTestRouter.sol";
import {GatewayTestSourceTerminal} from "../helpers/gateway/GatewayTestSourceTerminal.sol";
import {GatewayTestTerminalStore} from "../helpers/gateway/GatewayTestTerminalStore.sol";
import {GatewayTestToken} from "../helpers/gateway/GatewayTestToken.sol";
import {GatewayTestTrustedForwarder} from "../helpers/gateway/GatewayTestTrustedForwarder.sol";

/// @notice Exercises pending-payment custody, retries, and source-project recovery across routing failure boundaries.
contract RouterTerminalGatewayFailureTest is Test {
    //*********************************************************************//
    // ------------------------ internal constants ----------------------- //
    //*********************************************************************//

    /// @notice The original fee amount used to check custody conservation.
    uint256 internal constant _AMOUNT = 25_003;
    /// @notice The fee project receiving fixture payments.
    uint256 internal constant _DESTINATION_PROJECT_ID = 1;
    /// @notice The first pending identifier assigned by the gateway.
    bytes32 internal constant _ID = bytes32(uint256(1));
    /// @notice The project whose accounting receives qualified refunds.
    uint256 internal constant _SOURCE_PROJECT_ID = 2;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The directory controlling registered refund destinations.
    GatewayTestDirectory internal _directory;
    /// @notice The gateway whose custody and qualification are exercised.
    JBRouterTerminalGateway internal _gateway;
    /// @notice The registry forwarding source-terminal payments to the gateway.
    JBRouterTerminalRegistry internal _registry;
    /// @notice The router whose failure shape and gas requirements are configurable.
    GatewayTestRouter internal _router;
    /// @notice The funded source terminal whose project balance can receive refunds.
    GatewayTestSourceTerminal internal _sourceTerminal;
    /// @notice The original payment token held as pending-call collateral.
    GatewayTestToken internal _token;

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Deploys a failing router, its gateway, and a funded source terminal for isolated custody checks.
    function setUp() public {
        _directory = new GatewayTestDirectory();
        _router = new GatewayTestRouter();
        _gateway = new JBRouterTerminalGateway({
            directory: IJBDirectory(address(_directory)),
            permit2: IPermit2(address(0)),
            router: IJBRouterTerminal(address(_router)),
            trustedForwarder: address(0)
        });
        _registry = _registryFor(_gateway);
        _sourceTerminal = new GatewayTestSourceTerminal();
        _token = new GatewayTestToken();

        _directory.setIsTerminalOf({
            projectId: _SOURCE_PROJECT_ID, terminal: IJBTerminal(address(_sourceTerminal)), flag: true
        });
        _directory.setPrimaryTerminalOf({
            projectId: _SOURCE_PROJECT_ID, token: address(_token), terminal: IJBTerminal(address(_sourceTerminal))
        });
        _directory.setPrimaryTerminalOf({
            projectId: _SOURCE_PROJECT_ID,
            token: JBConstants.NATIVE_TOKEN,
            terminal: IJBTerminal(address(_sourceTerminal))
        });

        _token.mint(address(_sourceTerminal), _AMOUNT);
        vm.deal(address(_sourceTerminal), _AMOUNT);
    }

    /// @notice Checks that every retained fee remains fully backed by its original input amount.
    /// @param amount The nonzero original input amount to retain.
    /// @param sourceProjectId The nonzero project identifier carried in fee metadata.
    function testFuzz_failedFeeConservesOriginalInput(uint128 amount, uint64 sourceProjectId) public {
        // Every retained fee remains fully backed by its original input amount.
        vm.assume(amount != 0 && sourceProjectId != 0);
        _token.mint(address(_sourceTerminal), amount);

        _sourceTerminal.payFee({
            feeTerminal: _registry, token: address(_token), amount: amount, sourceProjectId: sourceProjectId
        });

        JBPendingRouterTerminalCall memory call =
            _feeCall({paymentToken: address(_token), amount: amount, payer: address(_sourceTerminal)});
        call.sourceProjectId = sourceProjectId;
        assertFalse(_sourceTerminal.feeWasForgiven());
        assertEq(_gateway.pendingCallCommitmentOf(_ID), _commitmentOf(call), "commitment must bind the retained fee");
        assertEq(_token.balanceOf(address(_gateway)), amount);
        assertEq(_token.balanceOf(address(_sourceTerminal)), _AMOUNT);
        assertEq(_token.balanceOf(address(_registry)), 0);
        assertEq(_token.balanceOf(address(_router)), 0);
    }

    /// @notice Checks that a retained add-to-balance call settles using its original operation.
    function test_addToBalancePayoutUsesTheSameRetentionAndRetryPath() public {
        // A retained add-to-balance call settles using its original operation.
        _sourceTerminal.sendPayout({
            terminal: _registry,
            destinationProjectId: _DESTINATION_PROJECT_ID,
            token: address(_token),
            amount: _AMOUNT,
            sourceProjectId: _SOURCE_PROJECT_ID,
            preferAddToBalance: true
        });

        assertFalse(_sourceTerminal.payoutWasNullified(), "gateway should absorb add-to-balance failure");
        assertEq(
            _gateway.pendingCallCommitmentOf(_ID),
            _commitmentOf(_payoutCall(address(_token), true)),
            "pending operation should remain add-to-balance"
        );

        _router.setMode(0);
        _process(_ID, _payoutCall(address(_token), true));

        assertEq(_token.balanceOf(address(_router)), _AMOUNT, "retry should settle the payout");
        assertEq(_gateway.pendingCallCommitmentOf(_ID), bytes32(0), "successful retry should delete pending state");
    }

    /// @notice Checks that changing a failure class preserves the highest attempted gas budget.
    function test_budgetFloorNeverDropsAfterClassChange() public {
        // Changing a failure class preserves the highest attempted gas budget.
        GatewayGasHarness harness = new GatewayGasHarness();
        // A real error surfaced only at 10M, after an exhaustion at 5M: the next minimum stays at 10M.
        JBPendingRouterTerminalCallFailure memory failure = JBPendingRouterTerminalCallFailure({
            count: 1, errorHash: keccak256("some route error"), lastFailureAt: 0, highestGasLimit: 10_000_000
        });
        uint256 maximumGasLimit = 15_000_000;
        assertEq(
            harness.qualifiedGasLimitFor({failure: failure, requestedGasLimit: 0, maximumGasLimit: maximumGasLimit}),
            10_000_000,
            "the floor is the highest budget already tried"
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalGateway.JBRouterTerminalGateway_RetryGasLimitTooLow.selector, 5_000_000, 10_000_000
            )
        );
        harness.qualifiedGasLimitFor({failure: failure, requestedGasLimit: 5_000_000, maximumGasLimit: maximumGasLimit});
    }

    /// @notice Checks that a token callback cannot create a pending claim without matching custody.
    function test_callbackTokenCannotOvercreditPooledCustody() public {
        // A token callback cannot create a pending claim without matching custody.
        uint256 attackerAmount = 100;
        uint256 victimAmount = 1000;
        GatewayCallbackToken callbackToken = new GatewayCallbackToken();
        GatewayReentrantPayer attacker = new GatewayReentrantPayer();

        callbackToken.configure({gatewayAddress: address(_gateway), callbackAddress: address(attacker)});
        callbackToken.mint({account: address(_sourceTerminal), amount: victimAmount});
        callbackToken.mint({account: address(attacker), amount: attackerAmount * 2});

        _sourceTerminal.payFee({
            feeTerminal: _registry,
            token: address(callbackToken),
            amount: victimAmount,
            sourceProjectId: _SOURCE_PROJECT_ID
        });
        attacker.attack({gatewayToUse: _gateway, tokenToUse: callbackToken, amount: attackerAmount});

        assertTrue(attacker.reentryReverted(), "nested intake should revert inside the callback");
        assertEq(_gateway.pendingCallCount(), 2, "the callback must not create an over-credited pending call");
        assertEq(
            _gateway.pendingCallCommitmentOf(_ID),
            _commitmentOf(
                _feeCall({paymentToken: address(callbackToken), amount: victimAmount, payer: address(_sourceTerminal)})
            ),
            "victim claim changed"
        );
        assertEq(
            _gateway.pendingCallCommitmentOf(bytes32(uint256(2))),
            _commitmentOf(
                _feeCall({paymentToken: address(callbackToken), amount: attackerAmount, payer: address(attacker)})
            ),
            "attacker claim was inflated"
        );
        assertEq(
            callbackToken.balanceOf(address(_gateway)), victimAmount + attackerAmount, "custody must cover every claim"
        );
    }

    /// @notice Checks that token intake prevents a callback from spending another pending call's custody.
    function test_callbackTokenCannotSettlePendingCallDuringIntake() public {
        // Token intake prevents a callback from spending another pending call's custody.
        GatewayCallbackToken callbackToken = new GatewayCallbackToken();
        GatewayCallbackSettler settler = new GatewayCallbackSettler();
        JBPendingRouterTerminalCall memory oldCall =
            _feeCall({paymentToken: address(callbackToken), amount: _AMOUNT, payer: address(_sourceTerminal)});

        callbackToken.mint({account: address(_sourceTerminal), amount: _AMOUNT});
        _queueFee(address(callbackToken));
        assertEq(_gateway.pendingCallCommitmentOf(_ID), _commitmentOf(oldCall), "old fee should be pending");

        // The route is healthy again, so the callback's settlement attempt would otherwise move the old custody out
        // while the new deposit's balance delta is still being measured.
        _router.setMode(0);
        callbackToken.configure({gatewayAddress: address(_gateway), callbackAddress: address(settler)});
        callbackToken.mint({account: address(settler), amount: 2 * _AMOUNT});
        settler.deposit({gatewayToUse: _gateway, tokenToUse: callbackToken, pendingCall: oldCall, amount: 2 * _AMOUNT});

        assertTrue(settler.settlementReverted(), "settling a pending call inside intake must revert");
        assertEq(_gateway.pendingCallCommitmentOf(_ID), _commitmentOf(oldCall), "old fee must stay pending");
        assertEq(_gateway.pendingCallCount(), 1, "the healthy deposit should settle without a new record");
        assertEq(callbackToken.balanceOf(address(_router)), 2 * _AMOUNT, "the whole new deposit should route");
        assertEq(callbackToken.balanceOf(address(_gateway)), _AMOUNT, "custody must equal the sole pending claim");
    }

    /// @notice Checks that retry escalation respects the executable chain ceiling and rejects invalid budgets.
    function test_chainAwareGasCapBoundsOtherwiseUnexecutableEscalation() public {
        // Retry escalation respects the executable chain ceiling and rejects invalid budgets.
        GatewayGasHarness harness = new GatewayGasHarness();
        uint256 maximumGasLimit = 11_000_000;
        JBPendingRouterTerminalCallFailure memory failure = JBPendingRouterTerminalCallFailure({
            count: 2, errorHash: harness.gasExhaustedErrorHash(), lastFailureAt: 0, highestGasLimit: 0
        });

        assertEq(
            harness.qualifiedGasLimitFor({failure: failure, requestedGasLimit: 0, maximumGasLimit: maximumGasLimit}),
            maximumGasLimit,
            "the live-chain cap should replace an impossible 15M escalation"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalGateway.JBRouterTerminalGateway_RetryGasLimitTooHigh.selector,
                maximumGasLimit + 1,
                maximumGasLimit
            )
        );
        harness.qualifiedGasLimitFor({
            failure: failure, requestedGasLimit: maximumGasLimit + 1, maximumGasLimit: maximumGasLimit
        });

        uint256 baseGasLimit = _gateway.QUALIFIED_CALL_GAS();
        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalGateway.JBRouterTerminalGateway_BlockGasLimitTooLow.selector,
                baseGasLimit - 1,
                baseGasLimit
            )
        );
        harness.qualifiedGasLimitFor({failure: failure, requestedGasLimit: 0, maximumGasLimit: baseGasLimit - 1});
    }

    /// @notice Checks that a different error selector starts a fresh qualification streak.
    function test_changedErrorResetsMatchingFailureStreak() public {
        // A different error selector starts a fresh qualification streak.
        _queueFee(address(_token));
        _process(_ID, _feeCall());

        JBPendingRouterTerminalCallFailure memory first = _gateway.pendingCallFailureOf(_ID);
        assertEq(first.count, 1);

        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        _router.setMode(2);
        _process(_ID, _feeCall());

        JBPendingRouterTerminalCallFailure memory changed = _gateway.pendingCallFailureOf(_ID);
        assertEq(changed.count, 1, "a different exact error must restart qualification");
        assertNotEq(changed.errorHash, first.errorHash, "different custom errors must have different fingerprints");

        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        _process(_ID, _feeCall());
        assertEq(_gateway.pendingCallFailureOf(_ID).count, 2, "the new matching error can start a fresh streak");
    }

    /// @notice Checks that empty reverts exhaust the retry gas ladder before qualifying for refund.
    function test_cheapEmptyRevertsClimbTheGasLadderThenRefund() public {
        // Empty reverts exhaust the retry gas ladder before qualifying for refund.
        // A bare `revert()` is indistinguishable from out-of-gas below the router, so it is treated as the gas class:
        // it climbs the budget ladder and refunds only once the ceiling has been tried.
        _router.setMode(6);
        _queueFee(address(_token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());

        JBPendingRouterTerminalCallFailure memory failure = _gateway.pendingCallFailureOf(_ID);
        assertEq(failure.errorHash, new GatewayGasHarness().gasExhaustedErrorHash(), "empty data is the gas class");
        assertEq(failure.count, 3);
        assertEq(failure.highestGasLimit, 3 * _gateway.QUALIFIED_CALL_GAS(), "three rungs were climbed");

        (bool wasRefunded,) = _finalize(_ID, _feeCall());

        assertTrue(wasRefunded, "a route that fails empty at the ceiling is refunded");
        assertEq(_sourceTerminal.credited(_SOURCE_PROJECT_ID, address(_token)), _AMOUNT);
    }

    /// @notice Checks that malformed payer introspection cannot defeat explicit source-project retention.
    function test_dirtyERC165ResponseDoesNotAffectSourceProjectRetention() public {
        // Malformed payer introspection cannot defeat explicit source-project retention.
        GatewayDirtyERC165Payer payer = new GatewayDirtyERC165Payer();
        _token.mint({account: address(payer), amount: _AMOUNT});

        vm.startPrank(address(payer));
        _token.approve({spender: address(_gateway), value: _AMOUNT});
        uint256 beneficiaryTokenCount = _gateway.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(_token),
            amount: _AMOUNT,
            beneficiary: address(payer),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(_SOURCE_PROJECT_ID)
        });
        vm.stopPrank();

        assertEq(beneficiaryTokenCount, 0, "failed route should be retained");
        assertEq(_gateway.pendingCallCount(), 1, "payer ERC-165 behavior must not affect explicit retention");
        assertEq(
            _gateway.pendingCallCommitmentOf(_ID),
            _commitmentOf(_feeCall({paymentToken: address(_token), amount: _AMOUNT, payer: address(payer)})),
            "original payer should remain observable"
        );
        assertEq(_token.balanceOf(address(_gateway)), _AMOUNT, "retained input must remain fully collateralized");
    }

    /// @notice Checks that changing arguments within one error class preserves refund qualification.
    function test_dynamicErrorArgumentsDoNotResetMatchingFailureStreak() public {
        // Changing arguments within one error class preserves refund qualification.
        _router.setMode(5);
        _router.setFailureArgument(1);
        _queueFee(address(_token));
        _process(_ID, _feeCall());

        JBPendingRouterTerminalCallFailure memory first = _gateway.pendingCallFailureOf(_ID);
        assertEq(first.count, 1);

        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        _router.setFailureArgument(2);
        _process(_ID, _feeCall());

        JBPendingRouterTerminalCallFailure memory second = _gateway.pendingCallFailureOf(_ID);
        assertEq(second.count, 2, "arguments from the same custom error must not reset qualification");
        assertEq(second.errorHash, first.errorHash, "the failure class should encode only the selector");
    }

    /// @notice Checks that a payer returning empty introspection data can complete a direct payment.
    function test_emptyFallbackPayerIsResolvedNotReverted() public {
        // A payer returning empty introspection data can complete a direct payment.
        // A caller whose fallback accepts `originalPayer()` with empty data must resolve to itself, not revert.
        GatewayEmptyFallbackPayer payer = new GatewayEmptyFallbackPayer();
        _token.mint(address(payer), _AMOUNT);
        _router.setMode(0);

        bool success = payer.payThrough({
            gateway: _gateway,
            token: address(_token),
            amount: _AMOUNT,
            metadata: abi.encodePacked(uint256(_SOURCE_PROJECT_ID))
        });
        assertTrue(success, "an empty-fallback payer must be able to pay directly");
        assertEq(_token.balanceOf(address(_router)), _AMOUNT);
    }

    /// @notice Checks that an ERC-20 payment cannot accidentally strand an accompanying native-token value.
    function test_erc20PayWithMsgValueReverts() public {
        // An ERC-20 payment cannot accidentally strand an accompanying native-token value.
        _token.mint(address(this), _AMOUNT);
        _token.approve(address(_gateway), _AMOUNT);
        vm.deal(address(this), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(JBRouterTerminalGateway.JBRouterTerminalGateway_NoMsgValueAllowed.selector, 1)
        );
        _gateway.pay{value: 1}({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(_token),
            amount: _AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(uint256(_SOURCE_PROJECT_ID))
        });
        assertEq(address(_gateway).balance, 0, "stray native value must never be accepted alongside an ERC-20");
    }

    /// @notice Checks that automatic gas escalation settles a route requiring more than the base budget.
    function test_expandableRetryGasSettlesRouteAboveDefaultBudget() public {
        // Automatic gas escalation settles a route requiring more than the base budget.
        _queueFee(address(_token));
        _router.setMode(7);

        _process(_ID, _feeCall());

        assertEq(_gateway.pendingCallFailureOf(_ID).count, 1, "the exhausted base budget should start escalation");
        assertEq(
            _gateway.pendingCallCommitmentOf(_ID), _commitmentOf(_feeCall()), "gas exhaustion must preserve custody"
        );

        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        uint256 beneficiaryTokenCount = _process(_ID, _feeCall());

        assertEq(beneficiaryTokenCount, _AMOUNT, "the automatically expanded retry should settle the healthy route");
        assertEq(_gateway.pendingCallCommitmentOf(_ID), bytes32(0), "settled retry must clear pending state");
        assertEq(_token.balanceOf(address(_gateway)), 0, "settled retry must consume custody");
    }

    /// @notice Checks that an ordinary failed add-to-balance call rolls back without retaining funds.
    function test_failedDirectAddToBalanceRevertsSynchronously() public {
        // An ordinary failed add-to-balance call rolls back without retaining funds.
        _token.mint(address(this), _AMOUNT);
        _token.approve(address(_gateway), _AMOUNT);

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RouteFailed.selector);
        _gateway.addToBalanceOf({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(_token),
            amount: _AMOUNT,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: ""
        });

        assertEq(_gateway.pendingCallCount(), 0, "ordinary add-to-balance failure must not be retained");
        assertEq(_token.balanceOf(address(this)), _AMOUNT, "revert should restore the payer's token");
    }

    /// @notice Checks that an ordinary failed payment rolls back without retaining funds.
    function test_failedDirectPayRevertsSynchronously() public {
        // An ordinary failed payment rolls back without retaining funds.
        _token.mint(address(this), _AMOUNT);
        _token.approve(address(_gateway), _AMOUNT);

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RouteFailed.selector);
        _gateway.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(_token),
            amount: _AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        assertEq(_gateway.pendingCallCount(), 0, "ordinary zero-minimum pay failure must not be retained");
        assertEq(_token.balanceOf(address(this)), _AMOUNT, "revert should restore the payer's token");
    }

    /// @notice Checks that finalization restarts qualification when the failure class changes.
    function test_finalChangedErrorResetsWithoutRefunding() public {
        // Finalization restarts qualification when the failure class changes.
        _queueFee(address(_token));
        _qualifyWithMatchingFailures();
        bytes32 qualifiedError = _gateway.pendingCallFailureOf(_ID).errorHash;

        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        _router.setMode(2);
        (bool wasRefunded,) = _finalize(_ID, _feeCall());

        JBPendingRouterTerminalCallFailure memory changed = _gateway.pendingCallFailureOf(_ID);
        assertFalse(wasRefunded, "changed failure must remain retryable");
        assertEq(changed.count, 1, "changed final error must reset the streak");
        assertNotEq(changed.errorHash, qualifiedError, "final error should record the new fingerprint");
        assertEq(_token.balanceOf(address(_gateway)), _AMOUNT, "gateway should retain custody");
        assertEq(
            _sourceTerminal.credited(_SOURCE_PROJECT_ID, address(_token)), 0, "source project must not be refunded"
        );
    }

    /// @notice Checks that a qualified add-to-balance failure refunds its source project.
    function test_finalMatchingAddToBalanceErrorRefundsOriginalProject() public {
        // A qualified add-to-balance failure refunds its source project.
        _sourceTerminal.sendPayout({
            terminal: _registry,
            destinationProjectId: _DESTINATION_PROJECT_ID,
            token: address(_token),
            amount: _AMOUNT,
            sourceProjectId: _SOURCE_PROJECT_ID,
            preferAddToBalance: true
        });
        _qualifyWithMatchingFailures(_payoutCall(address(_token), true));
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());

        (bool wasRefunded,) = _finalize(_ID, _payoutCall(address(_token), true));

        assertTrue(wasRefunded);
        assertEq(_sourceTerminal.credited(_SOURCE_PROJECT_ID, address(_token)), _AMOUNT);
        assertEq(_token.balanceOf(address(_gateway)), 0);
    }

    /// @notice Checks that a qualified payment failure refunds its source project.
    function test_finalMatchingErrorRefundsOriginalProject() public {
        // A qualified payment failure refunds its source project.
        _queueFee(address(_token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());

        (bool wasRefunded, uint256 beneficiaryTokenCount) = _finalize(_ID, _feeCall());

        assertTrue(wasRefunded, "same final error should authorize refund");
        assertEq(beneficiaryTokenCount, 0);
        assertEq(_sourceTerminal.credited(_SOURCE_PROJECT_ID, address(_token)), _AMOUNT, "project should be credited");
        assertEq(_token.balanceOf(address(_sourceTerminal)), _AMOUNT, "source terminal should reclaim the input token");
        assertEq(_token.balanceOf(address(_gateway)), 0, "gateway custody should clear");
        assertEq(_gateway.pendingCallCommitmentOf(_ID), bytes32(0), "pending state should clear");
    }

    /// @notice Checks that a qualified native-token failure restores its source project balance.
    function test_finalMatchingNativePayoutErrorRefundsOriginalProject() public {
        // A qualified native-token failure restores its source project balance.
        _sourceTerminal.sendPayout({
            terminal: _registry,
            destinationProjectId: _DESTINATION_PROJECT_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: _AMOUNT,
            sourceProjectId: _SOURCE_PROJECT_ID,
            preferAddToBalance: true
        });
        _qualifyWithMatchingFailures(_payoutCall(JBConstants.NATIVE_TOKEN, true));
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());

        (bool wasRefunded,) = _finalize(_ID, _payoutCall(JBConstants.NATIVE_TOKEN, true));

        assertTrue(wasRefunded);
        assertEq(
            _sourceTerminal.credited(_SOURCE_PROJECT_ID, JBConstants.NATIVE_TOKEN),
            _AMOUNT,
            "native refund should credit"
        );
        assertEq(address(_gateway).balance, 0, "native gateway custody should clear");
    }

    /// @notice Checks that a rejected refund preserves both custody and its completed qualification.
    function test_finalRefundFailureRollsBackAndPreservesQualification() public {
        // A rejected refund preserves both custody and its completed qualification.
        _queueFee(address(_token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        _sourceTerminal.setRejectRefund(true);

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RefundFailed.selector);
        _finalize(_ID, _feeCall());

        assertEq(_gateway.pendingCallFailureOf(_ID).count, 3, "failed refund must preserve qualification");
        assertEq(
            _gateway.pendingCallCommitmentOf(_ID), _commitmentOf(_feeCall()), "failed refund must restore pending state"
        );
        assertEq(_token.balanceOf(address(_gateway)), _AMOUNT, "failed refund must preserve custody");
    }

    /// @notice Checks that a rejected source-terminal refund can reach the current primary terminal.
    function test_finalRefundFallsBackToCurrentPrimaryTerminal() public {
        // A rejected source-terminal refund can reach the current primary terminal.
        _queueFee(address(_token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());

        GatewayTestSourceTerminal primaryTerminal = new GatewayTestSourceTerminal();
        _sourceTerminal.setRejectRefund(true);
        _directory.setPrimaryTerminalOf({
            projectId: _SOURCE_PROJECT_ID, token: address(_token), terminal: IJBTerminal(address(primaryTerminal))
        });

        (bool wasRefunded,) = _finalize(_ID, _feeCall());

        assertTrue(wasRefunded, "current primary terminal should accept the autonomous fallback");
        assertEq(primaryTerminal.credited(_SOURCE_PROJECT_ID, address(_token)), _AMOUNT);
        assertEq(_token.balanceOf(address(_gateway)), 0, "successful fallback must clear custody");
    }

    /// @notice Checks that refund discovery avoids forwarding cycles and finds a registered alternative.
    function test_finalRefundSkipsCircularPrimaryAndUsesRegisteredAlternative() public {
        // Refund discovery avoids forwarding cycles and finds a registered alternative.
        _queueFee(address(_token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());

        GatewayTestSourceTerminal alternativeTerminal = new GatewayTestSourceTerminal();
        _directory.setIsTerminalOf({
            projectId: _SOURCE_PROJECT_ID, terminal: IJBTerminal(address(_sourceTerminal)), flag: false
        });
        _directory.setPrimaryTerminalOf({
            projectId: _SOURCE_PROJECT_ID, token: address(_token), terminal: IJBTerminal(address(_registry))
        });

        IJBTerminal[] memory terminals = new IJBTerminal[](2);
        terminals[0] = IJBTerminal(address(_registry));
        terminals[1] = IJBTerminal(address(alternativeTerminal));
        _directory.setTerminalsOf({projectId: _SOURCE_PROJECT_ID, terminals: terminals});

        (bool wasRefunded,) = _finalize(_ID, _feeCall());

        assertTrue(wasRefunded, "the registered non-circular terminal should receive the refund");
        assertEq(alternativeTerminal.credited(_SOURCE_PROJECT_ID, address(_token)), _AMOUNT);
        assertEq(_token.balanceOf(address(_gateway)), 0, "successful alternative refund must clear custody");
    }

    /// @notice Checks that malformed forwarding data cannot block a healthy refund alternative.
    function test_finalRefundSurvivesMalformedOriginalTerminalProbe() public {
        // Malformed forwarding data cannot block a healthy refund alternative.
        _sourceTerminal = new GatewayMalformedProbeTerminal();
        _directory.setIsTerminalOf({
            projectId: _SOURCE_PROJECT_ID, terminal: IJBTerminal(address(_sourceTerminal)), flag: true
        });
        _token.mint({account: address(_sourceTerminal), amount: _AMOUNT});
        _queueFee(address(_token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());

        // The original terminal both answers the probe with a non-address word and rejects the refund, so the search
        // has to get past it to reach the healthy primary.
        _sourceTerminal.setRejectRefund(true);
        GatewayTestSourceTerminal healthyTerminal = new GatewayTestSourceTerminal();
        _directory.setIsTerminalOf({
            projectId: _SOURCE_PROJECT_ID, terminal: IJBTerminal(address(healthyTerminal)), flag: true
        });
        _directory.setPrimaryTerminalOf({
            projectId: _SOURCE_PROJECT_ID, token: address(_token), terminal: IJBTerminal(address(healthyTerminal))
        });

        (bool wasRefunded,) = _finalize(_ID, _feeCall());

        assertTrue(wasRefunded, "a malformed probe on one candidate must not block the healthy primary");
        assertEq(healthyTerminal.credited(_SOURCE_PROJECT_ID, address(_token)), _AMOUNT);
        assertEq(_token.balanceOf(address(_gateway)), 0, "successful primary refund must clear custody");
    }

    /// @notice Checks that refund discovery uses the current primary after the source terminal is removed.
    function test_finalRefundUsesCurrentPrimaryWhenOriginalTerminalWasRemoved() public {
        // Refund discovery uses the current primary after the source terminal is removed.
        _queueFee(address(_token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());

        GatewayTestSourceTerminal primaryTerminal = new GatewayTestSourceTerminal();
        _directory.setIsTerminalOf({
            projectId: _SOURCE_PROJECT_ID, terminal: IJBTerminal(address(_sourceTerminal)), flag: false
        });
        _directory.setPrimaryTerminalOf({
            projectId: _SOURCE_PROJECT_ID, token: address(_token), terminal: IJBTerminal(address(primaryTerminal))
        });

        (bool wasRefunded,) = _finalize(_ID, _feeCall());

        assertTrue(wasRefunded, "removed source terminal should be replaced by the current primary");
        assertEq(
            _sourceTerminal.credited(_SOURCE_PROJECT_ID, address(_token)), 0, "removed terminal must not be credited"
        );
        assertEq(primaryTerminal.credited(_SOURCE_PROJECT_ID, address(_token)), _AMOUNT);
    }

    /// @notice Checks that a healthy final attempt settles to the destination instead of refunding.
    function test_finalSuccessfulAttemptSettlesWithoutRefund() public {
        // A healthy final attempt settles to the destination instead of refunding.
        _queueFee(address(_token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        _router.setMode(0);

        (bool wasRefunded, uint256 beneficiaryTokenCount) = _finalize(_ID, _feeCall());

        assertFalse(wasRefunded);
        assertEq(beneficiaryTokenCount, _AMOUNT);
        assertEq(_token.balanceOf(address(_router)), _AMOUNT, "final attempt should settle into router");
        assertEq(_token.balanceOf(address(_gateway)), 0, "gateway custody should clear");
        assertEq(_sourceTerminal.credited(_SOURCE_PROJECT_ID, address(_token)), 0, "successful route must not refund");
    }

    /// @notice Checks that finalization rejects an incomplete matching-failure streak.
    function test_finalizeBeforeThreeMatchingFailuresReverts() public {
        // Finalization rejects an incomplete matching-failure streak.
        _queueFee(address(_token));
        _process(_ID, _feeCall());
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());

        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalGateway.JBRouterTerminalGateway_PendingCallNotFinalizable.selector, _ID, uint32(1)
            )
        );
        _finalize(_ID, _feeCall());

        assertEq(_gateway.pendingCallCommitmentOf(_ID), _commitmentOf(_feeCall()), "custody must remain pending");
        assertEq(_token.balanceOf(address(_gateway)), _AMOUNT, "an early finalize must not move custody");
    }

    /// @notice Checks that finalization accepts a sufficient explicit gas budget and settles a healthy call.
    function test_finalizeWithGasSettlesQualifiedCall() public {
        // Finalization accepts a sufficient explicit gas budget and settles a healthy call.
        _queueFee(address(_token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        _router.setMode(0);

        (bool wasRefunded, uint256 beneficiaryTokenCount) = _gateway.finalizePendingCallWithGas({
            id: _ID,
            call: _feeCall(),
            memo: "",
            metadata: abi.encodePacked(uint256(_SOURCE_PROJECT_ID)),
            gasLimit: _gateway.QUALIFIED_CALL_GAS() + 1
        });

        assertFalse(wasRefunded, "a recovered route settles rather than refunds");
        assertEq(beneficiaryTokenCount, _AMOUNT);
        assertEq(_token.balanceOf(address(_router)), _AMOUNT, "the explicit-gas final attempt must deliver custody");
        assertEq(_gateway.pendingCallCommitmentOf(_ID), bytes32(0));
        assertEq(_gateway.pendingCallFailureOf(_ID).count, 0);
    }

    /// @notice Checks that an explicit retry budget must follow the gas-exhaustion escalation floor.
    function test_gasExhaustionRequiresEscalatedCustomBudget() public {
        // An explicit retry budget must follow the gas-exhaustion escalation floor.
        _router.setMode(3);
        _queueFee(address(_token));
        _process(_ID, _feeCall());

        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        uint256 baseGasLimit = _gateway.QUALIFIED_CALL_GAS();
        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RetryGasLimitTooLow.selector);
        _gateway.processPendingCallWithGas({
            id: _ID, call: _feeCall(), gasLimit: baseGasLimit, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)
        });

        assertEq(_gateway.pendingCallFailureOf(_ID).count, 1, "an undersized custom retry must not advance custody");
    }

    /// @notice Checks that a failed Permit2 approval preserves payment through an existing token allowance.
    function test_gatewayPermitFailureFallsBackToDirectAllowance() public {
        // A failed Permit2 approval preserves payment through an existing token allowance.
        IPermit2 revertingPermit2 = IPermit2(makeAddr("revertingPermit2"));
        vm.etch(address(revertingPermit2), hex"00");
        JBRouterTerminalGateway compatibleGateway = new JBRouterTerminalGateway({
            directory: IJBDirectory(address(_directory)),
            permit2: revertingPermit2,
            router: IJBRouterTerminal(address(_router)),
            trustedForwarder: address(0)
        });
        address payer = makeAddr("payer");
        _token.mint({account: payer, amount: _AMOUNT});
        vm.prank(payer);
        _token.approve({spender: address(compatibleGateway), value: _AMOUNT});

        JBSingleAllowance memory allowance = JBSingleAllowance({
            sigDeadline: block.timestamp + 1 hours,
            // `_AMOUNT` is a fixed test value far below the Permit2 width.
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint160(_AMOUNT),
            expiration: uint48(block.timestamp + 1 hours),
            nonce: 0,
            signature: hex"1234"
        });
        bytes memory metadata = JBMetadataResolver.addToMetadata(
            "", JBMetadataResolver.getId("permit2", address(compatibleGateway)), abi.encode(allowance)
        );
        bytes memory reason = "invalid permit";
        vm.mockCallRevert(address(revertingPermit2), bytes(""), reason);

        _router.setMode(0);
        vm.recordLogs();
        vm.prank(payer);
        uint256 beneficiaryTokenCount = compatibleGateway.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(_token),
            amount: _AMOUNT,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });

        bytes32 permitFailureTopic = keccak256("Permit2AllowanceFailed(address,address,bytes,address)");
        bool sawPermitFailure;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(compatibleGateway) && logs[i].topics[0] == permitFailureTopic
                    && logs[i].topics[1] == bytes32(uint256(uint160(address(_token))))
                    && logs[i].topics[2] == bytes32(uint256(uint160(payer)))
            ) {
                sawPermitFailure = true;
            }
        }

        assertEq(beneficiaryTokenCount, _AMOUNT, "direct allowance should survive a failed Permit2 approval");
        assertTrue(sawPermitFailure, "failed Permit2 approval should remain observable");
        assertEq(_token.balanceOf(address(_router)), _AMOUNT, "fallback payment should settle through the router");
    }

    /// @notice Checks that forwarded payments apply Permit2 permissions to the original sender.
    function test_gatewayPreservesERC2771AndPermit2PaymentSurface() public {
        // Forwarded payments apply Permit2 permissions to the original sender.
        GatewayTestPermit2 permit2 = new GatewayTestPermit2();
        GatewayTestTrustedForwarder forwarder = new GatewayTestTrustedForwarder();
        JBRouterTerminalGateway compatibleGateway = new JBRouterTerminalGateway({
            directory: IJBDirectory(address(_directory)),
            permit2: IPermit2(address(permit2)),
            router: IJBRouterTerminal(address(_router)),
            trustedForwarder: address(forwarder)
        });
        address payer = makeAddr("payer");
        _token.mint({account: payer, amount: _AMOUNT});
        vm.prank(payer);
        _token.approve({spender: address(permit2), value: _AMOUNT});

        JBSingleAllowance memory allowance = JBSingleAllowance({
            sigDeadline: block.timestamp + 1 hours,
            // `_AMOUNT` is a fixed test value far below the Permit2 width.
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint160(_AMOUNT),
            expiration: uint48(block.timestamp + 1 hours),
            nonce: 0,
            signature: hex"1234"
        });
        bytes4 permit2MetadataId = JBMetadataResolver.getId("permit2", address(compatibleGateway));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", permit2MetadataId, abi.encode(allowance));
        bytes memory callData = abi.encodeCall(
            compatibleGateway.pay, (_DESTINATION_PROJECT_ID, address(_token), _AMOUNT, payer, 0, "", metadata)
        );

        _router.setMode(0);
        bytes memory result =
            forwarder.forward({target: address(compatibleGateway), data: callData, originalSender: payer});

        assertEq(abi.decode(result, (uint256)), _AMOUNT, "forwarded payment should return the router result");
        assertEq(permit2.lastOwner(), payer, "Permit2 owner must be the ERC-2771 sender");
        assertEq(permit2.lastSpender(), address(compatibleGateway), "Permit2 must authorize the gateway");
        assertEq(_token.balanceOf(address(_router)), _AMOUNT, "Permit2 payment should settle through the router");
        assertTrue(
            compatibleGateway.supportsInterface(type(IJBPermitTerminal).interfaceId),
            "resolved gateway must advertise Permit2"
        );
    }

    /// @notice Checks that successful routing consumes the input without creating pending state.
    function test_initialSuccessDoesNotCreatePendingCall() public {
        // Successful routing consumes the input without creating pending state.
        _router.setMode(0);
        _queueFee(address(_token));

        assertFalse(_sourceTerminal.feeWasForgiven());
        assertEq(_gateway.pendingCallCount(), 0, "successful route should not issue a pending id");
        assertEq(_token.balanceOf(address(_router)), _AMOUNT);
        assertEq(_token.balanceOf(address(_gateway)), 0);
    }

    /// @notice Checks that malformed router success data cannot leave an unbacked pending claim.
    function test_malformedSuccessfulPayReturnCannotCreateUnbackedPendingCall() public {
        // Malformed router success data cannot leave an unbacked pending claim.
        _router.setMode(4);
        _queueFee(address(_token));

        assertFalse(_sourceTerminal.feeWasForgiven());
        assertEq(_gateway.pendingCallCount(), 0, "successful side effects must not be recorded as failed custody");
        assertEq(_token.balanceOf(address(_router)), _AMOUNT, "router retained the successfully pulled input");
        assertEq(_token.balanceOf(address(_gateway)), 0, "gateway has no retained input to represent");
    }

    /// @notice Checks that repeated exhaustion reaches the executable ceiling before refunding.
    function test_matchingGasExhaustionEscalatesAndEventuallyRefunds() public {
        // Repeated exhaustion reaches the executable ceiling before refunding.
        _router.setMode(3);
        _queueFee(address(_token));

        _process(_ID, _feeCall());
        JBPendingRouterTerminalCallFailure memory first = _gateway.pendingCallFailureOf(_ID);
        assertEq(first.count, 1, "the first exhausted qualified budget should start the streak");

        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        _process(_ID, _feeCall());
        JBPendingRouterTerminalCallFailure memory second = _gateway.pendingCallFailureOf(_ID);
        assertEq(second.count, 2, "the second exhausted, larger budget should continue the streak");
        assertEq(second.errorHash, first.errorHash, "gas exhaustion must have one stable failure fingerprint");

        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        _process(_ID, _feeCall());
        assertEq(_gateway.pendingCallFailureOf(_ID).count, 3, "the third larger budget should qualify finalization");

        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        (bool wasRefunded,) = _finalize(_ID, _feeCall());

        assertTrue(wasRefunded, "four escalating exhausted budgets should prove the sink and release custody");
        assertEq(_sourceTerminal.credited(_SOURCE_PROJECT_ID, address(_token)), _AMOUNT);
        assertEq(_token.balanceOf(address(_gateway)), 0, "final refund must clear retained custody");
    }

    /// @notice Checks that settling one pending call preserves the custody backing another.
    function test_multiplePendingCallsKeepCustodySeparated() public {
        // Settling one pending call preserves the custody backing another.
        _token.mint(address(_sourceTerminal), _AMOUNT);
        _queueFee(address(_token));
        _queueFee(address(_token));

        assertEq(_gateway.pendingCallCount(), 2);
        assertEq(_token.balanceOf(address(_gateway)), _AMOUNT * 2);

        _router.setMode(0);
        _process(_ID, _feeCall());

        assertEq(_gateway.pendingCallCommitmentOf(_ID), bytes32(0), "first pending call should settle");
        assertEq(
            _gateway.pendingCallCommitmentOf(bytes32(uint256(2))),
            _commitmentOf(_feeCall()),
            "second pending call should remain"
        );
        assertEq(_token.balanceOf(address(_gateway)), _AMOUNT, "second pending input must remain in custody");
        assertEq(_token.balanceOf(address(_router)), _AMOUNT, "only first pending input should settle");
    }

    /// @notice Checks that an empty revert from a nested gas failure triggers a larger retry budget.
    function test_nestedGasExhaustionEscalatesInsteadOfRefunding() public {
        // An empty revert from a nested gas failure triggers a larger retry budget.
        // Out-of-gas one frame below the router bubbles as an empty revert while the router keeps its sixty-fourth, so
        // gas spent here never reaches the budget. It must still climb the ladder rather than "prove" the route dead.
        _queueFee(address(_token));
        _router.setMode(8);

        _process(_ID, _feeCall());
        JBPendingRouterTerminalCallFailure memory first = _gateway.pendingCallFailureOf(_ID);
        assertEq(first.errorHash, new GatewayGasHarness().gasExhaustedErrorHash(), "nested OOG is gas class");
        assertEq(first.count, 1);
        assertEq(first.highestGasLimit, _gateway.QUALIFIED_CALL_GAS(), "the base budget was forwarded");

        // The next default attempt is forced to 10M, which is enough for the route to complete.
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        uint256 count = _process(_ID, _feeCall());
        assertEq(count, _AMOUNT, "the escalated budget settles the route");
        assertEq(_token.balanceOf(address(_router)), _AMOUNT);
        assertEq(_gateway.pendingCallCommitmentOf(_ID), bytes32(0));
    }

    /// @notice Checks that nested routing restores the allowance required by the outer call.
    function test_nestedSameTokenRouteRestoresOuterRouterAllowance() public {
        // Nested routing restores the allowance required by the outer call.
        uint256 nestedAmount = 1000;
        GatewayNestedPayer nestedPayer = new GatewayNestedPayer();
        _token.mint({account: address(nestedPayer), amount: nestedAmount});
        nestedPayer.configure({
            gatewayToUse: _gateway, routerToUse: _router, tokenToUse: _token, amountToUse: nestedAmount
        });

        _router.setMode(0);
        _router.setBeforePullCallback(address(nestedPayer));
        _sourceTerminal.sendPayout({
            terminal: _registry,
            destinationProjectId: _DESTINATION_PROJECT_ID,
            token: address(_token),
            amount: _AMOUNT,
            sourceProjectId: _SOURCE_PROJECT_ID,
            preferAddToBalance: false
        });

        assertFalse(_sourceTerminal.payoutWasNullified());
        assertEq(_gateway.pendingCallCount(), 0, "nested route must not erase the outer Router allowance");
        assertEq(_token.balanceOf(address(_router)), _AMOUNT + nestedAmount, "both same-token routes should settle");
        assertEq(_token.balanceOf(address(_gateway)), 0);
    }

    /// @notice Checks that source-project metadata opts a protocol payer into project-accounting retention.
    function test_nonTerminalPayerWithSourceProjectMetadataIsRetained() public {
        // Source-project metadata opts a protocol payer into project-accounting retention.
        GatewayProtocolFeePayer payer = new GatewayProtocolFeePayer();
        _token.mint({account: address(payer), amount: _AMOUNT});

        payer.payFee({
            feeTerminal: _registry, token: address(_token), amount: _AMOUNT, sourceProjectId: _SOURCE_PROJECT_ID
        });

        JBPendingRouterTerminalCall memory call =
            _feeCall({paymentToken: address(_token), amount: _AMOUNT, payer: address(payer)});
        assertFalse(payer.feeWasForgiven(), "Gateway custody must stay outside the protocol payer's catch boundary");
        assertEq(
            _gateway.pendingCallCommitmentOf(_ID),
            _commitmentOf(call),
            "registry should preserve the non-terminal protocol payer and its source-project opt-in"
        );
        assertEq(_token.balanceOf(address(_gateway)), _AMOUNT, "retained input must remain fully collateralized");

        _qualifyWithMatchingFailures(call);
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        (bool wasRefunded,) = _finalize(_ID, call);

        assertTrue(wasRefunded, "matching failures should refund the named source project");
        assertEq(_sourceTerminal.credited(_SOURCE_PROJECT_ID, address(_token)), _AMOUNT, "project should be credited");
        assertEq(_token.balanceOf(address(_gateway)), 0, "refunded custody should clear");
    }

    /// @notice Checks that a failed payment with a token minimum cannot enter pending custody.
    function test_nonzeroMinimumStillRevertsSynchronously() public {
        // A failed payment with a token minimum cannot enter pending custody.
        _token.mint(address(this), _AMOUNT);
        _token.approve(address(_gateway), _AMOUNT);

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RouteFailed.selector);
        _gateway.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(_token),
            amount: _AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 1,
            memo: "",
            metadata: ""
        });

        assertEq(_gateway.pendingCallCount(), 0, "gateway must not hide a non-zero minimum failure");
        assertEq(_token.balanceOf(address(this)), _AMOUNT, "revert should restore the payer's token");
    }

    /// @notice Checks that an explicit retention opt-in cannot override a beneficiary token minimum.
    function test_optedInPayWithNonzeroMinimumStillRevertsSynchronously() public {
        // An explicit retention opt-in cannot override a beneficiary token minimum.
        _token.mint(address(this), _AMOUNT);
        _token.approve(address(_gateway), _AMOUNT);

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RouteFailed.selector);
        _gateway.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(_token),
            amount: _AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 1,
            memo: "",
            metadata: abi.encodePacked(uint256(_SOURCE_PROJECT_ID))
        });

        assertEq(_gateway.pendingCallCount(), 0, "a priced minimum must never be retained even with the opt-in");
        assertEq(_token.balanceOf(address(this)), _AMOUNT);
    }

    /// @notice Checks that retained metadata stays small enough to replay within an executable transaction.
    function test_oversizedMemoIsNeverRetained() public {
        // Retained metadata stays small enough to replay within an executable transaction.
        // A retained memo is resupplied as calldata on every retry; past a few kilobytes the top retry rung could no
        // longer fit in one transaction, so such a call must fail synchronously instead of entering custody.
        _token.mint(address(this), _AMOUNT * 2);
        _token.approve(address(_gateway), _AMOUNT * 2);
        string memory memo = string(new bytes(4097));

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RouteFailed.selector);
        _gateway.pay({
            projectId: 3,
            token: address(_token),
            amount: _AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: memo,
            metadata: abi.encodePacked(uint256(_SOURCE_PROJECT_ID))
        });
        assertEq(_gateway.pendingCallCount(), 0, "an oversized memo must never be retained");

        _gateway.pay({
            projectId: 3,
            token: address(_token),
            amount: _AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: string(new bytes(4096)),
            metadata: abi.encodePacked(uint256(_SOURCE_PROJECT_ID))
        });
        assertEq(_gateway.pendingCallCount(), 1, "a memo at the cap is retained");
    }

    /// @notice Checks that a retry must supply the exact call data authenticated by its commitment.
    function test_processRejectsChangedCalldata() public {
        // A retry must supply the exact call data authenticated by its commitment.
        _queueFee(address(_token));

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_CallDataMismatch.selector);
        _gateway.processPendingCall({
            id: _ID, call: _feeCall(), memo: "changed", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)
        });

        assertEq(_gateway.pendingCallFailureOf(_ID).count, 0);
        assertEq(_token.balanceOf(address(_gateway)), _AMOUNT);
    }

    /// @notice Checks that retries cannot accelerate qualification by bypassing the required delay.
    function test_processRequiresDelayBetweenQualifiedFailures() public {
        // Retries cannot accelerate qualification by bypassing the required delay.
        _queueFee(address(_token));
        _process(_ID, _feeCall());

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_PendingCallNotReady.selector);
        _process(_ID, _feeCall());

        assertEq(_gateway.pendingCallFailureOf(_ID).count, 1);
    }

    /// @notice Checks that a fully qualified call requires finalization instead of another ordinary retry.
    function test_processRequiresFinalizerAfterThreeMatchingFailures() public {
        // A fully qualified call requires finalization instead of another ordinary retry.
        _queueFee(address(_token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_PendingCallRequiresFinalization.selector);
        _process(_ID, _feeCall());

        assertEq(_gateway.pendingCallFailureOf(_ID).count, 3);
    }

    /// @notice Checks that unknown and already settled call identifiers cannot be processed.
    function test_processUnknownIdReverts() public {
        // Unknown and already settled call identifiers cannot be processed.
        vm.expectRevert(
            abi.encodeWithSelector(JBRouterTerminalGateway.JBRouterTerminalGateway_PendingCallNotFound.selector, _ID)
        );
        _process(_ID, _feeCall());

        // A settled id is gone for good: replaying it must fail the same way.
        _queueFee(address(_token));
        _router.setMode(0);
        _process(_ID, _feeCall());
        vm.expectRevert(
            abi.encodeWithSelector(JBRouterTerminalGateway.JBRouterTerminalGateway_PendingCallNotFound.selector, _ID)
        );
        _process(_ID, _feeCall());
    }

    /// @notice Checks that registry forwarding preserves the core source terminal as the refund target.
    function test_realCoreMultiTerminalPropagatesPreferredRefundTarget() public {
        // Registry forwarding preserves the core source terminal as the refund target.
        JBMultiTerminal multiTerminal = new JBMultiTerminal({
            feelessAddresses: IJBFeelessAddresses(address(0)),
            permissions: IJBPermissions(address(0)),
            projects: IJBProjects(address(0)),
            splits: IJBSplits(address(0)),
            store: IJBTerminalStore(address(new GatewayTestTerminalStore())),
            tokens: IJBTokens(address(0)),
            permit2: IPermit2(address(0)),
            trustedForwarder: address(0)
        });

        assertTrue(multiTerminal.supportsInterface(type(IJBTerminal).interfaceId));

        _token.mint({account: address(multiTerminal), amount: _AMOUNT});
        vm.startPrank(address(multiTerminal));
        _token.approve({spender: address(_registry), value: _AMOUNT});
        uint256 beneficiaryTokenCount = _registry.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(_token),
            amount: _AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(_SOURCE_PROJECT_ID)
        });
        vm.stopPrank();

        JBPendingRouterTerminalCall memory call =
            _feeCall({paymentToken: address(_token), amount: _AMOUNT, payer: address(multiTerminal)});
        call.projectId = _DESTINATION_PROJECT_ID;
        call.beneficiary = address(this);
        assertEq(beneficiaryTokenCount, 0, "failed route should be retained");
        assertEq(
            _gateway.pendingCallCommitmentOf(_ID),
            _commitmentOf(call),
            "registry must preserve the source terminal as refund target"
        );
        assertEq(_token.balanceOf(address(_gateway)), _AMOUNT, "retained input must remain fully collateralized");
    }

    /// @notice Checks that direct router failure reaches the source terminal's fee-forgiveness boundary.
    function test_reproducesFeeForgivenessWhenRouterReverts() public {
        // Direct router failure reaches the source terminal's fee-forgiveness boundary.
        JBRouterTerminalRegistry directRegistry = _registryFor(IJBTerminal(address(_router)));

        _sourceTerminal.payFee({
            feeTerminal: directRegistry, token: address(_token), amount: _AMOUNT, sourceProjectId: _SOURCE_PROJECT_ID
        });

        assertTrue(_sourceTerminal.feeWasForgiven(), "source terminal should take its fail-open catch");
        assertEq(_token.balanceOf(address(_sourceTerminal)), _AMOUNT, "reverted fee stays at its source");
        assertEq(_token.balanceOf(address(directRegistry)), 0, "registry must remain stateless");
        assertEq(_token.balanceOf(address(_router)), 0, "router pull must roll back");
    }

    /// @notice Checks that gateway custody prevents a source terminal from forgiving a failed fee.
    function test_routerGatewayRetainsFailedFeeWithoutChangingRegistry() public {
        // Gateway custody prevents a source terminal from forgiving a failed fee.
        _queueFee(address(_token));

        assertFalse(_sourceTerminal.feeWasForgiven(), "gateway must not cross the source terminal's catch boundary");
        assertEq(_gateway.pendingCallCount(), 1, "failed fee should be retained as pending");
        assertEq(
            _gateway.pendingCallCommitmentOf(_ID),
            _commitmentOf(_feeCall()),
            "registry should propagate the source terminal and its source-project opt-in"
        );
        assertEq(_token.balanceOf(address(_gateway)), _AMOUNT, "gateway should retain the original input token");
        assertEq(_token.balanceOf(address(_registry)), 0, "unchanged registry must remain stateless");
        assertEq(_token.balanceOf(address(_router)), 0, "failed router pull must roll back");
    }

    /// @notice Checks that the source project's own token never enters custody that its accounting cannot refund.
    function test_sourceProjectOwnTokenIsNeverRetainedRegardlessOfPayer() public {
        // The source project's own token never enters custody that its accounting cannot refund.
        // `JBController` distributes reserved splits in the source project's own token with exactly the opt-in
        // metadata shape, then hands the tokens to the split beneficiary if the terminal reverts. No source terminal
        // can ever book that token, so custody would be a permanent lock. The rule keys on the token, not on who the
        // payer appears to be: a controller whose transient `originalPayer` is a re-entering attacker looks like a
        // third party, and a project owner can point `controllerOf` at anything.
        GatewayTestToken projectToken = new GatewayTestToken();
        _router.TOKENS().setProjectIdOf({token: address(projectToken), projectId: _SOURCE_PROJECT_ID});
        projectToken.mint(address(this), _AMOUNT * 2);
        projectToken.approve(address(_gateway), _AMOUNT * 2);

        uint256[2] memory destinations = [uint256(JBConstants.FEE_BENEFICIARY_PROJECT_ID), uint256(3)];
        for (uint256 i; i < destinations.length; ++i) {
            vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RouteFailed.selector);
            _gateway.pay({
                projectId: destinations[i],
                token: address(projectToken),
                amount: _AMOUNT,
                beneficiary: address(this),
                minReturnedTokens: 0,
                memo: "",
                metadata: abi.encodePacked(uint256(_SOURCE_PROJECT_ID))
            });
        }

        assertEq(_gateway.pendingCallCount(), 0, "a project's own token must never be retained");
        assertEq(projectToken.balanceOf(address(this)), _AMOUNT * 2, "the caller's catch must get its tokens back");

        // Another project's token is bookable and retains as usual.
        _router.TOKENS().setProjectIdOf({token: address(projectToken), projectId: 9});
        _gateway.pay({
            projectId: 3,
            token: address(projectToken),
            amount: _AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(uint256(_SOURCE_PROJECT_ID))
        });
        assertEq(_gateway.pendingCallCount(), 1, "another project's token is ordinary custody");
    }

    /// @notice Checks that an independent caller can settle a pending payment to its original destination.
    function test_successfulPermissionlessRetrySettlesPendingCall() public {
        // An independent caller can settle a pending payment to its original destination.
        _queueFee(address(_token));
        _router.setMode(0);

        uint256 beneficiaryTokenCount = _process(_ID, _feeCall());

        assertEq(beneficiaryTokenCount, _AMOUNT);
        assertEq(_token.balanceOf(address(_router)), _AMOUNT);
        assertEq(_token.balanceOf(address(_gateway)), 0);
        assertEq(_gateway.pendingCallCommitmentOf(_ID), bytes32(0));
        assertEq(_gateway.pendingCallFailureOf(_ID).count, 0);
    }

    /// @notice Checks that a terminal call without a source project cannot create pending custody.
    function test_terminalCallWithoutSourceProjectRevertsSynchronously() public {
        // A terminal call without a source project cannot create pending custody.
        vm.startPrank(address(_sourceTerminal));
        _token.approve(address(_gateway), _AMOUNT);
        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RouteFailed.selector);
        _gateway.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(_token),
            amount: _AMOUNT,
            beneficiary: address(_sourceTerminal),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        vm.stopPrank();

        assertEq(_gateway.pendingCallCount(), 0, "malformed terminal metadata must not create direct-refund custody");
        assertEq(_token.balanceOf(address(_sourceTerminal)), _AMOUNT, "revert should restore terminal funds");
    }

    /// @notice Checks that ordinary payout failures retain the source terminal's synchronous recovery.
    function test_terminalPayoutToNonFeeProjectRevertsSynchronously() public {
        // Ordinary payout failures retain the source terminal's synchronous recovery.
        // A failed payout split reverting into `JBMultiTerminal` restores the full amount fee-free; retaining it
        // would charge the fee on a payout that never lands and lock the net for days.
        _token.mint(address(_sourceTerminal), _AMOUNT);
        _sourceTerminal.sendPayout({
            terminal: _registry,
            destinationProjectId: 3,
            token: address(_token),
            amount: _AMOUNT,
            sourceProjectId: _SOURCE_PROJECT_ID,
            preferAddToBalance: false
        });
        assertTrue(_sourceTerminal.payoutWasNullified(), "the terminal's catch must see the failure");

        _sourceTerminal.sendPayout({
            terminal: _registry,
            destinationProjectId: 3,
            token: address(_token),
            amount: _AMOUNT,
            sourceProjectId: _SOURCE_PROJECT_ID,
            preferAddToBalance: true
        });
        assertTrue(_sourceTerminal.payoutWasNullified(), "add-to-balance payouts follow the same rule");

        assertEq(_gateway.pendingCallCount(), 0, "terminal payouts to non-fee projects must not be retained");
        assertEq(_token.balanceOf(address(_sourceTerminal)), _AMOUNT * 2, "the source terminal keeps its payout");
        assertEq(_token.balanceOf(address(_gateway)), 0);
    }

    /// @notice Checks that three properly spaced matching failures preserve custody and qualify a call.
    function test_threeMatchingFailuresAdvanceQualification() public {
        // Three properly spaced matching failures preserve custody and qualify a call.
        _queueFee(address(_token));
        _qualifyWithMatchingFailures();

        JBPendingRouterTerminalCallFailure memory failure = _gateway.pendingCallFailureOf(_ID);
        assertEq(failure.count, 3);
        assertNotEq(failure.errorHash, bytes32(0));
        assertEq(failure.lastFailureAt, block.timestamp);
        assertEq(_token.balanceOf(address(_gateway)), _AMOUNT, "every failed pull must roll back to gateway custody");
    }

    /// @notice Checks that the per-transaction gas ceiling constrains escalation even with larger blocks.
    function test_transactionGasCapBoundsFinalRungOnLargeBlockChains() public {
        // The per-transaction gas ceiling constrains escalation even with larger blocks.
        GatewayGasHarness harness = new GatewayGasHarness();
        // Ethereum mainnet: 60M blocks but EIP-7825 caps one transaction at 2^24 gas.
        uint256 maximumGasLimit = harness.maximumQualifiedCallGasFor(60_000_000);
        assertEq(
            maximumGasLimit, uint256(16_777_216 - 1_500_000) * 63 / 64, "ceiling must follow the per-transaction cap"
        );
        assertEq(
            harness.maximumQualifiedCallGasFor(16_777_216), maximumGasLimit, "a cap-sized block yields the same ceiling"
        );
        assertLt(harness.maximumQualifiedCallGasFor(10_000_000), maximumGasLimit, "smaller blocks still bind");

        // The finalization rung (count 3 -> 20M target) must clip to something a transaction can carry.
        JBPendingRouterTerminalCallFailure memory failure = JBPendingRouterTerminalCallFailure({
            count: 3, errorHash: harness.gasExhaustedErrorHash(), lastFailureAt: 0, highestGasLimit: 0
        });
        uint256 rung =
            harness.qualifiedGasLimitFor({failure: failure, requestedGasLimit: 0, maximumGasLimit: maximumGasLimit});
        assertEq(rung, maximumGasLimit, "the 20M rung must clip to the ceiling");
        assertLt(rung + (rung + 62) / 63 + 750_000, 16_777_216, "the clipped rung must satisfy _requireRetryGas");
    }

    /// @notice Checks that an underfunded retry cannot advance failure qualification or spend custody.
    function test_underfundedRetryCannotAdvanceQualification() public {
        // An underfunded retry cannot advance failure qualification or spend custody.
        _queueFee(address(_token));

        bytes memory data = abi.encodeCall(
            _gateway.processPendingCall, (_ID, _feeCall(), "", bytes(abi.encodePacked(_SOURCE_PROJECT_ID)))
        );
        (bool success,) = address(_gateway).call{gas: _gateway.QUALIFIED_CALL_GAS() + 100_000}(data);

        assertFalse(success, "underfunded retry must revert");
        assertEq(_gateway.pendingCallFailureOf(_ID).count, 0, "underfunded retry must not qualify");
        assertEq(_gateway.pendingCallCommitmentOf(_ID), _commitmentOf(_feeCall()), "pending call must remain intact");
        assertEq(_token.balanceOf(address(_gateway)), _AMOUNT, "custody must remain intact");
    }

    /// @notice Checks that an unissuable source-project identifier cannot opt a payment into retention.
    function test_wideSourceProjectWordIsNotAnEscrowOptIn() public {
        // An unissuable source-project identifier cannot opt a payment into retention.
        // A coincidental 32-byte payload wider than core's `uint64` project-ID width (a hash, a packed address)
        // must keep synchronous failure semantics instead of entering custody aimed at an unissuable project.
        vm.startPrank(address(_sourceTerminal));
        _token.approve(address(_gateway), _AMOUNT);
        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RouteFailed.selector);
        _gateway.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(_token),
            amount: _AMOUNT,
            beneficiary: address(_sourceTerminal),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(uint256(type(uint64).max) + 1)
        });
        vm.stopPrank();

        assertEq(_gateway.pendingCallCount(), 0, "wide metadata word must not create custody");
        assertEq(_token.balanceOf(address(_sourceTerminal)), _AMOUNT, "revert should restore terminal funds");
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Finalizes a retained call using the fixture's authenticated metadata.
    /// @param id The pending call identifier.
    /// @param call The retained operation to finalize.
    /// @return wasRefunded Whether finalization returned funds to the source project.
    /// @return beneficiaryTokenCount The beneficiary tokens received if settlement succeeded.
    function _finalize(
        bytes32 id,
        JBPendingRouterTerminalCall memory call
    )
        internal
        returns (bool wasRefunded, uint256 beneficiaryTokenCount)
    {
        return _gateway.finalizePendingCall({
            id: id, call: call, memo: "", metadata: abi.encodePacked(uint256(call.sourceProjectId))
        });
    }

    /// @notice Retries a retained call using the fixture's authenticated metadata.
    /// @param id The pending call identifier.
    /// @param call The retained operation to retry.
    /// @return count The beneficiary tokens received if settlement succeeded.
    function _process(bytes32 id, JBPendingRouterTerminalCall memory call) internal returns (uint256 count) {
        return _gateway.processPendingCall({
            id: id, call: call, memo: "", metadata: abi.encodePacked(uint256(call.sourceProjectId))
        });
    }

    /// @notice Records three matching failures separated by the required retry delay.
    /// @param call The retained operation whose failure streak is qualified.
    function _qualifyWithMatchingFailures(JBPendingRouterTerminalCall memory call) internal {
        _process(_ID, call);
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        _process(_ID, call);
        vm.warp(block.timestamp + _gateway.RETRY_DELAY());
        _process(_ID, call);
    }

    /// @notice Records three matching failures separated by the required retry delay.
    function _qualifyWithMatchingFailures() internal {
        _qualifyWithMatchingFailures(_feeCall());
    }

    /// @notice Routes a source-terminal fee into the failing router so the gateway retains it.
    /// @param paymentToken The original asset in which the fee is denominated.
    function _queueFee(address paymentToken) internal {
        _sourceTerminal.payFee({
            feeTerminal: _registry, token: paymentToken, amount: _AMOUNT, sourceProjectId: _SOURCE_PROJECT_ID
        });
    }

    /// @notice Deploys a registry forwarding its default project route to the supplied terminal.
    /// @param terminal The default terminal to select.
    /// @return result The configured registry.
    function _registryFor(IJBTerminal terminal) internal returns (JBRouterTerminalRegistry result) {
        result = new JBRouterTerminalRegistry({
            permissions: IJBPermissions(address(0)),
            projects: IJBProjects(address(new GatewayTestProjects())),
            permit2: IPermit2(address(0)),
            owner: address(this),
            trustedForwarder: address(0)
        });
        result.setDefaultTerminal(terminal);
    }

    //*********************************************************************//
    // ------------------------- internal helpers ------------------------ //
    //*********************************************************************//

    /// @notice The gateway commitment for a call with an empty memo and source-project metadata.
    /// @param call The retained operation to authenticate.
    /// @return commitment The hash binding the call and its retry metadata.
    function _commitmentOf(JBPendingRouterTerminalCall memory call) internal pure returns (bytes32 commitment) {
        return keccak256(abi.encode(call, string(""), abi.encodePacked(uint256(call.sourceProjectId))));
    }

    /// @notice Builds the retained fee-call shape used by the fixture.
    /// @param paymentToken The original input asset.
    /// @param amount The original input amount.
    /// @param payer The beneficiary and preferred refund terminal.
    /// @return call The fee operation including its source project and refund target.
    function _feeCall(
        address paymentToken,
        uint256 amount,
        address payer
    )
        internal
        pure
        returns (JBPendingRouterTerminalCall memory call)
    {
        return JBPendingRouterTerminalCall({
            amount: amount,
            preferAddToBalance: false,
            shouldReturnHeldFees: false,
            beneficiary: payer,
            projectId: JBConstants.FEE_BENEFICIARY_PROJECT_ID,
            refundTo: payer,
            sourceProjectId: _SOURCE_PROJECT_ID,
            token: paymentToken
        });
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Builds the retained fee-call shape used by the fixture.
    /// @return call The fee operation including its source project and refund target.
    function _feeCall() internal view returns (JBPendingRouterTerminalCall memory call) {
        return _feeCall({paymentToken: address(_token), amount: _AMOUNT, payer: address(_sourceTerminal)});
    }

    /// @notice Builds a payout call with its original payment operation and refund target.
    /// @param paymentToken The input asset retained by the gateway.
    /// @param preferAddToBalance Whether the payout credits balance without minting beneficiary tokens.
    /// @return call The payout operation to authenticate when retrying.
    function _payoutCall(
        address paymentToken,
        bool preferAddToBalance
    )
        internal
        view
        returns (JBPendingRouterTerminalCall memory call)
    {
        return JBPendingRouterTerminalCall({
            amount: _AMOUNT,
            preferAddToBalance: preferAddToBalance,
            shouldReturnHeldFees: false,
            beneficiary: preferAddToBalance ? address(0) : address(_sourceTerminal),
            projectId: _DESTINATION_PROJECT_ID,
            refundTo: address(_sourceTerminal),
            sourceProjectId: _SOURCE_PROJECT_ID,
            token: paymentToken
        });
    }
}
