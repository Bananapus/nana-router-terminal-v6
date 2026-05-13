// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

/// @custom:member maxProjectId The highest project ID covered by this entry's `terminal`. Resolution walks the
/// history forward and returns the first entry whose `maxProjectId >= projectId`.
/// @custom:member terminal The default terminal that was current at the time this history entry was captured (i.e.
/// immediately before the subsequent `setDefaultTerminal` call).
struct DefaultTerminalSegment {
    uint256 maxProjectId;
    IJBTerminal terminal;
}
