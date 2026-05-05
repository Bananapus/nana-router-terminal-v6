// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";

/// @custom:member fallbackToken The first reclaimable JB project token found for recursive cashout routing.
/// @custom:member fallbackTerminal The cashout terminal to reclaim `fallbackToken` from.
/// @custom:member baseFallbackToken The first reclaimable base token found for swap-based fallback routing.
/// @custom:member baseFallbackTerminal The cashout terminal to reclaim `baseFallbackToken` from.
/// @custom:member directFallbackToken The first reclaimable token the destination project directly accepts.
/// @custom:member directFallbackTerminal The cashout terminal to reclaim `directFallbackToken` from.
struct CashOutPathCandidates {
    address fallbackToken;
    IJBCashOutTerminal fallbackTerminal;
    address baseFallbackToken;
    IJBCashOutTerminal baseFallbackTerminal;
    address directFallbackToken;
    IJBCashOutTerminal directFallbackTerminal;
}
