// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {RouterTerminalDeployment, RouterTerminalDeploymentLib} from "../script/helpers/RouterTerminalDeploymentLib.sol";

contract RouterTerminalDeploymentLibHarness {
    function getDeployment(
        string memory path,
        string memory networkName
    )
        external
        view
        returns (RouterTerminalDeployment memory deployment)
    {
        return RouterTerminalDeploymentLib.getDeployment({path: path, networkName: networkName});
    }

    function networkNameOf(uint256 chainId) external pure returns (string memory networkName) {
        return RouterTerminalDeploymentLib._networkNameOf(chainId);
    }
}

contract RouterTerminalDeploymentLibTest is Test {
    RouterTerminalDeploymentLibHarness internal harness;

    function setUp() public {
        harness = new RouterTerminalDeploymentLibHarness();
    }

    function test_networkNamesMatchDeploymentArtifactDirectories() public view {
        assertEq(harness.networkNameOf(1), "ethereum");
        assertEq(harness.networkNameOf(10), "optimism");
        assertEq(harness.networkNameOf(8453), "base");
        assertEq(harness.networkNameOf(42_161), "arbitrum");
        assertEq(harness.networkNameOf(84_532), "base_sepolia");
        assertEq(harness.networkNameOf(421_614), "arbitrum_sepolia");
        assertEq(harness.networkNameOf(11_155_111), "sepolia");
        assertEq(harness.networkNameOf(11_155_420), "optimism_sepolia");
    }

    function test_preGatewayDeploymentArtifactsRemainReadable() public view {
        RouterTerminalDeployment memory deployment = harness.getDeployment({path: "deployments/", networkName: "base"});

        assertEq(address(deployment.gateway), address(0), "missing gateway artifact should decode as zero");
        assertEq(address(deployment.registry), 0xe0427F250fdb0379c8E98e884Ee4570521208CbC);
        assertEq(address(deployment.terminal), 0x0FBcbb3d10C8F524840d74EF81c1A9f161c418d7);
    }

    function test_unsupportedChainReverts() public {
        vm.expectRevert(bytes("ChainID is not supported by RouterTerminalDeploymentLib."));
        harness.networkNameOf(123);
    }
}
