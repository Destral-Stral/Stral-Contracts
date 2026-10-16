// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "fixtures/BaseTest.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-5/proxy/ERC1967/ERC1967Proxy.sol";
import { SmartWalletCoordinator } from "src/smartWallet/SmartWalletCoordinator.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract CoordinatorTest is BaseTest {
  // ── Fixture state ───────────────────────────────────────────────────────

  address wallet1 = makeAddr("wallet1");
  address wallet2 = makeAddr("wallet2");
  address token2 = makeAddr("token2");

  function _deployCoordinator(
    SmartWalletCoordinator.Setup memory setup
  ) private returns (SmartWalletCoordinator) {
    return
      SmartWalletCoordinator(
        address(
          new ERC1967Proxy(
            address(new SmartWalletCoordinator()),
            abi.encodeCall(SmartWalletCoordinator.initialize, (setup))
          )
        )
      );
  }

  function test_initialize_emptySetupKeepsDefaults() public {
    address[] memory tokens = new address[](0);

    SmartWalletCoordinator configured = _deployCoordinator(
      SmartWalletCoordinator.Setup({
        owner: address(0),
        strategyAddress: address(0),
        withdrawalDelay: 0,
        allowedTokens: tokens,
        stakingToken: address(0),
        stakingContract: address(0),
        vestingContract: address(0),
        relayer: address(0)
      })
    );

    assertEq(configured.owner(), address(this));
    assertEq(configured.strategyAddress(), address(0));
    assertEq(configured.withdrawalDelay(), 0);
    assertEq(configured.getAllowedTokens().length, 0);
    assertEq(address(configured.stakingToken()), address(0));
    assertEq(configured.stakingContract(), address(0));
    assertEq(configured.vestingContract(), address(0));
    assertEq(configured.relayer(), address(0));
  }

  function test_initialize_appliesConfiguredValues()
    public
  {
    address devOpsAdmin = makeAddr("devOpsAdmin");
    address stakingToken = makeAddr("stakingToken");
    address stakingContract = makeAddr("stakingContract");
    address vestingContract = makeAddr("vestingContract");
    address relayer = makeAddr("relayer");
    address[] memory tokens = new address[](4);
    tokens[0] = address(token);
    tokens[1] = token2;
    tokens[2] = address(0);
    tokens[3] = token2;

    SmartWalletCoordinator configured = _deployCoordinator(
      SmartWalletCoordinator.Setup({
        owner: devOpsAdmin,
        strategyAddress: strategy,
        withdrawalDelay: 2 days,
        allowedTokens: tokens,
        stakingToken: stakingToken,
        stakingContract: stakingContract,
        vestingContract: vestingContract,
        relayer: relayer
      })
    );

    address[] memory allowedTokens = configured.getAllowedTokens();
    assertEq(configured.owner(), devOpsAdmin);
    assertEq(configured.strategyAddress(), strategy);
    assertEq(configured.withdrawalDelay(), 2 days);
    assertEq(allowedTokens.length, 2);
    assertEq(allowedTokens[0], address(token));
    assertEq(allowedTokens[1], token2);
    assertEq(address(configured.stakingToken()), stakingToken);
    assertEq(configured.stakingContract(), stakingContract);
    assertEq(configured.vestingContract(), vestingContract);
    assertEq(configured.relayer(), relayer);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  VIEW FUNCTIONS
  // ═══════════════════════════════════════════════════════════════════════

  function test_isBlocked_defaultFalse() public {
    assertFalse(coordinator.isBlocked(wallet1));
  }

  function test_isTokenAllowed_defaultFalse() public {
    // token2 was never allowed
    assertFalse(coordinator.isTokenAllowed(token2));
  }

  function test_isTokenAllowed_trueAfterAllow() public {
    // token was allowed in setUp
    assertTrue(coordinator.isTokenAllowed(address(token)));
  }

  function test_getBlockedWallets_emptyByDefault() public {
    assertEq(coordinator.getBlockedWallets().length, 0);
  }

  function test_getAllowedTokens_containsSetupToken() public {
    address[] memory tokens = coordinator.getAllowedTokens();
    assertEq(tokens.length, 1);
    assertEq(tokens[0], address(token));
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  setFactory
  // ═══════════════════════════════════════════════════════════════════════

  function test_setFactory_setsValue() public {
    address newFactory = makeAddr("newFactory");
    coordinator.setFactory(newFactory);
    assertEq(coordinator.factory(), newFactory);
  }

  function test_setFactory_emitsEvent() public {
    address newFactory = makeAddr("newFactory");
    vm.expectEmit(true, false, false, false, address(coordinator));
    emit SmartWalletCoordinator.FactorySet(newFactory);
    coordinator.setFactory(newFactory);
  }

  function test_setFactory_revertsIfNotOwner() public {
    vm.prank(makeAddr("notOwner"));
    vm.expectRevert();
    coordinator.setFactory(makeAddr("x"));
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  setStrategyAddress
  // ═══════════════════════════════════════════════════════════════════════

  function test_setStrategyAddress_setsValue() public {
    address newStrategy = makeAddr("newStrat");
    coordinator.setStrategyAddress(newStrategy);
    assertEq(coordinator.strategyAddress(), newStrategy);
  }

  function test_setStrategyAddress_emitsEvent() public {
    address newStrategy = makeAddr("newStrat");
    vm.expectEmit(true, false, false, false, address(coordinator));
    emit SmartWalletCoordinator.StrategyAddressUpdated(newStrategy);
    coordinator.setStrategyAddress(newStrategy);
  }

  function test_setStrategyAddress_revertsIfNotOwner() public {
    vm.prank(makeAddr("notOwner"));
    vm.expectRevert();
    coordinator.setStrategyAddress(makeAddr("x"));
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  setWithdrawalDelay
  // ═══════════════════════════════════════════════════════════════════════

  function test_setWithdrawalDelay_setsValue() public {
    coordinator.setWithdrawalDelay(7 days);
    assertEq(coordinator.withdrawalDelay(), 7 days);
  }

  function test_setWithdrawalDelay_emitsEvent() public {
    vm.expectEmit(false, false, false, true, address(coordinator));
    emit SmartWalletCoordinator.WithdrawalDelayUpdated(2 days);
    coordinator.setWithdrawalDelay(2 days);
  }

  function test_setWithdrawalDelay_revertsIfNotOwner() public {
    vm.prank(makeAddr("notOwner"));
    vm.expectRevert();
    coordinator.setWithdrawalDelay(1);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  blockWallet / unblockWallet
  // ═══════════════════════════════════════════════════════════════════════

  function test_blockWallet_setsBlocked() public {
    coordinator.blockWallet(wallet1);
    assertTrue(coordinator.isBlocked(wallet1));
  }

  function test_blockWallet_appendsToList() public {
    coordinator.blockWallet(wallet1);
    coordinator.blockWallet(wallet2);
    address[] memory list = coordinator.getBlockedWallets();
    assertEq(list.length, 2);
    assertEq(list[0], wallet1);
    assertEq(list[1], wallet2);
  }

  function test_blockWallet_idempotentListPush() public {
    coordinator.blockWallet(wallet1);
    coordinator.blockWallet(wallet1); // second call must not double-push
    assertEq(coordinator.getBlockedWallets().length, 1);
  }

  function test_blockWallet_emitsEvent() public {
    vm.expectEmit(true, false, false, false, address(coordinator));
    emit SmartWalletCoordinator.WalletBlocked(wallet1);
    coordinator.blockWallet(wallet1);
  }

  function test_blockWallet_revertsIfNotOwner() public {
    vm.prank(makeAddr("notOwner"));
    vm.expectRevert();
    coordinator.blockWallet(wallet1);
  }

  function test_unblockWallet_clearsBlocked() public {
    coordinator.blockWallet(wallet1);
    coordinator.unblockWallet(wallet1);
    assertFalse(coordinator.isBlocked(wallet1));
  }

  function test_unblockWallet_removesFromList() public {
    coordinator.blockWallet(wallet1);
    coordinator.blockWallet(wallet2);
    coordinator.unblockWallet(wallet1);
    address[] memory list = coordinator.getBlockedWallets();
    assertEq(list.length, 1);
    assertEq(list[0], wallet2);
  }

  function test_unblockWallet_swapAndPop_preservesOtherEntries()
    public
  {
    address wallet3 = makeAddr("wallet3");
    coordinator.blockWallet(wallet1);
    coordinator.blockWallet(wallet2);
    coordinator.blockWallet(wallet3);
    coordinator.unblockWallet(wallet2); // remove middle entry
    address[] memory list = coordinator.getBlockedWallets();
    assertEq(list.length, 2);
  }

  function test_unblockWallet_emitsEvent() public {
    coordinator.blockWallet(wallet1);
    vm.expectEmit(true, false, false, false, address(coordinator));
    emit SmartWalletCoordinator.WalletUnblocked(wallet1);
    coordinator.unblockWallet(wallet1);
  }

  function test_unblockWallet_revertsIfNotOwner() public {
    vm.prank(makeAddr("notOwner"));
    vm.expectRevert();
    coordinator.unblockWallet(wallet1);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  allowToken / disallowToken
  // ═══════════════════════════════════════════════════════════════════════

  function test_allowToken_setsAllowed() public {
    coordinator.allowToken(token2);
    assertTrue(coordinator.isTokenAllowed(token2));
  }

  function test_allowToken_appendsToList() public {
    coordinator.allowToken(token2);
    address[] memory tokens = coordinator.getAllowedTokens();
    assertEq(tokens.length, 2); // token from setUp + token2
  }

  function test_allowToken_idempotentListPush() public {
    coordinator.allowToken(address(token)); // already in setUp
    assertEq(coordinator.getAllowedTokens().length, 1);
  }

  function test_allowToken_emitsEvent() public {
    vm.expectEmit(true, false, false, false, address(coordinator));
    emit SmartWalletCoordinator.TokenAllowed(token2);
    coordinator.allowToken(token2);
  }

  function test_allowToken_revertsIfNotOwner() public {
    vm.prank(makeAddr("notOwner"));
    vm.expectRevert();
    coordinator.allowToken(token2);
  }

  function test_disallowToken_clearsAllowed() public {
    coordinator.disallowToken(address(token));
    assertFalse(coordinator.isTokenAllowed(address(token)));
  }

  function test_disallowToken_removesFromList() public {
    coordinator.allowToken(token2);
    coordinator.disallowToken(address(token));
    address[] memory tokens = coordinator.getAllowedTokens();
    assertEq(tokens.length, 1);
    assertEq(tokens[0], token2);
  }

  function test_disallowToken_emitsEvent() public {
    vm.expectEmit(true, false, false, false, address(coordinator));
    emit SmartWalletCoordinator.TokenDisallowed(address(token));
    coordinator.disallowToken(address(token));
  }

  function test_disallowToken_revertsIfNotOwner() public {
    vm.prank(makeAddr("notOwner"));
    vm.expectRevert();
    coordinator.disallowToken(address(token));
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  setStakingToken
  // ═══════════════════════════════════════════════════════════════════════

  function test_setStakingToken_defaultZero() public {
    assertEq(address(coordinator.stakingToken()), address(0));
  }

  function test_setStakingToken_setsValue() public {
    address dojium = makeAddr("dojium");
    coordinator.setStakingToken(dojium);
    assertEq(address(coordinator.stakingToken()), dojium);
  }

  function test_setStakingToken_emitsEvent() public {
    address dojium = makeAddr("dojium");
    vm.expectEmit(true, false, false, false, address(coordinator));
    emit SmartWalletCoordinator.StakingTokenSet(dojium);
    coordinator.setStakingToken(dojium);
  }

  function test_setStakingToken_revertsIfNotOwner() public {
    vm.prank(makeAddr("notOwner"));
    vm.expectRevert();
    coordinator.setStakingToken(makeAddr("dojium"));
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  setStakingContract
  // ═══════════════════════════════════════════════════════════════════════

  function test_setStakingContract_defaultZero() public {
    assertEq(coordinator.stakingContract(), address(0));
  }

  function test_setStakingContract_setsValue() public {
    address dest = makeAddr("stakingDest");
    coordinator.setStakingContract(dest);
    assertEq(coordinator.stakingContract(), dest);
  }

  function test_setStakingContract_emitsEvent() public {
    address dest = makeAddr("stakingDest");
    vm.expectEmit(true, false, false, false, address(coordinator));
    emit SmartWalletCoordinator.StakingContractSet(dest);
    coordinator.setStakingContract(dest);
  }

  function test_setStakingContract_revertsIfNotOwner() public {
    vm.prank(makeAddr("notOwner"));
    vm.expectRevert();
    coordinator.setStakingContract(makeAddr("dest"));
  }

  // ══════════════════════════════════════════════════════════════════════
  //  setVestingContract
  // ══════════════════════════════════════════════════════════════════════

  function test_setVestingContract_defaultZero() public {
    assertEq(coordinator.vestingContract(), address(0));
  }

  function test_setVestingContract_setsValue() public {
    address vesting = makeAddr("vesting");
    coordinator.setVestingContract(vesting);
    assertEq(coordinator.vestingContract(), vesting);
  }

  function test_setVestingContract_emitsEvent() public {
    address vesting = makeAddr("vesting");
    vm.expectEmit(true, false, false, false, address(coordinator));
    emit SmartWalletCoordinator.VestingContractSet(vesting);
    coordinator.setVestingContract(vesting);
  }

  function test_setVestingContract_revertsIfNotOwner() public {
    vm.prank(makeAddr("notOwner"));
    vm.expectRevert();
    coordinator.setVestingContract(makeAddr("vesting"));
  }

  // ══════════════════════════════════════════════════════════════════════
  //  setRelayer
  // ══════════════════════════════════════════════════════════════════════

  function test_setRelayer_setsValue() public {
    address relayer = makeAddr("relayer");
    coordinator.setRelayer(relayer);
    assertEq(coordinator.relayer(), relayer);
  }

  function test_setRelayer_emitsEvent() public {
    address relayer = makeAddr("relayer");
    vm.expectEmit(true, false, false, false, address(coordinator));
    emit SmartWalletCoordinator.RelayerSet(relayer);
    coordinator.setRelayer(relayer);
  }

  function test_setRelayer_revertsIfNotOwner() public {
    vm.prank(makeAddr("notOwner"));
    vm.expectRevert();
    coordinator.setRelayer(makeAddr("relayer"));
  }

  // ══════════════════════════════════════════════════════════════════════
  //  setWeth
  // ══════════════════════════════════════════════════════════════════════

  function test_setWeth_defaultZero() public {
    assertEq(coordinator.weth(), address(0));
  }

  function test_setWeth_setsValue() public {
    address weth = makeAddr("weth");
    coordinator.setWeth(weth);
    assertEq(coordinator.weth(), weth);
  }

  function test_setWeth_emitsEvent() public {
    address weth = makeAddr("weth");
    vm.expectEmit(true, false, false, false, address(coordinator));
    emit SmartWalletCoordinator.WethSet(weth);
    coordinator.setWeth(weth);
  }

  function test_setWeth_revertsIfNotOwner() public {
    vm.prank(makeAddr("notOwner"));
    vm.expectRevert();
    coordinator.setWeth(makeAddr("weth"));
  }
}
