// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

/// @notice Minimal ERC20 mock for balance-delta accounting in _acceptFundsFor.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice _cashOutLoop should revert with CashOutLoopLimit when circular token
/// dependencies cause more than 20 iterations, instead of consuming all gas.
contract CashOutLoopLimitTest is Test {
    JBRouterTerminal routerTerminal;

    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));
    IPermit2 permit2 = IPermit2(makeAddr("permit2"));
    IWETH9 weth = IWETH9(makeAddr("weth"));
    IUniswapV3Factory factory = IUniswapV3Factory(makeAddr("factory"));
    address owner = makeAddr("owner");

    address payer = makeAddr("payer");
    address mockTerminal = makeAddr("mockTerminal");

    // Two JB project tokens that form a cycle: tokenA -> tokenB -> tokenA -> ...
    MockToken tokenA;
    MockToken tokenB;

    uint256 constant DEST_PROJECT_ID = 99;
    uint256 constant PROJECT_A_ID = 10;
    uint256 constant PROJECT_B_ID = 20;

    function setUp() public {
        vm.etch(address(directory), hex"00");
        vm.etch(address(permissions), hex"00");
        vm.etch(address(projects), hex"00");
        vm.etch(address(tokens), hex"00");
        vm.etch(address(permit2), hex"00");
        vm.etch(address(weth), hex"00");
        vm.etch(address(factory), hex"00");
        vm.etch(mockTerminal, hex"00");

        routerTerminal = new JBRouterTerminal(
            directory,
            permissions,
            projects,
            tokens,
            permit2,
            owner,
            weth,
            factory,
            IPoolManager(address(0)), // no V4
            address(0)
        );

        tokenA = new MockToken();
        tokenB = new MockToken();

        // tokenA is the JB project token for PROJECT_A_ID.
        vm.mockCall(
            address(tokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(tokenA)))),
            abi.encode(PROJECT_A_ID)
        );

        // tokenB is the JB project token for PROJECT_B_ID.
        vm.mockCall(
            address(tokens),
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(tokenB)))),
            abi.encode(PROJECT_B_ID)
        );

        // Destination project does not accept tokenA or tokenB directly.
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(tokenA))),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(tokenB))),
            abi.encode(address(0))
        );

        // --- Circular cashout path setup ---
        // Project A's terminal cashes out to tokenB.
        _setupCashOutTerminal(PROJECT_A_ID, address(tokenB));
        // Project B's terminal cashes out to tokenA.
        _setupCashOutTerminal(PROJECT_B_ID, address(tokenA));
    }

    function _setupCashOutTerminal(uint256 projectId, address reclaimToken) internal {
        address terminal = makeAddr(string(abi.encodePacked("terminal", projectId)));
        vm.etch(terminal, hex"00");

        // Register as the project's terminal.
        IJBTerminal[] memory terminalList = new IJBTerminal[](1);
        terminalList[0] = IJBTerminal(terminal);
        vm.mockCall(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (projectId)), abi.encode(terminalList));

        // Supports IJBCashOutTerminal.
        vm.mockCall(
            terminal,
            abi.encodeCall(IERC165.supportsInterface, (type(IJBCashOutTerminal).interfaceId)),
            abi.encode(true)
        );

        // Accounting context: terminal accepts the reclaim token.
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        contexts[0] = JBAccountingContext({token: reclaimToken, decimals: 18, currency: uint32(uint160(reclaimToken))});
        vm.mockCall(terminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(contexts));

        // cashOutTokensOf returns 1e18 each time (simulating a successful cashout).
        vm.mockCall(
            terminal, abi.encodeWithSelector(IJBCashOutTerminal.cashOutTokensOf.selector), abi.encode(uint256(1e18))
        );
    }

    /// @notice A circular cashout chain (A -> B -> A -> ...) must revert with CashOutLoopLimit, not OOG.
    function test_cashOutLoop_revertsOnCircularDependency() public {
        uint256 amount = 10e18;

        // Mint tokenA to payer and approve.
        tokenA.mint(payer, amount);
        vm.prank(payer);
        tokenA.approve(address(routerTerminal), amount);

        // Expect the specific CashOutLoopLimit revert.
        vm.expectRevert(abi.encodeWithSelector(JBRouterTerminal.JBRouterTerminal_CashOutLoopLimit.selector));

        vm.prank(payer);
        routerTerminal.pay(DEST_PROJECT_ID, address(tokenA), amount, payer, 0, "", "");
    }

    /// @notice A non-circular path within the iteration cap should succeed normally.
    function test_cashOutLoop_succeedsWithinLimit() public {
        uint256 amount = 10e18;
        address baseToken = makeAddr("baseToken");
        vm.etch(baseToken, hex"00");

        // Override: tokenB is NOT a JB token (breaks the cycle).
        vm.mockCall(
            address(tokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(tokenB)))), abi.encode(uint256(0))
        );

        // Dest project accepts baseToken via a terminal (so the router can swap tokenB -> baseToken).
        // For simplicity: dest accepts tokenB directly.
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(tokenB))),
            abi.encode(mockTerminal)
        );

        // Mock dest terminal pay.
        vm.mockCall(mockTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(5)));

        // Mint and approve tokenA.
        tokenA.mint(payer, amount);
        vm.prank(payer);
        tokenA.approve(address(routerTerminal), amount);

        vm.prank(payer);
        uint256 result = routerTerminal.pay(DEST_PROJECT_ID, address(tokenA), amount, payer, 0, "", "");
        assertEq(result, 5);
    }
}
