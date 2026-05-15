// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";

/// @notice The cross-project cash-out extension surfaced by `JBMultiTerminal` once nana-core-v6 PR #143 lands.
/// @dev Local re-declaration so the router can call the new function before nana-core-v6 publishes a release that
/// folds the function into the canonical `IJBCashOutTerminal`. When the bumped core release is consumed, this
/// interface can be deleted and call sites can cast to `IJBCashOutTerminal` directly.
interface IJBCashOutTerminalCrossProject is IJBCashOutTerminal {
    /// @notice Atomically cash out `holder`'s tokens of `projectId` and pay the reclaim into `beneficiaryProjectId`.
    /// @dev Equivalent to `cashOutTokensOf` followed by `pay` on the destination project, except the source-side
    /// cash-out fee is skipped. The equivalent fee is bound on the destination project's side instead via a credit to
    /// `_feeFreeSurplusOf[beneficiaryProjectId]` measured from the destination project's balance growth on this
    /// terminal. The destination project's current ruleset can set `pauseCrossProjectFeeFreeInflows` to opt out, in
    /// which case the call reverts.
    /// @param holder The account whose project tokens are being burned.
    /// @param projectId The ID of the source project being cashed out from.
    /// @param cashOutCount The number of source-project tokens to burn, with 18 decimals.
    /// @param tokenToReclaim The terminal token reclaimed from the source project's surplus.
    /// @param beneficiaryProjectId The destination project receiving the reclaim.
    /// @param beneficiary The address that receives the newly minted destination-project tokens.
    /// @param minTokensOut The minimum number of destination-project tokens that must be minted, otherwise revert.
    /// @param cashOutMetadata Bytes forwarded to the source project's data hook and any cash-out hook specifications.
    /// @param payMetadata Bytes forwarded to the destination project's pay flow.
    /// @return reclaimAmount The gross reclaim amount returned by the store.
    /// @return beneficiaryTokenCount The number of destination-project tokens minted to `beneficiary`.
    function payAfterCashOutTokensOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 beneficiaryProjectId,
        address beneficiary,
        uint256 minTokensOut,
        bytes calldata cashOutMetadata,
        bytes calldata payMetadata
    )
        external
        returns (uint256 reclaimAmount, uint256 beneficiaryTokenCount);
}
