// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev Fields are ordered and sized to pack into five storage slots. Amounts use core's `uint224` fee-accounting
/// width and project IDs use core's `uint64` split/permission width. A retained call always has a nonzero
/// `sourceProjectId` and a zero `minReturnedTokens`, so neither an opt-in flag nor a minimum is stored.
/// @custom:member amount The original input-token amount retained by the gateway.
/// @custom:member preferAddToBalance Whether the call settles through `addToBalanceOf` instead of `pay`.
/// @custom:member shouldReturnHeldFees The held-fee preference of a routed `addToBalanceOf` call.
/// @custom:member beneficiary The beneficiary of a routed `pay` call.
/// @custom:member projectId The destination project ID.
/// @custom:member callDataHash The hash binding the original memo and metadata.
/// @custom:member refundTo The original payer, preferred as a refund terminal when registered for the source project.
/// @custom:member sourceProjectId The project named by metadata as the eventual refund creditor.
/// @custom:member token The original input token retained by the gateway.
struct JBPendingRouterTerminalCall {
    uint224 amount;
    bool preferAddToBalance;
    bool shouldReturnHeldFees;
    address beneficiary;
    uint64 projectId;
    bytes32 callDataHash;
    address refundTo;
    uint64 sourceProjectId;
    address token;
}
