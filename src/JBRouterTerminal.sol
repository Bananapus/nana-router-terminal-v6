// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermitTerminal} from "@bananapus/core-v6/src/interfaces/IJBPermitTerminal.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
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
import {IJBCashOutTerminalCrossProject} from "./interfaces/IJBCashOutTerminalCrossProject.sol";
import {IJBForwardingTerminal} from "./interfaces/IJBForwardingTerminal.sol";
import {IJBPayerTracker} from "./interfaces/IJBPayerTracker.sol";
import {IJBPayRoutePreviewer} from "./interfaces/IJBPayRoutePreviewer.sol";
import {IJBPayRouteResolver} from "./interfaces/IJBPayRouteResolver.sol";
import {IJBRouterTerminal} from "./interfaces/IJBRouterTerminal.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {JBForwardingCheck} from "./libraries/JBForwardingCheck.sol";
import {JBSwapLib} from "./libraries/JBSwapLib.sol";
import {JBPayRouteResolver} from "./JBPayRouteResolver.sol";
import {PoolInfo} from "./structs/PoolInfo.sol";

/// @notice A universal payment terminal that accepts any token and automatically converts it into whatever token the
/// destination project accepts. Routes payments via direct forwarding, Uniswap V3/V4 swaps, recursive JB token
/// cashouts, or a combination — always selecting the path that yields the most project tokens for the beneficiary.
/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
contract JBRouterTerminal is
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

    error JBRouterTerminal_AlreadyConfigured();
    error JBRouterTerminal_AmountOverflow(uint256 amount);
    error JBRouterTerminal_CallerNotPool(address caller);
    error JBRouterTerminal_CallerNotPoolManager(address caller);
    error JBRouterTerminal_InsufficientTwapHistory(address pool, uint256 twapWindow, uint256 minTwapWindow);
    error JBRouterTerminal_NoCashOutPath(uint256 sourceProjectId, uint256 destProjectId);
    error JBRouterTerminal_NoLiquidity(address pool, PoolId poolId);
    error JBRouterTerminal_NoMsgValueAllowed(uint256 value);
    error JBRouterTerminal_NoObservationHistory(address pool);
    error JBRouterTerminal_NoPoolFound(address tokenIn, address tokenOut);
    error JBRouterTerminal_HeldFeeReturnNotSupportedForProjectTokenInput();
    error JBRouterTerminal_NonStandardTerminalToken(
        address terminal, address token, uint256 expectedAmount, uint256 actualAmount
    );
    error JBRouterTerminal_PermitAllowanceNotEnough(uint256 amount, uint256 allowance);
    error JBRouterTerminal_SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error JBRouterTerminal_Unauthorized(address caller);

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

    /// @notice The denominator used for slippage tolerance basis points.
    uint256 internal constant _SLIPPAGE_DENOMINATOR = 10_000;

    /// @notice The TWAP window (in seconds) used when querying a V4 oracle hook.
    /// @dev Matches the V3 minimum TWAP window (MIN_TWAP_WINDOW = 120) to resist short-window manipulation.
    uint32 private constant _TWAP_WINDOW = 120;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The canonical buyback hook whose preview hook specification metadata this router understands.
    /// @dev Chain-same: `JBBuybackHook` is deployed via CREATE2 to a unified address on every chain, so this stays
    /// `immutable` without breaking the router's own chain-same CREATE2 address.
    address public immutable BUYBACK_HOOK;

    /// @notice The directory of terminals and controllers for projects.
    IJBDirectory public immutable DIRECTORY;

    /// @notice The Permit2 contract used for token approvals and transfers.
    IPermit2 public immutable override PERMIT2;

    /// @notice Manages minting, burning, and balances of projects' tokens and token credits.
    IJBTokens public immutable TOKENS;

    //*********************************************************************//
    // -------------- internal immutable stored properties -------------- //
    //*********************************************************************//

    /// @notice The deployer authorized to call `setChainSpecificConstants` exactly once.
    /// @dev Held immutable so the constructor inputs are byte-identical across chains and the CREATE2 address is
    /// unified. Mirrors the `JBOptimismSuckerDeployer.setChainSpecificConstants` pattern in nana-suckers-v6.
    address internal immutable _DEPLOYER;

    /// @notice The helper contract used to resolve best pay-route previews without bloating router runtime size.
    /// @dev Deployed in the constructor with chain-same inputs (just `directory` — the resolver does NOT cache
    /// `WRAPPED_NATIVE_TOKEN` locally; the router passes it in on every external resolver call as a parameter to
    /// avoid an extra external call on each normalization step). Because this router's address is chain-same via
    /// CREATE2 and the resolver is deployed at the router's nonce 1, the resolver's address is chain-same too.
    IJBPayRouteResolver internal immutable _PAY_ROUTE_RESOLVER;

    /// @notice Pre-computed metadata ID for "permit2".
    bytes4 internal immutable _PERMIT2_ID;

    /// @notice Pre-computed metadata ID for "quoteForSwap".
    bytes4 internal immutable _QUOTE_FOR_SWAP_ID;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The Uniswap V3 factory used for pool discovery and verification.
    /// @dev Set once by `_DEPLOYER` via `setChainSpecificConstants`. Held as storage rather than immutable so the
    /// constructor inputs are byte-identical on every chain (Uniswap V3 deploys to a different factory address per
    /// chain).
    IUniswapV3Factory public FACTORY;

    /// @notice The Uniswap V4 PoolManager. Can be `address(0)` if V4 is not deployed on this chain.
    /// @dev Set once by `_DEPLOYER` via `setChainSpecificConstants`. Held as storage rather than immutable so the
    /// constructor inputs are byte-identical on every chain.
    IPoolManager public POOL_MANAGER;

    /// @notice The canonical Uniswap V4 router hook address used by supported hooked pools.
    /// @dev Set once by `_DEPLOYER` via `setChainSpecificConstants`. Held as storage rather than immutable because
    /// `JBUniswapV4Hook` inherits Uniswap's `BaseHook -> ImmutableState`, which forces a chain-specific PoolManager
    /// immutable inside the hook itself — making the hook chain-different by design.
    address public UNIV4_HOOK;

    /// @notice The ERC-20 wrapper for the native token.
    /// @dev Set once by `_DEPLOYER` via `setChainSpecificConstants`. Held as storage rather than immutable so the
    /// constructor inputs are byte-identical on every chain (WETH/WCELO/etc. differ per chain).
    IWETH9 public override WRAPPED_NATIVE_TOKEN;

    //*********************************************************************//
    // ---------------------- internal stored properties ----------------- //
    //*********************************************************************//

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param tokens A contract managing project token balances.
    /// @param permit2 A permit2 utility.
    /// @param buybackHook The canonical buyback hook (chain-same across all chains).
    /// @param trustedForwarder The trusted forwarder for the contract.
    /// @param deployer The address authorized to call `setChainSpecificConstants` exactly once. Held immutable so the
    /// constructor inputs are byte-identical across chains and the CREATE2 address is unified.
    constructor(
        IJBDirectory directory,
        IJBTokens tokens,
        IPermit2 permit2,
        address buybackHook,
        address trustedForwarder,
        address deployer
    )
        ERC2771Context(trustedForwarder)
    {
        DIRECTORY = directory;
        TOKENS = tokens;
        PERMIT2 = permit2;
        BUYBACK_HOOK = buybackHook;
        _DEPLOYER = deployer;
        _PAY_ROUTE_RESOLVER = IJBPayRouteResolver(address(new JBPayRouteResolver({directory: directory})));

        // Pre-compute metadata IDs to avoid hashing string literals on every call.
        _PERMIT2_ID = JBMetadataResolver.getId("permit2");
        _QUOTE_FOR_SWAP_ID = JBMetadataResolver.getId("quoteForSwap");
    }

    //*********************************************************************//
    // ---------------------- receive / fallback ------------------------- //
    //*********************************************************************//

    /// @notice Receive native tokens from cash out reclaims, wrapped-native-token unwraps, and V4 PoolManager takes.
    receive() external payable {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Empty implementation to satisfy the interface. Accounting contexts are determined dynamically.
    /// @param projectId The ID of the project whose accounting contexts would otherwise be configured.
    /// @param accountingContexts Ignored because this terminal derives accounting contexts at runtime.
    function addAccountingContextsFor(
        uint256 projectId,
        JBAccountingContext[] calldata accountingContexts
    )
        external
        override
    {}

    /// @notice Add funds to a project's balance by routing the incoming token to whatever token the project accepts.
    /// @dev When `token` is a JB project token, the router routes through the source project's atomic
    /// `addToBalanceAfterCashOutTokensOf` entrypoint so the source-side cash-out fee is skipped and bound on the
    /// destination project's fee-free surplus instead. `shouldReturnHeldFees` is not honored in that path — the
    /// underlying core entrypoint is value top-up only and hardcodes held-fee return to `false`, so the router
    /// reverts when both are set together rather than silently dropping the flag.
    /// @param projectId The ID of the destination project.
    /// @param token The address of the token to pay in.
    /// @param amount The amount of tokens to send.
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
        // Accept the caller's funds first so the actual received balance drives every later decision.
        amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});

        // When the payer presents another project's tokens, route through the source project's atomic cross-project
        // cashout entrypoint so the source-side fee is skipped and bound on the destination project's fee-free surplus
        // instead.
        uint256 sourceProjectId = _sourceProjectIdOf(token);
        if (sourceProjectId != 0) {
            // Core's `addToBalanceAfterCashOutTokensOf` hardcodes held-fee return to `false`. Surface a clear error
            // instead of silently dropping a flag the caller asked for.
            if (shouldReturnHeldFees) revert JBRouterTerminal_HeldFeeReturnNotSupportedForProjectTokenInput();
            _addToBalanceAfterCashOut({
                sourceProjectId: sourceProjectId,
                cashOutCount: amount,
                beneficiaryProjectId: projectId,
                addToBalanceMetadata: metadata
            });
            return;
        }

        // Keep a reference to the terminal that will ultimately receive the routed funds.
        IJBTerminal destTerminal;

        // Resolve the route and return the terminal/token/amount the destination will see.
        (destTerminal, token, amount) = _route({
            destProjectId: projectId,
            tokenIn: token,
            amount: amount,
            metadata: metadata,
            refundTo: payable(_resolveOriginalPayer(_msgSender()))
        });

        // Prepare the final transfer into the destination terminal, using `msg.value` only when the final token is
        // native.
        uint256 payValue = _beforeTransferFor({to: address(destTerminal), token: token, amount: amount});

        // Snapshot the destination terminal's ERC20 balance and forwarding status for receipt enforcement.
        // Combines both checks into one call to avoid duplicate _isForwardingTerminal probes.
        (uint256 terminalReceiptBaseline, bool isForwarding) =
            _terminalReceiptBaselineOf({terminal: destTerminal, token: token, projectId: projectId});

        // Forward the fully routed funds into the destination terminal's add-to-balance flow.
        destTerminal.addToBalanceOf{value: payValue}({
            projectId: projectId,
            token: token,
            amount: amount,
            shouldReturnHeldFees: shouldReturnHeldFees,
            memo: memo,
            metadata: metadata
        });

        _afterTransferFor({destTerminal: destTerminal, token: token});

        // Reject fee-on-transfer or otherwise lossy ERC20 terminal pulls on the final forwarded hop.
        _enforceStandardTerminalReceipt({
            terminal: destTerminal,
            token: token,
            expectedAmount: amount,
            receiptBaseline: terminalReceiptBaseline,
            isForwarding: isForwarding
        });
    }

    /// @notice Empty implementation to satisfy the interface. This terminal has no balance to migrate.
    /// @param projectId The project whose balance migration was requested.
    /// @param token The token whose balance migration was requested.
    /// @param to The destination terminal that would receive migrated funds.
    /// @return balance Always returns 0 because the router does not hold project balances.
    function migrateBalanceOf(
        uint256 projectId,
        address token,
        IJBTerminal to
    )
        external
        pure
        override
        returns (uint256 balance)
    {
        projectId;
        token;
        to;
        return 0;
    }

    /// @notice Pay a project by routing the incoming token to whatever token the project accepts.
    /// @dev When `token` is a JB project token, the router routes through the source project's atomic
    /// `payAfterCashOutTokensOf` entrypoint so the source-side cash-out fee is skipped and bound on the destination
    /// project's fee-free surplus instead. Cashout-then-pay as two router-driven steps is intentionally gone — the
    /// destination project's current ruleset can opt out via `pauseCrossProjectFeeFreeInflows`, in which case the
    /// underlying core call reverts. For non-project-token inputs the router falls through to the standard route
    /// discovery (direct forwarding, Uniswap V3/V4 swaps, or a combination).
    /// @param projectId The ID of the destination project to pay.
    /// @param token The address of the token to pay with.
    /// @param amount The amount of tokens to send.
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
        // Accept the caller's funds first so the actual received balance drives every later decision.
        amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});

        // When the payer presents another project's tokens, route through the source project's atomic cross-project
        // cashout entrypoint so the source-side fee is skipped and bound on the destination project's fee-free surplus
        // instead.
        uint256 sourceProjectId = _sourceProjectIdOf(token);
        if (sourceProjectId != 0) {
            return _payAfterCashOut({
                sourceProjectId: sourceProjectId,
                cashOutCount: amount,
                beneficiaryProjectId: projectId,
                beneficiary: beneficiary,
                minTokensOut: minReturnedTokens,
                payMetadata: metadata
            });
        }

        // Non-project-token input — route via the standard pay-route discovery.
        IJBTerminal destTerminal;
        (destTerminal, token, amount) = _routeForPay({
            destProjectId: projectId,
            tokenIn: token,
            amount: amount,
            beneficiary: beneficiary,
            metadata: metadata,
            refundTo: payable(_resolveOriginalPayer(_msgSender()))
        });

        // Prepare the final transfer into the destination terminal, using `msg.value` only when the final token is
        // native.
        uint256 payValue = _beforeTransferFor({to: address(destTerminal), token: token, amount: amount});

        // Execute the final payment on the destination terminal and bubble back the beneficiary token count it
        // returned.
        beneficiaryTokenCount = destTerminal.pay{value: payValue}({
            projectId: projectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: minReturnedTokens,
            memo: memo,
            metadata: metadata
        });

        _afterTransferFor({destTerminal: destTerminal, token: token});

        // NOTE: No ERC-20 receipt enforcement here (unlike addToBalanceOf).
        // Pay hooks attached to the destination terminal may legitimately consume tokens during
        // pay(), making a balance-delta check produce false reverts. Fee-on-transfer (FOT) tokens
        // are therefore NOT supported for routed payments — the terminal will receive fewer tokens
        // than `amount` but the router cannot detect or prevent this. See RISKS.md for details.
    }

    /// @notice One-shot setter for the chain-specific Uniswap and wrapped-native addresses.
    /// @dev Callable only by `_DEPLOYER` and only once (when `WRAPPED_NATIVE_TOKEN` is still `address(0)`). After this
    /// call all four values are effectively immutable for the contract's lifetime. Mirrors the
    /// `JBOptimismSuckerDeployer.setChainSpecificConstants` pattern so the contract's CREATE2 inputs stay
    /// byte-identical across chains and its deployed address is unified.
    /// @param wrappedNativeToken The ERC-20 wrapper for the chain's native token (e.g. WETH on Ethereum,
    /// WCELO on Celo).
    /// @param factory The Uniswap V3 factory for pool discovery on this chain.
    /// @param poolManager The Uniswap V4 PoolManager on this chain (may be `address(0)` if V4 is not deployed there).
    /// @param univ4Hook The canonical Uniswap V4 router hook on this chain.
    function setChainSpecificConstants(
        IWETH9 wrappedNativeToken,
        IUniswapV3Factory factory,
        IPoolManager poolManager,
        address univ4Hook
    )
        external
    {
        if (msg.sender != _DEPLOYER) revert JBRouterTerminal_Unauthorized({caller: msg.sender});
        if (address(WRAPPED_NATIVE_TOKEN) != address(0)) revert JBRouterTerminal_AlreadyConfigured();
        WRAPPED_NATIVE_TOKEN = wrappedNativeToken;
        FACTORY = factory;
        POOL_MANAGER = poolManager;
        UNIV4_HOOK = univ4Hook;
    }

    /// @notice The Uniswap v3 pool callback where the token transfer is expected to happen.
    /// @dev Verifies the caller is a legitimate pool via the factory using the encoded tokenIn/tokenOut pair.
    /// @param amount0Delta The amount of token 0 used for the swap.
    /// @param amount1Delta The amount of token 1 used for the swap.
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
        uint256 amountToSendToPool = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);

        // Wrap native tokens if needed.
        if (tokenIn == JBConstants.NATIVE_TOKEN) _wrapNativeToken(amountToSendToPool);

        // Transfer the tokens to the pool.
        IERC20(normalizedTokenIn).safeTransfer({to: msg.sender, value: amountToSendToPool});
    }

    /// @notice The Uniswap V4 unlock callback. Called by the PoolManager during `unlock()`.
    /// @param data Encoded swap parameters.
    /// @return Encoded output amount.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert JBRouterTerminal_CallerNotPoolManager(msg.sender);

        // Decode the swap parameters.
        (
            PoolKey memory key,
            bool zeroForOne,
            int256 amountSpecified,
            uint160 sqrtPriceLimitX96,
            uint256 minAmountOut,
            bool canUseExistingNativeBalance
        ) = abi.decode(data, (PoolKey, bool, int256, uint160, uint256, bool));

        // Execute the swap.
        BalanceDelta delta = POOL_MANAGER.swap({
            key: key,
            params: SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            hookData: address(key.hooks) != address(0) ? abi.encode(minAmountOut) : bytes("")
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

        // Enforce the caller's V4 minimum against the realized delta before settling/taking pool balances.
        if (amountOut < minAmountOut) {
            revert JBRouterTerminal_SlippageExceeded({amountOut: amountOut, minAmountOut: minAmountOut});
        }

        // Settle input (pay what we owe to the PoolManager).
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        _settleV4({currency: inputCurrency, amount: amountIn, canUseExistingNativeBalance: canUseExistingNativeBalance});

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
    /// @param token The address of the token to get accounting context for.
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

    /// @notice Returns an empty array because this terminal accepts tokens dynamically rather than through a fixed
    /// accounting-context list.
    /// @param projectId The project whose accounting contexts were requested.
    /// @return contexts An empty array of `JBAccountingContext`.
    function accountingContextsOf(uint256 projectId)
        external
        pure
        override
        returns (JBAccountingContext[] memory contexts)
    {
        projectId;
        contexts = new JBAccountingContext[](0);
    }

    /// @notice This terminal holds no surplus because it routes funds onward instead of accounting for project
    /// balances itself.
    /// @param projectId The project whose surplus was requested.
    /// @param tokens The token set the caller wanted surplus measured against.
    /// @param decimals The fixed-point precision the caller wanted the surplus returned in.
    /// @param currency The currency the caller wanted the surplus returned in.
    /// @return surplus Always returns 0 because the router does not own project treasury balances.
    function currentSurplusOf(
        uint256 projectId,
        address[] calldata tokens,
        uint256 decimals,
        uint256 currency
    )
        external
        pure
        override
        returns (uint256 surplus)
    {
        projectId;
        tokens;
        decimals;
        currency;
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
        PoolInfo memory pool =
            _discoverPool({normalizedTokenIn: normalizedTokenIn, normalizedTokenOut: normalizedTokenOut});
        if (!pool.isV4 && address(pool.v3Pool) == address(0)) {
            revert JBRouterTerminal_NoPoolFound({tokenIn: normalizedTokenIn, tokenOut: normalizedTokenOut});
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
        returns (IUniswapV3Pool pool)
    {
        PoolInfo memory info =
            _discoverPool({normalizedTokenIn: normalizedTokenIn, normalizedTokenOut: normalizedTokenOut});
        if (!info.isV4 && address(info.v3Pool) == address(0)) {
            revert JBRouterTerminal_NoPoolFound({tokenIn: normalizedTokenIn, tokenOut: normalizedTokenOut});
        }
        if (!info.isV4) pool = info.v3Pool;
    }

    /// @notice Preview a payment by simulating the router's routing logic in view context.
    /// @dev Returns the router's best estimate using current routing and quote data, including swap quotes when needed.
    /// @param projectId The ID of the destination project to pay.
    /// @param token The token to provide to the router.
    /// @param amount The amount of the input token to provide.
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
        (,,, ruleset, beneficiaryTokenCount, reservedTokenCount, hookSpecifications) =
            _previewBestPayRoute({
                projectId: projectId, tokenIn: token, amount: amount, beneficiary: beneficiary, metadata: metadata
            });
    }

    /// @notice Preview the amount a direct token-to-token swap would return.
    /// @param tokenIn The input token.
    /// @param tokenOut The output token.
    /// @param amount The amount of `tokenIn` to swap.
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
    /// @param destTerminal The terminal whose pay preview to query.
    /// @param projectId The destination project that would receive the payment.
    /// @param token The token the destination terminal would receive.
    /// @param amount The amount of `token` the destination terminal would receive.
    /// @param beneficiary The address to measure beneficiary token count for.
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
        return _bestPoolLiquidity({tokenA: tokenA, tokenB: tokenB});
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherence to.
    /// @return A flag indicating whether the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IJBPermitTerminal).interfaceId
            || interfaceId == type(IJBRouterTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ------------------------- internal helpers ------------------------ //
    //*********************************************************************//

    /// @notice Atomically cash out source-project tokens and pay the reclaim into the beneficiary project.
    /// @dev Delegates `(sourceTerminal, tokenToReclaim)` selection to `_PAY_ROUTE_RESOLVER.previewBestCashOutPath`
    /// (kept off the router runtime to stay under the EIP-170 size limit), then executes via the source project's
    /// `payAfterCashOutTokensOf`. The source-side cash-out fee is skipped on-chain and bound on the destination
    /// project's fee-free surplus via core's balance-delta accounting. Reverts with `JBRouterTerminal_NoCashOutPath`
    /// when no candidate yields a usable route. The destination project's current ruleset can opt out via
    /// `pauseCrossProjectFeeFreeInflows`, in which case the underlying core call reverts.
    /// @param sourceProjectId The source project whose tokens were paid in.
    /// @param cashOutCount The number of source-project tokens to burn.
    /// @param beneficiaryProjectId The destination project that should receive the routed payment.
    /// @param beneficiary The address whose minted destination-project tokens to maximize.
    /// @param minTokensOut The minimum destination-project tokens that must be minted, otherwise revert (enforced by
    /// the underlying core call).
    /// @param payMetadata Metadata forwarded into the destination project's pay flow.
    /// @return beneficiaryTokenCount The number of destination-project tokens minted to `beneficiary`.
    function _payAfterCashOut(
        uint256 sourceProjectId,
        uint256 cashOutCount,
        uint256 beneficiaryProjectId,
        address beneficiary,
        uint256 minTokensOut,
        bytes calldata payMetadata
    )
        internal
        returns (uint256 beneficiaryTokenCount)
    {
        // Pick the candidate that produces the highest previewed beneficiary mint on the destination project.
        (IJBCashOutTerminalCrossProject sourceTerminal, address tokenToReclaim) =
            _PAY_ROUTE_RESOLVER.previewBestCashOutPath({
                router: IJBPayRoutePreviewer(address(this)),
                wrappedNativeToken: address(WRAPPED_NATIVE_TOKEN),
                sourceProjectId: sourceProjectId,
                cashOutCount: cashOutCount,
                beneficiaryProjectId: beneficiaryProjectId,
                beneficiary: beneficiary,
                payMetadata: payMetadata
            });

        // Surface a clean revert when no candidate produced a usable route so the failure mode matches the previous
        // cashout-loop's `NoCashOutPath` shape.
        if (address(sourceTerminal) == address(0)) {
            revert JBRouterTerminal_NoCashOutPath({
                sourceProjectId: sourceProjectId, destProjectId: beneficiaryProjectId
            });
        }

        // Execute the atomic cashout-then-pay. Slippage is enforced on the destination side by core's
        // `_checkMin(beneficiaryTokenCount, minTokensOut)`.
        (, beneficiaryTokenCount) = sourceTerminal.payAfterCashOutTokensOf({
            holder: address(this),
            projectId: sourceProjectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: tokenToReclaim,
            beneficiaryProjectId: beneficiaryProjectId,
            beneficiary: beneficiary,
            minTokensOut: minTokensOut,
            cashOutMetadata: "",
            payMetadata: payMetadata
        });
    }

    /// @notice Atomically cash out source-project tokens and add the reclaim to the beneficiary project's balance.
    /// @dev Reuses the same `(sourceTerminal, tokenToReclaim)` selection as the `pay()` path
    /// (`previewBestCashOutPath`) — scored by predicted beneficiary mint as a proxy for "best yielding route", even
    /// though no destination-project tokens are actually minted here. The source-side fee is skipped on-chain and
    /// bound on the destination project's fee-free surplus via core's balance-delta accounting. Held-fee return is
    /// hardcoded to `false` by the underlying core entrypoint; the caller's `shouldReturnHeldFees` flag is rejected
    /// upstream in `addToBalanceOf`.
    /// @param sourceProjectId The source project whose tokens were paid in.
    /// @param cashOutCount The number of source-project tokens to burn.
    /// @param beneficiaryProjectId The destination project whose balance should grow.
    /// @param addToBalanceMetadata Metadata forwarded into the destination project's `addToBalanceOf` event.
    function _addToBalanceAfterCashOut(
        uint256 sourceProjectId,
        uint256 cashOutCount,
        uint256 beneficiaryProjectId,
        bytes calldata addToBalanceMetadata
    )
        internal
    {
        // Pick the candidate that produces the highest previewed beneficiary mint on the destination project. No
        // tokens are actually minted in this path, but the same scorer surfaces the route most likely to land the
        // largest reclaim into B's surplus on the source terminal (the balance-delta core measures for the fee
        // credit).
        (IJBCashOutTerminalCrossProject sourceTerminal, address tokenToReclaim) =
            _PAY_ROUTE_RESOLVER.previewBestCashOutPath({
                router: IJBPayRoutePreviewer(address(this)),
                wrappedNativeToken: address(WRAPPED_NATIVE_TOKEN),
                sourceProjectId: sourceProjectId,
                cashOutCount: cashOutCount,
                beneficiaryProjectId: beneficiaryProjectId,
                beneficiary: address(this),
                payMetadata: addToBalanceMetadata
            });

        if (address(sourceTerminal) == address(0)) {
            revert JBRouterTerminal_NoCashOutPath({
                sourceProjectId: sourceProjectId, destProjectId: beneficiaryProjectId
            });
        }

        sourceTerminal.addToBalanceAfterCashOutTokensOf({
            holder: address(this),
            projectId: sourceProjectId,
            cashOutCount: cashOutCount,
            tokenToReclaim: tokenToReclaim,
            beneficiaryProjectId: beneficiaryProjectId,
            cashOutMetadata: "",
            addToBalanceMetadata: addToBalanceMetadata
        });
    }

    /// @notice Resolve the original payer when called through an intermediary.
    /// @dev Registry-style forwarders record the original payer in transient storage via `IJBPayerTracker`. When
    /// present, that address is used for refunds instead of the intermediary.
    /// @param fallback_ The default address to use when no original payer is available.
    /// @return The original payer, or `fallback_` if none is available.
    function _resolveOriginalPayer(address fallback_) internal view returns (address) {
        // Only attempt the call if msg.sender is a contract (EOAs have no code and would revert).
        if (msg.sender.code.length > 0) {
            try IJBPayerTracker(msg.sender).originalPayer() returns (address payer) {
                if (payer != address(0)) return payer;
            } catch {}
        }
        return fallback_;
    }

    /// @notice Route a payment using the destination token that yields the highest previewed beneficiary output.
    /// @param destProjectId The project to route the payment to.
    /// @param tokenIn The token currently held by the router for this payment.
    /// @param amount The amount of `tokenIn` available to route.
    /// @param beneficiary The address whose beneficiary token count to maximize.
    /// @param metadata Metadata forwarded into route discovery and the final destination payment.
    /// @param refundTo The address to receive any leftover input tokens from partial fills.
    /// @return destTerminal The terminal selected for the winning route.
    /// @return tokenOut The token `destTerminal` should receive for the winning route.
    /// @return amountOut The amount of `tokenOut` that will be delivered to `destTerminal`.
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
        // Read the destination project's terminal list in best-effort mode so a bad directory read degrades into
        // "no terminals" instead of bricking pay-route selection.
        IJBTerminal[] memory terminals = _terminalsOf({projectId: destProjectId, shouldIgnoreFailure: true});

        // Fall back to ordinary routing when the destination project exposes no direct terminals to score.
        if (terminals.length == 0) {
            return _route({
                destProjectId: destProjectId, tokenIn: tokenIn, amount: amount, metadata: metadata, refundTo: refundTo
            });
        }

        // Preview the best candidate route so execution can target the destination token with the highest payout.
        (destTerminal, tokenOut,,,,,) = _previewBestPayRoute({
            projectId: destProjectId, tokenIn: tokenIn, amount: amount, beneficiary: beneficiary, metadata: metadata
        });

        // Execute the winning route by converting into the preview-selected destination token.
        // Pass the preview-resolved destTerminal so execution skips the redundant directory lookup.
        return _routeToDestination({
            destProjectId: destProjectId,
            tokenIn: tokenIn,
            amount: amount,
            tokenOut: tokenOut,
            previewedDestTerminal: destTerminal,
            metadata: metadata,
            refundTo: refundTo
        });
    }

    /// @notice Preview the best pay route using the resolver helper.
    /// @param projectId The destination project to pay.
    /// @param tokenIn The token currently available to route.
    /// @param amount The amount of `tokenIn` to preview.
    /// @param beneficiary The address whose minted token count to optimize.
    /// @param metadata Metadata forwarded into route and pay previews.
    /// @return destTerminal The terminal chosen for the best previewed route.
    /// @return tokenOut The token `destTerminal` would receive.
    /// @return amountOut The amount of `tokenOut` that would be paid.
    /// @return ruleset The ruleset returned by the chosen terminal preview.
    /// @return beneficiaryTokenCount The effective beneficiary token count for the chosen route.
    /// @return reservedTokenCount The effective reserved token count for the chosen route.
    /// @return hookSpecifications The hook specifications returned by the chosen terminal preview.
    function _previewBestPayRoute(
        uint256 projectId,
        address tokenIn,
        uint256 amount,
        address beneficiary,
        bytes calldata metadata
    )
        internal
        view
        returns (
            IJBTerminal destTerminal,
            address tokenOut,
            uint256 amountOut,
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        )
    {
        // Delegate the heavy preview-selection logic to the helper contract so the router stays within runtime size.
        // Pass `wrappedNativeToken` once (single SLOAD) so the resolver does not have to call back into the router for
        // it on every normalization step.
        return _PAY_ROUTE_RESOLVER.previewBestPayRoute({
            router: IJBPayRoutePreviewer(address(this)),
            wrappedNativeToken: address(WRAPPED_NATIVE_TOKEN),
            projectId: projectId,
            tokenIn: tokenIn,
            amount: amount,
            beneficiary: beneficiary,
            metadata: metadata
        });
    }

    /// @notice Preview the output amount for a direct token-to-token swap route.
    /// @param tokenIn The token currently available to swap.
    /// @param tokenOut The token the swap should deliver.
    /// @param amount The amount of `tokenIn` to preview.
    /// @param metadata Metadata that can provide an explicit quote override for the swap.
    /// @return amountOut The predicted amount of `tokenOut` the router would receive.
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
        // Normalize native-token sentinels into wrapped native tokens so pool discovery and quoting use canonical pair
        // addresses. _pickPoolAndQuote already discovers the best pool and reverts with NoPoolFound when none exists,
        // so no separate liquidity guard is needed here.
        (amountOut,) = _pickPoolAndQuote({
            metadata: metadata,
            normalizedTokenIn: _normalize(tokenIn),
            amount: amount,
            normalizedTokenOut: _normalize(tokenOut)
        });
    }

    /// @notice Snapshot a destination terminal's pre-call token balance and check forwarding status.
    /// @dev Combines both the balance snapshot and forwarding probe into a single helper to avoid duplicate
    /// `_isForwardingTerminal` calls in the pay/addToBalance flows.
    /// @param terminal The destination terminal that will receive the final forwarded funds.
    /// @param token The token the terminal is expected to receive.
    /// @param projectId The project to check forwarding status for.
    /// @return receiptBaseline The terminal's balance in `token` before the final forwarded call.
    /// @return isForwarding Whether the terminal forwards calls onward.
    function _terminalReceiptBaselineOf(
        IJBTerminal terminal,
        address token,
        uint256 projectId
    )
        internal
        view
        returns (uint256 receiptBaseline, bool isForwarding)
    {
        // Skip native-token receipt enforcement because value transfers can be consumed during terminal execution.
        if (token == JBConstants.NATIVE_TOKEN) return (0, false);

        // Check forwarding status once and return it alongside the baseline.
        isForwarding = _isForwardingTerminal({terminal: terminal, projectId: projectId});

        // Skip receipt enforcement for forwarding terminals because they enforce the terminal-facing hop themselves.
        if (isForwarding) return (0, true);

        // Snapshot the terminal's ERC20 balance so final-hop receipt can be verified after the terminal pulls.
        return (IERC20(token).balanceOf(address(terminal)), false);
    }

    /// @notice Reject lossy ERC20 terminal pulls on the final forwarded hop.
    /// @param terminal The destination terminal that received the forwarded call.
    /// @param token The token the terminal was expected to pull.
    /// @param expectedAmount The nominal amount forwarded into the terminal call.
    /// @param receiptBaseline The terminal's pre-call balance in `token`.
    /// @param isForwarding Whether the terminal forwards calls onward (pre-computed by caller).
    function _enforceStandardTerminalReceipt(
        IJBTerminal terminal,
        address token,
        uint256 expectedAmount,
        uint256 receiptBaseline,
        bool isForwarding
    )
        internal
        view
    {
        // Native-token final hops are excluded because their value transfer is not observable via ERC20 balances.
        if (token == JBConstants.NATIVE_TOKEN) return;

        // Forwarding terminals are responsible for enforcing the final terminal-facing ERC20 receipt themselves.
        if (isForwarding) return;

        // Revert when the terminal received less ERC20 than promised, which indicates a lossy token path.
        uint256 actualAmount = IERC20(token).balanceOf(address(terminal)) - receiptBaseline;
        if (actualAmount != expectedAmount) {
            revert JBRouterTerminal_NonStandardTerminalToken({
                terminal: address(terminal), token: token, expectedAmount: expectedAmount, actualAmount: actualAmount
            });
        }
    }

    /// @notice Whether a terminal forwards terminal-facing calls onward instead of acting as the final receiver.
    /// @param terminal The terminal to check for forwarding behavior.
    /// @param projectId The project to resolve forwarding target for.
    /// @return isForwarding A flag indicating whether receipt enforcement should be delegated to `terminal`.
    function _isForwardingTerminal(IJBTerminal terminal, uint256 projectId) internal view returns (bool isForwarding) {
        // Probe via staticcall so non-forwarding terminals degrade cleanly.
        (bool success, bytes memory data) =
            address(terminal).staticcall(abi.encodeCall(IJBForwardingTerminal.terminalOf, (projectId)));

        // Treat terminals that do not implement the capability or return zero as final receivers.
        if (!success || data.length < 32) return false;

        return address(abi.decode(data, (IJBTerminal))) != address(0);
    }

    /// @notice Return a project's primary terminal only if the router can safely forward into it.
    /// @dev Inlined from the resolver to avoid a cross-contract roundtrip (saves 3 external calls per lookup).
    /// @param projectId The project to check the primary terminal for.
    /// @param token The token that terminal should accept.
    /// @return terminal The usable primary terminal, or address(0) if none is usable.
    function _usablePrimaryTerminalOf(uint256 projectId, address token) internal view returns (IJBTerminal terminal) {
        terminal = DIRECTORY.primaryTerminalOf({projectId: projectId, token: token});

        // Drop terminals that would route straight back into the router (circular).
        if (
            address(terminal) == address(0)
                || JBForwardingCheck.isCircularTerminal({
                    target: address(this), projectId: projectId, terminal: terminal
                })
        ) {
            return IJBTerminal(address(0));
        }

        // Check if the terminal is a forwarding layer that routes back into this router.
        (bool ok, bytes memory data) =
            address(terminal).staticcall(abi.encodeCall(IJBForwardingTerminal.terminalOf, (projectId)));
        if (ok && data.length >= 32 && address(abi.decode(data, (IJBTerminal))) == address(this)) {
            return IJBTerminal(address(0));
        }
    }

    /// @notice Resolve which source project a routed token should cash out from.
    /// @param token The current route token that may be a JB project token.
    /// @return sourceProjectId The project to cash out from, or 0 if the token is not a JB project token.
    function _sourceProjectIdOf(address token) internal view returns (uint256 sourceProjectId) {
        if (token != JBConstants.NATIVE_TOKEN) sourceProjectId = _projectIdOf(token);
    }

    /// @notice Accept a token paid in by the caller.
    /// @param token The address of the token to accept.
    /// @param amount The amount of tokens to accept.
    /// @param metadata The metadata in which `permit2` context is provided.
    /// @return The amount of tokens accepted.
    function _acceptFundsFor(address token, uint256 amount, bytes calldata metadata) internal returns (uint256) {
        // Cache _msgSender() once to avoid repeated ERC-2771 context resolution.
        address sender = _msgSender();

        // If native tokens are being paid in, return the `msg.value`.
        if (token == JBConstants.NATIVE_TOKEN) return msg.value;

        // Otherwise, the `msg.value` should be 0.
        if (msg.value != 0) revert JBRouterTerminal_NoMsgValueAllowed(msg.value);

        // Unpack the `JBSingleAllowance` to use given by the frontend.
        (bool exists, bytes memory parsedMetadata) = _getDataFor({metadata: metadata, id: _PERMIT2_ID});

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

            try PERMIT2.permit({owner: sender, permitSingle: permitSingle, signature: allowance.signature}) {}
            catch (bytes memory reason) {
                emit Permit2AllowanceFailed({token: token, owner: sender, reason: reason});
            }
        }

        // Fee-on-transfer tokens are not supported by design. The router uses balance-delta
        // checks for its own accounting but relies on underlying terminal behavior for FoT tokens. Projects
        // should avoid configuring FoT tokens.
        // Measure balance before transfer to determine actual tokens received (handles fee-on-transfer tokens).
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // Transfer the tokens from the sender to this terminal.
        _transferFrom({from: sender, to: payable(address(this)), token: token, amount: amount});

        // Return the actual amount received (balance delta), not the user-supplied amount.
        return IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    /// @notice Run the common post-transfer cleanup after forwarding funds into a destination terminal.
    /// @param destTerminal The terminal that just received the forwarded call.
    /// @param token The token that was forwarded into the destination terminal.
    function _afterTransferFor(IJBTerminal destTerminal, address token) internal {
        // Revoke any leftover allowance the destination terminal did not pull so routed calls do not leave approvals
        // hanging around after the terminal finishes its pull.
        if (token != JBConstants.NATIVE_TOKEN) IERC20(token).forceApprove({spender: address(destTerminal), value: 0});
    }

    /// @notice Logic to trigger before transferring tokens from this terminal.
    /// @param to The address to transfer tokens to.
    /// @param token The token to transfer.
    /// @param amount The amount of tokens to transfer.
    /// @return payValue The amount that will be paid as a `msg.value`.
    function _beforeTransferFor(address to, address token, uint256 amount) internal returns (uint256) {
        // If the token is the native token, return the amount as msg.value.
        if (token == JBConstants.NATIVE_TOKEN) return amount;

        // Reset-then-set: avoid reverts from tokens that disallow non-zero to non-zero approval changes.
        IERC20(token).forceApprove({spender: to, value: amount});

        return 0;
    }

    /// @notice Snapshot the normalized input-token balance used to measure refundable leftovers for one route.
    /// @param tokenIn The token to route.
    /// @param amount The fresh route input amount currently held by the router.
    /// @return baseline The normalized input-token balance attributable only to pre-existing funds.
    function _refundBalanceBaselineOf(address tokenIn, uint256 amount) internal view returns (uint256 baseline) {
        // Start from the router's normalized input-token balance before the route consumes any of it.
        baseline = IERC20(_normalize(tokenIn)).balanceOf(address(this));

        // Exclude the fresh ERC-20 route input so only pre-existing balances count toward refundable leftovers.
        if (tokenIn != JBConstants.NATIVE_TOKEN) baseline -= amount;
    }

    /// @notice Convert tokenIn to tokenOut. No-op if same, wrap/unwrap for native/wrapped-native, or swap via Uniswap.
    /// @param tokenIn The token to convert from.
    /// @param tokenOut The token to convert into.
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
            if (tokenIn == JBConstants.NATIVE_TOKEN) _wrapNativeToken(amount);
            else _unwrapNativeToken(amount);
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
    /// @param normalizedTokenIn The normalized token to swap in.
    /// @param normalizedTokenOut The normalized token to swap out.
    /// @param amount The amount of `normalizedTokenIn` to swap.
    /// @param metadata Bytes in `JBMetadataResolver`'s format, used for quote overrides.
    /// @param callbackData ABI-encoded callback data for the V3 swap path.
    /// @return amountOut The amount of `normalizedTokenOut` produced by the swap.
    function _executeSwap(
        address normalizedTokenIn,
        address normalizedTokenOut,
        bool canUseExistingNativeBalance,
        uint256 amount,
        bytes calldata metadata,
        bytes memory callbackData
    )
        internal
        returns (uint256 amountOut)
    {
        // Discover the best pool for the pair and compute the minimum acceptable output for the swap.
        (uint256 minAmountOut, PoolInfo memory pool) = _pickPoolAndQuote({
            metadata: metadata,
            normalizedTokenIn: normalizedTokenIn,
            amount: amount,
            normalizedTokenOut: normalizedTokenOut
        });

        // Dispatch to the V4 execution path when the chosen pool lives in the PoolManager.
        if (pool.isV4) {
            return _executeV4Swap({
                key: pool.v4Key,
                normalizedTokenIn: normalizedTokenIn,
                canUseExistingNativeBalance: canUseExistingNativeBalance,
                amount: amount,
                minAmountOut: minAmountOut
            });
        } else {
            // Otherwise execute the swap against the discovered V3 pool.
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
    /// @param pool The V3 pool to swap through.
    /// @param normalizedTokenIn The normalized token to sell.
    /// @param normalizedTokenOut The normalized token to buy.
    /// @param amount The exact input amount to swap.
    /// @param minAmountOut The minimum acceptable output after slippage protection.
    /// @param callbackData ABI-encoded data that the V3 callback will use to settle the input side.
    /// @return amountOut The amount of `normalizedTokenOut` the pool returned.
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
        // Determine swap direction using Uniswap's canonical token ordering so both the pool call and
        // sqrt-price limit are computed against the same side of the pair.
        bool zeroForOne = normalizedTokenIn < normalizedTokenOut;

        // Ask the pool to execute an exact-input swap. The callback settles the input token after the pool
        // computes how much of the output side it owes this router.
        // Use extreme sqrtPriceLimitX96 values to allow the swap to execute fully. Slippage is enforced
        // by the post-swap minAmountOut check below, which is more correct than deriving a price limit
        // from average execution rate.
        (int256 amount0, int256 amount1) = pool.swap({
            recipient: address(this),
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            data: callbackData
        });

        // Uniswap returns signed deltas for both sides of the swap. The output side is negative because the
        // pool sent tokens out to the router, so negate the selected leg to recover the positive amount received.
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));

        // Enforce slippage protection via realized output vs minimum acceptable output.
        // This is strictly more correct than sqrtPriceLimitX96 (which conflates marginal and average price).
        if (amountOut < minAmountOut) {
            revert JBRouterTerminal_SlippageExceeded({amountOut: amountOut, minAmountOut: minAmountOut});
        }
    }

    /// @notice Execute a swap through a V4 pool via PoolManager.unlock().
    /// @param key The V4 pool key describing the pool to swap through.
    /// @param normalizedTokenIn The normalized token to swap in.
    /// @param canUseExistingNativeBalance Whether raw ETH already held by the router can fund the input side.
    /// @param amount The amount of `normalizedTokenIn` to swap.
    /// @param minAmountOut The minimum acceptable amount out for the swap.
    /// @return amountOut The amount produced by the V4 swap.
    function _executeV4Swap(
        PoolKey memory key,
        address normalizedTokenIn,
        bool canUseExistingNativeBalance,
        uint256 amount,
        uint256 minAmountOut
    )
        internal
        returns (uint256 amountOut)
    {
        // Convert wrapped-native-token addresses to V4's native representation (address(0)) for currency comparison.
        address v4In = normalizedTokenIn == address(WRAPPED_NATIVE_TOKEN) ? address(0) : normalizedTokenIn;

        // Determine the V4 swap direction by comparing the input token to currency0 in the pool key.
        bool zeroForOne = Currency.unwrap(key.currency0) == v4In;

        // Use extreme sqrtPriceLimitX96 to allow full swap execution. Slippage is enforced by
        // the post-swap minAmountOut check in the unlock callback.
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;

        // V4 sign convention: negative = exact input, positive = exact output.
        // Ask the PoolManager to unlock and call back into this router to execute the swap atomically.
        // The router only reaches this path with uint256 amounts that fit the signed exact-input convention.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 exactInputAmount = -int256(amount);
        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(key, zeroForOne, exactInputAmount, sqrtPriceLimitX96, minAmountOut, canUseExistingNativeBalance)
        );

        // Decode and return the amount-out value surfaced by the unlock callback.
        amountOut = abi.decode(result, (uint256));
    }

    /// @notice Execute a Uniswap swap from tokenIn to tokenOut (V3 or V4).
    /// @param projectId The project ID (included in callback data).
    /// @param tokenIn The token to swap from.
    /// @param tokenOut The token to swap into.
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
            canUseExistingNativeBalance: tokenIn == JBConstants.NATIVE_TOKEN,
            amount: amount,
            metadata: metadata,
            callbackData: abi.encode(projectId, tokenIn, tokenOut)
        });

        // For native token inputs, wrap any raw ETH remaining from partial fills so the leftover check catches it.
        // In partial fills, the swap callback only wraps the amount the pool consumed, leaving excess as raw ETH.
        if (tokenIn == JBConstants.NATIVE_TOKEN && address(this).balance > nativeBalanceBaseline) {
            _wrapNativeToken(address(this).balance - nativeBalanceBaseline);
        }

        // Unwrap if output is native token.
        if (tokenOut == JBConstants.NATIVE_TOKEN) _unwrapNativeToken(amountOut);

        // Refund only the leftover portion attributable to this swap. Pre-existing balances are not part of the
        // caller's route and should not be swept into the current refund.
        uint256 balanceAfter = IERC20(normalizedTokenIn).balanceOf(address(this));
        if (balanceAfter > refundBalanceBaseline) {
            uint256 refundAmount = balanceAfter - refundBalanceBaseline;
            if (tokenIn == JBConstants.NATIVE_TOKEN) {
                _unwrapNativeToken(refundAmount);
                // Try native refund; fall back to wrapped native token if the recipient cannot accept native tokens.
                (bool success,) = refundTo.call{value: refundAmount}("");
                if (!success) {
                    _wrapNativeToken(refundAmount);
                    IERC20(address(WRAPPED_NATIVE_TOKEN)).safeTransfer(refundTo, refundAmount);
                }
            } else {
                _transferFrom({from: address(this), to: refundTo, token: tokenIn, amount: refundAmount});
            }
        }
    }

    /// @notice Core routing logic shared by pay() and addToBalanceOf() for non-project-token inputs.
    /// @dev Project-token inputs are intercepted upstream by `pay()` (atomic `payAfterCashOutTokensOf` path) and
    /// rejected by `addToBalanceOf()`. This helper only sees base tokens or wrapped-native equivalents.
    /// @param destProjectId The ID of the destination project.
    /// @param tokenIn The address of the token to route.
    /// @param amount The amount of tokens to route.
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
        // Resolve what token the destination project accepts and which terminal to use.
        (tokenOut, destTerminal) = _PAY_ROUTE_RESOLVER.resolveTokenOut({
            router: IJBPayRoutePreviewer(address(this)),
            wrappedNativeToken: address(WRAPPED_NATIVE_TOKEN),
            projectId: destProjectId,
            tokenIn: tokenIn,
            metadata: metadata
        });

        // Convert the route input into the resolved destination token and refund any leftover input.
        amountOut = _finalizeResolvedRoute({
            destProjectId: destProjectId,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amount: amount,
            metadata: metadata,
            refundTo: refundTo,
            refundBalanceBaseline: _refundBalanceBaselineOf({tokenIn: tokenIn, amount: amount})
        });
    }

    /// @notice Route funds to a specific destination token.
    /// @dev Project-token inputs are intercepted upstream by `pay()`, so this helper only sees base tokens or
    /// wrapped-native equivalents.
    /// @param destProjectId The project to route the payment to.
    /// @param tokenIn The token currently held by the router for this route.
    /// @param amount The amount of `tokenIn` available to route.
    /// @param tokenOut The destination token for the project to receive.
    /// @param metadata Metadata forwarded into swap execution.
    /// @param refundTo The address to receive any leftover input tokens from partial fills.
    /// @return destTerminal The terminal that accepts the resolved destination token.
    /// @return resolvedTokenOut The concrete destination token the router routed into.
    /// @return amountOut The amount of `resolvedTokenOut` that will be delivered to `destTerminal`.
    function _routeToDestination(
        uint256 destProjectId,
        address tokenIn,
        uint256 amount,
        address tokenOut,
        IJBTerminal previewedDestTerminal,
        bytes calldata metadata,
        address payable refundTo
    )
        internal
        returns (IJBTerminal destTerminal, address resolvedTokenOut, uint256 amountOut)
    {
        // Start from the caller-requested destination token.
        resolvedTokenOut = tokenOut;

        // Reuse the terminal already resolved during preview to avoid a redundant directory lookup.
        destTerminal = previewedDestTerminal;

        // Convert the route input into the resolved destination token and refund any leftover input.
        amountOut = _finalizeResolvedRoute({
            destProjectId: destProjectId,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amount: amount,
            metadata: metadata,
            refundTo: refundTo,
            refundBalanceBaseline: _refundBalanceBaselineOf({tokenIn: tokenIn, amount: amount})
        });
    }

    /// @notice Convert a route whose destination token is already resolved into that destination token.
    /// @param destProjectId The project receiving the routed payment.
    /// @param tokenIn The post-cashout route input token.
    /// @param tokenOut The resolved destination token to convert into.
    /// @param amount The amount of `tokenIn` available to convert.
    /// @param metadata Metadata forwarded into swap execution.
    /// @param refundTo The address that should receive any leftover input tokens from partial fills.
    /// @param refundBalanceBaseline The normalized input-token balance baseline for partial-fill refunds.
    /// @return amountOut The amount of `tokenOut` produced for the destination terminal.
    function _finalizeResolvedRoute(
        uint256 destProjectId,
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

    /// @notice Settle the input side of a V4 swap by transferring the owed input asset into the PoolManager.
    /// @param currency The V4 currency to settle with the PoolManager.
    /// @param amount The amount of `currency` to settle.
    /// @param canUseExistingNativeBalance Whether already-held raw native tokens can be used before unwrapping.
    function _settleV4(Currency currency, uint256 amount, bool canUseExistingNativeBalance) internal {
        if (Currency.unwrap(currency) == address(0)) {
            // Native-funded routes may spend the ETH they already hold.
            // Wrapped-native-funded routes must not consume unrelated raw native tokens already sitting on the router.
            if (canUseExistingNativeBalance) {
                // Only unwrap the shortfall so routes funded by direct native tokens do not churn through wrapping
                // unnecessarily.
                uint256 deficit = amount > address(this).balance ? amount - address(this).balance : 0;
                if (deficit > 0) _unwrapNativeToken(deficit);
            } else {
                // Wrapped-native-funded routes should unwrap the full amount because they are not allowed to consume
                // ambient native tokens.
                _unwrapNativeToken(amount);
            }
            // Native settlement uses `msg.value` because PoolManager expects ETH to accompany the settle call.
            POOL_MANAGER.settle{value: amount}();
        } else {
            // ERC20 settlement requires PoolManager to observe the token first (`sync`), then receive the transfer,
            // then finalize the accounting with `settle`.
            POOL_MANAGER.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer({to: address(POOL_MANAGER), value: amount});
            POOL_MANAGER.settle();
        }
    }

    /// @notice Take the output side of a V4 swap by pulling the owed asset from the PoolManager.
    /// @param currency The V4 currency to take from the PoolManager.
    /// @param amount The amount of `currency` to take.
    function _takeV4(Currency currency, uint256 amount) internal {
        // Pull the owed output asset into the router before any later wrapping/unwrapping or forwarding logic runs.
        POOL_MANAGER.take({currency: currency, to: address(this), amount: amount});

        // If native token output, wrap it (downstream _handleSwap unwraps if needed).
        if (Currency.unwrap(currency) == address(0)) _wrapNativeToken(amount);
    }

    /// @notice Transfer tokens from one address to another using direct approval, `safeTransfer`, or Permit2 as a
    /// fallback.
    /// @param from The address to transfer tokens from.
    /// @param to The address to transfer tokens to.
    /// @param token The address of the token to transfer.
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

    /// @notice Wrap native tokens into their ERC-20 wrapped representation.
    /// @param amount The amount of native tokens to wrap.
    function _wrapNativeToken(uint256 amount) internal {
        WRAPPED_NATIVE_TOKEN.deposit{value: amount}();
    }

    /// @notice Unwrap wrapped native tokens into native tokens.
    /// @param amount The amount of wrapped native tokens to unwrap.
    function _unwrapNativeToken(uint256 amount) internal {
        WRAPPED_NATIVE_TOKEN.withdraw(amount);
    }

    //*********************************************************************//
    // ------------------------- internal views -------------------------- //
    //*********************************************************************//

    /// @notice Look up a pool address from the V3 factory.
    /// @param tokenA One token in the pair.
    /// @param tokenB The other token in the pair.
    /// @param fee The fee tier to query.
    /// @return The pool address, or address(0) if none exists.
    function _getPool(address tokenA, address tokenB, uint24 fee) internal view returns (address) {
        return FACTORY.getPool({tokenA: tokenA, tokenB: tokenB, fee: fee});
    }

    /// @notice Look up the in-range liquidity of a V4 pool.
    /// @param id The pool ID to query.
    /// @return The pool's current in-range liquidity.
    function _getLiquidity(PoolId id) internal view returns (uint128) {
        return POOL_MANAGER.getLiquidity(id);
    }

    /// @notice Read slot0 from a V4 pool.
    /// @param id The pool ID to query.
    /// @return sqrtPriceX96 The current sqrt price.
    /// @return tick The current tick.
    /// @return protocolFee The protocol fee.
    /// @return lpFee The LP fee.
    function _getSlot0(PoolId id)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return POOL_MANAGER.getSlot0(id);
    }

    /// @notice Look up the primary terminal for a project and token.
    /// @param projectId The ID of the project to look up.
    /// @param token The token to look up.
    /// @return The primary terminal, or IJBTerminal(address(0)) if none.
    function _primaryTerminalOf(uint256 projectId, address token) internal view returns (IJBTerminal) {
        return DIRECTORY.primaryTerminalOf({projectId: projectId, token: token});
    }

    /// @notice Look up the project ID for a token.
    /// @param token The token address to query.
    /// @return The project ID, or 0 if the token is not a JB project token.
    function _projectIdOf(address token) internal view returns (uint256) {
        return TOKENS.projectIdOf(IJBToken(token));
    }

    /// @notice Read a project's terminal list from the directory.
    /// @param projectId The project to read terminals for.
    /// @param shouldIgnoreFailure Whether a reverting directory call should degrade into an empty list.
    /// @return terminals The project's terminal list, or an empty list if `shouldIgnoreFailure` is true and the call
    /// failed.
    function _terminalsOf(
        uint256 projectId,
        bool shouldIgnoreFailure
    )
        internal
        view
        returns (IJBTerminal[] memory terminals)
    {
        // Use the direct directory view when failures should surface to the caller.
        if (!shouldIgnoreFailure) return DIRECTORY.terminalsOf(projectId);

        // Fall back to a low-level staticcall so no-code or reverting directories degrade into an empty list.
        (bool success, bytes memory data) =
            address(DIRECTORY).staticcall(abi.encodeCall(IJBDirectory.terminalsOf, (projectId)));

        // Return the default empty array when the best-effort lookup failed or returned no payload.
        if (!success || data.length == 0) return terminals;

        // Decode and return the terminal list when the best-effort lookup succeeded.
        return abi.decode(data, (IJBTerminal[]));
    }

    /// @notice Find the highest liquidity across all V3 fee tiers and V4 pools for a token pair.
    /// @param tokenA One token in the pair.
    /// @param tokenB The other token in the pair.
    /// @return bestLiquidity The highest liquidity found, or 0 if no pool exists.
    function _bestPoolLiquidity(address tokenA, address tokenB) internal view returns (uint128 bestLiquidity) {
        PoolInfo memory pool = _discoverPool({normalizedTokenIn: tokenA, normalizedTokenOut: tokenB});
        if (pool.isV4) return _getLiquidity(pool.v4Key.toId());
        if (address(pool.v3Pool) != address(0)) return pool.v3Pool.liquidity();
    }

    /// @notice Return the ERC-2771 context suffix length used by the inherited forwarder-aware context.
    /// @return suffixLength The number of bytes appended to calldata for the forwarded sender.
    /// @dev ERC-2771 specifies the context as a single address, which is always 20 bytes.
    function _contextSuffixLength() internal view override returns (uint256) {
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
        for (uint256 i; i < 4;) {
            address poolAddr = _getPool({tokenA: normalizedTokenIn, tokenB: normalizedTokenOut, fee: _feeTier(i)});

            if (poolAddr == address(0)) {
                unchecked {
                    ++i;
                }
                continue;
            }

            uint128 poolLiquidity = IUniswapV3Pool(poolAddr).liquidity();

            if (poolLiquidity > bestLiquidity) {
                bestLiquidity = poolLiquidity;
                bestPool.v3Pool = IUniswapV3Pool(poolAddr);
            }

            unchecked {
                ++i;
            }
        }

        // Search V4.
        bestPool = _discoverV4Pool({
            normalizedTokenIn: normalizedTokenIn,
            normalizedTokenOut: normalizedTokenOut,
            currentBestLiquidity: bestLiquidity,
            bestPool: bestPool
        });
    }

    /// @notice Search supported V4 pools and update the best pool candidate if a deeper V4 pool exists.
    /// @param normalizedTokenIn The normalized input token to search pools for.
    /// @param normalizedTokenOut The normalized output token to search pools for.
    /// @param currentBestLiquidity The highest liquidity found so far from prior discovery passes.
    /// @param bestPool The current best pool candidate to preserve unless a better V4 pool is found.
    /// @return updatedBestPool The winning pool after evaluating all supported V4 fee, tick-spacing, and hook
    /// combinations.
    function _discoverV4Pool(
        address normalizedTokenIn,
        address normalizedTokenOut,
        uint128 currentBestLiquidity,
        PoolInfo memory bestPool
    )
        internal
        view
        returns (PoolInfo memory updatedBestPool)
    {
        // Preserve the caller's current best pool unless a deeper V4 pool is found below.
        updatedBestPool = bestPool;

        // Exit early on chains where V4 is not deployed.
        if (address(POOL_MANAGER) == address(0)) return updatedBestPool;

        // Convert wrapped native token -> address(0) for V4 native representation.
        address v4In = normalizedTokenIn == address(WRAPPED_NATIVE_TOKEN) ? address(0) : normalizedTokenIn;
        address v4Out = normalizedTokenOut == address(WRAPPED_NATIVE_TOKEN) ? address(0) : normalizedTokenOut;

        // Sort currencies (currency0 < currency1).
        (address sorted0, address sorted1) = v4In < v4Out ? (v4In, v4Out) : (v4Out, v4In);

        for (uint256 i; i < 4;) {
            for (uint256 j; j < 2;) {
                // Probe vanilla pools first, then the configured hooked-pool family if one exists.
                IHooks hooks = j == 0 ? IHooks(address(0)) : IHooks(UNIV4_HOOK);
                if (j != 0 && address(hooks) == address(0)) {
                    unchecked {
                        ++j;
                    }
                    continue;
                }

                // Build the V4 pool key for the current fee / tick-spacing / hook combination.
                // Fee tiers and tick spacings are returned from pure functions (no SLOAD).
                PoolKey memory key;
                {
                    (uint24 fee, int24 tickSpacing) = _v4FeeAndTickSpacing(i);
                    key = PoolKey({
                        currency0: _wrapCurrency(sorted0),
                        currency1: _wrapCurrency(sorted1),
                        fee: fee,
                        tickSpacing: tickSpacing,
                        hooks: hooks
                    });
                }

                // Cache key.toId() to avoid recomputing the same hash twice per inner iteration.
                PoolId id = key.toId();

                // Probe slot0 first so uninitialized pools can be skipped without treating them as valid candidates.
                (uint160 sqrtPriceX96,,,) = _getSlot0(id);
                if (sqrtPriceX96 == 0) {
                    unchecked {
                        ++j;
                    }
                    continue;
                }

                // Read the current in-range liquidity for the initialized pool.
                uint128 poolLiquidity = _getLiquidity(id);
                if (poolLiquidity > currentBestLiquidity) {
                    // Promote this V4 pool when it beats every candidate seen so far.
                    currentBestLiquidity = poolLiquidity;
                    updatedBestPool.isV4 = true;
                    updatedBestPool.v3Pool = IUniswapV3Pool(address(0));
                    updatedBestPool.v4Key = key;
                }

                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get the slippage tolerance for a given swap using the continuous sigmoid formula.
    /// @param amountIn The amount of tokens to swap.
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
        // Identify token0 so the quote logic can determine the swap direction in canonical pool order.
        (address token0,) = tokenOut < tokenIn ? (tokenOut, tokenIn) : (tokenIn, tokenOut);

        // Record whether the swap moves from token0 to token1, which the impact helper needs for its math.
        bool zeroForOne = tokenIn == token0;

        // Convert the quoted tick into the corresponding sqrt price used by the impact model.
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);

        // Fall back to the full denominator if the tick maps to zero, which effectively means "100% slippage guard".
        if (sqrtP == 0) return _SLIPPAGE_DENOMINATOR;

        // Estimate the trade's price impact from size, liquidity, price, and swap direction.
        uint256 impact =
            JBSwapLib.calculateImpact({amountIn: amountIn, liquidity: liquidity, sqrtP: sqrtP, zeroForOne: zeroForOne});

        // Convert the estimated impact into the bounded sigmoid slippage tolerance used by the router.
        return JBSwapLib.getSlippageTolerance({impact: impact, poolFeeBps: poolFeeBps});
    }

    /// @notice Get a TWAP-based quote with dynamic slippage for a V3 pool.
    /// @param pool The V3 pool to quote.
    /// @param normalizedTokenIn The normalized token to swap in.
    /// @param normalizedTokenOut The normalized token to swap out.
    /// @param amount The amount of `normalizedTokenIn` to quote.
    /// @return minAmountOut The minimum amount out implied by the TWAP quote and dynamic slippage model.
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
        // Convert the V3 fee tier into basis points so the slippage helper can incorporate pool fees consistently.
        uint256 feeBps = uint256(pool.fee()) / 100;

        // Read the oldest observation age to determine how much TWAP history the pool can support.
        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(address(pool));

        // Abort when the pool has no oracle history at all, since no TWAP can be formed.
        if (oldestObservation == 0) revert JBRouterTerminal_NoObservationHistory({pool: address(pool)});

        // Start from the default TWAP window.
        uint256 twapWindow = DEFAULT_TWAP_WINDOW;

        // Clamp the TWAP window down when the pool's observation history is shorter than the default window.
        if (oldestObservation < twapWindow) twapWindow = oldestObservation;

        // Enforce a minimum TWAP window to prevent manipulation of short-history pools.
        if (twapWindow < MIN_TWAP_WINDOW) {
            revert JBRouterTerminal_InsufficientTwapHistory({
                pool: address(pool), twapWindow: twapWindow, minTwapWindow: MIN_TWAP_WINDOW
            });
        }

        // Query the V3 oracle for the arithmetic-mean tick and in-range liquidity over the chosen TWAP window.
        (
            int24 arithmeticMeanTick,
            uint128 liquidity
            // forge-lint: disable-next-line(unsafe-typecast)
        ) = OracleLibrary.consult({pool: address(pool), secondsAgo: uint32(twapWindow)});

        // Abort when the chosen TWAP window has no in-range liquidity.
        if (liquidity == 0) {
            revert JBRouterTerminal_NoLiquidity({pool: address(pool), poolId: PoolId.wrap(bytes32(0))});
        }

        // Convert the TWAP tick and liquidity into a minimum amount out using the router's dynamic slippage model.
        minAmountOut = _quoteWithSlippage({
            amount: amount,
            liquidity: liquidity,
            tokenIn: normalizedTokenIn,
            tokenOut: normalizedTokenOut,
            tick: arithmeticMeanTick,
            poolFeeBps: feeBps
        });
    }

    /// @notice Get an automatic V4 quote with dynamic slippage.
    /// @dev Prefers a hook-provided geomean/TWAP quote when available. Falls back to the pool's spot tick otherwise.
    /// This fallback is an accepted product risk for programmatic integrations that cannot provide an external quote,
    /// but it should be understood as a bounded-convenience path rather than a fully manipulation-resistant one.
    ///
    /// SECURITY NOTE: The spot price read from `POOL_MANAGER.getSlot0(id)` is an instantaneous value
    /// that can be manipulated within the same block (e.g. via sandwich attacks or flash loans). Unlike V3 pools,
    /// V4 vanilla pools do not expose a built-in TWAP oracle, so there is no manipulation-resistant price source
    /// available on-chain for automatic quoting.
    ///
    /// Accepted operating envelope:
    ///   1. This path is intended mainly for routine flows against sufficiently deep pools where the cost of
    ///      manipulating the spot price is expected to outweigh likely extractable value.
    ///   2. Deep liquidity reduces practical risk, but does NOT remove the underlying same-block manipulation surface.
    ///   3. Thin pools, newly initialized pools, and unusually large swaps should not rely on this fallback.
    ///
    /// Mitigations in place:
    ///   1. Users SHOULD provide a `quoteForSwap` value in the payment metadata (obtained from an off-chain
    ///      quoter or RPC simulation). When present, this function is bypassed entirely — see `_pickPoolAndQuote`.
    ///   2. When a hook implements `IGeomeanOracle.observe(...)`, this function uses that oracle-derived tick instead
    ///      of spot.
    ///   3. The sigmoid slippage formula (`JBSwapLib.getSlippageTolerance`) enforces a minimum 2% slippage floor
    ///      (pool fee + 1%, with a hard floor of 2%), which bounds the worst-case loss even if the spot price is
    ///      manipulated. For small swaps in deep pools the tolerance stays near this floor; for larger swaps it
    ///      scales up to the 88% ceiling via a continuous sigmoid curve.
    ///   4. Pool discovery (`_discoverPool`) may select a V3 pool with TWAP if it has more liquidity, avoiding
    ///      this V4 spot-price path altogether.
    ///
    /// Despite these mitigations, the spot-based fallback does NOT provide full MEV protection. Integrators and
    /// front-ends should supply `quoteForSwap` metadata for V4 swaps whenever possible so the user's slippage
    /// tolerance reflects a recent, off-chain-verified price. When no external quote can be provided, this fallback
    /// is still available as an accepted-risk convenience path.
    /// @param key The V4 pool key describing the pool to quote against.
    /// @param normalizedTokenIn The normalized token to sell into the pool.
    /// @param normalizedTokenOut The normalized token to buy from the pool.
    /// @param amount The exact input amount to quote.
    /// @return minAmountOut The quoted minimum output after the router's slippage model is applied.
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
            secondsAgos[0] = _TWAP_WINDOW; // Start of the window (120 seconds ago).
            secondsAgos[1] = 0; // End of the window (current block).

            // Ask the hook for cumulative tick data over the window. Silently catch if it doesn't support it.
            try IGeomeanOracle(address(key.hooks)).observe(key, secondsAgos) returns (
                int56[] memory tickCumulatives, uint160[] memory
            ) {
                // Guard against malicious/broken hooks returning fewer elements than requested.
                // An OOB access in the try-success block panics and is NOT caught by catch{}.
                if (tickCumulatives.length >= 2) {
                    // Derive the arithmetic mean tick: (cumulative_now - cumulative_start) / elapsed_seconds.
                    int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
                    // The TWAP window is a small protocol constant that fits in int32 and int56.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    int56 period = int56(int32(_TWAP_WINDOW));
                    // The cumulative tick values come from Uniswap observations, whose average tick is int24-bounded.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    tick = int24(tickDelta / period);
                    // Round towards negative infinity for negative ticks (Uniswap convention).
                    if (tickDelta < 0 && (tickDelta % period != 0)) tick--;
                    usedTwap = true;
                }
            } catch {}
        }

        // If no TWAP was available (no hook, or hook doesn't implement observe), use the instantaneous spot tick.
        if (!usedTwap) {
            (, tick,,) = _getSlot0(id);
        }

        uint128 liquidity = _getLiquidity(id);

        if (liquidity == 0) revert JBRouterTerminal_NoLiquidity({pool: address(0), poolId: id});

        // V4 uses address(0) for native tokens; map the wrapped native token so OracleLibrary token sorting matches the
        // pool.
        normalizedTokenIn = normalizedTokenIn == address(WRAPPED_NATIVE_TOKEN) ? address(0) : normalizedTokenIn;
        normalizedTokenOut = normalizedTokenOut == address(WRAPPED_NATIVE_TOKEN) ? address(0) : normalizedTokenOut;

        if (!usedTwap) {
            // Without TWAP, instantaneous liquidity and spot price are both JIT-manipulable.
            // Use a fixed conservative slippage tolerance (15%) instead of the sigmoid formula, which
            // an attacker could deflate by inflating liquidity via just-in-time provisioning.
            uint256 fixedSlippage = 1500; // 15% in basis points of _SLIPPAGE_DENOMINATOR (10_000)

            // Quote the gross output at the spot tick.
            if (amount > type(uint128).max) revert JBRouterTerminal_AmountOverflow(amount);

            minAmountOut = OracleLibrary.getQuoteAtTick({
                tick: tick,
                // forge-lint: disable-next-line(unsafe-typecast)
                baseAmount: uint128(amount),
                baseToken: normalizedTokenIn,
                quoteToken: normalizedTokenOut
            });

            // Apply the fixed slippage tolerance.
            minAmountOut -= (minAmountOut * fixedSlippage) / _SLIPPAGE_DENOMINATOR;
        } else {
            minAmountOut = _quoteWithSlippage({
                amount: amount,
                liquidity: liquidity,
                tokenIn: normalizedTokenIn,
                tokenOut: normalizedTokenOut,
                tick: tick,
                poolFeeBps: uint256(key.fee) / 100
            });
        }
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    /// @return calldata The `msg.data` of this call.
    function _msgData() internal view override returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    /// @return sender The address which sent this call.
    function _msgSender() internal view override returns (address sender) {
        return ERC2771Context._msgSender();
    }

    /// @notice Return the balance of an account for a token, using ETH balance for the native token sentinel.
    /// @param token The token to read the balance of.
    /// @param account The account to read the balance of.
    /// @return balance The account's balance in `token`.
    function _balanceOf(address token, address account) internal view returns (uint256) {
        // Read raw ETH balance for the native-token sentinel and ERC20 balance otherwise.
        return token == JBConstants.NATIVE_TOKEN ? account.balance : IERC20(_normalize(token)).balanceOf(account);
    }

    /// @notice Normalize a token address by replacing the native token sentinel with the wrapped native token.
    /// @param token The token to normalize.
    /// @return normalizedToken The normalized token address.
    function _normalize(address token) internal view returns (address) {
        // Replace the native-token sentinel with the wrapped native token so both share one routing representation.
        return token == JBConstants.NATIVE_TOKEN ? address(WRAPPED_NATIVE_TOKEN) : token;
    }

    /// @notice Discover a pool and compute the minimum acceptable output for a swap. Uses a user-provided quote if
    /// available, otherwise falls back to TWAP (V3) or automatic V4 quoting with dynamic slippage.
    /// @dev For V4 pools without TWAP-capable hooks, `minAmountOut` is derived from the same-block spot tick, which is
    /// manipulable via sandwich attacks. This is an accepted risk for integrations that cannot source external quotes,
    /// especially when routing through deep pools and routine swap sizes, but it should not be treated as full MEV
    /// protection. Integrators should still supply `quoteForSwap` metadata whenever they can.
    ///
    /// Priority for `minAmountOut`:
    ///   1. **User-provided quote** — If `quoteForSwap` is present in `metadata`, it is used directly.
    ///      This is the recommended path for MEV protection, especially for V4 pools.
    ///   2. **V3 TWAP** — If the best pool is V3, uses a manipulation-resistant time-weighted average price.
    ///   3. **V4 automatic quote** — If the best pool is V4, first attempts a hook-provided oracle quote and
    ///      otherwise falls back to the instantaneous `getSlot0` tick. The spot fallback is manipulable within the
    ///      same block (see `_getV4SpotQuote` security note). The sigmoid slippage formula provides a floor but not
    ///      full MEV protection.
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
        pool = _discoverPool({normalizedTokenIn: normalizedTokenIn, normalizedTokenOut: normalizedTokenOut});
        if (!pool.isV4 && address(pool.v3Pool) == address(0)) {
            revert JBRouterTerminal_NoPoolFound({tokenIn: normalizedTokenIn, tokenOut: normalizedTokenOut});
        }

        // Check for a user-provided quote.
        (bool exists, bytes memory quote) = _getDataFor({metadata: metadata, id: _QUOTE_FOR_SWAP_ID});

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

    /// @notice Get a minimum-amount-out quote at the given tick, applying dynamic slippage.
    /// @param amount The input amount.
    /// @param liquidity The pool's in-range liquidity.
    /// @param tokenIn The input token address for sorting and quoting.
    /// @param tokenOut The output token address for sorting and quoting.
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
        // Derive the sigmoid slippage tolerance for this quoted trade shape.
        uint256 slippageTolerance = _getSlippageTolerance({
            amountIn: amount,
            liquidity: liquidity,
            tokenOut: tokenOut,
            tokenIn: tokenIn,
            arithmeticMeanTick: tick,
            poolFeeBps: poolFeeBps
        });

        // Treat a full-denominator slippage tolerance as "no safe output" and surface 0 immediately.
        if (slippageTolerance >= _SLIPPAGE_DENOMINATOR) return 0;

        // Uniswap's quote helper accepts only uint128 base amounts.
        if (amount > type(uint128).max) revert JBRouterTerminal_AmountOverflow(amount);

        // Quote the gross output at the supplied tick before applying the router's slippage buffer.
        minAmountOut = OracleLibrary.getQuoteAtTick({
            tick: tick,
            // forge-lint: disable-next-line(unsafe-typecast)
            baseAmount: uint128(amount),
            baseToken: tokenIn,
            quoteToken: tokenOut
        });

        // Discount the gross quote by the computed slippage tolerance to get the enforceable minimum.
        minAmountOut -= (minAmountOut * slippageTolerance) / _SLIPPAGE_DENOMINATOR;
    }

    /// @notice Read a metadata entry from the router's metadata namespace.
    /// @param metadata The metadata blob to query.
    /// @param id The pre-computed metadata ID to look up.
    /// @return exists Whether the metadata entry was present.
    /// @return data The raw metadata payload for `id`.
    function _getDataFor(bytes calldata metadata, bytes4 id) internal pure returns (bool exists, bytes memory data) {
        return JBMetadataResolver.getDataFor({id: id, metadata: metadata});
    }

    /// @notice Wrap an address into a Uniswap V4 `Currency`.
    /// @param token The token address to wrap.
    /// @return currency The wrapped currency value.
    function _wrapCurrency(address token) internal pure returns (Currency currency) {
        return Currency.wrap(token);
    }

    /// @notice Return the V3 fee tier at the given index.
    /// @dev Replaces the storage array `_FEE_TIERS` with a pure function (no SLOAD).
    /// @param index The tier index (0-3), ordered by commonality: 0.3%, 0.05%, 1%, 0.01%.
    /// @return fee The fee value.
    function _feeTier(uint256 index) internal pure returns (uint24 fee) {
        if (index == 0) return 3000;
        if (index == 1) return 500;
        if (index == 2) return 10_000;
        return 100;
    }

    /// @notice Return the V4 fee and tick spacing at the given index.
    /// @dev Replaces the storage arrays `_V4_FEES` and `_V4_TICK_SPACINGS` with a single pure function (no SLOAD).
    /// @param index The tier index (0-3).
    /// @return fee The V4 fee value.
    /// @return tickSpacing The V4 tick spacing value.
    function _v4FeeAndTickSpacing(uint256 index) internal pure returns (uint24 fee, int24 tickSpacing) {
        if (index == 0) return (3000, 60);
        if (index == 1) return (500, 10);
        if (index == 2) return (10_000, 200);
        return (100, 1);
    }
}
