// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev The bools follow `beneficiary` so the struct packs into eight storage slots.
/// @custom:member amount The original input-token amount retained by the gateway.
/// @custom:member beneficiary The beneficiary of a routed `pay` call.
/// @custom:member preferAddToBalance Whether the call settles through `addToBalanceOf` instead of `pay`.
/// @custom:member refundToProject Whether an eventual refund should credit `sourceProjectId`.
/// @custom:member shouldReturnHeldFees The held-fee preference of a routed `addToBalanceOf` call.
/// @custom:member callDataHash The hash binding the original memo and metadata.
/// @custom:member minReturnedTokens The minimum project-token count required by a routed `pay` call.
/// @custom:member projectId The destination project ID.
/// @custom:member refundTo The original payer, preferred as a refund terminal when registered for the source project.
/// @custom:member sourceProjectId The project named by metadata as the eventual refund creditor.
/// @custom:member token The original input token retained by the gateway.
struct JBPendingRouterTerminalCall {
    uint256 amount;
    address beneficiary;
    bool preferAddToBalance;
    bool refundToProject;
    bool shouldReturnHeldFees;
    bytes32 callDataHash;
    uint256 minReturnedTokens;
    uint256 projectId;
    address refundTo;
    uint256 sourceProjectId;
    address token;
}
