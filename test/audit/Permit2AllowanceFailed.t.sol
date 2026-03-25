// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Foundry test harness.
import {Test} from "forge-std/Test.sol";

// Core interfaces used by the registry constructor.
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";

// Terminal interface that the registry forwards payments to.
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

// The permit terminal interface that defines the event we are testing.
import {IJBPermitTerminal} from "@bananapus/core-v6/src/interfaces/IJBPermitTerminal.sol";

// Metadata resolver used to build permit2 metadata.
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";

// Struct that the permit2 metadata encodes.
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";

// ERC-20 interface used to mock token interactions.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Permit2 interface used by the registry.
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

// Contract under test.
import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";

/// @notice Regression test: when the PERMIT2.permit() call reverts during
///         `_acceptFundsFor`, the registry must emit `Permit2AllowanceFailed`
///         and continue the payment via fallback transfer.
contract Permit2AllowanceFailedTest is Test {
    // --- State ----------------------------------------------------------

    // Registry instance under test.
    JBRouterTerminalRegistry registry;

    // Mocked core dependencies.
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));

    // A mock ERC-20 token used as the payment token.
    address token = makeAddr("mockToken");

    // A mock destination terminal that the registry forwards to.
    IJBTerminal destTerminal = IJBTerminal(makeAddr("destTerminal"));

    // A mock Permit2 contract whose `permit` will revert.
    IPermit2 permit2 = IPermit2(makeAddr("permit2"));

    // Test addresses.
    address registryOwner = makeAddr("registryOwner");
    address payer = makeAddr("payer");
    address beneficiary = makeAddr("beneficiary");

    // Test project ID.
    uint256 projectId = 42;

    // Payment amount.
    uint256 payAmount = 100e18;

    // --- Setup ----------------------------------------------------------

    function setUp() public {
        // Etch minimal code so mocked addresses behave as contracts.
        vm.etch(address(permissions), hex"00");
        vm.etch(address(projects), hex"00");
        vm.etch(address(token), hex"00");
        vm.etch(address(destTerminal), hex"00");
        vm.etch(address(permit2), hex"00");

        // Deploy the registry with the mocked permit2.
        registry = new JBRouterTerminalRegistry(permissions, projects, permit2, registryOwner, address(0));

        // Set destTerminal as the default terminal.
        vm.prank(registryOwner);
        registry.setDefaultTerminal(destTerminal);
    }

    // --- Permit2AllowanceFailed event test --------------------------------

    /// @notice When `PERMIT2.permit()` reverts, the registry must emit
    ///         `Permit2AllowanceFailed(token, payer, reason)` and still
    ///         complete the payment via fallback ERC-20 transfer.
    function test_permit2AllowanceFailed_emitsEventOnRevert() public {
        // Build a JBSingleAllowance struct that will be encoded into metadata.
        JBSingleAllowance memory allowance = JBSingleAllowance({
            // forge-lint: disable-next-line(unsafe-typecast)
            amount: uint160(payAmount), // Allowance amount matches payment.
            expiration: uint48(block.timestamp + 1 hours), // Valid expiration.
            nonce: 0, // First nonce.
            sigDeadline: uint48(block.timestamp + 1 hours), // Signature deadline.
            signature: hex"deadbeef" // Dummy signature.
        });

        // Encode the allowance into JBMetadataResolver format keyed by "permit2".
        // The registry uses `getId("permit2")` which resolves to `getId("permit2", address(this))`.
        // Since the registry calls this internally, the id is xor(registry address, keccak256("permit2")).
        bytes4 permit2MetadataId = JBMetadataResolver.getId("permit2", address(registry));

        // Build the metadata with the permit2 allowance.
        bytes memory metadata = JBMetadataResolver.addToMetadata("", permit2MetadataId, abi.encode(allowance));

        // Mock ALL calls to the PERMIT2 address to revert. This covers the
        // `permit(address,PermitSingle,bytes)` overload that the registry calls.
        bytes memory revertReason = "INVALID_SIGNATURE";
        // Use explicit bytes type to disambiguate the mockCallRevert overload.
        vm.mockCallRevert(address(permit2), bytes(""), revertReason);

        // Mock the ERC-20 token allowance so that `_transferFrom` uses safeTransferFrom
        // (not the permit2 transferFrom fallback).
        vm.mockCall(
            address(token),
            abi.encodeWithSelector(IERC20.allowance.selector, payer, address(registry)),
            abi.encode(payAmount)
        );

        // Mock the ERC-20 safeTransferFrom to succeed (returns true).
        vm.mockCall(
            address(token),
            abi.encodeWithSelector(IERC20.transferFrom.selector, payer, address(registry), payAmount),
            abi.encode(true)
        );

        // Mock the ERC-20 allowance for the registry -> destTerminal approval.
        vm.mockCall(
            address(token),
            abi.encodeWithSelector(IERC20.allowance.selector, address(registry), address(destTerminal)),
            abi.encode(uint256(0))
        );

        // Mock the safeIncreaseAllowance (approve) call for forwarding to the terminal.
        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        // Mock the destination terminal's pay call to succeed.
        vm.mockCall(address(destTerminal), abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(1e18)));

        // Expect the Permit2AllowanceFailed event to be emitted.
        // The event is: Permit2AllowanceFailed(address indexed token, address indexed owner, bytes reason)
        vm.expectEmit(true, true, false, false, address(registry));
        emit IJBPermitTerminal.Permit2AllowanceFailed(token, payer, revertReason);

        // Call pay as the payer. The permit2 will fail, event emits, and fallback transfer completes.
        vm.prank(payer);
        registry.pay({
            projectId: projectId,
            token: token,
            amount: payAmount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });
    }
}
