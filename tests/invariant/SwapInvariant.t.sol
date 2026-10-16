// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-5/proxy/ERC1967/ERC1967Proxy.sol";
import { SmartWallet } from "src/smartWallet/SmartWallet.sol";
import { SmartWalletCoordinator } from "src/smartWallet/SmartWalletCoordinator.sol";
import { SmartWalletFactory } from "src/smartWallet/SmartWalletFactory.sol";
import { SwapExecutor } from "src/swap/SwapExecutor.sol";
import { MultiSignerAuth } from "src/module/MultiSignerAuth.sol";
import { MockERC20 } from "fixtures/MockERC20.sol";
import { MockAggregator } from "fixtures/MockAggregator.sol";

contract SwapHandler is Test {
  SmartWalletCoordinator public coordinator;
  SmartWalletFactory public factory;
  SwapExecutor public executor;
  MockAggregator public aggregator;
  MockERC20 public tokenIn;
  MockERC20 public tokenOut;

  SmartWallet[4] public wallets;
  address[4] public owners;

  // Ghost accounting across all successful swaps.
  uint256 public totalMintedIn;
  uint256 public totalSpentIn;
  uint256 public totalPaidOut;

  constructor() {
    address[] memory tokens = new address[](0);
    coordinator = SmartWalletCoordinator(
      address(
        new ERC1967Proxy(
          address(new SmartWalletCoordinator()),
          abi.encodeCall(
            SmartWalletCoordinator.initialize,
            (
              SmartWalletCoordinator.Setup({
                owner: address(0),
                strategyAddress: address(0),
                withdrawalDelay: 0,
                allowedTokens: tokens,
                stakingToken: address(0),
                stakingContract: address(0),
                vestingContract: address(0),
                relayer: address(this)
              })
            )
          )
        )
      )
    );
    factory = SmartWalletFactory(
      address(
        new ERC1967Proxy(
          address(new SmartWalletFactory()),
          abi.encodeCall(
            SmartWalletFactory.initialize,
            (address(coordinator), address(new SmartWallet()))
          )
        )
      )
    );
    coordinator.setFactory(address(factory));

    tokenIn = new MockERC20("USD Coin", "USDC");
    tokenOut = new MockERC20("Blue Chip", "BLUE");
    coordinator.allowToken(address(tokenIn));
    coordinator.allowToken(address(tokenOut));

    executor = new SwapExecutor(address(coordinator));
    coordinator.setSwapExecutor(address(executor));
    aggregator = new MockAggregator();
    executor.allowAggregator(address(aggregator));

    for (uint256 i = 0; i < 4; i++) {
      owners[i] = makeAddr(
        string.concat("swapOwner", vm.toString(i))
      );
      wallets[i] = SmartWallet(
        payable(factory.deployWallet(
          keccak256(abi.encode("swapWallet", i)),
          owners[i]
        ))
      );
    }
  }

  function _auth()
    private
    pure
    returns (MultiSignerAuth.Auth memory)
  {
    return
      MultiSignerAuth.Auth({
        authType: MultiSignerAuth.AuthType.Direct,
        payload: ""
      });
  }

  /// @dev Successful swap with full input spend.
  function swapFull(
    uint256 seed,
    uint256 amountIn,
    uint256 amountOut
  ) public {
    uint256 i = seed % wallets.length;
    amountIn = bound(amountIn, 1, 1_000 ether);
    amountOut = bound(amountOut, 1, 1_000 ether);

    tokenIn.mint(address(wallets[i]), amountIn);
    totalMintedIn += amountIn;

    vm.prank(owners[i]);
    wallets[i].swap(
      address(tokenIn),
      address(tokenOut),
      amountIn,
      amountOut,
      address(aggregator),
      abi.encodeCall(
        MockAggregator.swap,
        (tokenIn, amountIn, tokenOut, amountOut)
      ),
      type(uint256).max,
      _auth()
    );

    totalSpentIn += amountIn;
    totalPaidOut += amountOut;
  }

  /// @dev Successful swap where the route spends only part of the input (refund path).
  function swapPartial(
    uint256 seed,
    uint256 amountIn,
    uint256 spendRatio
  ) public {
    uint256 i = seed % wallets.length;
    amountIn = bound(amountIn, 2, 1_000 ether);
    uint256 spend = bound(spendRatio, 1, amountIn);
    uint256 amountOut = spend / 2 + 1;

    tokenIn.mint(address(wallets[i]), amountIn);
    totalMintedIn += amountIn;

    vm.prank(owners[i]);
    wallets[i].swap(
      address(tokenIn),
      address(tokenOut),
      amountIn,
      amountOut,
      address(aggregator),
      abi.encodeCall(
        MockAggregator.swap,
        (tokenIn, spend, tokenOut, amountOut)
      ),
      type(uint256).max,
      _auth()
    );

    totalSpentIn += spend;
    totalPaidOut += amountOut;
  }

  /// @dev Swap that fails the slippage check — must revert and change nothing.
  function swapSlippageFailure(
    uint256 seed,
    uint256 amountIn
  ) public {
    uint256 i = seed % wallets.length;
    amountIn = bound(amountIn, 1, 1_000 ether);

    tokenIn.mint(address(wallets[i]), amountIn);
    totalMintedIn += amountIn;

    vm.prank(owners[i]);
    try
      wallets[i].swap(
        address(tokenIn),
        address(tokenOut),
        amountIn,
        100 ether,
        address(aggregator),
        abi.encodeCall(
          MockAggregator.swap,
          (tokenIn, amountIn, tokenOut, 0)
        ),
        type(uint256).max,
        _auth()
      )
    {
      revert("slippage failure should revert");
    } catch {}
  }
}

/// @dev System-level swap invariants: the executor is a pure pass-through that never
///      accumulates funds or approvals, and token totals reconcile across the fleet.
contract SwapInvariantTest is StdInvariant, Test {
  SwapHandler handler;

  function setUp() public {
    handler = new SwapHandler();
    targetContract(address(handler));
  }

  function invariant_executorNeverRetainsFunds() public view {
    assertEq(
      handler.tokenIn().balanceOf(address(handler.executor())),
      0
    );
    assertEq(
      handler.tokenOut().balanceOf(address(handler.executor())),
      0
    );
  }

  function invariant_noDanglingApprovals() public view {
    assertEq(
      handler.tokenIn().allowance(
        address(handler.executor()),
        address(handler.aggregator())
      ),
      0
    );
    for (uint256 i = 0; i < 4; i++) {
      assertEq(
        handler.tokenIn().allowance(
          address(handler.wallets(i)),
          address(handler.executor())
        ),
        0
      );
    }
  }

  function invariant_tokenConservation() public view {
    // Unspent input remains in wallets; spent input sits with the aggregator.
    uint256 walletBalances;
    uint256 walletOutBalances;
    for (uint256 i = 0; i < 4; i++) {
      walletBalances += handler.tokenIn().balanceOf(
        address(handler.wallets(i))
      );
      walletOutBalances += handler.tokenOut().balanceOf(
        address(handler.wallets(i))
      );
    }

    assertEq(
      walletBalances,
      handler.totalMintedIn() - handler.totalSpentIn()
    );
    assertEq(
      handler.tokenIn().balanceOf(address(handler.aggregator())),
      handler.totalSpentIn()
    );
    assertEq(walletOutBalances, handler.totalPaidOut());
  }
}
