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
}

contract RouterTerminalDeploymentLibTest is Test {
    RouterTerminalDeploymentLibHarness internal harness;

    function setUp() public {
        harness = new RouterTerminalDeploymentLibHarness();
    }

    function test_preGatewayDeploymentArtifactsRemainReadable() public view {
        RouterTerminalDeployment memory deployment = harness.getDeployment({path: "deployments/", networkName: "base"});

        assertEq(address(deployment.gateway), address(0), "missing gateway artifact should decode as zero");
        assertEq(address(deployment.registry), 0xe0427F250fdb0379c8E98e884Ee4570521208CbC);
        assertEq(address(deployment.terminal), 0x0FBcbb3d10C8F524840d74EF81c1A9f161c418d7);
    }
}
