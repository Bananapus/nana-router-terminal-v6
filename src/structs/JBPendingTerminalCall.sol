// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A terminal-originated project payment retained by a forwarding registry after its downstream call failed.
/// @custom:member sourceProjectId The project whose terminal originated the forwarded payment.
/// @custom:member projectId The project the payment is intended for.
/// @custom:member token The token retained by the registry.
/// @custom:member amount The amount retained by the registry.
/// @custom:member beneficiary The beneficiary for a retried pay call.
/// @custom:member payer The original payer exposed to downstream forwarding terminals during a retry.
/// @custom:member sourceTerminal The authenticated terminal whose project balance funded the payment.
/// @custom:member preferAddToBalance Whether the retry should add to the project's balance instead of paying it.
struct JBPendingTerminalCall {
    uint256 sourceProjectId;
    uint256 projectId;
    address token;
    uint256 amount;
    address beneficiary;
    address payer;
    address sourceTerminal;
    bool preferAddToBalance;
}
