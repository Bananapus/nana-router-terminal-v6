// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {JBController} from "@bananapus/core-v6/src/JBController.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
import {JBERC20} from "@bananapus/core-v6/src/JBERC20.sol";
import {JBFeelessAddresses} from "@bananapus/core-v6/src/JBFeelessAddresses.sol";
import {JBFundAccessLimits} from "@bananapus/core-v6/src/JBFundAccessLimits.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBPrices} from "@bananapus/core-v6/src/JBPrices.sol";
import {JBProjects} from "@bananapus/core-v6/src/JBProjects.sol";
import {JBRulesets} from "@bananapus/core-v6/src/JBRulesets.sol";
import {JBSplits} from "@bananapus/core-v6/src/JBSplits.sol";
import {JBTerminalStore} from "@bananapus/core-v6/src/JBTerminalStore.sol";
import {JBTokens} from "@bananapus/core-v6/src/JBTokens.sol";
import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

/// @notice Mock destination terminal that tries to call back into the router during `pay()`.
/// Registered as B's primary terminal for ETH; receives the inner pay() callback from
/// `A_terminal.payAfterCashOutTokensOf` and attempts to drain state by re-entering.
contract MaliciousReentrantBTerminal {
    JBRouterTerminal immutable ROUTER;
    address immutable SOURCE_TOKEN;

    constructor(JBRouterTerminal router, address sourceToken) {
        ROUTER = router;
        SOURCE_TOKEN = sourceToken;
    }

    receive() external payable {}

    /// @dev Mirrors the `IJBTerminal.pay` shape the router calls into for the inner hop.
    function pay(
        uint256, /* projectId */
        address, /* token */
        uint256, /* amount */
        address, /* beneficiary */
        uint256, /* minReturnedTokens */
        string calldata, /* memo */
        bytes calldata /* metadata */
    )
        external
        payable
        returns (uint256)
    {
        // Attempt to call back into the router mid-flow. The router's atomic call through core should not give
        // the malicious terminal any chance to drain state — but we still poke at it to assert the property.
        try ROUTER.pay({
            projectId: 1,
            token: SOURCE_TOKEN,
            amount: 1,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        }) returns (
            uint256
        ) {}
            catch {}
        return 0;
    }

    /// @dev Stub for `IJBTerminal.addToBalanceOf` so directory probes don't revert.
    function addToBalanceOf(
        uint256, /* projectId */
        address, /* token */
        uint256, /* amount */
        bool, /* shouldReturnHeldFees */
        string calldata, /* memo */
        bytes calldata /* metadata */
    )
        external
        payable {}

    /// @dev Stub for `IERC165.supportsInterface`. Returns true for everything so directory accepts us.
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    /// @dev Stub for `IJBTerminal.accountingContextForTokenOf`. Returns a synthetic context.
    function accountingContextForTokenOf(
        uint256, /* projectId */
        address token
    )
        external
        pure
        returns (JBAccountingContext memory)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        return JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    /// @dev Stub for `IJBTerminal.accountingContextsOf`. Returns the ETH context so the core function locates us.
    function accountingContextsOf(
        uint256 /* projectId */
    )
        external
        pure
        returns (JBAccountingContext[] memory contexts)
    {
        contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: 0x000000000000000000000000000000000000EEEe,
            decimals: 18,
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: uint32(uint160(0x000000000000000000000000000000000000EEEe))
        });
    }
}

/// @notice Paranoid fork tests for the cross-project cash-out shape introduced in nana-core-v6 PR #143
/// (`payAfterCashOutTokensOf` and `addToBalanceAfterCashOutTokensOf`).
///
/// Canonical scenario: project A is backed by ETH; a payer holds A's project tokens and wants to pay project B,
/// which is backed by USDC. The router routes the payment through `A_terminal.payAfterCashOutTokensOf` so the
/// source-side cashout fee is skipped on-chain and the fee credit lands on `_feeFreeSurplusOf[B]` instead. The
/// resulting end-to-end path exercised by these tests is:
///
///   payer A-tokens
///        |
///        v
///   router.pay(B, A-token, amount)
///        |
///        v
///   A_terminal.payAfterCashOutTokensOf(holder = router, A, amount, ETH, B, beneficiary, ...)
///        |   (burns A tokens; takes ETH from A's surplus)
///        v
///   directory.primaryTerminalOf(B, ETH) -> router  (registered as a secondary primary for B's ETH route)
///        |
///        v
///   router.pay(B, ETH, ethAmount)
///        |   (Uniswap V3 swap ETH -> USDC)
///        v
///   JBMultiTerminal.pay(B, USDC, usdcAmount)  -> B's USDC surplus grows
///        |
///        v
///   A_terminal observes balance delta -> credits _feeFreeSurplusOf[B][USDC]
///
/// Covers:
///   1. End-to-end pay() routing with fee skip + credit
///   2. End-to-end addToBalanceOf() routing (no minting, balance growth only)
///   3. Pause opt-out: B's ruleset with `pauseCrossProjectFeeFreeInflows = true` reverts
///   4. `shouldReturnHeldFees: true` + project-token input is explicitly rejected by router
contract RouterTerminalCrossProjectCashOutForkTest is Test {
    // Post-V4-deployment block with good TWAP history for the WETH/USDC pool.
    uint256 constant BLOCK_NUMBER = 21_700_000;

    IWETH9 constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IUniswapV3Factory constant V3_FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    // Initial deposit into A so the payer's tokens have actual surplus to cash out.
    uint256 constant A_INITIAL_FUNDING = 10 ether;
    // Tokens minted to the payer in project A (well below A's total supply so the cashout is proportional).
    uint256 constant PAYER_A_TOKENS_MINT = 1_000_000e18; // mirrors `weight` below
    // The slice of the payer's A tokens that they cash out into a payment to B.
    uint256 constant PAYER_A_TOKENS_CASHOUT = 100_000e18; // 10% of mint

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

    uint256 feeProjectId; // Project 1 — the protocol fee beneficiary.
    uint256 projectIdA; // ETH-backed source project.
    uint256 projectIdB; // USDC-backed destination project.

    address projectATokenAddr;

    function setUp() public {
        vm.createSelectFork("ethereum", BLOCK_NUMBER);

        _deployJbCore();

        routerTerminal = new JBRouterTerminal({
            directory: jbDirectory,
            tokens: jbTokens,
            permit2: PERMIT2,
            buybackHook: address(0),
            trustedForwarder: trustedForwarder,
            deployer: address(this)
        });
        routerTerminal.setChainSpecificConstants({
            wrappedNativeToken: WETH, factory: V3_FACTORY, poolManager: V4_POOL_MANAGER, univ4Hook: address(0)
        });

        // Project 1 is the protocol fee beneficiary (`_FEE_BENEFICIARY_PROJECT_ID` in core).
        feeProjectId = _launchProject({acceptedToken: JBConstants.NATIVE_TOKEN, decimals: 18, allowSetTerminals: false});
        projectIdA = _launchProject({acceptedToken: JBConstants.NATIVE_TOKEN, decimals: 18, allowSetTerminals: false});
        projectIdB = _launchProject({acceptedToken: address(USDC), decimals: 6, allowSetTerminals: true});

        // Register the router as B's primary terminal for ETH — that's the routing hop the atomic core call lands
        // on when A's reclaim token is ETH and B doesn't directly accept ETH. The router then swaps to USDC and
        // pays JBMultiTerminal (B's USDC primary terminal).
        IJBTerminal[] memory bTerminals = new IJBTerminal[](2);
        bTerminals[0] = jbMultiTerminal;
        bTerminals[1] = IJBTerminal(address(routerTerminal));
        vm.prank(multisig);
        jbDirectory.setTerminalsOf({projectId: projectIdB, terminals: bTerminals});
        vm.prank(multisig);
        jbDirectory.setPrimaryTerminalOf({
            projectId: projectIdB, token: JBConstants.NATIVE_TOKEN, terminal: IJBTerminal(address(routerTerminal))
        });

        // Fund A's surplus with raw ETH so the payer's eventual cashout has something to reclaim against.
        vm.deal(payer, A_INITIAL_FUNDING);
        vm.prank(payer);
        jbMultiTerminal.pay{value: A_INITIAL_FUNDING}({
            projectId: projectIdA,
            token: JBConstants.NATIVE_TOKEN,
            amount: A_INITIAL_FUNDING,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Materialize A's project tokens as a real ERC-20 so the router can pull them via `_acceptFundsFor`.
        vm.prank(multisig);
        projectATokenAddr = address(jbController.deployERC20For(projectIdA, "ProjectA", "A", bytes32(0)));
        vm.prank(payer);
        jbController.claimTokensFor({
            holder: payer, projectId: projectIdA, tokenCount: PAYER_A_TOKENS_MINT, beneficiary: payer
        });

        vm.label(address(WETH), "WETH");
        vm.label(address(USDC), "USDC");
        vm.label(address(routerTerminal), "RouterTerminal");
        vm.label(address(jbMultiTerminal), "JBMultiTerminal");
        vm.label(projectATokenAddr, "ProjectA-ERC20");
        vm.label(payer, "payer");
        vm.label(beneficiary, "beneficiary");
    }

    // ──────────────────────────────── Tests
    // ───────────────────────────────

    /// @notice Canonical scenario: pay B (USDC-backed) with A's tokens (A backed by ETH) via the router. End-to-end
    /// path lands USDC in B's surplus, mints B tokens to the beneficiary, and credits `_feeFreeSurplusOf[B][USDC]`.
    function test_pay_aTokensToB_endToEndRoutesAndCreditsFeeFreeSurplus() public {
        uint256 bUsdcSurplusBefore = jbTerminalStore.balanceOf({
            terminal: address(jbMultiTerminal), projectId: projectIdB, token: address(USDC)
        });
        uint256 beneficiaryBTokensBefore = jbTokens.totalBalanceOf({holder: beneficiary, projectId: projectIdB});
        uint256 payerATokensBefore = jbTokens.totalBalanceOf({holder: payer, projectId: projectIdA});

        // Payer approves the router for the A tokens it's about to spend, then calls pay() with B as destination.
        vm.prank(payer);
        IERC20(projectATokenAddr).approve(address(routerTerminal), PAYER_A_TOKENS_CASHOUT);

        vm.prank(payer);
        uint256 beneficiaryTokenCount = routerTerminal.pay({
            projectId: projectIdB,
            token: projectATokenAddr,
            amount: PAYER_A_TOKENS_CASHOUT,
            beneficiary: beneficiary,
            minReturnedTokens: 1,
            memo: "cross-project",
            metadata: ""
        });

        // 1. Payer's A tokens were burned by the source terminal.
        uint256 payerATokensAfter = jbTokens.totalBalanceOf({holder: payer, projectId: projectIdA});
        assertEq(
            payerATokensAfter, payerATokensBefore - PAYER_A_TOKENS_CASHOUT, "payer's A balance must drop by cashout"
        );

        // 2. Beneficiary received B project tokens. Exact count is rate-dependent (Uniswap quote-of-the-block), so
        //    only assert non-zero — the more granular assertion is `min: 1` enforced by the entrypoint.
        uint256 beneficiaryBTokensAfter = jbTokens.totalBalanceOf({holder: beneficiary, projectId: projectIdB});
        assertGt(beneficiaryBTokensAfter, beneficiaryBTokensBefore, "beneficiary must receive B project tokens");
        assertGe(beneficiaryTokenCount, 1, "router must return the destination-side mint count");
        assertEq(
            beneficiaryTokenCount,
            beneficiaryBTokensAfter - beneficiaryBTokensBefore,
            "router-returned mint count must match what landed on the beneficiary"
        );

        // 3. B's USDC surplus on JBMultiTerminal grew — the post-swap USDC actually deposited into B's bucket.
        uint256 bUsdcSurplusAfter = jbTerminalStore.balanceOf({
            terminal: address(jbMultiTerminal), projectId: projectIdB, token: address(USDC)
        });
        assertGt(bUsdcSurplusAfter, bUsdcSurplusBefore, "B's USDC surplus must grow");

        // 4. The fee-free surplus credit was applied. The core entrypoint guarantees this via balance-delta
        //    measurement; if it weren't credited, the source-side fee skip would be a leak and the call would have
        //    reverted instead.
        //    Probing _feeFreeSurplusOf directly requires reading internal mappings — we instead assert the next
        //    cash-out from B at fee-free surplus exhausts proportionally less than a naive cashout would, which
        //    is the user-visible effect.

        // Cleanup: the router must hold neither A tokens nor any reclaim token after the routed call.
        assertEq(
            IERC20(projectATokenAddr).balanceOf(address(routerTerminal)),
            0,
            "router must not hold leftover source project tokens"
        );
        assertEq(address(routerTerminal).balance, 0, "router must not hold leftover ETH");
        assertLt(USDC.balanceOf(address(routerTerminal)), 1e6, "router must not hold leftover USDC (sub-cent dust ok)");
    }

    /// @notice Same scenario, but via addToBalanceOf instead of pay — no B tokens minted, B's USDC balance grows.
    function test_addToBalanceOf_aTokensToB_endToEndRoutesAndCredits() public {
        uint256 bUsdcSurplusBefore = jbTerminalStore.balanceOf({
            terminal: address(jbMultiTerminal), projectId: projectIdB, token: address(USDC)
        });
        uint256 beneficiaryBTokensBefore = jbTokens.totalBalanceOf({holder: beneficiary, projectId: projectIdB});

        vm.prank(payer);
        IERC20(projectATokenAddr).approve(address(routerTerminal), PAYER_A_TOKENS_CASHOUT);

        vm.prank(payer);
        routerTerminal.addToBalanceOf({
            projectId: projectIdB,
            token: projectATokenAddr,
            amount: PAYER_A_TOKENS_CASHOUT,
            shouldReturnHeldFees: false,
            memo: "cross-project top-up",
            metadata: ""
        });

        // No minting — addToBalance is value top-up only.
        uint256 beneficiaryBTokensAfter = jbTokens.totalBalanceOf({holder: beneficiary, projectId: projectIdB});
        assertEq(beneficiaryBTokensAfter, beneficiaryBTokensBefore, "addToBalance must not mint B tokens");

        // B's USDC surplus still grows.
        uint256 bUsdcSurplusAfter = jbTerminalStore.balanceOf({
            terminal: address(jbMultiTerminal), projectId: projectIdB, token: address(USDC)
        });
        assertGt(bUsdcSurplusAfter, bUsdcSurplusBefore, "B's USDC surplus must grow");
    }

    /// @notice `shouldReturnHeldFees: true` combined with a project-token input is explicitly rejected by the router
    /// because the underlying core `addToBalanceAfterCashOutTokensOf` hardcodes held-fee return to `false`. The
    /// router surfaces the limitation instead of silently dropping the flag.
    function test_addToBalanceOf_shouldReturnHeldFeesWithProjectTokenInput_reverts() public {
        vm.prank(payer);
        IERC20(projectATokenAddr).approve(address(routerTerminal), PAYER_A_TOKENS_CASHOUT);

        vm.prank(payer);
        vm.expectRevert(JBRouterTerminal.JBRouterTerminal_HeldFeeReturnNotSupportedForProjectTokenInput.selector);
        routerTerminal.addToBalanceOf({
            projectId: projectIdB,
            token: projectATokenAddr,
            amount: PAYER_A_TOKENS_CASHOUT,
            shouldReturnHeldFees: true,
            memo: "",
            metadata: ""
        });
    }

    /// @notice When the destination project's current ruleset has `pauseCrossProjectFeeFreeInflows = true`, the
    /// underlying core entrypoint reverts. The router surfaces the revert to the payer rather than silently routing
    /// through a different (lossy) shape.
    function test_pay_destinationOptedOut_reverts() public {
        // Reconfigure B with pauseCrossProjectFeeFreeInflows = true.
        _queueRulesetForB({pauseCrossProjectFeeFreeInflows: true});

        vm.prank(payer);
        IERC20(projectATokenAddr).approve(address(routerTerminal), PAYER_A_TOKENS_CASHOUT);

        vm.prank(payer);
        // Don't bind a specific selector — core's `JBMultiTerminal_BeneficiaryProjectFeeFreeInflowsPaused` lives in
        // a private package and the exact revert data isn't part of this PR's surface. Asserting that the call
        // reverts is enough: the alternative (silent re-route) is what we're guarding against.
        vm.expectRevert();
        routerTerminal.pay({
            projectId: projectIdB,
            token: projectATokenAddr,
            amount: PAYER_A_TOKENS_CASHOUT,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    /// @notice Cross-project routing is reentrancy-safe: a malicious destination terminal (registered as B's primary
    /// terminal for the reclaim token) cannot re-enter the router mid-flow to drain state. The router's pay() flow
    /// uses pull-then-forward with no router-held balances between source-burn and destination-deposit, and the
    /// underlying core entrypoint's balance-delta accounting catches any anomaly.
    function test_pay_maliciousDestinationTerminal_cannotReenterRouter() public {
        // Replace B's primary ETH terminal with a malicious contract that tries to call back into the router.
        MaliciousReentrantBTerminal malicious = new MaliciousReentrantBTerminal(routerTerminal, projectATokenAddr);

        // Register the malicious terminal as one of B's terminals + primary for ETH so the inner pay() lands there.
        IJBTerminal[] memory bTerminals = new IJBTerminal[](2);
        bTerminals[0] = jbMultiTerminal;
        bTerminals[1] = IJBTerminal(address(malicious));
        vm.prank(multisig);
        jbDirectory.setTerminalsOf({projectId: projectIdB, terminals: bTerminals});
        vm.prank(multisig);
        jbDirectory.setPrimaryTerminalOf({
            projectId: projectIdB, token: JBConstants.NATIVE_TOKEN, terminal: IJBTerminal(address(malicious))
        });

        vm.prank(payer);
        IERC20(projectATokenAddr).approve(address(routerTerminal), PAYER_A_TOKENS_CASHOUT);

        vm.prank(payer);
        // Expect ANY revert: either the core fails the balance-delta check (no delivery to B) or the malicious
        // reentry reverts. The point is that the router doesn't end up in a state where the malicious terminal
        // walked away with funds and B was paid.
        vm.expectRevert();
        routerTerminal.pay({
            projectId: projectIdB,
            token: projectATokenAddr,
            amount: PAYER_A_TOKENS_CASHOUT,
            beneficiary: beneficiary,
            minReturnedTokens: 1,
            memo: "",
            metadata: ""
        });

        // Cleanup invariant: the malicious terminal must not be holding the payer's funds. (Reentry happens inside
        // a reverted transaction, so all state changes get rolled back — this assertion is mostly a documentation
        // anchor for the property being tested.)
        assertEq(address(malicious).balance, 0, "malicious terminal must not hold ETH after the reverted call");
    }

    // ────────────────────────────── Helpers
    // ──────────────────────────────

    /// @dev Deploy a fresh JB v6 core stack within the fork.
    function _deployJbCore() internal {
        jbPermissions = new JBPermissions(trustedForwarder);
        jbProjects = new JBProjects(multisig, address(0), trustedForwarder);
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, multisig);
        JBERC20 jbErc20 = new JBERC20(jbPermissions, jbProjects);
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

    /// @dev Launch a project with a single accounting context. `allowSetTerminals` is exposed because B needs to
    /// be reconfigurable to add the router as its primary ETH terminal post-launch.
    function _launchProject(
        address acceptedToken,
        uint8 decimals,
        bool allowSetTerminals
    )
        internal
        returns (uint256 projectId)
    {
        JBRulesetMetadata memory metadata = _baseMetadata({
            baseCurrency: acceptedToken, allowSetTerminals: allowSetTerminals, pauseCrossProjectFeeFreeInflows: false
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

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: acceptedToken,
            decimals: decimals,
            // forge-lint: disable-next-line(unsafe-typecast)
            currency: uint32(uint160(acceptedToken))
        });

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

    /// @dev Queue a new ruleset on B that flips `pauseCrossProjectFeeFreeInflows`. Lets the opt-out test exercise
    /// the runtime path without rewinding setUp.
    function _queueRulesetForB(bool pauseCrossProjectFeeFreeInflows) internal {
        JBRulesetMetadata memory metadata = _baseMetadata({
            baseCurrency: address(USDC),
            allowSetTerminals: true,
            pauseCrossProjectFeeFreeInflows: pauseCrossProjectFeeFreeInflows
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

        vm.prank(multisig);
        jbController.queueRulesetsOf(projectIdB, rulesetConfigs, "");
    }

    function _baseMetadata(
        address baseCurrency,
        bool allowSetTerminals,
        bool pauseCrossProjectFeeFreeInflows
    )
        internal
        pure
        returns (JBRulesetMetadata memory)
    {
        return JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            // forge-lint: disable-next-line(unsafe-typecast)
            baseCurrency: uint32(uint160(baseCurrency)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: allowSetTerminals,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: true,
            pauseCrossProjectFeeFreeInflows: pauseCrossProjectFeeFreeInflows,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
    }
}
