// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPermitTerminal} from "@bananapus/core-v6/src/interfaces/IJBPermitTerminal.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";

import {IJBRouterTerminal} from "./interfaces/IJBRouterTerminal.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {JBSwapLib} from "./libraries/JBSwapLib.sol";
import {PoolInfo} from "./structs/PoolInfo.sol";

/// @notice The `JBRouterTerminal` accepts any token and dynamically discovers what token each destination project
/// accepts, then routes the payment there — via direct forwarding, Uniswap swap, JB token cashout, or a combination.
/// Supports both Uniswap V3 and V4 pools, choosing whichever offers better liquidity.
/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
contract JBRouterTerminal is
    JBPermissioned,
    Ownable,
    ERC2771Context,
    IJBTerminal,
    IJBPermitTerminal,
    IUniswapV3SwapCallback,
    IUnlockCallback,
    IJBRouterTerminal
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
    error JBRouterTerminal_NoCashOutPath(uint256 sourceProjectId, uint256 destProjectId);
    error JBRouterTerminal_NoLiquidity();
    error JBRouterTerminal_NoMsgValueAllowed(uint256 value);
    error JBRouterTerminal_NoObservationHistory();
    error JBRouterTerminal_NoPoolFound(address tokenIn, address tokenOut);
    error JBRouterTerminal_NoRouteFound(uint256 projectId, address tokenIn);
    error JBRouterTerminal_PermitAllowanceNotEnough(uint256 amount, uint256 allowance);
    error JBRouterTerminal_SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error JBRouterTerminal_TokenNotAccepted(uint256 projectId, address token);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The default TWAP window used for auto-discovered pools.
    uint256 public constant DEFAULT_TWAP_WINDOW = 10 minutes;

    /// @notice The denominator used for slippage tolerance basis points.
    uint256 public constant SLIPPAGE_DENOMINATOR = 10_000;

    //*********************************************************************//
    // ---------------------- internal stored properties ----------------- //
    //*********************************************************************//

    /// @notice The fee tiers to search when auto-discovering V3 pools, ordered by commonality.
    /// 3000 = 0.3%, 500 = 0.05%, 10000 = 1%, 100 = 0.01%.
    uint24[4] internal _FEE_TIERS = [uint24(3000), uint24(500), uint24(10_000), uint24(100)];

    /// @notice The fee/tickSpacing pairings to search for V4 vanilla pools.
    uint24[4] internal _V4_FEES = [uint24(3000), uint24(500), uint24(10_000), uint24(100)];
    int24[4] internal _V4_TICK_SPACINGS = [int24(60), int24(10), int24(200), int24(1)];

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The directory of terminals and controllers for projects.
    IJBDirectory public immutable DIRECTORY;

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    IJBProjects public immutable PROJECTS;

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

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param permissions A contract storing permissions.
    /// @param projects A contract which mints ERC-721s that represent project ownership and transfers.
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
        IJBProjects projects,
        IJBTokens tokens,
        IPermit2 permit2,
        address owner,
        IWETH9 weth,
        IUniswapV3Factory factory,
        IPoolManager poolManager,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
        Ownable(owner)
    {
        DIRECTORY = directory;
        PROJECTS = projects;
        TOKENS = tokens;
        FACTORY = factory;
        POOL_MANAGER = poolManager;
        PERMIT2 = permit2;
        WETH = weth;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Returns a dynamic accounting context for any token with 18 decimals.
    /// @dev The router terminal does not store accounting contexts — it constructs them on the fly because it can
    /// accept any token.
    /// @param token The address of the token to get the accounting context for.
    /// @return context A `JBAccountingContext` for the specified token.
    function accountingContextForTokenOf(
        uint256,
        address token
    )
        external
        pure
        override
        returns (JBAccountingContext memory context)
    {
        context = JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    /// @notice Returns an empty array — this terminal accepts any token dynamically.
    /// @return contexts An empty array of `JBAccountingContext`.
    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](0);
    }

    /// @notice This terminal holds no surplus. Always returns 0.
    function currentSurplusOf(
        uint256,
        JBAccountingContext[] memory,
        uint256,
        uint256
    )
        external
        pure
        override
        returns (uint256)
    {
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
        returns (PoolInfo memory pool)
    {
        return _discoverPool(normalizedTokenIn, normalizedTokenOut);
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
        PoolInfo memory info = _discoverPool(normalizedTokenIn, normalizedTokenOut);
        if (!info.isV4) pool = info.v3Pool;
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
            || interfaceId == type(IERC165).interfaceId || interfaceId == type(IJBPermissioned).interfaceId;
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
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
        {
            amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});

            address tokenOut;
            uint256 amountOut;
            (destTerminal, tokenOut, amountOut) =
                _route({destProjectId: projectId, tokenIn: token, amount: amount, metadata: metadata});
            token = tokenOut;
            amount = amountOut;
        }

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
    function migrateBalanceOf(uint256, address, IJBTerminal) external override returns (uint256 balance) {
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
        IJBTerminal destTerminal;
        {
            amount = _acceptFundsFor({token: token, amount: amount, metadata: metadata});

            address tokenOut;
            uint256 amountOut;
            (destTerminal, tokenOut, amountOut) =
                _route({destProjectId: projectId, tokenIn: token, amount: amount, metadata: metadata});
            token = tokenOut;
            amount = amountOut;
        }

        uint256 payValue = _beforeTransferFor({to: address(destTerminal), token: token, amount: amount});

        return destTerminal.pay{value: payValue}({
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
        address normalizedTokenIn = tokenIn == JBConstants.NATIVE_TOKEN ? address(WETH) : tokenIn;
        address normalizedTokenOut = tokenOut == JBConstants.NATIVE_TOKEN ? address(WETH) : tokenOut;

        // Verify caller is a legitimate pool via the factory.
        uint24 fee = IUniswapV3Pool(msg.sender).fee();
        address expectedPool = FACTORY.getPool(normalizedTokenIn, normalizedTokenOut, fee);
        if (msg.sender != expectedPool) revert JBRouterTerminal_CallerNotPool(msg.sender);

        // Calculate the amount of tokens to send to the pool (the positive delta).
        uint256 amountToSendToPool = amount0Delta < 0 ? uint256(amount1Delta) : uint256(amount0Delta);

        // Wrap native tokens if needed.
        if (tokenIn == JBConstants.NATIVE_TOKEN) WETH.deposit{value: amountToSendToPool}();

        // Transfer the tokens to the pool.
        IERC20(normalizedTokenIn).safeTransfer(msg.sender, amountToSendToPool);
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
        uint256 amountIn;
        uint256 amountOut;
        {
            int128 delta0 = delta.amount0();
            int128 delta1 = delta.amount1();
            if (zeroForOne) {
                amountIn = uint256(uint128(-delta0));
                amountOut = uint256(uint128(delta1));
            } else {
                amountIn = uint256(uint128(-delta1));
                amountOut = uint256(uint128(delta0));
            }
        }

        if (amountOut < minAmountOut) revert JBRouterTerminal_SlippageExceeded(amountOut, minAmountOut);

        // Settle input (pay what we owe to the PoolManager).
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        _settleV4(inputCurrency, amountIn);

        // Take output (receive what the PoolManager owes us).
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        _takeV4(outputCurrency, amountOut);

        return abi.encode(amountOut);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Accepts a token being paid in.
    /// @param token The address of the token being paid in.
    /// @param amount The amount of tokens being paid in.
    /// @param metadata The metadata in which `permit2` and credit context is provided.
    /// @return The amount of tokens that have been accepted.
    function _acceptFundsFor(address token, uint256 amount, bytes calldata metadata) internal returns (uint256) {
        // Check for credit cash-out metadata.
        {
            (bool creditExists, bytes memory creditData) =
                JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("cashOutSource"), metadata: metadata});

            if (creditExists) {
                // Credit cashouts don't use msg.value — revert if ETH was sent to prevent it being trapped.
                if (msg.value != 0) revert JBRouterTerminal_NoMsgValueAllowed(msg.value);

                (uint256 sourceProjectId, uint256 creditAmount) = abi.decode(creditData, (uint256, uint256));

                // Pull credits from the payer (requires payer to have granted TRANSFER_CREDITS to this contract).
                TOKENS.transferCreditsFrom({
                    holder: _msgSender(), projectId: sourceProjectId, recipient: address(this), count: creditAmount
                });

                return creditAmount;
            }
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
            if (amount > allowance.amount) {
                revert JBRouterTerminal_PermitAllowanceNotEnough(amount, allowance.amount);
            }

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
        IERC20(token).safeIncreaseAllowance(to, amount);

        return 0;
    }

    /// @notice Find the highest liquidity across all V3 fee tiers and V4 pools for a token pair.
    /// @param tokenA One token in the pair.
    /// @param tokenB The other token in the pair.
    /// @return bestLiquidity The highest liquidity found, or 0 if no pool exists.
    function _bestPoolLiquidity(address tokenA, address tokenB) internal view returns (uint128 bestLiquidity) {
        // Search V3.
        for (uint256 i; i < 4; i++) {
            // slither-disable-next-line calls-loop
            address poolAddr = FACTORY.getPool(tokenA, tokenB, _FEE_TIERS[i]);
            if (poolAddr == address(0)) continue;

            // slither-disable-next-line calls-loop
            uint128 liquidity = IUniswapV3Pool(poolAddr).liquidity();
            if (liquidity > bestLiquidity) bestLiquidity = liquidity;
        }

        // Search V4 — reuse _discoverV4Pool with current best.
        PoolInfo memory v4Result = _discoverV4Pool(
            tokenA,
            tokenB,
            bestLiquidity,
            PoolInfo({
                isV4: false,
                v3Pool: IUniswapV3Pool(address(0)),
                v4Key: PoolKey({
                    currency0: Currency.wrap(address(0)),
                    currency1: Currency.wrap(address(0)),
                    fee: 0,
                    tickSpacing: 0,
                    hooks: IHooks(address(0))
                })
            })
        );
        if (v4Result.isV4) {
            bestLiquidity = POOL_MANAGER.getLiquidity(v4Result.v4Key.toId());
        }
    }

    /// @notice The maximum number of cashout iterations before reverting. Prevents infinite loops from circular
    /// token dependencies.
    uint256 internal constant _MAX_CASHOUT_ITERATIONS = 20;

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
        bytes calldata metadata
    )
        internal
        returns (IJBTerminal destTerminal, address finalToken, uint256 finalAmount)
    {
        // Check for a user-provided minimum cashout reclaim amount (slippage protection).
        uint256 minTokensReclaimed;
        {
            (bool exists, bytes memory minData) =
                JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("cashOutMinReclaimed"), metadata: metadata});
            if (exists) minTokensReclaimed = abi.decode(minData, (uint256));
        }

        for (uint256 i; i < _MAX_CASHOUT_ITERATIONS; i++) {
            // Skip the destination check on the first iteration if we have a credit override.
            if (sourceProjectIdOverride == 0) {
                // slither-disable-next-line calls-loop
                destTerminal = DIRECTORY.primaryTerminalOf({projectId: destProjectId, token: token});
                // Skip if the destination terminal is this router itself (would recurse).
                if (address(destTerminal) != address(0) && address(destTerminal) != address(this)) {
                    return (destTerminal, token, amount);
                }
            }

            // Use the override if provided, otherwise look up the project ID from the token.
            // slither-disable-next-line calls-loop
            uint256 sourceProjectId =
                sourceProjectIdOverride != 0 ? sourceProjectIdOverride : TOKENS.projectIdOf(IJBToken(token));

            // If it's not a JB project token, return as-is (caller handles the swap).
            if (sourceProjectId == 0) {
                return (IJBTerminal(address(0)), token, amount);
            }

            // Find which terminal to cash out from and which token to reclaim.
            (address tokenToReclaim, IJBCashOutTerminal cashOutTerminal) =
                _findCashOutPath({sourceProjectId: sourceProjectId, destProjectId: destProjectId});

            // Cash out the source project's tokens.
            // slither-disable-next-line calls-loop
            amount = cashOutTerminal.cashOutTokensOf({
                holder: address(this),
                projectId: sourceProjectId,
                cashOutCount: amount,
                tokenToReclaim: tokenToReclaim,
                minTokensReclaimed: minTokensReclaimed,
                beneficiary: payable(address(this)),
                metadata: bytes("")
            });

            // Only apply the minimum to the first cashout step.
            minTokensReclaimed = 0;

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
    /// @return The amount of tokenOut produced.
    function _convert(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 projectId,
        bytes calldata metadata
    )
        internal
        returns (uint256)
    {
        // Exact same token — no conversion needed.
        if (tokenIn == tokenOut) return amount;

        address nIn = tokenIn == JBConstants.NATIVE_TOKEN ? address(WETH) : tokenIn;
        address nOut = tokenOut == JBConstants.NATIVE_TOKEN ? address(WETH) : tokenOut;

        if (nIn == nOut) {
            // Same underlying token — just wrap or unwrap.
            if (tokenIn == JBConstants.NATIVE_TOKEN) {
                WETH.deposit{value: amount}();
            } else {
                WETH.withdraw(amount);
            }
            return amount;
        }

        // Different tokens — swap via Uniswap (V3 or V4).
        return
            _handleSwap({
                projectId: projectId, tokenIn: tokenIn, tokenOut: tokenOut, amount: amount, metadata: metadata
            });
    }

    /// @notice Search a project's terminals for an accepted token that has a Uniswap pool with tokenIn.
    /// @dev Falls back to the first accepted token if no pool exists (for JB token cashout paths).
    /// @param projectId The ID of the project to search.
    /// @param tokenIn The input token to find a pool for.
    /// @return tokenOut The best accepted token found.
    /// @return destTerminal The terminal that accepts tokenOut.
    function _discoverAcceptedToken(
        uint256 projectId,
        address tokenIn
    )
        internal
        view
        returns (address tokenOut, IJBTerminal destTerminal)
    {
        address normalizedTokenIn = tokenIn == JBConstants.NATIVE_TOKEN ? address(WETH) : tokenIn;
        IJBTerminal[] memory terminals = DIRECTORY.terminalsOf(projectId);

        uint128 bestLiquidity;
        bool hasFallback;

        for (uint256 i; i < terminals.length; i++) {
            // slither-disable-next-line calls-loop
            JBAccountingContext[] memory contexts = terminals[i].accountingContextsOf(projectId);

            for (uint256 j; j < contexts.length; j++) {
                address candidateToken = contexts[j].token;
                address normalizedCandidate =
                    candidateToken == JBConstants.NATIVE_TOKEN ? address(WETH) : candidateToken;

                if (normalizedCandidate == normalizedTokenIn) continue;

                // Save first candidate as fallback.
                if (!hasFallback) {
                    tokenOut = candidateToken;
                    destTerminal = terminals[i];
                    hasFallback = true;
                }

                // Search for pool with best liquidity (V3 + V4).
                uint128 candidateLiquidity = _bestPoolLiquidity(normalizedTokenIn, normalizedCandidate);
                if (candidateLiquidity > bestLiquidity) {
                    bestLiquidity = candidateLiquidity;
                    tokenOut = candidateToken;
                    destTerminal = terminals[i];
                }
            }
        }

        if (!hasFallback) revert JBRouterTerminal_NoRouteFound(projectId, tokenIn);
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
            address poolAddr = FACTORY.getPool(normalizedTokenIn, normalizedTokenOut, _FEE_TIERS[i]);

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

        if (!bestPool.isV4 && address(bestPool.v3Pool) == address(0)) {
            revert JBRouterTerminal_NoPoolFound(normalizedTokenIn, normalizedTokenOut);
        }
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
            (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
            // slither-disable-next-line incorrect-equality
            if (sqrtPriceX96 == 0) continue;

            // slither-disable-next-line calls-loop
            uint128 poolLiquidity = POOL_MANAGER.getLiquidity(key.toId());
            if (poolLiquidity > currentBestLiquidity) {
                currentBestLiquidity = poolLiquidity;
                bestPool = PoolInfo({isV4: true, v3Pool: IUniswapV3Pool(address(0)), v4Key: key});
            }
        }

        return bestPool;
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
                key: pool.v4Key,
                normalizedTokenIn: normalizedTokenIn,
                normalizedTokenOut: normalizedTokenOut,
                amount: amount,
                minAmountOut: minAmountOut
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
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: JBSwapLib.sqrtPriceLimitFromAmounts(amount, minAmountOut, zeroForOne),
            data: callbackData
        });

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        if (amountOut < minAmountOut) revert JBRouterTerminal_SlippageExceeded(amountOut, minAmountOut);
    }

    /// @notice Execute a swap through a V4 pool via PoolManager.unlock().
    function _executeV4Swap(
        PoolKey memory key,
        address normalizedTokenIn,
        address normalizedTokenOut,
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
        uint160 sqrtPriceLimitX96 = JBSwapLib.sqrtPriceLimitFromAmounts(amount, minAmountOut, zeroForOne);

        // V4 sign convention: negative = exact input, positive = exact output.
        bytes memory result =
            POOL_MANAGER.unlock(abi.encode(key, zeroForOne, -int256(amount), sqrtPriceLimitX96, minAmountOut));

        amountOut = abi.decode(result, (uint256));
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
        uint256 destProjectId
    )
        internal
        view
        returns (address tokenToReclaim, IJBCashOutTerminal cashOutTerminal)
    {
        address fallbackToken;
        IJBCashOutTerminal fallbackTerminal;
        address baseFallbackToken;
        IJBCashOutTerminal baseFallbackTerminal;

        // slither-disable-next-line calls-loop
        IJBTerminal[] memory terminals = DIRECTORY.terminalsOf(sourceProjectId);

        for (uint256 i; i < terminals.length; i++) {
            // Check if this terminal supports the IJBCashOutTerminal interface.
            {
                // slither-disable-next-line calls-loop
                try IERC165(address(terminals[i])).supportsInterface(type(IJBCashOutTerminal).interfaceId) returns (
                    bool supported
                ) {
                    if (!supported) continue;
                } catch {
                    continue;
                }
            }

            IJBCashOutTerminal terminal = IJBCashOutTerminal(address(terminals[i]));
            // slither-disable-next-line calls-loop
            JBAccountingContext[] memory contexts = terminals[i].accountingContextsOf(sourceProjectId);

            for (uint256 j; j < contexts.length; j++) {
                address contextToken = contexts[j].token;

                // Priority 1: Does the destination project directly accept this token?
                {
                    // slither-disable-next-line calls-loop
                    IJBTerminal destTerminal =
                        DIRECTORY.primaryTerminalOf({projectId: destProjectId, token: contextToken});
                    if (address(destTerminal) != address(0)) {
                        return (contextToken, terminal);
                    }
                }

                // Priority 2: Is this a JB project token (so we can recurse)?
                if (address(fallbackTerminal) == address(0) && contextToken != JBConstants.NATIVE_TOKEN) {
                    // slither-disable-next-line calls-loop
                    if (TOKENS.projectIdOf(IJBToken(contextToken)) != 0) {
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
    /// @return The slippage tolerance in basis points of SLIPPAGE_DENOMINATOR.
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
        if (sqrtP == 0) return SLIPPAGE_DENOMINATOR;

        uint256 impact = JBSwapLib.calculateImpact(amountIn, liquidity, sqrtP, zeroForOne);
        return JBSwapLib.getSlippageTolerance(impact, poolFeeBps);
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

        (int24 arithmeticMeanTick, uint128 liquidity) =
            OracleLibrary.consult({pool: address(pool), secondsAgo: uint32(twapWindow)});

        if (liquidity == 0) revert JBRouterTerminal_NoLiquidity();

        {
            uint256 slippageTolerance = _getSlippageTolerance({
                amountIn: amount,
                liquidity: liquidity,
                tokenOut: normalizedTokenOut,
                tokenIn: normalizedTokenIn,
                arithmeticMeanTick: arithmeticMeanTick,
                poolFeeBps: feeBps
            });

            if (slippageTolerance >= SLIPPAGE_DENOMINATOR) return 0;

            if (amount > type(uint128).max) revert JBRouterTerminal_AmountOverflow(amount);
            minAmountOut = OracleLibrary.getQuoteAtTick({
                tick: arithmeticMeanTick,
                baseAmount: uint128(amount),
                baseToken: normalizedTokenIn,
                quoteToken: normalizedTokenOut
            });

            minAmountOut -= (minAmountOut * slippageTolerance) / SLIPPAGE_DENOMINATOR;
        }
    }

    /// @notice Get a spot-price-based quote with dynamic slippage for a V4 pool.
    /// @dev V4 vanilla pools have no TWAP oracle. Uses spot tick with the same sigmoid slippage formula.
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
        // slither-disable-next-line unused-return
        (, int24 tick,,) = POOL_MANAGER.getSlot0(id);
        uint128 liquidity = POOL_MANAGER.getLiquidity(id);

        if (liquidity == 0) revert JBRouterTerminal_NoLiquidity();

        uint256 slippageTolerance = _getSlippageTolerance({
            amountIn: amount,
            liquidity: liquidity,
            tokenOut: normalizedTokenOut,
            tokenIn: normalizedTokenIn,
            arithmeticMeanTick: tick,
            poolFeeBps: uint256(key.fee) / 100
        });

        if (slippageTolerance >= SLIPPAGE_DENOMINATOR) return 0;

        if (amount > type(uint128).max) revert JBRouterTerminal_AmountOverflow(amount);
        minAmountOut = OracleLibrary.getQuoteAtTick({
            tick: tick, baseAmount: uint128(amount), baseToken: normalizedTokenIn, quoteToken: normalizedTokenOut
        });

        minAmountOut -= (minAmountOut * slippageTolerance) / SLIPPAGE_DENOMINATOR;
    }

    /// @notice Execute a Uniswap swap from tokenIn to tokenOut (V3 or V4).
    /// @param projectId The project ID (included in callback data).
    /// @param tokenIn The input token.
    /// @param tokenOut The output token.
    /// @param amount The amount of tokenIn to swap.
    /// @param metadata Bytes in `JBMetadataResolver`'s format (may contain quoteForSwap).
    /// @return amountOut The amount of tokenOut received.
    function _handleSwap(
        uint256 projectId,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata metadata
    )
        internal
        returns (uint256 amountOut)
    {
        address normalizedTokenIn = tokenIn == JBConstants.NATIVE_TOKEN ? address(WETH) : tokenIn;

        // Snapshot the input token balance before the swap to compute the leftover delta accurately.
        uint256 balanceBefore = IERC20(normalizedTokenIn).balanceOf(address(this));

        // Execute the swap in a scoped block to manage stack depth.
        amountOut = _executeSwap({
            normalizedTokenIn: normalizedTokenIn,
            normalizedTokenOut: tokenOut == JBConstants.NATIVE_TOKEN ? address(WETH) : tokenOut,
            amount: amount,
            metadata: metadata,
            callbackData: abi.encode(projectId, tokenIn, tokenOut)
        });

        // For native token inputs, wrap any raw ETH remaining from partial fills so the leftover check catches it.
        // In partial fills, the swap callback only wraps the amount the pool consumed, leaving excess as raw ETH.
        if (tokenIn == JBConstants.NATIVE_TOKEN && address(this).balance != 0) {
            WETH.deposit{value: address(this).balance}();
        }

        // Unwrap if output is native token.
        if (tokenOut == JBConstants.NATIVE_TOKEN) WETH.withdraw(amountOut);

        // Return leftover input tokens to payer using balance delta rather than global balance.
        uint256 balanceAfter = IERC20(normalizedTokenIn).balanceOf(address(this));
        if (balanceAfter > balanceBefore) {
            uint256 leftover = balanceAfter - balanceBefore;
            if (tokenIn == JBConstants.NATIVE_TOKEN) WETH.withdraw(leftover);
            _transferFrom({from: address(this), to: payable(_msgSender()), token: tokenIn, amount: leftover});
        }
    }

    /// @notice Discover a pool and compute the minimum acceptable output for a swap.
    /// @dev Uses a user-provided quote if available, otherwise falls back to TWAP (V3) or spot price (V4)
    /// with dynamic slippage.
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

        // Check for a user-provided quote.
        (bool exists, bytes memory quote) =
            JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("quoteForSwap"), metadata: metadata});

        if (exists) {
            (minAmountOut) = abi.decode(quote, (uint256));
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

    /// @notice Determine what output token a project accepts for a given input token.
    /// @dev Priority: 1) metadata override, 2) direct acceptance, 3) NATIVE/WETH equivalence, 4) pool discovery.
    /// @param projectId The ID of the destination project.
    /// @param tokenIn The input token being routed.
    /// @param metadata Bytes in `JBMetadataResolver`'s format.
    /// @return tokenOut The token the project accepts.
    /// @return destTerminal The terminal that accepts tokenOut.
    function _resolveTokenOut(
        uint256 projectId,
        address tokenIn,
        bytes calldata metadata
    )
        internal
        view
        returns (address tokenOut, IJBTerminal destTerminal)
    {
        // 1. Metadata override — payer specifies tokenOut explicitly.
        {
            (bool exists, bytes memory routeData) =
                JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("routeTokenOut"), metadata: metadata});
            if (exists) {
                (tokenOut) = abi.decode(routeData, (address));
                destTerminal = DIRECTORY.primaryTerminalOf({projectId: projectId, token: tokenOut});
                if (address(destTerminal) == address(0)) {
                    revert JBRouterTerminal_TokenNotAccepted(projectId, tokenOut);
                }
                return (tokenOut, destTerminal);
            }
        }

        // 2. Direct acceptance — project accepts tokenIn as-is.
        destTerminal = DIRECTORY.primaryTerminalOf({projectId: projectId, token: tokenIn});
        if (address(destTerminal) != address(0)) {
            return (tokenIn, destTerminal);
        }

        // 2b. Check NATIVE_TOKEN <-> WETH equivalence.
        if (tokenIn == JBConstants.NATIVE_TOKEN) {
            destTerminal = DIRECTORY.primaryTerminalOf({projectId: projectId, token: address(WETH)});
            if (address(destTerminal) != address(0)) return (address(WETH), destTerminal);
        } else if (tokenIn == address(WETH)) {
            destTerminal = DIRECTORY.primaryTerminalOf({projectId: projectId, token: JBConstants.NATIVE_TOKEN});
            if (address(destTerminal) != address(0)) return (JBConstants.NATIVE_TOKEN, destTerminal);
        }

        // 3. Dynamic discovery — iterate terminals, find accepted token with best Uniswap pool.
        (tokenOut, destTerminal) = _discoverAcceptedToken({projectId: projectId, tokenIn: tokenIn});
    }

    /// @notice Core routing logic shared by pay() and addToBalanceOf().
    /// @dev Determines whether to forward directly, cashout JB tokens, swap via Uniswap, or a combination.
    /// @param destProjectId The ID of the destination project.
    /// @param tokenIn The address of the token being routed.
    /// @param amount The amount of tokens being routed.
    /// @param metadata Bytes in `JBMetadataResolver`'s format.
    /// @return destTerminal The terminal to forward funds to.
    /// @return tokenOut The token the destination project accepts.
    /// @return amountOut The amount of tokenOut to forward.
    function _route(
        uint256 destProjectId,
        address tokenIn,
        uint256 amount,
        bytes calldata metadata
    )
        internal
        returns (IJBTerminal destTerminal, address tokenOut, uint256 amountOut)
    {
        // Check for credit source override.
        uint256 sourceProjectIdOverride;
        {
            (bool creditExists, bytes memory creditData) =
                JBMetadataResolver.getDataFor({id: JBMetadataResolver.getId("cashOutSource"), metadata: metadata});
            if (creditExists) {
                (sourceProjectIdOverride,) = abi.decode(creditData, (uint256, uint256));
            }
        }

        // Check if input is a JB project token (credit or ERC-20).
        uint256 sourceProjectId = sourceProjectIdOverride;
        if (sourceProjectId == 0 && tokenIn != JBConstants.NATIVE_TOKEN) {
            sourceProjectId = TOKENS.projectIdOf(IJBToken(tokenIn));
        }

        if (sourceProjectId != 0) {
            // JB token path: cashout recursively, then maybe swap the reclaimed token.
            (destTerminal, tokenOut, amountOut) = _cashOutLoop({
                destProjectId: destProjectId,
                token: tokenIn,
                amount: amount,
                sourceProjectIdOverride: sourceProjectIdOverride,
                metadata: metadata
            });

            // If the cashout loop found a terminal that accepts the reclaimed token, we're done.
            if (address(destTerminal) != address(0)) {
                return (destTerminal, tokenOut, amountOut);
            }

            // Cashout produced a base token the destination doesn't accept — fall through to resolve + convert.
            tokenIn = tokenOut;
            amount = amountOut;
        }

        // Resolve what token the destination project accepts and which terminal to use.
        (tokenOut, destTerminal) = _resolveTokenOut({projectId: destProjectId, tokenIn: tokenIn, metadata: metadata});

        // Convert tokenIn -> tokenOut (no-op if they match, wrap/unwrap, or swap).
        amountOut = _convert({
            tokenIn: tokenIn, tokenOut: tokenOut, amount: amount, projectId: destProjectId, metadata: metadata
        });
    }

    /// @notice Settle the input side of a V4 swap (transfer tokens to PoolManager).
    function _settleV4(Currency currency, uint256 amount) internal {
        if (Currency.unwrap(currency) == address(0)) {
            // Native ETH: contract already holds raw ETH.
            // slither-disable-next-line unused-return
            POOL_MANAGER.settle{value: amount}();
        } else {
            // ERC20: sync then transfer then settle.
            POOL_MANAGER.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(POOL_MANAGER), amount);
            // slither-disable-next-line unused-return
            POOL_MANAGER.settle();
        }
    }

    /// @notice Take the output side of a V4 swap (receive tokens from PoolManager).
    function _takeV4(Currency currency, uint256 amount) internal {
        POOL_MANAGER.take(currency, address(this), amount);

        // If native ETH output, wrap to WETH (downstream _handleSwap unwraps if needed).
        if (Currency.unwrap(currency) == address(0)) {
            WETH.deposit{value: amount}();
        }
    }

    /// @notice Transfers tokens.
    /// @param from The address to transfer tokens from.
    /// @param to The address to transfer tokens to.
    /// @param token The address of the token being transferred.
    /// @param amount The amount of tokens to transfer.
    function _transferFrom(address from, address payable to, address token, uint256 amount) internal {
        if (from == address(this)) {
            // If the token is native token, assume the `sendValue` standard.
            if (token == JBConstants.NATIVE_TOKEN) return Address.sendValue(to, amount);

            // If the transfer is from this terminal, use `safeTransfer`.
            return IERC20(token).safeTransfer(to, amount);
        }

        // If there's sufficient approval, transfer normally.
        if (IERC20(token).allowance({owner: address(from), spender: address(this)}) >= amount) {
            return IERC20(token).safeTransferFrom(from, to, amount);
        }

        // Otherwise, attempt to use the `permit2` method.
        PERMIT2.transferFrom(from, to, uint160(amount), token);
    }

    //*********************************************************************//
    // ---------------------------- receive  ----------------------------- //
    //*********************************************************************//

    /// @notice Receive native tokens from cash out reclaims, WETH unwraps, and V4 PoolManager takes.
    receive() external payable {}
}
