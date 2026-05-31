// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

contract RegressionMockERC20 {
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

contract RegressionMockPreviewDestTerminal {
    address public immutable ACCEPTED_TOKEN;
    uint256 public immutable PAY_RESULT;
    uint256 public totalReceived;

    constructor(address acceptedToken, uint256 payResult) {
        ACCEPTED_TOKEN = acceptedToken;
        PAY_RESULT = payResult;
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
        if (token == JBConstants.NATIVE_TOKEN) require(msg.value == amount, "eth mismatch");
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        else IERC20(token).transferFrom(msg.sender, address(this), amount);

        totalReceived += amount;
        return PAY_RESULT;
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
        return (ruleset, PAY_RESULT, 0, hookSpecifications);
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

    receive() external payable {}
}

contract RegressionMockCashOutTerminal {
    RegressionMockERC20 public immutable TOKEN;
    address public immutable RECLAIM_TOKEN;
    uint256 public immutable PREVIEW_RECLAIM_AMOUNT;
    uint256 public immutable EXECUTION_TRANSFER_AMOUNT;

    constructor(
        RegressionMockERC20 token,
        address reclaimToken,
        uint256 previewReclaimAmount,
        uint256 executionTransferAmount
    )
        payable {
        TOKEN = token;
        RECLAIM_TOKEN = reclaimToken;
        PREVIEW_RECLAIM_AMOUNT = previewReclaimAmount;
        EXECUTION_TRANSFER_AMOUNT = executionTransferAmount;
    }

    function cashOutTokensOf(
        address holder,
        uint256,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256,
        address payable beneficiary,
        bytes calldata,
        uint256 /* referralProjectId */
    )
        external
        returns (uint256)
    {
        require(tokenToReclaim == RECLAIM_TOKEN, "wrong reclaim token");
        TOKEN.burn(holder, cashOutCount);

        if (tokenToReclaim == JBConstants.NATIVE_TOKEN) {
            (bool ok,) = beneficiary.call{value: EXECUTION_TRANSFER_AMOUNT}("");
            require(ok, "eth send failed");
        } else {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(tokenToReclaim).transfer(beneficiary, EXECUTION_TRANSFER_AMOUNT);
        }

        return EXECUTION_TRANSFER_AMOUNT;
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
            id: 2,
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

contract DeployBuybackHookZeroTest is Test {
    uint256 internal constant DEST_PROJECT_ID = 1;
    uint256 internal constant SOURCE_PROJECT_ID = 2;
    uint256 internal constant AMOUNT = 100;

    IJBDirectory internal directory;
    IJBTokens internal tokens;
    IPermit2 internal permit2;
    IWETH9 internal weth;
    IUniswapV3Factory internal factory;
    IPoolManager internal poolManager;

    JBRouterTerminal internal configuredRouter;
    JBRouterTerminal internal zeroHookRouter;

    RegressionMockERC20 internal jbToken;
    RegressionMockERC20 internal reclaimToken;
    RegressionMockPreviewDestTerminal internal nativeTerminal;
    RegressionMockPreviewDestTerminal internal tokenBTerminal;
    RegressionMockCashOutTerminal internal nativeCashOut;
    RegressionMockCashOutTerminal internal tokenBCashOut;

    address internal buybackHook = makeAddr("buybackHook");
    address internal payer = makeAddr("payer");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        directory = IJBDirectory(makeAddr("directory"));
        tokens = IJBTokens(makeAddr("tokens"));
        permit2 = IPermit2(makeAddr("permit2"));
        weth = IWETH9(makeAddr("weth"));
        factory = IUniswapV3Factory(makeAddr("factory"));
        poolManager = IPoolManager(makeAddr("poolManager"));

        vm.etch(address(directory), hex"00");
        vm.etch(address(tokens), hex"00");
        vm.mockCall(address(tokens), abi.encodeWithSelector(IJBTokens.creditBalanceOf.selector), abi.encode(0));
        vm.etch(address(permit2), hex"00");
        vm.etch(address(weth), hex"00");
        vm.etch(address(factory), hex"00");
        vm.etch(address(poolManager), hex"00");
        vm.etch(buybackHook, hex"00");

        configuredRouter = new JBRouterTerminal({
            directory: directory,
            tokens: tokens,
            permit2: permit2,
            buybackHook: buybackHook,
            trustedForwarder: address(0),
            deployer: address(this)
        });
        configuredRouter.setChainSpecificConstants({
            newWrappedNativeToken: weth, newFactory: factory, newPoolManager: poolManager, newUniv4Hook: address(0)
        });

        zeroHookRouter = new JBRouterTerminal({
            directory: directory,
            tokens: tokens,
            permit2: permit2,
            buybackHook: address(0),
            trustedForwarder: address(0),
            deployer: address(this)
        });
        zeroHookRouter.setChainSpecificConstants({
            newWrappedNativeToken: weth, newFactory: factory, newPoolManager: poolManager, newUniv4Hook: address(0)
        });

        jbToken = new RegressionMockERC20();
        reclaimToken = new RegressionMockERC20();
        nativeTerminal = new RegressionMockPreviewDestTerminal(JBConstants.NATIVE_TOKEN, 100);
        tokenBTerminal = new RegressionMockPreviewDestTerminal(address(reclaimToken), 150);
        vm.deal(address(this), 80);
        nativeCashOut = new RegressionMockCashOutTerminal{value: 80}(jbToken, JBConstants.NATIVE_TOKEN, 40, 40);
        tokenBCashOut = new RegressionMockCashOutTerminal(jbToken, address(reclaimToken), 50, 50);

        reclaimToken.mint(address(tokenBCashOut), 50);
        jbToken.mint(payer, AMOUNT * 2);

        vm.mockCall(
            address(tokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(jbToken)))),
            abi.encode(SOURCE_PROJECT_ID)
        );
        vm.mockCall(
            address(tokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(reclaimToken)))),
            abi.encode(uint256(0))
        );

        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(nativeTerminal))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(reclaimToken))),
            abi.encode(address(tokenBTerminal))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(jbToken))),
            abi.encode(address(0))
        );

        IJBTerminal[] memory sourceTerminals = new IJBTerminal[](2);
        sourceTerminals[0] = IJBTerminal(address(nativeCashOut));
        sourceTerminals[1] = IJBTerminal(address(tokenBCashOut));
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.terminalsOf, (SOURCE_PROJECT_ID)),
            abi.encode(sourceTerminals)
        );

        IJBTerminal[] memory destTerminals = new IJBTerminal[](2);
        destTerminals[0] = IJBTerminal(address(nativeTerminal));
        destTerminals[1] = IJBTerminal(address(tokenBTerminal));
        vm.mockCall(
            address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (DEST_PROJECT_ID)), abi.encode(destTerminals)
        );

        JBPayHookSpecification[] memory buybackSpecs = _buybackPayHookSpecifications(buybackHook, 150, 5);

        vm.mockCall(
            address(tokenBTerminal),
            abi.encodeCall(
                IJBTerminal.previewPayFor, (DEST_PROJECT_ID, address(reclaimToken), 50, beneficiary, bytes(""))
            ),
            abi.encode(_ruleset(), uint256(0), uint256(0), buybackSpecs)
        );
    }

    function test_deployScriptZeroBuybackHookForcesWorseRoute() public {
        vm.startPrank(payer);
        jbToken.approve(address(configuredRouter), AMOUNT);
        jbToken.approve(address(zeroHookRouter), AMOUNT);

        (, uint256 configuredPreview,,) =
            configuredRouter.previewPayFor(DEST_PROJECT_ID, address(jbToken), AMOUNT, beneficiary, "");
        (, uint256 zeroHookPreview,,) =
            zeroHookRouter.previewPayFor(DEST_PROJECT_ID, address(jbToken), AMOUNT, beneficiary, "");

        uint256 configuredMinted =
            configuredRouter.pay(DEST_PROJECT_ID, address(jbToken), AMOUNT, beneficiary, 0, "configured", "");
        uint256 zeroHookMinted =
            zeroHookRouter.pay(DEST_PROJECT_ID, address(jbToken), AMOUNT, beneficiary, 0, "zero-hook", "");
        vm.stopPrank();

        assertEq(configuredPreview, 150, "configured router should surface buyback-improved preview");
        assertEq(configuredMinted, 150, "configured router should route through the buyback-improved path");

        assertEq(zeroHookPreview, 100, "zero-hook deployment should ignore buyback hook metadata");
        assertEq(zeroHookMinted, 100, "zero-hook deployment should settle through the inferior route");

        assertEq(tokenBTerminal.totalReceived(), 50, "configured router should deliver tokenB route");
        assertEq(nativeTerminal.totalReceived(), 40, "zero-hook router should fall back to the native route");
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

    function _ruleset() internal pure returns (JBRuleset memory ruleset) {
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
    }
}
