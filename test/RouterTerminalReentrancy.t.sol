// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Mock: Minimal ERC20 that tracks balances.
// ──────────────────────────────────────────────────────────────────────────────

contract ReentrancyMockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MaliciousTerminal: re-enters router.pay() during cashOutTokensOf callback.
// ──────────────────────────────────────────────────────────────────────────────

contract MaliciousReentrantTerminal {
    JBRouterTerminal public router;
    bool public shouldReenter;
    bool public reentered;
    bool public reentryReverted;

    constructor(JBRouterTerminal _router) {
        router = _router;
    }

    function setShouldReenter(bool val) external {
        shouldReenter = val;
    }

    /// @notice Mimics IJBCashOutTerminal.cashOutTokensOf. Re-enters router.pay() if armed.
    function cashOutTokensOf(
        address, /* holder */
        uint256, /* projectId */
        uint256, /* cashOutCount */
        address, /* tokenToReclaim */
        uint256, /* minTokensReclaimed */
        address payable, /* beneficiary */
        bytes calldata /* metadata */
    )
        external
        returns (uint256)
    {
        if (shouldReenter) {
            shouldReenter = false;
            reentered = true;
            // Attempt to re-enter router.pay().
            try router.pay{value: 0}({
                projectId: 999,
                token: address(0x1234),
                amount: 0,
                beneficiary: address(this),
                minReturnedTokens: 0,
                memo: "reentrant",
                metadata: ""
            }) {}
            catch {
                reentryReverted = true;
            }
        }
        return 1e18;
    }

    /// @notice Mimics IERC165.supportsInterface — reports supporting IJBCashOutTerminal.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBCashOutTerminal).interfaceId || interfaceId == type(IJBTerminal).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Mimics IJBTerminal.accountingContextsOf for the source project.
    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
    }

    /// @notice Mimics IJBTerminal.pay for the destination project.
    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        return 42;
    }

    receive() external payable {}
}

// ──────────────────────────────────────────────────────────────────────────────
// MaliciousAddToBalanceTerminal: re-enters router.addToBalanceOf() during
// cashOutTokensOf callback.
// ──────────────────────────────────────────────────────────────────────────────

contract MaliciousAddToBalanceTerminal {
    JBRouterTerminal public router;
    bool public shouldReenter;
    bool public reentered;
    bool public reentryReverted;

    constructor(JBRouterTerminal _router) {
        router = _router;
    }

    function setShouldReenter(bool val) external {
        shouldReenter = val;
    }

    /// @notice Mimics IJBCashOutTerminal.cashOutTokensOf. Re-enters router.addToBalanceOf() if armed.
    function cashOutTokensOf(
        address, /* holder */
        uint256, /* projectId */
        uint256, /* cashOutCount */
        address, /* tokenToReclaim */
        uint256, /* minTokensReclaimed */
        address payable, /* beneficiary */
        bytes calldata /* metadata */
    )
        external
        returns (uint256)
    {
        if (shouldReenter) {
            shouldReenter = false;
            reentered = true;
            // Attempt to re-enter router.addToBalanceOf().
            try router.addToBalanceOf{value: 0}({
                projectId: 999,
                token: address(0x1234),
                amount: 0,
                shouldReturnHeldFees: false,
                memo: "reentrant",
                metadata: ""
            }) {}
            catch {
                reentryReverted = true;
            }
        }
        return 1e18;
    }

    /// @notice Mimics IERC165.supportsInterface — reports supporting IJBCashOutTerminal.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBCashOutTerminal).interfaceId || interfaceId == type(IJBTerminal).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Mimics IJBTerminal.accountingContextsOf for the source project.
    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
    }

    /// @notice Mimics IJBTerminal.pay for the destination project.
    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        return 42;
    }

    /// @notice Mimics IJBTerminal.addToBalanceOf for the destination project.
    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable {}

    receive() external payable {}
}

// ══════════════════════════════════════════════════════════════════════════════
// Test Contract: Reentrancy scenarios for JBRouterTerminal
// ══════════════════════════════════════════════════════════════════════════════

contract RouterTerminalReentrancyTest is Test {
    JBRouterTerminal routerTerminal;

    // Mocked dependencies.
    IJBDirectory mockDirectory;
    IJBPermissions mockPermissions;
    IJBProjects mockProjects;
    IJBTokens mockTokens;
    IPermit2 mockPermit2;
    IWETH9 mockWeth;
    IUniswapV3Factory mockFactory;
    IPoolManager mockPoolManager;

    address terminalOwner;

    function setUp() public {
        mockDirectory = IJBDirectory(makeAddr("mockDirectory"));
        vm.etch(address(mockDirectory), hex"00");
        mockPermissions = IJBPermissions(makeAddr("mockPermissions"));
        vm.etch(address(mockPermissions), hex"00");
        mockProjects = IJBProjects(makeAddr("mockProjects"));
        vm.etch(address(mockProjects), hex"00");
        mockTokens = IJBTokens(makeAddr("mockTokens"));
        vm.etch(address(mockTokens), hex"00");
        mockPermit2 = IPermit2(makeAddr("mockPermit2"));
        vm.etch(address(mockPermit2), hex"00");
        mockWeth = IWETH9(makeAddr("mockWeth"));
        vm.etch(address(mockWeth), hex"00");
        mockFactory = IUniswapV3Factory(makeAddr("mockFactory"));
        vm.etch(address(mockFactory), hex"00");
        mockPoolManager = IPoolManager(makeAddr("mockPoolManager"));
        vm.etch(address(mockPoolManager), hex"00");

        terminalOwner = makeAddr("terminalOwner");

        routerTerminal = new JBRouterTerminal(
            mockDirectory,
            mockPermissions,
            mockProjects,
            mockTokens,
            mockPermit2,
            terminalOwner,
            mockWeth,
            mockFactory,
            mockPoolManager,
            address(0)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 1: Malicious terminal re-enters router.pay() during cashOutTokensOf
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice A malicious terminal tries to re-enter router.pay() during a cashout callback.
    /// The router should either revert the reentry or remain in a consistent state.
    /// The mock cashOutTokensOf returns 1e18. The router forwards that ETH to the dest terminal.
    function test_reentrancy_maliciousTerminalReentersPay() public {
        MaliciousReentrantTerminal malicious = new MaliciousReentrantTerminal(routerTerminal);

        ReentrancyMockERC20 jbTokenMock = new ReentrancyMockERC20();
        address jbToken = address(jbTokenMock);
        address payer = makeAddr("payer");
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;

        // The jbToken is a JB project token for sourceProjectId.
        vm.mockCall(
            address(mockTokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(jbToken))), abi.encode(sourceProjectId)
        );

        // Dest project (1) does NOT accept jbToken directly.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, jbToken)),
            abi.encode(address(0))
        );

        // Dest project (1) accepts NATIVE_TOKEN at the malicious terminal (which doubles as dest terminal).
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(malicious))
        );

        // Source project's terminal list: the malicious terminal (for cashout).
        {
            IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
            sourceTerminals[0] = IJBTerminal(address(malicious));
            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
                abi.encode(sourceTerminals)
            );
        }

        // Arm the malicious terminal to re-enter on cashout.
        malicious.setShouldReenter(true);

        // Mint jbToken to payer and approve the router.
        jbTokenMock.mint(payer, 100e18);
        vm.prank(payer);
        jbTokenMock.approve(address(routerTerminal), 100e18);

        // The mock cashOutTokensOf returns 1e18 as the reclaimed amount. In production, the cashout
        // terminal would actually transfer ETH. Fund the router with exactly what the mock returns.
        vm.deal(address(routerTerminal), 1e18);

        // Record the router's ETH balance before.
        uint256 routerEthBefore = address(routerTerminal).balance;

        // Execute: the cashout callback will try to re-enter router.pay().
        vm.prank(payer);
        uint256 result = routerTerminal.pay(destProjectId, jbToken, 100e18, payer, 0, "", "");

        // The outer pay call should complete and return the pay result from the malicious terminal.
        assertEq(result, 42, "outer pay should complete successfully");

        // The malicious terminal's reentry was attempted.
        assertTrue(malicious.reentered(), "malicious terminal should have attempted reentry");

        // The reentry should have been reverted by the reentrancy guard.
        assertTrue(malicious.reentryReverted(), "reentry should have been reverted by reentrancy guard");

        // The router forwarded all the reclaimed ETH to the destination terminal.
        // In a mock scenario, the router should have sent exactly what the cashout returned.
        assertEq(
            address(routerTerminal).balance, routerEthBefore - 1e18, "router should have forwarded all reclaimed ETH"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 2: Malicious terminal re-enters router.addToBalanceOf() during cashout
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice A malicious terminal tries to re-enter router.addToBalanceOf() during a cashout callback.
    /// The router should either revert the reentry or remain in a consistent state.
    /// The mock cashOutTokensOf returns 1e18. The router forwards that ETH to the dest terminal.
    function test_reentrancy_maliciousTerminalReentersAddToBalance() public {
        MaliciousAddToBalanceTerminal malicious = new MaliciousAddToBalanceTerminal(routerTerminal);

        ReentrancyMockERC20 jbTokenMock = new ReentrancyMockERC20();
        address jbToken = address(jbTokenMock);
        address payer = makeAddr("payer");
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;

        // The jbToken is a JB project token for sourceProjectId.
        vm.mockCall(
            address(mockTokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(jbToken))), abi.encode(sourceProjectId)
        );

        // Dest project (1) does NOT accept jbToken directly.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, jbToken)),
            abi.encode(address(0))
        );

        // Dest project (1) accepts NATIVE_TOKEN at the malicious terminal.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(malicious))
        );

        // Source project's terminal list: the malicious terminal (for cashout).
        {
            IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
            sourceTerminals[0] = IJBTerminal(address(malicious));
            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
                abi.encode(sourceTerminals)
            );
        }

        // Arm the malicious terminal to re-enter on cashout.
        malicious.setShouldReenter(true);

        // Mint jbToken to payer and approve the router.
        jbTokenMock.mint(payer, 100e18);
        vm.prank(payer);
        jbTokenMock.approve(address(routerTerminal), 100e18);

        // The mock cashOutTokensOf returns 1e18. Fund router with exactly that amount.
        vm.deal(address(routerTerminal), 1e18);
        uint256 routerEthBefore = address(routerTerminal).balance;

        // Execute: the cashout callback will try to re-enter router.addToBalanceOf().
        vm.prank(payer);
        routerTerminal.addToBalanceOf(destProjectId, jbToken, 100e18, false, "", "");

        // The malicious terminal's reentry was attempted.
        assertTrue(malicious.reentered(), "malicious terminal should have attempted reentry");

        // The reentry should have been reverted by the reentrancy guard.
        assertTrue(malicious.reentryReverted(), "reentry should have been reverted by reentrancy guard");

        // Router forwarded all the reclaimed ETH to the destination terminal.
        assertEq(
            address(routerTerminal).balance, routerEthBefore - 1e18, "router should have forwarded all reclaimed ETH"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 3: Re-enter with ETH value during cashout (native token path)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Verifies the normal (non-reentrant) cashout path works correctly and the router
    /// forwards exactly the reclaimed ETH amount to the destination terminal.
    function test_reentrancy_normalPathForwardsCorrectETH() public {
        MaliciousReentrantTerminal malicious = new MaliciousReentrantTerminal(routerTerminal);

        ReentrancyMockERC20 jbTokenMock = new ReentrancyMockERC20();
        address jbToken = address(jbTokenMock);
        address payer = makeAddr("payer");
        uint256 destProjectId = 1;
        uint256 sourceProjectId = 2;

        // The jbToken is a JB project token for sourceProjectId.
        vm.mockCall(
            address(mockTokens), abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(jbToken))), abi.encode(sourceProjectId)
        );

        // Dest project does NOT accept jbToken directly.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, jbToken)),
            abi.encode(address(0))
        );

        // Dest project accepts NATIVE_TOKEN at the malicious terminal.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (destProjectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(malicious))
        );

        // Source project's terminal list.
        {
            IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
            sourceTerminals[0] = IJBTerminal(address(malicious));
            vm.mockCall(
                address(mockDirectory),
                abi.encodeCall(IJBDirectory.terminalsOf, (sourceProjectId)),
                abi.encode(sourceTerminals)
            );
        }

        // Do NOT arm reentry — test the normal non-reentrant path
        // and verify ETH balance consistency.
        malicious.setShouldReenter(false);

        // Mint jbToken to payer and approve the router.
        jbTokenMock.mint(payer, 50e18);
        vm.prank(payer);
        jbTokenMock.approve(address(routerTerminal), 50e18);

        // The mock cashOutTokensOf returns 1e18. Fund router with exactly that.
        vm.deal(address(routerTerminal), 1e18);

        // Execute normally.
        vm.prank(payer);
        uint256 result = routerTerminal.pay(destProjectId, jbToken, 50e18, payer, 0, "", "");

        assertEq(result, 42, "pay should return malicious terminal's result");
        // Router forwarded exactly 1e18 (the cashout return) to dest terminal.
        assertEq(address(routerTerminal).balance, 0, "router should have no leftover ETH");
    }
}
