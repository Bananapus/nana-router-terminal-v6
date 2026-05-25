// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {IJBForwardingTerminal} from "../../src/interfaces/IJBForwardingTerminal.sol";
import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";
import {JBForwardingCheck} from "../../src/libraries/JBForwardingCheck.sol";

import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

contract RegistryMultiHopForwarder is IJBTerminal, IJBForwardingTerminal {
    IJBTerminal internal immutable _next;

    constructor(IJBTerminal next_) {
        _next = next_;
    }

    function terminalOf(uint256) external view override returns (IJBTerminal) {
        return _next;
    }

    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        returns (JBAccountingContext memory)
    {
        return _next.accountingContextForTokenOf({projectId: projectId, token: token});
    }

    function accountingContextsOf(uint256 projectId) external view returns (JBAccountingContext[] memory) {
        return _next.accountingContextsOf(projectId);
    }

    function currentSurplusOf(
        uint256 projectId,
        address[] calldata tokens,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256)
    {
        return _next.currentSurplusOf({projectId: projectId, tokens: tokens, decimals: decimals, currency: currency});
    }

    function previewPayFor(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        bytes calldata metadata
    )
        external
        view
        returns (JBRuleset memory, uint256, uint256, JBPayHookSpecification[] memory)
    {
        return _next.previewPayFor({
            projectId: projectId, token: token, amount: amount, beneficiary: beneficiary, metadata: metadata
        });
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external {}

    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool shouldReturnHeldFees,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
    {
        _next.addToBalanceOf{value: msg.value}({
            projectId: projectId,
            token: token,
            amount: amount,
            shouldReturnHeldFees: shouldReturnHeldFees,
            memo: memo,
            metadata: metadata
        });
    }

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure returns (uint256) {
        return 0;
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        returns (uint256)
    {
        return _next.pay{value: msg.value}({
            projectId: projectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: minReturnedTokens,
            memo: memo,
            metadata: metadata
        });
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract RegistryForwardingCheckHarness {
    function isCircular(address target, uint256 projectId, IJBTerminal terminal) external view returns (bool) {
        return JBForwardingCheck.isCircularTerminal({target: target, projectId: projectId, terminal: terminal});
    }
}

contract RegistryMultiHopForwardingCycleTest is Test {
    uint256 internal constant PROJECT_ID = 1;

    IJBPermissions internal permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects internal projects = IJBProjects(makeAddr("projects"));
    IPermit2 internal permit2 = IPermit2(makeAddr("permit2"));

    address internal owner = makeAddr("owner");
    address internal projectOwner = makeAddr("projectOwner");

    JBRouterTerminalRegistry internal registry;
    RegistryForwardingCheckHarness internal forwardingCheck;

    function setUp() public {
        registry = new JBRouterTerminalRegistry({
            permissions: permissions, projects: projects, permit2: permit2, owner: owner, trustedForwarder: address(0)
        });
        forwardingCheck = new RegistryForwardingCheckHarness();

        vm.mockCall(address(projects), abi.encodeCall(IJBProjects.count, ()), abi.encode(uint256(0)));
        vm.mockCall(address(projects), abi.encodeCall(IERC721.ownerOf, (PROJECT_ID)), abi.encode(projectOwner));
        vm.mockCall(
            address(permissions),
            abi.encodeWithSignature(
                "hasPermission(address,address,uint256,uint256,bool,bool)",
                projectOwner,
                projectOwner,
                PROJECT_ID,
                JBPermissionIds.SET_ROUTER_TERMINAL,
                true,
                true
            ),
            abi.encode(true)
        );
    }

    function test_registryRejectsMultiHopForwardingCycle() public {
        RegistryMultiHopForwarder secondHop = new RegistryMultiHopForwarder(IJBTerminal(address(registry)));
        RegistryMultiHopForwarder firstHop = new RegistryMultiHopForwarder(IJBTerminal(address(secondHop)));

        assertTrue(
            forwardingCheck.isCircular({target: address(registry), projectId: PROJECT_ID, terminal: firstHop}),
            "shared forwarding check sees the transitive cycle"
        );

        // The registry walks the forwarding chain transitively (registry -> firstHop ->
        // secondHop -> registry) and rejects the default before it can be installed.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(JBRouterTerminalRegistry.JBRouterTerminalRegistry_CircularForward.selector, firstHop)
        );
        registry.setDefaultTerminal(firstHop);
    }
}
