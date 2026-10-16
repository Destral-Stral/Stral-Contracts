// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "fixtures/BaseTest.sol";
import { SmartWallet } from "src/smartWallet/SmartWallet.sol";
import { MultiSignerAuth } from "src/module/MultiSignerAuth.sol";
import { SwapModule } from "src/swap/SwapModule.sol";
import { PasskeySignature } from "src/libs/PasskeySignature.sol";
import { MockERC20 } from "fixtures/MockERC20.sol";
import { MockWETH } from "fixtures/MockWETH.sol";
import { MockStaking } from "fixtures/MockStaking.sol";

contract WalletTest is BaseTest {
  SmartWallet wallet;
  address owner = makeAddr("owner");
  bytes32 constant USER_ID = keccak256("user1");

  MockERC20 dojiumToken;
  MockStaking staking;
  address stakingContract;

  function setUp() public override {
    super.setUp();
    wallet = _deployWallet(USER_ID, owner);

    dojiumToken = new MockERC20("DOJIUM", "DOJ");
    staking = new MockStaking(dojiumToken);
    stakingContract = address(staking);
    coordinator.setStakingToken(address(dojiumToken));
    coordinator.setStakingContract(stakingContract);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  VIEW FUNCTIONS
  // ═══════════════════════════════════════════════════════════════════════

  function test_isWalletOwner_trueForInitialOwner() public {
    assertTrue(wallet.isWalletOwner(owner));
  }

  function test_isWalletOwner_falseForStranger() public {
    assertFalse(wallet.isWalletOwner(makeAddr("stranger")));
  }

  function test_getOwners_returnsInitialOwnerEntry() public {
    MultiSignerAuth.OwnerEntry[] memory owners = wallet.getOwners();
    assertEq(owners.length, 1);
    assertEq(
      uint8(owners[0].ownerType),
      uint8(MultiSignerAuth.AuthType.Direct)
    );
    assertEq(owners[0].wallet, owner);
  }

  function test_getWhitelist_emptyByDefault() public {
    (
      address[] memory recipients,
      uint256[] memory timestamps
    ) = wallet.getWhitelist();
    assertEq(recipients.length, 0);
    assertEq(timestamps.length, 0);
  }

  function test_nonce_startsAtZero() public {
    assertEq(wallet.nonce(), 0);
  }

  function test_receive_acceptsEth() public {
    address sender = makeAddr("sender");
    vm.deal(sender, 1 ether);
    vm.prank(sender);
    (bool ok, ) = address(wallet).call{ value: 1 ether }("");
    assertTrue(ok);
    assertEq(address(wallet).balance, 1 ether);
  }

  function test_receive_emitsEvent() public {
    address sender = makeAddr("sender");
    vm.deal(sender, 1 ether);
    vm.prank(sender);
    vm.expectEmit(true, false, false, true, address(wallet));
    emit SmartWallet.Received(sender, 1 ether);
    (bool ok, ) = address(wallet).call{ value: 1 ether }("");
    assertTrue(ok);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  addWalletOwner / removeWalletOwner
  // ═══════════════════════════════════════════════════════════════════════

  function test_addWalletOwner_direct_addsOwner() public {
    address newOwner = makeAddr("newOwner");
    vm.prank(owner);
    wallet.addWalletOwner(newOwner, NO_DEADLINE, _directAuth());
    assertTrue(wallet.isWalletOwner(newOwner));
  }

  function test_addWalletOwner_direct_emitsEvent() public {
    address newOwner = makeAddr("newOwner");
    vm.prank(owner);
    vm.expectEmit(true, false, false, false, address(wallet));
    emit MultiSignerAuth.WalletOwnerAdded(newOwner);
    wallet.addWalletOwner(newOwner, NO_DEADLINE, _directAuth());
  }

  function test_addWalletOwner_direct_doesNotIncrementNonce() public {
    address newOwner = makeAddr("newOwner");
    vm.prank(owner);
    wallet.addWalletOwner(newOwner, NO_DEADLINE, _directAuth());
    assertEq(wallet.nonce(), 0); // Direct auth bypasses nonce
  }

  function test_addWalletOwner_revertsIfNotOwner() public {
    vm.prank(makeAddr("stranger"));
    vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
    wallet.addWalletOwner(makeAddr("x"), NO_DEADLINE, _directAuth());
  }

  function test_removeWalletOwner_direct_removesOwner() public {
    address newOwner = makeAddr("newOwner");
    vm.prank(owner);
    wallet.addWalletOwner(newOwner, NO_DEADLINE, _directAuth());

    vm.prank(owner);
    wallet.removeWalletOwner(newOwner, NO_DEADLINE, _directAuth());
    assertFalse(wallet.isWalletOwner(newOwner));
  }

  function test_removeWalletOwner_direct_emitsEvent() public {
    address newOwner = makeAddr("newOwner");
    vm.prank(owner);
    wallet.addWalletOwner(newOwner, NO_DEADLINE, _directAuth());

    vm.prank(owner);
    vm.expectEmit(true, false, false, false, address(wallet));
    emit MultiSignerAuth.WalletOwnerRemoved(newOwner);
    wallet.removeWalletOwner(newOwner, NO_DEADLINE, _directAuth());
  }

  function test_removeWalletOwner_direct_updatesGetOwners() public {
    address newOwner = makeAddr("newOwner");
    vm.prank(owner);
    wallet.addWalletOwner(newOwner, NO_DEADLINE, _directAuth());
    vm.prank(owner);
    wallet.removeWalletOwner(newOwner, NO_DEADLINE, _directAuth());
    assertEq(wallet.getOwners().length, 1);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  addES256Owner / removeES256Owner
  // ═══════════════════════════════════════════════════════════════════════

  function test_addES256Owner_direct_registersPasskey() public {
    bytes32 credentialId = keccak256("cred");
    PasskeySignature.ES256PublicKey memory pk = PasskeySignature
      .ES256PublicKey({
        qx: bytes32(uint256(10)),
        qy: bytes32(uint256(20))
      });
    vm.prank(owner);
    wallet.addES256Owner(
      credentialId,
      pk,
      NO_DEADLINE,
      _directAuth()
    );

    MultiSignerAuth.OwnerEntry[] memory owners = wallet.getOwners();
    assertEq(owners.length, 2);
    assertEq(
      uint8(owners[1].ownerType),
      uint8(MultiSignerAuth.AuthType.ES256)
    );
    assertEq(owners[1].credentialId, credentialId);
  }

  function test_addES256Owner_direct_emitsEvent() public {
    bytes32 credentialId = keccak256("cred");
    PasskeySignature.ES256PublicKey memory pk = PasskeySignature
      .ES256PublicKey({
        qx: bytes32(uint256(10)),
        qy: bytes32(uint256(20))
      });
    vm.prank(owner);
    vm.expectEmit(true, false, false, false, address(wallet));
    emit MultiSignerAuth.ES256OwnerAdded(credentialId);
    wallet.addES256Owner(
      credentialId,
      pk,
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_removeES256Owner_direct_removesPasskey() public {
    bytes32 credentialId = keccak256("cred");
    PasskeySignature.ES256PublicKey memory pk = PasskeySignature
      .ES256PublicKey({
        qx: bytes32(uint256(10)),
        qy: bytes32(uint256(20))
      });
    vm.prank(owner);
    wallet.addES256Owner(
      credentialId,
      pk,
      NO_DEADLINE,
      _directAuth()
    );

    vm.prank(owner);
    wallet.removeES256Owner(credentialId, NO_DEADLINE, _directAuth());
    assertEq(wallet.getOwners().length, 1);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  addToWhitelist / removeFromWhitelist
  // ═══════════════════════════════════════════════════════════════════════

  function test_addToWhitelist_direct_addsRecipient() public {
    address recipient = makeAddr("recipient");
    vm.prank(owner);
    wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());
    assertTrue(wallet.whitelist(recipient) > 1); // >1 = block.timestamp
  }

  function test_addToWhitelist_direct_emitsEvent() public {
    address recipient = makeAddr("recipient");
    vm.prank(owner);
    vm.expectEmit(true, false, false, false, address(wallet));
    emit SmartWallet.WhitelistAdded(recipient, block.timestamp);
    wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());
  }

  function test_addToWhitelist_direct_appearsInGetWhitelist() public {
    address recipient = makeAddr("recipient");
    vm.prank(owner);
    wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());
    (address[] memory r, ) = wallet.getWhitelist();
    assertEq(r.length, 1);
    assertEq(r[0], recipient);
  }

  function test_addToWhitelist_revertsIfNotOwner() public {
    vm.prank(makeAddr("stranger"));
    vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
    wallet.addToWhitelist(makeAddr("x"), NO_DEADLINE, _directAuth());
  }

  function test_removeFromWhitelist_direct_removesRecipient() public {
    address recipient = makeAddr("recipient");
    vm.prank(owner);
    wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());
    vm.prank(owner);
    wallet.removeFromWhitelist(recipient, NO_DEADLINE, _directAuth());
    assertEq(wallet.whitelist(recipient), 0);
  }

  function test_removeFromWhitelist_direct_emitsEvent() public {
    address recipient = makeAddr("recipient");
    vm.prank(owner);
    wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());
    vm.prank(owner);
    vm.expectEmit(true, false, false, false, address(wallet));
    emit SmartWallet.WhitelistRemoved(recipient);
    wallet.removeFromWhitelist(recipient, NO_DEADLINE, _directAuth());
  }

  function test_removeFromWhitelist_direct_removesFromGetWhitelist()
    public
  {
    address recipient = makeAddr("recipient");
    vm.prank(owner);
    wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());
    vm.prank(owner);
    wallet.removeFromWhitelist(recipient, NO_DEADLINE, _directAuth());
    (address[] memory r, ) = wallet.getWhitelist();
    assertEq(r.length, 0);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  withdrawAssets
  // ═══════════════════════════════════════════════════════════════════════

  function test_withdrawAssets_succeedsForNonAllowedToken() public {
    MockERC20 otherToken = new MockERC20("Other", "OTH");
    otherToken.mint(address(wallet), 100 ether);
    address recipient = makeAddr("recipient");
    vm.prank(owner);
    wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());

    vm.warp(block.timestamp + DELAY + 1);
    vm.prank(owner);
    wallet.withdrawAssets(
      recipient,
      address(otherToken),
      10 ether,
      NO_DEADLINE,
      _directAuth()
    );
    assertEq(otherToken.balanceOf(recipient), 10 ether);
  }

  function test_withdrawAssets_sendsEth() public {
    vm.deal(address(wallet), 5 ether);
    address recipient = makeAddr("recipient");
    vm.prank(owner);
    wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());

    vm.warp(block.timestamp + DELAY + 1);
    vm.prank(owner);
    wallet.withdrawAssets(
      recipient,
      address(0),
      2 ether,
      NO_DEADLINE,
      _directAuth()
    );
    assertEq(recipient.balance, 2 ether);
    assertEq(address(wallet).balance, 3 ether);
  }

  function test_withdrawAssets_ethRevertsIfDelayNotMet() public {
    vm.deal(address(wallet), 5 ether);
    address recipient = makeAddr("recipient");
    vm.prank(owner);
    wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());

    uint256 addedAt = wallet.whitelist(recipient);
    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SmartWallet.WithdrawalDelayNotMet.selector,
        addedAt + DELAY
      )
    );
    wallet.withdrawAssets(
      recipient,
      address(0),
      1 ether,
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_withdrawAssets_revertsIfNotWhitelisted() public {
    address stranger = makeAddr("stranger");
    token.mint(address(wallet), 100 ether);
    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SmartWallet.NotWhitelisted.selector,
        stranger
      )
    );
    wallet.withdrawAssets(
      stranger,
      address(token),
      1 ether,
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_withdrawAssets_revertsIfDelayNotMet() public {
    address recipient = makeAddr("recipient");
    vm.prank(owner);
    wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());
    token.mint(address(wallet), 100 ether);

    // Read whitelist value before vm.prank so the view call doesn't consume the prank.
    uint256 addedAt = wallet.whitelist(recipient);
    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SmartWallet.WithdrawalDelayNotMet.selector,
        addedAt + DELAY
      )
    );
    wallet.withdrawAssets(
      recipient,
      address(token),
      1 ether,
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_withdrawAssets_succeedsAfterDelay() public {
    address recipient = makeAddr("recipient");
    vm.prank(owner);
    wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());
    token.mint(address(wallet), 100 ether);

    vm.warp(block.timestamp + DELAY + 1);
    vm.prank(owner);
    wallet.withdrawAssets(
      recipient,
      address(token),
      10 ether,
      NO_DEADLINE,
      _directAuth()
    );
    assertEq(token.balanceOf(recipient), 10 ether);
  }

  function test_withdrawAssets_newOwnerIsNotWhitelistedAutomatically()
    public
  {
    token.mint(address(wallet), 100 ether);
    address otherOwner = makeAddr("otherOwner");
    vm.prank(owner);
    wallet.addWalletOwner(otherOwner, NO_DEADLINE, _directAuth());

    assertEq(wallet.whitelist(otherOwner), 0);

    vm.prank(otherOwner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SmartWallet.NotWhitelisted.selector,
        otherOwner
      )
    );
    wallet.withdrawAssets(
      otherOwner,
      address(token),
      10 ether,
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_withdrawAssets_initialOwnerIsNotWhitelistedAutomatically()
    public
  {
    token.mint(address(wallet), 100 ether);
    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SmartWallet.NotWhitelisted.selector,
        owner
      )
    );
    wallet.withdrawAssets(
      owner,
      address(token),
      50 ether,
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_withdrawAssets_emitsEvent() public {
    address recipient = makeAddr("recipient");
    token.mint(address(wallet), 100 ether);
    vm.prank(owner);
    wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());

    vm.warp(block.timestamp + DELAY + 1);
    vm.prank(owner);
    vm.expectEmit(true, true, false, true, address(wallet));
    emit SmartWallet.AssetsWithdrawn(
      recipient,
      address(token),
      50 ether
    );
    wallet.withdrawAssets(
      recipient,
      address(token),
      50 ether,
      NO_DEADLINE,
      _directAuth()
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  transferAssets
  // ═══════════════════════════════════════════════════════════════════════

  function test_transferAssets_revertsIfTokenNotAllowed() public {
    address badToken = makeAddr("badToken");
    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SmartWallet.TokenNotAllowed.selector,
        badToken
      )
    );
    wallet.transferAssets(badToken, 1, NO_DEADLINE, _directAuth());
  }

  function test_transferAssets_revertsIfBlocked() public {
    coordinator.blockWallet(address(wallet));
    token.mint(address(wallet), 100 ether);
    vm.prank(owner);
    vm.expectRevert(SwapModule.WalletBlocked.selector);
    wallet.transferAssets(
      address(token),
      1 ether,
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_transferAssets_revertsIfStrategyNotSet() public {
    coordinator.setStrategyAddress(address(0));
    token.mint(address(wallet), 100 ether);
    vm.prank(owner);
    vm.expectRevert(SmartWallet.StrategyNotSet.selector);
    wallet.transferAssets(
      address(token),
      1 ether,
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_transferAssets_sendsToStrategy() public {
    token.mint(address(wallet), 100 ether);
    vm.prank(owner);
    wallet.transferAssets(
      address(token),
      60 ether,
      NO_DEADLINE,
      _directAuth()
    );
    assertEq(token.balanceOf(strategy), 60 ether);
    assertEq(token.balanceOf(address(wallet)), 40 ether);
  }

  function test_transferAssets_emitsEvent() public {
    token.mint(address(wallet), 100 ether);
    vm.prank(owner);
    vm.expectEmit(true, false, false, true, address(wallet));
    emit SmartWallet.AssetsTransferred(
      address(token),
      60 ether,
      strategy
    );
    wallet.transferAssets(
      address(token),
      60 ether,
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_transferAssets_ethRevertsIfWethNotSet() public {
    vm.deal(address(wallet), 5 ether);
    vm.prank(owner);
    vm.expectRevert(SwapModule.WethNotSet.selector);
    wallet.transferAssets(address(0), 1 ether, NO_DEADLINE, _directAuth());
  }

  function test_transferAssets_ethRevertsIfWethNotAllowed() public {
    MockWETH weth = new MockWETH();
    coordinator.setWeth(address(weth));
    vm.deal(address(wallet), 5 ether);
    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SmartWallet.TokenNotAllowed.selector,
        address(weth)
      )
    );
    wallet.transferAssets(address(0), 1 ether, NO_DEADLINE, _directAuth());
  }

  function test_transferAssets_wrapsEthAndSendsWethToStrategy() public {
    MockWETH weth = new MockWETH();
    coordinator.setWeth(address(weth));
    coordinator.allowToken(address(weth));
    vm.deal(address(wallet), 5 ether);

    vm.prank(owner);
    vm.expectEmit(true, false, false, true, address(wallet));
    emit SmartWallet.AssetsTransferred(address(weth), 2 ether, strategy);
    wallet.transferAssets(address(0), 2 ether, NO_DEADLINE, _directAuth());

    assertEq(weth.balanceOf(strategy), 2 ether);
    assertEq(address(wallet).balance, 3 ether);
    assertEq(address(weth).balance, 2 ether);
  }

  function test_transferAssets_revertsIfNotOwner() public {
    token.mint(address(wallet), 100 ether);
    vm.prank(makeAddr("stranger"));
    vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
    wallet.transferAssets(
      address(token),
      1 ether,
      NO_DEADLINE,
      _directAuth()
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  stakeDojium
  // ═══════════════════════════════════════════════════════════════════════

  function test_stake_revertsIfStakingTokenNotSet() public {
    coordinator.setStakingToken(address(0));
    dojiumToken.mint(address(wallet), 100 ether);
    vm.prank(owner);
    vm.expectRevert(SmartWallet.StakingNotConfigured.selector);
    wallet.stake(10 ether, NO_DEADLINE, _directAuth());
  }

  function test_stake_revertsIfStakingContractNotSet() public {
    coordinator.setStakingContract(address(0));
    dojiumToken.mint(address(wallet), 100 ether);
    vm.prank(owner);
    vm.expectRevert(SmartWallet.StakingNotConfigured.selector);
    wallet.stake(10 ether, NO_DEADLINE, _directAuth());
  }

  function test_stake_revertsIfAmountExceedsBalance() public {
    // The staking contract's transferFrom fails when the wallet balance is insufficient.
    vm.prank(owner);
    vm.expectRevert();
    wallet.stake(40 ether, NO_DEADLINE, _directAuth());
  }

  function test_stake_transfersToStakingContract() public {
    dojiumToken.mint(address(wallet), 100 ether);
    vm.prank(owner);
    wallet.stake(40 ether, NO_DEADLINE, _directAuth());
    assertEq(dojiumToken.balanceOf(stakingContract), 40 ether);
    assertEq(dojiumToken.balanceOf(address(wallet)), 60 ether);
    assertEq(staking.staked(address(wallet)), 40 ether);
  }

  function test_stake_emitsEvent() public {
    dojiumToken.mint(address(wallet), 100 ether);
    vm.prank(owner);
    vm.expectEmit(false, true, false, true, address(wallet));
    emit SmartWallet.Staked(40 ether, stakingContract);
    wallet.stake(40 ether, NO_DEADLINE, _directAuth());
  }

  function test_unstake_callsStakingContract() public {
    dojiumToken.mint(address(wallet), 100 ether);
    vm.prank(owner);
    wallet.stake(40 ether, NO_DEADLINE, _directAuth());

    vm.prank(owner);
    wallet.unstake(15 ether, NO_DEADLINE, _directAuth());

    assertEq(dojiumToken.balanceOf(stakingContract), 25 ether);
    assertEq(dojiumToken.balanceOf(address(wallet)), 75 ether);
    assertEq(staking.staked(address(wallet)), 25 ether);
  }

  function test_unstake_emitsEvent() public {
    dojiumToken.mint(address(wallet), 100 ether);
    vm.prank(owner);
    wallet.stake(40 ether, NO_DEADLINE, _directAuth());

    vm.prank(owner);
    vm.expectEmit(false, true, false, true, address(wallet));
    emit SmartWallet.Unstaked(15 ether, stakingContract);
    wallet.unstake(15 ether, NO_DEADLINE, _directAuth());
  }

  function test_stake_revertsIfNotOwner() public {
    dojiumToken.mint(address(wallet), 100 ether);
    vm.prank(makeAddr("stranger"));
    vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
    wallet.stake(10 ether, NO_DEADLINE, _directAuth());
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  EOASig auth — nonce consumption
  // ═══════════════════════════════════════════════════════════════════════

  function test_eoaSig_incrementsNonce() public {
    uint256 ownerKey = uint256(keccak256("ownerKey"));
    address sigOwner = vm.addr(ownerKey);

    SmartWallet w = _deployWallet(keccak256("sigWallet"), sigOwner);
    assertEq(w.nonce(), 0);

    address newOwner = makeAddr("newOwner");

    // Build EIP-712 digest for addWalletOwner
    bytes32 structHash = keccak256(
      abi.encode(
        keccak256(
          "AddWalletOwner(address owner,uint256 nonce,uint256 deadline)"
        ),
        newOwner,
        uint256(0),
        NO_DEADLINE
      )
    );
    bytes32 digest = _walletDigest(address(w), structHash);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
    bytes memory sig = abi.encodePacked(r, s, v);

    MultiSignerAuth.Auth memory auth = MultiSignerAuth.Auth({
      authType: MultiSignerAuth.AuthType.EOASig,
      payload: sig
    });

    w.addWalletOwner(newOwner, NO_DEADLINE, auth);
    assertEq(w.nonce(), 1); // incremented on signed auth
  }

  function test_eoaSig_revertsOnReplay() public {
    uint256 ownerKey = uint256(keccak256("ownerKey"));
    address sigOwner = vm.addr(ownerKey);
    SmartWallet w = _deployWallet(keccak256("sigWallet2"), sigOwner);

    address newOwner = makeAddr("newOwner");
    bytes32 structHash = keccak256(
      abi.encode(
        keccak256(
          "AddWalletOwner(address owner,uint256 nonce,uint256 deadline)"
        ),
        newOwner,
        uint256(0),
        NO_DEADLINE
      )
    );
    bytes32 digest = _walletDigest(address(w), structHash);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
    bytes memory sig = abi.encodePacked(r, s, v);
    MultiSignerAuth.Auth memory auth = MultiSignerAuth.Auth({
      authType: MultiSignerAuth.AuthType.EOASig,
      payload: sig
    });

    w.addWalletOwner(newOwner, NO_DEADLINE, auth);

    // Replay the exact same sig — nonce is now 1, structHash has nonce=0, sig is stale
    vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
    w.addWalletOwner(newOwner, NO_DEADLINE, auth);
  }

  function test_eoaSig_revertsAfterDeadline() public {
    uint256 ownerKey = uint256(keccak256("ownerKey"));
    address sigOwner = vm.addr(ownerKey);
    SmartWallet w = _deployWallet(keccak256("sigWallet3"), sigOwner);

    address newOwner = makeAddr("newOwner");
    uint256 deadline = block.timestamp + 1 hours;
    bytes32 structHash = keccak256(
      abi.encode(
        keccak256(
          "AddWalletOwner(address owner,uint256 nonce,uint256 deadline)"
        ),
        newOwner,
        uint256(0),
        deadline
      )
    );
    bytes32 digest = _walletDigest(address(w), structHash);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
    MultiSignerAuth.Auth memory auth = MultiSignerAuth.Auth({
      authType: MultiSignerAuth.AuthType.EOASig,
      payload: abi.encodePacked(r, s, v)
    });

    vm.warp(deadline + 1);
    vm.expectRevert(
      abi.encodeWithSelector(
        MultiSignerAuth.SignatureExpired.selector,
        deadline
      )
    );
    w.addWalletOwner(newOwner, deadline, auth);
  }

  function test_removeWalletOwner_revertsOnLastOwner() public {
    vm.prank(owner);
    vm.expectRevert(MultiSignerAuth.CannotRemoveLastOwner.selector);
    wallet.removeWalletOwner(owner, NO_DEADLINE, _directAuth());
  }
}
