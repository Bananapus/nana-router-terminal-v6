// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
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

/// @notice Cash-out terminal that actually transfers the reclaim token to the beneficiary,
/// so the router's balance-delta accounting sees a real balance increase.
contract RealCashOutTerminal {
    MockToken public immutable RECLAIM_TOKEN;
    uint256 public immutable RECLAIM_AMOUNT;

    constructor(MockToken reclaimToken_, uint256 reclaimAmount_) {
        RECLAIM_TOKEN = reclaimToken_;
        RECLAIM_AMOUNT = reclaimAmount_;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBCashOutTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function accountingContextsOf(uint256) external view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        contexts[0] = JBAccountingContext({
            token: address(RECLAIM_TOKEN), decimals: 18, currency: uint32(uint160(address(RECLAIM_TOKEN)))
        });
    }

    function cashOutTokensOf(
        address,
        uint256,
        uint256,
        address,
        uint256,
        address payable beneficiary,
        bytes calldata
    )
        external
        returns (uint256)
    {
        require(RECLAIM_TOKEN.transfer(beneficiary, RECLAIM_AMOUNT), "reclaim transfer failed");
        return RECLAIM_AMOUNT;
    }
}

/// @notice Destination terminal that actually pulls tokens from the sender via transferFrom,
/// so the router's receipt enforcement (_enforceStandardTerminalReceipt) sees the expected balance.
contract RealDestTerminal {
    uint256 public lastReturnValue;

    constructor(uint256 returnValue_) {
        lastReturnValue = returnValue_;
    }

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
        returns (uint256)
    {
        require(MockToken(token).transferFrom(msg.sender, address(this), amount), "pay transfer failed");
        return lastReturnValue;
    }
}

/// @notice _cashOutLoop should revert with CashOutLoopLimit when circular token
/// dependencies cause more than 20 iterations, instead of consuming all gas.
contract CashOutLoopLimitTest is Test {
    JBRouterTerminal routerTerminal;

    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));

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
        vm.etch(address(tokens), hex"00");
        vm.etch(address(permit2), hex"00");
        vm.etch(address(weth), hex"00");
        vm.etch(address(factory), hex"00");
        vm.etch(mockTerminal, hex"00");

        routerTerminal = new JBRouterTerminal(
            directory,
            tokens,
            permit2,
            weth,
            factory,
            IPoolManager(address(0)), // no V4
            address(0),
            address(0),
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
        RealCashOutTerminal terminal = new RealCashOutTerminal(MockToken(reclaimToken), 1e18);
        MockToken(reclaimToken).mint(address(terminal), 25e18);

        // Register as the project's terminal.
        IJBTerminal[] memory terminalList = new IJBTerminal[](1);
        terminalList[0] = IJBTerminal(address(terminal));
        vm.mockCall(address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (projectId)), abi.encode(terminalList));
    }

    /// @notice A circular cashout chain (A -> B -> A -> ...) must revert with CashOutLoopLimit, not OOG.
    function test_cashOutLoop_revertsOnCircularDependency() public {
        uint256 amount = 10e18;

        // Mint tokenA to payer and approve.
        tokenA.mint(payer, amount);
        vm.prank(payer);
        tokenA.approve(address(routerTerminal), amount);

        // Expect the specific CashOutLoopLimit revert.
        vm.expectRevert(abi.encodeWithSelector(JBRouterTerminal.JBRouterTerminal_CashOutLoopLimit.selector, 20));

        vm.prank(payer);
        routerTerminal.pay(DEST_PROJECT_ID, address(tokenA), amount, payer, 0, "", "");
    }

    /// @notice A non-circular path within the iteration cap should succeed normally.
    function test_cashOutLoop_succeedsWithinLimit() public {
        uint256 amount = 10e18;

        // Override: tokenB is NOT a JB token (breaks the cycle).
        vm.mockCall(
            address(tokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(tokenB)))), abi.encode(uint256(0))
        );

        // Replace project A's mocked terminal with a real contract that transfers tokenB to
        // the router so the balance-delta accounting sees the cashout proceeds.
        RealCashOutTerminal realTerminalA = new RealCashOutTerminal(tokenB, 1e18);
        tokenB.mint(address(realTerminalA), 1e18);

        {
            IJBTerminal[] memory terminalList = new IJBTerminal[](1);
            terminalList[0] = IJBTerminal(address(realTerminalA));
            vm.mockCall(
                address(directory), abi.encodeCall(IJBDirectory.terminalsOf, (PROJECT_A_ID)), abi.encode(terminalList)
            );
        }

        // Use a real destination terminal that pulls tokens via transferFrom so the router's
        // receipt enforcement sees the expected balance increase.
        RealDestTerminal realDestTerminal = new RealDestTerminal(5);

        // Dest project accepts tokenB directly via the real destination terminal.
        vm.mockCall(
            address(directory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (DEST_PROJECT_ID, address(tokenB))),
            abi.encode(address(realDestTerminal))
        );

        // Mint and approve tokenA.
        tokenA.mint(payer, amount);
        vm.prank(payer);
        tokenA.approve(address(routerTerminal), amount);

        vm.prank(payer);
        uint256 result = routerTerminal.pay(DEST_PROJECT_ID, address(tokenA), amount, payer, 0, "", "");
        assertEq(result, 5);
    }
}
