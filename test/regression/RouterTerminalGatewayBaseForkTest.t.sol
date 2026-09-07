// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {JBRouterTerminalGateway} from "../../src/JBRouterTerminalGateway.sol";
import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";

import {IJBRouterTerminal} from "../../src/interfaces/IJBRouterTerminal.sol";

import {JBPendingRouterTerminalCall} from "../../src/structs/JBPendingRouterTerminalCall.sol";

import {RouterTerminalMigrationLib} from "../../script/helpers/RouterTerminalMigrationLib.sol";

import {IGatewayDirectoryProvider} from "../helpers/gateway/IGatewayDirectoryProvider.sol";

/// @notice Replays a pinned Base payout to check fee retention and settlement under executable gas budgets.
contract RouterTerminalGatewayBaseForkTest is Test {
    //*********************************************************************//
    // ------------------------ internal constants ----------------------- //
    //*********************************************************************//

    /// @notice The Base block immediately before the payout being replayed.
    uint256 internal constant _BASE_BLOCK_BEFORE_TX = 49_764_740;
    /// @notice The gas forwarded to the payout call being replayed.
    uint256 internal constant _ORIGINAL_CALL_GAS = 1_097_146;

    /// @notice The account authorized to request the payout on the pinned fork.
    address internal constant _FEE_BENEFICIARY = 0x59733c7Cd78d08dAb90368aD2cc09c8c81f097C0;
    /// @notice The deployed terminal processing the source project payout.
    address internal constant _MULTI_TERMINAL = 0x130f5Dd2bD8805443Cf41755253D778a75a67f53;
    /// @notice The receiver whose payout must remain intact when the fee is retained.
    address internal constant _PAYOUT_BENEFICIARY = 0x0a61E9065219A1B84A9fa1B67482C485C39c51De;
    /// @notice The deployed registry forwarding project 1 payments.
    address internal constant _REGISTRY = 0xe0427F250fdb0379c8E98e884Ee4570521208CbC;
    /// @notice The original input asset used by the pinned payout.
    address internal constant _USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @notice The event signature identifying an upstream forgiven fee.
    bytes32 internal constant _FEE_REVERTED_TOPIC =
        keccak256("FeeReverted(uint256,address,uint256,uint256,bytes,address)");
    /// @notice The event signature identifying a processed source-terminal fee.
    bytes32 internal constant _PROCESS_FEE_TOPIC =
        keccak256("ProcessFee(uint256,address,uint256,bool,address,address)");
    /// @notice The event signature exposing the complete retained call for permissionless replay.
    bytes32 internal constant _QUEUE_PENDING_CALL_TOPIC = keccak256(
        "JBRouterTerminalGateway_QueuePendingCall(bytes32,(uint256,bool,bool,address,uint256,address,uint256,address),string,bytes,bytes32,address)"
    );

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Checks that every completing payout in the tested gas range also avoids fee forgiveness.
    function testFork_reportedBaseFeeHasNoSuccessfulFeeRevertGasBand() public {
        // A named endpoint makes missing archive access fail explicitly instead of omitting this chain.
        vm.createSelectFork("base", _BASE_BLOCK_BEFORE_TX);

        _installGateway();
        uint256 snapshot = vm.snapshotState();

        for (uint256 gasLimit = 750_000; gasLimit <= 1_500_000; gasLimit += 10_000) {
            vm.recordLogs();
            bool success = _replayReportedPayout(gasLimit);

            if (success) {
                Vm.Log[] memory logs = vm.getRecordedLogs();
                for (uint256 i; i < logs.length; ++i) {
                    assertTrue(
                        logs[i].topics[0] != _FEE_REVERTED_TOPIC,
                        string.concat("fee forgiven with call gas ", vm.toString(gasLimit))
                    );
                }
            }

            assertTrue(vm.revertToState(snapshot));
        }
    }

    /// @notice Checks that the pinned Base payout retains its fee and supports later permissionless settlement.
    function testFork_reportedBaseFeeIsRetainedByGatewayWithoutRegistryCodeChanges() public {
        // A named endpoint makes missing archive access fail explicitly instead of omitting this chain.
        vm.createSelectFork("base", _BASE_BLOCK_BEFORE_TX);

        JBRouterTerminalGateway gateway = _installGateway();
        // EIP-7825 caps any transaction at 2^24 gas, so the 20M rung must clip to what one transaction can carry.
        assertEq(
            gateway.maximumQualifiedCallGas(),
            uint256(16_777_216 - 1_500_000) * 63 / 64,
            "the ladder ceiling must be the per-transaction cap, not the block limit"
        );
        uint256 gatewayBalanceBefore = IERC20(_USDC).balanceOf(address(gateway));
        uint256 payoutBalanceBefore = IERC20(_USDC).balanceOf(_PAYOUT_BENEFICIARY);

        vm.recordLogs();
        bool success = _replayReportedPayout(_ORIGINAL_CALL_GAS);
        assertTrue(success, "reported payout transaction reverted");

        bool sawFeeReverted;
        bool sawProcessFee;
        JBPendingRouterTerminalCall memory pending;
        string memory pendingMemo;
        bytes memory pendingMetadata;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == _FEE_REVERTED_TOPIC) sawFeeReverted = true;
            if (logs[i].topics[0] == _PROCESS_FEE_TOPIC) sawProcessFee = true;
            // Recover the retained call the way a permissionless retrier would: from the queue event.
            if (logs[i].topics[0] == _QUEUE_PENDING_CALL_TOPIC && logs[i].emitter == address(gateway)) {
                (pending, pendingMemo, pendingMetadata,,) =
                    abi.decode(logs[i].data, (JBPendingRouterTerminalCall, string, bytes, bytes32, address));
            }
        }
        assertFalse(sawFeeReverted, "fee was forgiven");
        assertTrue(sawProcessFee, "source terminal did not recognize gateway custody");

        assertEq(pending.amount, 25_003, "fee was not retained");
        assertEq(pending.token, _USDC, "gateway did not retain the original input token");
        assertEq(pending.refundTo, _MULTI_TERMINAL, "source terminal was not propagated");
        assertTrue(pending.sourceProjectId != 0, "fee refund should return through source project accounting");
        assertEq(pending.sourceProjectId, 9, "source project metadata was not retained");
        assertEq(
            gateway.pendingCallCommitmentOf(bytes32(uint256(1))),
            keccak256(abi.encode(pending, pendingMemo, pendingMetadata)),
            "stored commitment must match the queue event"
        );
        assertEq(IERC20(_USDC).balanceOf(address(gateway)) - gatewayBalanceBefore, 25_003, "custody mismatch");
        assertEq(IERC20(_USDC).balanceOf(_PAYOUT_BENEFICIARY) - payoutBalanceBefore, 975_118, "payout changed");

        uint256 beneficiaryTokenCount = gateway.processPendingCall({
            id: bytes32(uint256(1)), call: pending, memo: pendingMemo, metadata: pendingMetadata
        });
        assertGt(beneficiaryTokenCount, 0, "retry did not mint fee-project tokens");
        assertEq(gateway.pendingCallCommitmentOf(bytes32(uint256(1))), bytes32(0), "retry remained pending");
        assertEq(IERC20(_USDC).balanceOf(address(gateway)), gatewayBalanceBefore, "retry did not consume fee");
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Installs a gateway through the registry owner's explicit project migration.
    /// @return gateway The gateway selected for project 1 on the fork.
    function _installGateway() internal returns (JBRouterTerminalGateway gateway) {
        JBRouterTerminalRegistry registry = JBRouterTerminalRegistry(_REGISTRY);
        IJBRouterTerminal router = IJBRouterTerminal(address(registry.terminalOf(1)));
        gateway = new JBRouterTerminalGateway({
            directory: IGatewayDirectoryProvider(address(router)).DIRECTORY(),
            permit2: registry.PERMIT2(),
            router: router,
            trustedForwarder: registry.trustedForwarder()
        });

        // Match deployment: changing the default does not move project 1, then the migration list does so explicitly.
        vm.startPrank(registry.owner());
        registry.setDefaultTerminal(gateway);
        uint256[] memory projectIds = new uint256[](1);
        projectIds[0] = 1;
        RouterTerminalMigrationLib._migrateProjects({
            registry: registry, terminal: gateway, projectCount: registry.PROJECTS().count(), projectIds: projectIds
        });
        RouterTerminalMigrationLib._requireMigratedProject({registry: registry, terminal: gateway, projectId: 1});
        vm.stopPrank();

        assertEq(address(registry.terminalOf(1)), address(gateway), "deployment migration must repoint fee project");
    }

    /// @notice Replays the pinned source-project payout with a chosen gas budget.
    /// @param gasLimit The gas forwarded into the source terminal.
    /// @return success Whether the source terminal completed the payout call.
    function _replayReportedPayout(uint256 gasLimit) internal returns (bool success) {
        vm.prank(_FEE_BENEFICIARY);
        (success,) = _MULTI_TERMINAL.call{gas: gasLimit}(
            abi.encodeWithSelector(
                bytes4(0xcfaf5839), uint256(9), _USDC, uint256(1_000_000), uint256(2), uint256(990_119)
            )
        );
    }
}
