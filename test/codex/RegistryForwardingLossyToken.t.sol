// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {JBRouterTerminalRegistry} from "../../src/JBRouterTerminalRegistry.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

contract LossyToken {
    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 1000;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 fee = amount * FEE_BPS / BPS;
        uint256 received = amount - fee;
        balanceOf[from] -= amount;
        balanceOf[to] += received;
    }
}

contract LossyFinalTerminal {
    uint256 public lastNominalAmount;
    uint256 public lastActualReceipt;

    function pay(
        uint256,
        address token,
        uint256 amount,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        returns (uint256)
    {
        lastNominalAmount = amount;
        uint256 beforeBalance = LossyToken(token).balanceOf(address(this));
        require(LossyToken(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        lastActualReceipt = LossyToken(token).balanceOf(address(this)) - beforeBalance;
        return lastActualReceipt;
    }

    function previewPayFor(
        uint256,
        address,
        uint256 amount,
        address,
        bytes calldata
    )
        external
        pure
        returns (JBRuleset memory ruleset, uint256, uint256, JBPayHookSpecification[] memory hookSpecifications)
    {
        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        hookSpecifications = new JBPayHookSpecification[](0);
        return (ruleset, amount, 0, hookSpecifications);
    }

    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](0);
    }

    function accountingContextForTokenOf(
        uint256,
        address token
    )
        external
        pure
        returns (JBAccountingContext memory context)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        context = JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

contract RegistryForwardingLossyTokenTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant AMOUNT = 100e18;

    JBRouterTerminal internal router;
    JBRouterTerminalRegistry internal registry;

    IJBDirectory internal directory;
    IJBPermissions internal permissions;
    IJBProjects internal projects;
    IJBTokens internal tokens;
    IPermit2 internal permit2;
    IWETH9 internal weth;
    IUniswapV3Factory internal factory;
    IPoolManager internal poolManager;

    LossyToken internal token;
    LossyFinalTerminal internal finalTerminal;

    address internal owner = makeAddr("owner");
    address internal payer = makeAddr("payer");

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        permissions = IJBPermissions(makeAddr("permissions"));
        projects = IJBProjects(makeAddr("projects"));
        tokens = IJBTokens(makeAddr("tokens"));
        permit2 = IPermit2(makeAddr("permit2"));
        weth = IWETH9(makeAddr("weth"));
        factory = IUniswapV3Factory(makeAddr("factory"));
        poolManager = IPoolManager(makeAddr("poolManager"));

        vm.etch(address(directory), hex"00");
        vm.etch(address(permissions), hex"00");
        vm.etch(address(projects), hex"00");
        vm.etch(address(tokens), hex"00");
        vm.etch(address(permit2), hex"00");
        vm.etch(address(weth), hex"00");
        vm.etch(address(factory), hex"00");
        vm.etch(address(poolManager), hex"00");

        router = new JBRouterTerminal({
            directory: directory,
            tokens: tokens,
            permit2: permit2,
            weth: weth,
            factory: factory,
            poolManager: poolManager,
            buybackHook: address(0),
            univ4Hook: address(0),
            trustedForwarder: address(0)
        });

        registry = new JBRouterTerminalRegistry({
            permissions: permissions, projects: projects, permit2: permit2, owner: owner, trustedForwarder: address(0)
        });

        token = new LossyToken();
        finalTerminal = new LossyFinalTerminal();

        vm.prank(owner);
        registry.setDefaultTerminal(IJBTerminal(address(finalTerminal)));

        token.mint(payer, AMOUNT);
        vm.prank(payer);
        token.approve(address(router), type(uint256).max);

        vm.mockCall(
            address(tokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(token)))), abi.encode(uint256(0))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(token))),
            abi.encode(address(registry))
        );
    }

    function test_routerSkipsFinalReceiptCheckWhenRegistryForwardsLossyToken() public {
        vm.prank(payer);
        uint256 minted = router.pay(PROJECT_ID, address(token), AMOUNT, payer, 0, "", "");

        assertEq(token.balanceOf(address(registry)), 0, "registry should not retain leftovers");
        assertEq(finalTerminal.lastNominalAmount(), 81e18, "registry forwards only what it received");
        assertEq(finalTerminal.lastActualReceipt(), 72.9e18, "final terminal receives less on the second lossy hop");
        assertEq(minted, 72.9e18, "call succeeds using the shrunken receipt");
    }

    function test_directRouterPathRevertsOnSameLossyToken() public {
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(token))),
            abi.encode(address(finalTerminal))
        );

        vm.prank(payer);
        vm.expectRevert(JBRouterTerminal.JBRouterTerminal_NonStandardTerminalToken.selector);
        router.pay(PROJECT_ID, address(token), AMOUNT, payer, 0, "", "");
    }
}
