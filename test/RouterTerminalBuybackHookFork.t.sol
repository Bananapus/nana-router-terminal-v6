// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

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
import {IJBPriceFeed} from "@bananapus/core-v6/src/interfaces/IJBPriceFeed.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath as V4TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";
import {JBBuybackHook} from "@bananapus/buyback-hook-v6/src/JBBuybackHook.sol";
import {IGeomeanOracle} from "@bananapus/univ4-router-v6/src/interfaces/IGeomeanOracle.sol";

contract BuybackForkLiquidityHelper is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable POOL_MANAGER;

    struct AddLiqParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    constructor(IPoolManager poolManager_) {
        POOL_MANAGER = poolManager_;
    }

    function addLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    )
        external
        payable
    {
        POOL_MANAGER.unlock(
            abi.encode(
                AddLiqParams({key: key, tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta})
            )
        );
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "only PM");

        AddLiqParams memory params = abi.decode(data, (AddLiqParams));
        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
            params.key,
            ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        _settleIfNegative(params.key.currency0, delta.amount0());
        _settleIfNegative(params.key.currency1, delta.amount1());
        _takeIfPositive(params.key.currency0, delta.amount0());
        _takeIfPositive(params.key.currency1, delta.amount1());

        return abi.encode(delta);
    }

    function _settleIfNegative(Currency currency, int128 delta) internal {
        if (delta >= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = uint256(uint128(-delta));

        if (currency.isAddressZero()) {
            POOL_MANAGER.settle{value: amount}();
        } else {
            POOL_MANAGER.sync(currency);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(Currency.unwrap(currency)).transfer(address(POOL_MANAGER), amount);
            POOL_MANAGER.settle();
        }
    }

    function _takeIfPositive(Currency currency, int128 delta) internal {
        if (delta <= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        // forge-lint: disable-next-line(unsafe-typecast)
        POOL_MANAGER.take(currency, address(this), uint256(uint128(delta)));
    }

    receive() external payable {}
}

/// @notice A fixed price feed.
contract FixedPriceFeed is IJBPriceFeed {
    uint256 internal immutable _PRICE;
    uint256 internal immutable _DECIMALS;

    constructor(uint256 price, uint256 decimals) {
        _PRICE = price;
        _DECIMALS = decimals;
    }

    function currentUnitPrice(uint256 decimals) external view override returns (uint256) {
        return decimals >= _DECIMALS ? _PRICE * 10 ** (decimals - _DECIMALS) : _PRICE / 10 ** (_DECIMALS - decimals);
    }
}

contract RouterTerminalBuybackHookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint256 internal constant BLOCK_NUMBER = 21_700_000;
    uint112 internal constant PROJECT_WEIGHT = 1e18;
    uint256 internal constant PAY_AMOUNT = 1 ether;
    uint256 internal constant LIQUIDITY_DELTA = 100 ether;
    int24 internal constant TICK_LOWER = -88_740;
    int24 internal constant TICK_UPPER = 88_740;
    int24 internal constant START_TICK = 46_000;

    IWETH9 internal constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IUniswapV3Factory internal constant V3_FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
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
    JBBuybackHook internal buybackHook;
    BuybackForkLiquidityHelper internal liqHelper;

    uint256 internal hookedProjectId;
    address internal hookedProjectToken;
    PoolKey internal buybackPoolKey;

    function setUp() public {
        vm.createSelectFork("ethereum", BLOCK_NUMBER);

        _deployJbCore();

        buybackHook =
            new JBBuybackHook(jbDirectory, jbPermissions, jbPrices, jbProjects, jbTokens, address(this), address(0));
        buybackHook.setChainSpecificConstants({newPoolManager: V4_POOL_MANAGER, newOracleHook: IHooks(address(0))});

        routerTerminal = new JBRouterTerminal({
            directory: jbDirectory,
            tokens: IJBTokens(address(jbTokens)),
            permit2: PERMIT2,
            buybackHook: address(buybackHook),
            trustedForwarder: address(0),
            deployer: address(this)
        });
        routerTerminal.setChainSpecificConstants({
            newWrappedNativeToken: WETH,
            newFactory: V3_FACTORY,
            newPoolManager: V4_POOL_MANAGER,
            newUniv4Hook: address(0)
        });

        liqHelper = new BuybackForkLiquidityHelper(V4_POOL_MANAGER);

        hookedProjectId = _launchHookedProject();

        vm.prank(multisig);
        hookedProjectToken = address(jbController.deployERC20For(hookedProjectId, "HookedProject", "HOOK", bytes32(0)));

        _seedBuybackPool();
        // forge-lint: disable-next-line(unsafe-typecast)
        _mockOracle(int256(LIQUIDITY_DELTA), START_TICK, 10 minutes);
        vm.deal(payer, 10 ether);
    }

    function test_fork_previewAndPay_routeToProjectUsingBuybackHook() public {
        uint256 directMintTokenCount = PAY_AMOUNT;
        bytes memory metadata = _buybackQuoteMetadata(0, 10 ether);

        (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory specs
        ) = routerTerminal.previewPayFor(hookedProjectId, JBConstants.NATIVE_TOKEN, PAY_AMOUNT, beneficiary, metadata);

        assertGt(ruleset.id, 0, "preview ruleset missing");
        assertEq(specs.length, 1, "expected buyback hook spec");
        assertEq(address(specs[0].hook), address(buybackHook), "wrong hook");
        assertGt(beneficiaryTokenCount, directMintTokenCount, "router did not surface buyback-improved preview");
        assertEq(reservedTokenCount, 0, "unexpected reserved tokens");

        uint256 balanceBefore = IERC20(hookedProjectToken).balanceOf(beneficiary);

        vm.prank(payer);
        uint256 minted = routerTerminal.pay{value: PAY_AMOUNT}({
            projectId: hookedProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: PAY_AMOUNT,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "buyback hook route",
            metadata: metadata
        });

        uint256 balanceAfter = IERC20(hookedProjectToken).balanceOf(beneficiary);

        assertEq(balanceAfter - balanceBefore, minted, "beneficiary balance mismatch");
        assertGt(minted, directMintTokenCount, "pay did not use buyback-favorable route");
    }

    function test_fork_previewAndPay_skipSplitsPreviewMatchesExecution() public {
        _queueReservedRuleset(5000);
        bytes memory splitMetadata = _buybackQuoteMetadata({amountToSwapWith: 0, minimumSwapAmountOut: 10 ether});
        bytes memory skipMetadata =
            _buybackQuoteMetadata({amountToSwapWith: 0, minimumSwapAmountOut: 10 ether, skipSplits: true});

        (, uint256 splitBeneficiaryTokenCount, uint256 splitReservedTokenCount,) = routerTerminal.previewPayFor(
            hookedProjectId, JBConstants.NATIVE_TOKEN, PAY_AMOUNT, beneficiary, splitMetadata
        );
        (, uint256 skipBeneficiaryTokenCount, uint256 skipReservedTokenCount,) = routerTerminal.previewPayFor(
            hookedProjectId, JBConstants.NATIVE_TOKEN, PAY_AMOUNT, beneficiary, skipMetadata
        );

        assertGt(splitReservedTokenCount, 0, "the 50% split should reserve part of the swap output");
        assertEq(skipReservedTokenCount, 0, "skip mode reserves nothing from an all-swap payment");
        assertEq(
            skipBeneficiaryTokenCount,
            splitBeneficiaryTokenCount + splitReservedTokenCount,
            "skip mode hands the whole swap output to the beneficiary"
        );

        // Execute both modes from the same pool state so the swap output is identical and only the split differs.
        uint256 snapshot = vm.snapshotState();
        uint256 reservedBefore = jbController.pendingReservedTokenBalanceOf(hookedProjectId);
        uint256 splitReceived = _payHooked(splitMetadata);
        uint256 splitReservedReceived = jbController.pendingReservedTokenBalanceOf(hookedProjectId) - reservedBefore;
        assertTrue(vm.revertToState(snapshot));
        uint256 skipReceived = _payHooked(skipMetadata);

        assertGt(splitReservedReceived, 0, "the split execution should reserve tokens");
        assertEq(
            skipReceived,
            splitReceived + splitReservedReceived,
            "skip execution must hand the split's beneficiary plus reserved output to the beneficiary"
        );
        assertGe(skipReceived, 10 ether, "the quoted floor must hold in skip mode");
    }

    function test_fork_previewAndPay_dustSwapDoesNotUnderstateDirectMint() public {
        _queueReservedRuleset(5000);
        // Nearly the whole payment mints directly; the swap leg is dust, so any rounding in the hook's swap-leg
        // figures would be amplified enormously if the direct leg were derived from them.
        bytes memory metadata = _buybackQuoteMetadata({amountToSwapWith: 3, minimumSwapAmountOut: 2, skipSplits: true});

        (, uint256 previewBeneficiaryTokenCount, uint256 previewReservedTokenCount,) =
            routerTerminal.previewPayFor(hookedProjectId, JBConstants.NATIVE_TOKEN, PAY_AMOUNT, beneficiary, metadata);
        uint256 reservedBefore = jbController.pendingReservedTokenBalanceOf(hookedProjectId);
        uint256 received = _payHooked(metadata);
        uint256 reserved = jbController.pendingReservedTokenBalanceOf(hookedProjectId) - reservedBefore;

        // Only the dust swap's own output, a few hundred wei of project token, can differ between quote and
        // execution. The defect this guards against understated the direct leg by a sixth of a token.
        assertApproxEqAbs(received, previewBeneficiaryTokenCount, 1000, "direct-mint beneficiary share understated");
        assertEq(reserved, previewReservedTokenCount, "direct-mint reserved share must match execution");
        assertGt(reserved, 0.49 ether, "half of the direct leg is reserved");
    }

    function test_fork_previewAndPay_fullReserveReservesWholeDirectMint() public {
        _queueReservedRuleset(10_000);
        bytes memory metadata =
            _buybackQuoteMetadata({amountToSwapWith: 0.1 ether, minimumSwapAmountOut: 1 ether, skipSplits: true});

        (, uint256 previewBeneficiaryTokenCount, uint256 previewReservedTokenCount,) =
            routerTerminal.previewPayFor(hookedProjectId, JBConstants.NATIVE_TOKEN, PAY_AMOUNT, beneficiary, metadata);
        uint256 reservedBefore = jbController.pendingReservedTokenBalanceOf(hookedProjectId);
        uint256 received = _payHooked(metadata);
        uint256 reserved = jbController.pendingReservedTokenBalanceOf(hookedProjectId) - reservedBefore;

        assertEq(reserved, 0.9 ether, "execution reserves the entire direct leg");
        assertEq(previewReservedTokenCount, reserved, "preview must reserve the entire direct leg too");
        assertGe(previewBeneficiaryTokenCount, 1 ether, "the swap floor is scored for the beneficiary");
        assertGe(received, 1 ether, "the swap floor holds at execution");
    }

    /// @notice Pay the hooked project through the router and return what the beneficiary actually received.
    function _payHooked(bytes memory metadata) internal returns (uint256 received) {
        uint256 balanceBefore = IERC20(hookedProjectToken).balanceOf(beneficiary);
        vm.prank(payer);
        received = routerTerminal.pay{value: PAY_AMOUNT}({
            projectId: hookedProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: PAY_AMOUNT,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "buyback hook",
            metadata: metadata
        });
        assertEq(IERC20(hookedProjectToken).balanceOf(beneficiary) - balanceBefore, received, "balance mismatch");
    }

    function _deployJbCore() internal {
        jbPermissions = new JBPermissions(address(0));
        jbProjects = new JBProjects(multisig, address(0), address(0));
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, multisig);
        JBERC20 jbErc20 = new JBERC20(jbPermissions, jbProjects);
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

    function _hookedRulesetConfigs(uint16 reservedPercent)
        internal
        view
        returns (JBRulesetConfig[] memory rulesetConfigs)
    {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: reservedPercent,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: true,
            useDataHookForCashOut: false,
            dataHook: address(buybackHook),
            metadata: 0
        });

        rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 0,
            weight: PROJECT_WEIGHT,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: metadata,
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });
    }

    /// @notice Replace the project's current duration-less ruleset so a reserved split applies immediately.
    function _queueReservedRuleset(uint16 reservedPercent) internal {
        vm.prank(multisig);
        jbController.queueRulesetsOf({
            projectId: hookedProjectId, rulesetConfigurations: _hookedRulesetConfigs(reservedPercent), memo: ""
        });
        (JBRuleset memory current, JBRulesetMetadata memory currentMetadata) =
            jbController.currentRulesetOf(hookedProjectId);
        assertGt(current.id, 0, "no current ruleset");
        assertEq(currentMetadata.reservedPercent, reservedPercent, "reserved ruleset is not current");
    }

    function _launchHookedProject() internal returns (uint256 projectId) {
        JBRulesetConfig[] memory rulesetConfigs = _hookedRulesetConfigs(0);

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});

        projectId = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "router-buyback-fork",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    function _seedBuybackPool() internal {
        address terminalToken = address(0);
        (address currency0, address currency1) = terminalToken < hookedProjectToken
            ? (terminalToken, hookedProjectToken)
            : (hookedProjectToken, terminalToken);

        buybackPoolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        V4_POOL_MANAGER.initialize(buybackPoolKey, V4TickMath.getSqrtPriceAtTick(START_TICK));

        vm.prank(multisig);
        jbController.mintTokensOf({
            projectId: hookedProjectId,
            tokenCount: 10_000 ether,
            beneficiary: address(liqHelper),
            memo: "",
            useReservedPercent: false
        });

        vm.deal(address(liqHelper), 20 ether);
        vm.prank(address(liqHelper));
        IERC20(hookedProjectToken).approve(address(V4_POOL_MANAGER), type(uint256).max);

        vm.prank(address(liqHelper));
        // forge-lint: disable-next-line(unsafe-typecast)
        liqHelper.addLiquidity{value: 20 ether}(buybackPoolKey, TICK_LOWER, TICK_UPPER, int256(LIQUIDITY_DELTA));

        vm.prank(multisig);
        buybackHook.setPoolFor(hookedProjectId, buybackPoolKey, 10 minutes, JBConstants.NATIVE_TOKEN);
    }

    function _buybackQuoteMetadata(
        uint256 amountToSwapWith,
        uint256 minimumSwapAmountOut
    )
        internal
        view
        returns (bytes memory metadata)
    {
        return _buybackQuoteMetadata({
            amountToSwapWith: amountToSwapWith, minimumSwapAmountOut: minimumSwapAmountOut, skipSplits: false
        });
    }

    function _buybackQuoteMetadata(
        uint256 amountToSwapWith,
        uint256 minimumSwapAmountOut,
        bool skipSplits
    )
        internal
        view
        returns (bytes memory metadata)
    {
        return JBMetadataResolver.addToMetadata(
            "",
            JBMetadataResolver.getId("pay", address(buybackHook)),
            abi.encode(amountToSwapWith, minimumSwapAmountOut, skipSplits)
        );
    }

    function _mockOracle(int256 liquidity, int24 tick, uint32 twapWindow) internal {
        vm.etch(address(0), hex"00");

        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        tickCumulatives[1] = int56(tick) * int56(int32(twapWindow));

        uint160[] memory secondsPerLiquidityCumulativeX128s = new uint160[](2);
        secondsPerLiquidityCumulativeX128s[0] = 0;

        uint256 liq = uint256(liquidity > 0 ? liquidity : -liquidity);
        if (liq == 0) liq = 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        secondsPerLiquidityCumulativeX128s[1] = uint160((uint256(twapWindow) << 128) / liq);

        vm.mockCall(
            address(0), abi.encodeWithSelector(IGeomeanOracle.hasObservationCoverage.selector), abi.encode(true)
        );
        vm.mockCall(
            address(0), abi.encodeWithSelector(IGeomeanOracle.observationCoverageOf.selector), abi.encode(twapWindow)
        );

        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IGeomeanOracle.observe.selector),
            abi.encode(tickCumulatives, secondsPerLiquidityCumulativeX128s)
        );
    }

    //*********************************************************************//
    // ------------------ buyback hook 1.5 route scoring ----------------- //
    //*********************************************************************//

    /// @notice Replace the 1.4 hook under test with buyback hook 1.5 at the same address. The fixture is the 1.5 hook's
    /// creation bytecode (nana-buyback-hook-v6#181), so this repo's resolver runs against it without compiling its
    /// source. It is deployed with the same constructor arguments and its runtime code etched over the 1.4 hook, so the
    /// router's immutable `BUYBACK_HOOK` and the hook's storage (same layout in both versions) carry over.
    function _useBuybackHook15() internal {
        address hook15 = deployCode(
            "test/fixtures/JBBuybackHook-1.5.0.json",
            abi.encode(jbDirectory, jbPermissions, jbPrices, jbProjects, jbTokens, address(this), address(0))
        );
        vm.etch(address(buybackHook), hook15.code);
    }

    /// @notice A no-quote ETH pay's router preview and the tokens it settles.
    function _previewAndSettleNoQuote(uint256 amount) internal returns (uint256 preview, uint256 received) {
        (, preview,,) = routerTerminal.previewPayFor(hookedProjectId, JBConstants.NATIVE_TOKEN, amount, beneficiary, "");
        uint256 snapshot = vm.snapshotState();
        uint256 balanceBefore = IERC20(hookedProjectToken).balanceOf(beneficiary);
        vm.prank(payer);
        routerTerminal.pay{value: amount}({
            projectId: hookedProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        received = IERC20(hookedProjectToken).balanceOf(beneficiary) - balanceBefore;
        assertTrue(vm.revertToState(snapshot));
    }

    /// @notice A no-quote pay the sigmoid floor routes settles the same under both hooks. The 1.4 preview scores the
    /// fee- and impact-free raw quote; the 1.5 preview scores the hook's expected settlement, which it delivers.
    function test_fork_buyback15_previewMatchesSigmoidRouteSettlement() public {
        (uint256 preview14, uint256 received14) = _previewAndSettleNoQuote(PAY_AMOUNT);
        _useBuybackHook15();
        (uint256 preview15, uint256 received15) = _previewAndSettleNoQuote(PAY_AMOUNT);

        emit log_named_decimal_uint("1.4 preview", preview14, 18);
        emit log_named_decimal_uint("1.5 preview", preview15, 18);
        emit log_named_decimal_uint("settled", received15, 18);
        assertEq(received15, received14, "the sigmoid route is unchanged");
        assertGt(preview14, received14 * 105 / 100, "1.4 overstates the route");
        assertApproxEqRel(preview15, received15, 0.001e18, "1.5 previews what the pay settles");
    }

    /// @notice An 8 ETH no-quote pay at 50 tokens per ETH of issuance is larger than the pool can take above issuance.
    /// Hook 1.4 mints it; 1.5 swaps to the issuance-rate price limit, mints the rest, and previews that settlement.
    function test_fork_buyback15_previewMatchesPartialFillSettlement() public {
        JBRulesetConfig[] memory rulesetConfigs = _hookedRulesetConfigs(0);
        rulesetConfigs[0].weight = 50e18;
        vm.prank(multisig);
        jbController.queueRulesetsOf({projectId: hookedProjectId, rulesetConfigurations: rulesetConfigs, memo: ""});

        (, uint256 received14) = _previewAndSettleNoQuote(8 ether);
        _useBuybackHook15();
        (uint256 preview15, uint256 received15) = _previewAndSettleNoQuote(8 ether);

        emit log_named_decimal_uint("1.4 settled", received14, 18);
        emit log_named_decimal_uint("1.5 preview", preview15, 18);
        emit log_named_decimal_uint("1.5 settled", received15, 18);
        assertEq(received14, 400 ether, "1.4 mints");
        assertGt(received15, 460 ether, "1.5 swaps to the price limit and mints the rest");
        assertApproxEqRel(preview15, received15, 0.001e18, "1.5 previews what the pay settles");
    }

    /// @notice The project also accepts USDC, priced so a USDC-routed ETH pay mints about 95 tokens per ETH: below the
    /// 1.4 hook's raw ETH-pool quote (about 99.5) but above what the ETH pool settles (about 90.2). The 1.4 hook makes
    /// the router rank the thin ETH pool first; the 1.5 hook's published settlement makes it pick USDC, which pays
    /// more.
    function test_fork_buyback15_ranksRoutesBySettlement() public {
        IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        uint32 usdcCurrency = uint32(uint160(address(usdc)));
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: address(usdc), decimals: 6, currency: usdcCurrency});
        vm.prank(multisig);
        jbMultiTerminal.addAccountingContextsFor(hookedProjectId, contexts);
        uint256 usdcPerEth =
            routerTerminal.previewSwapAmountOutOf(JBConstants.NATIVE_TOKEN, address(usdc), PAY_AMOUNT, "");
        IJBPriceFeed feed = new FixedPriceFeed(usdcPerEth / 95, 6);
        vm.prank(multisig);
        jbPrices.addPriceFeedFor({
            projectId: 0,
            pricingCurrency: usdcCurrency,
            unitCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            feed: feed
        });

        (, uint256 preview14,, JBPayHookSpecification[] memory specs14) =
            routerTerminal.previewPayFor(hookedProjectId, JBConstants.NATIVE_TOKEN, PAY_AMOUNT, beneficiary, "");
        _useBuybackHook15();
        (, uint256 preview15,, JBPayHookSpecification[] memory specs15) =
            routerTerminal.previewPayFor(hookedProjectId, JBConstants.NATIVE_TOKEN, PAY_AMOUNT, beneficiary, "");

        uint256 viaEth = _payVia(JBConstants.NATIVE_TOKEN);
        uint256 viaUsdc = _payVia(address(usdc));
        emit log_named_decimal_uint("1.4 best preview", preview14, 18);
        emit log_named_decimal_uint("1.5 best preview", preview15, 18);
        emit log_named_decimal_uint("settled via the ETH pool", viaEth, 18);
        emit log_named_decimal_uint("settled via USDC", viaUsdc, 18);

        assertEq(specs14.length, 1, "1.4 ranks the ETH pool route first");
        assertEq(address(specs14[0].hook), address(buybackHook), "1.4 ranks the ETH pool route first");
        assertEq(specs15.length, 0, "1.5 ranks the USDC route first");
        assertGt(viaUsdc, viaEth, "the USDC route pays more");
        assertGt(preview14, viaUsdc, "1.4 scored the ETH pool above what USDC pays");
        // The router previews the USDC leg's swap conservatively, so the USDC route settles a little above its 95-token
        // preview.
        assertApproxEqRel(preview15, 95e18, 0.001e18, "1.5 previews the USDC route");
    }

    /// @notice Pay 1 ETH routed to `tokenOut` and return the beneficiary's tokens, leaving state unchanged.
    function _payVia(address tokenOut) internal returns (uint256 received) {
        uint256 snapshot = vm.snapshotState();
        uint256 balanceBefore = IERC20(hookedProjectToken).balanceOf(beneficiary);
        vm.prank(payer);
        routerTerminal.pay{value: PAY_AMOUNT}({
            projectId: hookedProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: PAY_AMOUNT,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: JBMetadataResolver.addToMetadata(
                "", JBMetadataResolver.getId("routeTokenOut", address(routerTerminal)), abi.encode(tokenOut)
            )
        });
        received = IERC20(hookedProjectToken).balanceOf(beneficiary) - balanceBefore;
        assertTrue(vm.revertToState(snapshot));
    }
}
