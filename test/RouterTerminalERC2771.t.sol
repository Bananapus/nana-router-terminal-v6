// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../src/JBRouterTerminal.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Minimal ERC-20 mock that tracks balances and records transfer-from addresses.
// ──────────────────────────────────────────────────────────────────────────────
contract ERC2771MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice The last `from` address passed to transferFrom.
    address public lastTransferFromSender;

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
        lastTransferFromSender = from;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Trusted forwarder that relays calls per ERC-2771 spec.
// Appends the original sender's address (20 bytes) to the calldata.
// ──────────────────────────────────────────────────────────────────────────────
contract MockTrustedForwarder {
    /// @notice Forward a call to the target, appending `originalSender` per ERC-2771.
    function forward(
        address target,
        bytes calldata data,
        address originalSender
    )
        external
        payable
        returns (bytes memory)
    {
        bytes memory callData = abi.encodePacked(data, originalSender);
        (bool success, bytes memory result) = target.call{value: msg.value}(callData);
        require(success, "MockTrustedForwarder: forwarded call reverted");
        return result;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Test: ERC-2771 meta-transaction support in JBRouterTerminal
// ══════════════════════════════════════════════════════════════════════════════
contract RouterTerminalERC2771Test is Test {
    JBRouterTerminal routerTerminal;
    MockTrustedForwarder forwarder;
    ERC2771MockERC20 token;

    // Mocked dependencies.
    IJBDirectory mockDirectory;
    IJBPermissions mockPermissions;
    IJBProjects mockProjects;
    IJBTokens mockTokens;
    IPermit2 mockPermit2;
    IUniswapV3Factory mockFactory;
    IPoolManager mockPoolManager;

    address terminalOwner;

    function setUp() public {
        forwarder = new MockTrustedForwarder();
        token = new ERC2771MockERC20();

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
        mockFactory = IUniswapV3Factory(makeAddr("mockFactory"));
        vm.etch(address(mockFactory), hex"00");
        mockPoolManager = IPoolManager(makeAddr("mockPoolManager"));
        vm.etch(address(mockPoolManager), hex"00");

        terminalOwner = makeAddr("terminalOwner");

        // Deploy with a REAL trusted forwarder (not address(0)).
        routerTerminal = new JBRouterTerminal(
            mockDirectory,
            mockPermissions,
            mockProjects,
            mockTokens,
            mockPermit2,
            terminalOwner,
            IWETH9(makeAddr("mockWeth")),
            mockFactory,
            mockPoolManager,
            address(forwarder)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 1: pay() through trusted forwarder resolves _msgSender() to the
    // appended address, NOT msg.sender (the forwarder).
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When the trusted forwarder relays a pay() call, the router should pull tokens from
    /// the real caller (appended to calldata), not from the forwarder contract.
    function test_pay_viaTrustedForwarder_resolvesRealSender() public {
        uint256 projectId = 1;
        address realCaller = makeAddr("realCaller");
        uint256 amount = 1000;
        address mockTerminal = makeAddr("destTerminal");
        vm.etch(mockTerminal, hex"00");

        // Not a JB token.
        vm.mockCall(address(mockTokens), abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));

        // Project accepts the token directly.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, address(token))),
            abi.encode(mockTerminal)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: address(token), decimals: 18, currency: uint32(uint160(address(token)))});
        vm.mockCall(mockTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(contexts));

        // Mint tokens to the REAL caller and have them approve the router.
        token.mint(realCaller, amount);
        vm.prank(realCaller);
        token.approve(address(routerTerminal), amount);

        // Mock safeIncreaseAllowance: the router approves the dest terminal.
        vm.mockCall(address(token), abi.encodeCall(IERC20.approve, (mockTerminal, amount)), abi.encode(true));

        // Mock dest terminal pay.
        vm.mockCall(mockTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(42)));

        // Encode the pay() calldata (without the appended sender — the forwarder adds it).
        bytes memory payCalldata =
            abi.encodeCall(IJBTerminal.pay, (projectId, address(token), amount, realCaller, 0, "", ""));

        // Call through the forwarder, which appends `realCaller` to the calldata.
        bytes memory result =
            forwarder.forward({target: address(routerTerminal), data: payCalldata, originalSender: realCaller});

        // Verify: the router pulled tokens from `realCaller`, not from the forwarder.
        assertEq(token.lastTransferFromSender(), realCaller, "Router should pull tokens from the real caller");
        assertEq(token.balanceOf(realCaller), 0, "Real caller should have zero tokens remaining");

        // Verify: pay returned the expected value.
        uint256 returnValue = abi.decode(result, (uint256));
        assertEq(returnValue, 42, "pay() return value mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 2: Direct call (not through forwarder) uses msg.sender as usual.
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When pay() is called directly (not through the forwarder), _msgSender() should
    /// return msg.sender as usual.
    function test_pay_directCall_usesMsgSender() public {
        uint256 projectId = 1;
        address directCaller = makeAddr("directCaller");
        uint256 amount = 500;
        address mockTerminal = makeAddr("destTerminal");
        vm.etch(mockTerminal, hex"00");

        // Not a JB token.
        vm.mockCall(address(mockTokens), abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));

        // Project accepts the token directly.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, address(token))),
            abi.encode(mockTerminal)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: address(token), decimals: 18, currency: uint32(uint160(address(token)))});
        vm.mockCall(mockTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(contexts));

        // Mint tokens to the direct caller and have them approve the router.
        token.mint(directCaller, amount);
        vm.prank(directCaller);
        token.approve(address(routerTerminal), amount);

        // Mock safeIncreaseAllowance.
        vm.mockCall(address(token), abi.encodeCall(IERC20.approve, (mockTerminal, amount)), abi.encode(true));

        // Mock dest terminal pay.
        vm.mockCall(mockTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(99)));

        // Call directly (no forwarder).
        vm.prank(directCaller);
        uint256 result = routerTerminal.pay(projectId, address(token), amount, directCaller, 0, "", "");

        // Verify: tokens pulled from directCaller (msg.sender).
        assertEq(token.lastTransferFromSender(), directCaller, "Router should pull tokens from msg.sender");
        assertEq(token.balanceOf(directCaller), 0, "Direct caller should have zero tokens remaining");
        assertEq(result, 99, "pay() return value mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 3: ETH payment through forwarder resolves correctly.
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Native ETH payments through the forwarder should work correctly.
    /// The _msgSender() resolution doesn't affect ETH flow (msg.value is used directly),
    /// but the forwarder must relay the value. The call should succeed and the dest terminal's
    /// pay should be invoked with the correct ETH amount.
    function test_pay_ethViaTrustedForwarder() public {
        uint256 projectId = 1;
        address realCaller = makeAddr("realCaller");
        uint256 amount = 1 ether;
        address mockTerminal = makeAddr("destTerminal");
        vm.etch(mockTerminal, hex"00");

        // Project accepts NATIVE_TOKEN.
        vm.mockCall(
            address(mockDirectory),
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (projectId, JBConstants.NATIVE_TOKEN)),
            abi.encode(mockTerminal)
        );

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(0)});
        vm.mockCall(mockTerminal, abi.encodeCall(IJBTerminal.accountingContextsOf, (projectId)), abi.encode(contexts));

        // Mock dest terminal pay.
        vm.mockCall(mockTerminal, abi.encodeWithSelector(IJBTerminal.pay.selector), abi.encode(uint256(10)));

        // Fund the forwarder with ETH.
        vm.deal(address(forwarder), amount);

        // Encode the pay() calldata.
        bytes memory payCalldata =
            abi.encodeCall(IJBTerminal.pay, (projectId, JBConstants.NATIVE_TOKEN, amount, realCaller, 0, "", ""));

        // Forward with ETH value.
        bytes memory result = forwarder.forward{value: amount}({
            target: address(routerTerminal), data: payCalldata, originalSender: realCaller
        });

        uint256 returnValue = abi.decode(result, (uint256));
        assertEq(returnValue, 10, "pay() return value mismatch");
    }
}
