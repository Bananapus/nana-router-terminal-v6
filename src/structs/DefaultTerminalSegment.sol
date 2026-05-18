// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

/// @notice A segment of the default-terminal history. Each segment pins a previous default to the half-open range of
/// project IDs that were created while it was active. Resolution returns the segment whose
/// `(minProjectIdExclusive, maxProjectId]` window contains the project's ID.
/// @custom:member minProjectIdExclusive The threshold that was active when this segment's terminal first became the
/// default. Project IDs strictly greater than this fall within this segment.
/// @custom:member maxProjectId The threshold that was set when this segment's terminal was overwritten. Project IDs
/// less than or equal to this fall within this segment.
/// @custom:member terminal The default terminal that was active for project IDs in
/// `(minProjectIdExclusive, maxProjectId]`.
struct DefaultTerminalSegment {
    uint256 minProjectIdExclusive;
    uint256 maxProjectId;
    IJBTerminal terminal;
}
