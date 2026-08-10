// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member amount The original input-token amount retained by the gateway.
/// @custom:member beneficiary The beneficiary of a routed `pay` call.
/// @custom:member callDataHash The hash binding the original memo and metadata.
/// @custom:member minReturnedTokens The minimum project-token count required by a routed `pay` call.
/// @custom:member preferAddToBalance Whether the call settles through `addToBalanceOf` instead of `pay`.
/// @custom:member projectId The destination project ID.
/// @custom:member refundTo The original payer, or source terminal for a project-originated call.
/// @custom:member refundToProject Whether a terminal refund should credit `sourceProjectId`.
/// @custom:member shouldReturnHeldFees The held-fee preference of a routed `addToBalanceOf` call.
/// @custom:member sourceProjectId The project whose terminal originated the retained call.
/// @custom:member token The original input token retained by the gateway.
struct JBPendingRouterTerminalCall {
    uint256 amount;
    address beneficiary;
    bytes32 callDataHash;
    uint256 minReturnedTokens;
    bool preferAddToBalance;
    uint256 projectId;
    address refundTo;
    bool refundToProject;
    bool shouldReturnHeldFees;
    uint256 sourceProjectId;
    address token;
}
