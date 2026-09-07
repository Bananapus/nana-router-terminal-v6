// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {RouterTerminalDeployment, RouterTerminalDeploymentLib} from "../script/helpers/RouterTerminalDeploymentLib.sol";

import {RouterTerminalDeploymentLibHarness} from "./helpers/deployment/RouterTerminalDeploymentLibHarness.sol";

/// @notice Tests deployment artifact resolution and supported network directory names.
contract RouterTerminalDeploymentLibTest is Test {
    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Exposes the deployment library's internal functions to the tests.
    RouterTerminalDeploymentLibHarness internal _harness;

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Each supported chain resolves to the directory containing its deployment artifacts.
    function test_networkNamesMatchDeploymentArtifactDirectories() public view {
        assertEq(_harness.networkNameOf(1), "ethereum");
        assertEq(_harness.networkNameOf(10), "optimism");
        assertEq(_harness.networkNameOf(8453), "base");
        assertEq(_harness.networkNameOf(42_161), "arbitrum");
        assertEq(_harness.networkNameOf(84_532), "base_sepolia");
        assertEq(_harness.networkNameOf(421_614), "arbitrum_sepolia");
        assertEq(_harness.networkNameOf(11_155_111), "sepolia");
        assertEq(_harness.networkNameOf(11_155_420), "optimism_sepolia");
    }

    /// @notice An artifact set without a gateway resolves its available contracts and a zero gateway address.
    function test_preGatewayDeploymentArtifactsRemainReadable() public view {
        // The Base fixture omits the optional gateway artifact while providing the required registry and router.
        RouterTerminalDeployment memory deployment = _harness.getDeployment({path: "deployments/", networkName: "base"});

        assertEq(address(deployment.gateway), address(0), "missing gateway artifact should decode as zero");
        assertEq(address(deployment.registry), 0xe0427F250fdb0379c8E98e884Ee4570521208CbC);
        assertEq(address(deployment.terminal), 0x0FBcbb3d10C8F524840d74EF81c1A9f161c418d7);
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Deploy the harness used to exercise the library through external calls.
    function setUp() public {
        _harness = new RouterTerminalDeploymentLibHarness();
    }

    /// @notice Unsupported chains revert with the unresolved chain ID.
    function test_unsupportedChainReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                RouterTerminalDeploymentLib.RouterTerminalDeploymentLib_UnsupportedChain.selector, 123
            )
        );
        _harness.networkNameOf(123);
    }
}
