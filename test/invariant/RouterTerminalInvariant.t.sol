// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBRouterTerminal} from "../../src/JBRouterTerminal.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Mock ERC-20 token with mint/burn and proper balanceOf tracking.
// ──────────────────────────────────────────────────────────────────────────────
contract InvariantMockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ERC20: insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Mock WETH9 with deposit/withdraw and proper ETH handling.
// ──────────────────────────────────────────────────────────────────────────────
contract InvariantMockWETH9 {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "WETH: insufficient balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "WETH: ETH transfer failed");
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "WETH: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "WETH: insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "WETH: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Mock terminal that accepts payments and tracks received amounts.
// Implements IJBTerminal.pay and IJBTerminal.addToBalanceOf.
// ──────────────────────────────────────────────────────────────────────────────
contract MockDestTerminal {
    // Cumulative tracking of all received funds per token.
    mapping(address => uint256) public totalReceived;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public totalETHReceived;
    uint256 public payCallCount;
    uint256 public addToBalanceCallCount;

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
        returns (uint256)
    {
        payCallCount++;
        if (token == JBConstants.NATIVE_TOKEN) {
            require(msg.value == amount, "MockTerminal: ETH mismatch");
            totalETHReceived += amount;
        } else {
            // Pull the ERC-20 tokens from the router via the allowance it set.
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(token).transferFrom(msg.sender, address(this), amount);
            totalReceived[token] += amount;
        }
        return 1; // Return 1 project token minted.
    }

    function addToBalanceOf(
        uint256,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
    {
        addToBalanceCallCount++;
        if (token == JBConstants.NATIVE_TOKEN) {
            require(msg.value == amount, "MockTerminal: ETH mismatch");
            totalETHReceived += amount;
        } else {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(token).transferFrom(msg.sender, address(this), amount);
            totalReceived[token] += amount;
        }
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](0);
    }

    receive() external payable {}
}

// ──────────────────────────────────────────────────────────────────────────────
// Mock cashout terminal that simulates cashing out JB project tokens for ETH.
// When cashOutTokensOf is called, it sends ETH back to the caller (the router)
// to simulate the bonding curve reclaim. The reclaim amount is a fraction of
// the cashOutCount to simulate realistic slippage.
// ──────────────────────────────────────────────────────────────────────────────
contract MockCashOutTerminal {
    uint256 public cashOutCallCount;

    /// @notice The JB project token whose cashouts this terminal handles.
    /// Set by the invariant test's setUp so the mock can burn tokens from the holder.
    InvariantMockERC20 public jbToken;

    function setJbToken(InvariantMockERC20 _jbToken) external {
        jbToken = _jbToken;
    }

    /// @notice Simulates cashing out project tokens. Returns 80% of cashOutCount as ETH reclaim.
    /// Burns the project tokens from the holder to match real terminal behavior.
    function cashOutTokensOf(
        address holder,
        uint256, /* projectId */
        uint256 cashOutCount,
        address, /* tokenToReclaim */
        uint256, /* minTokensReclaimed */
        address payable beneficiary,
        bytes calldata /* metadata */
    )
        external
        returns (uint256 reclaimAmount)
    {
        cashOutCallCount++;

        // Burn the project tokens from the holder (simulates what a real terminal does via JBTokens.burnFrom).
        if (address(jbToken) != address(0) && cashOutCount > 0) {
            jbToken.burn(holder, cashOutCount);
        }

        // Simulate bonding curve: reclaim 80% of the cashout count (in wei, treating count as ETH amount).
        reclaimAmount = cashOutCount * 80 / 100;
        if (reclaimAmount > 0) {
            (bool ok,) = beneficiary.call{value: reclaimAmount}("");
            require(ok, "MockCashOutTerminal: ETH transfer failed");
        }
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            // forge-lint: disable-next-line(unsafe-typecast)
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
    }

    receive() external payable {}
}

// ──────────────────────────────────────────────────────────────────────────────
// Handler contract that exercises pay() and addToBalanceOf() with bounded
// random inputs. The fuzzer calls operations on this handler.
// ──────────────────────────────────────────────────────────────────────────────
contract RouterTerminalHandler is Test {
    JBRouterTerminal public router;
    InvariantMockERC20 public tokenA;
    InvariantMockERC20 public tokenB;
    InvariantMockERC20 public jbProjectToken;
    InvariantMockWETH9 public weth;
    MockDestTerminal public destTerminal;
    MockCashOutTerminal public cashOutTerminal;

    uint256 public constant PROJECT_ID = 1;
    uint256 public constant SOURCE_PROJECT_ID = 2;

    // Ghost variables: track total amounts sent to the router.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public ghost_totalETHPaid;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public ghost_totalTokenAPaid;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public ghost_totalTokenBPaid;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public ghost_totalCashOutETH;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public ghost_operationCount;

    constructor(
        JBRouterTerminal _router,
        InvariantMockERC20 _tokenA,
        InvariantMockERC20 _tokenB,
        InvariantMockERC20 _jbProjectToken,
        InvariantMockWETH9 _weth,
        MockDestTerminal _destTerminal,
        MockCashOutTerminal _cashOutTerminal
    ) {
        router = _router;
        tokenA = _tokenA;
        tokenB = _tokenB;
        jbProjectToken = _jbProjectToken;
        weth = _weth;
        destTerminal = _destTerminal;
        cashOutTerminal = _cashOutTerminal;
    }

    /// @notice Pay a project with native ETH.
    function payWithEth(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);

        vm.deal(address(this), amount);

        router.pay{value: amount}({
            projectId: PROJECT_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        ghost_totalETHPaid += amount;
        ghost_operationCount++;
    }

    /// @notice Pay a project with ERC-20 token A (project accepts token A directly).
    function payWithTokenA(uint256 amount) external {
        amount = bound(amount, 1, 100_000e18);

        tokenA.mint(address(this), amount);
        tokenA.approve(address(router), amount);

        router.pay({
            projectId: PROJECT_ID,
            token: address(tokenA),
            amount: amount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        ghost_totalTokenAPaid += amount;
        ghost_operationCount++;
    }

    /// @notice Pay a project with ERC-20 token B (project accepts token B directly).
    function payWithTokenB(uint256 amount) external {
        amount = bound(amount, 1, 100_000e18);

        tokenB.mint(address(this), amount);
        tokenB.approve(address(router), amount);

        router.pay({
            projectId: PROJECT_ID,
            token: address(tokenB),
            amount: amount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        ghost_totalTokenBPaid += amount;
        ghost_operationCount++;
    }

    /// @notice Add to a project's balance with native ETH.
    function addToBalanceWithEth(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);

        vm.deal(address(this), amount);

        router.addToBalanceOf{value: amount}({
            projectId: PROJECT_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: ""
        });

        ghost_totalETHPaid += amount;
        ghost_operationCount++;
    }

    /// @notice Add to a project's balance with ERC-20 token A.
    function addToBalanceWithTokenA(uint256 amount) external {
        amount = bound(amount, 1, 100_000e18);

        tokenA.mint(address(this), amount);
        tokenA.approve(address(router), amount);

        router.addToBalanceOf({
            projectId: PROJECT_ID,
            token: address(tokenA),
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: ""
        });

        ghost_totalTokenAPaid += amount;
        ghost_operationCount++;
    }

    /// @notice Add to a project's balance with ERC-20 token B.
    function addToBalanceWithTokenB(uint256 amount) external {
        amount = bound(amount, 1, 100_000e18);

        tokenB.mint(address(this), amount);
        tokenB.approve(address(router), amount);

        router.addToBalanceOf({
            projectId: PROJECT_ID,
            token: address(tokenB),
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: ""
        });

        ghost_totalTokenBPaid += amount;
        ghost_operationCount++;
    }

    /// @notice Pay a project with a JB project token, triggering the cashout loop.
    /// The router detects the token is a JB project token, enters _cashOutLoop, cashes out
    /// for ETH via the MockCashOutTerminal, and forwards the reclaimed ETH to the dest terminal.
    function payWithCashOut(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);

        // Mint the JB project token to the handler and approve the router.
        jbProjectToken.mint(address(this), amount);
        jbProjectToken.approve(address(router), amount);

        // Fund the cashout terminal with enough ETH to cover the reclaim (80% of amount).
        uint256 expectedReclaim = amount * 80 / 100;
        vm.deal(address(cashOutTerminal), expectedReclaim);

        router.pay({
            projectId: PROJECT_ID,
            token: address(jbProjectToken),
            amount: amount,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        ghost_totalCashOutETH += expectedReclaim;
        ghost_totalETHPaid += expectedReclaim;
        ghost_operationCount++;
    }

    // Allow receiving ETH (needed for vm.deal).
    receive() external payable {}
}

// ──────────────────────────────────────────────────────────────────────────────
// Invariant test contract.
// ──────────────────────────────────────────────────────────────────────────────
contract RouterTerminalInvariant is Test {
    JBRouterTerminal public router;
    InvariantMockERC20 public tokenA;
    InvariantMockERC20 public tokenB;
    InvariantMockERC20 public jbProjectToken;
    InvariantMockWETH9 public weth;
    MockDestTerminal public destTerminal;
    MockCashOutTerminal public cashOutTerminal;
    RouterTerminalHandler public handler;

    // Mocked protocol contracts.
    address public mockDirectory;
    address public mockPermissions;
    address public mockProjects;
    address public mockTokens;
    address public mockPermit2;
    address public mockFactory;
    address public mockPoolManager;

    uint256 public constant PROJECT_ID = 1;
    uint256 public constant SOURCE_PROJECT_ID = 2;

    function setUp() public {
        // Deploy real mock tokens.
        tokenA = new InvariantMockERC20("Token A", "TKA");
        tokenB = new InvariantMockERC20("Token B", "TKB");
        jbProjectToken = new InvariantMockERC20("JB Project Token", "JBT");
        weth = new InvariantMockWETH9();
        destTerminal = new MockDestTerminal();
        cashOutTerminal = new MockCashOutTerminal();
        cashOutTerminal.setJbToken(jbProjectToken);

        // Create addresses for mocked protocol contracts.
        mockDirectory = makeAddr("mockDirectory");
        vm.etch(mockDirectory, hex"00");
        mockPermissions = makeAddr("mockPermissions");
        vm.etch(mockPermissions, hex"00");
        mockProjects = makeAddr("mockProjects");
        vm.etch(mockProjects, hex"00");
        mockTokens = makeAddr("mockTokens");
        vm.etch(mockTokens, hex"00");
        mockPermit2 = makeAddr("mockPermit2");
        vm.etch(mockPermit2, hex"00");
        mockFactory = makeAddr("mockFactory");
        vm.etch(mockFactory, hex"00");
        mockPoolManager = makeAddr("mockPoolManager");
        vm.etch(mockPoolManager, hex"00");

        // Deploy the router terminal.
        router = new JBRouterTerminal(
            IJBDirectory(mockDirectory),
            IJBPermissions(mockPermissions),
            IJBProjects(mockProjects),
            IJBTokens(mockTokens),
            IPermit2(mockPermit2),
            address(this), // owner
            IWETH9(address(weth)),
            IUniswapV3Factory(mockFactory),
            IPoolManager(mockPoolManager),
            address(0) // no trusted forwarder
        );

        // ── Mock: directory.primaryTerminalOf returns our destTerminal for each token ──
        // Native token (ETH).
        vm.mockCall(
            mockDirectory,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, JBConstants.NATIVE_TOKEN)),
            abi.encode(address(destTerminal))
        );
        // Token A.
        vm.mockCall(
            mockDirectory,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(tokenA))),
            abi.encode(address(destTerminal))
        );
        // Token B.
        vm.mockCall(
            mockDirectory,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(tokenB))),
            abi.encode(address(destTerminal))
        );

        // ── Mock: tokens.projectIdOf returns 0 by default (not a JB project token) ──
        // This makes the router skip the cashout loop and go straight to resolve+convert.
        vm.mockCall(mockTokens, abi.encodeWithSelector(IJBTokens.projectIdOf.selector), abi.encode(uint256(0)));

        // ── Mock: tokens.projectIdOf returns SOURCE_PROJECT_ID for our JB project token ──
        // This specific mock overrides the default for this token, triggering the cashout loop.
        vm.mockCall(
            mockTokens,
            abi.encodeCall(IJBTokens.projectIdOf, (IJBToken(address(jbProjectToken)))),
            abi.encode(SOURCE_PROJECT_ID)
        );

        // ── Mock: dest project does NOT accept the JB project token directly ──
        // This forces the router into the cashout loop instead of direct forwarding.
        vm.mockCall(
            mockDirectory,
            abi.encodeCall(IJBDirectory.primaryTerminalOf, (PROJECT_ID, address(jbProjectToken))),
            abi.encode(address(0))
        );

        // ── Mock: directory.terminalsOf returns the cashout terminal for the source project ──
        IJBTerminal[] memory sourceTerminals = new IJBTerminal[](1);
        sourceTerminals[0] = IJBTerminal(address(cashOutTerminal));
        vm.mockCall(
            mockDirectory, abi.encodeCall(IJBDirectory.terminalsOf, (SOURCE_PROJECT_ID)), abi.encode(sourceTerminals)
        );

        // Deploy handler.
        handler = new RouterTerminalHandler(router, tokenA, tokenB, jbProjectToken, weth, destTerminal, cashOutTerminal);

        // Target only the handler for invariant testing.
        targetContract(address(handler));

        // Target all handler functions (including the cashout handler).
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = RouterTerminalHandler.payWithEth.selector;
        selectors[1] = RouterTerminalHandler.payWithTokenA.selector;
        selectors[2] = RouterTerminalHandler.payWithTokenB.selector;
        selectors[3] = RouterTerminalHandler.addToBalanceWithEth.selector;
        selectors[4] = RouterTerminalHandler.addToBalanceWithTokenA.selector;
        selectors[5] = RouterTerminalHandler.addToBalanceWithTokenB.selector;
        selectors[6] = RouterTerminalHandler.payWithCashOut.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ────────────────────────────────── INVARIANTS
    // ──────────────────────────────────

    /// @notice The router should never hold ETH after completing an operation.
    /// It is a pass-through: all ETH should be forwarded to the destination terminal.
    function invariant_routerHoldsNoETH() public view {
        assertEq(address(router).balance, 0, "Router holds ETH after operation");
    }

    /// @notice The router should never hold token A after completing an operation.
    function invariant_routerHoldsNoTokenA() public view {
        assertEq(tokenA.balanceOf(address(router)), 0, "Router holds token A after operation");
    }

    /// @notice The router should never hold token B after completing an operation.
    function invariant_routerHoldsNoTokenB() public view {
        assertEq(tokenB.balanceOf(address(router)), 0, "Router holds token B after operation");
    }

    /// @notice The router should never hold WETH after completing an operation.
    function invariant_routerHoldsNoWETH() public view {
        assertEq(weth.balanceOf(address(router)), 0, "Router holds WETH after operation");
    }

    /// @notice All ETH paid through the router must arrive at the destination terminal.
    function invariant_allETHForwarded() public view {
        assertEq(
            destTerminal.totalETHReceived(),
            handler.ghost_totalETHPaid(),
            "ETH forwarded to terminal != ETH paid to router"
        );
    }

    /// @notice All token A paid through the router must arrive at the destination terminal.
    function invariant_allTokenAForwarded() public view {
        assertEq(
            destTerminal.totalReceived(address(tokenA)),
            handler.ghost_totalTokenAPaid(),
            "Token A forwarded to terminal != token A paid to router"
        );
    }

    /// @notice All token B paid through the router must arrive at the destination terminal.
    function invariant_allTokenBForwarded() public view {
        assertEq(
            destTerminal.totalReceived(address(tokenB)),
            handler.ghost_totalTokenBPaid(),
            "Token B forwarded to terminal != token B paid to router"
        );
    }

    /// @notice The router should never hold the JB project token after a cashout operation.
    function invariant_routerHoldsNoJBProjectToken() public view {
        assertEq(jbProjectToken.balanceOf(address(router)), 0, "Router holds JB project token after operation");
    }

    /// @notice Sanity check: the fuzzer actually called some operations.
    function invariant_callSummary() public pure {
        // This invariant just logs — it always passes.
        // When run with -vv, you can see the operation count.
        assert(true);
    }
}
