// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

// JB core (deployed fresh within fork).
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

// Uniswap.
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

// Router terminal.
import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Mock: Fee-on-transfer ERC20 (burns a percentage per transfer).
// ──────────────────────────────────────────────────────────────────────────────

contract MockFoTToken {
    string public name = "FeeOnTransfer";
    string public symbol = "FOT";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Fee deducted per transfer (in basis points, e.g. 100 = 1%).
    uint256 public immutable feePercent;

    constructor(uint256 _feePercent) {
        feePercent = _feePercent;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        uint256 fee = (amount * feePercent) / 10_000;
        uint256 received = amount - fee;
        balanceOf[to] += received;
        totalSupply -= fee; // fee is burned
        emit Transfer(msg.sender, to, received);
        if (fee > 0) emit Transfer(msg.sender, address(0), fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        uint256 fee = (amount * feePercent) / 10_000;
        uint256 received = amount - fee;
        balanceOf[to] += received;
        totalSupply -= fee; // fee is burned
        emit Transfer(from, to, received);
        if (fee > 0) emit Transfer(from, address(0), fee);
        return true;
    }

    event Transfer(address indexed from, address indexed to, uint256 value);
}

/// @notice Fork tests for fee-on-transfer tokens through the router terminal.
/// @dev Verifies that `pay` accepts the terminal-side fee loss, while `addToBalanceOf` rejects it with receipt
///      enforcement.
///
///      The router's `_acceptFundsFor` uses balance-delta to capture the actual received amount
///      (handles the first transfer fee). However, the second transfer (router → terminal) can also incur a fee.
///
///      FOT tokens are not supported for routed payments because the terminal may receive fewer tokens than `amount`.
contract RouterTerminalFOTForkTest is Test {
    uint256 constant BLOCK_NUMBER = 21_700_000;

    IWETH9 constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV3Factory constant V3_FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    address multisig = address(0xBEEF);
    address payer = makeAddr("payer");
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

    MockFoTToken fotToken;
    uint256 feeProjectId;
    uint256 fotProjectId;

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
            newWrappedNativeToken: WETH,
            newFactory: V3_FACTORY,
            newPoolManager: V4_POOL_MANAGER,
            newUniv4Hook: address(0)
        });

        // Deploy mock FOT token (1% fee per transfer).
        fotToken = new MockFoTToken(100);

        // Fee project.
        feeProjectId = _launchProject(JBConstants.NATIVE_TOKEN, 18);

        // Project that accepts the FOT token.
        fotProjectId = _launchProject(address(fotToken), 18);

        vm.label(address(fotToken), "FOT");
        vm.label(address(routerTerminal), "RouterTerminal");
        vm.label(address(jbMultiTerminal), "JBMultiTerminal");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // FOT: Direct forward (no swap) — router pays project that accepts FOT
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The pay path does not enforce ERC-20 receipt checks because pay hooks may legitimately consume tokens.
    ///         FOT direct forwarding succeeds silently, and the terminal receives fewer tokens than `amount`.
    ///
    ///         Flow: payer sends 10,000 FOT → router receives 9,900 (1% fee) →
    ///               router approves terminal for 9,900 → terminal pulls 9,900 from router →
    ///               terminal receives 9,801 (1% fee) → NO receipt check → succeeds.
    function test_fork_fotDirectForward_succeedsSilently() public {
        uint256 amount = 10_000e18;
        fotToken.mint(payer, amount);

        vm.startPrank(payer);
        fotToken.approve(address(routerTerminal), amount);

        // The pay path does not enforce receipt checks, so this succeeds.
        routerTerminal.pay({
            projectId: fotProjectId,
            token: address(fotToken),
            amount: amount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "FOT direct forward",
            metadata: ""
        });
        vm.stopPrank();
    }

    /// @notice FOT addToBalanceOf reverts when the final terminal receives less than the routed amount.
    function test_fork_fotAddToBalance_reverts() public {
        uint256 amount = 5000e18;
        fotToken.mint(payer, amount);

        vm.startPrank(payer);
        fotToken.approve(address(routerTerminal), amount);

        uint256 expectedAmount = amount - (amount * fotToken.feePercent()) / 10_000;
        uint256 actualAmount = expectedAmount - (expectedAmount * fotToken.feePercent()) / 10_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminal.JBRouterTerminal_NonStandardTerminalToken.selector,
                address(jbMultiTerminal),
                address(fotToken),
                expectedAmount,
                actualAmount
            )
        );
        routerTerminal.addToBalanceOf({
            projectId: fotProjectId,
            token: address(fotToken),
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "FOT add to balance",
            metadata: ""
        });
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Standard ERC20: Direct forward works (control test)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Standard (non-FOT) ERC20 direct forward succeeds — proves the test
    ///         infrastructure is correct and only FOT causes the revert.
    function test_fork_standardDirectForward_succeeds() public {
        uint256 amount = 1 ether;

        vm.deal(payer, amount);
        vm.prank(payer);
        uint256 tokenCount = routerTerminal.pay{value: amount}({
            projectId: feeProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "standard ETH direct forward",
            metadata: ""
        });

        assertGt(tokenCount, 0, "standard token should mint");
        assertEq(address(routerTerminal).balance, 0, "router should have no leftover ETH");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // FOT: ETH payment to FOT-accepting project (swap path)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Paying ETH to a project that only accepts FOT reverts because
    ///         no Uniswap pool exists for ETH/FOT.
    /// @dev Bare expectRevert here: the specific error varies by route discovery path
    ///      (NoPoolFound vs NoRouteFound) depending on internal resolver logic.
    function test_fork_fotSwapPath_noPoolReverts() public {
        uint256 amount = 1 ether;

        vm.deal(payer, amount);
        vm.prank(payer);
        vm.expectRevert();
        routerTerminal.pay{value: amount}({
            projectId: fotProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "ETH to FOT project - no pool",
            metadata: ""
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal helpers
    // ═══════════════════════════════════════════════════════════════════════

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
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: true,
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
}
