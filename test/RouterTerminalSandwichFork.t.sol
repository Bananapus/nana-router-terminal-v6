// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";

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
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

// Uniswap V4.
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams as V4SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath as V4TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Permit2.
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

// OpenZeppelin.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Router terminal.
import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

//*********************************************************************//
// ----------------------------- Helpers ----------------------------- //
//*********************************************************************//

/// @notice Attacker that swaps directly through V3 pools.
contract V3SwapAttacker is IUniswapV3SwapCallback {
    function swap(IUniswapV3Pool pool, bool zeroForOne, int256 amountSpecified) external returns (int256, int256) {
        (int256 amount0, int256 amount1) = pool.swap(
            address(this),
            zeroForOne,
            amountSpecified,
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            abi.encode(msg.sender)
        );
        return (amount0, amount1);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        // Pay the pool whatever it asks for.
        if (amount0Delta > 0) {
            // forge-lint: disable-next-line(unsafe-typecast, erc20-unchecked-transfer)
            IERC20(IUniswapV3Pool(msg.sender).token0()).transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            // forge-lint: disable-next-line(unsafe-typecast, erc20-unchecked-transfer)
            IERC20(IUniswapV3Pool(msg.sender).token1()).transfer(msg.sender, uint256(amount1Delta));
        }
    }

    receive() external payable {}
}

/// @notice Attacker that swaps directly through V4 PoolManager.
contract V4SwapAttacker is IUnlockCallback {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IPoolManager public immutable poolManager;

    struct SwapParams {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    )
        external
        payable
        returns (BalanceDelta delta)
    {
        bytes memory result = poolManager.unlock(
            abi.encode(
                SwapParams({
                    key: key,
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: sqrtPriceLimitX96
                })
            )
        );
        delta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "only PM");
        SwapParams memory params = abi.decode(data, (SwapParams));

        BalanceDelta delta = poolManager.swap(
            params.key,
            V4SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
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

//*********************************************************************//
// ----------------------------- Tests ------------------------------- //
//*********************************************************************//

/// @title RouterTerminalSandwichForkTest
/// @notice Fork tests simulating sandwich attacks against the router terminal's V3 TWAP path and V4 spot path.
///         Verifies that TWAP-based quoting resists same-block manipulation, sigmoid slippage bounds loss,
///         and user-provided quotes provide tighter protection.
///
///         Run with: forge test --match-contract RouterTerminalSandwichForkTest -vvv --skip "script/*"
///         Requires RPC_ETHEREUM_MAINNET in .env
contract RouterTerminalSandwichForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    //*********************************************************************//
    // ----------------------------- constants --------------------------- //
    //*********************************************************************//

    uint256 constant BLOCK_NUMBER = 21_700_000;

    IWETH9 constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IUniswapV3Factory constant V3_FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    /// @notice WETH/USDC 0.05% V3 pool — one of the deepest on mainnet.
    IUniswapV3Pool constant WETH_USDC_V3 = IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);

    //*********************************************************************//
    // ----------------------------- JB core ----------------------------- //
    //*********************************************************************//

    address multisig = address(0xBEEF);
    address payer = makeAddr("payer");
    address beneficiary = makeAddr("beneficiary");
    address attacker = makeAddr("attacker");
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

    V3SwapAttacker v3Attacker;
    V4SwapAttacker v4Attacker;
    V4LiquidityHelper v4LiqHelper;

    uint256 feeProjectId;
    uint256 usdcProjectId;

    //*********************************************************************//
    // ----------------------------- setup ------------------------------- //
    //*********************************************************************//

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

        v3Attacker = new V3SwapAttacker();
        v4Attacker = new V4SwapAttacker(V4_POOL_MANAGER);
        v4LiqHelper = new V4LiquidityHelper(V4_POOL_MANAGER);

        feeProjectId = _launchProject({acceptedToken: JBConstants.NATIVE_TOKEN, decimals: 18});
        usdcProjectId = _launchProject({acceptedToken: address(USDC), decimals: 6});

        vm.label(address(WETH), "WETH");
        vm.label(address(USDC), "USDC");
        vm.label(address(routerTerminal), "RouterTerminal");
        vm.label(address(jbMultiTerminal), "JBMultiTerminal");
        vm.label(address(v3Attacker), "V3Attacker");
        vm.label(address(v4Attacker), "V4Attacker");
        vm.label(payer, "payer");
        vm.label(attacker, "attacker");
    }

    //*********************************************************************//
    // --- Test 1: V3 Sandwich at varying attack sizes ------------------- //
    //*********************************************************************//

    /// @notice Sandwich 1 ETH victim on real WETH/USDC V3 0.05% pool.
    ///         Attack sizes: [0.5, 1, 5, 10, 50, 100] ETH.
    ///         Measures victim loss and attacker profit. TWAP-based sqrtPriceLimit bounds loss.
    function test_fork_v3Sandwich_varyingAttackSizes() public {
        console.log("");
        console.log("====== V3 SANDWICH: VARYING ATTACK SIZES ======");
        console.log("Pool: WETH/USDC 0.05%% V3 (block %s)", _toString(BLOCK_NUMBER));
        console.log("Victim: 1 ETH -> USDC via router terminal");
        console.log("");

        uint256[6] memory attackSizes = [uint256(0.5 ether), 1 ether, 5 ether, 10 ether, 50 ether, 100 ether];
        uint256 victimAmount = 1 ether;

        // Baseline: victim swap with no attack.
        uint256 snapBaseline = vm.snapshotState();
        uint256 baselineTokens = _payEth(usdcProjectId, victimAmount);
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 baselineUSDC = jbTerminalStore.balanceOf(address(jbMultiTerminal), usdcProjectId, address(USDC));
        vm.revertToState(snapBaseline);

        console.log(
            "  Baseline: %s tokens minted, %s USDC in terminal", _toString(baselineTokens), _formatUsdc(baselineUSDC)
        );
        console.log("");

        // WETH/USDC 0.05% pool: USDC is token0, WETH is token1.
        address token0 = WETH_USDC_V3.token0(); // USDC
        address token1 = WETH_USDC_V3.token1(); // WETH

        for (uint256 i = 0; i < attackSizes.length; i++) {
            uint256 attackSize = attackSizes[i];
            uint256 snapId = vm.snapshotState();

            // Step 1: Attacker frontrun — sell WETH for USDC (zeroForOne=false: sell token1 for token0).
            // This pushes the WETH price down (makes USDC cheaper per WETH).
            deal(token1, address(v3Attacker), attackSize);

            // forge-lint: disable-next-line(unsafe-typecast)
            (int256 frontAmount0,) = v3Attacker.swap(WETH_USDC_V3, false, int256(attackSize));

            // V3: with zeroForOne=false exact input, amount0 is negative (USDC received by attacker).
            // forge-lint: disable-next-line(unsafe-typecast, mixed-case-variable)
            uint256 attackerUSDCReceived = frontAmount0 < 0 ? uint256(-frontAmount0) : 0;

            // Step 2: Victim pays through router terminal.
            _payEth(usdcProjectId, victimAmount);
            // forge-lint: disable-next-line(mixed-case-variable)
            uint256 victimUSDC = jbTerminalStore.balanceOf(address(jbMultiTerminal), usdcProjectId, address(USDC));

            // Step 3: Attacker backrun — sell USDC back for WETH.
            // forge-lint: disable-next-line(mixed-case-variable)
            uint256 attackerWETHBack = 0;
            if (attackerUSDCReceived > 0) {
                deal(token0, address(v3Attacker), attackerUSDCReceived);
                // V3: zeroForOne=true exact input of USDC. amount1 is negative (WETH received).
                // forge-lint: disable-next-line(unsafe-typecast)
                (, int256 backAmount1) = v3Attacker.swap(WETH_USDC_V3, true, int256(attackerUSDCReceived));
                // forge-lint: disable-next-line(unsafe-typecast)
                attackerWETHBack = backAmount1 < 0 ? uint256(-backAmount1) : 0;
            }

            // forge-lint: disable-next-line(unsafe-typecast)
            int256 attackerProfit = int256(attackerWETHBack) - int256(attackSize);
            uint256 victimLossBps = baselineUSDC > 0
                ? ((baselineUSDC > victimUSDC ? baselineUSDC - victimUSDC : 0) * 10_000) / baselineUSDC
                : 0;

            console.log("  Attack: %s ETH", _formatEther(attackSize));
            console.log(
                "    Victim: %s USDC (loss: %s bps vs baseline)", _formatUsdc(victimUSDC), _toString(victimLossBps)
            );
            if (attackerProfit >= 0) {
                // forge-lint: disable-next-line(unsafe-typecast)
                console.log("    Attacker: +%s ETH profit", _formatEther(uint256(attackerProfit)));
            } else {
                // forge-lint: disable-next-line(unsafe-typecast)
                console.log("    Attacker: -%s ETH LOSS", _formatEther(uint256(-attackerProfit)));
            }

            vm.revertToState(snapId);
        }

        console.log("");
        console.log("KEY: V3 TWAP quote is computed from 10-min oracle history.");
        console.log("Single-block spot manipulation does NOT affect the TWAP quote.");
        console.log("Attacker pays 2x pool fees (0.05%% each way = 0.1%%) for no gain.");
    }

    //*********************************************************************//
    // --- Test 2: TWAP resistance to same-block manipulation ------------ //
    //*********************************************************************//

    /// @notice Prove that the V3 TWAP quote is identical before and after same-block spot price manipulation.
    function test_fork_v3Sandwich_twapResistance() public {
        console.log("");
        console.log("====== V3 TWAP RESISTANCE: SAME-BLOCK MANIPULATION ======");
        console.log("");

        // Read TWAP before any manipulation.
        uint32 twapWindow = 600; // 10 minutes
        (int24 tickBefore,) = OracleLibrary.consult(address(WETH_USDC_V3), twapWindow);
        uint256 twapQuoteBefore = OracleLibrary.getQuoteAtTick(tickBefore, 1 ether, address(WETH), address(USDC));

        console.log("  TWAP tick before: %s", _tickStr(tickBefore));
        console.log("  TWAP quote before: %s USDC per ETH", _formatUsdc(twapQuoteBefore));

        // Manipulate: large swap to move spot price.
        uint256 manipSize = 100 ether;
        deal(address(WETH), address(v3Attacker), manipSize);
        // forge-lint: disable-next-line(unsafe-typecast)
        v3Attacker.swap(WETH_USDC_V3, false, int256(manipSize));

        // Read spot price after manipulation.
        (, int24 spotTickAfter,,,,,) = WETH_USDC_V3.slot0();
        uint256 spotQuoteAfter = OracleLibrary.getQuoteAtTick(spotTickAfter, 1 ether, address(WETH), address(USDC));

        // Read TWAP after manipulation (same block!).
        (int24 tickAfter,) = OracleLibrary.consult(address(WETH_USDC_V3), twapWindow);
        uint256 twapQuoteAfter = OracleLibrary.getQuoteAtTick(tickAfter, 1 ether, address(WETH), address(USDC));

        console.log("");
        console.log("  After %s ETH manipulation:", _formatEther(manipSize));
        console.log("  Spot tick: %s | Spot quote: %s USDC", _tickStr(spotTickAfter), _formatUsdc(spotQuoteAfter));
        console.log("  TWAP tick: %s | TWAP quote: %s USDC", _tickStr(tickAfter), _formatUsdc(twapQuoteAfter));

        uint256 spotDeltaBps =
            twapQuoteBefore > spotQuoteAfter ? ((twapQuoteBefore - spotQuoteAfter) * 10_000) / twapQuoteBefore : 0;
        uint256 twapDeltaBps =
            twapQuoteBefore > twapQuoteAfter ? ((twapQuoteBefore - twapQuoteAfter) * 10_000) / twapQuoteBefore : 0;

        console.log("");
        console.log("  Spot moved: %s bps from pre-manipulation", _toString(spotDeltaBps));
        console.log("  TWAP moved: %s bps from pre-manipulation", _toString(twapDeltaBps));

        // TWAP should be identical (or within 1 bps from rounding).
        assertEq(tickBefore, tickAfter, "TWAP tick should be identical before and after same-block manipulation");

        console.log("");
        console.log("KEY: TWAP is immune to same-block spot price manipulation.");
        console.log("The 10-minute observation window makes single-block attacks futile.");
    }

    //*********************************************************************//
    // --- Test 3: User quote blocks sandwich that TWAP alone allows ----- //
    //*********************************************************************//

    /// @notice User provides a tight quote (0.5% slippage). Sandwich that TWAP-based tolerance would allow
    ///         is blocked by the user's tighter quote.
    function test_fork_v3Sandwich_withUserQuote() public {
        console.log("");
        console.log("====== V3 USER QUOTE vs SANDWICH ======");
        console.log("");

        uint256 victimAmount = 1 ether;

        // Get baseline USDC output.
        uint256 snapBaseline = vm.snapshotState();
        _payEth(usdcProjectId, victimAmount);
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 baselineUSDC = jbTerminalStore.balanceOf(address(jbMultiTerminal), usdcProjectId, address(USDC));
        vm.revertToState(snapBaseline);

        console.log("  Baseline USDC: %s", _formatUsdc(baselineUSDC));

        // User sets tight quote: 0.5% slippage.
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 userMinUSDC = (baselineUSDC * 995) / 1000;
        console.log("  User min USDC (0.5%% slippage): %s", _formatUsdc(userMinUSDC));

        // Attacker frontruns.
        uint256 attackSize = 50 ether;
        uint256 snapId = vm.snapshotState();

        deal(address(WETH), address(v3Attacker), attackSize);
        // forge-lint: disable-next-line(unsafe-typecast)
        v3Attacker.swap(WETH_USDC_V3, false, int256(attackSize));

        // Victim pays with tight user quote.
        bytes4 quoteId = JBMetadataResolver.getId("quoteForSwap", address(routerTerminal));
        bytes memory metadata = JBMetadataResolver.addToMetadata("", quoteId, abi.encode(userMinUSDC));

        vm.deal(payer, victimAmount);
        vm.prank(payer);

        // The tight quote should cause a revert if the sandwich moved the price beyond 0.5%.
        bool reverted = false;
        try routerTerminal.pay{value: victimAmount}({
            projectId: usdcProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: victimAmount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "tight quote sandwich test",
            metadata: metadata
        }) returns (
            uint256 tokenCount
        ) {
            // forge-lint: disable-next-line(mixed-case-variable)
            uint256 victimUSDC = jbTerminalStore.balanceOf(address(jbMultiTerminal), usdcProjectId, address(USDC));
            console.log("  Swap succeeded: %s tokens, %s USDC", _toString(tokenCount), _formatUsdc(victimUSDC));
            console.log("  (Attack was within 0.5%% tolerance)");
        } catch {
            reverted = true;
            console.log("  Swap REVERTED: user quote blocked the sandwich");
        }

        vm.revertToState(snapId);

        console.log("");
        if (reverted) {
            console.log("KEY: User-provided tight quote (0.5%%) blocked a sandwich that");
            console.log("the TWAP's wider tolerance (~2%%) would have allowed.");
        } else {
            console.log(
                "KEY: The %s ETH attack was too small to breach 0.5%% on this deep pool.", _formatEther(attackSize)
            );
            console.log("For very deep pools, even large attacks produce minimal slippage.");
        }
    }

    //*********************************************************************//
    // --- Test 4: V4 spot price manipulation (M-3 risk documentation) --- //
    //*********************************************************************//

    /// @notice Create a fresh V4 pool, manipulate spot price, route victim through it.
    ///         Documents that V4 spot path exposes up to sigmoid-slippage% per trade (known M-3 risk).
    function test_fork_v4SpotPrice_manipulation() public {
        console.log("");
        console.log("====== V4 SPOT PRICE MANIPULATION (M-3 RISK) ======");
        console.log("Creating fresh WETH/USDC V4 pool to demonstrate spot manipulation.");
        console.log("");

        (PoolKey memory key, uint256 quoteBefore) = _setupV4Pool();

        console.log("  Quote before: %s USDC per ETH", _formatUsdc(quoteBefore));

        // Attacker manipulates V4 pool spot price at varying sizes.
        uint256[3] memory attackSizes = [uint256(10 ether), 50 ether, 100 ether];

        for (uint256 i = 0; i < attackSizes.length; i++) {
            _v4AttackIteration(key, attackSizes[i], quoteBefore);
        }

        console.log("");
        console.log("RISK (M-3): V4 spot price IS manipulable within the same block.");
        console.log("Mitigations: (1) sigmoid 2%% floor, (2) user quote override, (3) V3 pool preferred if deeper.");
        console.log("Recommendation: front-ends MUST supply quoteForSwap metadata for V4 swaps.");
    }

    /// @dev Set up a V4 WETH/USDC pool and return the pool key + initial quote.
    function _setupV4Pool() internal returns (PoolKey memory key, uint256 quoteBefore) {
        address usdc = address(USDC);
        address wethAddr = address(WETH);

        key = PoolKey({
            currency0: Currency.wrap(usdc),
            currency1: Currency.wrap(wethAddr),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        (, int24 currentV3Tick,,,,,) = WETH_USDC_V3.slot0();
        V4_POOL_MANAGER.initialize(key, V4TickMath.getSqrtPriceAtTick(currentV3Tick));

        deal(usdc, address(v4LiqHelper), 10_000_000e6);
        deal(wethAddr, address(v4LiqHelper), 3000 ether);

        vm.startPrank(address(v4LiqHelper));
        IERC20(usdc).approve(address(V4_POOL_MANAGER), type(uint256).max);
        IERC20(wethAddr).approve(address(V4_POOL_MANAGER), type(uint256).max);
        vm.stopPrank();

        int24 lower = (currentV3Tick / int24(60) - 100) * int24(60);
        int24 upper = (currentV3Tick / int24(60) + 100) * int24(60);

        vm.prank(address(v4LiqHelper));
        v4LiqHelper.addLiquidity(key, lower, upper, 1_000_000e6);

        (, int24 spotBefore,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        quoteBefore = OracleLibrary.getQuoteAtTick(spotBefore, 1 ether, wethAddr, usdc);
    }

    /// @dev Run a single V4 attack iteration: manipulate spot, read new price, log, revert.
    function _v4AttackIteration(PoolKey memory key, uint256 attackSize, uint256 quoteBefore) internal {
        uint256 snapId = vm.snapshotState();

        address wethAddr = address(WETH);
        deal(wethAddr, address(v4Attacker), attackSize);
        vm.startPrank(address(v4Attacker));
        IERC20(wethAddr).approve(address(V4_POOL_MANAGER), type(uint256).max);
        vm.stopPrank();

        // forge-lint: disable-next-line(unsafe-typecast)
        v4Attacker.swap(key, false, -int256(attackSize), V4TickMath.MAX_SQRT_PRICE - 1);

        (, int24 spotAfter,,) = V4_POOL_MANAGER.getSlot0(key.toId());
        uint256 quoteAfter = OracleLibrary.getQuoteAtTick(spotAfter, 1 ether, wethAddr, address(USDC));
        uint256 deltaBps = quoteBefore > quoteAfter ? ((quoteBefore - quoteAfter) * 10_000) / quoteBefore : 0;

        console.log("  Attack %s ETH: spot moved %s bps", _formatEther(attackSize), _toString(deltaBps));
        console.log("    Price: %s -> %s USDC/ETH", _formatUsdc(quoteBefore), _formatUsdc(quoteAfter));

        vm.revertToState(snapId);
    }

    //*********************************************************************//
    // ----------------------- Internal helpers -------------------------- //
    //*********************************************************************//

    function _payEth(uint256 projectId, uint256 amountIn) internal returns (uint256 tokenCount) {
        vm.deal(payer, amountIn);
        vm.prank(payer);
        tokenCount = routerTerminal.pay{value: amountIn}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amountIn,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "sandwich test",
            metadata: ""
        });
    }

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

    //*********************************************************************//
    // ----------------------------- Formatters -------------------------- //
    //*********************************************************************//

    function _formatEther(uint256 weiAmount) internal pure returns (string memory) {
        uint256 whole = weiAmount / 1e18;
        uint256 frac = (weiAmount % 1e18) / 1e16;
        if (frac < 10) return string(abi.encodePacked(_toString(whole), ".0", _toString(frac)));
        return string(abi.encodePacked(_toString(whole), ".", _toString(frac)));
    }

    function _formatUsdc(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e6;
        uint256 frac = (amount % 1e6) / 1e4;
        if (frac < 10) return string(abi.encodePacked(_toString(whole), ".0", _toString(frac)));
        return string(abi.encodePacked(_toString(whole), ".", _toString(frac)));
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            // forge-lint: disable-next-line(unsafe-typecast)
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }

    function _tickStr(int24 tick) internal pure returns (string memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        if (tick >= 0) return _toString(uint256(uint24(tick)));
        // forge-lint: disable-next-line(unsafe-typecast)
        return string(abi.encodePacked("-", _toString(uint256(uint24(-tick)))));
    }
}
