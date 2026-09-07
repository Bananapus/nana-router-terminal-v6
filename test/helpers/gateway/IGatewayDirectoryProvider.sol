// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";

/// @notice Exposes the directory used by a deployed router when installing a gateway on a fork.
interface IGatewayDirectoryProvider {
    /// @notice Returns the router's project directory.
    /// @return directory The directory used to discover project refund terminals.
    function DIRECTORY() external view returns (IJBDirectory directory);
}
