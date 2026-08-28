// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev Retained calls are never written to storage — only a hash commitment over this struct and the original memo
/// and metadata is. This shape is therefore an ABI surface, where every field is word-padded regardless of its
/// declared width, so the members keep the same widths as the terminal arguments they mirror. A retained call always
/// has a nonzero `sourceProjectId` and a zero `minReturnedTokens`, so neither an opt-in flag nor a minimum is carried.
/// @custom:member amount The original input-token amount retained by the gateway.
/// @custom:member preferAddToBalance Whether the call settles through `addToBalanceOf` instead of `pay`.
/// @custom:member shouldReturnHeldFees The held-fee preference of a routed `addToBalanceOf` call.
/// @custom:member beneficiary The beneficiary of a routed `pay` call.
/// @custom:member projectId The destination project ID.
/// @custom:member refundTo The original payer, preferred as a refund terminal when registered for the source project.
/// @custom:member sourceProjectId The project named by metadata as the eventual refund creditor.
/// @custom:member token The original input token retained by the gateway.
struct JBPendingRouterTerminalCall {
    uint256 amount;
    bool preferAddToBalance;
    bool shouldReturnHeldFees;
    address beneficiary;
    uint256 projectId;
    address refundTo;
    uint256 sourceProjectId;
    address token;
}
