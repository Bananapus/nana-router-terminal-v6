// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";

/// @custom:member fallbackToken The first reclaimable JB project token discovered for recursive cashout routing.
/// @custom:member fallbackTerminal The cashout terminal that can reclaim `fallbackToken`.
/// @custom:member baseFallbackToken The first reclaimable base token discovered for swap-based fallback routing.
/// @custom:member baseFallbackTerminal The cashout terminal that can reclaim `baseFallbackToken`.
/// @custom:member directFallbackToken The first reclaimable token the destination project directly accepts.
/// @custom:member directFallbackTerminal The cashout terminal that can reclaim `directFallbackToken`.
struct CashOutPathCandidates {
    address fallbackToken;
    IJBCashOutTerminal fallbackTerminal;
    address baseFallbackToken;
    IJBCashOutTerminal baseFallbackTerminal;
    address directFallbackToken;
    IJBCashOutTerminal directFallbackTerminal;
}
