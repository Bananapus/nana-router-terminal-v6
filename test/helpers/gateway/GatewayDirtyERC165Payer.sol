// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Returns an invalid ABI boolean to test payer introspection without changing retention eligibility.
contract GatewayDirtyERC165Payer {
    /// @notice Responds to every interface probe with a word outside the ABI boolean range.
    /// @dev The interface selector is ignored because every probe must receive the same malformed shape.
    /// @return supported The malformed ABI word returned directly by the assembly block.
    function supportsInterface(bytes4) external pure returns (bool supported) {
        // Returning raw bytes bypasses Solidity's boolean encoding so callers must handle malformed data.
        assembly ("memory-safe") {
            supported := 2
            mstore(0, supported)
            return(0, 32)
        }
    }
}
