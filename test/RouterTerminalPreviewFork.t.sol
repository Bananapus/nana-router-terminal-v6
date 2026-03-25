// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {JBController} from "@bananapus/core-v6/src/JBController.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
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
import {JBERC20} from "@bananapus/core-v6/src/JBERC20.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract RouterTerminalPreviewForkTest is Test {
    uint256 internal constant BLOCK_NUMBER = 21_700_000;
    bytes32 internal constant _PAY_EVENT_SIGNATURE =
        keccak256("Pay(uint256,uint256,uint256,address,address,uint256,uint256,string,bytes,address)");

    IWETH9 internal constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 internal constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IUniswapV3Factory internal constant V3_FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolManager internal constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    address internal multisig = address(0xBEEF);
    address internal payer = makeAddr("payer");
    address internal beneficiary = makeAddr("beneficiary");

    JBPermissions internal jbPermissions;
    JBProjects internal jbProjects;
    JBDirectory internal jbDirectory;
    JBRulesets internal jbRulesets;
    JBTokens internal jbTokens;
    JBSplits internal jbSplits;
    JBPrices internal jbPrices;
    JBFundAccessLimits internal jbFundAccessLimits;
    JBFeelessAddresses internal jbFeelessAddresses;
    JBController internal jbController;
    JBTerminalStore internal jbTerminalStore;
    JBMultiTerminal internal jbMultiTerminal;
    JBRouterTerminal internal routerTerminal;

    uint256 internal feeProjectId;
    uint256 internal ethProjectId;
    uint256 internal usdcProjectId;

    function setUp() public {
        vm.createSelectFork("ethereum", BLOCK_NUMBER);

        _deployJbCore();

        routerTerminal = new JBRouterTerminal({
            directory: jbDirectory,
            permissions: IJBPermissions(address(jbPermissions)),
            projects: IJBProjects(address(jbProjects)),
            tokens: IJBTokens(address(jbTokens)),
            permit2: PERMIT2,
            owner: multisig,
            weth: WETH,
            factory: V3_FACTORY,
            poolManager: V4_POOL_MANAGER,
            trustedForwarder: address(0)
        });

        feeProjectId = _launchProject(JBConstants.NATIVE_TOKEN, 18, 0);
        ethProjectId = _launchProject(JBConstants.NATIVE_TOKEN, 18, 0);
        usdcProjectId = _launchProject(address(USDC), 6, 0);
    }

    function test_fork_previewPayForMatchesDirectPay() public {
        uint256 amountIn = 1 ether;

        (
            uint256 previewRulesetId,
            uint256 previewCycleNumber,
            uint256 previewTokenCount,
            uint256 previewReservedTokenCount,
            uint256 specCount
        ) = _previewPayFor(ethProjectId, JBConstants.NATIVE_TOKEN, amountIn, beneficiary, "");
        assertGt(previewTokenCount, 0, "preview minted no beneficiary tokens");
        assertEq(previewReservedTokenCount, 0, "unexpected reserved token preview");
        assertEq(specCount, 0, "unexpected hook specs");

        vm.deal(payer, amountIn);

        vm.recordLogs();
        vm.prank(payer);
        uint256 mintedTokenCount = routerTerminal.pay{value: amountIn}({
            projectId: ethProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "preview parity direct",
            metadata: ""
        });

        (uint256 rulesetId, uint256 cycleNumber, uint256 eventTokenCount) = _payEventData();
        assertEq(mintedTokenCount, previewTokenCount, "preview beneficiary token count mismatch");
        assertEq(eventTokenCount, previewTokenCount, "pay event token count mismatch");
        assertEq(rulesetId, previewRulesetId, "preview ruleset id mismatch");
        assertEq(cycleNumber, previewCycleNumber, "preview cycle number mismatch");
    }

    function test_fork_previewPayForMatchesDirectUsdcPay() public {
        uint256 amountIn = 1000e6;

        (
            uint256 previewRulesetId,
            uint256 previewCycleNumber,
            uint256 previewTokenCount,
            uint256 previewReservedTokenCount,
            uint256 specCount
        ) = _previewPayFor(usdcProjectId, address(USDC), amountIn, beneficiary, "");
        assertGt(previewTokenCount, 0, "preview minted no beneficiary tokens");
        assertEq(previewReservedTokenCount, 0, "unexpected reserved token preview");
        assertEq(specCount, 0, "unexpected hook specs");

        vm.startPrank(payer);
        deal(address(USDC), payer, amountIn);
        USDC.approve(address(routerTerminal), amountIn);
        vm.recordLogs();
        uint256 mintedTokenCount = routerTerminal.pay({
            projectId: usdcProjectId,
            token: address(USDC),
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "preview parity direct usdc",
            metadata: ""
        });
        vm.stopPrank();

        (uint256 rulesetId, uint256 cycleNumber, uint256 eventTokenCount) = _payEventData();
        assertEq(mintedTokenCount, previewTokenCount, "preview beneficiary token count mismatch");
        assertEq(eventTokenCount, previewTokenCount, "pay event token count mismatch");
        assertEq(rulesetId, previewRulesetId, "preview ruleset id mismatch");
        assertEq(cycleNumber, previewCycleNumber, "preview cycle number mismatch");
    }

    function test_fork_previewPayForEstimatesEthToUsdcSwapRoute() public view {
        uint256 amountIn = 1 ether;

        (
            uint256 previewRulesetId,
            uint256 previewCycleNumber,
            uint256 previewTokenCount,
            uint256 previewReservedTokenCount,
            uint256 specCount
        ) = _previewPayFor(usdcProjectId, JBConstants.NATIVE_TOKEN, amountIn, beneficiary, "");

        assertGt(previewRulesetId, 0, "preview ruleset id missing");
        assertGt(previewCycleNumber, 0, "preview cycle number missing");
        assertGt(previewTokenCount, 0, "swap preview minted no beneficiary tokens");
        assertEq(previewReservedTokenCount, 0, "unexpected reserved token preview");
        assertEq(specCount, 0, "unexpected hook specs");
    }

    function test_fork_previewPayForEstimatesUsdcToEthSwapRoute() public view {
        uint256 amountIn = 1000e6;

        (
            uint256 previewRulesetId,
            uint256 previewCycleNumber,
            uint256 previewTokenCount,
            uint256 previewReservedTokenCount,
            uint256 specCount
        ) = _previewPayFor(ethProjectId, address(USDC), amountIn, beneficiary, "");

        assertGt(previewRulesetId, 0, "preview ruleset id missing");
        assertGt(previewCycleNumber, 0, "preview cycle number missing");
        assertGt(previewTokenCount, 0, "swap preview minted no beneficiary tokens");
        assertEq(previewReservedTokenCount, 0, "unexpected reserved token preview");
        assertEq(specCount, 0, "unexpected hook specs");
    }

    function _previewPayFor(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary_,
        bytes memory metadata
    )
        internal
        view
        returns (
            uint256 rulesetId,
            uint256 cycleNumber,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            uint256 specCount
        )
    {
        JBRuleset memory ruleset;
        JBPayHookSpecification[] memory specs;
        (ruleset, beneficiaryTokenCount, reservedTokenCount, specs) = routerTerminal.previewPayFor({
            projectId: projectId, token: token, amount: amount, beneficiary: beneficiary_, metadata: metadata
        });

        return (ruleset.id, ruleset.cycleNumber, beneficiaryTokenCount, reservedTokenCount, specs.length);
    }

    function _payEventData() internal view returns (uint256 rulesetId, uint256 cycleNumber, uint256 tokenCount) {
        Vm.Log[] memory entries = vm.getRecordedLogs();

        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter != address(jbMultiTerminal)) continue;
            if (entries[i].topics.length == 0 || entries[i].topics[0] != _PAY_EVENT_SIGNATURE) continue;

            rulesetId = uint256(entries[i].topics[1]);
            cycleNumber = uint256(entries[i].topics[2]);
            (,,, tokenCount,,,) =
                abi.decode(entries[i].data, (address, address, uint256, uint256, string, bytes, address));
            return (rulesetId, cycleNumber, tokenCount);
        }

        revert("Pay event not found");
    }

    function _deployJbCore() internal {
        jbPermissions = new JBPermissions(address(0));
        jbProjects = new JBProjects(multisig, address(0), address(0));
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, multisig);
        JBERC20 jbErc20 = new JBERC20();
        jbTokens = new JBTokens(jbDirectory, jbErc20);
        jbRulesets = new JBRulesets(jbDirectory);
        jbPrices = new JBPrices(jbDirectory, jbPermissions, jbProjects, multisig, address(0));
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
            address(0)
        );

        vm.prank(multisig);
        jbDirectory.setIsAllowedToSetFirstController(address(jbController), true);

        jbTerminalStore = new JBTerminalStore(jbDirectory, jbPrices, jbRulesets);

        jbMultiTerminal = new JBMultiTerminal(
            jbFeelessAddresses, jbPermissions, jbProjects, jbSplits, jbTerminalStore, jbTokens, PERMIT2, address(0)
        );
    }

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
        rulesetConfigs[0].weight = 1_000_000e18;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] =
            JBAccountingContext({token: acceptedToken, decimals: decimals, currency: uint32(uint160(acceptedToken))});

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});

        projectId = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "preview-parity",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }
}
