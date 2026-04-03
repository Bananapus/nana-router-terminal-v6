// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPermitTerminal} from "@bananapus/core-v6/src/interfaces/IJBPermitTerminal.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IGeomeanOracle} from "./interfaces/IGeomeanOracle.sol";
import {IJBPayRoutePreviewer} from "./interfaces/IJBPayRoutePreviewer.sol";
import {IJBPayRouteResolver} from "./interfaces/IJBPayRouteResolver.sol";
import {IJBRouterTerminal} from "./interfaces/IJBRouterTerminal.sol";
import {IJBPayerTracker} from "./interfaces/IJBPayerTracker.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {JBSwapLib} from "./libraries/JBSwapLib.sol";
import {JBPayRouteResolver} from "./JBPayRouteResolver.sol";
import {PoolInfo} from "./structs/PoolInfo.sol";

/// @notice The `JBRouterTerminal` accepts any token and dynamically discovers what token each destination project
/// accepts, then routes the payment there — via direct forwarding, Uniswap swap, JB token cashout, or a combination.
/// Supports both Uniswap V3 and V4 pools, choosing whichever offers better liquidity.
/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
contract JBRouterTerminal is
    JBPermissioned,
    Ownable,
    ERC2771Context,
    IJBPermitTerminal,
    IUniswapV3SwapCallback,
    IUnlockCallback,
    IJBRouterTerminal,
    IJBPayRoutePreviewer
{
    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBRouterTerminal_AmountOverflow(uint256 amount);
    error JBRouterTerminal_CallerNotPool(address caller);
    error JBRouterTerminal_CallerNotPoolManager(address caller);
    error JBRouterTerminal_CashOutLoopLimit();
    error JBRouterTerminal_InsufficientTwapHistory();
    error JBRouterTerminal_NoCashOutPath(uint256 sourceProjectId, uint256 destProjectId);
    error JBRouterTerminal_NoLiquidity();
    error JBRouterTerminal_NoMsgValueAllowed(uint256 value);
    error JBRouterTerminal_NoObservationHistory();
    error JBRouterTerminal_NoPoolFound(address tokenIn, address tokenOut);
    error JBRouterTerminal_NoRouteFound(uint256 projectId, address tokenIn);
    error JBRouterTerminal_PermitAllowanceNotEnough(uint256 amount, uint256 allowance);
    error JBRouterTerminal_SlippageExceeded(uint256 amountOut, uint256 minAmountOut);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The default TWAP window used for auto-discovered pools.
    uint256 public constant DEFAULT_TWAP_WINDOW = 10 minutes;

    /// @notice The minimum acceptable TWAP window (2 minutes). Reverts if the pool's oldest observation is below this
    /// floor.
    uint32 public constant MIN_TWAP_WINDOW = 120;

    //*********************************************************************//
    // ------------------------ internal constants ----------------------- //
    //*********************************************************************//

    /// @notice The maximum number of cashout iterations before reverting. Prevents infinite loops from circular
    /// token dependencies.
    uint256 internal constant _MAX_CASHOUT_ITERATIONS = 20;

    /// @notice The denominator used for slippage tolerance basis points.
    uint256 internal constant _SLIPPAGE_DENOMINATOR = 10_000;

    /// @notice The TWAP window (in seconds) used when querying a V4 oracle hook.
    uint32 private constant _TWAP_WINDOW = 30;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The directory of terminals and controllers for projects.
    IJBDirectory public immutable DIRECTORY;

    /// @notice Manages minting, burning, and balances of projects' tokens and token credits.
    IJBTokens public immutable TOKENS;

    /// @notice The Uniswap V3 factory used for pool discovery and verification.
    IUniswapV3Factory public immutable FACTORY;

    /// @notice The Uniswap V4 PoolManager. Can be address(0) if V4 is not deployed on this chain.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice The permit2 utility.
    IPermit2 public immutable override PERMIT2;

    /// @notice The ERC-20 wrapper for the native token.
    IWETH9 public immutable WETH;

    /// @notice The canonical buyback hook whose preview hook specification metadata this router understands.
    address public immutable BUYBACK_HOOK;

    /// @notice The helper contract used to resolve best pay-route previews without bloating router runtime size.
    IJBPayRouteResolver internal immutable PAY_ROUTE_RESOLVER;

    //*********************************************************************//
    // ---------------------- internal stored properties ----------------- //
    //*********************************************************************//

    /// @notice The fee tiers to search when auto-discovering V3 pools, ordered by commonality.
    /// 3000 = 0.3%, 500 = 0.05%, 10000 = 1%, 100 = 0.01%.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint24[4] internal _FEE_TIERS = [uint24(3000), uint24(500), uint24(10_000), uint24(100)];

    /// @notice The fee/tickSpacing pairings to search for V4 vanilla pools.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint24[4] internal _V4_FEES = [uint24(3000), uint24(500), uint24(10_000), uint24(100)];
    // forge-lint: disable-next-line(mixed-case-variable)
    int24[4] internal _V4_TICK_SPACINGS = [int24(60), int24(10), int24(200), int24(1)];

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param permissions A contract storing permissions.
    /// @param tokens A contract managing project token balances.
    /// @param permit2 A permit2 utility.
    /// @param owner The owner of the contract.
    /// @param weth A contract which wraps the native token.
    /// @param factory The Uniswap V3 factory for pool discovery.
    /// @param poolManager The Uniswap V4 PoolManager (address(0) if V4 not available).
    /// @param trustedForwarder The trusted forwarder for the contract.
    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        IJBTokens tokens,
        IPermit2 permit2,
        address owner,
        IWETH9 weth,
        IUniswapV3Factory factory,
        IPoolManager poolManager,
        address buybackHook,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
        Ownable(owner)
    {
        DIRECTORY = directory;
        TOKENS = tokens;
        FACTORY = factory;
        POOL_MANAGER = poolManager;
        PERMIT2 = permit2;
        WETH = weth;
        BUYBACK_HOOK = buybackHook;
        PAY_ROUTE_RESOLVER = IJBPayRouteResolver(address(new JBPayRouteResolver()));
    }

    //*********************************************************************//
    // ---------------------- receive / fallback ------------------------- //
    //*********************************************************************//

    /// @notice Receive native tokens from cash out reclaims, WETH unwraps, and V4 PoolManager takes.
    receive() external payable {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Empty implementation to satisfy the interface. Accounting contexts are determined dynamically.
    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    /// @notice Add funds to a project's balance by routing the incoming token to whatever token the project accepts.
    /// @param projectId The ID of the destination project.
    /// @param token The address of the token being paid in.
    /// @param amount The amount of tokens being paid in.
    /// @param shouldReturnHeldFees Whether held fees should be returned based on the amount added.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes in `JBMetadataResolver`'s format.
    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool shouldReturnHeldFees,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        override
    {
        IJBTerminal destTerminal;
        (destTerminal, token, amount) = _route({
            destProjectId: projectId,
            tokenIn: token,
            amount: _acceptFundsFor({token: token, amount: amount, metadata: metadata}),
            metadata: metadata,
            refundTo: _resolveRefundWithBackupRecipient(payable(_msgSender()))
        });

        uint256 payValue = _beforeTransferFor({to: address(destTerminal), token: token, amount: amount});

        destTerminal.addToBalanceOf{value: payValue}({
            projectId: projectId,
            token: token,
            amount: amount,
            shouldReturnHeldFees: shouldReturnHeldFees,
            memo: memo,
            metadata: metadata
        });
    }

    /// @notice Empty implementation to satisfy the interface. This terminal has no balance to migrate.
    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256 balance) {
        return 0;
    }

    /// @notice Pay a project by routing the incoming token to whatever token the project accepts.
    /// @dev Automatically handles direct forwarding, Uniswap swaps, JB token cashouts, or combinations.
    /// @param projectId The ID of the destination project being paid.
    /// @param token The address of the token being paid in.
    /// @param amount The amount of tokens being paid in.
    /// @param beneficiary The address to receive any tokens minted by the destination project.
    /// @param minReturnedTokens The minimum number of destination project tokens expected in return.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes in `JBMetadataResolver`'s format.
    /// @return beneficiaryTokenCount The number of tokens minted for the beneficiary.
    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        virtual
        override
        returns (uint256 beneficiaryTokenCount)
    {
        amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});

        IJBTerminal destTerminal;
        (destTerminal, token, amount) = _routeForPay({
            destProjectId: projectId,
            tokenIn: token,
            amount: amount,
            beneficiary: beneficiary,
            metadata: metadata,
            refundTo: _resolveRefundWithBackupRecipient(payable(_msgSender()))
        });

        uint256 payValue = _beforeTransferFor({to: address(destTerminal), token: token, amount: amount});

        beneficiaryTokenCount = destTerminal.pay{value: payValue}({
            projectId: projectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: minReturnedTokens,
            memo: memo,
            metadata: metadata
        });
    }

    /// @notice The Uniswap v3 pool callback where the token transfer is expected to happen.
    /// @dev Verifies the caller is a legitimate pool via the factory using the encoded tokenIn/tokenOut pair.
    /// @param amount0Delta The amount of token 0 being used for the swap.
    /// @param amount1Delta The amount of token 1 being used for the swap.
    /// @param data Data passed in by the swap operation: abi.encode(projectId, tokenIn, tokenOut).
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        // Unpack the data from the original swap config.
        (, address tokenIn, address tokenOut) = abi.decode(data, (uint256, address, address));

        // Normalize tokens (wrap native token if needed).
        address normalizedTokenIn = _normalize(tokenIn);
        address normalizedTokenOut = _normalize(tokenOut);

        // Verify caller is a legitimate pool via the factory.
        uint24 fee = IUniswapV3Pool(msg.sender).fee();
        address expectedPool = _getPool({tokenA: normalizedTokenIn, tokenB: normalizedTokenOut, fee: fee});
        if (msg.sender != expectedPool) revert JBRouterTerminal_CallerNotPool(msg.sender);

        // Calculate the amount of tokens to send to the pool (the positive delta).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountToSendToPool = amount0Delta < 0 ? uint256(amount1Delta) : uint256(amount0Delta);

        // Wrap native tokens if needed.
        if (tokenIn == JBConstants.NATIVE_TOKEN) _wethDeposit(amountToSendToPool);

        // Transfer the tokens to the pool.
        IERC20(normalizedTokenIn).safeTransfer({to: msg.sender, value: amountToSendToPool});
    }

    /// @notice The Uniswap V4 unlock callback. Called by the PoolManager during `unlock()`.
    /// @param data Encoded swap parameters.
    /// @return Encoded output amount.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert JBRouterTerminal_CallerNotPoolManager(msg.sender);

        // Decode the swap parameters.
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, uint256 minAmountOut) =
            abi.decode(data, (PoolKey, bool, int256, uint160, uint256));

        // Execute the swap.
        BalanceDelta delta = POOL_MANAGER.swap({
            key: key,
            params: SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            hookData: ""
        });

        // Determine input/output amounts from the delta.
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        uint256 amountIn;
        uint256 amountOut;
        if (zeroForOne) {
            // forge-lint: disable-next-line(unsafe-typecast)
            amountIn = uint256(uint128(-delta0));
            // forge-lint: disable-next-line(unsafe-typecast)
            amountOut = uint256(uint128(delta1));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            amountIn = uint256(uint128(-delta1));
            // forge-lint: disable-next-line(unsafe-typecast)
            amountOut = uint256(uint128(delta0));
        }

        if (amountOut < minAmountOut) revert JBRouterTerminal_SlippageExceeded(amountOut, minAmountOut);

        // Settle input (pay what we owe to the PoolManager).
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        _settleV4({currency: inputCurrency, amount: amountIn});

        // Take output (receive what the PoolManager owes us).
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        _takeV4({currency: outputCurrency, amount: amountOut});

        return abi.encode(amountOut);
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Returns a best-effort accounting context for any token the router can route.
    /// @dev This surface is still synthetic for routing discovery, but it probes ERC-20 decimals when available and
    /// falls back to 18 if a token omits or breaks `decimals()`.
    /// @param token The address of the token to get the accounting context for.
    function accountingContextForTokenOf(
        uint256,
        address token
    )
        external
        view
        override
        returns (JBAccountingContext memory)
    {
        uint8 decimals = 18;

        if (token != JBConstants.NATIVE_TOKEN) {
            try IJBToken(token).decimals() returns (uint8 resolvedDecimals) {
                decimals = resolvedDecimals;
            } catch {
                // Non-standard ERC-20s that omit or break `decimals()` remain discoverable with a synthetic fallback.
            }
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        return JBAccountingContext({token: token, decimals: decimals, currency: uint32(uint160(token))});
    }

    /// @notice Returns an empty array — this terminal accepts any token dynamically.
    /// @return contexts An empty array of `JBAccountingContext`.
    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](0);
    }

    /// @notice This terminal holds no surplus. Always returns 0.
    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    /// @notice Discover the best pool across both V3 and V4 for a token pair.
    /// @param normalizedTokenIn The input token (wrapped if native).
    /// @param normalizedTokenOut The output token (wrapped if native).
    /// @return pool The best pool found.
    function discoverBestPool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        external
        view
        override
        returns (PoolInfo memory)
    {
        PoolInfo memory pool = _discoverPool(normalizedTokenIn, normalizedTokenOut);
        if (!pool.isV4 && address(pool.v3Pool) == address(0)) {
            revert JBRouterTerminal_NoPoolFound(normalizedTokenIn, normalizedTokenOut);
        }
        return pool;
    }

    /// @notice Public wrapper for V3-only _discoverPool, useful for off-chain queries.
    /// @param normalizedTokenIn The input token (wrapped if native).
    /// @param normalizedTokenOut The output token (wrapped if native).
    /// @return pool The V3 pool with the highest liquidity.
    function discoverPool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        external
        view
        override
        returns (IUniswapV3Pool)
    {
        PoolInfo memory info = _discoverPool(normalizedTokenIn, normalizedTokenOut);
        if (!info.isV4 && address(info.v3Pool) == address(0)) {
            revert JBRouterTerminal_NoPoolFound(normalizedTokenIn, normalizedTokenOut);
        }
        if (!info.isV4) return info.v3Pool;
        return IUniswapV3Pool(address(0));
    }

    /// @notice Preview a payment by simulating the router's routing logic in view context.
    /// @dev Returns the router's best estimate using current routing and quote data, including swap quotes when needed.
    /// @param projectId The ID of the destination project being paid.
    /// @param token The token that would be provided to the router.
    /// @param amount The amount of the input token that would be provided.
    /// @param beneficiary The address that would receive any minted project tokens.
    /// @param metadata Extra data used to preview fund acceptance, routing, and the destination terminal call.
    /// @return ruleset The current ruleset the destination terminal would use.
    /// @return beneficiaryTokenCount The number of project tokens that would be minted for the beneficiary.
    /// @return reservedTokenCount The number of project tokens that would be reserved.
    /// @return hookSpecifications The pay hook specifications the resolved terminal would return.
    function previewPayFor(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        bytes calldata metadata
    )
        external
        view
        returns (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        )
    {
        // Simulate how the router would normalize the incoming funds before routing.
        amount = _previewAcceptFundsFor({amount: amount, metadata: metadata});
        (,,, ruleset, beneficiaryTokenCount, reservedTokenCount, hookSpecifications) =
            PAY_ROUTE_RESOLVER.previewBestPayRoute({
                router: IJBPayRoutePreviewer(address(this)),
                projectId: projectId,
                tokenIn: token,
                amount: amount,
                beneficiary: beneficiary,
                metadata: metadata
            });
    }

    /// @notice Preview the recursive cashout loop the router would use for a project-token input.
    /// @param destProjectId The destination project the router is trying to pay.
    /// @param token The current token being routed.
    /// @param amount The amount of `token` being previewed.
    /// @param sourceProjectIdOverride The one-shot source project override encoded in metadata, if any.
    /// @param metadata Metadata forwarded into preview helpers.
    /// @param preferredToken The token the cashout loop should prefer to land on, or `address(0)` for no preference.
    /// @return destTerminal The terminal reached by the cashout loop, or address(0) if routing should continue.
    /// @return finalToken The token produced by the previewed cashout loop.
    /// @return finalAmount The amount of `finalToken` produced by the previewed cashout loop.
    function previewCashOutLoopOf(
        uint256 destProjectId,
        address token,
        uint256 amount,
        uint256 sourceProjectIdOverride,
        bytes calldata metadata,
        address preferredToken
    )
        external
        view
        returns (IJBTerminal destTerminal, address finalToken, uint256 finalAmount)
    {
        return _previewCashOutLoop({
            destProjectId: destProjectId,
            token: token,
            amount: amount,
            sourceProjectIdOverride: sourceProjectIdOverride,
            metadata: metadata,
            preferredToken: preferredToken
        });
    }

    /// @notice Preview the amount a direct token-to-token swap would return.
    /// @param tokenIn The input token.
    /// @param tokenOut The output token.
    /// @param amount The amount of `tokenIn` being swapped.
    /// @param metadata Metadata forwarded into quote selection.
    /// @return amountOut The quoted amount of `tokenOut`.
    function previewSwapAmountOutOf(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata metadata
    )
        external
        view
        returns (uint256 amountOut)
    {
        return _previewSwapAmountOut({tokenIn: tokenIn, tokenOut: tokenOut, amount: amount, metadata: metadata});
    }

    /// @notice Preview a destination terminal payment from the router's caller context.
    /// @param destTerminal The terminal whose pay preview should be queried.
    /// @param projectId The destination project that would receive the payment.
    /// @param token The token the destination terminal would receive.
    /// @param amount The amount of `token` the destination terminal would receive.
    /// @param beneficiary The address whose beneficiary token count is being measured.
    /// @param metadata Metadata forwarded unchanged into the destination terminal preview.
    /// @return ruleset The ruleset returned by the destination terminal preview.
    /// @return beneficiaryTokenCount The beneficiary token count returned by the destination terminal preview.
    /// @return reservedTokenCount The reserved token count returned by the destination terminal preview.
    /// @return hookSpecifications The pay hook specifications returned by the destination terminal preview.
    function previewTerminalPayOf(
        IJBTerminal destTerminal,
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        bytes calldata metadata
    )
        external
        view
        returns (JBRuleset memory, uint256, uint256, JBPayHookSpecification[] memory)
    {
        return destTerminal.previewPayFor({
            projectId: projectId, token: token, amount: amount, beneficiary: beneficiary, metadata: metadata
        });
    }

    /// @notice Return the highest discovered pool liquidity between two normalized tokens.
    /// @param tokenA One token in the pair.
    /// @param tokenB The other token in the pair.
    /// @return bestLiquidity The highest liquidity found, or 0 if no pool exists.
    function bestPoolLiquidityOf(address tokenA, address tokenB) external view returns (uint128) {
        return _bestPoolLiquidity(tokenA, tokenB);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherence to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IJBPermitTerminal).interfaceId
            || interfaceId == type(IJBRouterTerminal).interfaceId || interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IJBPermissioned).interfaceId;
    }

    //*********************************************************************//
    // ------------------------- internal helpers ------------------------ //
    //*********************************************************************//

    /// @notice Resolve the refund target for partial-fill leftovers.
    /// @dev When called via an intermediary that implements `IJBPayerTracker` (e.g. `JBRouterTerminalRegistry`),
    /// the intermediary stores the original payer in transient storage. This function reads it so that refunds
    /// go to the true payer rather than the intermediary.
    /// @param fallback_ The default refund address to use when no original payer is available.
    /// @return The address to refund partial-fill leftovers to.
    function _resolveRefundWithBackupRecipient(address payable fallback_) internal view returns (address payable) {
        // Only attempt the call if msg.sender is a contract (EOAs have no code and would revert).
        if (msg.sender.code.length > 0) {
            // Check if the caller implements IJBPayerTracker and has an original payer set.
            try IJBPayerTracker(msg.sender).originalPayer() returns (address payer) {
                if (payer != address(0)) return payable(payer);
            } catch {}
        }
        return fallback_;
    }

    /// @notice Route a payment using the destination token that yields the highest previewed beneficiary output.
    function _routeForPay(
        uint256 destProjectId,
        address tokenIn,
        uint256 amount,
        address beneficiary,
        bytes calldata metadata,
        address payable refundTo
    )
        internal
        returns (IJBTerminal destTerminal, address tokenOut, uint256 amountOut)
    {
        IJBTerminal[] memory terminals;
        (bool success, bytes memory data) =
            address(DIRECTORY).staticcall(abi.encodeWithSelector(IJBDirectory.terminalsOf.selector, destProjectId));
        if (success && data.length != 0) terminals = abi.decode(data, (IJBTerminal[]));

        if (terminals.length == 0) {
            return _route({
                destProjectId: destProjectId, tokenIn: tokenIn, amount: amount, metadata: metadata, refundTo: refundTo
            });
        }

        (destTerminal, tokenOut,,,,,) = PAY_ROUTE_RESOLVER.previewBestPayRoute({
            router: IJBPayRoutePreviewer(address(this)),
            projectId: destProjectId,
            tokenIn: tokenIn,
            amount: amount,
            beneficiary: beneficiary,
            metadata: metadata
        });

        return _routeToDestination({
            destProjectId: destProjectId,
            tokenIn: tokenIn,
            amount: amount,
            tokenOut: tokenOut,
            metadata: metadata,
            refundTo: refundTo
        });
    }

    /// @notice Estimate the amount a buyback-hook cash-out preview would actually deliver to the router.
    function _effectivePreviewCashOutAmount(
        uint256 reclaimAmount,
        JBCashOutHookSpecification[] memory hookSpecifications
    )
        internal
        view
        returns (uint256)
    {
        uint256 effectiveAmount = reclaimAmount;

        for (uint256 i; i < hookSpecifications.length; i++) {
            JBCashOutHookSpecification memory specification = hookSpecifications[i];
            if (specification.noop || address(specification.hook) != BUYBACK_HOOK) continue;

            (uint256 minimumSwapAmountOut,,,,,, uint256 rawSwapQuote) =
                abi.decode(specification.metadata, (uint256, uint256, uint256, int24, uint128, PoolId, uint256));

            uint256 quotedAmount = rawSwapQuote != 0 ? rawSwapQuote : minimumSwapAmountOut;
            if (quotedAmount > effectiveAmount) effectiveAmount = quotedAmount;
        }

        return effectiveAmount;
    }

    /// @notice Preview the output amount for a direct token-to-token swap route.
    function _previewSwapAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata metadata
    )
        internal
        view
        returns (uint256 amountOut)
    {
        address normalizedTokenIn = _normalize(tokenIn);
        address normalizedTokenOut = _normalize(tokenOut);

        if (_bestPoolLiquidity({tokenA: normalizedTokenIn, tokenB: normalizedTokenOut}) == 0) {
            revert JBRouterTerminal_NoPoolFound(normalizedTokenIn, normalizedTokenOut);
        }

        (amountOut,) = _pickPoolAndQuote({
            metadata: metadata,
            normalizedTokenIn: normalizedTokenIn,
            amount: amount,
            normalizedTokenOut: normalizedTokenOut
        });
    }

    /// @notice Whether routing through a terminal would immediately cycle back into the router.
    /// @param projectId The destination project whose terminal topology is being checked.
    /// @param terminal The terminal that would receive the route.
    /// @return isCircular A flag indicating whether `terminal` resolves back into this router.
    function _isCircularTerminal(uint256 projectId, IJBTerminal terminal) internal view returns (bool isCircular) {
        return PAY_ROUTE_RESOLVER.isCircularTerminal(IJBPayRoutePreviewer(address(this)), projectId, terminal);
    }

    /// @notice Accepts a token being paid in.
    /// @param token The address of the token being paid in.
    /// @param amount The amount of tokens being paid in.
    /// @param metadata The metadata in which `permit2` and credit context is provided.
    /// @return The amount of tokens that have been accepted.
    function _acceptFundsFor(address token, uint256 amount, bytes calldata metadata) internal returns (uint256) {
        // Check for credit cash-out metadata.
        (bool creditExists, bytes memory creditData) =
            JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("cashOutSource"), metadata: metadata});

        if (creditExists) {
            // Credit cashouts don't use msg.value — revert if ETH was sent to prevent it being trapped.
            if (msg.value != 0) revert JBRouterTerminal_NoMsgValueAllowed(msg.value);

            (uint256 sourceProjectId, uint256 creditAmount) = abi.decode(creditData, (uint256, uint256));

            // Credit transfers must be attributed to the direct caller.
            // Intermediary-supplied payer metadata is not trusted for credit ownership.
            address holder = _msgSender();

            // Pull credits through the project's controller, which enforces holder permissions for credit transfers.
            IJBController controller = IJBController(address(DIRECTORY.controllerOf(sourceProjectId)));
            controller.transferCreditsFrom({
                holder: holder, projectId: sourceProjectId, recipient: address(this), creditCount: creditAmount
            });

            return creditAmount;
        }

        // If native tokens are being paid in, return the `msg.value`.
        if (token == JBConstants.NATIVE_TOKEN) return msg.value;

        // Otherwise, the `msg.value` should be 0.
        if (msg.value != 0) revert JBRouterTerminal_NoMsgValueAllowed(msg.value);

        // Unpack the `JBSingleAllowance` to use given by the frontend.
        (bool exists, bytes memory parsedMetadata) =
            JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("permit2"), metadata: metadata});

        // If the metadata contained permit data, use it to set the allowance.
        if (exists) {
            // Keep a reference to the allowance context parsed from the metadata.
            (JBSingleAllowance memory allowance) = abi.decode(parsedMetadata, (JBSingleAllowance));

            // Make sure the permit allowance is enough for this payment. If not, revert early.
            if (amount > allowance.amount) revert JBRouterTerminal_PermitAllowanceNotEnough(amount, allowance.amount);

            // Keep a reference to the permit rules.
            IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
                details: IAllowanceTransfer.PermitDetails({
                    token: token, amount: allowance.amount, expiration: allowance.expiration, nonce: allowance.nonce
                }),
                spender: address(this),
                sigDeadline: allowance.sigDeadline
            });

            // slither-disable-next-line reentrancy-events
            try PERMIT2.permit({owner: _msgSender(), permitSingle: permitSingle, signature: allowance.signature}) {}
            catch (bytes memory reason) {
                emit Permit2AllowanceFailed(token, _msgSender(), reason);
            }
        }

        // Fee-on-transfer tokens are not supported by design. The router uses balance-delta
        // checks for its own accounting but relies on underlying terminal behavior for FoT tokens. Projects
        // should avoid configuring FoT tokens.
        // Measure balance before transfer to determine actual tokens received (handles fee-on-transfer tokens).
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // Transfer the tokens from the `_msgSender()` to this terminal.
        _transferFrom({from: _msgSender(), to: payable(address(this)), token: token, amount: amount});

        // Return the actual amount received (balance delta), not the user-supplied amount.
        return IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    /// @notice Logic to be triggered before transferring tokens from this terminal.
    /// @param to The address to transfer tokens to.
    /// @param token The token being transferred.
    /// @param amount The amount of tokens to transfer.
    /// @return payValue The amount that will be paid as a `msg.value`.
    function _beforeTransferFor(address to, address token, uint256 amount) internal returns (uint256) {
        // If the token is the native token, return the amount as msg.value.
        if (token == JBConstants.NATIVE_TOKEN) return amount;

        // Otherwise, set the appropriate allowance for the recipient.
        IERC20(token).safeIncreaseAllowance({spender: to, value: amount});

        return 0;
    }

    /// @notice Recursively cash out JB project tokens until reaching a token the destination accepts or a base token.
    /// @param destProjectId The ID of the destination project.
    /// @param token The current token being processed.
    /// @param amount The amount of the current token.
    /// @param sourceProjectIdOverride When non-zero, use this as the source project ID instead of looking up via
    /// `TOKENS.projectIdOf()`. Reset to 0 after first use.
    /// @param metadata Bytes in `JBMetadataResolver`'s format (may contain cashOutMinReclaimed).
    /// @return destTerminal The terminal that accepts the final token (address(0) if no direct acceptance found).
    /// @return finalToken The token after all cashouts.
    /// @return finalAmount The amount of the final token.
    function _cashOutLoop(
        uint256 destProjectId,
        address token,
        uint256 amount,
        uint256 sourceProjectIdOverride,
        bytes calldata metadata,
        address preferredToken
    )
        internal
        returns (IJBTerminal destTerminal, address finalToken, uint256 finalAmount)
    {
        // Check for a user-provided minimum cashout reclaim amount (slippage protection).
        uint256 minTokensReclaimed = _minReclaimedFrom(metadata);

        // Propagate proportional slippage protection across multi-hop cashouts. Each intermediate step scales the
        // minimum by the ratio of actual output to expected input, maintaining end-to-end slippage guarantees.
        for (uint256 i; i < _MAX_CASHOUT_ITERATIONS; i++) {
            if (preferredToken != address(0)) {
                if (token == preferredToken || _normalize(token) == _normalize(preferredToken)) {
                    destTerminal = _primaryTerminalOf({projectId: destProjectId, token: preferredToken});
                    if (
                        address(destTerminal) != address(0) && address(destTerminal) != address(this)
                            && !_isCircularTerminal(destProjectId, destTerminal)
                    ) {
                        return (destTerminal, preferredToken, amount);
                    }
                }
            }
            // Skip the destination check on the first iteration if we have a credit override.
            else if (sourceProjectIdOverride == 0) {
                // slither-disable-next-line calls-loop
                destTerminal = _primaryTerminalOf({projectId: destProjectId, token: token});
                if (
                    address(destTerminal) != address(0) && address(destTerminal) != address(this)
                        && !_isCircularTerminal(destProjectId, destTerminal)
                ) {
                    return (destTerminal, token, amount);
                }
            }

            // Use the override if provided, otherwise look up the project ID from the token.
            // slither-disable-next-line calls-loop
            uint256 sourceProjectId = sourceProjectIdOverride != 0 ? sourceProjectIdOverride : _projectIdOf(token);

            // If it's not a JB project token, return as-is (caller handles the swap).
            if (sourceProjectId == 0) return (IJBTerminal(address(0)), token, amount);

            // Find which terminal to cash out from and which token to reclaim.
            (address tokenToReclaim, IJBCashOutTerminal cashOutTerminal) = _findCashOutPath({
                sourceProjectId: sourceProjectId, destProjectId: destProjectId, preferredToken: preferredToken
            });

            // Track the expected amount before cashout so we can scale the minimum proportionally.
            uint256 previousExpectedAmount = amount;
            uint256 balanceBefore = _balanceOf({token: tokenToReclaim, account: address(this)});

            // Cash out the source project's tokens.
            // Don't rely on the terminal return value here. Buyback-hook sell-side execution returns 0 reclaimAmount
            // from nana-core, then transfers the real proceeds during the hook callback.
            // slither-disable-next-line calls-loop
            cashOutTerminal.cashOutTokensOf({
                holder: address(this),
                projectId: sourceProjectId,
                cashOutCount: previousExpectedAmount,
                tokenToReclaim: tokenToReclaim,
                minTokensReclaimed: 0,
                beneficiary: payable(address(this)),
                metadata: ""
            });

            amount = _balanceOf({token: tokenToReclaim, account: address(this)}) - balanceBefore;
            if (amount < minTokensReclaimed) revert JBRouterTerminal_SlippageExceeded(amount, minTokensReclaimed);

            // Scale the minimum proportionally for the next step based on the actual cashout ratio.
            // This propagates slippage protection through multi-hop cashouts instead of dropping it.
            if (minTokensReclaimed != 0 && previousExpectedAmount != 0) {
                minTokensReclaimed = mulDiv(minTokensReclaimed, amount, previousExpectedAmount);
                // minTokensReclaimed may round to 0 here — that is intentional.
                // A 0 minimum is valid and means no slippage protection for this hop.
            }

            // Update for next iteration.
            token = tokenToReclaim;
            sourceProjectIdOverride = 0;
        }

        // If we reach here, the loop exceeded the maximum iteration count.
        revert JBRouterTerminal_CashOutLoopLimit();
    }

    /// @notice Convert tokenIn to tokenOut. No-op if same, wrap/unwrap for NATIVE/WETH, or swap via Uniswap.
    /// @param tokenIn The token to convert from.
    /// @param tokenOut The token to convert to.
    /// @param amount The amount to convert.
    /// @param projectId The project ID (passed through to swap callback data).
    /// @param metadata Bytes in `JBMetadataResolver`'s format (may contain quoteForSwap).
    /// @param refundTo The address to receive leftover input tokens from partial fills.
    /// @return The amount of tokenOut produced.
    function _convert(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 projectId,
        bytes calldata metadata,
        address payable refundTo,
        uint256 refundBalanceBaseline
    )
        internal
        returns (uint256)
    {
        // Exact same token — no conversion needed.
        if (tokenIn == tokenOut) return amount;

        address nIn = _normalize(tokenIn);
        address nOut = _normalize(tokenOut);

        if (nIn == nOut) {
            // Same underlying token — just wrap or unwrap.
            if (tokenIn == JBConstants.NATIVE_TOKEN) _wethDeposit(amount);
            else _wethWithdraw(amount);
            return amount;
        }

        // Different tokens — swap via Uniswap (V3 or V4).
        return _handleSwap({
            projectId: projectId,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amount: amount,
            metadata: metadata,
            refundTo: refundTo,
            refundBalanceBaseline: refundBalanceBaseline
        });
    }

    /// @notice Discover a pool, get a quote, and execute the swap (dispatches to V3 or V4).
    /// @dev Separated from _handleSwap to manage stack depth.
    function _executeSwap(
        address normalizedTokenIn,
        address normalizedTokenOut,
        uint256 amount,
        bytes calldata metadata,
        bytes memory callbackData
    )
        internal
        returns (uint256 amountOut)
    {
        (uint256 minAmountOut, PoolInfo memory pool) = _pickPoolAndQuote({
            metadata: metadata,
            normalizedTokenIn: normalizedTokenIn,
            amount: amount,
            normalizedTokenOut: normalizedTokenOut
        });

        if (pool.isV4) {
            return _executeV4Swap({
                key: pool.v4Key, normalizedTokenIn: normalizedTokenIn, amount: amount, minAmountOut: minAmountOut
            });
        } else {
            return _executeV3Swap({
                pool: pool.v3Pool,
                normalizedTokenIn: normalizedTokenIn,
                normalizedTokenOut: normalizedTokenOut,
                amount: amount,
                minAmountOut: minAmountOut,
                callbackData: callbackData
            });
        }
    }

    /// @notice Execute a swap through a V3 pool.
    function _executeV3Swap(
        IUniswapV3Pool pool,
        address normalizedTokenIn,
        address normalizedTokenOut,
        uint256 amount,
        uint256 minAmountOut,
        bytes memory callbackData
    )
        internal
        returns (uint256 amountOut)
    {
        bool zeroForOne = normalizedTokenIn < normalizedTokenOut;

        (int256 amount0, int256 amount1) = pool.swap({
            recipient: address(this),
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: JBSwapLib.sqrtPriceLimitFromAmounts({
                amountIn: amount, minimumAmountOut: minAmountOut, zeroForOne: zeroForOne
            }),
            data: callbackData
        });

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        if (amountOut < minAmountOut) revert JBRouterTerminal_SlippageExceeded(amountOut, minAmountOut);
    }

    /// @notice Execute a swap through a V4 pool via PoolManager.unlock().
    function _executeV4Swap(
        PoolKey memory key,
        address normalizedTokenIn,
        uint256 amount,
        uint256 minAmountOut
    )
        internal
        returns (uint256 amountOut)
    {
        // Convert WETH addresses to V4's native ETH (address(0)) for currency comparison.
        address v4In = normalizedTokenIn == address(WETH) ? address(0) : normalizedTokenIn;
        bool zeroForOne = Currency.unwrap(key.currency0) == v4In;

        // Use sqrtPriceLimitFromAmounts for partial-fill protection, consistent with V3 path.
        uint160 sqrtPriceLimitX96 = JBSwapLib.sqrtPriceLimitFromAmounts({
            amountIn: amount, minimumAmountOut: minAmountOut, zeroForOne: zeroForOne
        });

        // V4 sign convention: negative = exact input, positive = exact output.
        bytes memory result =
        // forge-lint: disable-next-line(unsafe-typecast)
        POOL_MANAGER.unlock(abi.encode(key, zeroForOne, -int256(amount), sqrtPriceLimitX96, minAmountOut));

        amountOut = abi.decode(result, (uint256));
    }

    /// @notice Execute a Uniswap swap from tokenIn to tokenOut (V3 or V4).
    /// @param projectId The project ID (included in callback data).
    /// @param tokenIn The input token.
    /// @param tokenOut The output token.
    /// @param amount The amount of tokenIn to swap.
    /// @param metadata Bytes in `JBMetadataResolver`'s format (may contain quoteForSwap).
    /// @param refundTo The address to receive leftover input tokens from partial fills.
    /// @return amountOut The amount of tokenOut received.
    function _handleSwap(
        uint256 projectId,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata metadata,
        address payable refundTo,
        uint256 refundBalanceBaseline
    )
        internal
        returns (uint256 amountOut)
    {
        address normalizedTokenIn = _normalize(tokenIn);
        uint256 nativeBalanceBaseline;
        if (tokenIn == JBConstants.NATIVE_TOKEN) nativeBalanceBaseline = address(this).balance - amount;

        // Execute the swap in a scoped block to manage stack depth.
        amountOut = _executeSwap({
            normalizedTokenIn: normalizedTokenIn,
            normalizedTokenOut: _normalize(tokenOut),
            amount: amount,
            metadata: metadata,
            callbackData: abi.encode(projectId, tokenIn, tokenOut)
        });

        // For native token inputs, wrap any raw ETH remaining from partial fills so the leftover check catches it.
        // In partial fills, the swap callback only wraps the amount the pool consumed, leaving excess as raw ETH.
        if (tokenIn == JBConstants.NATIVE_TOKEN && address(this).balance > nativeBalanceBaseline) {
            _wethDeposit(address(this).balance - nativeBalanceBaseline);
        }

        // Unwrap if output is native token.
        if (tokenOut == JBConstants.NATIVE_TOKEN) _wethWithdraw(amountOut);

        // Refund only the leftover portion attributable to this swap. Pre-existing balances are not part of the
        // caller's route and should not be swept into the current refund.
        uint256 balanceAfter = IERC20(normalizedTokenIn).balanceOf(address(this));
        if (balanceAfter > refundBalanceBaseline) {
            uint256 refundAmount = balanceAfter - refundBalanceBaseline;
            if (tokenIn == JBConstants.NATIVE_TOKEN) _wethWithdraw(refundAmount);
            _transferFrom({from: address(this), to: refundTo, token: tokenIn, amount: refundAmount});
        }
    }

    /// @notice Core routing logic shared by pay() and addToBalanceOf().
    /// @dev Determines whether to forward directly, cashout JB tokens, swap via Uniswap, or a combination.
    /// @param destProjectId The ID of the destination project.
    /// @param tokenIn The address of the token being routed.
    /// @param amount The amount of tokens being routed.
    /// @param metadata Bytes in `JBMetadataResolver`'s format.
    /// @param refundTo The address to receive leftover input tokens from partial fills.
    /// @return destTerminal The terminal to forward funds to.
    /// @return tokenOut The token the destination project accepts.
    /// @return amountOut The amount of tokenOut to forward.
    function _route(
        uint256 destProjectId,
        address tokenIn,
        uint256 amount,
        bytes calldata metadata,
        address payable refundTo
    )
        internal
        returns (IJBTerminal destTerminal, address tokenOut, uint256 amountOut)
    {
        // Route any project-token source through cashout before resolving the destination token.
        (destTerminal, tokenIn, amount) = _routeInputFromSource({
            destProjectId: destProjectId,
            tokenIn: tokenIn,
            amount: amount,
            metadata: metadata,
            preferredToken: address(0)
        });

        // If the cashout loop found a destination terminal, the route is already complete.
        if (address(destTerminal) != address(0)) return (destTerminal, tokenIn, amount);

        // Resolve what token the destination project accepts and which terminal to use.
        (tokenOut, destTerminal) = PAY_ROUTE_RESOLVER.resolveTokenOut({
            router: IJBPayRoutePreviewer(address(this)), projectId: destProjectId, tokenIn: tokenIn, metadata: metadata
        });

        uint256 refundBalanceBaseline = IERC20(_normalize(tokenIn)).balanceOf(address(this));
        if (tokenIn != JBConstants.NATIVE_TOKEN) refundBalanceBaseline -= amount;

        // Convert tokenIn -> tokenOut (no-op if they match, wrap/unwrap, or swap).
        amountOut = _convert({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amount: amount,
            projectId: destProjectId,
            metadata: metadata,
            refundTo: refundTo,
            refundBalanceBaseline: refundBalanceBaseline
        });
    }

    /// @notice Route funds to a specific destination token.
    function _routeToDestination(
        uint256 destProjectId,
        address tokenIn,
        uint256 amount,
        address tokenOut,
        bytes calldata metadata,
        address payable refundTo
    )
        internal
        returns (IJBTerminal destTerminal, address resolvedTokenOut, uint256 amountOut)
    {
        resolvedTokenOut = tokenOut;
        destTerminal = _primaryTerminalOf({projectId: destProjectId, token: tokenOut});
        if (address(destTerminal) == address(0)) revert JBRouterTerminal_NoRouteFound(destProjectId, tokenOut);

        IJBTerminal cashOutResolvedTerminal;
        (cashOutResolvedTerminal, tokenIn, amount) = _routeInputFromSource({
            destProjectId: destProjectId, tokenIn: tokenIn, amount: amount, metadata: metadata, preferredToken: tokenOut
        });
        if (address(cashOutResolvedTerminal) != address(0)) return (cashOutResolvedTerminal, tokenOut, amount);

        uint256 refundBalanceBaseline = IERC20(_normalize(tokenIn)).balanceOf(address(this));
        if (tokenIn != JBConstants.NATIVE_TOKEN) refundBalanceBaseline -= amount;

        amountOut = _convert({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amount: amount,
            projectId: destProjectId,
            metadata: metadata,
            refundTo: refundTo,
            refundBalanceBaseline: refundBalanceBaseline
        });
    }

    /// @notice Route the current input through a project-token cashout first when the route starts from a JB token.
    /// @param destProjectId The destination project the route is trying to reach.
    /// @param tokenIn The current route input token.
    /// @param amount The current route input amount.
    /// @param metadata Metadata that may include a cashout-source override.
    /// @param preferredToken The preferred token to target during any cashout loop.
    /// @return resolvedTerminal The terminal found by the cashout loop, or address(0) if conversion should continue.
    /// @return routedTokenIn The token that remains to be routed after the cashout step.
    /// @return routedAmountIn The amount of `routedTokenIn` that remains to be routed.
    function _routeInputFromSource(
        uint256 destProjectId,
        address tokenIn,
        uint256 amount,
        bytes calldata metadata,
        address preferredToken
    )
        internal
        returns (IJBTerminal resolvedTerminal, address routedTokenIn, uint256 routedAmountIn)
    {
        (uint256 sourceProjectIdOverride,) = _cashOutSourceFrom(metadata);
        uint256 sourceProjectId = sourceProjectIdOverride;
        if (sourceProjectId == 0 && tokenIn != JBConstants.NATIVE_TOKEN) {
            sourceProjectId = _projectIdOf(tokenIn);
        }

        if (sourceProjectId == 0) return (resolvedTerminal, tokenIn, amount);

        return _cashOutLoop({
            destProjectId: destProjectId,
            token: tokenIn,
            amount: amount,
            sourceProjectIdOverride: sourceProjectIdOverride,
            metadata: metadata,
            preferredToken: preferredToken
        });
    }

    /// @notice Settle the input side of a V4 swap (transfer tokens to PoolManager).
    function _settleV4(Currency currency, uint256 amount) internal {
        if (Currency.unwrap(currency) == address(0)) {
            // Unwrap only the WETH deficit (caller may hold partial ETH + partial WETH).
            uint256 deficit = amount > address(this).balance ? amount - address(this).balance : 0;
            if (deficit > 0) _wethWithdraw(deficit);
            // slither-disable-next-line unused-return
            POOL_MANAGER.settle{value: amount}();
        } else {
            // ERC20: sync then transfer then settle.
            POOL_MANAGER.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer({to: address(POOL_MANAGER), value: amount});
            // slither-disable-next-line unused-return
            POOL_MANAGER.settle();
        }
    }

    /// @notice Take the output side of a V4 swap (receive tokens from PoolManager).
    function _takeV4(Currency currency, uint256 amount) internal {
        POOL_MANAGER.take({currency: currency, to: address(this), amount: amount});

        // If native ETH output, wrap to WETH (downstream _handleSwap unwraps if needed).
        if (Currency.unwrap(currency) == address(0)) _wethDeposit(amount);
    }

    /// @notice Transfers tokens.
    /// @param from The address to transfer tokens from.
    /// @param to The address to transfer tokens to.
    /// @param token The address of the token being transferred.
    /// @param amount The amount of tokens to transfer.
    function _transferFrom(address from, address payable to, address token, uint256 amount) internal {
        if (from == address(this)) {
            // If the token is native token, assume the `sendValue` standard.
            if (token == JBConstants.NATIVE_TOKEN) return Address.sendValue({recipient: to, amount: amount});

            // If the transfer is from this terminal, use `safeTransfer`.
            return IERC20(token).safeTransfer({to: to, value: amount});
        }

        // If there's sufficient approval, transfer normally.
        if (IERC20(token).allowance({owner: address(from), spender: address(this)}) >= amount) {
            return IERC20(token).safeTransferFrom({from: from, to: to, value: amount});
        }

        // Otherwise, attempt to use the `permit2` method.
        if (amount > type(uint160).max) revert JBRouterTerminal_AmountOverflow(amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        PERMIT2.transferFrom({from: from, to: to, amount: uint160(amount), token: token});
    }

    /// @notice Deposit native tokens into WETH.
    /// @param amount The amount of native tokens to wrap.
    function _wethDeposit(uint256 amount) internal {
        WETH.deposit{value: amount}();
    }

    /// @notice Withdraw native tokens from WETH.
    /// @param amount The amount of WETH to unwrap.
    function _wethWithdraw(uint256 amount) internal {
        WETH.withdraw(amount);
    }

    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    /// @notice Look up the best pool address from the V3 factory.
    /// @param tokenA One token in the pair.
    /// @param tokenB The other token in the pair.
    /// @param fee The fee tier to query.
    /// @return The pool address, or address(0) if none exists.
    // slither-disable-next-line calls-loop
    function _getPool(address tokenA, address tokenB, uint24 fee) internal view returns (address) {
        return FACTORY.getPool({tokenA: tokenA, tokenB: tokenB, fee: fee});
    }

    /// @notice Look up the in-range liquidity for a V4 pool.
    /// @param id The pool ID.
    /// @return The pool's current in-range liquidity.
    function _getLiquidity(PoolId id) internal view returns (uint128) {
        return POOL_MANAGER.getLiquidity(id);
    }

    /// @notice Read slot0 from a V4 pool.
    /// @param id The pool ID.
    /// @return sqrtPriceX96 The current sqrt price.
    /// @return tick The current tick.
    /// @return protocolFee The protocol fee.
    /// @return lpFee The LP fee.
    // slither-disable-next-line unused-return
    function _getSlot0(PoolId id)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return POOL_MANAGER.getSlot0(id);
    }

    /// @notice Look up the primary terminal for a project and token.
    /// @param projectId The ID of the project.
    /// @param token The token to look up.
    /// @return The primary terminal, or IJBTerminal(address(0)) if none.
    // slither-disable-next-line calls-loop
    function _primaryTerminalOf(uint256 projectId, address token) internal view returns (IJBTerminal) {
        return DIRECTORY.primaryTerminalOf({projectId: projectId, token: token});
    }

    /// @notice Look up the project ID for a token.
    /// @param token The token address to query.
    /// @return The project ID, or 0 if the token is not a JB project token.
    function _projectIdOf(address token) internal view returns (uint256) {
        return TOKENS.projectIdOf(IJBToken(token));
    }

    /// @notice Find the highest liquidity across all V3 fee tiers and V4 pools for a token pair.
    /// @param tokenA One token in the pair.
    /// @param tokenB The other token in the pair.
    /// @return bestLiquidity The highest liquidity found, or 0 if no pool exists.
    // slither-disable-next-line calls-loop
    function _bestPoolLiquidity(address tokenA, address tokenB) internal view returns (uint128 bestLiquidity) {
        PoolInfo memory pool = _discoverPool(tokenA, tokenB);
        if (pool.isV4) return _getLiquidity(pool.v4Key.toId());
        if (address(pool.v3Pool) != address(0)) return pool.v3Pool.liquidity();
    }

    /// @notice Parse the optional `cashOutSource` metadata.
    /// @param metadata The metadata to inspect for a credit cashout override.
    /// @return sourceProjectId The source project override, or 0 if none is specified.
    /// @return amount The credit amount, or 0 if none is specified.
    function _cashOutSourceFrom(bytes calldata metadata)
        internal
        view
        returns (uint256 sourceProjectId, uint256 amount)
    {
        // Read the optional cash-out source payload from the metadata blob.
        (bool exists, bytes memory creditData) =
            JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("cashOutSource"), metadata: metadata});

        // Decode the source project and credit amount if the payload is present.
        if (exists) (sourceProjectId, amount) = abi.decode(creditData, (uint256, uint256));
    }

    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    /// @notice Search Uniswap V3 and V4 for the best pool between two tokens.
    /// @dev Returns the pool with the highest liquidity across both protocols.
    /// @param normalizedTokenIn The input token (wrapped if native).
    /// @param normalizedTokenOut The output token (wrapped if native).
    /// @return bestPool The pool with the highest liquidity.
    function _discoverPool(
        address normalizedTokenIn,
        address normalizedTokenOut
    )
        internal
        view
        returns (PoolInfo memory bestPool)
    {
        uint128 bestLiquidity;

        // Search V3.
        for (uint256 i; i < 4; i++) {
            // slither-disable-next-line calls-loop
            address poolAddr = _getPool({tokenA: normalizedTokenIn, tokenB: normalizedTokenOut, fee: _FEE_TIERS[i]});

            if (poolAddr == address(0)) continue;

            // slither-disable-next-line calls-loop
            uint128 poolLiquidity = IUniswapV3Pool(poolAddr).liquidity();

            if (poolLiquidity > bestLiquidity) {
                bestLiquidity = poolLiquidity;
                bestPool = PoolInfo({
                    isV4: false,
                    v3Pool: IUniswapV3Pool(poolAddr),
                    v4Key: PoolKey({
                        currency0: Currency.wrap(address(0)),
                        currency1: Currency.wrap(address(0)),
                        fee: 0,
                        tickSpacing: 0,
                        hooks: IHooks(address(0))
                    })
                });
            }
        }

        // Search V4.
        bestPool = _discoverV4Pool(normalizedTokenIn, normalizedTokenOut, bestLiquidity, bestPool);
    }

    /// @notice Search V4 vanilla pools and update bestPool if a V4 pool has higher liquidity.
    function _discoverV4Pool(
        address normalizedTokenIn,
        address normalizedTokenOut,
        uint128 currentBestLiquidity,
        PoolInfo memory bestPool
    )
        internal
        view
        returns (PoolInfo memory)
    {
        if (address(POOL_MANAGER) == address(0)) return bestPool;

        // Convert WETH -> address(0) for V4 native ETH representation.
        address v4In = normalizedTokenIn == address(WETH) ? address(0) : normalizedTokenIn;
        address v4Out = normalizedTokenOut == address(WETH) ? address(0) : normalizedTokenOut;

        // Sort currencies (currency0 < currency1).
        (address sorted0, address sorted1) = v4In < v4Out ? (v4In, v4Out) : (v4Out, v4In);

        for (uint256 i; i < 4; i++) {
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(sorted0),
                currency1: Currency.wrap(sorted1),
                fee: _V4_FEES[i],
                tickSpacing: _V4_TICK_SPACINGS[i],
                hooks: IHooks(address(0))
            });

            // slither-disable-next-line unused-return,calls-loop
            (uint160 sqrtPriceX96,,,) = _getSlot0(key.toId());
            // slither-disable-next-line incorrect-equality
            if (sqrtPriceX96 == 0) continue;

            // slither-disable-next-line calls-loop
            uint128 poolLiquidity = _getLiquidity(key.toId());
            if (poolLiquidity > currentBestLiquidity) {
                currentBestLiquidity = poolLiquidity;
                bestPool = PoolInfo({isV4: true, v3Pool: IUniswapV3Pool(address(0)), v4Key: key});
            }
        }

        return bestPool;
    }

    /// @notice Find which terminal to cash out from and which token to reclaim.
    /// @dev Prioritizes: 1) tokens the destination directly accepts, 2) JB project tokens (recursable),
    /// 3) any base token (the router will swap it).
    /// @param sourceProjectId The ID of the project whose tokens are being cashed out.
    /// @param destProjectId The ID of the destination project.
    /// @return tokenToReclaim The token to reclaim from the cash out.
    /// @return cashOutTerminal The terminal to cash out from.
    function _findCashOutPath(
        uint256 sourceProjectId,
        uint256 destProjectId,
        address preferredToken
    )
        internal
        view
        returns (address tokenToReclaim, IJBCashOutTerminal cashOutTerminal)
    {
        address fallbackToken;
        IJBCashOutTerminal fallbackTerminal;
        address baseFallbackToken;
        IJBCashOutTerminal baseFallbackTerminal;
        address directFallbackToken;
        IJBCashOutTerminal directFallbackTerminal;

        // slither-disable-next-line calls-loop
        IJBTerminal[] memory terminals = DIRECTORY.terminalsOf(sourceProjectId);

        for (uint256 i; i < terminals.length; i++) {
            // Check if this terminal supports the IJBCashOutTerminal interface.
            // slither-disable-next-line calls-loop
            try IERC165(address(terminals[i])).supportsInterface(type(IJBCashOutTerminal).interfaceId) returns (
                bool supported
            ) {
                if (!supported) continue;
            } catch {
                continue;
            }

            IJBCashOutTerminal terminal = IJBCashOutTerminal(address(terminals[i]));
            // slither-disable-next-line calls-loop
            JBAccountingContext[] memory contexts = terminals[i].accountingContextsOf(sourceProjectId);

            for (uint256 j; j < contexts.length; j++) {
                address contextToken = contexts[j].token;

                if (preferredToken != address(0) && contextToken == preferredToken) {
                    IJBTerminal preferredTerminal = _primaryTerminalOf({projectId: destProjectId, token: contextToken});
                    if (address(preferredTerminal) != address(0)) return (contextToken, terminal);
                }

                // Priority 1: Does the destination project directly accept this token?
                // slither-disable-next-line calls-loop
                IJBTerminal destTerminal = _primaryTerminalOf({projectId: destProjectId, token: contextToken});
                if (address(destTerminal) != address(0) && address(directFallbackTerminal) == address(0)) {
                    directFallbackToken = contextToken;
                    directFallbackTerminal = terminal;
                }

                // Priority 2: Is this a JB project token (so we can recurse)?
                if (address(fallbackTerminal) == address(0) && contextToken != JBConstants.NATIVE_TOKEN) {
                    // slither-disable-next-line calls-loop
                    if (_projectIdOf(contextToken) != 0) {
                        fallbackToken = contextToken;
                        fallbackTerminal = terminal;
                    }
                }

                // Priority 3: Any base token (the router will swap it).
                if (address(baseFallbackTerminal) == address(0)) {
                    baseFallbackToken = contextToken;
                    baseFallbackTerminal = terminal;
                }
            }
        }

        if (address(directFallbackTerminal) != address(0)) return (directFallbackToken, directFallbackTerminal);
        if (address(fallbackTerminal) != address(0)) return (fallbackToken, fallbackTerminal);
        if (address(baseFallbackTerminal) != address(0)) return (baseFallbackToken, baseFallbackTerminal);

        revert JBRouterTerminal_NoCashOutPath(sourceProjectId, destProjectId);
    }

    /// @notice Get the slippage tolerance for a given swap using the continuous sigmoid formula.
    /// @param amountIn The amount of tokens being swapped.
    /// @param liquidity The pool's in-range liquidity.
    /// @param tokenOut The output token.
    /// @param tokenIn The input token.
    /// @param arithmeticMeanTick The TWAP arithmetic mean tick (or spot tick for V4).
    /// @param poolFeeBps The pool fee in basis points.
    /// @return The slippage tolerance in basis points of _SLIPPAGE_DENOMINATOR.
    function _getSlippageTolerance(
        uint256 amountIn,
        uint128 liquidity,
        address tokenOut,
        address tokenIn,
        int24 arithmeticMeanTick,
        uint256 poolFeeBps
    )
        internal
        pure
        returns (uint256)
    {
        (address token0,) = tokenOut < tokenIn ? (tokenOut, tokenIn) : (tokenIn, tokenOut);
        bool zeroForOne = tokenIn == token0;

        uint160 sqrtP = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);
        if (sqrtP == 0) return _SLIPPAGE_DENOMINATOR;

        uint256 impact =
            JBSwapLib.calculateImpact({amountIn: amountIn, liquidity: liquidity, sqrtP: sqrtP, zeroForOne: zeroForOne});
        return JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: poolFeeBps});
    }

    /// @notice Get a TWAP-based quote with dynamic slippage for a V3 pool.
    function _getV3TwapQuote(
        IUniswapV3Pool pool,
        address normalizedTokenIn,
        address normalizedTokenOut,
        uint256 amount
    )
        internal
        view
        returns (uint256 minAmountOut)
    {
        uint256 feeBps = uint256(pool.fee()) / 100;
        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(address(pool));
        if (oldestObservation == 0) revert JBRouterTerminal_NoObservationHistory();

        uint256 twapWindow = DEFAULT_TWAP_WINDOW;
        if (oldestObservation < twapWindow) twapWindow = oldestObservation;

        // Enforce a minimum TWAP window to prevent manipulation of short-history pools.
        if (twapWindow < MIN_TWAP_WINDOW) revert JBRouterTerminal_InsufficientTwapHistory();

        (
            int24 arithmeticMeanTick,
            uint128 liquidity
            // forge-lint: disable-next-line(unsafe-typecast)
        ) = OracleLibrary.consult({pool: address(pool), secondsAgo: uint32(twapWindow)});

        if (liquidity == 0) revert JBRouterTerminal_NoLiquidity();

        minAmountOut = _quoteWithSlippage({
            amount: amount,
            liquidity: liquidity,
            tokenIn: normalizedTokenIn,
            tokenOut: normalizedTokenOut,
            tick: arithmeticMeanTick,
            poolFeeBps: feeBps
        });
    }

    /// @notice Get a spot-price-based quote with dynamic slippage for a V4 pool.
    /// @dev V4 vanilla pools have no TWAP oracle. Uses spot tick with the same sigmoid slippage formula.
    ///
    /// SECURITY NOTE: The spot price read from `POOL_MANAGER.getSlot0(id)` is an instantaneous value
    /// that can be manipulated within the same block (e.g. via sandwich attacks or flash loans). Unlike V3 pools,
    /// V4 vanilla pools do not expose a built-in TWAP oracle, so there is no manipulation-resistant price source
    /// available on-chain for automatic quoting.
    ///
    /// Mitigations in place:
    ///   1. Users SHOULD provide a `quoteForSwap` value in the payment metadata (obtained from an off-chain
    ///      quoter or RPC simulation). When present, this function is bypassed entirely — see `_pickPoolAndQuote`.
    ///   2. The sigmoid slippage formula (`JBSwapLib.getSlippageTolerance`) enforces a minimum 2% slippage floor
    ///      (pool fee + 1%, with a hard floor of 2%), which bounds the worst-case loss even if the spot price is
    ///      manipulated. For small swaps in deep pools the tolerance stays near this floor; for larger swaps it
    ///      scales up to the 88% ceiling via a continuous sigmoid curve.
    ///   3. Pool discovery (`_discoverPool`) may select a V3 pool with TWAP if it has more liquidity, avoiding
    ///      this V4 spot-price path altogether.
    ///
    /// Despite these mitigations, the spot-based quote does NOT provide full MEV protection. Integrators and
    /// front-ends should always supply `quoteForSwap` metadata for V4 swaps to ensure the user's slippage
    /// tolerance reflects a recent, off-chain-verified price.
    function _getV4SpotQuote(
        PoolKey memory key,
        address normalizedTokenIn,
        address normalizedTokenOut,
        uint256 amount
    )
        internal
        view
        returns (uint256 minAmountOut)
    {
        PoolId id = key.toId();

        // The tick used for quoting — prefer TWAP over spot for MEV resistance.
        int24 tick;

        // Track whether the oracle hook provided a TWAP so we know whether to fall back to spot.
        bool usedTwap;

        // If the pool has a hook, try querying it as a geomean oracle (e.g., JBUniswapV4Hook implements this).
        if (address(key.hooks) != address(0)) {
            // Build the two-element lookback array: [_TWAP_WINDOW seconds ago, now].
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = _TWAP_WINDOW; // Start of the window (30 seconds ago).
            secondsAgos[1] = 0; // End of the window (current block).

            // Ask the hook for cumulative tick data over the window. Silently catch if it doesn't support it.
            // slither-disable-next-line unused-return
            try IGeomeanOracle(address(key.hooks)).observe(key, secondsAgos) returns (
                int56[] memory tickCumulatives, uint160[] memory
            ) {
                // Derive the arithmetic mean tick: (cumulative_now - cumulative_start) / elapsed_seconds.
                // forge-lint: disable-next-line(unsafe-typecast)
                tick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(int32(_TWAP_WINDOW)));
                usedTwap = true;
            } catch {}
        }

        // If no TWAP was available (no hook, or hook doesn't implement observe), use the instantaneous spot tick.
        if (!usedTwap) {
            // slither-disable-next-line unused-return
            (, tick,,) = _getSlot0(id);
        }

        uint128 liquidity = _getLiquidity(id);

        if (liquidity == 0) revert JBRouterTerminal_NoLiquidity();

        // V4 uses address(0) for native ETH; map WETH so OracleLibrary token sorting matches the pool.
        normalizedTokenIn = normalizedTokenIn == address(WETH) ? address(0) : normalizedTokenIn;
        normalizedTokenOut = normalizedTokenOut == address(WETH) ? address(0) : normalizedTokenOut;

        minAmountOut = _quoteWithSlippage({
            amount: amount,
            liquidity: liquidity,
            tokenIn: normalizedTokenIn,
            tokenOut: normalizedTokenOut,
            tick: tick,
            poolFeeBps: uint256(key.fee) / 100
        });
    }

    /// @notice Parse the optional `cashOutMinReclaimed` metadata.
    /// @param metadata The metadata to inspect for a minimum reclaim amount.
    /// @return minTokensReclaimed The minimum reclaim amount, or 0 if none is specified.
    function _minReclaimedFrom(bytes calldata metadata) internal view returns (uint256 minTokensReclaimed) {
        (bool exists, bytes memory minData) =
            JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("cashOutMinReclaimed"), metadata: metadata});
        if (exists) minTokensReclaimed = abi.decode(minData, (uint256));
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    /// @return calldata The `msg.data` of this call.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    /// @return sender The address which sent this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    /// @notice Return the balance of an account for a token, using ETH balance for the native token sentinel.
    function _balanceOf(address token, address account) internal view returns (uint256) {
        return token == JBConstants.NATIVE_TOKEN ? account.balance : IERC20(_normalize(token)).balanceOf(account);
    }

    /// @notice Normalize a token address by replacing the native token sentinel with WETH.
    function _normalize(address token) internal view returns (address) {
        return token == JBConstants.NATIVE_TOKEN ? address(WETH) : token;
    }

    /// @notice Discover a pool and compute the minimum acceptable output for a swap.
    /// @dev Uses a user-provided quote if available, otherwise falls back to TWAP (V3) or spot price (V4)
    /// with dynamic slippage.
    ///
    /// Priority for `minAmountOut`:
    ///   1. **User-provided quote** — If `quoteForSwap` is present in `metadata`, it is used directly.
    ///      This is the recommended path for MEV protection, especially for V4 pools.
    ///   2. **V3 TWAP** — If the best pool is V3, uses a manipulation-resistant time-weighted average price.
    ///   3. **V4 spot price** — If the best pool is V4, uses the instantaneous `getSlot0` tick. This is
    ///      manipulable within the same block (see `_getV4SpotQuote` security note). The sigmoid slippage
    ///      formula provides a floor but not full MEV protection.
    ///
    /// @param metadata Bytes in `JBMetadataResolver`'s format (may contain quoteForSwap).
    /// @param normalizedTokenIn The normalized input token address.
    /// @param amount The amount of tokens to swap.
    /// @param normalizedTokenOut The normalized output token address.
    /// @return minAmountOut The minimum acceptable output.
    /// @return pool The pool to swap in (V3 or V4).
    function _pickPoolAndQuote(
        bytes calldata metadata,
        address normalizedTokenIn,
        uint256 amount,
        address normalizedTokenOut
    )
        internal
        view
        returns (uint256 minAmountOut, PoolInfo memory pool)
    {
        // Discover the best pool across V3 and V4 fee tiers.
        pool = _discoverPool(normalizedTokenIn, normalizedTokenOut);
        if (!pool.isV4 && address(pool.v3Pool) == address(0)) {
            revert JBRouterTerminal_NoPoolFound(normalizedTokenIn, normalizedTokenOut);
        }

        // Check for a user-provided quote.
        (bool exists, bytes memory quote) =
            JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("quoteForSwap"), metadata: metadata});

        if (exists) {
            (minAmountOut) = abi.decode(quote, (uint256));
        }

        // Treat a decoded value of 0 the same as "not provided" so that a stale or default-zero quote
        // does not silently disable slippage protection. Fall through to automatic quoting.
        if (minAmountOut != 0) {
            // User-provided quote is valid; skip automatic quoting.
        } else if (pool.isV4) {
            minAmountOut = _getV4SpotQuote({
                key: pool.v4Key,
                normalizedTokenIn: normalizedTokenIn,
                normalizedTokenOut: normalizedTokenOut,
                amount: amount
            });
        } else {
            minAmountOut = _getV3TwapQuote({
                pool: pool.v3Pool,
                normalizedTokenIn: normalizedTokenIn,
                normalizedTokenOut: normalizedTokenOut,
                amount: amount
            });
        }
    }

    /// @notice A view-only mirror of `_acceptFundsFor` used for previews.
    /// @dev Preview semantics use the caller-supplied `amount` as the intended input amount.
    /// @param amount The caller-supplied payment amount.
    /// @param metadata The metadata to inspect for a credit cashout override.
    /// @return The effective amount that routing should use.
    function _previewAcceptFundsFor(uint256 amount, bytes calldata metadata) internal view returns (uint256) {
        // Credit cashouts use the credit amount encoded in metadata rather than the raw token amount.
        (uint256 sourceProjectId, uint256 creditAmount) = _cashOutSourceFrom(metadata);

        // Mirror execution semantics exactly: the presence of a source override means the decoded
        // credit amount, even `0`, is the effective routed amount.
        if (sourceProjectId != 0) return creditAmount;

        // Otherwise, use the caller-specified amount unchanged.
        return amount;
    }

    /// @notice A view-only mirror of `_cashOutLoop`.
    /// @param destProjectId The ID of the destination project.
    /// @param token The current token being processed.
    /// @param amount The amount of the current token.
    /// @param sourceProjectIdOverride An optional source project override from metadata.
    /// @param metadata Bytes in `JBMetadataResolver`'s format.
    /// @return destTerminal The terminal that accepts the final token, if found.
    /// @return finalToken The token after all cash-out steps.
    /// @return finalAmount The amount of the final token.
    function _previewCashOutLoop(
        uint256 destProjectId,
        address token,
        uint256 amount,
        uint256 sourceProjectIdOverride,
        bytes calldata metadata,
        address preferredToken
    )
        internal
        view
        returns (IJBTerminal destTerminal, address finalToken, uint256 finalAmount)
    {
        // Track the one-time minimum reclaim amount that the caller may require on the first hop.
        uint256 minTokensReclaimed = _minReclaimedFrom(metadata);

        // Walk the same cash-out path execution would take, bounded to prevent circular routes.
        for (uint256 i; i < _MAX_CASHOUT_ITERATIONS; i++) {
            if (preferredToken != address(0)) {
                if (token == preferredToken || _normalize(token) == _normalize(preferredToken)) {
                    destTerminal = _primaryTerminalOf({projectId: destProjectId, token: preferredToken});
                    if (
                        address(destTerminal) != address(0) && address(destTerminal) != address(this)
                            && !_isCircularTerminal(destProjectId, destTerminal)
                    ) {
                        return (destTerminal, preferredToken, amount);
                    }
                }
            }
            // Only probe direct destination acceptance when there is no one-shot source override to consume first.
            else if (sourceProjectIdOverride == 0) {
                // Ask the directory whether the destination already has a primary terminal for the current token.
                destTerminal = _primaryTerminalOf({projectId: destProjectId, token: token});

                // If a real external terminal accepts this token, the preview route is complete and exact.
                if (
                    address(destTerminal) != address(0) && address(destTerminal) != address(this)
                        && !_isCircularTerminal(destProjectId, destTerminal)
                ) {
                    return (destTerminal, token, amount);
                }
            }

            // Use the override once when present; otherwise infer the source project from the current JB token.
            uint256 sourceProjectId = sourceProjectIdOverride != 0 ? sourceProjectIdOverride : _projectIdOf(token);

            // If this is no longer a JB project token, stop cashing out and let the caller continue routing from it.
            if (sourceProjectId == 0) return (IJBTerminal(address(0)), token, amount);

            // Hold the token produced by the next previewed cashout hop.
            address tokenToReclaim;

            // Track the expected amount before cashout so we can scale the minimum proportionally.
            uint256 previousExpectedAmount = amount;

            // Preview the next cashout hop to learn which base token and amount would come out.
            (tokenToReclaim, amount) = _previewCashOutStep({
                sourceProjectId: sourceProjectId,
                destProjectId: destProjectId,
                amount: previousExpectedAmount,
                preferredToken: preferredToken
            });

            // Enforce the caller's minimum reclaim amount on this hop.
            if (amount < minTokensReclaimed) revert JBRouterTerminal_SlippageExceeded(amount, minTokensReclaimed);

            // Scale the minimum proportionally for the next step based on the actual cashout ratio.
            if (minTokensReclaimed != 0 && previousExpectedAmount != 0) {
                minTokensReclaimed = mulDiv(minTokensReclaimed, amount, previousExpectedAmount);
                // minTokensReclaimed may round to 0 here — that is intentional.
                // A 0 minimum is valid and means no slippage protection for this hop.
            }

            // Continue previewing from the token reclaimed in this hop.
            token = tokenToReclaim;

            // Consume the one-shot override so later hops derive their project from the reclaimed token itself.
            sourceProjectIdOverride = 0;
        }

        // If no terminal was reached within the iteration cap, treat the route as non-converging.
        revert JBRouterTerminal_CashOutLoopLimit();
    }

    /// @notice Preview a single cashout hop in the recursive cashout path.
    /// @param sourceProjectId The project whose tokens are being cashed out.
    /// @param destProjectId The final destination project being paid.
    /// @param amount The amount of source-project tokens to cash out.
    /// @return tokenToReclaim The token that would be reclaimed from the source terminal.
    /// @return reclaimAmount The amount of that token that would be reclaimed.
    function _previewCashOutStep(
        uint256 sourceProjectId,
        uint256 destProjectId,
        uint256 amount,
        address preferredToken
    )
        internal
        view
        returns (address tokenToReclaim, uint256 reclaimAmount)
    {
        // Hold the terminal that would process this cashout hop.
        IJBCashOutTerminal cashOutTerminal;

        // Resolve both the reclaim token and the terminal the router would use for this hop.
        (tokenToReclaim, cashOutTerminal) = _findCashOutPath({
            sourceProjectId: sourceProjectId, destProjectId: destProjectId, preferredToken: preferredToken
        });

        // Ask that terminal how much of the reclaim token this cashout count would return.
        // slither-disable-next-line unused-return,calls-loop
        JBCashOutHookSpecification[] memory hookSpecifications;
        (, reclaimAmount,, hookSpecifications) = cashOutTerminal.previewCashOutFrom({
            holder: address(this),
            projectId: sourceProjectId,
            cashOutCount: amount,
            tokenToReclaim: tokenToReclaim,
            beneficiary: payable(address(this)),
            metadata: ""
        });

        reclaimAmount = _effectivePreviewCashOutAmount(reclaimAmount, hookSpecifications);
    }

    /// @notice Get a minimum-amount-out quote at the given tick, applying dynamic slippage.
    /// @param amount The input amount.
    /// @param liquidity The pool's in-range liquidity.
    /// @param tokenIn The input token address (used for token sorting and quoting).
    /// @param tokenOut The output token address (used for token sorting and quoting).
    /// @param tick The tick to quote at (TWAP mean tick or spot tick).
    /// @param poolFeeBps The pool fee in basis points.
    /// @return minAmountOut The quoted output amount after slippage.
    function _quoteWithSlippage(
        uint256 amount,
        uint128 liquidity,
        address tokenIn,
        address tokenOut,
        int24 tick,
        uint256 poolFeeBps
    )
        internal
        pure
        returns (uint256 minAmountOut)
    {
        uint256 slippageTolerance = _getSlippageTolerance({
            amountIn: amount,
            liquidity: liquidity,
            tokenOut: tokenOut,
            tokenIn: tokenIn,
            arithmeticMeanTick: tick,
            poolFeeBps: poolFeeBps
        });

        if (slippageTolerance >= _SLIPPAGE_DENOMINATOR) return 0;

        if (amount > type(uint128).max) revert JBRouterTerminal_AmountOverflow(amount);

        minAmountOut = OracleLibrary.getQuoteAtTick({
            tick: tick,
            // forge-lint: disable-next-line(unsafe-typecast)
            baseAmount: uint128(amount),
            baseToken: tokenIn,
            quoteToken: tokenOut
        });

        minAmountOut -= (minAmountOut * slippageTolerance) / _SLIPPAGE_DENOMINATOR;
    }
}
