// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

/// @notice A fee-on-transfer ERC-20 that burns 1% of every transfer (simulating a lossy token).
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee On Transfer", "FOT") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount / 100; // 1% fee
        _burn(msg.sender, fee);
        return super.transfer(to, amount - fee);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount / 100; // 1% fee
        _burn(from, fee);
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount - fee);
        return true;
    }
}

/// @notice A minimal terminal that pulls ERC-20 via transferFrom in both pay() and addToBalanceOf().
contract PullingTerminal is IJBTerminal {
    IERC20 public immutable TOKEN;

    constructor(IERC20 token_) {
        TOKEN = token_;
    }

    function accountingContextForTokenOf(uint256, address token_) external pure returns (JBAccountingContext memory) {
        return JBAccountingContext({token: token_, decimals: 18, currency: 0});
    }

    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: address(TOKEN), decimals: 18, currency: 0});
    }

    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external {}

    function addToBalanceOf(uint256, address, uint256 amount, bool, string calldata, bytes calldata) external payable {
        // Pull tokens from the router.
        require(TOKEN.transferFrom(msg.sender, address(this), amount));
    }

    function previewPayFor(
        uint256,
        address,
        uint256,
        address,
        bytes calldata
    )
        external
        pure
        returns (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedTokenCount,
            JBPayHookSpecification[] memory hookSpecifications
        )
    {
        beneficiaryTokenCount = 1;
        reservedTokenCount = 0;
        hookSpecifications = new JBPayHookSpecification[](0);
        ruleset.id = 1;
    }

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure returns (uint256) {
        return 0;
    }

    function pay(
        uint256,
        address,
        uint256 amount,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        // Pull tokens from the router.
        require(TOKEN.transferFrom(msg.sender, address(this), amount));
        return 1;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice regression fix: `addToBalanceOf` still enforces receipt check for lossy ERC-20s.
contract LossyReceiptRegressionTest is Test {
    uint256 constant PROJECT_ID = 1;
    uint256 constant AMOUNT = 100 ether;

    FeeOnTransferToken token;
    PullingTerminal terminal;
    JBRouterTerminal router;
    address payer = address(0xA11CE);

    function setUp() public {
        token = new FeeOnTransferToken();
        terminal = new PullingTerminal(IERC20(address(token)));

        address directory = address(0xD1);
        address tokens = address(0x70);
        vm.etch(directory, hex"00");
        vm.etch(tokens, hex"00");

        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(address(terminal));

        vm.mockCall(directory, abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_ID)), abi.encode(terminals));
        vm.mockCall(
            directory,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(token))),
            abi.encode(address(terminal))
        );
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(token)))), abi.encode(uint256(0)));

        router = new JBRouterTerminal({
            directory: IJBDirectory(directory),
            tokens: IJBTokens(tokens),
            permit2: IPermit2(address(0x22)),
            buybackHook: address(0),
            trustedForwarder: address(0),
            deployer: address(this)
        });
        router.setChainSpecificConstants({
            wrappedNativeToken: IWETH9(address(0x33)),
            factory: IUniswapV3Factory(address(0x44)),
            poolManager: IPoolManager(address(0)),
            univ4Hook: address(0)
        });

        token.mint(payer, AMOUNT * 10);
    }

    /// @notice addToBalanceOf must still revert for fee-on-transfer tokens (receipt enforcement kept).
    function test_addToBalanceOf_revertsForLossyERC20() external {
        vm.startPrank(payer);
        token.approve(address(router), AMOUNT);

        uint256 expectedAmount = AMOUNT - (AMOUNT / 100);
        uint256 actualAmount = expectedAmount - (expectedAmount / 100);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBRouterTerminal.JBRouterTerminal_NonStandardTerminalToken.selector,
                address(terminal),
                address(token),
                expectedAmount,
                actualAmount
            )
        );
        router.addToBalanceOf({
            projectId: PROJECT_ID,
            token: address(token),
            amount: AMOUNT,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: ""
        });
        vm.stopPrank();
    }

    /// @notice pay() must NOT revert for lossy tokens after fix (receipt enforcement removed from pay).
    function test_pay_doesNotRevertForLossyERC20() external {
        vm.startPrank(payer);
        token.approve(address(router), AMOUNT);

        // Should succeed — pay() no longer enforces the receipt check.
        uint256 beneficiaryTokenCount = router.pay({
            projectId: PROJECT_ID,
            token: address(token),
            amount: AMOUNT,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        vm.stopPrank();

        assertEq(beneficiaryTokenCount, 1, "mock terminal returns 1 token");
    }
}
