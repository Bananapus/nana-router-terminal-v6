// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Router terminal.
import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

/// @notice A mock ERC20 that has no Uniswap pool. Used to test the no-pool-found revert path.
contract MockObscureToken is ERC20 {
    constructor() ERC20("ObscureToken", "OBSCURE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Fork tests documenting the behavior boundary of JBRouterTerminal._discoverPool().
/// @dev _discoverPool() searches V3 fee tiers [3000, 500, 10000, 100] and corresponding V4 tiers
///      for a DIRECT pool only. No path encoding = no multi-hop routing. These tests verify:
///      1. Direct pool discovery works (USDC/DAI pair exists on mainnet).
///      2. Clean revert when no direct pool exists (mock token with no Uniswap pool).
///      3. Slippage protection catches bad pricing on thin-liquidity pools.
contract RouterTerminalMultihopForkTest is Test {
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
    uint256 feeProjectId;
    uint256 daiProjectId;

    // Mock token for no-pool test.
    MockObscureToken obscureToken;
    uint256 obscureProjectId;

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

        // Deploy mock obscure token (no Uniswap pool exists for it).
        obscureToken = new MockObscureToken();

        // Create test projects.
        feeProjectId = _launchProject({acceptedToken: JBConstants.NATIVE_TOKEN, decimals: 18});
        daiProjectId = _launchProject({acceptedToken: address(DAI), decimals: 18});
        obscureProjectId = _launchProject({acceptedToken: address(obscureToken), decimals: 18});

        // Labels for trace readability.
        vm.label(address(WETH), "WETH");
        vm.label(address(USDC), "USDC");
        vm.label(address(DAI), "DAI");
        vm.label(address(obscureToken), "ObscureToken");
        vm.label(address(routerTerminal), "RouterTerminal");
        vm.label(address(jbMultiTerminal), "JBMultiTerminal");
        vm.label(payer, "payer");
        vm.label(beneficiary, "beneficiary");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TEST 1: Direct pool discovery — USDC -> DAI (exists on mainnet)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Verify that the router can find the USDC/DAI direct V3 pool and route a payment.
    /// @dev USDC/DAI pools exist on mainnet at multiple fee tiers (notably 0.01% and 0.05%).
    ///      _discoverPool() iterates [3000, 500, 10000, 100] and picks the one with highest liquidity.
    ///      This documents that single-hop routing works for well-known stablecoin pairs.
    function testFork_DirectPoolDiscovery() public {
        uint256 amountIn = 10_000e6; // 10,000 USDC

        // Give the payer USDC.
        deal(address(USDC), payer, amountIn);

        vm.startPrank(payer);
        USDC.approve(address(routerTerminal), amountIn);

        uint256 tokenCount = routerTerminal.pay({
            projectId: daiProjectId,
            token: address(USDC),
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "USDC->DAI direct pool discovery",
            metadata: ""
        });
        vm.stopPrank();

        // 1. Tokens were minted — the payment went through.
        assertGt(tokenCount, 0, "no tokens minted for USDC->DAI direct pool swap");

        // 2. Terminal received DAI (project balance increased).
        uint256 terminalBal = jbTerminalStore.balanceOf(address(jbMultiTerminal), daiProjectId, address(DAI));
        assertGt(terminalBal, 0, "terminal has no DAI balance after USDC payment");

        // 3. Router has no leftover tokens.
        assertEq(USDC.balanceOf(address(routerTerminal)), 0, "router has leftover USDC");
        assertEq(DAI.balanceOf(address(routerTerminal)), 0, "router has leftover DAI");
        assertEq(address(routerTerminal).balance, 0, "router has leftover ETH");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TEST 2: No pool found — mock token with no Uniswap pool
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Verify clean revert when paying with USDC to a project that only accepts
    ///         an obscure token with no Uniswap pool. _discoverPool() finds no V3 or V4 pool,
    ///         so _pickPoolAndQuote reverts with NoPoolFound.
    /// @dev This documents the boundary: the router does NOT support multi-hop routing.
    ///      Even if USDC->WETH and WETH->OBSCURE pools existed, the router only looks for
    ///      a DIRECT USDC->OBSCURE pool. With a mock token, no pool exists at any fee tier.
    function testFork_NoPoolFoundReverts() public {
        uint256 amountIn = 1000e6; // 1,000 USDC

        // Give the payer USDC.
        deal(address(USDC), payer, amountIn);

        vm.startPrank(payer);
        USDC.approve(address(routerTerminal), amountIn);

        // Should revert because no direct USDC<->ObscureToken pool exists on Uniswap.
        vm.expectRevert();
        routerTerminal.pay({
            projectId: obscureProjectId,
            token: address(USDC),
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "should revert - no pool",
            metadata: ""
        });
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TEST 3: Slippage protection on thin liquidity
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Verify that slippage protection catches bad pricing when a large payment
    ///         goes through a pool. We use USDC->DAI with an unreasonably high quote to
    ///         force the SlippageExceeded revert path.
    /// @dev The router's TWAP-based slippage protection calculates a minAmountOut.
    ///      By providing a user quote (via metadata) that demands far more output than
    ///      the pool can deliver, we trigger SlippageExceeded. This proves the router
    ///      does not silently accept bad pricing.
    function testFork_SlippageProtectionOnThinPool() public {
        uint256 amountIn = 10_000e6; // 10,000 USDC

        // Give the payer USDC.
        deal(address(USDC), payer, amountIn);

        // Demand 100,000 DAI for 10,000 USDC — 10x the market rate.
        // This forces the swap to revert with SlippageExceeded because the pool
        // will return ~10,000 DAI (stablecoin pair), far below the 100,000 demanded.
        bytes4 quoteId = JBMetadataResolver.getId("quoteForSwap", address(routerTerminal));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", quoteId, abi.encode(uint256(100_000e18)));

        vm.startPrank(payer);
        USDC.approve(address(routerTerminal), amountIn);

        // The router should revert — either SlippageExceeded from the V3 swap callback
        // or from the post-swap check in _executeSwap.
        vm.expectRevert();
        routerTerminal.pay({
            projectId: daiProjectId,
            token: address(USDC),
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "should revert - slippage exceeded",
            metadata: metadata
        });
        vm.stopPrank();
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
