// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

// JB core (deploy fresh within fork — same pattern as RouterTerminalFork.t.sol).
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
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";

// Uniswap.
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

// OpenZeppelin.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Router terminal.
import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

/// @notice Fork test: pay project B with project A's ERC-20 token via the router terminal's cashout path.
///
/// Setup:
///   - Project A: accepts NATIVE_TOKEN (ETH), cashOutTaxRate = 0.
///   - Project B (ETH path): accepts NATIVE_TOKEN — tests the simple cashout-only path (no swap).
///   - Project B (USDC path): accepts USDC — tests the cashout + swap path.
///
/// Flow (ERC-20 cashout path):
///   1. Pay project A with ETH via the multi terminal -> mints project A tokens (as ERC-20 since token deployed).
///   2. Deploy ERC-20 for project A, claim credits as ERC-20.
///   3. User approves the router terminal for project A's ERC-20 tokens.
///   4. User calls routerTerminal.pay() with project A's ERC-20 tokens, targeting project B.
///   5. Router detects the token is a JB project token, enters _cashOutLoop.
///   6. _cashOutLoop cashes out project A's tokens -> gets ETH back.
///   7. If project B accepts ETH: done (direct forward).
///      If project B accepts USDC: router swaps ETH -> USDC via Uniswap, then pays project B.
///   8. Assert: user receives project B tokens, project B terminal has balance, router has no leftover.
contract RouterTerminalCashOutForkTest is Test {
    // ───────────────────────── Mainnet addresses
    // ──────────────────────────

    uint256 constant BLOCK_NUMBER = 21_700_000;

    IWETH9 constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IUniswapV3Factory constant V3_FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    // ───────────────────────── Actors
    // ──────────────────────────

    address multisig = address(0xBEEF);
    address payer = makeAddr("payer");
    address beneficiary = makeAddr("beneficiary");
    address trustedForwarder = address(0);

    // ───────────────────────── JB core
    // ──────────────────────────

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

    // ───────────────────────── Project IDs
    // ──────────────────────────

    uint256 feeProjectId; // Project 1 (fee recipient).
    uint256 projectAId; // Accepts ETH, cashOutTaxRate = 0.
    uint256 projectBEthId; // Accepts ETH (tests cashout-only path).
    uint256 projectBUsdcId; // Accepts USDC (tests cashout + swap path).

    // ───────────────────────── Project A's ERC-20
    // ──────────────────────────

    IJBToken projectAToken;

    // ───────────────────────── Setup
    // ──────────────────────────

    function setUp() public {
        vm.createSelectFork("ethereum", BLOCK_NUMBER);

        _deployJbCore();

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

        // Project 1 (fee project): accepts ETH.
        feeProjectId = _launchProject({acceptedToken: JBConstants.NATIVE_TOKEN, decimals: 18, cashOutTaxRate: 0});

        // Project A: accepts ETH, cashOutTaxRate = 0.
        projectAId = _launchProject({acceptedToken: JBConstants.NATIVE_TOKEN, decimals: 18, cashOutTaxRate: 0});

        // Deploy ERC-20 for project A.
        vm.prank(multisig);
        projectAToken = jbController.deployERC20For({projectId: projectAId, name: "ProjectA", symbol: "PA", salt: 0});

        // Project B (ETH): accepts ETH.
        projectBEthId = _launchProject({acceptedToken: JBConstants.NATIVE_TOKEN, decimals: 18, cashOutTaxRate: 0});

        // Project B (USDC): accepts USDC.
        projectBUsdcId = _launchProject({acceptedToken: address(USDC), decimals: 6, cashOutTaxRate: 0});

        // Labels for trace readability.
        vm.label(address(WETH), "WETH");
        vm.label(address(USDC), "USDC");
        vm.label(address(routerTerminal), "RouterTerminal");
        vm.label(address(jbMultiTerminal), "JBMultiTerminal");
        vm.label(address(projectAToken), "ProjectAToken");
        vm.label(payer, "payer");
        vm.label(beneficiary, "beneficiary");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 1: Cashout-only path — pay project B (ETH) with project A tokens
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Pay project A tokens into project B (which accepts ETH).
    /// Router cashes out A tokens -> gets ETH -> pays project B. No swap needed.
    function test_fork_cashOutPath_projectTokenToETH() public {
        uint256 payAmount = 10 ether;

        // Step 1: Pay project A with ETH -> mints project A ERC-20 tokens.
        vm.deal(payer, payAmount);
        vm.prank(payer);
        jbMultiTerminal.pay{value: payAmount}({
            projectId: projectAId,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "fund project A",
            metadata: ""
        });

        // Step 2: Verify payer has project A ERC-20 tokens.
        uint256 paTokenBalance = IERC20(address(projectAToken)).balanceOf(payer);
        assertGt(paTokenBalance, 0, "payer should have project A ERC-20 tokens");

        // Record project B's ETH balance before the router pay.
        uint256 projectBBalBefore =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), projectBEthId, JBConstants.NATIVE_TOKEN);

        // Step 3: Pay project B via router terminal using project A's ERC-20 tokens.
        vm.startPrank(payer);
        IERC20(address(projectAToken)).approve(address(routerTerminal), paTokenBalance);
        uint256 tokenCount = routerTerminal.pay({
            projectId: projectBEthId,
            token: address(projectAToken),
            amount: paTokenBalance,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "pay project B with project A tokens (cashout-only path)",
            metadata: ""
        });
        vm.stopPrank();

        // Assertions.

        // 1. Project B tokens were minted for the beneficiary.
        assertGt(tokenCount, 0, "no project B tokens minted");

        // 2. Project B terminal received ETH (balance increased).
        uint256 projectBBalAfter =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), projectBEthId, JBConstants.NATIVE_TOKEN);
        assertGt(projectBBalAfter, projectBBalBefore, "project B ETH balance should have increased");

        // 3. Router has no leftover tokens.
        assertEq(
            IERC20(address(projectAToken)).balanceOf(address(routerTerminal)),
            0,
            "router should have no leftover project A tokens"
        );
        assertEq(address(routerTerminal).balance, 0, "router should have no leftover ETH");
        assertEq(IERC20(address(WETH)).balanceOf(address(routerTerminal)), 0, "router should have no leftover WETH");

        // 4. Payer should have spent all their project A tokens.
        assertEq(IERC20(address(projectAToken)).balanceOf(payer), 0, "payer should have no remaining project A tokens");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 2: Cashout + swap path — pay project B (USDC) with project A tokens
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Pay project A tokens into project B (which accepts USDC).
    /// Router cashes out A tokens -> gets ETH -> swaps ETH to USDC via Uniswap -> pays project B.
    function test_fork_cashOutPath_projectTokenToUSDC() public {
        uint256 payAmount = 10 ether;

        // Step 1: Pay project A with ETH -> mints project A ERC-20 tokens.
        vm.deal(payer, payAmount);
        vm.prank(payer);
        jbMultiTerminal.pay{value: payAmount}({
            projectId: projectAId,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "fund project A",
            metadata: ""
        });

        // Step 2: Verify payer has project A ERC-20 tokens.
        uint256 paTokenBalance = IERC20(address(projectAToken)).balanceOf(payer);
        assertGt(paTokenBalance, 0, "payer should have project A ERC-20 tokens");

        // Record project B (USDC) balance before the router pay.
        uint256 projectBBalBefore = jbTerminalStore.balanceOf(address(jbMultiTerminal), projectBUsdcId, address(USDC));

        // Step 3: Pay project B (USDC) via router terminal using project A's ERC-20 tokens.
        vm.startPrank(payer);
        IERC20(address(projectAToken)).approve(address(routerTerminal), paTokenBalance);
        uint256 tokenCount = routerTerminal.pay({
            projectId: projectBUsdcId,
            token: address(projectAToken),
            amount: paTokenBalance,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "pay project B (USDC) with project A tokens (cashout + swap path)",
            metadata: ""
        });
        vm.stopPrank();

        // Assertions.

        // 1. Project B tokens were minted for the beneficiary.
        assertGt(tokenCount, 0, "no project B tokens minted");

        // 2. Project B terminal received USDC (balance increased).
        uint256 projectBBalAfter = jbTerminalStore.balanceOf(address(jbMultiTerminal), projectBUsdcId, address(USDC));
        assertGt(projectBBalAfter, projectBBalBefore, "project B USDC balance should have increased");

        // 3. Router has no leftover tokens.
        assertEq(
            IERC20(address(projectAToken)).balanceOf(address(routerTerminal)),
            0,
            "router should have no leftover project A tokens"
        );
        assertEq(address(routerTerminal).balance, 0, "router should have no leftover ETH");
        assertEq(IERC20(address(WETH)).balanceOf(address(routerTerminal)), 0, "router should have no leftover WETH");
        assertEq(USDC.balanceOf(address(routerTerminal)), 0, "router should have no leftover USDC");

        // 4. Payer should have spent all their project A tokens.
        assertEq(IERC20(address(projectAToken)).balanceOf(payer), 0, "payer should have no remaining project A tokens");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 3: Partial cashout — pay a portion of project A tokens
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Pay only half of the project A tokens into project B (ETH).
    /// Verifies partial amounts work correctly through the cashout path.
    function test_fork_cashOutPath_partialAmount() public {
        uint256 payAmount = 10 ether;

        // Step 1: Pay project A with ETH.
        vm.deal(payer, payAmount);
        vm.prank(payer);
        jbMultiTerminal.pay{value: payAmount}({
            projectId: projectAId,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "fund project A",
            metadata: ""
        });

        uint256 paTokenBalance = IERC20(address(projectAToken)).balanceOf(payer);
        uint256 halfBalance = paTokenBalance / 2;
        assertGt(halfBalance, 0, "half balance should be > 0");

        // Step 2: Pay project B with only half the tokens.
        vm.startPrank(payer);
        IERC20(address(projectAToken)).approve(address(routerTerminal), halfBalance);
        uint256 tokenCount = routerTerminal.pay({
            projectId: projectBEthId,
            token: address(projectAToken),
            amount: halfBalance,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "partial cashout path",
            metadata: ""
        });
        vm.stopPrank();

        // Assertions.

        // 1. Project B tokens were minted.
        assertGt(tokenCount, 0, "no project B tokens minted for partial cashout");

        // 2. Payer still has remaining project A tokens.
        uint256 remainingBalance = IERC20(address(projectAToken)).balanceOf(payer);
        assertEq(remainingBalance, paTokenBalance - halfBalance, "payer should have remaining tokens");

        // 3. Router has no leftover.
        assertEq(
            IERC20(address(projectAToken)).balanceOf(address(routerTerminal)),
            0,
            "router should have no leftover project A tokens"
        );
        assertEq(address(routerTerminal).balance, 0, "router should have no leftover ETH");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 4: Small amount cashout path
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Cashout path with a small ETH amount (0.01 ETH) to verify no dust issues.
    function test_fork_cashOutPath_smallAmount() public {
        uint256 payAmount = 0.01 ether;

        // Pay project A with a small amount.
        vm.deal(payer, payAmount);
        vm.prank(payer);
        jbMultiTerminal.pay{value: payAmount}({
            projectId: projectAId,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "small fund project A",
            metadata: ""
        });

        uint256 paTokenBalance = IERC20(address(projectAToken)).balanceOf(payer);
        assertGt(paTokenBalance, 0, "payer should have project A tokens");

        // Pay project B (ETH) via cashout path.
        vm.startPrank(payer);
        IERC20(address(projectAToken)).approve(address(routerTerminal), paTokenBalance);
        uint256 tokenCount = routerTerminal.pay({
            projectId: projectBEthId,
            token: address(projectAToken),
            amount: paTokenBalance,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "small cashout path",
            metadata: ""
        });
        vm.stopPrank();

        // Project B tokens were minted.
        assertGt(tokenCount, 0, "no project B tokens minted for small amount");

        // Router clean.
        assertEq(address(routerTerminal).balance, 0, "router has leftover ETH");
        assertEq(
            IERC20(address(projectAToken)).balanceOf(address(routerTerminal)), 0, "router has leftover project A tokens"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 5: Large amount cashout + swap path
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Cashout + swap path with a large ETH amount (100 ETH) to verify it handles liquidity.
    function test_fork_cashOutPath_largeAmount_toUSDC() public {
        uint256 payAmount = 100 ether;

        // Pay project A with a large amount.
        vm.deal(payer, payAmount);
        vm.prank(payer);
        jbMultiTerminal.pay{value: payAmount}({
            projectId: projectAId,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "large fund project A",
            metadata: ""
        });

        uint256 paTokenBalance = IERC20(address(projectAToken)).balanceOf(payer);
        assertGt(paTokenBalance, 0, "payer should have project A tokens");

        // Pay project B (USDC) via cashout + swap path.
        vm.startPrank(payer);
        IERC20(address(projectAToken)).approve(address(routerTerminal), paTokenBalance);
        uint256 tokenCount = routerTerminal.pay({
            projectId: projectBUsdcId,
            token: address(projectAToken),
            amount: paTokenBalance,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "large cashout + swap path",
            metadata: ""
        });
        vm.stopPrank();

        // Project B tokens were minted.
        assertGt(tokenCount, 0, "no project B tokens minted for large amount");

        // Project B terminal received USDC.
        uint256 projectBUsdcBal = jbTerminalStore.balanceOf(address(jbMultiTerminal), projectBUsdcId, address(USDC));
        assertGt(projectBUsdcBal, 0, "project B should have USDC balance");

        // Router clean.
        assertEq(address(routerTerminal).balance, 0, "router has leftover ETH");
        assertEq(USDC.balanceOf(address(routerTerminal)), 0, "router has leftover USDC");
        assertEq(
            IERC20(address(projectAToken)).balanceOf(address(routerTerminal)), 0, "router has leftover project A tokens"
        );
        assertEq(IERC20(address(WETH)).balanceOf(address(routerTerminal)), 0, "router has leftover WETH");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Launch a JB project that accepts `acceptedToken` via the multi terminal.
    function _launchProject(
        address acceptedToken,
        uint8 decimals,
        uint16 cashOutTaxRate
    )
        internal
        returns (uint256 projectId)
    {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: cashOutTaxRate,
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
}
