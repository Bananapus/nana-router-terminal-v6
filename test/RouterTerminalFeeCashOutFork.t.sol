// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

// JB core.
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
import {JBCurrencyAmount} from "@bananapus/core-v6/src/structs/JBCurrencyAmount.sol";
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

/// @notice Fork test: fee project (project 1) accepts fees paid in project 2's ERC-20 token via the router terminal's
/// cashout route.
///
/// Setup:
///   - Project 1 (fee project): has a multi terminal (accepts NATIVE_TOKEN) AND a router terminal.
///   - Project 2: accepts NATIVE_TOKEN, deploys an ERC-20 token, cashOutTaxRate = 0.
///   - Project 3: accepts project 2's ERC-20 as its token, has payout limits in that token.
///
/// Flow:
///   1. Pay project 2 with ETH → mints project 2 tokens (credits).
///   2. Deploy ERC-20 for project 2, claim credits as ERC-20.
///   3. Pay project 3 with project 2's ERC-20 → project 3 holds a balance.
///   4. Project 3 sends payouts → fee is taken in project 2's ERC-20 token.
///   5. Fee terminal lookup finds the router terminal for project 1.
///   6. Router terminal cashes out project 2's tokens → receives ETH.
///   7. Router forwards ETH to project 1's multi terminal.
///   8. Assert: project 1's ETH balance increased, router has no leftover.
contract RouterTerminalFeeCashOutForkTest is Test {
    // ───────────────────────── Mainnet addresses
    // ──────────────────────────

    uint256 constant BLOCK_NUMBER = 21_700_000;

    IWETH9 constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV3Factory constant V3_FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    // ───────────────────────── Actors
    // ──────────────────────────

    address multisig = address(0xBEEF);
    address payer = makeAddr("payer");
    address project3Owner = makeAddr("project3Owner");
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

    uint256 feeProjectId; // Project 1.
    uint256 project2Id;
    uint256 project3Id;

    // ───────────────────────── Project 2's ERC-20
    // ──────────────────────────

    IJBToken project2Token;

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

        // ── Project 1 (fee project): multi terminal (ETH) + router terminal ──
        feeProjectId = _launchFeeProject();
        require(feeProjectId == 1, "fee project must be #1");

        // ── Project 2: accepts ETH, cashOutTaxRate = 0 ──
        project2Id = _launchProject({
            owner: multisig,
            acceptedToken: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            cashOutTaxRate: 0,
            payoutLimitToken: address(0),
            payoutLimitAmount: 0
        });

        // Deploy ERC-20 for project 2.
        vm.prank(multisig);
        project2Token = jbController.deployERC20For({projectId: project2Id, name: "Project2", symbol: "P2", salt: 0});

        // ── Project 3: accepts project 2's ERC-20 token ──
        project3Id = _launchProject({
            owner: project3Owner,
            acceptedToken: address(project2Token),
            decimals: 18,
            cashOutTaxRate: 0,
            payoutLimitToken: address(project2Token),
            payoutLimitAmount: 10e18 // 10 project 2 tokens payout limit.
        });

        // Labels.
        vm.label(address(routerTerminal), "RouterTerminal");
        vm.label(address(jbMultiTerminal), "JBMultiTerminal");
        vm.label(address(project2Token), "Project2Token");
        vm.label(payer, "payer");
        vm.label(project3Owner, "project3Owner");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: fee paid in project 2's token routes through cashout to project 1
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_feeCashOutRoute() public {
        // ── Step 1: Pay project 2 with 10 ETH → mints credits ──
        uint256 payAmount = 10 ether;
        vm.deal(payer, payAmount);
        vm.prank(payer);
        jbMultiTerminal.pay{value: payAmount}({
            projectId: project2Id,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "fund project 2",
            metadata: ""
        });

        // ── Step 2: Verify payer has project 2's ERC-20 tokens ──
        // (Minted directly as ERC-20 since the token was deployed before payment.)
        uint256 p2TokenBalance = IERC20(address(project2Token)).balanceOf(payer);
        assertGt(p2TokenBalance, 0, "payer should have project 2 ERC-20 tokens");

        // ── Step 3: Pay project 3 with project 2's ERC-20 ──
        uint256 project3PayAmount = p2TokenBalance;
        vm.startPrank(payer);
        IERC20(address(project2Token)).approve(address(jbMultiTerminal), project3PayAmount);
        jbMultiTerminal.pay({
            projectId: project3Id,
            token: address(project2Token),
            amount: project3PayAmount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "fund project 3 with P2 tokens",
            metadata: ""
        });
        vm.stopPrank();

        // Verify project 3 has a balance in project 2's token.
        uint256 project3Balance =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), project3Id, address(project2Token));
        assertGt(project3Balance, 0, "project 3 should have P2 token balance");

        // ── Step 4: Record fee project's ETH balance before payout ──
        uint256 feeProjectBalanceBefore =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), feeProjectId, JBConstants.NATIVE_TOKEN);

        // ── Step 5: Project 3 sends payouts → fee taken in project 2's token ──
        // The payout limit is 10e18 project 2 tokens.
        // The leftover goes to the project owner, minus the 2.5% fee.
        // The fee is sent to project 1 via the router terminal (cashout route).
        uint256 payoutAmount = 10e18;
        vm.prank(project3Owner);
        jbMultiTerminal.sendPayoutsOf({
            projectId: project3Id,
            token: address(project2Token),
            amount: payoutAmount,
            currency: uint32(uint160(address(project2Token))),
            minTokensPaidOut: 0
        });

        // ── Assertions ──

        // 1. Fee project (project 1) received ETH in its multi terminal.
        uint256 feeProjectBalanceAfter =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), feeProjectId, JBConstants.NATIVE_TOKEN);
        assertGt(feeProjectBalanceAfter, feeProjectBalanceBefore, "fee project should have received ETH from fee");

        // 2. Router terminal has no leftover tokens.
        assertEq(
            IERC20(address(project2Token)).balanceOf(address(routerTerminal)),
            0,
            "router should have no leftover P2 tokens"
        );
        assertEq(address(routerTerminal).balance, 0, "router should have no leftover ETH");

        // 3. The fee amount should correspond to 2.5% of the payout.
        // The entire payout (10e18) is eligible for fees since there are no splits
        // and the full amount goes to the project owner.
        // Fee = amount * 25 / 1000 = 2.5%.
        // The fee in P2 tokens gets cashed out for ETH. Since project 2 has cashOutTaxRate = 0,
        // the cashout returns the proportional surplus (fee_tokens / total_supply * surplus).
        // We just verify the fee project received a non-zero ETH amount.
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 feeProjectETHGain = feeProjectBalanceAfter - feeProjectBalanceBefore;
        assertGt(feeProjectETHGain, 0, "fee project ETH gain should be > 0");

        emit log_named_uint("Fee project ETH gain (wei)", feeProjectETHGain);
        emit log_named_uint("Fee project ETH gain (P2 tokens worth, approx)", feeProjectETHGain);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Launch the fee project (project 1) with both multi terminal and router terminal.
    function _launchFeeProject() internal returns (uint256 projectId) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
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
        rulesetConfigs[0].weight = 1_000_000e18;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        // Multi terminal: accepts NATIVE_TOKEN.
        JBAccountingContext[] memory ethContext = new JBAccountingContext[](1);
        ethContext[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // Router terminal: accepts any token (empty contexts — it generates them dynamically).
        JBAccountingContext[] memory routerContext = new JBAccountingContext[](0);

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](2);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: ethContext});
        terminalConfigs[1] = JBTerminalConfig({terminal: routerTerminal, accountingContextsToAccept: routerContext});

        projectId = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "fee-project",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    /// @dev Launch a project with a single accepted token and optional payout limit.
    function _launchProject(
        address owner,
        address acceptedToken,
        uint8 decimals,
        uint16 cashOutTaxRate,
        address payoutLimitToken,
        uint224 payoutLimitAmount
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

        // Set up fund access limits if a payout limit is specified.
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups;
        if (payoutLimitAmount > 0) {
            fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
            JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
            // forge-lint: disable-next-line(unsafe-typecast)
            payoutLimits[0] = JBCurrencyAmount({amount: payoutLimitAmount, currency: uint32(uint160(payoutLimitToken))});
            fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
                terminal: address(jbMultiTerminal),
                token: payoutLimitToken,
                payoutLimits: payoutLimits,
                surplusAllowances: new JBCurrencyAmount[](0)
            });
        } else {
            fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);
        }

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        rulesetConfigs[0].weight = 1_000_000e18;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = fundAccessLimitGroups;

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: acceptedToken, decimals: decimals, currency: uint32(uint160(acceptedToken))});

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});

        projectId = jbController.launchProjectFor({
            owner: owner,
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
            address(0),
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
