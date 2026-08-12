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
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {RouterTerminalMigrationLib} from "../../script/helpers/RouterTerminalMigrationLib.sol";
import {JBRouterTerminalGateway} from "../../src/JBRouterTerminalGateway.sol";
import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";
import {IJBRouterTerminal} from "../../src/interfaces/IJBRouterTerminal.sol";
import {JBPendingRouterTerminalCall} from "../../src/structs/JBPendingRouterTerminalCall.sol";
import {JBPendingRouterTerminalCallFailure} from "../../src/structs/JBPendingRouterTerminalCallFailure.sol";

contract GatewayTestToken is ERC20 {
    constructor() ERC20("Test", "TST") {}

    function mint(address account, uint256 amount) external {
        _mint({account: account, value: amount});
    }
}

interface IGatewayRouterCallback {
    function beforeGatewayRouterPull() external;
}

interface IGatewayTokenTransferCallback {
    function beforeGatewayTokenTransfer() external;
}

contract GatewayCallbackToken is ERC20 {
    address public callback;
    address public gateway;

    bool internal _callingBack;

    constructor() ERC20("Callback", "CBK") {}

    function configure(address gatewayAddress, address callbackAddress) external {
        callback = callbackAddress;
        gateway = gatewayAddress;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (msg.sender == gateway && from == callback && to == gateway && !_callingBack) {
            _callingBack = true;
            IGatewayTokenTransferCallback(callback).beforeGatewayTokenTransfer();
            _callingBack = false;
        }

        return super.transferFrom({from: from, to: to, value: amount});
    }
}

contract GatewayDirtyERC165Payer {
    function supportsInterface(bytes4) external pure returns (bool) {
        assembly ("memory-safe") {
            mstore(0, 2)
            return(0, 32)
        }
    }
}

/// @notice Models an immutable protocol contract which catches and forgives a failed fee payment.
contract GatewayProtocolFeePayer {
    bool public feeWasForgiven;

    function payFee(IJBTerminal feeTerminal, address token, uint256 amount, uint256 sourceProjectId) external {
        if (token != JBConstants.NATIVE_TOKEN) IERC20(token).approve({spender: address(feeTerminal), value: amount});

        try feeTerminal.pay{value: token == JBConstants.NATIVE_TOKEN ? amount : 0}({
            projectId: JBConstants.FEE_BENEFICIARY_PROJECT_ID,
            token: token,
            amount: amount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(sourceProjectId)
        }) returns (
            uint256
        ) {
            feeWasForgiven = false;
        } catch {
            feeWasForgiven = true;
        }
    }
}

contract GatewayTestDirectory {
    mapping(uint256 projectId => mapping(address terminal => bool)) public isTerminal;
    mapping(uint256 projectId => mapping(address token => IJBTerminal terminal)) public primaryTerminal;
    mapping(uint256 projectId => IJBTerminal[] terminals) internal _terminalsOf;

    function isTerminalOf(uint256 projectId, IJBTerminal terminal) external view returns (bool) {
        return isTerminal[projectId][address(terminal)];
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return primaryTerminal[projectId][token];
    }

    function setIsTerminalOf(uint256 projectId, IJBTerminal terminal, bool flag) external {
        isTerminal[projectId][address(terminal)] = flag;
    }

    function setPrimaryTerminalOf(uint256 projectId, address token, IJBTerminal terminal) external {
        primaryTerminal[projectId][token] = terminal;
    }

    function setTerminalsOf(uint256 projectId, IJBTerminal[] calldata terminals) external {
        _terminalsOf[projectId] = terminals;
    }

    function terminalsOf(uint256 projectId) external view returns (IJBTerminal[] memory) {
        return _terminalsOf[projectId];
    }
}

interface IGatewayDirectoryProvider {
    function DIRECTORY() external view returns (IJBDirectory directory);
}

contract GatewayTestProjects {
    function count() external pure returns (uint256) {
        return 2;
    }
}

contract GatewayTestRouter {
    error GatewayTestRouter_FailureA();
    error GatewayTestRouter_FailureB();
    error GatewayTestRouter_FailureWithArgument(uint256 argument);

    address public beforePullCallback;
    uint256 public failureArgument;
    uint256 public mode = 1;
    uint256 public received;

    bool internal _callingBeforePull;

    receive() external payable {}

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
        _accept({token: token, amount: amount});
        _finish();
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
        _accept({token: token, amount: amount});
        _finish();
        return amount;
    }

    function setBeforePullCallback(address newCallback) external {
        beforePullCallback = newCallback;
    }

    function setFailureArgument(uint256 newArgument) external {
        failureArgument = newArgument;
    }

    function setMode(uint256 newMode) external {
        mode = newMode;
    }

    function _accept(address token, uint256 amount) internal {
        if (beforePullCallback != address(0) && !_callingBeforePull) {
            _callingBeforePull = true;
            IGatewayRouterCallback(beforePullCallback).beforeGatewayRouterPull();
            _callingBeforePull = false;
        }

        if (token == JBConstants.NATIVE_TOKEN) {
            require(msg.value == amount, "native amount");
        } else {
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "router transfer");
        }
        received += amount;
    }

    function _finish() internal view {
        if (mode == 1) revert GatewayTestRouter_FailureA();
        if (mode == 2) revert GatewayTestRouter_FailureB();
        if (mode == 3) {
            assembly ("memory-safe") {
                invalid()
            }
        }
        if (mode == 4) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (mode == 5) revert GatewayTestRouter_FailureWithArgument(failureArgument);
        if (mode == 6) {
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }
        if (mode == 7 && gasleft() < 6_000_000) {
            assembly ("memory-safe") {
                invalid()
            }
        }
    }
}

contract GatewayNestedPayer is IGatewayRouterCallback {
    uint256 internal constant _SOURCE_PROJECT_ID = 2;

    uint256 public amount;
    JBRouterTerminalGateway public gateway;
    GatewayTestRouter public router;
    GatewayTestToken public token;

    function beforeGatewayRouterPull() external {
        require(msg.sender == address(router));
        gateway.pay({
            projectId: 1,
            token: address(token),
            amount: amount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(_SOURCE_PROJECT_ID)
        });
    }

    function configure(
        JBRouterTerminalGateway gatewayToUse,
        GatewayTestRouter routerToUse,
        GatewayTestToken tokenToUse,
        uint256 amountToUse
    )
        external
    {
        amount = amountToUse;
        gateway = gatewayToUse;
        router = routerToUse;
        token = tokenToUse;
        tokenToUse.approve({spender: address(gatewayToUse), value: amountToUse});
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract GatewayReentrantPayer is IGatewayTokenTransferCallback {
    uint256 internal constant _SOURCE_PROJECT_ID = 2;

    JBRouterTerminalGateway public gateway;
    uint256 public reentryAmount;
    bool public reentryReverted;
    GatewayCallbackToken public token;

    function attack(JBRouterTerminalGateway gatewayToUse, GatewayCallbackToken tokenToUse, uint256 amount) external {
        gateway = gatewayToUse;
        token = tokenToUse;
        reentryAmount = amount;

        tokenToUse.approve({spender: address(gatewayToUse), value: amount * 2});
        gatewayToUse.pay({
            projectId: 1,
            token: address(tokenToUse),
            amount: amount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(_SOURCE_PROJECT_ID)
        });
    }

    function beforeGatewayTokenTransfer() external {
        require(msg.sender == address(token));

        try gateway.pay({
            projectId: 1,
            token: address(token),
            amount: reentryAmount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(_SOURCE_PROJECT_ID)
        }) returns (
            uint256
        ) {}
        catch {
            reentryReverted = true;
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Models the source terminal's fail-open protocol-fee and project-payout boundaries.
contract GatewayTestSourceTerminal {
    error GatewayTestSourceTerminal_RefundRejected();

    mapping(uint256 projectId => mapping(address token => uint256 amount)) public credited;
    bool public feeWasForgiven;
    bool public payoutWasNullified;
    bool public rejectRefund;

    receive() external payable {}

    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
    {
        if (rejectRefund) revert GatewayTestSourceTerminal_RefundRejected();

        if (token == JBConstants.NATIVE_TOKEN) {
            require(msg.value == amount, "native refund amount");
        } else {
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "refund transfer");
        }
        credited[projectId][token] += amount;
    }

    function payFee(IJBTerminal feeTerminal, address token, uint256 amount, uint256 sourceProjectId) external {
        uint256 value = _beforeCall({terminal: feeTerminal, token: token, amount: amount});

        try feeTerminal.pay{value: value}({
            projectId: JBConstants.FEE_BENEFICIARY_PROJECT_ID,
            token: token,
            amount: amount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(sourceProjectId)
        }) returns (
            uint256
        ) {
            feeWasForgiven = false;
        } catch {
            feeWasForgiven = true;
        }
    }

    function sendPayout(
        IJBTerminal terminal,
        uint256 destinationProjectId,
        address token,
        uint256 amount,
        uint256 sourceProjectId,
        bool preferAddToBalance
    )
        external
    {
        uint256 value = _beforeCall({terminal: terminal, token: token, amount: amount});

        if (preferAddToBalance) {
            try terminal.addToBalanceOf{value: value}({
                projectId: destinationProjectId,
                token: token,
                amount: amount,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: abi.encodePacked(sourceProjectId)
            }) {
                payoutWasNullified = false;
            } catch {
                payoutWasNullified = true;
            }
        } else {
            try terminal.pay{value: value}({
                projectId: destinationProjectId,
                token: token,
                amount: amount,
                beneficiary: address(this),
                minReturnedTokens: 0,
                memo: "",
                metadata: abi.encodePacked(sourceProjectId)
            }) returns (
                uint256
            ) {
                payoutWasNullified = false;
            } catch {
                payoutWasNullified = true;
            }
        }
    }

    function setRejectRefund(bool flag) external {
        rejectRefund = flag;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function _beforeCall(IJBTerminal terminal, address token, uint256 amount) internal returns (uint256 value) {
        if (token == JBConstants.NATIVE_TOKEN) return amount;
        IERC20(token).approve(address(terminal), amount);
    }
}

/// @notice Minimal store shape used to deploy the current core terminal in a payer-propagation regression.
contract GatewayTestTerminalStore {
    /// @notice Return no directory because the regression only exercises the terminal's payer and interface shape.
    /// @return directory The empty directory address.
    function DIRECTORY() external pure returns (address directory) {
        return address(0);
    }
}

contract GatewayGasHarness is JBRouterTerminalGateway {
    constructor()
        JBRouterTerminalGateway(
            IJBDirectory(address(1)), IPermit2(address(2)), IJBRouterTerminal(address(3)), address(0)
        )
    {}

    function gasExhaustedErrorHash() external pure returns (bytes32 errorHash) {
        return _GAS_EXHAUSTED_ERROR_HASH;
    }

    function qualifiedGasLimitFor(
        JBPendingRouterTerminalCallFailure memory failure,
        uint256 requestedGasLimit,
        uint256 maximumGasLimit
    )
        external
        pure
        returns (uint256 gasLimit)
    {
        return _qualifiedGasLimitFor({
            failure: failure, requestedGasLimit: requestedGasLimit, maximumGasLimit: maximumGasLimit
        });
    }
}

contract GatewayTestPermit2 {
    address public lastOwner;
    address public lastSpender;

    function permit(address owner, IAllowanceTransfer.PermitSingle calldata permitSingle, bytes calldata) external {
        lastOwner = owner;
        lastSpender = permitSingle.spender;
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        IERC20(token).transferFrom({from: from, to: to, value: amount});
    }
}

contract GatewayTestTrustedForwarder {
    function forward(
        address target,
        bytes calldata data,
        address originalSender
    )
        external
        payable
        returns (bytes memory result)
    {
        (bool success, bytes memory returnData) = target.call{value: msg.value}(abi.encodePacked(data, originalSender));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return returnData;
    }
}

contract RouterTerminalGatewayFailureTest is Test {
    uint256 internal constant _AMOUNT = 25_003;
    uint256 internal constant _DESTINATION_PROJECT_ID = 1;
    uint256 internal constant _SOURCE_PROJECT_ID = 2;

    bytes32 internal constant _ID = bytes32(uint256(1));

    GatewayTestDirectory internal directory;
    JBRouterTerminalGateway internal gateway;
    JBRouterTerminalRegistry internal registry;
    GatewayTestRouter internal router;
    GatewayTestSourceTerminal internal sourceTerminal;
    GatewayTestToken internal token;

    function setUp() public {
        directory = new GatewayTestDirectory();
        router = new GatewayTestRouter();
        gateway = new JBRouterTerminalGateway({
            directory: IJBDirectory(address(directory)),
            permit2: IPermit2(address(0)),
            router: IJBRouterTerminal(address(router)),
            trustedForwarder: address(0)
        });
        registry = _registryFor(gateway);
        sourceTerminal = new GatewayTestSourceTerminal();
        token = new GatewayTestToken();

        directory.setIsTerminalOf({
            projectId: _SOURCE_PROJECT_ID, terminal: IJBTerminal(address(sourceTerminal)), flag: true
        });
        directory.setPrimaryTerminalOf({
            projectId: _SOURCE_PROJECT_ID, token: address(token), terminal: IJBTerminal(address(sourceTerminal))
        });
        directory.setPrimaryTerminalOf({
            projectId: _SOURCE_PROJECT_ID,
            token: JBConstants.NATIVE_TOKEN,
            terminal: IJBTerminal(address(sourceTerminal))
        });

        token.mint(address(sourceTerminal), _AMOUNT);
        vm.deal(address(sourceTerminal), _AMOUNT);
    }

    function _qualifyWithMatchingFailures() internal {
        _qualifyWithMatchingFailures({id: _ID, metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});
    }

    function _qualifyWithMatchingFailures(bytes32 id, bytes memory metadata) internal {
        gateway.processPendingCall({id: id, memo: "", metadata: metadata});
        vm.warp(block.timestamp + gateway.RETRY_DELAY());
        gateway.processPendingCall({id: id, memo: "", metadata: metadata});
        vm.warp(block.timestamp + gateway.RETRY_DELAY());
        gateway.processPendingCall({id: id, memo: "", metadata: metadata});
    }

    function _queueFee(address paymentToken) internal {
        sourceTerminal.payFee({
            feeTerminal: registry, token: paymentToken, amount: _AMOUNT, sourceProjectId: _SOURCE_PROJECT_ID
        });
    }

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

    function testFuzz_failedFeeConservesOriginalInput(uint128 amount, uint96 sourceProjectId) public {
        vm.assume(amount != 0 && sourceProjectId != 0);
        token.mint(address(sourceTerminal), amount);

        sourceTerminal.payFee({
            feeTerminal: registry, token: address(token), amount: amount, sourceProjectId: sourceProjectId
        });

        JBPendingRouterTerminalCall memory call = gateway.pendingCallOf(_ID);
        assertFalse(sourceTerminal.feeWasForgiven());
        assertEq(call.amount, amount);
        assertEq(call.sourceProjectId, sourceProjectId);
        assertEq(token.balanceOf(address(gateway)), amount);
        assertEq(token.balanceOf(address(sourceTerminal)), _AMOUNT);
        assertEq(token.balanceOf(address(registry)), 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function test_addToBalancePayoutUsesTheSameRetentionAndRetryPath() public {
        sourceTerminal.sendPayout({
            terminal: registry,
            destinationProjectId: _DESTINATION_PROJECT_ID,
            token: address(token),
            amount: _AMOUNT,
            sourceProjectId: _SOURCE_PROJECT_ID,
            preferAddToBalance: true
        });

        assertFalse(sourceTerminal.payoutWasNullified(), "gateway should absorb add-to-balance failure");
        assertTrue(gateway.pendingCallOf(_ID).preferAddToBalance, "pending operation should remain add-to-balance");

        router.setMode(0);
        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertEq(token.balanceOf(address(router)), _AMOUNT, "retry should settle the payout");
        assertEq(gateway.pendingCallOf(_ID).refundTo, address(0), "successful retry should delete pending state");
    }

    function test_callbackTokenCannotOvercreditPooledCustody() public {
        uint256 attackerAmount = 100;
        uint256 victimAmount = 1000;
        GatewayCallbackToken callbackToken = new GatewayCallbackToken();
        GatewayReentrantPayer attacker = new GatewayReentrantPayer();

        callbackToken.configure({gatewayAddress: address(gateway), callbackAddress: address(attacker)});
        callbackToken.mint({account: address(sourceTerminal), amount: victimAmount});
        callbackToken.mint({account: address(attacker), amount: attackerAmount * 2});

        sourceTerminal.payFee({
            feeTerminal: registry,
            token: address(callbackToken),
            amount: victimAmount,
            sourceProjectId: _SOURCE_PROJECT_ID
        });
        attacker.attack({gatewayToUse: gateway, tokenToUse: callbackToken, amount: attackerAmount});

        assertTrue(attacker.reentryReverted(), "nested intake should revert inside the callback");
        assertEq(gateway.pendingCallCount(), 2, "the callback must not create an over-credited pending call");
        assertEq(gateway.pendingCallOf(_ID).amount, victimAmount, "victim claim changed");
        assertEq(gateway.pendingCallOf(bytes32(uint256(2))).amount, attackerAmount, "attacker claim was inflated");
        assertEq(
            callbackToken.balanceOf(address(gateway)), victimAmount + attackerAmount, "custody must cover every claim"
        );
    }

    function test_chainAwareGasCapBoundsOtherwiseUnexecutableEscalation() public {
        GatewayGasHarness harness = new GatewayGasHarness();
        uint256 maximumGasLimit = 11_000_000;
        JBPendingRouterTerminalCallFailure memory failure = JBPendingRouterTerminalCallFailure({
            count: 2, errorHash: harness.gasExhaustedErrorHash(), lastFailureAt: 0
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

        uint256 baseGasLimit = gateway.QUALIFIED_CALL_GAS();
        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalGateway.JBRouterTerminalGateway_BlockGasLimitTooLow.selector,
                baseGasLimit - 1,
                baseGasLimit
            )
        );
        harness.qualifiedGasLimitFor({failure: failure, requestedGasLimit: 0, maximumGasLimit: baseGasLimit - 1});
    }

    function test_changedErrorResetsMatchingFailureStreak() public {
        _queueFee(address(token));
        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        JBPendingRouterTerminalCallFailure memory first = gateway.pendingCallFailureOf(_ID);
        assertEq(first.count, 1);

        vm.warp(block.timestamp + gateway.RETRY_DELAY());
        router.setMode(2);
        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        JBPendingRouterTerminalCallFailure memory changed = gateway.pendingCallFailureOf(_ID);
        assertEq(changed.count, 1, "a different exact error must restart qualification");
        assertNotEq(changed.errorHash, first.errorHash, "different custom errors must have different fingerprints");

        vm.warp(block.timestamp + gateway.RETRY_DELAY());
        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});
        assertEq(gateway.pendingCallFailureOf(_ID).count, 2, "the new matching error can start a fresh streak");
    }

    function test_dirtyERC165ResponseDoesNotAffectSourceProjectRetention() public {
        GatewayDirtyERC165Payer payer = new GatewayDirtyERC165Payer();
        token.mint({account: address(payer), amount: _AMOUNT});

        vm.startPrank(address(payer));
        token.approve({spender: address(gateway), value: _AMOUNT});
        uint256 beneficiaryTokenCount = gateway.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(token),
            amount: _AMOUNT,
            beneficiary: address(payer),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(_SOURCE_PROJECT_ID)
        });
        vm.stopPrank();

        assertEq(beneficiaryTokenCount, 0, "failed route should be retained");
        assertEq(gateway.pendingCallCount(), 1, "payer ERC-165 behavior must not affect explicit retention");
        assertEq(gateway.pendingCallOf(_ID).refundTo, address(payer), "original payer should remain observable");
        assertEq(token.balanceOf(address(gateway)), _AMOUNT, "retained input must remain fully collateralized");
    }

    function test_dynamicErrorArgumentsDoNotResetMatchingFailureStreak() public {
        router.setMode(5);
        router.setFailureArgument(1);
        _queueFee(address(token));
        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        JBPendingRouterTerminalCallFailure memory first = gateway.pendingCallFailureOf(_ID);
        assertEq(first.count, 1);

        vm.warp(block.timestamp + gateway.RETRY_DELAY());
        router.setFailureArgument(2);
        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        JBPendingRouterTerminalCallFailure memory second = gateway.pendingCallFailureOf(_ID);
        assertEq(second.count, 2, "arguments from the same custom error must not reset qualification");
        assertEq(second.errorHash, first.errorHash, "the failure class should encode only the selector");
    }

    function test_expandableRetryGasSettlesRouteAboveDefaultBudget() public {
        _queueFee(address(token));
        router.setMode(7);

        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertEq(gateway.pendingCallFailureOf(_ID).count, 1, "the exhausted base budget should start escalation");
        assertEq(gateway.pendingCallOf(_ID).amount, _AMOUNT, "gas exhaustion must preserve custody");

        vm.warp(block.timestamp + gateway.RETRY_DELAY());
        uint256 beneficiaryTokenCount =
            gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertEq(beneficiaryTokenCount, _AMOUNT, "the automatically expanded retry should settle the healthy route");
        assertEq(gateway.pendingCallOf(_ID).refundTo, address(0), "settled retry must clear pending state");
        assertEq(token.balanceOf(address(gateway)), 0, "settled retry must consume custody");
    }

    function test_gasExhaustionRequiresEscalatedCustomBudget() public {
        router.setMode(3);
        _queueFee(address(token));
        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        vm.warp(block.timestamp + gateway.RETRY_DELAY());
        uint256 baseGasLimit = gateway.QUALIFIED_CALL_GAS();
        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RetryGasLimitTooLow.selector);
        gateway.processPendingCallWithGas({
            id: _ID, gasLimit: baseGasLimit, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)
        });

        assertEq(gateway.pendingCallFailureOf(_ID).count, 1, "an undersized custom retry must not advance custody");
    }

    function test_gatewayPermitFailureFallsBackToDirectAllowance() public {
        IPermit2 revertingPermit2 = IPermit2(makeAddr("revertingPermit2"));
        vm.etch(address(revertingPermit2), hex"00");
        JBRouterTerminalGateway compatibleGateway = new JBRouterTerminalGateway({
            directory: IJBDirectory(address(directory)),
            permit2: revertingPermit2,
            router: IJBRouterTerminal(address(router)),
            trustedForwarder: address(0)
        });
        address payer = makeAddr("payer");
        token.mint({account: payer, amount: _AMOUNT});
        vm.prank(payer);
        token.approve({spender: address(compatibleGateway), value: _AMOUNT});

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

        router.setMode(0);
        vm.recordLogs();
        vm.prank(payer);
        uint256 beneficiaryTokenCount = compatibleGateway.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(token),
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
                    && logs[i].topics[1] == bytes32(uint256(uint160(address(token))))
                    && logs[i].topics[2] == bytes32(uint256(uint160(payer)))
            ) {
                sawPermitFailure = true;
            }
        }

        assertEq(beneficiaryTokenCount, _AMOUNT, "direct allowance should survive a failed Permit2 approval");
        assertTrue(sawPermitFailure, "failed Permit2 approval should remain observable");
        assertEq(token.balanceOf(address(router)), _AMOUNT, "fallback payment should settle through the router");
    }

    function test_gatewayPreservesERC2771AndPermit2PaymentSurface() public {
        GatewayTestPermit2 permit2 = new GatewayTestPermit2();
        GatewayTestTrustedForwarder forwarder = new GatewayTestTrustedForwarder();
        JBRouterTerminalGateway compatibleGateway = new JBRouterTerminalGateway({
            directory: IJBDirectory(address(directory)),
            permit2: IPermit2(address(permit2)),
            router: IJBRouterTerminal(address(router)),
            trustedForwarder: address(forwarder)
        });
        address payer = makeAddr("payer");
        token.mint({account: payer, amount: _AMOUNT});
        vm.prank(payer);
        token.approve({spender: address(permit2), value: _AMOUNT});

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
            compatibleGateway.pay, (_DESTINATION_PROJECT_ID, address(token), _AMOUNT, payer, 0, "", metadata)
        );

        router.setMode(0);
        bytes memory result =
            forwarder.forward({target: address(compatibleGateway), data: callData, originalSender: payer});

        assertEq(abi.decode(result, (uint256)), _AMOUNT, "forwarded payment should return the router result");
        assertEq(permit2.lastOwner(), payer, "Permit2 owner must be the ERC-2771 sender");
        assertEq(permit2.lastSpender(), address(compatibleGateway), "Permit2 must authorize the gateway");
        assertEq(token.balanceOf(address(router)), _AMOUNT, "Permit2 payment should settle through the router");
        assertTrue(
            compatibleGateway.supportsInterface(type(IJBPermitTerminal).interfaceId),
            "resolved gateway must advertise Permit2"
        );
    }

    function test_failedDirectAddToBalanceRevertsSynchronously() public {
        token.mint(address(this), _AMOUNT);
        token.approve(address(gateway), _AMOUNT);

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RouteFailed.selector);
        gateway.addToBalanceOf({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(token),
            amount: _AMOUNT,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: ""
        });

        assertEq(gateway.pendingCallCount(), 0, "ordinary add-to-balance failure must not be retained");
        assertEq(token.balanceOf(address(this)), _AMOUNT, "revert should restore the payer's token");
    }

    function test_failedDirectPayRevertsSynchronously() public {
        token.mint(address(this), _AMOUNT);
        token.approve(address(gateway), _AMOUNT);

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RouteFailed.selector);
        gateway.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(token),
            amount: _AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        assertEq(gateway.pendingCallCount(), 0, "ordinary zero-minimum pay failure must not be retained");
        assertEq(token.balanceOf(address(this)), _AMOUNT, "revert should restore the payer's token");
    }

    function test_finalChangedErrorResetsWithoutRefunding() public {
        _queueFee(address(token));
        _qualifyWithMatchingFailures();
        bytes32 qualifiedError = gateway.pendingCallFailureOf(_ID).errorHash;

        vm.warp(block.timestamp + gateway.RETRY_DELAY());
        router.setMode(2);
        (bool wasRefunded,) =
            gateway.finalizePendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        JBPendingRouterTerminalCallFailure memory changed = gateway.pendingCallFailureOf(_ID);
        assertFalse(wasRefunded, "changed failure must remain retryable");
        assertEq(changed.count, 1, "changed final error must reset the streak");
        assertNotEq(changed.errorHash, qualifiedError, "final error should record the new fingerprint");
        assertEq(token.balanceOf(address(gateway)), _AMOUNT, "gateway should retain custody");
        assertEq(sourceTerminal.credited(_SOURCE_PROJECT_ID, address(token)), 0, "source project must not be refunded");
    }

    function test_finalMatchingAddToBalanceErrorRefundsOriginalProject() public {
        sourceTerminal.sendPayout({
            terminal: registry,
            destinationProjectId: _DESTINATION_PROJECT_ID,
            token: address(token),
            amount: _AMOUNT,
            sourceProjectId: _SOURCE_PROJECT_ID,
            preferAddToBalance: true
        });
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + gateway.RETRY_DELAY());

        (bool wasRefunded,) =
            gateway.finalizePendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertTrue(wasRefunded);
        assertEq(sourceTerminal.credited(_SOURCE_PROJECT_ID, address(token)), _AMOUNT);
        assertEq(token.balanceOf(address(gateway)), 0);
    }

    function test_finalMatchingErrorRefundsOriginalProject() public {
        _queueFee(address(token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + gateway.RETRY_DELAY());

        (bool wasRefunded, uint256 beneficiaryTokenCount) =
            gateway.finalizePendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertTrue(wasRefunded, "same final error should authorize refund");
        assertEq(beneficiaryTokenCount, 0);
        assertEq(sourceTerminal.credited(_SOURCE_PROJECT_ID, address(token)), _AMOUNT, "project should be credited");
        assertEq(token.balanceOf(address(sourceTerminal)), _AMOUNT, "source terminal should reclaim the input token");
        assertEq(token.balanceOf(address(gateway)), 0, "gateway custody should clear");
        assertEq(gateway.pendingCallOf(_ID).refundTo, address(0), "pending state should clear");
    }

    function test_finalMatchingNativePayoutErrorRefundsOriginalProject() public {
        sourceTerminal.sendPayout({
            terminal: registry,
            destinationProjectId: _DESTINATION_PROJECT_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: _AMOUNT,
            sourceProjectId: _SOURCE_PROJECT_ID,
            preferAddToBalance: true
        });
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + gateway.RETRY_DELAY());

        (bool wasRefunded,) =
            gateway.finalizePendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertTrue(wasRefunded);
        assertEq(
            sourceTerminal.credited(_SOURCE_PROJECT_ID, JBConstants.NATIVE_TOKEN),
            _AMOUNT,
            "native refund should credit"
        );
        assertEq(address(gateway).balance, 0, "native gateway custody should clear");
    }

    function test_finalRefundFailureRollsBackAndPreservesQualification() public {
        _queueFee(address(token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + gateway.RETRY_DELAY());
        sourceTerminal.setRejectRefund(true);

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RefundFailed.selector);
        gateway.finalizePendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertEq(gateway.pendingCallFailureOf(_ID).count, 3, "failed refund must preserve qualification");
        assertEq(gateway.pendingCallOf(_ID).amount, _AMOUNT, "failed refund must restore pending state");
        assertEq(token.balanceOf(address(gateway)), _AMOUNT, "failed refund must preserve custody");
    }

    function test_finalRefundFallsBackToCurrentPrimaryTerminal() public {
        _queueFee(address(token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + gateway.RETRY_DELAY());

        GatewayTestSourceTerminal primaryTerminal = new GatewayTestSourceTerminal();
        sourceTerminal.setRejectRefund(true);
        directory.setPrimaryTerminalOf({
            projectId: _SOURCE_PROJECT_ID, token: address(token), terminal: IJBTerminal(address(primaryTerminal))
        });

        (bool wasRefunded,) =
            gateway.finalizePendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertTrue(wasRefunded, "current primary terminal should accept the autonomous fallback");
        assertEq(primaryTerminal.credited(_SOURCE_PROJECT_ID, address(token)), _AMOUNT);
        assertEq(token.balanceOf(address(gateway)), 0, "successful fallback must clear custody");
    }

    function test_finalRefundSkipsCircularPrimaryAndUsesRegisteredAlternative() public {
        _queueFee(address(token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + gateway.RETRY_DELAY());

        GatewayTestSourceTerminal alternativeTerminal = new GatewayTestSourceTerminal();
        directory.setIsTerminalOf({
            projectId: _SOURCE_PROJECT_ID, terminal: IJBTerminal(address(sourceTerminal)), flag: false
        });
        directory.setPrimaryTerminalOf({
            projectId: _SOURCE_PROJECT_ID, token: address(token), terminal: IJBTerminal(address(registry))
        });

        IJBTerminal[] memory terminals = new IJBTerminal[](2);
        terminals[0] = IJBTerminal(address(registry));
        terminals[1] = IJBTerminal(address(alternativeTerminal));
        directory.setTerminalsOf({projectId: _SOURCE_PROJECT_ID, terminals: terminals});

        (bool wasRefunded,) =
            gateway.finalizePendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertTrue(wasRefunded, "the registered non-circular terminal should receive the refund");
        assertEq(alternativeTerminal.credited(_SOURCE_PROJECT_ID, address(token)), _AMOUNT);
        assertEq(token.balanceOf(address(gateway)), 0, "successful alternative refund must clear custody");
    }

    function test_finalRefundUsesCurrentPrimaryWhenOriginalTerminalWasRemoved() public {
        _queueFee(address(token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + gateway.RETRY_DELAY());

        GatewayTestSourceTerminal primaryTerminal = new GatewayTestSourceTerminal();
        directory.setIsTerminalOf({
            projectId: _SOURCE_PROJECT_ID, terminal: IJBTerminal(address(sourceTerminal)), flag: false
        });
        directory.setPrimaryTerminalOf({
            projectId: _SOURCE_PROJECT_ID, token: address(token), terminal: IJBTerminal(address(primaryTerminal))
        });

        (bool wasRefunded,) =
            gateway.finalizePendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertTrue(wasRefunded, "removed source terminal should be replaced by the current primary");
        assertEq(
            sourceTerminal.credited(_SOURCE_PROJECT_ID, address(token)), 0, "removed terminal must not be credited"
        );
        assertEq(primaryTerminal.credited(_SOURCE_PROJECT_ID, address(token)), _AMOUNT);
    }

    function test_finalSuccessfulAttemptSettlesWithoutRefund() public {
        _queueFee(address(token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + gateway.RETRY_DELAY());
        router.setMode(0);

        (bool wasRefunded, uint256 beneficiaryTokenCount) =
            gateway.finalizePendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertFalse(wasRefunded);
        assertEq(beneficiaryTokenCount, _AMOUNT);
        assertEq(token.balanceOf(address(router)), _AMOUNT, "final attempt should settle into router");
        assertEq(token.balanceOf(address(gateway)), 0, "gateway custody should clear");
        assertEq(sourceTerminal.credited(_SOURCE_PROJECT_ID, address(token)), 0, "successful route must not refund");
    }

    function test_initialSuccessDoesNotCreatePendingCall() public {
        router.setMode(0);
        _queueFee(address(token));

        assertFalse(sourceTerminal.feeWasForgiven());
        assertEq(gateway.pendingCallCount(), 0, "successful route should not issue a pending id");
        assertEq(token.balanceOf(address(router)), _AMOUNT);
        assertEq(token.balanceOf(address(gateway)), 0);
    }

    function test_malformedSuccessfulPayReturnCannotCreateUnbackedPendingCall() public {
        router.setMode(4);
        _queueFee(address(token));

        assertFalse(sourceTerminal.feeWasForgiven());
        assertEq(gateway.pendingCallCount(), 0, "successful side effects must not be recorded as failed custody");
        assertEq(token.balanceOf(address(router)), _AMOUNT, "router retained the successfully pulled input");
        assertEq(token.balanceOf(address(gateway)), 0, "gateway has no retained input to represent");
    }

    function test_matchingCheapEmptyErrorsCanQualifyAndRefund() public {
        router.setMode(6);
        _queueFee(address(token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + gateway.RETRY_DELAY());

        (bool wasRefunded,) =
            gateway.finalizePendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertTrue(wasRefunded, "matching explicit empty reverts should qualify");
        assertEq(sourceTerminal.credited(_SOURCE_PROJECT_ID, address(token)), _AMOUNT);
    }

    function test_matchingGasExhaustionEscalatesAndEventuallyRefunds() public {
        router.setMode(3);
        _queueFee(address(token));

        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});
        JBPendingRouterTerminalCallFailure memory first = gateway.pendingCallFailureOf(_ID);
        assertEq(first.count, 1, "the first exhausted qualified budget should start the streak");

        vm.warp(block.timestamp + gateway.RETRY_DELAY());
        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});
        JBPendingRouterTerminalCallFailure memory second = gateway.pendingCallFailureOf(_ID);
        assertEq(second.count, 2, "the second exhausted, larger budget should continue the streak");
        assertEq(second.errorHash, first.errorHash, "gas exhaustion must have one stable failure fingerprint");

        vm.warp(block.timestamp + gateway.RETRY_DELAY());
        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});
        assertEq(gateway.pendingCallFailureOf(_ID).count, 3, "the third larger budget should qualify finalization");

        vm.warp(block.timestamp + gateway.RETRY_DELAY());
        (bool wasRefunded,) =
            gateway.finalizePendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertTrue(wasRefunded, "four escalating exhausted budgets should prove the sink and release custody");
        assertEq(sourceTerminal.credited(_SOURCE_PROJECT_ID, address(token)), _AMOUNT);
        assertEq(token.balanceOf(address(gateway)), 0, "final refund must clear retained custody");
    }

    function test_multiplePendingCallsKeepCustodySeparated() public {
        token.mint(address(sourceTerminal), _AMOUNT);
        _queueFee(address(token));
        _queueFee(address(token));

        assertEq(gateway.pendingCallCount(), 2);
        assertEq(token.balanceOf(address(gateway)), _AMOUNT * 2);

        router.setMode(0);
        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertEq(gateway.pendingCallOf(_ID).refundTo, address(0), "first pending call should settle");
        assertEq(gateway.pendingCallOf(bytes32(uint256(2))).amount, _AMOUNT, "second pending call should remain");
        assertEq(token.balanceOf(address(gateway)), _AMOUNT, "second pending input must remain in custody");
        assertEq(token.balanceOf(address(router)), _AMOUNT, "only first pending input should settle");
    }

    function test_nestedSameTokenRouteRestoresOuterRouterAllowance() public {
        uint256 nestedAmount = 1000;
        GatewayNestedPayer nestedPayer = new GatewayNestedPayer();
        token.mint({account: address(nestedPayer), amount: nestedAmount});
        nestedPayer.configure({
            gatewayToUse: gateway, routerToUse: router, tokenToUse: token, amountToUse: nestedAmount
        });

        router.setMode(0);
        router.setBeforePullCallback(address(nestedPayer));
        sourceTerminal.sendPayout({
            terminal: registry,
            destinationProjectId: _DESTINATION_PROJECT_ID,
            token: address(token),
            amount: _AMOUNT,
            sourceProjectId: _SOURCE_PROJECT_ID,
            preferAddToBalance: false
        });

        assertFalse(sourceTerminal.payoutWasNullified());
        assertEq(gateway.pendingCallCount(), 0, "nested route must not erase the outer Router allowance");
        assertEq(token.balanceOf(address(router)), _AMOUNT + nestedAmount, "both same-token routes should settle");
        assertEq(token.balanceOf(address(gateway)), 0);
    }

    /// @notice Raw source-project metadata opts a non-terminal protocol payer into project-accounting retention.
    function test_nonTerminalPayerWithSourceProjectMetadataIsRetained() public {
        GatewayProtocolFeePayer payer = new GatewayProtocolFeePayer();
        token.mint({account: address(payer), amount: _AMOUNT});

        payer.payFee({
            feeTerminal: registry, token: address(token), amount: _AMOUNT, sourceProjectId: _SOURCE_PROJECT_ID
        });

        JBPendingRouterTerminalCall memory call = gateway.pendingCallOf(_ID);
        assertFalse(payer.feeWasForgiven(), "Gateway custody must stay outside the protocol payer's catch boundary");
        assertEq(call.refundTo, address(payer), "registry should preserve the non-terminal protocol payer");
        assertTrue(call.refundToProject, "raw source-project metadata should opt into project accounting refund");
        assertEq(call.sourceProjectId, _SOURCE_PROJECT_ID);
        assertEq(token.balanceOf(address(gateway)), _AMOUNT, "retained input must remain fully collateralized");

        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + gateway.RETRY_DELAY());
        (bool wasRefunded,) =
            gateway.finalizePendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertTrue(wasRefunded, "matching failures should refund the named source project");
        assertEq(sourceTerminal.credited(_SOURCE_PROJECT_ID, address(token)), _AMOUNT, "project should be credited");
        assertEq(token.balanceOf(address(gateway)), 0, "refunded custody should clear");
    }

    function test_nonzeroMinimumStillRevertsSynchronously() public {
        token.mint(address(this), _AMOUNT);
        token.approve(address(gateway), _AMOUNT);

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RouteFailed.selector);
        gateway.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(token),
            amount: _AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 1,
            memo: "",
            metadata: ""
        });

        assertEq(gateway.pendingCallCount(), 0, "gateway must not hide a non-zero minimum failure");
        assertEq(token.balanceOf(address(this)), _AMOUNT, "revert should restore the payer's token");
    }

    function test_processRejectsChangedCalldata() public {
        _queueFee(address(token));

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_CallDataMismatch.selector);
        gateway.processPendingCall({id: _ID, memo: "changed", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertEq(gateway.pendingCallFailureOf(_ID).count, 0);
        assertEq(token.balanceOf(address(gateway)), _AMOUNT);
    }

    function test_processRequiresDelayBetweenQualifiedFailures() public {
        _queueFee(address(token));
        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_PendingCallNotReady.selector);
        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertEq(gateway.pendingCallFailureOf(_ID).count, 1);
    }

    function test_processRequiresFinalizerAfterThreeMatchingFailures() public {
        _queueFee(address(token));
        _qualifyWithMatchingFailures();
        vm.warp(block.timestamp + gateway.RETRY_DELAY());

        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_PendingCallRequiresFinalization.selector);
        gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertEq(gateway.pendingCallFailureOf(_ID).count, 3);
    }

    function test_successfulPermissionlessRetrySettlesPendingCall() public {
        _queueFee(address(token));
        router.setMode(0);

        uint256 beneficiaryTokenCount =
            gateway.processPendingCall({id: _ID, memo: "", metadata: abi.encodePacked(_SOURCE_PROJECT_ID)});

        assertEq(beneficiaryTokenCount, _AMOUNT);
        assertEq(token.balanceOf(address(router)), _AMOUNT);
        assertEq(token.balanceOf(address(gateway)), 0);
        assertEq(gateway.pendingCallOf(_ID).refundTo, address(0));
        assertEq(gateway.pendingCallFailureOf(_ID).count, 0);
    }

    function test_terminalCallWithoutSourceProjectRevertsSynchronously() public {
        vm.startPrank(address(sourceTerminal));
        token.approve(address(gateway), _AMOUNT);
        vm.expectPartialRevert(JBRouterTerminalGateway.JBRouterTerminalGateway_RouteFailed.selector);
        gateway.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(token),
            amount: _AMOUNT,
            beneficiary: address(sourceTerminal),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        vm.stopPrank();

        assertEq(gateway.pendingCallCount(), 0, "malformed terminal metadata must not create direct-refund custody");
        assertEq(token.balanceOf(address(sourceTerminal)), _AMOUNT, "revert should restore terminal funds");
    }

    function test_threeMatchingFailuresAdvanceQualification() public {
        _queueFee(address(token));
        _qualifyWithMatchingFailures();

        JBPendingRouterTerminalCallFailure memory failure = gateway.pendingCallFailureOf(_ID);
        assertEq(failure.count, 3);
        assertNotEq(failure.errorHash, bytes32(0));
        assertEq(failure.lastFailureAt, block.timestamp);
        assertEq(token.balanceOf(address(gateway)), _AMOUNT, "every failed pull must roll back to gateway custody");
    }

    function test_underfundedRetryCannotAdvanceQualification() public {
        _queueFee(address(token));

        bytes memory data =
            abi.encodeCall(gateway.processPendingCall, (_ID, "", bytes(abi.encodePacked(_SOURCE_PROJECT_ID))));
        (bool success,) = address(gateway).call{gas: gateway.QUALIFIED_CALL_GAS() + 100_000}(data);

        assertFalse(success, "underfunded retry must revert");
        assertEq(gateway.pendingCallFailureOf(_ID).count, 0, "underfunded retry must not qualify");
        assertEq(gateway.pendingCallOf(_ID).amount, _AMOUNT, "pending call must remain intact");
        assertEq(token.balanceOf(address(gateway)), _AMOUNT, "custody must remain intact");
    }

    /// @notice Pins Registry propagation of the real core terminal as the preferred refund target.
    function test_realCoreMultiTerminalPropagatesPreferredRefundTarget() public {
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

        token.mint({account: address(multiTerminal), amount: _AMOUNT});
        vm.startPrank(address(multiTerminal));
        token.approve({spender: address(registry), value: _AMOUNT});
        uint256 beneficiaryTokenCount = registry.pay({
            projectId: _DESTINATION_PROJECT_ID,
            token: address(token),
            amount: _AMOUNT,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: abi.encodePacked(_SOURCE_PROJECT_ID)
        });
        vm.stopPrank();

        JBPendingRouterTerminalCall memory call = gateway.pendingCallOf(_ID);
        assertEq(beneficiaryTokenCount, 0, "failed route should be retained");
        assertEq(call.refundTo, address(multiTerminal), "registry must preserve the source terminal as refund target");
        assertTrue(call.refundToProject, "raw source-project metadata should qualify for project refund");
        assertEq(call.sourceProjectId, _SOURCE_PROJECT_ID);
        assertEq(token.balanceOf(address(gateway)), _AMOUNT, "retained input must remain fully collateralized");
    }

    /// @notice Reproduces the deployed fail-open boundary: the unchanged registry bubbles a router failure, so the
    /// source terminal forgives the fee while retaining its input token.
    function test_reproducesFeeForgivenessWhenRouterReverts() public {
        JBRouterTerminalRegistry directRegistry = _registryFor(IJBTerminal(address(router)));

        sourceTerminal.payFee({
            feeTerminal: directRegistry, token: address(token), amount: _AMOUNT, sourceProjectId: _SOURCE_PROJECT_ID
        });

        assertTrue(sourceTerminal.feeWasForgiven(), "source terminal should take its fail-open catch");
        assertEq(token.balanceOf(address(sourceTerminal)), _AMOUNT, "reverted fee stays at its source");
        assertEq(token.balanceOf(address(directRegistry)), 0, "registry must remain stateless");
        assertEq(token.balanceOf(address(router)), 0, "router pull must roll back");
    }

    /// @notice The replacement registry target must absorb the same router failure after taking custody, preventing
    /// the source terminal's fail-open catch from forgiving the fee.
    function test_routerGatewayRetainsFailedFeeWithoutChangingRegistry() public {
        _queueFee(address(token));

        JBPendingRouterTerminalCall memory call = gateway.pendingCallOf(_ID);
        assertFalse(sourceTerminal.feeWasForgiven(), "gateway must not cross the source terminal's catch boundary");
        assertEq(gateway.pendingCallCount(), 1, "failed fee should be retained as pending");
        assertEq(call.amount, _AMOUNT);
        assertEq(call.refundTo, address(sourceTerminal), "registry should propagate the source terminal");
        assertTrue(call.refundToProject, "terminal-shaped fee payer should qualify for project accounting refund");
        assertEq(call.sourceProjectId, _SOURCE_PROJECT_ID);
        assertEq(token.balanceOf(address(gateway)), _AMOUNT, "gateway should retain the original input token");
        assertEq(token.balanceOf(address(registry)), 0, "unchanged registry must remain stateless");
        assertEq(token.balanceOf(address(router)), 0, "failed router pull must roll back");
    }
}

contract RouterTerminalGatewayBaseForkTest is Test {
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
        RouterTerminalMigrationLib.migrateProjects({
            registry: registry, terminal: gateway, projectCount: registry.PROJECTS().count(), projectIds: projectIds
        });
        RouterTerminalMigrationLib.requireMigratedProject({registry: registry, terminal: gateway, projectId: 1});
        vm.stopPrank();

        assertEq(address(registry.terminalOf(1)), address(gateway), "deployment migration must repoint fee project");
    }

    function _replayReportedPayout(uint256 gasLimit) internal returns (bool success) {
        vm.prank(_FEE_BENEFICIARY);
        (success,) = _MULTI_TERMINAL.call{gas: gasLimit}(
            abi.encodeWithSelector(
                bytes4(0xcfaf5839), uint256(9), _USDC, uint256(1_000_000), uint256(2), uint256(990_119)
            )
        );
    }

    /// @notice Replays the exact reported Base payout with only project 1's registry pointer changed to the gateway.
    function testFork_reportedBaseFeeIsRetainedByGatewayWithoutRegistryCodeChanges() public {
        string memory rpc = vm.envOr("RPC_BASE_MAINNET", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, _BASE_BLOCK_BEFORE_TX);

        JBRouterTerminalGateway gateway = _installGateway();
        assertGe(gateway.maximumQualifiedCallGas(), 20_000_000, "Base must support the complete default gas ladder");
        uint256 gatewayBalanceBefore = IERC20(_USDC).balanceOf(address(gateway));
        uint256 payoutBalanceBefore = IERC20(_USDC).balanceOf(_PAYOUT_BENEFICIARY);

        vm.recordLogs();
        bool success = _replayReportedPayout(_ORIGINAL_CALL_GAS);
        assertTrue(success, "reported payout transaction reverted");

        bool sawFeeReverted;
        bool sawProcessFee;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == _FEE_REVERTED_TOPIC) sawFeeReverted = true;
            if (logs[i].topics[0] == _PROCESS_FEE_TOPIC) sawProcessFee = true;
        }
        assertFalse(sawFeeReverted, "fee was forgiven");
        assertTrue(sawProcessFee, "source terminal did not recognize gateway custody");

        JBPendingRouterTerminalCall memory pending = gateway.pendingCallOf(bytes32(uint256(1)));
        assertEq(pending.amount, 25_003, "fee was not retained");
        assertEq(pending.token, _USDC, "gateway did not retain the original input token");
        assertEq(pending.refundTo, _MULTI_TERMINAL, "source terminal was not propagated");
        assertTrue(pending.refundToProject, "fee refund should return through source project accounting");
        assertEq(pending.sourceProjectId, 9, "source project metadata was not retained");
        assertEq(IERC20(_USDC).balanceOf(address(gateway)) - gatewayBalanceBefore, 25_003, "custody mismatch");
        assertEq(IERC20(_USDC).balanceOf(_PAYOUT_BENEFICIARY) - payoutBalanceBefore, 975_118, "payout changed");

        uint256 beneficiaryTokenCount =
            gateway.processPendingCall({id: bytes32(uint256(1)), memo: "", metadata: abi.encodePacked(uint256(9))});
        assertGt(beneficiaryTokenCount, 0, "retry did not mint fee-project tokens");
        assertEq(gateway.pendingCallOf(bytes32(uint256(1))).refundTo, address(0), "retry remained pending");
        assertEq(IERC20(_USDC).balanceOf(address(gateway)), gatewayBalanceBefore, "retry did not consume fee");
    }

    /// @notice Sweeps the reported gas boundary. Any payout which completes must not forgive its fee.
    function testFork_reportedBaseFeeHasNoSuccessfulFeeRevertGasBand() public {
        string memory rpc = vm.envOr("RPC_BASE_MAINNET", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, _BASE_BLOCK_BEFORE_TX);

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
}
