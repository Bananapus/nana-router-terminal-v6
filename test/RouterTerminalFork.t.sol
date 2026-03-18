// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

// JB core (via TestBaseWorkflow pattern — deploy fresh within fork).
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBProjects} from "@bananapus/core-v6/src/JBProjects.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
import {JBRulesets} from "@bananapus/core-v6/src/JBRulesets.sol";
import {JBTokens} from "@bananapus/core-v6/src/JBTokens.sol";
import {JBERC20} from "@bananapus/core-v6/src/JBERC20.sol";
import {JBSplits} from "@bananapus/core-v6/src/JBSplits.sol";
import {JBPrices} from "@bananapus/core-v6/src/JBPrices.sol";
import {JBController} from "@bananapus/core-v6/src/JBController.sol";
import {JBFundAccessLimits} from "@bananapus/core-v6/src/JBFundAccessLimits.sol";
import {JBFeelessAddresses} from "@bananapus/core-v6/src/JBFeelessAddresses.sol";
import {JBTerminalStore} from "@bananapus/core-v6/src/JBTerminalStore.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";

// Uniswap.
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

// OpenZeppelin.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Router terminal.
import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

/// @notice Fork tests for JBRouterTerminal against real Uniswap V3 pools on Ethereum mainnet.
/// @dev Uses a pinned block for determinism. JB core is deployed fresh within the fork so we control project state.
contract RouterTerminalForkTest is Test {
    // ───────────────────────── Mainnet addresses
    // ──────────────────────────

    // Post-V4-deployment block (V4 PoolManager deployed ~21,690,000) with good TWAP history.
    uint256 constant BLOCK_NUMBER = 21_700_000;

    IWETH9 constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IUniswapV3Factory constant V3_FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    // Well-known V3 pools (we don't create them — they exist on mainnet).
    // WETH/USDC 0.05%: 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640
    // WETH/DAI  0.3%:  0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8

    // ───────────────────────── JB core (deployed fresh)
    // ────────────────────

    address multisig = address(0xBEEF);
    address payer = makeAddr("payer");
    address beneficiary = makeAddr("beneficiary");
    address trustedForwarder = address(0);

    JBPermissions jbPermissions;
    JBProjects jbProjects;
    JBDirectory jbDirectory;
    JBRulesets jbRulesets;
    JBTokens jbTokens;
    JBSplits jbSplits;
    JBPrices jbPrices;
    JBFundAccessLimits jbFundAccessLimits;
    JBFeelessAddresses jbFeelessAddresses;
    JBController jbController;
    JBTerminalStore jbTerminalStore;
    JBMultiTerminal jbMultiTerminal;
    JBRouterTerminal routerTerminal;

    // Project IDs.
    uint256 feeProjectId; // Project 1 (fee recipient).
    uint256 ethProjectId; // Accepts NATIVE_TOKEN (ETH).
    uint256 usdcProjectId; // Accepts USDC.
    uint256 daiProjectId; // Accepts DAI.

    // ───────────────────────── Setup
    // ──────────────────────────────────────

    function setUp() public {
        vm.createSelectFork("ethereum", BLOCK_NUMBER);

        // Deploy all JB core contracts fresh within the fork.
        _deployJbCore();

        // Deploy the router terminal with real Uniswap + real Permit2, but fresh JB core.
        routerTerminal = new JBRouterTerminal({
            directory: jbDirectory,
            permissions: jbPermissions,
            projects: jbProjects,
            tokens: jbTokens,
            permit2: PERMIT2,
            owner: multisig,
            weth: WETH,
            factory: V3_FACTORY,
            poolManager: V4_POOL_MANAGER,
            trustedForwarder: trustedForwarder
        });

        // Create test projects.
        feeProjectId = _launchProject({acceptedToken: JBConstants.NATIVE_TOKEN, decimals: 18});
        ethProjectId = _launchProject({acceptedToken: JBConstants.NATIVE_TOKEN, decimals: 18});
        usdcProjectId = _launchProject({acceptedToken: address(USDC), decimals: 6});
        daiProjectId = _launchProject({acceptedToken: address(DAI), decimals: 18});

        // Labels for trace readability.
        vm.label(address(WETH), "WETH");
        vm.label(address(USDC), "USDC");
        vm.label(address(DAI), "DAI");
        vm.label(address(routerTerminal), "RouterTerminal");
        vm.label(address(jbMultiTerminal), "JBMultiTerminal");
        vm.label(payer, "payer");
        vm.label(beneficiary, "beneficiary");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // V3 SWAP: ETH → USDC (pay project that accepts USDC with ETH)
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_payETH_projectAcceptsUSDC_small() public {
        uint256 amountIn = 0.01 ether;
        _payEthAndAssert(usdcProjectId, amountIn, address(USDC));
    }

    function test_fork_payETH_projectAcceptsUSDC_medium() public {
        uint256 amountIn = 1 ether;
        _payEthAndAssert(usdcProjectId, amountIn, address(USDC));
    }

    function test_fork_payETH_projectAcceptsUSDC_large() public {
        uint256 amountIn = 100 ether;
        _payEthAndAssert(usdcProjectId, amountIn, address(USDC));
    }

    function test_fork_payETH_projectAcceptsUSDC_veryLarge() public {
        uint256 amountIn = 1000 ether;
        _payEthAndAssert(usdcProjectId, amountIn, address(USDC));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // V3 SWAP: USDC → ETH (pay project that accepts ETH with USDC)
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_payUSDC_projectAcceptsETH_small() public {
        uint256 amountIn = 10e6; // 10 USDC
        _payErc20AndAssert(usdcProjectId, ethProjectId, address(USDC), amountIn, JBConstants.NATIVE_TOKEN);
    }

    function test_fork_payUSDC_projectAcceptsETH_large() public {
        uint256 amountIn = 1_000_000e6; // 1M USDC
        _payErc20AndAssert(usdcProjectId, ethProjectId, address(USDC), amountIn, JBConstants.NATIVE_TOKEN);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // DIRECT FORWARD (no swap needed)
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_payETH_projectAcceptsETH() public {
        uint256 amountIn = 1 ether;

        vm.deal(payer, amountIn);
        uint256 payerBalBefore = payer.balance;

        vm.prank(payer);
        uint256 tokenCount = routerTerminal.pay{value: amountIn}({
            projectId: ethProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "direct ETH forward",
            metadata: ""
        });

        // Project tokens minted.
        assertGt(tokenCount, 0, "no tokens minted for direct ETH forward");

        // Payer spent exactly amountIn.
        assertEq(payerBalBefore - payer.balance, amountIn, "payer balance mismatch");

        // Terminal received the ETH.
        uint256 terminalBal =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), ethProjectId, JBConstants.NATIVE_TOKEN);
        assertGt(terminalBal, 0, "terminal has no ETH balance");

        // Router has no leftover.
        assertEq(address(routerTerminal).balance, 0, "router has leftover ETH");
    }

    function test_fork_payUSDC_projectAcceptsUSDC() public {
        uint256 amountIn = 1000e6; // 1000 USDC

        deal(address(USDC), payer, amountIn);

        vm.startPrank(payer);
        USDC.approve(address(routerTerminal), amountIn);
        uint256 tokenCount = routerTerminal.pay({
            projectId: usdcProjectId,
            token: address(USDC),
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "direct USDC forward",
            metadata: ""
        });
        vm.stopPrank();

        assertGt(tokenCount, 0, "no tokens minted for direct USDC forward");

        // Terminal received the USDC.
        uint256 terminalBal = jbTerminalStore.balanceOf(address(jbMultiTerminal), usdcProjectId, address(USDC));
        assertGt(terminalBal, 0, "terminal has no USDC balance");

        // Router has no leftover.
        assertEq(USDC.balanceOf(address(routerTerminal)), 0, "router has leftover USDC");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // V3 SWAP: ETH → DAI
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_payETH_projectAcceptsDAI() public {
        uint256 amountIn = 1 ether;
        _payEthAndAssert(daiProjectId, amountIn, address(DAI));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // addToBalanceOf
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_addToBalance_ETHtoUSDC() public {
        uint256 amountIn = 1 ether;

        vm.deal(payer, amountIn);
        uint256 terminalBalBefore = jbTerminalStore.balanceOf(address(jbMultiTerminal), usdcProjectId, address(USDC));

        vm.prank(payer);
        routerTerminal.addToBalanceOf{value: amountIn}({
            projectId: usdcProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amountIn,
            shouldReturnHeldFees: false,
            memo: "add to balance ETH->USDC",
            metadata: ""
        });

        uint256 terminalBalAfter = jbTerminalStore.balanceOf(address(jbMultiTerminal), usdcProjectId, address(USDC));

        assertGt(terminalBalAfter, terminalBalBefore, "terminal balance did not increase");
        assertEq(address(routerTerminal).balance, 0, "router has leftover ETH");
        assertEq(USDC.balanceOf(address(routerTerminal)), 0, "router has leftover USDC");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // User-provided quote (metadata override)
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_payETH_withQuoteMetadata() public {
        uint256 amountIn = 1 ether;

        // Set a generous quote (1 USDC minimum — well below market, should succeed).
        bytes4 quoteId = JBMetadataResolver.getId("quoteForSwap", address(routerTerminal));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", quoteId, abi.encode(uint256(1e6)));

        vm.deal(payer, amountIn);

        vm.prank(payer);
        uint256 tokenCount = routerTerminal.pay{value: amountIn}({
            projectId: usdcProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "ETH->USDC with quote metadata",
            metadata: metadata
        });

        assertGt(tokenCount, 0, "no tokens minted with quote metadata");

        // Terminal received USDC.
        uint256 terminalBal = jbTerminalStore.balanceOf(address(jbMultiTerminal), usdcProjectId, address(USDC));
        assertGt(terminalBal, 0, "terminal has no USDC balance after quote metadata pay");

        // Router clean.
        assertEq(address(routerTerminal).balance, 0, "router has leftover ETH");
        assertEq(USDC.balanceOf(address(routerTerminal)), 0, "router has leftover USDC");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Slippage / revert scenarios
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_payETH_tightQuote_reverts() public {
        uint256 amountIn = 1 ether;

        // Set a quote 3x above market (~3,300 USDC/ETH → require 10,000 USDC).
        // This is tight enough to trigger SlippageExceeded but not so extreme that
        // sqrtPriceLimitFromAmounts falls back to "no limit".
        bytes4 quoteId = JBMetadataResolver.getId("quoteForSwap", address(routerTerminal));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", quoteId, abi.encode(uint256(10_000e6)));

        vm.deal(payer, amountIn);

        vm.prank(payer);
        vm.expectRevert();
        routerTerminal.pay{value: amountIn}({
            projectId: usdcProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "should revert - tight quote",
            metadata: metadata
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Pay ETH via the router terminal to a project that accepts `expectedTokenOut`. Asserts swap happened.
    function _payEthAndAssert(uint256 projectId, uint256 amountIn, address expectedTokenOut) internal {
        vm.deal(payer, amountIn);
        uint256 payerBalBefore = payer.balance;

        vm.prank(payer);
        uint256 tokenCount = routerTerminal.pay{value: amountIn}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "fork test ETH swap",
            metadata: ""
        });

        // 1. Swap produced output — tokens minted.
        assertGt(tokenCount, 0, "no tokens minted");

        // 2. Destination terminal received the output tokens (project balance increased).
        uint256 terminalBal = jbTerminalStore.balanceOf(address(jbMultiTerminal), projectId, expectedTokenOut);
        assertGt(terminalBal, 0, "terminal has no balance in expected token");

        // 3. No leftover tokens stuck in the router.
        assertEq(address(routerTerminal).balance, 0, "router has leftover ETH");
        assertEq(IERC20(address(WETH)).balanceOf(address(routerTerminal)), 0, "router has leftover WETH");
        assertEq(IERC20(expectedTokenOut).balanceOf(address(routerTerminal)), 0, "router has leftover output token");

        // 4. Payer's balance decreased by exactly the input amount.
        assertEq(payerBalBefore - payer.balance, amountIn, "payer balance mismatch");
    }

    /// @dev Pay ERC-20 via the router terminal to a project that accepts a different token.
    function _payErc20AndAssert(
        uint256, /* sourceProjectIdForDeal — unused */
        uint256 destProjectId,
        address tokenIn,
        uint256 amountIn,
        address expectedTokenOut
    )
        internal
    {
        deal(tokenIn, payer, amountIn);

        vm.startPrank(payer);
        IERC20(tokenIn).approve(address(routerTerminal), amountIn);
        uint256 tokenCount = routerTerminal.pay({
            projectId: destProjectId,
            token: tokenIn,
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "fork test ERC20 swap",
            metadata: ""
        });
        vm.stopPrank();

        // Tokens minted.
        assertGt(tokenCount, 0, "no tokens minted for ERC20 swap");

        // Terminal received expected output token.
        uint256 terminalBal = jbTerminalStore.balanceOf(address(jbMultiTerminal), destProjectId, expectedTokenOut);
        assertGt(terminalBal, 0, "terminal has no balance in expected token");

        // Router clean.
        assertEq(IERC20(tokenIn).balanceOf(address(routerTerminal)), 0, "router has leftover tokenIn");
        if (expectedTokenOut != JBConstants.NATIVE_TOKEN) {
            assertEq(IERC20(expectedTokenOut).balanceOf(address(routerTerminal)), 0, "router has leftover tokenOut");
        }
        assertEq(address(routerTerminal).balance, 0, "router has leftover ETH");
    }

    // ───────────────────────── JB Core Deployment
    // ─────────────────────────

    function _deployJbCore() internal {
        jbPermissions = new JBPermissions(trustedForwarder);
        jbProjects = new JBProjects(multisig, address(0), trustedForwarder);
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, multisig);
        JBERC20 jbErc20 = new JBERC20();
        jbTokens = new JBTokens(jbDirectory, jbErc20);
        jbRulesets = new JBRulesets(jbDirectory);
        jbPrices = new JBPrices(jbDirectory, jbPermissions, jbProjects, multisig, trustedForwarder);
        jbSplits = new JBSplits(jbDirectory);
        jbFundAccessLimits = new JBFundAccessLimits(jbDirectory);
        jbFeelessAddresses = new JBFeelessAddresses(multisig);

        jbController = new JBController(
            jbDirectory,
            jbFundAccessLimits,
            jbPermissions,
            jbPrices,
            jbProjects,
            jbRulesets,
            jbSplits,
            jbTokens,
            address(0), // omnichainRulesetOperator
            trustedForwarder
        );

        vm.prank(multisig);
        jbDirectory.setIsAllowedToSetFirstController(address(jbController), true);

        jbTerminalStore = new JBTerminalStore(jbDirectory, jbPrices, jbRulesets);

        jbMultiTerminal = new JBMultiTerminal(
            jbFeelessAddresses,
            jbPermissions,
            jbProjects,
            jbSplits,
            jbTerminalStore,
            jbTokens,
            PERMIT2,
            trustedForwarder
        );
    }

    /// @dev Launch a JB project that accepts `acceptedToken` via the multi terminal.
    function _launchProject(address acceptedToken, uint8 decimals) internal returns (uint256 projectId) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            // forge-lint: disable-next-line(unsafe-typecast)
            baseCurrency: uint32(uint160(acceptedToken)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        rulesetConfigs[0].weight = 1_000_000e18; // 1M tokens per unit of currency
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: acceptedToken, decimals: decimals, currency: uint32(uint160(acceptedToken))});

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});

        projectId = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "test-project",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }
}
