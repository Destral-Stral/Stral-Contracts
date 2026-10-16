// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "fixtures/BaseTest.sol";
import { SmartWallet } from "src/smartWallet/SmartWallet.sol";
import { SwapExecutor } from "src/swap/SwapExecutor.sol";
import { MultiSignerAuth } from "src/module/MultiSignerAuth.sol";
import { MockERC20 } from "fixtures/MockERC20.sol";
import { MockAggregator } from "fixtures/MockAggregator.sol";
import { TheftAggregator, SelfPayAggregator, ReentrantWalletAggregator, NestedExecutorAggregator } from "fixtures/MaliciousAggregators.sol";
import { RevertingERC20, FalseReturnERC20, FeeOnTransferERC20 } from "fixtures/AdversarialTokens.sol";
import { IERC20 } from "@openzeppelin/contracts-5/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts-5/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts-5/token/ERC20/utils/SafeERC20.sol";

/// @dev Adversarial coverage for the swap path: hostile tokens, allowlisted-but-malicious
///      aggregators, reentrancy, and approval hygiene. Mirrors WalletAdversarialTest.
contract SwapAdversarialTest is BaseTest {
  SmartWallet wallet;
  address owner = makeAddr("owner");

  SwapExecutor executor;
  MockAggregator aggregator;
  MockERC20 tokenOut;

  uint256 constant AMOUNT_IN = 100 ether;
  uint256 constant AMOUNT_OUT = 50 ether;

  function setUp() public override {
    super.setUp();
    wallet = _deployWallet(keccak256("advUser"), owner);

    tokenOut = new MockERC20("Blue Chip", "BLUE");
    coordinator.allowToken(address(tokenOut));

    executor = new SwapExecutor(address(coordinator));
    coordinator.setSwapExecutor(address(executor));

    aggregator = new MockAggregator();
    executor.allowAggregator(address(aggregator));

    token.mint(address(wallet), AMOUNT_IN);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Malicious aggregators (allowlisted, then hostile)
  // ═══════════════════════════════════════════════════════════════════════

  function test_theftAggregator_takesInputPaysNothing_reverts()
    public
  {
    TheftAggregator theft = new TheftAggregator();
    executor.allowAggregator(address(theft));

    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SwapExecutor.InsufficientOutput.selector,
        0,
        AMOUNT_OUT
      )
    );
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(theft),
      abi.encodeCall(
        TheftAggregator.swap,
        (IERC20(address(token)), AMOUNT_IN)
      ),
      NO_DEADLINE,
      _directAuth()
    );

    // Revert rolled everything back: wallet keeps its input.
    assertEq(token.balanceOf(address(wallet)), AMOUNT_IN);
  }

  function test_selfPayAggregator_paysItself_reverts() public {
    SelfPayAggregator selfPay = new SelfPayAggregator();
    executor.allowAggregator(address(selfPay));

    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SwapExecutor.InsufficientOutput.selector,
        0,
        AMOUNT_OUT
      )
    );
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(selfPay),
      abi.encodeCall(
        SelfPayAggregator.swap,
        (IERC20(address(token)), AMOUNT_IN, tokenOut, AMOUNT_OUT)
      ),
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_reentrantWalletAggregator_cannotAuthAsWallet()
    public
  {
    ReentrantWalletAggregator reentrant = new ReentrantWalletAggregator();
    executor.allowAggregator(address(reentrant));

    // The aggregator reenters wallet.swap with Direct auth; it is not an owner,
    // so the auth gate rejects it and the whole swap unwinds.
    vm.prank(owner);
    vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(reentrant),
      abi.encodeCall(
        ReentrantWalletAggregator.swap,
        (wallet, address(token), address(tokenOut), AMOUNT_IN)
      ),
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_nestedExecutorAggregator_reentrancyBlocked() public {
    NestedExecutorAggregator nested = new NestedExecutorAggregator();
    executor.allowAggregator(address(nested));

    vm.prank(owner);
    vm.expectRevert(
      ReentrancyGuard.ReentrancyGuardReentrantCall.selector
    );
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(nested),
      abi.encodeCall(
        NestedExecutorAggregator.swap,
        (executor, address(token), address(tokenOut))
      ),
      NO_DEADLINE,
      _directAuth()
    );

    assertEq(token.balanceOf(address(wallet)), AMOUNT_IN);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Hostile tokens
  // ═══════════════════════════════════════════════════════════════════════

  function test_falseReturnTokenIn_reverts() public {
    FalseReturnERC20 falseToken = new FalseReturnERC20();
    coordinator.allowToken(address(falseToken));
    falseToken.mint(address(wallet), AMOUNT_IN);

    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SafeERC20.SafeERC20FailedOperation.selector,
        address(falseToken)
      )
    );
    wallet.swap(
      address(falseToken),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      "",
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_revertingTokenIn_reverts() public {
    RevertingERC20 revToken = new RevertingERC20();
    coordinator.allowToken(address(revToken));
    revToken.mint(address(wallet), AMOUNT_IN);

    vm.prank(owner);
    vm.expectRevert(RevertingERC20.TransferFailed.selector);
    wallet.swap(
      address(revToken),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      "",
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_feeOnTransferTokenIn_swapsWithReceivedAmount()
    public
  {
    FeeOnTransferERC20 feeToken = new FeeOnTransferERC20(
      makeAddr("feeSink")
    );
    coordinator.allowToken(address(feeToken));
    feeToken.mint(address(wallet), AMOUNT_IN);

    // Executor receives amountIn minus the 1% fee; the route must spend only that.
    uint256 received = AMOUNT_IN - AMOUNT_IN / feeToken.FEE_BPS();

    vm.prank(owner);
    wallet.swap(
      address(feeToken),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      abi.encodeCall(
        MockAggregator.swap,
        (MockERC20(address(feeToken)), received, tokenOut, AMOUNT_OUT)
      ),
      NO_DEADLINE,
      _directAuth()
    );

    assertEq(tokenOut.balanceOf(address(wallet)), AMOUNT_OUT);
    assertEq(feeToken.balanceOf(address(executor)), 0);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Approval hygiene
  // ═══════════════════════════════════════════════════════════════════════

  function test_swap_leavesNoDanglingApprovals() public {
    vm.prank(owner);
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      abi.encodeCall(
        MockAggregator.swap,
        (token, AMOUNT_IN, tokenOut, AMOUNT_OUT)
      ),
      NO_DEADLINE,
      _directAuth()
    );

    assertEq(token.allowance(address(wallet), address(executor)), 0);
    assertEq(
      token.allowance(address(executor), address(aggregator)),
      0
    );
  }

  function test_partialSpend_clearsAggregatorApproval() public {
    // Route spends half; executor must still zero the aggregator's remaining approval.
    vm.prank(owner);
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      abi.encodeCall(
        MockAggregator.swap,
        (token, AMOUNT_IN / 2, tokenOut, AMOUNT_OUT)
      ),
      NO_DEADLINE,
      _directAuth()
    );

    assertEq(
      token.allowance(address(executor), address(aggregator)),
      0
    );
    assertEq(token.balanceOf(address(wallet)), AMOUNT_IN / 2);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Direct executor calls (permissionless surface)
  // ═══════════════════════════════════════════════════════════════════════

  function test_executeSwap_directCall_onlyMovesCallerFunds() public {
    // A stranger calling the executor directly can only spend their own approved funds.
    address stranger = makeAddr("stranger");
    token.mint(stranger, AMOUNT_IN);

    vm.startPrank(stranger);
    token.approve(address(executor), AMOUNT_IN);
    uint256 amountOut = executor.executeSwap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      abi.encodeCall(
        MockAggregator.swap,
        (token, AMOUNT_IN, tokenOut, AMOUNT_OUT)
      )
    );
    vm.stopPrank();

    assertEq(amountOut, AMOUNT_OUT);
    assertEq(tokenOut.balanceOf(stranger), AMOUNT_OUT);
    // Wallet funds were never touched.
    assertEq(token.balanceOf(address(wallet)), AMOUNT_IN);
  }

  function test_executeSwap_directCall_cannotSpendWalletApproval()
    public
  {
    // Even mid-approval, only the wallet itself can trigger a pull of its funds:
    // approvals are granted inside swap() and consumed in the same call, so a
    // stranger calling executeSwap pulls from *themselves* (and fails without funds).
    address stranger = makeAddr("stranger");
    vm.prank(stranger);
    vm.expectRevert();
    executor.executeSwap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      abi.encodeCall(
        MockAggregator.swap,
        (token, AMOUNT_IN, tokenOut, AMOUNT_OUT)
      )
    );
  }
}
