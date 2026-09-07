// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";

import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {JBRouterTerminalGateway} from "../../../src/JBRouterTerminalGateway.sol";

import {IJBRouterTerminal} from "../../../src/interfaces/IJBRouterTerminal.sol";

import {JBPendingRouterTerminalCallFailure} from "../../../src/structs/JBPendingRouterTerminalCallFailure.sol";

/// @notice Exposes gateway gas calculations for checking executable retry budgets independently of routing.
contract GatewayGasHarness is JBRouterTerminalGateway {
    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice Initializes unused dependencies for a harness that only exercises pure gas calculations.
    constructor()
        JBRouterTerminalGateway(
            IJBDirectory(address(1)), IPermit2(address(2)), IJBRouterTerminal(address(3)), address(0)
        )
    {}

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Returns the gateway's fingerprint for exhausted or otherwise ambiguous empty failures.
    /// @return errorHash The gas-exhaustion failure class.
    function gasExhaustedErrorHash() external pure returns (bytes32 errorHash) {
        return _GAS_EXHAUSTED_ERROR_HASH;
    }

    /// @notice Returns the executable call-gas ceiling for a supplied block gas limit.
    /// @param blockGasLimit The chain's block gas limit.
    /// @return gasLimit The highest router-call budget that leaves transaction and gateway overhead available.
    function maximumQualifiedCallGasFor(uint256 blockGasLimit) external pure returns (uint256 gasLimit) {
        return _maximumQualifiedCallGas(blockGasLimit);
    }

    /// @notice Resolves the retry budget allowed by the supplied failure history and executable ceiling.
    /// @param failure The recorded failure class, count, and highest previously attempted gas limit.
    /// @param requestedGasLimit The explicit call budget, or zero to select the automatic rung.
    /// @param maximumGasLimit The executable router-call ceiling.
    /// @return gasLimit The qualified call budget to forward.
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
