// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {RouterTerminalTest, MockConfigurableCashOutTerminal, MockERC20} from "../RouterTerminal.t.sol";

/// @notice A destination terminal that previews either an active buyback route, described by the words the buyback
/// hook publishes, or a plain mint, and settles a pay by returning what that route really delivers.
/// @dev Settlement here is a fixture: `DELIVERED` is what the described pool gives, worked out from the same pool
/// model. The real hook's settlement is covered by `RouterTerminalBuybackHookFork`.
contract BuybackRoutePreviewTerminal {
    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The token this terminal accepts.
    address public immutable ACCEPTED_TOKEN;

    /// @notice The input the buyback hook swaps.
    uint256 public immutable AMOUNT_TO_SWAP_WITH;

    /// @notice The buyback hook named in the previewed hook specification.
    address public immutable BUYBACK_HOOK;

    /// @notice The tokens this route really delivers, which the preview may not show.
    uint256 public immutable DELIVERED;

    /// @notice The buyback hook's executable minimum swap output.
    uint256 public immutable MINIMUM_SWAP_AMOUNT_OUT;

    /// @notice The buyback hook's impact-free TWAP quote, or 0 for a plain mint route.
    uint256 public immutable RAW_SWAP_QUOTE;

    /// @notice The TWAP liquidity the buyback hook publishes.
    uint128 public immutable TWAP_LIQUIDITY;

    /// @notice The weight ratio the buyback hook publishes, which sets issuance against the 1e18 ruleset weight, or 0
    /// to publish none.
    uint256 public immutable WEIGHT_RATIO;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The total input this terminal has received.
    uint256 public totalReceived;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param acceptedToken The token this terminal accepts.
    /// @param amountToSwapWith The input the buyback hook swaps.
    /// @param buybackHook The buyback hook named in the previewed hook specification.
    /// @param delivered The tokens this route really delivers.
    /// @param minimumSwapAmountOut The buyback hook's executable minimum swap output.
    /// @param rawSwapQuote The buyback hook's impact-free TWAP quote, or 0 for a plain mint route.
    /// @param twapLiquidity The TWAP liquidity the buyback hook publishes.
    /// @param weightRatio The weight ratio the buyback hook publishes, or 0 to publish none.
    constructor(
        address acceptedToken,
        uint256 amountToSwapWith,
        address buybackHook,
        uint256 delivered,
        uint256 minimumSwapAmountOut,
        uint256 rawSwapQuote,
        uint128 twapLiquidity,
        uint256 weightRatio
    ) {
        ACCEPTED_TOKEN = acceptedToken;
        AMOUNT_TO_SWAP_WITH = amountToSwapWith;
        BUYBACK_HOOK = buybackHook;
        DELIVERED = delivered;
        MINIMUM_SWAP_AMOUNT_OUT = minimumSwapAmountOut;
        RAW_SWAP_QUOTE = rawSwapQuote;
        TWAP_LIQUIDITY = twapLiquidity;
        WEIGHT_RATIO = weightRatio;
    }

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Accept native refunds.
    receive() external payable {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Accept a balance addition without bookkeeping.
    /// @dev Every parameter is unused.
    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}

    /// @notice Take the payment and report what the route really delivers.
    /// @dev Unnamed parameters are the project ID, beneficiary, minimum returned tokens, memo and metadata.
    /// @param token The token paid.
    /// @param amount The amount paid.
    /// @return delivered The tokens this route delivers.
    function pay(
        uint256,
        address token,
        uint256 amount,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256 delivered)
    {
        if (token == JBConstants.NATIVE_TOKEN) {
            require(msg.value == amount, "BuybackRoutePreviewTerminal: ETH mismatch");
        } else {
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        }

        totalReceived += amount;
        delivered = DELIVERED;
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The single accounting context for `ACCEPTED_TOKEN`.
    /// @dev The unnamed parameter is the project ID.
    /// @return contexts The accepted token's context.
    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: ACCEPTED_TOKEN, decimals: 18, currency: uint32(uint160(ACCEPTED_TOKEN))});
    }

    /// @notice Preview either the buyback route's published metadata or a plain mint of `DELIVERED`.
    /// @dev Unnamed parameters are the project ID, token, amount, beneficiary and metadata.
    /// @return ruleset A placeholder ruleset with a 1e18 weight.
    /// @return beneficiaryTokenCount The plain mint's count, or 0 when the buyback hook mints.
    /// @return reservedTokenCount Always 0.
    /// @return hookSpecifications The buyback hook's specification with its 18 published words, if any.
    function previewPayFor(
        uint256,
        address,
        uint256,
        address,
        bytes calldata
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
        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 555,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        // A route without a buyback quote is a plain mint.
        if (RAW_SWAP_QUOTE == 0) return (ruleset, DELIVERED, 0, hookSpecifications);

        hookSpecifications = new JBPayHookSpecification[](1);
        hookSpecifications[0] = JBPayHookSpecification({
            hook: IJBPayHook(BUYBACK_HOOK),
            noop: false,
            amount: AMOUNT_TO_SWAP_WITH,
            metadata: abi.encode(
                false,
                uint256(0),
                MINIMUM_SWAP_AMOUNT_OUT,
                false,
                address(0),
                WEIGHT_RATIO == 0 ? 0 : AMOUNT_TO_SWAP_WITH * 1e18 / WEIGHT_RATIO,
                WEIGHT_RATIO,
                AMOUNT_TO_SWAP_WITH,
                int24(0),
                TWAP_LIQUIDITY,
                PoolId.wrap(bytes32(0)),
                MINIMUM_SWAP_AMOUNT_OUT,
                uint256(0),
                RAW_SWAP_QUOTE,
                false,
                false,
                uint256(0),
                true
            )
        });
    }

    /// @notice Report terminal and ERC-165 support so the router accepts this terminal.
    /// @param interfaceId The interface ID to check.
    /// @return supported Whether the interface is supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool supported) {
        supported = interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @title ThinPoolBuybackRouteMisrankTest
/// @notice The router scores an active buyback route by the settlement its pool can give after price impact and the
/// hook's issuance price limit, not the raw TWAP quote and not only the hook's conservative minimum. A 1 ETH pay
/// reaches the destination project as ETH or tokenB (a WETH stand-in) through a 1:1 cash-out of the payer's
/// source-project tokens.
contract ThinPoolBuybackRouteMisrankTest is RouterTerminalTest {
    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The input both routes receive after the 1:1 cash-out.
    uint256 internal constant _AMOUNT = 1e18;

    /// @notice The project being paid.
    uint256 internal constant _DEST_PROJECT_ID = 1;

    /// @notice The project whose tokens the payer routes in.
    uint256 internal constant _SOURCE_PROJECT_ID = 2;

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice A pool at 1% impact: raw 1,000, real ~990, sigmoid floor 836.7. A plain mint route gives 900. Scoring
    /// the minimum alone would pick the mint and deliver 900; the pool delivers 990.
    function test_conservativeSigmoidFloorDoesNotLoseToWorseMintRoute() public {
        MockERC20 tokenB = new MockERC20();
        BuybackRoutePreviewTerminal nativeTerminal = new BuybackRoutePreviewTerminal({
            acceptedToken: JBConstants.NATIVE_TOKEN,
            amountToSwapWith: 0,
            buybackHook: address(0),
            delivered: 900e18,
            minimumSwapAmountOut: 0,
            rawSwapQuote: 0,
            twapLiquidity: 0,
            weightRatio: 0
        });
        BuybackRoutePreviewTerminal tokenBTerminal = new BuybackRoutePreviewTerminal({
            acceptedToken: address(tokenB),
            amountToSwapWith: _AMOUNT,
            buybackHook: buybackHook,
            delivered: 990e18,
            minimumSwapAmountOut: 836.7e18,
            rawSwapQuote: 1000e18,
            twapLiquidity: 3_162_277_660_168_379_331_900,
            weightRatio: 0
        });

        (uint256 preview, uint256 delivered) =
            _previewAndPay({nativeTerminal: nativeTerminal, tokenBTerminal: tokenBTerminal});

        assertApproxEqRel(preview, 990.099e18, 1e12, "preview scores the pool's impact-adjusted output");
        assertEq(delivered, 990e18, "pay settles through the pool");
        assertEq(nativeTerminal.totalReceived(), 0, "the worse mint route is not chosen");
        assertEq(tokenBTerminal.totalReceived(), _AMOUNT, "pool route receives the payment");
    }

    /// @notice Issuance 250. Native pool raw 1,000 at impact 2.8 reaches the issuance price after 35.7% of the input:
    /// the swap gives 178.57 and the rest mints 160.71, 339.29 in all. Deep pool raw 310 at impact 0.1% delivers
    /// 309.69. Scoring the native pool's full-input output (263.16) would pick the deep pool and deliver 8.7% less.
    function test_partialFillScoresLeftoverIssuance() public {
        MockERC20 tokenB = new MockERC20();
        BuybackRoutePreviewTerminal nativeTerminal = new BuybackRoutePreviewTerminal({
            acceptedToken: JBConstants.NATIVE_TOKEN,
            amountToSwapWith: _AMOUNT,
            buybackHook: buybackHook,
            delivered: 339.285714e18,
            minimumSwapAmountOut: 257.89e18,
            rawSwapQuote: 1000e18,
            twapLiquidity: 11_293_848_786_315_640_471,
            weightRatio: 4e15
        });
        BuybackRoutePreviewTerminal tokenBTerminal = new BuybackRoutePreviewTerminal({
            acceptedToken: address(tokenB),
            amountToSwapWith: _AMOUNT,
            buybackHook: buybackHook,
            delivered: 309.69e18,
            minimumSwapAmountOut: 300e18,
            rawSwapQuote: 310e18,
            twapLiquidity: 17_606_816_861_659_009_145_769,
            weightRatio: 4e15
        });

        (uint256 preview, uint256 delivered) =
            _previewAndPay({nativeTerminal: nativeTerminal, tokenBTerminal: tokenBTerminal});

        assertApproxEqRel(preview, 339.285714e18, 1e12, "preview scores the partial swap plus leftover issuance");
        assertEq(delivered, 339.285714e18, "pay settles through the native pool");
        assertEq(nativeTerminal.totalReceived(), _AMOUNT, "the partially filling pool receives the payment");
        assertEq(tokenBTerminal.totalReceived(), 0, "the deep pool that delivers less is not chosen");
    }

    /// @notice Native pool ~1 ETH / 1,000 tokens: raw 1,000, impact 100%, real ~500, expected-output
    /// floor 490. Deep pool ~1,000 / 600,000 tokens: raw 600, impact 0.1%, real 599.4, sigmoid floor 577.92. Raw
    /// quote scoring would pick native and deliver 500; the deep pool delivers 599.4.
    function test_thinPoolRawQuoteDoesNotOutrankDeeperPool() public {
        MockERC20 tokenB = new MockERC20();
        BuybackRoutePreviewTerminal nativeTerminal = new BuybackRoutePreviewTerminal({
            acceptedToken: JBConstants.NATIVE_TOKEN,
            amountToSwapWith: _AMOUNT,
            buybackHook: buybackHook,
            delivered: 500e18,
            minimumSwapAmountOut: 490e18,
            rawSwapQuote: 1000e18,
            twapLiquidity: 31_622_776_601_683_793_319,
            weightRatio: 0
        });
        BuybackRoutePreviewTerminal tokenBTerminal = new BuybackRoutePreviewTerminal({
            acceptedToken: address(tokenB),
            amountToSwapWith: _AMOUNT,
            buybackHook: buybackHook,
            delivered: 599.4e18,
            minimumSwapAmountOut: 577.92e18,
            rawSwapQuote: 600e18,
            twapLiquidity: 24_494_897_427_831_780_981_972,
            weightRatio: 0
        });

        (uint256 preview, uint256 delivered) =
            _previewAndPay({nativeTerminal: nativeTerminal, tokenBTerminal: tokenBTerminal});

        assertApproxEqRel(preview, 599.4006e18, 1e12, "preview scores the deep pool's impact-adjusted output");
        assertEq(delivered, 599.4e18, "pay settles through the deep pool");
        assertEq(nativeTerminal.totalReceived(), 0, "thin native pool is not chosen");
        assertEq(tokenBTerminal.totalReceived(), _AMOUNT, "deep pool receives the payment");
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Wire both destination terminals behind a 1:1 cash-out, preview the default route, then pay it.
    /// @param nativeTerminal The destination terminal for the native route.
    /// @param tokenBTerminal The destination terminal for the tokenB route.
    /// @return preview The beneficiary token count the router previews for its chosen route.
    /// @return delivered The tokens the chosen route's terminal reports delivering.
    function _previewAndPay(
        BuybackRoutePreviewTerminal nativeTerminal,
        BuybackRoutePreviewTerminal tokenBTerminal
    )
        internal
        returns (uint256 preview, uint256 delivered)
    {
        address payer = makeAddr("payer");
        address beneficiary = makeAddr("beneficiary");

        MockERC20 jbToken = new MockERC20();
        MockERC20 tokenB = MockERC20(tokenBTerminal.ACCEPTED_TOKEN());

        // Both cash-outs reclaim 1:1, so the destination previews alone decide the route.
        MockConfigurableCashOutTerminal nativeCashOut = new MockConfigurableCashOutTerminal{value: _AMOUNT}({
            token_: jbToken,
            reclaimToken_: JBConstants.NATIVE_TOKEN,
            previewReclaimAmount_: _AMOUNT,
            executionTransferAmount_: _AMOUNT,
            executionReturnAmount_: _AMOUNT
        });
        MockConfigurableCashOutTerminal tokenBCashOut = new MockConfigurableCashOutTerminal({
            token_: jbToken,
            reclaimToken_: address(tokenB),
            previewReclaimAmount_: _AMOUNT,
            executionTransferAmount_: _AMOUNT,
            executionReturnAmount_: _AMOUNT
        });

        tokenB.mint({to: address(tokenBCashOut), amount: _AMOUNT});
        jbToken.mint({to: payer, amount: _AMOUNT});

        // The buyback hook only needs code so the router recognizes it; previews carry its metadata.
        vm.etch(buybackHook, hex"00");
        vm.mockCall({
            callee: address(mockTokens),
            data: abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(jbToken)))),
            returnData: abi.encode(_SOURCE_PROJECT_ID)
        });
        vm.mockCall({
            callee: address(mockTokens),
            data: abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(tokenB)))),
            returnData: abi.encode(uint256(0))
        });
        vm.mockCall({
            callee: address(mockDirectory),
            data: abi.encodeCall(IJBDirectory.primaryTerminalOf, (_DEST_PROJECT_ID, address(jbToken))),
            returnData: abi.encode(address(0))
        });
        vm.mockCall({
            callee: address(mockDirectory),
            data: abi.encodeCall(IJBDirectory.primaryTerminalOf, (_DEST_PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            returnData: abi.encode(address(nativeTerminal))
        });
        vm.mockCall({
            callee: address(mockDirectory),
            data: abi.encodeCall(IJBDirectory.primaryTerminalOf, (_DEST_PROJECT_ID, address(tokenB))),
            returnData: abi.encode(address(tokenBTerminal))
        });

        IJBTerminal[] memory sourceTerminals = new IJBTerminal[](2);
        sourceTerminals[0] = IJBTerminal(address(nativeCashOut));
        sourceTerminals[1] = IJBTerminal(address(tokenBCashOut));
        vm.mockCall({
            callee: address(mockDirectory),
            data: abi.encodeCall(IJBDirectory.terminalsOf, (_SOURCE_PROJECT_ID)),
            returnData: abi.encode(sourceTerminals)
        });

        IJBTerminal[] memory destTerminals = new IJBTerminal[](2);
        destTerminals[0] = IJBTerminal(address(nativeTerminal));
        destTerminals[1] = IJBTerminal(address(tokenBTerminal));
        vm.mockCall({
            callee: address(mockDirectory),
            data: abi.encodeCall(IJBDirectory.terminalsOf, (_DEST_PROJECT_ID)),
            returnData: abi.encode(destTerminals)
        });

        // Preview the default route, then pay it with no route override so the router picks the same candidate.
        vm.startPrank(payer);
        jbToken.approve({spender: address(routerTerminal), amount: type(uint256).max});
        (, preview,,) = routerTerminal.previewPayFor({
            projectId: _DEST_PROJECT_ID,
            token: address(jbToken),
            amount: _AMOUNT,
            beneficiary: beneficiary,
            metadata: ""
        });
        delivered = routerTerminal.pay({
            projectId: _DEST_PROJECT_ID,
            token: address(jbToken),
            amount: _AMOUNT,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        vm.stopPrank();
    }
}
