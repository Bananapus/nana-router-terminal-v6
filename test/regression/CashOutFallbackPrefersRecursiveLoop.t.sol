// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

contract FallbackMockToken {
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

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }
}

contract FallbackMockWETH is IWETH9 {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

    function deposit() external payable override {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    function withdraw(uint256 amount) external override {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {}
}

contract FallbackCashOutTerminal {
    FallbackMockToken public immutable TOKEN_TO_BURN;
    address[] internal _tokens;
    uint256 public immutable RECLAIM_AMOUNT;

    constructor(FallbackMockToken tokenToBurn, address[] memory tokens, uint256 reclaimAmount) payable {
        TOKEN_TO_BURN = tokenToBurn;
        _tokens = tokens;
        RECLAIM_AMOUNT = reclaimAmount;
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
        TOKEN_TO_BURN.burn(holder, cashOutCount);
        if (tokenToReclaim == JBConstants.NATIVE_TOKEN) {
            (bool ok,) = beneficiary.call{value: RECLAIM_AMOUNT}("");
            require(ok, "eth send failed");
        } else {
            require(FallbackMockToken(tokenToReclaim).transfer(beneficiary, RECLAIM_AMOUNT), "transfer failed");
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
            id: 1,
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

    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](_tokens.length);
        for (uint256 i; i < _tokens.length; i++) {
            contexts[i] = JBAccountingContext({token: _tokens[i], decimals: 18, currency: uint32(uint160(_tokens[i]))});
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBCashOutTerminal).interfaceId || interfaceId == type(IJBTerminal).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    receive() external payable {}
}

contract FallbackRevertingCashOutTerminal {
    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory) {
        revert("BROKEN_CONTEXTS");
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBCashOutTerminal).interfaceId || interfaceId == type(IJBTerminal).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

contract FallbackDestinationTerminal {
    uint256 public totalReceived;

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
        require(IWETH9(payable(token)).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        totalReceived += amount;
        return amount;
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
        return (ruleset, amount, 0, hookSpecifications);
    }

    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: address(0), decimals: 18, currency: 0});
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

contract CashOutFallbackPrefersRecursiveLoopTest is Test {
    uint256 internal constant DEST_PROJECT_ID = 1;
    uint256 internal constant SOURCE_PROJECT_ID = 2;
    uint256 internal constant LOOP_PROJECT_ID = 3;
    uint256 internal constant AMOUNT = 100e18;
    uint256 internal constant RECLAIM = 10 ether;

    JBRouterTerminal internal router;
    IJBDirectory internal directory;
    IJBTokens internal tokens;
    FallbackMockWETH internal weth;
    FallbackMockToken internal sourceToken;
    FallbackMockToken internal loopToken;
    FallbackCashOutTerminal internal sourceTerminal;
    FallbackCashOutTerminal internal nativeOnlySourceTerminal;
    FallbackCashOutTerminal internal loopTerminal;
    FallbackRevertingCashOutTerminal internal revertingSourceTerminal;
    FallbackDestinationTerminal internal destinationTerminal;

    address internal payer = makeAddr("payer");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        tokens = IJBTokens(makeAddr("tokens"));

        vm.etch(address(directory), hex"00");
        vm.etch(address(tokens), hex"00");
        vm.mockCall(address(tokens), abi.encodeWithSelector(IJBTokens.creditBalanceOf.selector), abi.encode(0));
        vm.etch(address(makeAddr("permit2")), hex"00");
        vm.etch(address(makeAddr("factory")), hex"00");

        weth = new FallbackMockWETH();
        router = new JBRouterTerminal({
            directory: directory,
            tokens: tokens,
            permit2: IPermit2(makeAddr("permit2")),
            buybackHook: address(0),
            trustedForwarder: address(0),
            deployer: address(this)
        });
        router.setChainSpecificConstants({
            newWrappedNativeToken: weth,
            newFactory: IUniswapV3Factory(makeAddr("factory")),
            newPoolManager: IPoolManager(address(0)),
            newUniv4Hook: address(0)
        });

        sourceToken = new FallbackMockToken();
        loopToken = new FallbackMockToken();
        destinationTerminal = new FallbackDestinationTerminal();

        address[] memory sourceContexts = new address[](2);
        sourceContexts[0] = address(loopToken);
        sourceContexts[1] = JBConstants.NATIVE_TOKEN;
        sourceTerminal = new FallbackCashOutTerminal{value: RECLAIM}(sourceToken, sourceContexts, RECLAIM);
        revertingSourceTerminal = new FallbackRevertingCashOutTerminal();

        address[] memory nativeOnlyContexts = new address[](1);
        nativeOnlyContexts[0] = JBConstants.NATIVE_TOKEN;
        nativeOnlySourceTerminal = new FallbackCashOutTerminal{value: RECLAIM}(sourceToken, nativeOnlyContexts, RECLAIM);

        address[] memory loopContexts = new address[](1);
        loopContexts[0] = address(loopToken);
        loopTerminal = new FallbackCashOutTerminal(loopToken, loopContexts, RECLAIM);

        loopToken.mint(address(sourceTerminal), RECLAIM * 40);
        loopToken.mint(address(loopTerminal), RECLAIM * 40);

        sourceToken.mint(payer, AMOUNT);
        vm.prank(payer);
        sourceToken.approve(address(router), AMOUNT);

        vm.mockCall(
            address(tokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(sourceToken)))),
            abi.encode(SOURCE_PROJECT_ID)
        );
    }

    function _mockRouteState(
        bool loopTokenIsJbToken,
        bool useMixedSourceContexts,
        bool includeRevertingSourceTerminal
    )
        internal
    {
        vm.mockCall(
            address(tokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(loopToken)))),
            abi.encode(loopTokenIsJbToken ? LOOP_PROJECT_ID : uint256(0))
        );

        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(sourceToken))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(loopToken))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(weth))),
            abi.encode(address(destinationTerminal))
        );

        IJBTerminal[] memory sourceTerminals = new IJBTerminal[](includeRevertingSourceTerminal ? 2 : 1);
        uint256 sourceTerminalIndex;
        if (includeRevertingSourceTerminal) {
            sourceTerminals[0] = IJBTerminal(address(revertingSourceTerminal));
            sourceTerminalIndex = 1;
        }
        sourceTerminals[sourceTerminalIndex] =
            IJBTerminal(address(useMixedSourceContexts ? sourceTerminal : nativeOnlySourceTerminal));
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.terminalsOf, (SOURCE_PROJECT_ID)),
            abi.encode(sourceTerminals)
        );

        IJBTerminal[] memory loopTerminals = new IJBTerminal[](1);
        loopTerminals[0] = IJBTerminal(address(loopTerminal));
        vm.mockCall(
            address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (LOOP_PROJECT_ID)), abi.encode(loopTerminals)
        );
    }

    function test_routePrefersUsableBaseExitOverRecursiveLoop() public {
        _mockRouteState({loopTokenIsJbToken: true, useMixedSourceContexts: true, includeRevertingSourceTerminal: false});

        vm.prank(payer);
        uint256 minted = router.pay(DEST_PROJECT_ID, address(sourceToken), AMOUNT, beneficiary, 0, "", "");

        assertEq(minted, RECLAIM, "native fallback should beat the looping recursive fallback");
        assertEq(destinationTerminal.totalReceived(), RECLAIM, "destination should receive the usable base-token exit");
    }

    function test_routeSucceedsOnceRecursiveFallbackIsRemoved() public {
        _mockRouteState({
            loopTokenIsJbToken: false, useMixedSourceContexts: false, includeRevertingSourceTerminal: false
        });

        vm.prank(payer);
        uint256 minted = router.pay(DEST_PROJECT_ID, address(sourceToken), AMOUNT, beneficiary, 0, "", "");

        assertEq(minted, RECLAIM, "native fallback should wrap into WETH and pay the destination");
        assertEq(destinationTerminal.totalReceived(), RECLAIM, "destination should receive the base-token fallback");
    }

    function test_routeSkipsRevertingCashOutTerminal() public {
        _mockRouteState({
            loopTokenIsJbToken: false, useMixedSourceContexts: false, includeRevertingSourceTerminal: true
        });

        vm.prank(payer);
        uint256 minted = router.pay(DEST_PROJECT_ID, address(sourceToken), AMOUNT, beneficiary, 0, "", "");

        assertEq(minted, RECLAIM, "native fallback should wrap into WETH and pay the destination");
        assertEq(destinationTerminal.totalReceived(), RECLAIM, "destination should receive the base-token fallback");
    }
}
