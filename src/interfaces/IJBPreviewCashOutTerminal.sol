// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

/// @notice A local compatibility interface for terminals that support cash-out previews.
interface IJBPreviewCashOutTerminal {
    /// @notice Simulates cashing out project tokens from this terminal without modifying state.
    function previewCashOutFrom(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        address payable beneficiary,
        bytes calldata metadata
    )
        external
        view
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        );
}
