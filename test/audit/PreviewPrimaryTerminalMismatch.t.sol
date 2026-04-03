// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

contract AuditMismatchToken {
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
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract AuditPreviewTerminal {
    address public immutable acceptedToken;
    uint256 public immutable previewCount;
    uint256 public totalReceived;

    constructor(address acceptedToken_, uint256 previewCount_) {
        acceptedToken = acceptedToken_;
        previewCount = previewCount_;
    }

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
        AuditMismatchToken(token).transferFrom(msg.sender, address(this), amount);
        totalReceived += amount;
        return previewCount;
    }

    function previewPayFor(
        uint256,
        address,
        uint256,
        address,
        bytes calldata
    )
        external
        view
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
        return (ruleset, previewCount, 0, hookSpecifications);
    }

    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        contexts[0] =
            JBAccountingContext({token: acceptedToken, decimals: 18, currency: uint32(uint160(acceptedToken))});
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

contract PreviewPrimaryTerminalMismatchTest is Test {
    JBRouterTerminal internal router;

    IJBDirectory internal directory;
    IJBPermissions internal permissions;
    IJBTokens internal tokens;
    IPermit2 internal permit2;
    IWETH9 internal weth;
    IUniswapV3Factory internal factory;
    IPoolManager internal poolManager;

    AuditMismatchToken internal token;
    AuditPreviewTerminal internal fakePreviewTerminal;
    AuditPreviewTerminal internal primaryTerminal;

    address internal payer = makeAddr("payer");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        permissions = IJBPermissions(makeAddr("permissions"));
        tokens = IJBTokens(makeAddr("tokens"));
        permit2 = IPermit2(makeAddr("permit2"));
        weth = IWETH9(makeAddr("weth"));
        factory = IUniswapV3Factory(makeAddr("factory"));
        poolManager = IPoolManager(makeAddr("poolManager"));

        vm.etch(address(directory), hex"00");
        vm.etch(address(permissions), hex"00");
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
            trustedForwarder: address(0)
        });

        token = new AuditMismatchToken();
        fakePreviewTerminal = new AuditPreviewTerminal(address(token), 1000e18);
        primaryTerminal = new AuditPreviewTerminal(address(token), 1e18);

        token.mint(payer, 100e18);
        vm.prank(payer);
        token.approve(address(router), type(uint256).max);

        vm.mockCall(
            address(tokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(token)))), abi.encode(uint256(0))
        );

        IJBTerminal[] memory terminals = new IJBTerminal[](2);
        terminals[0] = IJBTerminal(address(fakePreviewTerminal));
        terminals[1] = IJBTerminal(address(primaryTerminal));
        vm.mockCall(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (1)), abi.encode(terminals));

        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, address(token))),
            abi.encode(address(primaryTerminal))
        );
    }

    function test_previewUsesPrimaryTerminalLikeExecution() public {
        (, uint256 previewBeneficiaryTokenCount,,) = router.previewPayFor(1, address(token), 100e18, beneficiary, "");

        vm.prank(payer);
        uint256 minted = router.pay(1, address(token), 100e18, beneficiary, 0, "", "");

        assertEq(previewBeneficiaryTokenCount, 1e18, "preview should read the primary terminal");
        assertEq(minted, 1e18, "execution should use the primary terminal too");
        assertEq(primaryTerminal.totalReceived(), 100e18, "payment should be forwarded to the primary terminal");
        assertEq(fakePreviewTerminal.totalReceived(), 0, "non-primary preview terminal should never receive funds");
    }
}
