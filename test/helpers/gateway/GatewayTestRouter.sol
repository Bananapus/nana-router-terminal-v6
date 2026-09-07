// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GatewayTestTokens} from "./GatewayTestTokens.sol";

import {IGatewayGasBurner} from "./IGatewayGasBurner.sol";
import {IGatewayRouterCallback} from "./IGatewayRouterCallback.sol";

/// @notice Accepts gateway payments and exposes configurable return, revert, and gas-exhaustion behavior.
contract GatewayTestRouter {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown in failure mode one to produce a stable failure selector.
    error GatewayTestRouter_FailureA();

    /// @notice Thrown in failure mode two to produce a distinct failure selector.
    error GatewayTestRouter_FailureB();

    /// @notice Thrown in failure mode five to distinguish selector matching from argument matching.
    /// @param argument The configured argument included in the failure payload.
    error GatewayTestRouter_FailureWithArgument(uint256 argument);

    /// @notice Thrown when the native value differs from the reported payment amount.
    /// @param value The native value received.
    /// @param amount The reported payment amount.
    error GatewayTestRouter_NativeAmountMismatch(uint256 value, uint256 amount);

    /// @notice Thrown when the payment token declines the router's transfer.
    /// @param token The payment token.
    /// @param amount The requested payment amount.
    error GatewayTestRouter_TransferFailed(address token, uint256 amount);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The project-token lookup exposed to the gateway.
    GatewayTestTokens public immutable TOKENS = new GatewayTestTokens();

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The optional callback invoked before accepting each payment.
    address public beforePullCallback;

    /// @notice The revert argument used by failure mode five.
    uint256 public failureArgument;

    /// @notice The selected success or failure behavior, with one selecting the default failure.
    uint256 public mode = 1;

    /// @notice The cumulative amount accepted by calls that do not revert.
    uint256 public received;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Whether the router is executing its before-pull callback.
    /// @dev Prevents the callback from recursively invoking itself during nested gateway calls.
    bool internal _callingBeforePull;

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Accept native funds used by the payment fixtures.
    receive() external payable {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Accept an add-to-balance call and apply the configured completion behavior.
    /// @dev The first, fourth, fifth, and sixth arguments are the unused project ID, held-fee preference, memo,
    /// and metadata. Their ABI positions match the terminal interface.
    /// @param token The payment token.
    /// @param amount The amount to accept.
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
        // Accept first so reverting completion must roll back token custody as well as router accounting.
        _accept({token: token, amount: amount});
        _finish();
    }

    /// @notice Accept a payment and apply the configured completion behavior.
    /// @dev The first, fourth, fifth, sixth, and seventh arguments are the unused project ID, beneficiary,
    /// minimum return, memo, and metadata. Their ABI positions match the terminal interface.
    /// @param token The payment token.
    /// @param amount The amount to accept and return on success.
    /// @return beneficiaryTokenCount The amount accepted when completion returns normally.
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
        returns (uint256 beneficiaryTokenCount)
    {
        // Accept first so reverting completion must roll back token custody as well as router accounting.
        _accept({token: token, amount: amount});
        _finish();
        return amount;
    }

    /// @notice Select the callback invoked before the router pulls payment funds.
    /// @param newCallback The callback address, or zero to disable callbacks.
    function setBeforePullCallback(address newCallback) external {
        beforePullCallback = newCallback;
    }

    /// @notice Select the argument included in failure mode five's revert data.
    /// @param newArgument The argument to include.
    function setFailureArgument(uint256 newArgument) external {
        failureArgument = newArgument;
    }

    /// @notice Select the completion behavior applied to each payment.
    /// @param newMode The behavior selector, with zero selecting successful completion.
    function setMode(uint256 newMode) external {
        mode = newMode;
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Consume all gas forwarded to this call.
    /// @dev The unbounded loop makes the caller observe a downstream frame exhausting its gas budget.
    function burn() external pure {
        while (true) {}
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Pull the payment funds and record the amount accepted.
    /// @param token The payment token.
    /// @param amount The amount to accept.
    function _accept(address token, uint256 amount) internal {
        // Keep nested payments possible while limiting the configured callback to one active frame.
        if (beforePullCallback != address(0) && !_callingBeforePull) {
            _callingBeforePull = true;
            IGatewayRouterCallback(beforePullCallback).beforeGatewayRouterPull();
            _callingBeforePull = false;
        }

        // Require actual custody before recording a payment as received.
        if (token == JBConstants.NATIVE_TOKEN) {
            if (msg.value != amount) revert GatewayTestRouter_NativeAmountMismatch(msg.value, amount);
        } else {
            if (!IERC20(token).transferFrom({from: msg.sender, to: address(this), value: amount})) {
                revert GatewayTestRouter_TransferFailed(token, amount);
            }
        }
        received += amount;
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Complete the current call with the configured failure or return shape.
    /// @dev Gas-consuming modes distinguish insufficient forwarding budgets from ordinary application failures.
    function _finish() internal view {
        // Distinct selectors and an adjustable argument exercise failure qualification independently.
        if (mode == 1) revert GatewayTestRouter_FailureA();
        if (mode == 2) revert GatewayTestRouter_FailureB();
        if (mode == 3) {
            // An invalid opcode consumes the router frame's remaining gas.
            assembly ("memory-safe") {
                invalid()
            }
        }
        if (mode == 4) {
            // Empty successful return data exercises the gateway's return-value validation.
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (mode == 5) revert GatewayTestRouter_FailureWithArgument(failureArgument);
        if (mode == 6) {
            // An empty revert supplies no selector for failure classification.
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }
        if (mode == 7 && gasleft() < 6_000_000) {
            // Require a larger budget before allowing this otherwise successful route to complete.
            assembly ("memory-safe") {
                invalid()
            }
        }
        // A nested frame exhausts gas below the threshold to model a route needing a larger budget.
        if (mode == 8 && gasleft() < 8_000_000) IGatewayGasBurner(address(this)).burn();
    }
}
