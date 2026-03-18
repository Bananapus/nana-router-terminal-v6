// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";

// JB core (deploy fresh within fork — same pattern as RouterTerminalSandwichFork.t.sol).
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

// Uniswap V3.
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

// Uniswap V4.
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath as V4TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Permit2.
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

// OpenZeppelin.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Router terminal.
import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

//*********************************************************************//
// ----------------------------- Helpers ----------------------------- //
//*********************************************************************//

/// @notice Helper that adds liquidity to a V4 pool.
contract V4LiquidityHelper is IUnlockCallback {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IPoolManager public immutable poolManager;

    struct AddLiqParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
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
        // forge-lint: disable-next-line(named-struct-fields)
        poolManager.unlock(abi.encode(AddLiqParams(key, tickLower, tickUpper, liquidityDelta)));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "only PM");
        AddLiqParams memory params = abi.decode(data, (AddLiqParams));

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            params.key,
            ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        _settleIfNegative(params.key.currency0, callerDelta.amount0());
        _settleIfNegative(params.key.currency1, callerDelta.amount1());
        _takeIfPositive(params.key.currency0, callerDelta.amount0());
        _takeIfPositive(params.key.currency1, callerDelta.amount1());

        return abi.encode(callerDelta);
    }

    function _settleIfNegative(Currency currency, int128 delta) internal {
        if (delta >= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = uint256(uint128(-delta));
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(Currency.unwrap(currency)).transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _takeIfPositive(Currency currency, int128 delta) internal {
        if (delta <= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        poolManager.take(currency, address(this), uint256(uint128(delta)));
    }

    receive() external payable {}
}

/// @notice Stub V3 factory that always returns address(0) for all pools.
///         Deploying the router terminal with this factory forces all swaps through V4.
contract NoV3PoolFactory {
    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

//*********************************************************************//
// ----------------------------- Tests ------------------------------- //
//*********************************************************************//

/// @title V4QuoteAndSettlementForkTest
/// @notice Fork tests proving V4 quote ordering and WETH settlement correctness.
///
///         The V4 pool uses address(0) for native ETH. The quote function must use address(0)
///         (not WETH) when calling OracleLibrary.getQuoteAtTick so that token sorting matches
///         the V4 pool's currency order. Additionally, when the user pays with WETH ERC-20 and
///         the V4 pool uses address(0) for ETH, the settlement must unwrap WETH before calling
///         settle{value:...}().
///
///         A stub V3 factory is used to ensure all swaps route through V4.
///
///         Run with: forge test --match-contract V4QuoteAndSettlementForkTest -vvv --skip "script/*"
///         Requires RPC_ETHEREUM_MAINNET in .env
contract V4QuoteAndSettlementForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    //*********************************************************************//
    // ----------------------------- constants --------------------------- //
    //*********************************************************************//

    uint256 constant BLOCK_NUMBER = 21_700_000;

    IWETH9 constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IUniswapV3Factory constant V3_FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    /// @notice WETH/USDC 0.05% V3 pool — used for baseline comparison in test 4.
    IUniswapV3Pool constant WETH_USDC_V3 = IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);

    /// @notice WETH/DAI 0.3% V3 pool — used for baseline comparison in test 4.
    IUniswapV3Pool constant WETH_DAI_V3 = IUniswapV3Pool(0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8);

    //*********************************************************************//
    // ----------------------------- JB core ----------------------------- //
    //*********************************************************************//

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

    /// @notice Router terminal deployed with a stub V3 factory to force V4 routing.
    JBRouterTerminal routerTerminal;

    V4LiquidityHelper v4LiqHelper;

    uint256 feeProjectId;
    uint256 usdcProjectId;
    uint256 daiProjectId;

    //*********************************************************************//
    // ----------------------------- V4 pool keys ------------------------ //
    //*********************************************************************//

    /// @dev V4 ETH/USDC pool key. currency0 = address(0) (native ETH), currency1 = USDC.
    /// address(0) < USDC address, so ETH is currency0.
    /// The quote ordering bug caused OracleLibrary to be called with WETH instead of address(0),
    /// flipping the tick direction for pairs where the counterpart sorts between address(0) and WETH.
    PoolKey v4EthUsdcKey;

    /// @dev V4 ETH/DAI pool key. currency0 = address(0) (native ETH), currency1 = DAI.
    PoolKey v4EthDaiKey;

    //*********************************************************************//
    // ----------------------------- setup ------------------------------- //
    //*********************************************************************//

    function setUp() public {
        vm.createSelectFork("ethereum", BLOCK_NUMBER);

        _deployJbCore();

        v4LiqHelper = new V4LiquidityHelper(V4_POOL_MANAGER);

        // Deploy the router terminal with a stub V3 factory. This ensures pool discovery
        // finds no V3 pools, forcing all swaps through V4 where the quote ordering fix applies.
        NoV3PoolFactory noV3Factory = new NoV3PoolFactory();
        routerTerminal = new JBRouterTerminal({
            directory: jbDirectory,
            permissions: jbPermissions,
            projects: jbProjects,
            tokens: jbTokens,
            permit2: PERMIT2,
            owner: multisig,
            weth: WETH,
            factory: IUniswapV3Factory(address(noV3Factory)),
            poolManager: V4_POOL_MANAGER,
            trustedForwarder: trustedForwarder
        });

        feeProjectId = _launchProject({acceptedToken: JBConstants.NATIVE_TOKEN, decimals: 18});
        usdcProjectId = _launchProject({acceptedToken: address(USDC), decimals: 6});
        daiProjectId = _launchProject({acceptedToken: address(DAI), decimals: 18});

        // Create and provision V4 pools.
        _setupV4EthUsdcPool();
        _setupV4EthDaiPool();

        vm.label(address(WETH), "WETH");
        vm.label(address(USDC), "USDC");
        vm.label(address(DAI), "DAI");
        vm.label(address(routerTerminal), "RouterTerminal");
        vm.label(address(jbMultiTerminal), "JBMultiTerminal");
        vm.label(payer, "payer");
    }

    //*********************************************************************//
    // --- Test 1: V4 ETH -> USDC swap succeeds (quote ordering) -------- //
    //*********************************************************************//

    /// @notice Pay ETH to a USDC-accepting project via the router terminal, routed through V4.
    ///         USDC address (0xA0b8...) sorts below WETH address (0xC02a...) but above address(0).
    ///         The V4 pool orders currencies as [address(0), USDC]. If the quote function incorrectly
    ///         used WETH instead of address(0), OracleLibrary would sort tokens as [USDC, WETH]
    ///         (flipped from the pool's actual [address(0), USDC] order), producing an inverted price.
    function test_fork_v4EthToUsdc_quoteOrderingCorrect() public {
        uint256 payAmount = 1 ether;

        // Provide a user quote to control slippage tolerance. We set minAmountOut to 1 USDC
        // to prove the swap executes; the assertions below verify the output is reasonable.
        bytes4 quoteId = JBMetadataResolver.getId("quoteForSwap", address(routerTerminal));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", quoteId, abi.encode(uint256(1e6)));

        vm.deal(payer, payAmount);
        vm.prank(payer);
        uint256 tokensMinted = routerTerminal.pay{value: payAmount}({
            projectId: usdcProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "V4 ETH->USDC quote ordering test",
            metadata: metadata
        });

        // Verify tokens were minted.
        assertGt(tokensMinted, 0, "Should mint project tokens");

        // Verify USDC arrived in the terminal.
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 terminalUsdcBalance = jbTerminalStore.balanceOf(address(jbMultiTerminal), usdcProjectId, address(USDC));
        assertGt(terminalUsdcBalance, 0, "Terminal should hold USDC");

        // Sanity: USDC amount should be in the right ballpark for 1 ETH (~2000-4000 USDC at block 21.7M).
        // An inverted price would give a value many orders of magnitude off.
        assertGt(terminalUsdcBalance, 100e6, "USDC amount should be reasonable (> $100 for 1 ETH)");
        assertLt(terminalUsdcBalance, 100_000e6, "USDC amount should be reasonable (< $100k for 1 ETH)");

        // Verify no leftover WETH stuck in the router terminal.
        assertEq(IERC20(address(WETH)).balanceOf(address(routerTerminal)), 0, "No leftover WETH in router");
        assertEq(address(routerTerminal).balance, 0, "No leftover ETH in router");

        console.log("V4 ETH->USDC: %s tokens minted, %s USDC in terminal", tokensMinted, terminalUsdcBalance);
    }

    //*********************************************************************//
    // --- Test 2: V4 ETH -> DAI swap succeeds (quote ordering) --------- //
    //*********************************************************************//

    /// @notice Same test with DAI. DAI address (0x6B17...) also sorts below WETH (0xC02a...) but
    ///         above address(0), so the same quote ordering fix applies.
    function test_fork_v4EthToDai_quoteOrderingCorrect() public {
        uint256 payAmount = 1 ether;

        // Provide a user quote. Set minAmountOut to 1 DAI.
        bytes4 quoteId = JBMetadataResolver.getId("quoteForSwap", address(routerTerminal));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", quoteId, abi.encode(uint256(1e18)));

        vm.deal(payer, payAmount);
        vm.prank(payer);
        uint256 tokensMinted = routerTerminal.pay{value: payAmount}({
            projectId: daiProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "V4 ETH->DAI quote ordering test",
            metadata: metadata
        });

        // Verify tokens were minted.
        assertGt(tokensMinted, 0, "Should mint project tokens");

        // Verify DAI arrived in the terminal.
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 terminalDaiBalance = jbTerminalStore.balanceOf(address(jbMultiTerminal), daiProjectId, address(DAI));
        assertGt(terminalDaiBalance, 0, "Terminal should hold DAI");

        // Sanity: DAI amount should be in the right ballpark for 1 ETH (~2000-4000 DAI at block 21.7M).
        assertGt(terminalDaiBalance, 100e18, "DAI amount should be reasonable (> 100 DAI for 1 ETH)");
        assertLt(terminalDaiBalance, 100_000e18, "DAI amount should be reasonable (< 100k DAI for 1 ETH)");

        // Verify no leftover WETH stuck in the router terminal.
        assertEq(IERC20(address(WETH)).balanceOf(address(routerTerminal)), 0, "No leftover WETH in router");
        assertEq(address(routerTerminal).balance, 0, "No leftover ETH in router");

        console.log("V4 ETH->DAI: %s tokens minted, %s DAI in terminal", tokensMinted, terminalDaiBalance);
    }

    //*********************************************************************//
    // --- Test 3: WETH ERC-20 payment settles via V4 ------------------- //
    //*********************************************************************//

    /// @notice Pay with WETH ERC-20 (not NATIVE_TOKEN) to a USDC-accepting project.
    ///         The V4 pool uses address(0) for ETH. Settlement must unwrap WETH to raw ETH
    ///         before calling settle{value:...}(). Without the fix, this would revert because
    ///         the contract holds WETH but tries to send raw ETH it doesn't have.
    function test_fork_v4WethErc20Payment_settlesCorrectly() public {
        uint256 payAmount = 1 ether;

        // Provide a user quote. Set minAmountOut to 1 USDC.
        bytes4 quoteId = JBMetadataResolver.getId("quoteForSwap", address(routerTerminal));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", quoteId, abi.encode(uint256(1e6)));

        // Give payer WETH (not raw ETH).
        deal(address(WETH), payer, payAmount);

        // Approve the router terminal to spend WETH.
        vm.prank(payer);
        IERC20(address(WETH)).approve(address(routerTerminal), payAmount);

        // Pay with WETH ERC-20 token address (not NATIVE_TOKEN sentinel).
        vm.prank(payer);
        uint256 tokensMinted = routerTerminal.pay({
            projectId: usdcProjectId,
            token: address(WETH),
            amount: payAmount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "WETH ERC-20 settlement test",
            metadata: metadata
        });

        // Verify tokens were minted.
        assertGt(tokensMinted, 0, "Should mint project tokens");

        // Verify USDC arrived in the terminal.
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 terminalUsdcBalance = jbTerminalStore.balanceOf(address(jbMultiTerminal), usdcProjectId, address(USDC));
        assertGt(terminalUsdcBalance, 0, "Terminal should hold USDC");

        // Sanity check the USDC amount.
        assertGt(terminalUsdcBalance, 100e6, "USDC amount should be reasonable (> $100 for 1 WETH)");
        assertLt(terminalUsdcBalance, 100_000e6, "USDC amount should be reasonable (< $100k for 1 WETH)");

        // Verify no leftover tokens stuck in the router terminal.
        assertEq(IERC20(address(WETH)).balanceOf(address(routerTerminal)), 0, "No leftover WETH in router");
        assertEq(address(routerTerminal).balance, 0, "No leftover ETH in router");

        // Verify payer's WETH was consumed.
        assertEq(IERC20(address(WETH)).balanceOf(payer), 0, "Payer WETH should be consumed");

        console.log("WETH ERC-20 -> USDC: %s tokens minted, %s USDC in terminal", tokensMinted, terminalUsdcBalance);
    }

    //*********************************************************************//
    // --- Test 4: V4 vs V3 quote sanity check -------------------------- //
    //*********************************************************************//

    /// @notice For the same ETH amount, compare V3 and V4 spot quotes. Both pools are initialized
    ///         at the same tick, so their quotes should be in the same ballpark (within 20%).
    ///         An inverted price would be orders of magnitude off (>99% difference).
    function test_fork_v4VsV3_quoteSanity() public view {
        uint256 swapAmount = 1 ether;

        // --- V3 baseline: read the V3 pool's spot tick and compute a quote. ---
        (, int24 v3Tick,,,,,) = WETH_USDC_V3.slot0();
        uint256 v3Quote = OracleLibrary.getQuoteAtTick({
            tick: v3Tick,
            // forge-lint: disable-next-line(unsafe-typecast)
            baseAmount: uint128(swapAmount),
            baseToken: address(WETH),
            quoteToken: address(USDC)
        });

        // --- V4 quote: read the V4 pool's spot tick and compute the same way. ---
        // V4 pool uses address(0) for ETH. This is the corrected call path.
        (, int24 v4Tick,,) = V4_POOL_MANAGER.getSlot0(v4EthUsdcKey.toId());
        uint256 v4Quote = OracleLibrary.getQuoteAtTick({
            tick: v4Tick,
            // forge-lint: disable-next-line(unsafe-typecast)
            baseAmount: uint128(swapAmount),
            baseToken: address(0),
            quoteToken: address(USDC)
        });

        console.log("V3 USDC quote for 1 ETH: %s", v3Quote);
        console.log("V4 USDC quote for 1 ETH: %s", v4Quote);

        // Both quotes should be in the same ballpark.
        // We initialized the V4 pool at the V3 pool's current tick, so they should be very close.
        uint256 higher = v3Quote > v4Quote ? v3Quote : v4Quote;
        uint256 lower = v3Quote > v4Quote ? v4Quote : v3Quote;
        uint256 diffBps = ((higher - lower) * 10_000) / higher;

        console.log("Difference: %s bps", diffBps);

        // Within 20% (2000 bps). An inverted price would differ by >99% (~10000x).
        assertLt(diffBps, 2000, "V3 and V4 quotes should be within 20% of each other");

        // Additional check: both should be reasonable USD values for 1 ETH.
        assertGt(v3Quote, 500e6, "V3 quote should be > $500");
        assertGt(v4Quote, 500e6, "V4 quote should be > $500");
        assertLt(v3Quote, 10_000e6, "V3 quote should be < $10,000");
        assertLt(v4Quote, 10_000e6, "V4 quote should be < $10,000");
    }

    //*********************************************************************//
    // ----------------------- V4 pool setup ----------------------------- //
    //*********************************************************************//

    /// @dev Set up the V4 ETH/USDC pool. The 1% (fee=10000, tickSpacing=200) tier does not exist at
    ///      block 21.7M, so we can initialize it at the correct price. We use the V3 pool's current
    ///      tick to ensure the price matches the real market.
    function _setupV4EthUsdcPool() internal {
        v4EthUsdcKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(USDC)),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });

        // Read V3 pool's spot tick. The V3 pool has USDC as token0 and WETH as token1 (USDC < WETH).
        // The V4 pool has address(0) as currency0 and USDC as currency1 (address(0) < USDC).
        // Token ordering is REVERSED: V3 has [USDC, WETH] but V4 has [ETH, USDC].
        // Since tick encodes log(price) = log(token1/token0), the V4 tick must be negated.
        (, int24 v3Tick,,,,,) = WETH_USDC_V3.slot0();
        int24 v4Tick = -v3Tick;

        V4_POOL_MANAGER.initialize(v4EthUsdcKey, V4TickMath.getSqrtPriceAtTick(v4Tick));

        _addV4Liquidity({
            key: v4EthUsdcKey,
            currentTick: v4Tick,
            tickSpacing: 200,
            ethAmount: 500_000 ether,
            tokenAmount: 100_000_000_000_000e6, // 100 trillion USDC (test only, dealt via vm.deal)
            tokenAddr: address(USDC)
        });
    }

    /// @dev Create and provision a V4 ETH/DAI pool. No ETH/DAI V4 pools exist at this block,
    ///      so we initialize one at the V3 WETH/DAI pool's current tick.
    function _setupV4EthDaiPool() internal {
        v4EthDaiKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(DAI)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Read V3 pool's spot tick. V3 has [DAI, WETH] (DAI < WETH) but V4 has [ETH, DAI]
        // (address(0) < DAI). Token ordering is reversed, so negate the tick.
        (, int24 v3DaiTick,,,,,) = WETH_DAI_V3.slot0();
        int24 v4DaiTick = -v3DaiTick;
        V4_POOL_MANAGER.initialize(v4EthDaiKey, V4TickMath.getSqrtPriceAtTick(v4DaiTick));

        _addV4LiquidityWide({
            key: v4EthDaiKey,
            currentTick: v4DaiTick,
            tickSpacing: 60,
            ethAmount: 500_000 ether,
            tokenAmount: 100_000_000_000_000e18, // 100 trillion DAI (test only, dealt via vm.deal)
            tokenAddr: address(DAI)
        });
    }

    /// @dev Add liquidity to a V4 pool with native ETH as currency0.
    ///      Uses a tight range for deep concentrated liquidity.
    function _addV4Liquidity(
        PoolKey memory key,
        int24 currentTick,
        int24 tickSpacing,
        uint256 ethAmount,
        uint256 tokenAmount,
        address tokenAddr
    )
        internal
    {
        int24 lower = ((currentTick / tickSpacing) - 5) * tickSpacing;
        int24 upper = ((currentTick / tickSpacing) + 5) * tickSpacing;
        _addV4LiquidityInRange(key, lower, upper, ethAmount, tokenAmount, tokenAddr);
    }

    /// @dev Add liquidity to a V4 pool with a wide tick range.
    ///      More range = less token per L = can support higher L.
    function _addV4LiquidityWide(
        PoolKey memory key,
        int24 currentTick,
        int24 tickSpacing,
        uint256 ethAmount,
        uint256 tokenAmount,
        address tokenAddr
    )
        internal
    {
        int24 lower = ((currentTick / tickSpacing) - 500) * tickSpacing;
        int24 upper = ((currentTick / tickSpacing) + 500) * tickSpacing;
        _addV4LiquidityInRange(key, lower, upper, ethAmount, tokenAmount, tokenAddr);
    }

    /// @dev Core liquidity addition logic.
    function _addV4LiquidityInRange(
        PoolKey memory key,
        int24 lower,
        int24 upper,
        uint256 ethAmount,
        uint256 tokenAmount,
        address tokenAddr
    )
        internal
    {
        // Provision the liquidity helper with tokens.
        deal(tokenAddr, address(v4LiqHelper), tokenAmount);
        vm.deal(address(v4LiqHelper), ethAmount);

        // Approve the PoolManager to pull ERC-20 tokens.
        vm.startPrank(address(v4LiqHelper));
        IERC20(tokenAddr).approve(address(V4_POOL_MANAGER), type(uint256).max);
        vm.stopPrank();

        // Add deep liquidity. Need L comparable to V3 pools to support 1 ETH swaps.
        // The NoV3PoolFactory ensures V4 is selected regardless of V3 depth.
        vm.prank(address(v4LiqHelper));
        v4LiqHelper.addLiquidity{value: ethAmount}(key, lower, upper, 100_000_000_000_000_000_000);
    }

    //*********************************************************************//
    // ----------------------- Internal helpers -------------------------- //
    //*********************************************************************//

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
        rulesetConfigs[0].weight = 1_000_000e18;
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
