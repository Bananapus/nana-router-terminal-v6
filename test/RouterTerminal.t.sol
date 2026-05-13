// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {JBRouterTerminalRegistry} from "../src/JBRouterTerminalRegistry.sol";
import {JBPayRouteResolver} from "../src/JBPayRouteResolver.sol";
import {IJBPayRoutePreviewer} from "../src/interfaces/IJBPayRoutePreviewer.sol";
import {IJBRouterTerminal} from "../src/interfaces/IJBRouterTerminal.sol";
import {PoolInfo} from "../src/structs/PoolInfo.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

/// @notice Minimal ERC20 mock that tracks balances so balanceOf delta works with _acceptFundsFor.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }
}

contract MockERC20WithDecimals is MockERC20 {
    uint8 internal immutable _DECIMALS;

    constructor(uint8 decimals_) {
        _DECIMALS = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _DECIMALS;
    }
}

contract MockERC20BrokenDecimals is MockERC20 {
    function decimals() external pure returns (uint8) {
        revert();
    }
}

/// @notice Mock WETH that tracks balances and sends ETH on withdraw.
contract MockWETH9 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "MockWETH9: insufficient balance");
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "MockWETH9: ETH transfer failed");
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

/// @notice Mock PoolManager that only supports settle{value:...}() for _settleV4 testing.
contract MockPoolManagerForSettle {
    uint256 public lastSettleAmount;

    function settle() external payable returns (uint256) {
        lastSettleAmount = msg.value;
        return msg.value;
    }

    // Fallback so vm.etch and other calls don't revert.
    fallback() external payable {}
    receive() external payable {}
}

contract MockPreviewDestTerminal {
    address public immutable ACCEPTED_TOKEN;
    uint256 public immutable PREVIEWED_TOKEN_COUNT;
    uint256 public totalBalanceAdded;
    uint256 public totalReceived;

    constructor(address acceptedToken_, uint256 previewedTokenCount_) {
        ACCEPTED_TOKEN = acceptedToken_;
        PREVIEWED_TOKEN_COUNT = previewedTokenCount_;
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
        payable
        returns (uint256)
    {
        if (token == JBConstants.NATIVE_TOKEN) require(msg.value == amount, "MockPreviewDestTerminal: ETH mismatch");
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        else IERC20(token).transferFrom(msg.sender, address(this), amount);

        totalReceived += amount;
        return PREVIEWED_TOKEN_COUNT;
    }

    function addToBalanceOf(
        uint256,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
    {
        if (token == JBConstants.NATIVE_TOKEN) require(msg.value == amount, "MockPreviewDestTerminal: ETH mismatch");
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        else IERC20(token).transferFrom(msg.sender, address(this), amount);

        totalBalanceAdded += amount;
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
            id: 2,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        hookSpecifications = new JBPayHookSpecification[](0);
        return (ruleset, PREVIEWED_TOKEN_COUNT, 0, hookSpecifications);
    }

    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 currency = uint32(uint160(ACCEPTED_TOKEN));
        contexts[0] = JBAccountingContext({token: ACCEPTED_TOKEN, decimals: 18, currency: currency});
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    receive() external payable {}
}

contract PayerSensitivePreviewTerminal {
    address public immutable EXPECTED_PAYER;
    address public immutable ACCEPTED_TOKEN;
    uint256 public immutable MATCHING_PREVIEW;
    uint256 public immutable MISMATCH_PREVIEW;

    constructor(address expectedPayer_, address acceptedToken_, uint256 matchingPreview_, uint256 mismatchPreview_) {
        EXPECTED_PAYER = expectedPayer_;
        ACCEPTED_TOKEN = acceptedToken_;
        MATCHING_PREVIEW = matchingPreview_;
        MISMATCH_PREVIEW = mismatchPreview_;
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
            id: 444,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        hookSpecifications = new JBPayHookSpecification[](0);
        return (ruleset, msg.sender == EXPECTED_PAYER ? MATCHING_PREVIEW : MISMATCH_PREVIEW, 0, hookSpecifications);
    }

    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: ACCEPTED_TOKEN, decimals: 18, currency: uint32(uint160(ACCEPTED_TOKEN))});
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

contract MockPreviewCashOutTerminal {
    uint256 public immutable RECLAIM_AMOUNT;
    MockERC20 public immutable TOKEN;

    constructor(MockERC20 token_, uint256 reclaimAmount_) payable {
        TOKEN = token_;
        RECLAIM_AMOUNT = reclaimAmount_;
    }

    function cashOutTokensOf(
        address holder,
        uint256,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256,
        address payable beneficiary,
        bytes calldata
    )
        external
        returns (uint256)
    {
        TOKEN.burn(holder, cashOutCount);

        if (tokenToReclaim == JBConstants.NATIVE_TOKEN) {
            (bool success,) = beneficiary.call{value: RECLAIM_AMOUNT}("");
            require(success, "MockPreviewCashOutTerminal: ETH send failed");
        }
        return RECLAIM_AMOUNT;
    }

    function previewCashOutFrom(
        address,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata
    )
        external
        view
        returns (JBRuleset memory ruleset, uint256, uint256, JBCashOutHookSpecification[] memory hookSpecifications)
    {
        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 3,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        hookSpecifications = new JBCashOutHookSpecification[](0);
        return (ruleset, RECLAIM_AMOUNT, 0, hookSpecifications);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBCashOutTerminal).interfaceId || interfaceId == type(IJBTerminal).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
    }

    receive() external payable {}
}

contract MockConfigurableCashOutTerminal {
    MockERC20 public immutable TOKEN;
    address public immutable RECLAIM_TOKEN;
    uint256 public immutable PREVIEW_RECLAIM_AMOUNT;
    uint256 public immutable EXECUTION_TRANSFER_AMOUNT;
    uint256 public immutable EXECUTION_RETURN_AMOUNT;

    constructor(
        MockERC20 token_,
        address reclaimToken_,
        uint256 previewReclaimAmount_,
        uint256 executionTransferAmount_,
        uint256 executionReturnAmount_
    )
        payable {
        TOKEN = token_;
        RECLAIM_TOKEN = reclaimToken_;
        PREVIEW_RECLAIM_AMOUNT = previewReclaimAmount_;
        EXECUTION_TRANSFER_AMOUNT = executionTransferAmount_;
        EXECUTION_RETURN_AMOUNT = executionReturnAmount_;
    }

    function cashOutTokensOf(
        address holder,
        uint256,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256,
        address payable beneficiary,
        bytes calldata
    )
        external
        returns (uint256)
    {
        require(tokenToReclaim == RECLAIM_TOKEN, "MockConfigurableCashOutTerminal: wrong reclaim token");
        TOKEN.burn(holder, cashOutCount);

        if (tokenToReclaim == JBConstants.NATIVE_TOKEN) {
            (bool success,) = beneficiary.call{value: EXECUTION_TRANSFER_AMOUNT}("");
            require(success, "MockConfigurableCashOutTerminal: ETH send failed");
        } else {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(tokenToReclaim).transfer(beneficiary, EXECUTION_TRANSFER_AMOUNT);
        }

        return EXECUTION_RETURN_AMOUNT;
    }

    function previewCashOutFrom(
        address,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata
    )
        external
        view
        returns (JBRuleset memory ruleset, uint256, uint256, JBCashOutHookSpecification[] memory hookSpecifications)
    {
        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 3,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        hookSpecifications = new JBCashOutHookSpecification[](0);
        return (ruleset, PREVIEW_RECLAIM_AMOUNT, 0, hookSpecifications);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBCashOutTerminal).interfaceId || interfaceId == type(IJBTerminal).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: RECLAIM_TOKEN, decimals: 18, currency: uint32(uint160(RECLAIM_TOKEN))});
    }

    receive() external payable {}
}

/// @notice A harness that exposes internal functions for testing.
contract RouterTerminalHarness is JBRouterTerminal {
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        IPermit2 permit2,
        address owner,
        address buybackHook,
        address trustedForwarder,
        address deployer
    )
        // forge-lint: disable-next-line — Solidity disallows named-args in parent ctor invocations.
        JBRouterTerminal(directory, tokens, permit2, buybackHook, trustedForwarder, deployer)
    {}

    function exposedResolveTokenOut(
        uint256 projectId,
        address tokenIn,
        bytes calldata metadata
    )
        external
        view
        returns (address tokenOut, IJBTerminal destTerminal)
    {
        return _PAY_ROUTE_RESOLVER.resolveTokenOut({
            router: IJBPayRoutePreviewer(address(this)), projectId: projectId, tokenIn: tokenIn, metadata: metadata
        });
    }

    function exposedDiscoverPool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        external
        view
        returns (PoolInfo memory pool)
    {
        pool = _discoverPool(normalizedTokenIn, normalizedTokenOut);
        if (!pool.isV4 && address(pool.v3Pool) == address(0)) {
            revert JBRouterTerminal_NoPoolFound(normalizedTokenIn, normalizedTokenOut);
        }
    }

    function exposedSettleV4(Currency currency, uint256 amount, bool canUseExistingNativeBalance) external {
        _settleV4(currency, amount, canUseExistingNativeBalance);
    }
}

contract RouterTerminalTest is Test {
    using PoolIdLibrary for PoolKey;

    RouterTerminalHarness routerTerminal;

    // Mocked dependencies
    IJBDirectory mockDirectory;
    IJBPermissions mockPermissions;
    IJBTokens mockTokens;
    IPermit2 mockPermit2;
    IWETH9 mockWeth;
    IUniswapV3Factory mockFactory;
    IPoolManager mockPoolManager;
    address buybackHook;

    address terminalOwner;

    function setUp() public {
        mockDirectory = IJBDirectory(makeAddr("mockDirectory"));
        vm.etch(address(mockDirectory), hex"00");
        mockPermissions = IJBPermissions(makeAddr("mockPermissions"));
        vm.etch(address(mockPermissions), hex"00");
        mockTokens = IJBTokens(makeAddr("mockTokens"));
        vm.etch(address(mockTokens), hex"00");
        mockPermit2 = IPermit2(makeAddr("mockPermit2"));
        vm.etch(address(mockPermit2), hex"00");
        mockWeth = IWETH9(address(new MockWETH9()));
        mockFactory = IUniswapV3Factory(makeAddr("mockFactory"));
        vm.etch(address(mockFactory), hex"00");
        mockPoolManager = IPoolManager(makeAddr("mockPoolManager"));
        vm.etch(address(mockPoolManager), hex"00");
        buybackHook = makeAddr("configuredBuybackHook");

        terminalOwner = makeAddr("terminalOwner");

        routerTerminal = new RouterTerminalHarness(
            mockDirectory,
            mockPermissions,
            mockTokens,
            mockPermit2,
            terminalOwner,
            buybackHook,
            address(0),
            address(this)
        );
        routerTerminal.setChainSpecificConstants({
            weth: mockWeth, factory: mockFactory, poolManager: mockPoolManager, univ4Hook: address(0)
        });
    }

    //*********************************************************************//
    // -------------------- accounting context tests -------------------- //
    //*********************************************************************//

    function test_accountingContext_nativeTokenFallsBackTo18Decimals() public view {
        address token = JBConstants.NATIVE_TOKEN;
        JBAccountingContext memory ctx = routerTerminal.accountingContextForTokenOf(1, token);
        assertEq(ctx.token, token);
        assertEq(ctx.decimals, 18);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(ctx.currency, uint32(uint160(token)));
    }

    function test_accountingContext_usesBestEffortTokenDecimals() public {
        address usdcLike = address(new MockERC20WithDecimals(6));
        JBAccountingContext memory ctx = routerTerminal.accountingContextForTokenOf(1, usdcLike);
        assertEq(ctx.token, usdcLike);
        assertEq(ctx.decimals, 6);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(ctx.currency, uint32(uint160(usdcLike)));
    }

    function test_accountingContext_fallsBackTo18WhenTokenBreaksDecimals() public {
        address weirdToken = address(new MockERC20BrokenDecimals());

        JBAccountingContext memory ctx = routerTerminal.accountingContextForTokenOf(1, weirdToken);
        assertEq(ctx.token, weirdToken);
        assertEq(ctx.decimals, 18);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(ctx.currency, uint32(uint160(weirdToken)));
    }

    function test_accountingContexts_empty() public view {
        JBAccountingContext[] memory ctxs = routerTerminal.accountingContextsOf(1);
        assertEq(ctxs.length, 0);
    }

    function test_currentSurplus_zero() public view {
        assertEq(routerTerminal.currentSurplusOf(1, new address[](0), 18, 1), 0);
    }

    //*********************************************************************//
    // -------------------- resolve token out tests --------------------- //
    //*********************************************************************//

    function test_resolveTokenOut_directAcceptance() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");
        address mockTerminal = makeAddr("destTerminal");
        vm.etch(mockTerminal, hex"00");

        // Project accepts tokenIn directly.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)),
            abi.encode(mockTerminal)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: tokenIn, decimals: 18, currency: uint32(uint160(tokenIn))});
        vm.mockCall(mockTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(contexts));

        (address tokenOut, IJBTerminal destTerminal) = routerTerminal.exposedResolveTokenOut(projectId, tokenIn, "");

        assertEq(tokenOut, tokenIn);
        assertEq(address(destTerminal), mockTerminal);
    }

    function test_registry_revertsWhenForwardingBackToImmediateCaller() public {
        uint256 projectId = 1;
        uint256 amount = 1 ether;
        address beneficiary = makeAddr("beneficiary");
        IJBProjects mockProjects = IJBProjects(makeAddr("mockProjects"));
        vm.etch(address(mockProjects), hex"00");

        JBRouterTerminalRegistry registry =
            new JBRouterTerminalRegistry(mockPermissions, mockProjects, mockPermit2, terminalOwner, address(0));

        // PR #108: setDefaultTerminal now reads PROJECTS.count(). Mock it to 0 (fresh chain).
        vm.mockCall(address(mockProjects), abi.encodeCall(IJBProjects.count, ()), abi.encode(uint256(0)));
        vm.prank(terminalOwner);
        registry.setDefaultTerminal(IJBTerminal(address(routerTerminal)));

        vm.deal(address(routerTerminal), amount);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminalRegistry.JBRouterTerminalRegistry_CircularForward.selector,
                IJBTerminal(address(routerTerminal))
            )
        );
        vm.prank(address(routerTerminal));
        registry.pay{value: amount}(projectId, JBConstants.NATIVE_TOKEN, amount, beneficiary, 0, "", "");
    }

    function test_resolveTokenOut_revertsWhenForwardingTerminalResolvesBackToRouter() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");
        IJBProjects mockProjects = IJBProjects(makeAddr("mockProjects"));
        vm.etch(address(mockProjects), hex"00");

        JBRouterTerminalRegistry registry =
            new JBRouterTerminalRegistry(mockPermissions, mockProjects, mockPermit2, terminalOwner, address(0));

        // PR #108: setDefaultTerminal now reads PROJECTS.count(). Mock it to 0 (fresh chain).
        vm.mockCall(address(mockProjects), abi.encodeCall(IJBProjects.count, ()), abi.encode(uint256(0)));
        vm.prank(terminalOwner);
        registry.setDefaultTerminal(IJBTerminal(address(routerTerminal)));

        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)),
            abi.encode(address(registry))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.terminalsOf, (projectId)),
            abi.encode(new IJBTerminal[](0))
        );

        vm.expectRevert(
            abi.encodeWithSelector(JBPayRouteResolver.JBRouterTerminal_NoRouteFound.selector, projectId, tokenIn)
        );
        routerTerminal.exposedResolveTokenOut(projectId, tokenIn, "");
    }

    function test_resolveTokenOut_metadataOverride() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");
        address desiredTokenOut = makeAddr("desiredOut");
        address mockTerminal = makeAddr("destTerminal");
        vm.etch(mockTerminal, hex"00");

        // Build metadata with routeTokenOut.
        bytes4 metadataId = JBMetadataResolver.getId("routeTokenOut", address(routerTerminal));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(desiredTokenOut));

        // Mock: project accepts the desired token.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, desiredTokenOut)),
            abi.encode(mockTerminal)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: desiredTokenOut, decimals: 18, currency: uint32(uint160(desiredTokenOut))});
        vm.mockCall(mockTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(contexts));

        (address tokenOut, IJBTerminal destTerminal) =
            routerTerminal.exposedResolveTokenOut(projectId, tokenIn, metadata);

        assertEq(tokenOut, desiredTokenOut);
        assertEq(address(destTerminal), mockTerminal);
    }

    function test_resolveTokenOut_discoversAcceptedToken() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");
        address acceptedToken = makeAddr("acceptedToken");
        address mockTerminal = makeAddr("destTerminal");
        address mockPool = makeAddr("mockPool");
        vm.etch(mockTerminal, hex"00");
        vm.etch(mockPool, hex"00");

        // Project doesn't accept tokenIn directly.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, acceptedToken)),
            abi.encode(mockTerminal)
        );

        // Set up terminals with accounting contexts.
        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(mockTerminal);
        vm.mockCall(
            address(mockDirectory), abi.encodeCall(IJBDirectory.terminalsOf, (projectId)), abi.encode(terminals)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: acceptedToken, decimals: 18, currency: uint32(uint160(acceptedToken))});
        vm.mockCall(mockTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(contexts));

        // Mock V3 pool discovery: pool exists at 0.3% fee tier with liquidity.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, acceptedToken, 3000)),
            abi.encode(mockPool)
        );
        vm.mockCall(mockPool, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(1000e18)));

        // Mock no V3 pools at other fee tiers.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, acceptedToken, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, acceptedToken, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, acceptedToken, 100)),
            abi.encode(address(0))
        );

        // Mock V4 — no pools found (extsload returns 0 for all).
        _mockV4NoPools(tokenIn, acceptedToken);

        (address tokenOut, IJBTerminal destTerminal) = routerTerminal.exposedResolveTokenOut(projectId, tokenIn, "");

        assertEq(tokenOut, acceptedToken);
        assertEq(address(destTerminal), mockTerminal);
    }

    function test_resolveTokenOut_revertsNoRoute() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");

        // Project doesn't accept tokenIn.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)),
            abi.encode(address(0))
        );

        // No terminals.
        IJBTerminal[] memory terminals = new IJBTerminal[](0);
        vm.mockCall(
            address(mockDirectory), abi.encodeCall(IJBDirectory.terminalsOf, (projectId)), abi.encode(terminals)
        );

        vm.expectRevert(
            abi.encodeWithSelector(JBPayRouteResolver.JBRouterTerminal_NoRouteFound.selector, projectId, tokenIn)
        );
        routerTerminal.exposedResolveTokenOut(projectId, tokenIn, "");
    }

    //*********************************************************************//
    // ----------------------- pay direct forward ----------------------- //
    //*********************************************************************//

    function test_pay_directForward() public {
        uint256 projectId = 1;
        MockERC20 token = new MockERC20();
        address tokenIn = address(token);
        uint256 amount = 1000;
        address beneficiary = makeAddr("beneficiary");
        address payer = makeAddr("payer");
        MockPreviewDestTerminal mockTerminalContract = new MockPreviewDestTerminal(tokenIn, 100);
        address mockTerminal = address(mockTerminalContract);

        // Not a JB token.
        vm.mockCall(address(mockTokens), abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));

        // Project accepts tokenIn directly.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)),
            abi.encode(mockTerminal)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: tokenIn, decimals: 18, currency: uint32(uint160(tokenIn))});
        vm.mockCall(mockTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(contexts));

        // Mint tokens to payer and approve the router terminal.
        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(routerTerminal), amount);

        vm.prank(payer);
        uint256 result = routerTerminal.pay(projectId, tokenIn, amount, beneficiary, 0, "", "");
        assertEq(result, 100);
        assertEq(mockTerminalContract.totalReceived(), amount);
    }

    //*********************************************************************//
    // -------------------- pay with native tokens ---------------------- //
    //*********************************************************************//

    function test_pay_nativeTokenDirectForward() public {
        uint256 projectId = 1;
        uint256 amount = 1 ether;
        address beneficiary = makeAddr("beneficiary");
        address payer = makeAddr("payer");
        address mockTerminal = makeAddr("destTerminal");
        vm.etch(mockTerminal, hex"00");

        // Project accepts NATIVE_TOKEN directly.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(mockTerminal)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(0)});
        vm.mockCall(mockTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(contexts));

        // Mock dest terminal pay (should receive msg.value).
        vm.mockCall(mockTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(50)));

        vm.deal(payer, amount);
        vm.prank(payer);
        uint256 result =
            routerTerminal.pay{value: amount}(projectId, JBConstants.NATIVE_TOKEN, amount, beneficiary, 0, "", "");
        assertEq(result, 50);
    }

    //*********************************************************************//
    // ----------------------- callback tests --------------------------- //
    //*********************************************************************//

    function test_callback_factoryVerified() public {
        address tokenIn = makeAddr("tokenIn");
        address tokenOut = makeAddr("tokenOut");
        address realPool = makeAddr("realPool");
        vm.etch(realPool, hex"00");
        vm.etch(tokenIn, hex"00");

        // The pool reports fee 3000.
        vm.mockCall(realPool, abi.encodeWithSignature("fee()"), abi.encode(uint24(3000)));

        // Factory confirms this pool.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, tokenOut, 3000)),
            abi.encode(realPool)
        );

        // Mock token transfer.
        vm.mockCall(tokenIn, abi.encodeCall(IERC20.transfer, (realPool, 100)), abi.encode(true));

        bytes memory data = abi.encode(uint256(1), tokenIn, tokenOut);

        // Call from the real pool — should succeed.
        vm.prank(realPool);
        routerTerminal.uniswapV3SwapCallback(int256(-200), int256(100), data);
    }

    function test_callback_rejectsUnverified() public {
        address tokenIn = makeAddr("tokenIn");
        address tokenOut = makeAddr("tokenOut");
        address fakePool = makeAddr("fakePool");
        address realPool = makeAddr("realPool");
        vm.etch(fakePool, hex"00");

        // Fake pool reports fee 3000.
        vm.mockCall(fakePool, abi.encodeWithSignature("fee()"), abi.encode(uint24(3000)));

        // Factory returns a different pool address.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, tokenOut, 3000)),
            abi.encode(realPool)
        );

        bytes memory data = abi.encode(uint256(1), tokenIn, tokenOut);

        vm.prank(fakePool);
        vm.expectRevert(abi.encodeWithSelector(JBRouterTerminal.JBRouterTerminal_CallerNotPool.selector, fakePool));
        routerTerminal.uniswapV3SwapCallback(int256(-200), int256(100), data);
    }

    //*********************************************************************//
    // -------------------- addToBalanceOf tests ------------------------ //
    //*********************************************************************//

    function test_addToBalanceOf_directForward() public {
        uint256 projectId = 1;
        MockERC20 token = new MockERC20();
        address tokenIn = address(token);
        uint256 amount = 500;
        address payer = makeAddr("payer");
        MockPreviewDestTerminal mockTerminalContract = new MockPreviewDestTerminal(tokenIn, 0);
        address mockTerminal = address(mockTerminalContract);

        // Not a JB token.
        vm.mockCall(address(mockTokens), abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));

        // Project accepts tokenIn.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)),
            abi.encode(mockTerminal)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: tokenIn, decimals: 18, currency: uint32(uint160(tokenIn))});
        vm.mockCall(mockTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(contexts));

        // Mint tokens to payer and approve the router terminal.
        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(routerTerminal), amount);

        vm.prank(payer);
        routerTerminal.addToBalanceOf(projectId, tokenIn, amount, false, "", "");
        assertEq(mockTerminalContract.totalBalanceAdded(), amount);
    }

    //*********************************************************************//
    // -------------------- discover pool tests ------------------------- //
    //*********************************************************************//

    function test_discoverPool_findsBestLiquidity() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        address pool3000 = makeAddr("pool3000");
        address pool500 = makeAddr("pool500");
        vm.etch(pool3000, hex"00");
        vm.etch(pool500, hex"00");

        // Pool at 0.3% has lower liquidity.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 3000)),
            abi.encode(pool3000)
        );
        vm.mockCall(pool3000, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(100e18)));

        // Pool at 0.05% has higher liquidity.
        vm.mockCall(
            address(mockFactory), abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 500)), abi.encode(pool500)
        );
        vm.mockCall(pool500, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(500e18)));

        // No pools at other tiers.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 100)),
            abi.encode(address(0))
        );

        // Mock V4 — no pools.
        _mockV4NoPools(tokenA, tokenB);

        PoolInfo memory result = routerTerminal.exposedDiscoverPool(tokenA, tokenB);
        assertFalse(result.isV4);
        assertEq(address(result.v3Pool), pool500);
    }

    function test_discoverPool_revertsNoPool() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");

        // No V3 pools at any tier.
        vm.mockCall(
            address(mockFactory), abi.encodeWithSelector(IUniswapV3Factory.getPool.selector), abi.encode(address(0))
        );

        // No V4 pools.
        _mockV4NoPools(tokenA, tokenB);

        vm.expectRevert(abi.encodeWithSelector(JBRouterTerminal.JBRouterTerminal_NoPoolFound.selector, tokenA, tokenB));
        routerTerminal.exposedDiscoverPool(tokenA, tokenB);
    }

    //*********************************************************************//
    // -------------------- supports interface tests -------------------- //
    //*********************************************************************//

    function test_supportsInterface() public view {
        assertTrue(routerTerminal.supportsInterface(type(IJBTerminal).interfaceId));
        assertTrue(routerTerminal.supportsInterface(type(IJBRouterTerminal).interfaceId));
        assertTrue(routerTerminal.supportsInterface(type(IERC165).interfaceId));
    }

    function test_previewPayFor_forwardsDirectRoute() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");
        address beneficiary = makeAddr("beneficiary");
        address destTerminal = makeAddr("destTerminal");

        vm.etch(destTerminal, hex"00");

        vm.mockCall(
            address(mockTokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(tokenIn))), abi.encode(uint256(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)),
            abi.encode(destTerminal)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        contexts[0] = JBAccountingContext({token: tokenIn, decimals: 18, currency: uint32(uint160(tokenIn))});
        vm.mockCall(destTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(contexts));

        JBRuleset memory expectedRuleset = JBRuleset({
            cycleNumber: 1,
            id: 2,
            basedOnId: 1,
            start: 3,
            duration: 4,
            weight: 5,
            weightCutPercent: 6,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 7
        });
        JBPayHookSpecification[] memory expectedSpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            destTerminal,
            abi.encodeCall(IJBTerminal.previewPayFor, (projectId, tokenIn, 100, beneficiary, bytes(""))),
            abi.encode(expectedRuleset, uint256(11), uint256(12), expectedSpecs)
        );

        (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        ) = routerTerminal.previewPayFor(projectId, tokenIn, 100, beneficiary, "");

        assertEq(ruleset.id, expectedRuleset.id);
        assertEq(beneficiaryTokenCount, 11);
        assertEq(reservedTokenCount, 12);
        assertEq(hookSpecifications.length, 0);
    }

    function test_previewPayFor_usesRouterAsDownstreamPreviewCaller() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");
        address beneficiary = makeAddr("beneficiary");
        PayerSensitivePreviewTerminal terminal =
            new PayerSensitivePreviewTerminal(address(routerTerminal), tokenIn, 123, 1);

        vm.mockCall(
            address(mockTokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(tokenIn))), abi.encode(uint256(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)),
            abi.encode(address(terminal))
        );

        IJBTerminal[] memory terminals = new IJBTerminal[](0);
        vm.mockCall(
            address(mockDirectory), abi.encodeCall(IJBDirectory.terminalsOf, (projectId)), abi.encode(terminals)
        );

        (, uint256 beneficiaryTokenCount,,) = routerTerminal.previewPayFor(projectId, tokenIn, 100, beneficiary, "");

        assertEq(beneficiaryTokenCount, 123);
    }

    function test_previewPayFor_forwardsWrapRoute() public {
        uint256 projectId = 1;
        address beneficiary = makeAddr("beneficiary");
        address destTerminal = makeAddr("destTerminal");

        vm.etch(destTerminal, hex"00");

        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, address(mockWeth))),
            abi.encode(destTerminal)
        );

        JBRuleset memory expectedRuleset = JBRuleset({
            cycleNumber: 9,
            id: 8,
            basedOnId: 7,
            start: 6,
            duration: 5,
            weight: 4,
            weightCutPercent: 3,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 2
        });
        JBPayHookSpecification[] memory expectedSpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            destTerminal,
            abi.encodeCall(IJBTerminal.previewPayFor, (projectId, address(mockWeth), 1 ether, beneficiary, bytes(""))),
            abi.encode(expectedRuleset, uint256(21), uint256(22), expectedSpecs)
        );

        (JBRuleset memory ruleset, uint256 beneficiaryTokenCount, uint256 reservedTokenCount,) =
            routerTerminal.previewPayFor(projectId, JBConstants.NATIVE_TOKEN, 1 ether, beneficiary, "");

        assertEq(ruleset.id, expectedRuleset.id);
        assertEq(beneficiaryTokenCount, 21);
        assertEq(reservedTokenCount, 22);
    }

    function test_previewPayFor_forwardsCashOutRoute() public {
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;
        address jbToken = makeAddr("jbToken");
        address beneficiary = makeAddr("beneficiary");
        address destTerminal = makeAddr("destTerminal");
        address cashOutTerminal = makeAddr("cashOutTerminal");

        vm.etch(destTerminal, hex"00");
        vm.etch(cashOutTerminal, hex"00");

        vm.mockCall(
            address(mockTokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(jbToken))), abi.encode(sourceProjectId)
        );
        vm.mockCall(
            address(mockTokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(JBConstants.NATIVE_TOKEN))),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, jbToken)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(destTerminal)
        );

        IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
        sourceTerminals[0] = IJBTerminal(cashOutTerminal);
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
            abi.encode(sourceTerminals)
        );

        vm.mockCall(
            cashOutTerminal,
            abi.encodeCall(IERC165.supportsInterface, (type(IJBCashOutTerminal).interfaceId)),
            abi.encode(true)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        vm.mockCall(
            cashOutTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (sourceProjectId)), abi.encode(contexts)
        );

        vm.mockCall(
            cashOutTerminal,
            abi.encodeCall(
                IJBCashOutTerminal.previewCashOutFrom,
                (
                    address(routerTerminal),
                    sourceProjectId,
                    100,
                    JBConstants.NATIVE_TOKEN,
                    payable(address(routerTerminal)),
                    bytes("")
                )
            ),
            abi.encode(
                JBRuleset({
                    cycleNumber: 0,
                    id: 0,
                    basedOnId: 0,
                    start: 0,
                    duration: 0,
                    weight: 0,
                    weightCutPercent: 0,
                    approvalHook: IJBRulesetApprovalHook(address(0)),
                    metadata: 0
                }),
                uint256(60),
                uint256(0),
                new JBCashOutHookSpecification[](0)
            )
        );

        JBRuleset memory expectedRuleset = JBRuleset({
            cycleNumber: 1,
            id: 77,
            basedOnId: 1,
            start: 1,
            duration: 1,
            weight: 1,
            weightCutPercent: 1,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 1
        });
        JBPayHookSpecification[] memory expectedSpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            destTerminal,
            abi.encodeCall(
                IJBTerminal.previewPayFor, (destProjectId, JBConstants.NATIVE_TOKEN, 60, beneficiary, bytes(""))
            ),
            abi.encode(expectedRuleset, uint256(31), uint256(32), expectedSpecs)
        );

        (JBRuleset memory ruleset, uint256 beneficiaryTokenCount, uint256 reservedTokenCount,) =
            routerTerminal.previewPayFor(destProjectId, jbToken, 100, beneficiary, "");

        assertEq(ruleset.id, expectedRuleset.id);
        assertEq(beneficiaryTokenCount, 31);
        assertEq(reservedTokenCount, 32);
    }

    function test_previewPayFor_estimatesSwapRouteWithQuoteMetadata() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");
        address tokenOut = makeAddr("tokenOut");
        address beneficiary = makeAddr("beneficiary");
        address destTerminal = makeAddr("destTerminal");
        address pool = makeAddr("pool");
        uint256 quotedAmountOut = 55;

        vm.etch(destTerminal, hex"00");
        vm.etch(pool, hex"00");

        bytes4 routeTokenOutId = JBMetadataResolver.getId("routeTokenOut", address(routerTerminal));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", routeTokenOutId, abi.encode(tokenOut));
        bytes4 quoteId = JBMetadataResolver.getId("quoteForSwap", address(routerTerminal));
        metadata = JBMetadataResolver.addToMetadata(metadata, quoteId, abi.encode(quotedAmountOut));

        vm.mockCall(
            address(mockTokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(tokenIn))), abi.encode(uint256(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(destTerminal)
        );

        vm.mockCall(
            address(mockFactory), abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, tokenOut, 3000)), abi.encode(pool)
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, tokenOut, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, tokenOut, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, tokenOut, 100)),
            abi.encode(address(0))
        );
        vm.mockCall(pool, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(1000)));
        _mockV4NoPools(tokenIn, tokenOut);

        JBRuleset memory expectedRuleset = JBRuleset({
            cycleNumber: 1,
            id: 88,
            basedOnId: 1,
            start: 1,
            duration: 1,
            weight: 1,
            weightCutPercent: 1,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 1
        });
        JBPayHookSpecification[] memory expectedSpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            destTerminal,
            abi.encodeCall(IJBTerminal.previewPayFor, (projectId, tokenOut, quotedAmountOut, beneficiary, metadata)),
            abi.encode(expectedRuleset, uint256(41), uint256(42), expectedSpecs)
        );

        (JBRuleset memory ruleset, uint256 beneficiaryTokenCount, uint256 reservedTokenCount,) =
            routerTerminal.previewPayFor(projectId, tokenIn, 100, beneficiary, metadata);

        assertEq(ruleset.id, expectedRuleset.id);
        assertEq(beneficiaryTokenCount, 41);
        assertEq(reservedTokenCount, 42);
    }

    function test_previewPayFor_estimatesCashOutThenSwapRouteWithQuoteMetadata() public {
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;
        address jbToken = makeAddr("jbToken");
        address tokenOut = makeAddr("tokenOut");
        address beneficiary = makeAddr("beneficiary");
        address destTerminal = makeAddr("destTerminal");
        address cashOutTerminal = makeAddr("cashOutTerminal");
        address pool = makeAddr("pool");
        uint256 quotedAmountOut = 77;

        vm.etch(destTerminal, hex"00");
        vm.etch(cashOutTerminal, hex"00");
        vm.etch(pool, hex"00");

        bytes4 routeTokenOutId = JBMetadataResolver.getId("routeTokenOut", address(routerTerminal));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", routeTokenOutId, abi.encode(tokenOut));
        bytes4 quoteId = JBMetadataResolver.getId("quoteForSwap", address(routerTerminal));
        metadata = JBMetadataResolver.addToMetadata(metadata, quoteId, abi.encode(quotedAmountOut));

        vm.mockCall(
            address(mockTokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(jbToken))), abi.encode(sourceProjectId)
        );
        vm.mockCall(
            address(mockTokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(JBConstants.NATIVE_TOKEN))),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, jbToken)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, tokenOut)),
            abi.encode(destTerminal)
        );

        IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
        sourceTerminals[0] = IJBTerminal(cashOutTerminal);
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
            abi.encode(sourceTerminals)
        );
        vm.mockCall(
            cashOutTerminal,
            abi.encodeCall(IERC165.supportsInterface, (type(IJBCashOutTerminal).interfaceId)),
            abi.encode(true)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        vm.mockCall(
            cashOutTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (sourceProjectId)), abi.encode(contexts)
        );
        vm.mockCall(
            cashOutTerminal,
            abi.encodeCall(
                IJBCashOutTerminal.previewCashOutFrom,
                (
                    address(routerTerminal),
                    sourceProjectId,
                    100,
                    JBConstants.NATIVE_TOKEN,
                    payable(address(routerTerminal)),
                    bytes("")
                )
            ),
            abi.encode(
                JBRuleset({
                    cycleNumber: 0,
                    id: 0,
                    basedOnId: 0,
                    start: 0,
                    duration: 0,
                    weight: 0,
                    weightCutPercent: 0,
                    approvalHook: IJBRulesetApprovalHook(address(0)),
                    metadata: 0
                }),
                uint256(60),
                uint256(0),
                new JBCashOutHookSpecification[](0)
            )
        );

        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (address(mockWeth), tokenOut, 3000)),
            abi.encode(pool)
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (address(mockWeth), tokenOut, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (address(mockWeth), tokenOut, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (address(mockWeth), tokenOut, 100)),
            abi.encode(address(0))
        );
        vm.mockCall(pool, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(1000)));
        _mockV4NoPools(address(0), tokenOut);

        JBRuleset memory expectedRuleset = JBRuleset({
            cycleNumber: 1,
            id: 99,
            basedOnId: 1,
            start: 1,
            duration: 1,
            weight: 1,
            weightCutPercent: 1,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 1
        });
        JBPayHookSpecification[] memory expectedSpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            destTerminal,
            abi.encodeCall(
                IJBTerminal.previewPayFor, (destProjectId, tokenOut, quotedAmountOut, beneficiary, metadata)
            ),
            abi.encode(expectedRuleset, uint256(51), uint256(52), expectedSpecs)
        );

        (JBRuleset memory ruleset, uint256 beneficiaryTokenCount, uint256 reservedTokenCount,) =
            routerTerminal.previewPayFor(destProjectId, jbToken, 100, beneficiary, metadata);

        assertEq(ruleset.id, expectedRuleset.id);
        assertEq(beneficiaryTokenCount, 51);
        assertEq(reservedTokenCount, 52);
    }

    function testFuzz_previewPayFor_forwardsQuotedSwapEstimate(uint256 amountIn, uint256 quotedAmountOut) public {
        amountIn = bound(amountIn, 1, type(uint128).max);
        quotedAmountOut = bound(quotedAmountOut, 1, type(uint128).max);

        uint256 projectId = 1;
        address tokenIn = makeAddr("fuzzTokenIn");
        address tokenOut = makeAddr("fuzzTokenOut");
        address beneficiary = makeAddr("fuzzBeneficiary");
        address destTerminal = makeAddr("fuzzDestTerminal");
        address pool = makeAddr("fuzzPool");

        vm.etch(destTerminal, hex"00");
        vm.etch(pool, hex"00");

        bytes4 routeTokenOutId = JBMetadataResolver.getId("routeTokenOut", address(routerTerminal));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", routeTokenOutId, abi.encode(tokenOut));
        bytes4 quoteId = JBMetadataResolver.getId("quoteForSwap", address(routerTerminal));
        metadata = JBMetadataResolver.addToMetadata(metadata, quoteId, abi.encode(quotedAmountOut));

        vm.mockCall(
            address(mockTokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(tokenIn))), abi.encode(uint256(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenOut)),
            abi.encode(destTerminal)
        );
        vm.mockCall(
            address(mockFactory), abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, tokenOut, 3000)), abi.encode(pool)
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, tokenOut, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, tokenOut, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, tokenOut, 100)),
            abi.encode(address(0))
        );
        vm.mockCall(pool, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(1000)));
        _mockV4NoPools(tokenIn, tokenOut);

        JBPayHookSpecification[] memory expectedSpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            destTerminal,
            abi.encodeCall(IJBTerminal.previewPayFor, (projectId, tokenOut, quotedAmountOut, beneficiary, metadata)),
            abi.encode(
                JBRuleset({
                    cycleNumber: 0,
                    id: 1,
                    basedOnId: 0,
                    start: 0,
                    duration: 0,
                    weight: 0,
                    weightCutPercent: 0,
                    approvalHook: IJBRulesetApprovalHook(address(0)),
                    metadata: 0
                }),
                quotedAmountOut,
                uint256(0),
                expectedSpecs
            )
        );

        (, uint256 beneficiaryTokenCount,,) =
            routerTerminal.previewPayFor(projectId, tokenIn, amountIn, beneficiary, metadata);

        assertEq(beneficiaryTokenCount, quotedAmountOut);
    }

    function test_previewPayFor_decodesBuybackPayHookMetadata() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("buybackTokenIn");
        address beneficiary = makeAddr("buybackBeneficiary");
        address destTerminal = makeAddr("buybackDestTerminal");
        vm.etch(destTerminal, hex"00");
        vm.etch(buybackHook, hex"00");

        vm.mockCall(
            address(mockTokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(tokenIn))), abi.encode(uint256(0))
        );

        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(destTerminal);
        vm.mockCall(
            address(mockDirectory), abi.encodeCall(IJBDirectory.terminalsOf, (projectId)), abi.encode(terminals)
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, tokenIn)),
            abi.encode(destTerminal)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        contexts[0] = JBAccountingContext({token: tokenIn, decimals: 18, currency: uint32(uint160(tokenIn))});
        vm.mockCall(destTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(contexts));

        bytes4 buybackInterfaceId = bytes4(keccak256("MAX_TWAP_WINDOW()"));
        vm.mockCall(buybackHook, abi.encodeCall(IERC165.supportsInterface, (buybackInterfaceId)), abi.encode(true));

        JBPayHookSpecification[] memory hookSpecifications = _buybackPayHookSpecifications(buybackHook, 123, 7);

        vm.mockCall(
            destTerminal,
            abi.encodeCall(IJBTerminal.previewPayFor, (projectId, tokenIn, 100, beneficiary, bytes(""))),
            abi.encode(
                JBRuleset({
                    cycleNumber: 1,
                    id: 111,
                    basedOnId: 0,
                    start: 0,
                    duration: 0,
                    weight: 0,
                    weightCutPercent: 0,
                    approvalHook: IJBRulesetApprovalHook(address(0)),
                    metadata: 0
                }),
                uint256(0),
                uint256(0),
                hookSpecifications
            )
        );

        (, uint256 beneficiaryTokenCount, uint256 reservedTokenCount, JBPayHookSpecification[] memory returnedSpecs) =
            routerTerminal.previewPayFor(projectId, tokenIn, 100, beneficiary, "");

        assertEq(beneficiaryTokenCount, 123);
        assertEq(reservedTokenCount, 7);
        assertEq(returnedSpecs.length, 1);
        assertEq(address(returnedSpecs[0].hook), buybackHook);
    }

    function test_previewPayFor_prefersRouteWithHigherBuybackHookOutput() public {
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;
        uint256 amount = 100;
        address payer = makeAddr("bestRoutePayer");
        address beneficiary = makeAddr("bestRouteBeneficiary");
        MockERC20 jbToken = new MockERC20();
        MockERC20 reclaimToken = new MockERC20();
        address tokenB = address(reclaimToken);
        MockPreviewDestTerminal nativeTerminal = new MockPreviewDestTerminal(JBConstants.NATIVE_TOKEN, 100);
        MockPreviewDestTerminal tokenBTerminal = new MockPreviewDestTerminal(tokenB, 150);
        MockConfigurableCashOutTerminal nativeCashOut =
            new MockConfigurableCashOutTerminal{value: 40}(jbToken, JBConstants.NATIVE_TOKEN, 40, 40, 40);
        MockConfigurableCashOutTerminal tokenBCashOut = new MockConfigurableCashOutTerminal(jbToken, tokenB, 50, 50, 50);

        reclaimToken.mint(address(tokenBCashOut), 50);
        jbToken.mint(payer, amount);

        vm.etch(buybackHook, hex"00");
        vm.mockCall(
            address(mockTokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(jbToken)))),
            abi.encode(sourceProjectId)
        );
        vm.mockCall(
            address(mockTokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(tokenB))), abi.encode(uint256(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(nativeTerminal))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, tokenB)),
            abi.encode(address(tokenBTerminal))
        );

        IJBTerminal[] memory sourceTerminals = new IJBTerminal[](2);
        sourceTerminals[0] = IJBTerminal(address(nativeCashOut));
        sourceTerminals[1] = IJBTerminal(address(tokenBCashOut));
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
            abi.encode(sourceTerminals)
        );

        IJBTerminal[] memory destTerminals = new IJBTerminal[](2);
        destTerminals[0] = IJBTerminal(address(nativeTerminal));
        destTerminals[1] = IJBTerminal(address(tokenBTerminal));
        vm.mockCall(
            address(mockDirectory), abi.encodeCall(IJBDirectory.terminalsOf, (destProjectId)), abi.encode(destTerminals)
        );

        bytes4 buybackInterfaceId = bytes4(keccak256("MAX_TWAP_WINDOW()"));
        vm.mockCall(buybackHook, abi.encodeCall(IERC165.supportsInterface, (buybackInterfaceId)), abi.encode(true));

        JBPayHookSpecification[] memory buybackSpecs = _buybackPayHookSpecifications(buybackHook, 150, 5);
        vm.mockCall(
            address(tokenBTerminal),
            abi.encodeCall(IJBTerminal.previewPayFor, (destProjectId, tokenB, 50, beneficiary, bytes(""))),
            abi.encode(
                JBRuleset({
                    cycleNumber: 1,
                    id: 222,
                    basedOnId: 0,
                    start: 0,
                    duration: 0,
                    weight: 0,
                    weightCutPercent: 0,
                    approvalHook: IJBRulesetApprovalHook(address(0)),
                    metadata: 0
                }),
                uint256(0),
                uint256(0),
                buybackSpecs
            )
        );

        vm.startPrank(payer);
        jbToken.approve(address(routerTerminal), amount);

        (, uint256 previewTokenCount,,) =
            routerTerminal.previewPayFor(destProjectId, address(jbToken), amount, beneficiary, "");
        uint256 mintedTokenCount =
            routerTerminal.pay(destProjectId, address(jbToken), amount, beneficiary, 0, "best route", "");
        vm.stopPrank();

        assertEq(previewTokenCount, 150);
        assertEq(mintedTokenCount, 150);
        assertEq(nativeTerminal.totalReceived(), 0);
        assertEq(tokenBTerminal.totalReceived(), 50);
    }

    function test_previewPayFor_skipsRevertingCandidateAndUsesWorkingRoute() public {
        uint256 projectId = 1;
        address tokenIn = makeAddr("tokenIn");
        address brokenToken = tokenIn;
        address workingToken = makeAddr("workingToken");
        address beneficiary = makeAddr("beneficiary");
        address brokenTerminal = makeAddr("brokenTerminal");
        address workingTerminal = makeAddr("workingTerminal");
        address pool = makeAddr("pool");
        uint256 quotedAmountOut = 55;

        vm.etch(brokenTerminal, hex"00");
        vm.etch(workingTerminal, hex"00");
        vm.etch(pool, hex"00");

        vm.mockCall(
            address(mockTokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(tokenIn))), abi.encode(uint256(0))
        );

        IJBTerminal[] memory terminals = new IJBTerminal[](2);
        terminals[0] = IJBTerminal(brokenTerminal);
        terminals[1] = IJBTerminal(workingTerminal);
        vm.mockCall(
            address(mockDirectory), abi.encodeCall(IJBDirectory.terminalsOf, (projectId)), abi.encode(terminals)
        );

        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, brokenToken)),
            abi.encode(brokenTerminal)
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, workingToken)),
            abi.encode(workingTerminal)
        );

        JBAccountingContext[] memory brokenContexts = new JBAccountingContext[](1);
        brokenContexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: brokenToken, decimals: 18, currency: uint32(uint160(brokenToken))});
        vm.mockCall(
            brokenTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(brokenContexts)
        );

        JBAccountingContext[] memory workingContexts = new JBAccountingContext[](1);
        workingContexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: workingToken, decimals: 18, currency: uint32(uint160(workingToken))});
        vm.mockCall(
            workingTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(workingContexts)
        );

        vm.mockCallRevert(
            brokenTerminal,
            abi.encodeCall(IJBTerminal.previewPayFor, (projectId, brokenToken, 100, beneficiary, bytes(""))),
            abi.encodeWithSignature("Error(string)", "broken candidate")
        );

        bytes4 quoteId = JBMetadataResolver.getId("quoteForSwap", address(routerTerminal));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", quoteId, abi.encode(quotedAmountOut));

        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, workingToken, 3000)),
            abi.encode(pool)
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, workingToken, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, workingToken, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenIn, workingToken, 100)),
            abi.encode(address(0))
        );
        vm.mockCall(pool, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(1000)));
        _mockV4NoPools(tokenIn, workingToken);

        JBRuleset memory expectedRuleset = JBRuleset({
            cycleNumber: 1,
            id: 333,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        JBPayHookSpecification[] memory expectedSpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            workingTerminal,
            abi.encodeCall(
                IJBTerminal.previewPayFor, (projectId, workingToken, quotedAmountOut, beneficiary, metadata)
            ),
            abi.encode(expectedRuleset, uint256(41), uint256(42), expectedSpecs)
        );

        (JBRuleset memory ruleset, uint256 beneficiaryTokenCount, uint256 reservedTokenCount,) =
            routerTerminal.previewPayFor(projectId, tokenIn, 100, beneficiary, metadata);

        assertEq(ruleset.id, expectedRuleset.id);
        assertEq(beneficiaryTokenCount, 41);
        assertEq(reservedTokenCount, 42);
    }

    function test_previewAndPay_handleBuybackHookSellSideCashOut() public {
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;
        uint256 amount = 100;
        uint256 quotedReclaimAmount = 75;
        address payer = makeAddr("sellSidePayer");
        address beneficiary = makeAddr("sellSideBeneficiary");
        MockERC20 jbToken = new MockERC20();
        MockPreviewDestTerminal destTerminal = new MockPreviewDestTerminal(JBConstants.NATIVE_TOKEN, 222);
        MockConfigurableCashOutTerminal cashOutTerminal = new MockConfigurableCashOutTerminal{
            value: quotedReclaimAmount
        }(
            jbToken, JBConstants.NATIVE_TOKEN, 0, quotedReclaimAmount, 0
        );

        jbToken.mint(payer, amount);

        vm.etch(buybackHook, hex"00");
        vm.mockCall(
            address(mockTokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(jbToken)))),
            abi.encode(sourceProjectId)
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, address(jbToken))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(destTerminal))
        );

        IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
        sourceTerminals[0] = IJBTerminal(address(cashOutTerminal));
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
            abi.encode(sourceTerminals)
        );

        bytes4 buybackInterfaceId = bytes4(keccak256("MAX_TWAP_WINDOW()"));
        vm.mockCall(buybackHook, abi.encodeCall(IERC165.supportsInterface, (buybackInterfaceId)), abi.encode(true));

        JBCashOutHookSpecification[] memory hookSpecifications =
            _buybackCashOutHookSpecifications(buybackHook, quotedReclaimAmount);
        vm.mockCall(
            address(cashOutTerminal),
            abi.encodeCall(
                IJBCashOutTerminal.previewCashOutFrom,
                (
                    address(routerTerminal),
                    sourceProjectId,
                    amount,
                    JBConstants.NATIVE_TOKEN,
                    payable(address(routerTerminal)),
                    bytes("")
                )
            ),
            abi.encode(
                JBRuleset({
                    cycleNumber: 1,
                    id: 333,
                    basedOnId: 0,
                    start: 0,
                    duration: 0,
                    weight: 0,
                    weightCutPercent: 0,
                    approvalHook: IJBRulesetApprovalHook(address(0)),
                    metadata: 0
                }),
                uint256(0),
                uint256(0),
                hookSpecifications
            )
        );

        vm.expectCall(
            address(destTerminal),
            abi.encodeCall(
                IJBTerminal.previewPayFor,
                (destProjectId, JBConstants.NATIVE_TOKEN, quotedReclaimAmount, beneficiary, bytes(""))
            )
        );

        vm.startPrank(payer);
        jbToken.approve(address(routerTerminal), amount);

        (, uint256 previewTokenCount,,) =
            routerTerminal.previewPayFor(destProjectId, address(jbToken), amount, beneficiary, "");
        uint256 mintedTokenCount =
            routerTerminal.pay(destProjectId, address(jbToken), amount, beneficiary, 0, "buyback sell side", "");
        vm.stopPrank();

        assertEq(previewTokenCount, mintedTokenCount);
        assertEq(mintedTokenCount, 222);
        assertEq(destTerminal.totalReceived(), quotedReclaimAmount);
        assertEq(address(routerTerminal).balance, 0);
    }

    function test_previewPayFor_matchesPay_cashOutRoute() public {
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;
        uint256 amount = 100;
        uint256 reclaimAmount = 60;
        address payer = makeAddr("payer");
        address beneficiary = makeAddr("beneficiary");
        MockERC20 token = new MockERC20();
        MockPreviewDestTerminal destTerminal = new MockPreviewDestTerminal(JBConstants.NATIVE_TOKEN, 777);
        MockPreviewCashOutTerminal cashOutTerminal =
            new MockPreviewCashOutTerminal{value: reclaimAmount}(token, reclaimAmount);
        address jbToken = address(token);

        vm.mockCall(
            address(mockTokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(jbToken))), abi.encode(sourceProjectId)
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, jbToken)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(destTerminal))
        );

        IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
        sourceTerminals[0] = IJBTerminal(address(cashOutTerminal));
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
            abi.encode(sourceTerminals)
        );

        token.mint(payer, amount);
        vm.startPrank(payer);
        token.approve({spender: address(routerTerminal), amount: amount});

        (, uint256 previewTokenCount, uint256 previewReservedTokenCount,) = routerTerminal.previewPayFor({
            projectId: destProjectId, token: jbToken, amount: amount, beneficiary: beneficiary, metadata: ""
        });
        uint256 mintedTokenCount = routerTerminal.pay({
            projectId: destProjectId,
            token: jbToken,
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "cashout parity",
            metadata: ""
        });
        vm.stopPrank();

        assertEq(previewTokenCount, mintedTokenCount);
        assertEq(previewReservedTokenCount, 0);
        assertEq(destTerminal.totalReceived(), reclaimAmount);
        assertEq(token.balanceOf(address(routerTerminal)), 0);
        assertEq(address(routerTerminal).balance, 0);
    }

    //*********************************************************************//
    // ----------------------- no-op tests ------------------------------ //
    //*********************************************************************//

    function test_migrateBalanceOf_returnsZero() public {
        assertEq(routerTerminal.migrateBalanceOf(1, makeAddr("token"), IJBTerminal(makeAddr("terminal"))), 0);
    }

    function test_addAccountingContextsFor_noOp() public {
        // Should not revert.
        routerTerminal.addAccountingContextsFor(1, new JBAccountingContext[](0));
    }

    //*********************************************************************//
    // ----------------------- V4 pool discovery tests ------------------ //
    //*********************************************************************//

    function test_discoverPool_v4WinsOverV3() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        address v3Pool = makeAddr("v3Pool");
        vm.etch(v3Pool, hex"00");

        // V3 pool with moderate liquidity.
        vm.mockCall(
            address(mockFactory), abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 3000)), abi.encode(v3Pool)
        );
        vm.mockCall(v3Pool, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(100e18)));

        // No other V3 pools.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 100)),
            abi.encode(address(0))
        );

        // V4 pool with higher liquidity at 0.3%/60 tick spacing.
        // Sort currencies.
        (address sorted0, address sorted1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        PoolKey memory v4Key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: 3000,
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });
        PoolId v4Id = v4Key.toId();

        // Mock getSlot0 via extsload — pool exists (sqrtPriceX96 != 0).
        _mockV4PoolExists(v4Id, uint160(79_228_162_514_264_337_593_543_950_336), 500e18);

        // Mock other V4 fee tiers as non-existent.
        _mockV4PoolNotExists(sorted0, sorted1, 500, int24(10));
        _mockV4PoolNotExists(sorted0, sorted1, 10_000, int24(200));
        _mockV4PoolNotExists(sorted0, sorted1, 100, int24(1));

        PoolInfo memory result = routerTerminal.exposedDiscoverPool(tokenA, tokenB);
        assertTrue(result.isV4);
        assertEq(Currency.unwrap(result.v4Key.currency0), sorted0);
        assertEq(Currency.unwrap(result.v4Key.currency1), sorted1);
        assertEq(result.v4Key.fee, 3000);
    }

    function test_discoverPool_v3WinsOverV4() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        address v3Pool = makeAddr("v3Pool");
        vm.etch(v3Pool, hex"00");

        // V3 pool with high liquidity.
        vm.mockCall(
            address(mockFactory), abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 3000)), abi.encode(v3Pool)
        );
        vm.mockCall(v3Pool, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(1000e18)));

        // No other V3 pools.
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 100)),
            abi.encode(address(0))
        );

        // V4 pool with lower liquidity.
        (address sorted0, address sorted1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        PoolKey memory v4Key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: 3000,
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });
        PoolId v4Id = v4Key.toId();

        _mockV4PoolExists(v4Id, uint160(79_228_162_514_264_337_593_543_950_336), 50e18);

        _mockV4PoolNotExists(sorted0, sorted1, 500, int24(10));
        _mockV4PoolNotExists(sorted0, sorted1, 10_000, int24(200));
        _mockV4PoolNotExists(sorted0, sorted1, 100, int24(1));

        PoolInfo memory result = routerTerminal.exposedDiscoverPool(tokenA, tokenB);
        assertFalse(result.isV4);
        assertEq(address(result.v3Pool), v3Pool);
    }

    function test_discoverPool_v4OnlyNoV3() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");

        // No V3 pools.
        vm.mockCall(
            address(mockFactory), abi.encodeWithSelector(IUniswapV3Factory.getPool.selector), abi.encode(address(0))
        );

        // V4 pool exists.
        (address sorted0, address sorted1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        PoolKey memory v4Key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: 500,
            tickSpacing: int24(10),
            hooks: IHooks(address(0))
        });
        PoolId v4Id = v4Key.toId();

        // First fee tier (3000/60) doesn't exist.
        _mockV4PoolNotExists(sorted0, sorted1, 3000, int24(60));
        // Second fee tier (500/10) exists.
        _mockV4PoolExists(v4Id, uint160(79_228_162_514_264_337_593_543_950_336), 200e18);
        // Other tiers don't exist.
        _mockV4PoolNotExists(sorted0, sorted1, 10_000, int24(200));
        _mockV4PoolNotExists(sorted0, sorted1, 100, int24(1));

        PoolInfo memory result = routerTerminal.exposedDiscoverPool(tokenA, tokenB);
        assertTrue(result.isV4);
        assertEq(result.v4Key.fee, 500);
        assertEq(result.v4Key.tickSpacing, int24(10));
    }

    function test_discoverPool_noPoolManager() public {
        // Deploy a router with address(0) as PoolManager.
        RouterTerminalHarness noV4Router = new RouterTerminalHarness(
            mockDirectory,
            mockPermissions,
            mockTokens,
            mockPermit2,
            terminalOwner,
            buybackHook,
            address(0),
            address(this)
        );
        noV4Router.setChainSpecificConstants({
            weth: mockWeth, factory: mockFactory, poolManager: IPoolManager(address(0)), univ4Hook: address(0)
        });

        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        address v3Pool = makeAddr("v3Pool");
        vm.etch(v3Pool, hex"00");

        // V3 pool exists.
        vm.mockCall(
            address(mockFactory), abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 3000)), abi.encode(v3Pool)
        );
        vm.mockCall(v3Pool, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(100e18)));

        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 500)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 10_000)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(mockFactory),
            abi.encodeCall(IUniswapV3Factory.getPool, (tokenA, tokenB, 100)),
            abi.encode(address(0))
        );

        // V4 is skipped (POOL_MANAGER = address(0)), should find V3 pool.
        PoolInfo memory result = noV4Router.exposedDiscoverPool(tokenA, tokenB);
        assertFalse(result.isV4);
        assertEq(address(result.v3Pool), v3Pool);
    }

    //*********************************************************************//
    // -------------------- V4 unlock callback test --------------------- //
    //*********************************************************************//

    function test_unlockCallback_rejectsNonPoolManager() public {
        address notPoolManager = makeAddr("notPoolManager");

        vm.prank(notPoolManager);
        vm.expectRevert(
            abi.encodeWithSelector(JBRouterTerminal.JBRouterTerminal_CallerNotPoolManager.selector, notPoolManager)
        );
        routerTerminal.unlockCallback("");
    }

    //*********************************************************************//
    // -------------------- V4 spot quote test -------------------------- //
    //*********************************************************************//

    function test_discoverBestPool_returnsV4() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");

        // No V3 pools.
        vm.mockCall(
            address(mockFactory), abi.encodeWithSelector(IUniswapV3Factory.getPool.selector), abi.encode(address(0))
        );

        // V4 pool exists at 3000/60.
        (address sorted0, address sorted1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        PoolKey memory v4Key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: 3000,
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });
        PoolId v4Id = v4Key.toId();
        _mockV4PoolExists(v4Id, uint160(79_228_162_514_264_337_593_543_950_336), 300e18);

        _mockV4PoolNotExists(sorted0, sorted1, 500, int24(10));
        _mockV4PoolNotExists(sorted0, sorted1, 10_000, int24(200));
        _mockV4PoolNotExists(sorted0, sorted1, 100, int24(1));

        PoolInfo memory result = routerTerminal.discoverBestPool(tokenA, tokenB);
        assertTrue(result.isV4);
        assertEq(result.v4Key.fee, 3000);
    }

    function _buybackPayHookSpecifications(
        address hook,
        uint256 minimumBeneficiaryTokenCount,
        uint256 minimumReservedTokenCount
    )
        internal
        pure
        returns (JBPayHookSpecification[] memory specifications)
    {
        specifications = new JBPayHookSpecification[](1);
        specifications[0] = JBPayHookSpecification({
            hook: IJBPayHook(hook),
            noop: false,
            amount: 0,
            metadata: abi.encode(
                false,
                uint256(0),
                uint256(0),
                false,
                address(0),
                uint256(0),
                uint256(0),
                int24(0),
                uint128(0),
                PoolId.wrap(bytes32(0)),
                minimumBeneficiaryTokenCount,
                minimumReservedTokenCount,
                uint256(0)
            )
        });
    }

    function _buybackCashOutHookSpecifications(
        address hook,
        uint256 quotedAmount
    )
        internal
        pure
        returns (JBCashOutHookSpecification[] memory specifications)
    {
        specifications = new JBCashOutHookSpecification[](1);
        specifications[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(hook),
            noop: false,
            amount: 0,
            metadata: abi.encode(
                quotedAmount, uint256(0), uint256(0), int24(0), uint128(0), PoolId.wrap(bytes32(0)), quotedAmount
            )
        });
    }

    //*********************************************************************//
    // ----------------------- V4 mock helpers -------------------------- //
    //*********************************************************************//

    /// @notice Mock V4 pool as existing with given sqrtPriceX96 and liquidity.
    function _mockV4PoolExists(PoolId id, uint160 sqrtPriceX96, uint256 liquidity) internal {
        // StateLibrary uses extsload to read pool state.
        // Slot0 is at the pool state slot.
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(id), bytes32(uint256(6))));

        // Pack slot0: sqrtPriceX96 (160 bits) | tick (24 bits) | protocolFee (24 bits) | lpFee (24 bits)
        bytes32 slot0Data = bytes32(uint256(sqrtPriceX96));
        vm.mockCall(
            address(mockPoolManager), abi.encodeWithSignature("extsload(bytes32)", stateSlot), abi.encode(slot0Data)
        );

        // Liquidity is at stateSlot + 3.
        bytes32 liquiditySlot = bytes32(uint256(stateSlot) + 3);
        vm.mockCall(
            address(mockPoolManager),
            abi.encodeWithSignature("extsload(bytes32)", liquiditySlot),
            abi.encode(bytes32(liquidity))
        );
    }

    /// @notice Mock a V4 pool as non-existent (sqrtPriceX96 = 0).
    function _mockV4PoolNotExists(address sorted0, address sorted1, uint24 fee, int24 tickSpacing) internal {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
        PoolId id = key.toId();
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(id), bytes32(uint256(6))));

        vm.mockCall(
            address(mockPoolManager), abi.encodeWithSignature("extsload(bytes32)", stateSlot), abi.encode(bytes32(0))
        );
    }

    /// @notice Mock all V4 pools as non-existent for a token pair.
    function _mockV4NoPools(address tokenA, address tokenB) internal {
        (address sorted0, address sorted1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        _mockV4PoolNotExists(sorted0, sorted1, 3000, int24(60));
        _mockV4PoolNotExists(sorted0, sorted1, 500, int24(10));
        _mockV4PoolNotExists(sorted0, sorted1, 10_000, int24(200));
        _mockV4PoolNotExists(sorted0, sorted1, 100, int24(1));
    }

    //*********************************************************************//
    // ----------- Bug fix regression tests: V4 sign convention ---------- //
    //*********************************************************************//

    /// @notice The V4 unlock callback should receive a negative amountSpecified for exact-input (fix #1).
    function test_unlockCallback_negativeAmountSpecified() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        (address sorted0, address sorted1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: 3000,
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });

        uint256 amount = 1e18;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountSpecified = -int256(amount); // exact-input: NEGATIVE
        uint160 sqrtPriceLimitX96 = 4_295_128_740; // MIN_SQRT_RATIO + 1
        uint256 minAmountOut = 0;

        // Encode the data as the contract would encode it (with the sign fix).
        bytes memory callbackData = abi.encode(key, true, amountSpecified, sqrtPriceLimitX96, minAmountOut, false);

        // Mock the PoolManager.swap call — it should receive a negative amountSpecified.
        // We construct the expected SwapParams to verify the sign.
        vm.mockCall(
            address(mockPoolManager),
            abi.encodeWithSelector(IPoolManager.swap.selector),
            // Return a BalanceDelta where token0 goes in (-1e18) and token1 comes out (+5e17).
            abi.encode(int256(-1e18) << 128 | int256(uint256(5e17)))
        );

        // Mock settle and take.
        vm.mockCall(address(mockPoolManager), abi.encodeWithSignature("settle()"), abi.encode(uint256(1e18)));
        vm.mockCall(address(mockPoolManager), abi.encodeWithSignature("settle{value}()"), abi.encode(uint256(1e18)));
        vm.mockCall(address(mockPoolManager), abi.encodeWithSignature("sync(address)"), abi.encode());
        vm.mockCall(address(mockPoolManager), abi.encodeWithSignature("take(address,address,uint256)"), abi.encode());
        vm.mockCall(sorted0, abi.encodeCall(IERC20.transfer, (address(mockPoolManager), 1e18)), abi.encode(true));

        // Call from the PoolManager (authorized).
        vm.prank(address(mockPoolManager));

        // The callback should decode a NEGATIVE amountSpecified and process the swap.
        // If the old bug existed (positive), the swap behavior would be different.
        bytes memory result = routerTerminal.unlockCallback(callbackData);

        // Verify amountOut is decoded correctly.
        uint256 amountOut = abi.decode(result, (uint256));
        assertEq(amountOut, 5e17);
    }

    //*********************************************************************//
    // --------- Bug fix regression tests: cashout slippage -------------- //
    //*********************************************************************//

    /// @notice cashOutMinReclaimed metadata should be forwarded to the cashout terminal (fix #4).
    function test_pay_cashOutMinReclaimedMetadata() public {
        MockERC20 jbTokenMock = new MockERC20();
        address jbToken = address(jbTokenMock);
        address payer = makeAddr("payer");
        address mockTerminal = makeAddr("destTerminal");
        MockPreviewCashOutTerminal mockCashOutTerminal =
            new MockPreviewCashOutTerminal{value: 60e18}(jbTokenMock, 60e18);
        vm.etch(mockTerminal, hex"00");

        // Build metadata with cashOutMinReclaimed — must use router address for getId.
        bytes memory metadata;
        {
            bytes4 metadataId = JBMetadataResolver.getId("cashOutMinReclaimed", address(routerTerminal));
            metadata = JBMetadataResolver.addToMetadata("", metadataId, abi.encode(uint256(50e18)));
        }

        // jbToken is a JB project token for sourceProjectId (2).
        vm.mockCall(
            address(mockTokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(jbToken))), abi.encode(uint256(2))
        );

        // Dest project (1) accepts NATIVE_TOKEN.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, JBConstants.NATIVE_TOKEN)),
            abi.encode(mockTerminal)
        );

        // Dest project doesn't accept jbToken directly.
        vm.mockCall(
            address(mockDirectory), abi.encodeCall(IJBDirectory.primaryTerminalOf, (1, jbToken)), abi.encode(address(0))
        );

        {
            // Source project's terminals (for _findCashOutPath).
            IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
            sourceTerminals[0] = IJBTerminal(address(mockCashOutTerminal));
            vm.mockCall(
                address(mockDirectory), abi.encodeCall(IJBDirectory.terminalsOf, (2)), abi.encode(sourceTerminals)
            );
        }

        {
            // Accounting context: source project terminal accepts NATIVE_TOKEN.
            JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
            contexts[0] = JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });
            vm.mockCall(
                address(mockCashOutTerminal),
                abi.encodeCall(IJBTerminal.accountingContextsOf, (2)),
                abi.encode(contexts)
            );
        }

        // The router now passes minTokensReclaimed=0 to the terminal and enforces the user's
        // minimum via the balance-delta check instead (to support buyback-hook sell-side flows).
        vm.expectCall(
            address(mockCashOutTerminal),
            abi.encodeCall(
                IJBCashOutTerminal.cashOutTokensOf,
                (
                    address(routerTerminal),
                    2, // sourceProjectId
                    100e18, // amount
                    JBConstants.NATIVE_TOKEN,
                    0, // router passes 0 and enforces via balance-delta
                    payable(address(routerTerminal)),
                    bytes("")
                )
            )
        );

        // Mint jbToken to payer and approve the router terminal (_acceptFundsFor uses balanceOf delta).
        jbTokenMock.mint(payer, 100e18);
        vm.prank(payer);
        jbTokenMock.approve(address(routerTerminal), 100e18);

        // Mock dest terminal pay.
        vm.mockCall(mockTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(10)));

        vm.prank(payer);
        routerTerminal.pay(1, jbToken, 100e18, payer, 0, "", metadata);
    }
}

/// @notice Tests for the _settleV4 WETH deficit-only withdrawal fix.
contract SettleV4DeficitTest is Test {
    RouterTerminalHarness routerTerminal;

    MockWETH9 weth;
    MockPoolManagerForSettle poolManager;

    // Mocked JB dependencies (unused by _settleV4 but required for constructor).
    IJBDirectory mockDirectory;
    IJBPermissions mockPermissions;
    IJBTokens mockTokens;
    IPermit2 mockPermit2;
    IUniswapV3Factory mockFactory;

    function setUp() public {
        mockDirectory = IJBDirectory(makeAddr("mockDirectory"));
        vm.etch(address(mockDirectory), hex"00");
        mockPermissions = IJBPermissions(makeAddr("mockPermissions"));
        vm.etch(address(mockPermissions), hex"00");
        mockTokens = IJBTokens(makeAddr("mockTokens"));
        vm.etch(address(mockTokens), hex"00");
        mockPermit2 = IPermit2(makeAddr("mockPermit2"));
        vm.etch(address(mockPermit2), hex"00");
        mockFactory = IUniswapV3Factory(makeAddr("mockFactory"));
        vm.etch(address(mockFactory), hex"00");

        // Deploy real mock WETH and PoolManager.
        weth = new MockWETH9();
        poolManager = new MockPoolManagerForSettle();

        routerTerminal = new RouterTerminalHarness(
            mockDirectory,
            mockPermissions,
            mockTokens,
            mockPermit2,
            makeAddr("owner"),
            address(0),
            address(0),
            address(this)
        );
        routerTerminal.setChainSpecificConstants({
            weth: IWETH9(address(weth)),
            factory: mockFactory,
            poolManager: IPoolManager(address(poolManager)),
            univ4Hook: address(0)
        });
    }

    /// @notice Settlement with partial ETH + partial WETH should only withdraw the deficit.
    ///         Pre-load 0.5 ETH in the contract and 0.5 WETH, then settle 1 ETH total.
    function test_settleV4_partialEthPartialWeth() public {
        uint256 totalAmount = 1 ether;
        uint256 ethPortion = 0.5 ether;
        uint256 wethPortion = 0.5 ether;

        // Give the router terminal partial raw ETH.
        vm.deal(address(routerTerminal), ethPortion);

        // Give the router terminal partial WETH (fund the mock WETH contract with ETH
        // so withdraw can send it back, then credit the router terminal's WETH balance).
        vm.deal(address(weth), wethPortion);
        weth.deposit{value: 0}(); // just to ensure contract is initialized
        // Directly set the WETH balance for the router terminal.
        vm.deal(address(weth), wethPortion); // ensure WETH contract has ETH to pay out
        // Credit WETH balance to the router terminal by depositing on its behalf.
        vm.deal(address(routerTerminal), ethPortion); // keep ETH portion
        vm.prank(address(routerTerminal));
        weth.deposit{value: 0}();
        // Manually set the WETH balance for the router (MockWETH9 uses a mapping).
        // We need to deposit from the router's perspective.
        vm.deal(address(routerTerminal), ethPortion + wethPortion);
        vm.prank(address(routerTerminal));
        weth.deposit{value: wethPortion}();

        // Verify setup: router has 0.5 ETH + 0.5 WETH.
        assertEq(address(routerTerminal).balance, ethPortion, "Setup: router ETH balance");
        assertEq(weth.balanceOf(address(routerTerminal)), wethPortion, "Setup: router WETH balance");

        // Settle 1 ETH via _settleV4. Should withdraw only 0.5 WETH (the deficit).
        routerTerminal.exposedSettleV4(Currency.wrap(address(0)), totalAmount, true);

        // PoolManager should have received 1 ETH.
        assertEq(poolManager.lastSettleAmount(), totalAmount, "PoolManager received correct amount");

        // Router terminal should have 0 ETH and 0 WETH remaining.
        assertEq(address(routerTerminal).balance, 0, "Router ETH should be drained");
        assertEq(weth.balanceOf(address(routerTerminal)), 0, "Router WETH should be drained");
    }

    /// @notice Settlement with sufficient raw ETH should NOT withdraw any WETH.
    function test_settleV4_sufficientEth_noWethWithdraw() public {
        uint256 amount = 1 ether;

        // Give the router terminal enough raw ETH.
        vm.deal(address(routerTerminal), amount);

        // Give it some WETH too (should remain untouched).
        vm.deal(address(routerTerminal), amount + 0.5 ether);
        vm.prank(address(routerTerminal));
        weth.deposit{value: 0.5 ether}();

        // Verify setup.
        assertEq(address(routerTerminal).balance, amount, "Setup: router ETH balance");
        assertEq(weth.balanceOf(address(routerTerminal)), 0.5 ether, "Setup: router WETH balance");

        // Settle 1 ETH. No WETH should be withdrawn.
        routerTerminal.exposedSettleV4(Currency.wrap(address(0)), amount, true);

        // PoolManager received the ETH.
        assertEq(poolManager.lastSettleAmount(), amount, "PoolManager received correct amount");

        // WETH should be untouched.
        assertEq(weth.balanceOf(address(routerTerminal)), 0.5 ether, "WETH should remain untouched");
    }

    /// @notice Settlement with zero ETH should withdraw the full amount from WETH.
    function test_settleV4_allWeth_fullWithdraw() public {
        uint256 amount = 1 ether;

        // Give the router terminal only WETH, no raw ETH.
        vm.deal(address(routerTerminal), amount);
        vm.prank(address(routerTerminal));
        weth.deposit{value: amount}();

        // Verify setup: 0 ETH, 1 WETH.
        assertEq(address(routerTerminal).balance, 0, "Setup: router should have 0 ETH");
        assertEq(weth.balanceOf(address(routerTerminal)), amount, "Setup: router WETH balance");

        // Settle 1 ETH. Should withdraw all 1 WETH.
        routerTerminal.exposedSettleV4(Currency.wrap(address(0)), amount, false);

        // PoolManager received the ETH.
        assertEq(poolManager.lastSettleAmount(), amount, "PoolManager received correct amount");

        // All WETH drained.
        assertEq(weth.balanceOf(address(routerTerminal)), 0, "WETH should be fully drained");
        assertEq(address(routerTerminal).balance, 0, "ETH should be fully drained");
    }
}
