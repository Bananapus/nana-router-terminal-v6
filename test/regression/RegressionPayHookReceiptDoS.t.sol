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

contract RegressionERC20 is ERC20 {
    constructor() ERC20("Regression Regression Token", "CNT") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract HookForwardingTerminal is IJBTerminal {
    IERC20 public immutable TOKEN;
    address public immutable HOOK;
    uint256 public immutable HOOK_AMOUNT;

    constructor(IERC20 token_, address hook_, uint256 hookAmount_) {
        TOKEN = token_;
        HOOK = hook_;
        HOOK_AMOUNT = hookAmount_;
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
            uint256 terminalTokenAmount,
            JBPayHookSpecification[] memory specs
        )
    {
        specs = new JBPayHookSpecification[](1);
        specs[0].amount = HOOK_AMOUNT;
        beneficiaryTokenCount = 1;
        terminalTokenAmount = HOOK_AMOUNT;
        ruleset.id = 1;
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external {}

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}

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
        require(TOKEN.transferFrom(msg.sender, address(this), amount));
        require(TOKEN.transfer(HOOK, HOOK_AMOUNT));
        return 1;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract RegressionPayHookReceiptDoSTest is Test {
    /// @notice After fix: pay() no longer enforces _enforceStandardTerminalReceipt, so a terminal
    ///         that forwards tokens to a pay hook should succeed rather than revert.
    function test_routerAllowsErc20TerminalThatForwardsToPayHook() external {
        uint256 projectId = 1;
        address payer = address(0xA11CE);
        address beneficiary = address(0xB0B);
        address hook = address(0xCAFE);
        uint256 amount = 100 ether;
        uint256 hookAmount = 40 ether;

        RegressionERC20 token = new RegressionERC20();
        HookForwardingTerminal terminal = new HookForwardingTerminal(token, hook, hookAmount);

        address directory = address(0xD1);
        address tokens = address(0x70);
        vm.etch(directory, hex"00");
        vm.etch(tokens, hex"00");

        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(address(terminal));

        vm.mockCall(directory, abi.encodeCall(IJBDirectory.terminalsOf, (projectId)), abi.encode(terminals));
        vm.mockCall(
            directory,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, address(token))),
            abi.encode(address(terminal))
        );
        vm.mockCall(tokens, abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(token)))), abi.encode(uint256(0)));

        JBRouterTerminal router = new JBRouterTerminal({
            directory: IJBDirectory(directory),
            tokens: IJBTokens(tokens),
            permit2: IPermit2(address(0x22)),
            buybackHook: address(0),
            trustedForwarder: address(0),
            deployer: address(this)
        });
        router.setChainSpecificConstants({
            newWrappedNativeToken: IWETH9(address(0x33)),
            newFactory: IUniswapV3Factory(address(0x44)),
            newPoolManager: IPoolManager(address(0)),
            newUniv4Hook: address(0)
        });

        token.mint(payer, amount);

        vm.startPrank(payer);
        token.approve(address(router), amount);
        // fix: pay() no longer reverts when hooks consume tokens — should succeed.
        uint256 beneficiaryTokenCount = router.pay({
            projectId: projectId,
            token: address(token),
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        vm.stopPrank();

        assertEq(beneficiaryTokenCount, 1, "beneficiary should receive 1 token from mock terminal");
    }
}
