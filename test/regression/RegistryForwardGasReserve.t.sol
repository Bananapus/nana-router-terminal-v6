// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";
import {JBPendingTerminalCall} from "../../src/structs/JBPendingTerminalCall.sol";

contract ForwardGasToken {
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ForwardGasTerminal {
    bool public shouldRunOutOfGas;
    uint256 public addedBalance;
    uint256 public paid;
    address public originalPayerSeen;
    address public payerSeen;

    function addToBalanceOf(
        uint256,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
    {
        if (shouldRunOutOfGas) {
            assembly ("memory-safe") {
                invalid()
            }
        }
        _accept(token, amount);
        addedBalance += amount;
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
        if (shouldRunOutOfGas) {
            assembly ("memory-safe") {
                invalid()
            }
        }
        _accept(token, amount);
        paid += amount;
        return 123;
    }

    function setShouldRunOutOfGas(bool flag) external {
        shouldRunOutOfGas = flag;
    }

    function _accept(address token, uint256 amount) internal {
        payerSeen = msg.sender;
        try IJBPayerTracker(msg.sender).originalPayer() returns (address payer) {
            originalPayerSeen = payer;
        } catch {}
        if (token == JBConstants.NATIVE_TOKEN) {
            require(msg.value == amount);
        } else {
            require(IERC20(token).transferFrom(msg.sender, address(this), amount));
        }
    }
}

/// @notice Models the core terminal's catch boundary around project payouts and fee processing.
contract ForwardGasSourceTerminal {
    uint256 public catchAccounting;
    uint256 public outcome;

    IJBDirectory public immutable DIRECTORY;

    constructor(IJBDirectory directory) {
        DIRECTORY = directory;
    }

    function approve(ForwardGasToken token, JBRouterTerminalRegistry registry) external {
        token.approve(address(registry), type(uint256).max);
    }

    function forwardAddToBalance(
        JBRouterTerminalRegistry registry,
        address token,
        uint256 amount,
        uint256 sourceProjectId,
        uint256 destinationProjectId
    )
        external
    {
        uint256 value = token == JBConstants.NATIVE_TOKEN ? amount : 0;
        try registry.addToBalanceOf{value: value}({
            projectId: destinationProjectId,
            token: token,
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: abi.encodePacked(sourceProjectId)
        }) {
            outcome = 1;
        } catch {
            // Approximate core's catch-side accounting writes. If this branch completes, the originating terminal
            // could have observed a failed Router call while keeping the outer operation successful.
            outcome = 2;
            catchAccounting += amount;
        }
    }

    function forwardPay(
        JBRouterTerminalRegistry registry,
        address token,
        uint256 amount,
        uint256 sourceProjectId,
        uint256 destinationProjectId,
        address beneficiary
    )
        external
    {
        uint256 value = token == JBConstants.NATIVE_TOKEN ? amount : 0;
        try registry.pay{value: value}({
            projectId: destinationProjectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(sourceProjectId)
        }) returns (
            uint256
        ) {
            outcome = 1;
        } catch {
            outcome = 2;
            catchAccounting += amount;
        }
    }
}

contract RegistryForwardGasReserveTest is Test {
    uint256 internal constant _AMOUNT = 1 ether;
    uint256 internal constant _DESTINATION_PROJECT_ID = 17;
    uint256 internal constant _SOURCE_PROJECT_ID = 9;

    ForwardGasSourceTerminal internal source;
    ForwardGasTerminal internal terminal;
    ForwardGasToken internal token;
    JBRouterTerminalRegistry internal registry;
    IJBDirectory internal directory;

    function setUp() public {
        IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
        IJBProjects projects = IJBProjects(makeAddr("projects"));
        IPermit2 permit2 = IPermit2(makeAddr("permit2"));
        address owner = makeAddr("owner");
        directory = IJBDirectory(makeAddr("directory"));

        registry = new JBRouterTerminalRegistry(permissions, projects, permit2, owner, address(0));
        terminal = new ForwardGasTerminal();
        source = new ForwardGasSourceTerminal(directory);
        token = new ForwardGasToken();

        vm.mockCall(address(projects), abi.encodeCall(IJBProjects.count, ()), abi.encode(uint256(0)));
        vm.mockCall(address(directory), abi.encodeCall(IJBDirectory.PROJECTS, ()), abi.encode(projects));
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.isTerminalOf, (_SOURCE_PROJECT_ID, IJBTerminal(address(source)))),
            abi.encode(true)
        );
        vm.prank(owner);
        registry.setDefaultTerminal(IJBTerminal(address(terminal)));

        token.mint(address(source), _AMOUNT);
        source.approve(token, registry);
    }

    function test_forwardedAddToBalanceQueuesAndRetriesAfterDownstreamOutOfGas() public {
        terminal.setShouldRunOutOfGas(true);
        source.forwardAddToBalance(registry, address(token), _AMOUNT, _SOURCE_PROJECT_ID, _DESTINATION_PROJECT_ID);

        bytes32 id = _pendingId({beneficiary: address(0), preferAddToBalance: true});
        JBPendingTerminalCall memory pending = registry.pendingTerminalCallOf(id);
        assertEq(pending.amount, _AMOUNT);
        assertTrue(pending.preferAddToBalance);
        assertEq(token.balanceOf(address(registry)), _AMOUNT);
        assertEq(token.balanceOf(address(source)), 0);
        assertEq(token.allowance(address(registry), address(terminal)), 0);
        assertEq(source.outcome(), 1);
        assertEq(source.catchAccounting(), 0);

        terminal.setShouldRunOutOfGas(false);
        registry.processPendingTerminalCall(id);

        assertEq(terminal.addedBalance(), _AMOUNT);
        assertEq(terminal.originalPayerSeen(), address(source));
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(registry.pendingTerminalCallOf(id).amount, 0);
    }

    function test_forwardedPayQueuesAndRetriesAfterDownstreamOutOfGas() public {
        address beneficiary = makeAddr("beneficiary");
        terminal.setShouldRunOutOfGas(true);
        source.forwardPay(registry, address(token), _AMOUNT, _SOURCE_PROJECT_ID, _DESTINATION_PROJECT_ID, beneficiary);

        bytes32 id = _pendingId({beneficiary: beneficiary, preferAddToBalance: false});
        JBPendingTerminalCall memory pending = registry.pendingTerminalCallOf(id);
        assertEq(pending.amount, _AMOUNT);
        assertEq(pending.beneficiary, beneficiary);
        assertFalse(pending.preferAddToBalance);
        assertEq(token.balanceOf(address(registry)), _AMOUNT);
        assertEq(source.outcome(), 1);
        assertEq(source.catchAccounting(), 0);

        terminal.setShouldRunOutOfGas(false);
        uint256 tokenCount = registry.processPendingTerminalCall(id);

        assertEq(tokenCount, 123);
        assertEq(terminal.paid(), _AMOUNT);
        assertEq(terminal.originalPayerSeen(), address(source));
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(registry.pendingTerminalCallOf(id).amount, 0);
    }

    function test_forwardedPaySucceedsSynchronouslyWithoutQueueing() public {
        address beneficiary = makeAddr("beneficiary");
        source.forwardPay(registry, address(token), _AMOUNT, _SOURCE_PROJECT_ID, _DESTINATION_PROJECT_ID, beneficiary);

        bytes32 id = _pendingId({beneficiary: beneficiary, preferAddToBalance: false});
        assertEq(source.outcome(), 1);
        assertEq(terminal.paid(), _AMOUNT);
        assertEq(terminal.originalPayerSeen(), address(source));
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(registry.pendingTerminalCallOf(id).amount, 0);
    }

    function test_failedCallsWithTheSameRouteAggregateAndSettleTogether() public {
        address beneficiary = makeAddr("beneficiary");
        terminal.setShouldRunOutOfGas(true);

        source.forwardPay(registry, address(token), _AMOUNT, _SOURCE_PROJECT_ID, _DESTINATION_PROJECT_ID, beneficiary);
        token.mint(address(source), _AMOUNT);
        source.forwardPay(registry, address(token), _AMOUNT, _SOURCE_PROJECT_ID, _DESTINATION_PROJECT_ID, beneficiary);

        bytes32 id = _pendingId({beneficiary: beneficiary, preferAddToBalance: false});
        assertEq(registry.pendingTerminalCallOf(id).amount, _AMOUNT * 2);
        assertEq(token.balanceOf(address(registry)), _AMOUNT * 2);

        terminal.setShouldRunOutOfGas(false);
        registry.processPendingTerminalCall(id);

        assertEq(terminal.paid(), _AMOUNT * 2);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(registry.pendingTerminalCallOf(id).amount, 0);
    }

    function test_directPayPreservesSynchronousRevertBehavior() public {
        terminal.setShouldRunOutOfGas(true);
        token.mint(address(this), _AMOUNT);
        token.approve(address(registry), _AMOUNT);

        vm.expectRevert();
        registry.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(token),
            amount: _AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        assertEq(token.balanceOf(address(this)), _AMOUNT);
        assertEq(token.balanceOf(address(registry)), 0);
    }

    function test_contractCallWithUnverifiedSourceMetadataPreservesSynchronousRevertBehavior() public {
        ForwardGasSourceTerminal unverifiedSource = new ForwardGasSourceTerminal(IJBDirectory(makeAddr("other")));
        token.mint(address(unverifiedSource), _AMOUNT);
        unverifiedSource.approve(token, registry);
        terminal.setShouldRunOutOfGas(true);

        unverifiedSource.forwardPay(
            registry, address(token), _AMOUNT, _SOURCE_PROJECT_ID, _DESTINATION_PROJECT_ID, address(this)
        );

        assertEq(unverifiedSource.outcome(), 2);
        assertEq(unverifiedSource.catchAccounting(), _AMOUNT);
        assertEq(token.balanceOf(address(unverifiedSource)), _AMOUNT);
        assertEq(token.balanceOf(address(registry)), 0);
    }

    function test_forwardedNativePayQueuesAndRetriesAfterDownstreamOutOfGas() public {
        address beneficiary = makeAddr("nativeBeneficiary");
        vm.deal(address(source), _AMOUNT);
        terminal.setShouldRunOutOfGas(true);

        source.forwardPay(
            registry, JBConstants.NATIVE_TOKEN, _AMOUNT, _SOURCE_PROJECT_ID, _DESTINATION_PROJECT_ID, beneficiary
        );

        bytes32 id = _pendingIdFor({
            pendingToken: JBConstants.NATIVE_TOKEN,
            beneficiary: beneficiary,
            payer: address(source),
            preferAddToBalance: false
        });
        assertEq(registry.pendingTerminalCallOf(id).amount, _AMOUNT);
        assertEq(address(registry).balance, _AMOUNT);
        assertEq(address(source).balance, 0);
        assertEq(source.outcome(), 1);

        terminal.setShouldRunOutOfGas(false);
        registry.processPendingTerminalCall(id);

        assertEq(terminal.paid(), _AMOUNT);
        assertEq(address(registry).balance, 0);
        assertEq(address(terminal).balance, _AMOUNT);
    }

    function test_processPendingTerminalCallRevertsAndPreservesPendingCallWhenRetryFails() public {
        address beneficiary = makeAddr("beneficiary");
        terminal.setShouldRunOutOfGas(true);
        source.forwardPay(registry, address(token), _AMOUNT, _SOURCE_PROJECT_ID, _DESTINATION_PROJECT_ID, beneficiary);

        bytes32 id = _pendingId({beneficiary: beneficiary, preferAddToBalance: false});
        vm.expectRevert();
        registry.processPendingTerminalCall(id);

        assertEq(registry.pendingTerminalCallOf(id).amount, _AMOUNT);
        assertEq(token.balanceOf(address(registry)), _AMOUNT);
    }

    function test_processPendingTerminalCallRevertsForUnknownId() public {
        bytes32 id = keccak256("missing");
        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalRegistry.JBRouterTerminalRegistry_PendingTerminalCallNotFound.selector, id
            )
        );
        registry.processPendingTerminalCall(id);
    }

    function testFuzz_forwardedPayNeverCompletesTheSourceCatchWithoutRegistryCustody(uint24 gasLimit) public {
        gasLimit = uint24(bound(gasLimit, 80_000, 1_500_000));
        terminal.setShouldRunOutOfGas(true);

        (bool completed,) = address(source).call{gas: gasLimit}(
            abi.encodeCall(
                ForwardGasSourceTerminal.forwardPay,
                (registry, address(token), _AMOUNT, _SOURCE_PROJECT_ID, _DESTINATION_PROJECT_ID, address(this))
            )
        );

        if (completed) {
            assertEq(source.outcome(), 1, "source catch completed");
            assertEq(source.catchAccounting(), 0, "source recorded a failed forwarding call");
            assertEq(token.balanceOf(address(registry)), _AMOUNT, "registry did not retain the payment");
        }
    }

    function testFuzz_forwardedAddNeverCompletesTheSourceCatchWithoutRegistryCustody(uint24 gasLimit) public {
        gasLimit = uint24(bound(gasLimit, 80_000, 1_500_000));
        terminal.setShouldRunOutOfGas(true);

        (bool completed,) = address(source).call{gas: gasLimit}(
            abi.encodeCall(
                ForwardGasSourceTerminal.forwardAddToBalance,
                (registry, address(token), _AMOUNT, _SOURCE_PROJECT_ID, _DESTINATION_PROJECT_ID)
            )
        );

        if (completed) {
            assertEq(source.outcome(), 1, "source catch completed");
            assertEq(source.catchAccounting(), 0, "source recorded a failed forwarding call");
            assertEq(token.balanceOf(address(registry)), _AMOUNT, "registry did not retain the payment");
        }
    }

    function _pendingId(address beneficiary, bool preferAddToBalance) internal view returns (bytes32) {
        return _pendingIdFor({
            pendingToken: address(token),
            beneficiary: beneficiary,
            payer: address(source),
            preferAddToBalance: preferAddToBalance
        });
    }

    function _pendingIdFor(
        address pendingToken,
        address beneficiary,
        address payer,
        bool preferAddToBalance
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                _SOURCE_PROJECT_ID, _DESTINATION_PROJECT_ID, pendingToken, beneficiary, payer, preferAddToBalance
            )
        );
    }
}

contract RegistryForwardGasReserveBaseForkTest is Test {
    uint256 internal constant _BASE_BLOCK_BEFORE_TX = 49_764_740;
    uint256 internal constant _ORIGINAL_CALL_GAS = 1_097_146;

    address internal constant _FEE_BENEFICIARY = 0x59733c7Cd78d08dAb90368aD2cc09c8c81f097C0;
    address internal constant _MULTI_TERMINAL = 0x130f5Dd2bD8805443Cf41755253D778a75a67f53;
    address internal constant _PAYOUT_BENEFICIARY = 0x0a61E9065219A1B84A9fa1B67482C485C39c51De;
    address internal constant _REGISTRY = 0xe0427F250fdb0379c8E98e884Ee4570521208CbC;
    address internal constant _USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    bytes32 internal constant _FEE_REVERTED_TOPIC =
        keccak256("FeeReverted(uint256,address,uint256,uint256,bytes,address)");
    bytes32 internal constant _PROCESS_FEE_TOPIC =
        keccak256("ProcessFee(uint256,address,uint256,bool,address,address)");

    /// @notice Replays the reported Base transaction against the patched registry bytecode. Configure
    /// `RPC_BASE_MAINNET` to run this archive-fork regression locally.
    function testFork_reportedBaseFeeOutOfGasIsRetainedInsteadOfForgiven() public {
        string memory rpc = vm.envOr("RPC_BASE_MAINNET", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, _BASE_BLOCK_BEFORE_TX);

        JBRouterTerminalRegistry deployed = JBRouterTerminalRegistry(_REGISTRY);
        JBRouterTerminalRegistry replacement = new JBRouterTerminalRegistry({
            permissions: deployed.PERMISSIONS(),
            projects: deployed.PROJECTS(),
            permit2: deployed.PERMIT2(),
            owner: deployed.owner(),
            trustedForwarder: deployed.trustedForwarder()
        });
        vm.etch(_REGISTRY, address(replacement).code);

        uint256 registryBalanceBefore = IERC20(_USDC).balanceOf(_REGISTRY);
        uint256 payoutBalanceBefore = IERC20(_USDC).balanceOf(_PAYOUT_BENEFICIARY);

        vm.recordLogs();
        vm.prank(_FEE_BENEFICIARY);
        (bool success,) = _MULTI_TERMINAL.call{gas: _ORIGINAL_CALL_GAS}(
            abi.encodeWithSelector(
                bytes4(0xcfaf5839), uint256(9), _USDC, uint256(1_000_000), uint256(2), uint256(990_119)
            )
        );
        assertTrue(success, "reported payout transaction reverted");

        bool sawFeeReverted;
        bool sawProcessFee;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == _FEE_REVERTED_TOPIC) sawFeeReverted = true;
            if (logs[i].topics[0] == _PROCESS_FEE_TOPIC) sawProcessFee = true;
        }
        assertFalse(sawFeeReverted, "fee was forgiven");
        assertTrue(sawProcessFee, "source terminal did not recognize fee custody");

        bytes32 id = keccak256(abi.encode(uint256(9), uint256(1), _USDC, _FEE_BENEFICIARY, _MULTI_TERMINAL, false));
        JBPendingTerminalCall memory pending = deployed.pendingTerminalCallOf(id);
        assertEq(pending.amount, 25_003, "fee was not retained");
        assertEq(IERC20(_USDC).balanceOf(_REGISTRY) - registryBalanceBefore, 25_003, "registry custody mismatch");
        assertEq(IERC20(_USDC).balanceOf(_PAYOUT_BENEFICIARY) - payoutBalanceBefore, 975_118, "project payout changed");

        uint256 beneficiaryTokenCount = deployed.processPendingTerminalCall(id);
        assertGt(beneficiaryTokenCount, 0, "retry did not mint fee-project tokens");
        assertEq(deployed.pendingTerminalCallOf(id).amount, 0, "processed fee remained pending");
        assertEq(IERC20(_USDC).balanceOf(_REGISTRY), registryBalanceBefore, "retry did not consume retained fee");
    }

    /// @notice Checks the gas boundary around the reported transaction, including levels which cannot complete the
    /// outer payout. Any level which does complete must not reach the source terminal's fee-forgiveness catch.
    function testFork_reportedBaseFeeHasNoSuccessfulFeeRevertGasBand() public {
        string memory rpc = vm.envOr("RPC_BASE_MAINNET", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, _BASE_BLOCK_BEFORE_TX);

        JBRouterTerminalRegistry deployed = JBRouterTerminalRegistry(_REGISTRY);
        JBRouterTerminalRegistry replacement = new JBRouterTerminalRegistry({
            permissions: deployed.PERMISSIONS(),
            projects: deployed.PROJECTS(),
            permit2: deployed.PERMIT2(),
            owner: deployed.owner(),
            trustedForwarder: deployed.trustedForwarder()
        });
        vm.etch(_REGISTRY, address(replacement).code);

        uint256 snapshot = vm.snapshotState();
        for (uint256 gasLimit = 750_000; gasLimit <= 1_250_000; gasLimit += 10_000) {
            vm.recordLogs();
            vm.prank(_FEE_BENEFICIARY);
            (bool success,) = _MULTI_TERMINAL.call{gas: gasLimit}(
                abi.encodeWithSelector(
                    bytes4(0xcfaf5839), uint256(9), _USDC, uint256(1_000_000), uint256(2), uint256(990_119)
                )
            );

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
}
