// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { BeaconProxy } from "@openzeppelin/contracts-5/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts-5/proxy/beacon/UpgradeableBeacon.sol";
import { BaseTest } from "fixtures/BaseTest.sol";
import { SmartWalletFactory } from "src/smartWallet/SmartWalletFactory.sol";
import { SmartWallet } from "src/smartWallet/SmartWallet.sol";
import { MultiSignerAuth } from "src/module/MultiSignerAuth.sol";
import { ISmartWalletFactory } from "src/interfaces/ISmartWalletFactory.sol";

contract FactoryTest is BaseTest {
  bytes32 constant USER_ID = keccak256("user1");
  bytes32 constant USER_ID2 = keccak256("user2");
  address owner = makeAddr("owner");

  // ═══════════════════════════════════════════════════════════════════════
  //  initialize / views
  // ═══════════════════════════════════════════════════════════════════════

  function test_initialize_setsCoordinator() public {
    assertEq(factory.coordinator(), address(coordinator));
  }

  function test_initialize_deploysBeacon() public {
    assertTrue(factory.beaconImplementation() != address(0));
  }

  function test_beaconImplementation_pointsToWalletImpl() public {
    address impl = UpgradeableBeacon(factory.beaconImplementation())
      .implementation();
    assertEq(impl, address(walletImpl));
  }

  function test_parameters_returnsEmpty() public {
    ISmartWalletFactory.Parameters memory p = factory.parameters();
    assertEq(p.wallet, address(0));
    assertEq(p.credentialId, 0);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  upgradeTo
  // ═══════════════════════════════════════════════════════════════════════

  function test_upgradeTo_updatesBeacon() public {
    SmartWallet newImpl = new SmartWallet();
    factory.upgradeTo(address(newImpl));
    address current = UpgradeableBeacon(
      factory.beaconImplementation()
    ).implementation();
    assertEq(current, address(newImpl));
  }

  function test_upgradeTo_emitsEvent() public {
    SmartWallet newImpl = new SmartWallet();
    vm.expectEmit(true, false, false, false, address(factory));
    emit SmartWalletFactory.ImplementationUpgraded(address(newImpl));
    factory.upgradeTo(address(newImpl));
  }

  function test_upgradeTo_revertsIfNotCoordinatorOwner() public {
    SmartWallet newImpl = new SmartWallet();
    vm.prank(makeAddr("notOwner"));
    vm.expectRevert(SmartWalletFactory.NotOwner.selector);
    factory.upgradeTo(address(newImpl));
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  deployWallet
  // ═══════════════════════════════════════════════════════════════════════

  function test_deployWallet_returnsNonZeroAddress() public {
    address addr = factory.deployWallet(USER_ID, owner);
    assertTrue(addr != address(0));
  }

  function test_deployWallet_revertsIfNotRelayer() public {
    vm.prank(makeAddr("notRelayer"));
    vm.expectRevert(SmartWalletFactory.NotRelayer.selector);
    factory.deployWallet(USER_ID, owner);
  }

  function test_deployWalletWithPasskey_revertsIfNotRelayer() public {
    SmartWalletFactory.InitialPasskey memory passkey = SmartWalletFactory
      .InitialPasskey({
        algo: ISmartWalletFactory.PasskeyAlgo.None,
        credentialId: 0,
        qx: 0,
        qy: 0,
        n: "",
        e: ""
      });

    vm.prank(makeAddr("notRelayer"));
    vm.expectRevert(SmartWalletFactory.NotRelayer.selector);
    factory.deployWalletWithPasskey(USER_ID, owner, passkey);
  }

  function test_getWalletsPage_windowing() public {
    address addr1 = factory.deployWallet(USER_ID, owner);
    address addr2 = factory.deployWallet(USER_ID2, owner);

    (SmartWalletFactory.WalletEntry[] memory page, uint256 total) = factory
      .getWalletsPage(1, 10);
    assertEq(total, 2);
    assertEq(page.length, 1);
    assertEq(page[0].walletId, USER_ID2);
    assertEq(page[0].wallet, addr2);

    (page, total) = factory.getWalletsPage(0, 1);
    assertEq(total, 2);
    assertEq(page.length, 1);
    assertEq(page[0].wallet, addr1);

    (page, total) = factory.getWalletsPage(5, 10);
    assertEq(total, 2);
    assertEq(page.length, 0);
  }

  function test_deployWallet_succeedsAfterRelayerRotation() public {
    address newRelayer = makeAddr("newRelayer");
    coordinator.setRelayer(newRelayer);

    // Old relayer (this test contract) is rejected.
    vm.expectRevert(SmartWalletFactory.NotRelayer.selector);
    factory.deployWallet(USER_ID, owner);

    // New relayer can deploy.
    vm.prank(newRelayer);
    address addr = factory.deployWallet(USER_ID, owner);
    assertTrue(addr != address(0));
  }

  function test_deployWallet_differentSaltsDifferentAddresses()
    public
  {
    address addr1 = factory.deployWallet(USER_ID, owner);
    address addr2 = factory.deployWallet(USER_ID2, owner);
    assertTrue(addr1 != addr2);
  }

  function test_deployWallet_deterministicBySalt() public {
    // Compute CREATE2 address directly with forge cheatcode
    bytes32 initCodeHash = keccak256(
      abi.encodePacked(
        type(BeaconProxy).creationCode,
        abi.encode(
          factory.beaconImplementation(),
          abi.encodeWithSignature("initialize()")
        )
      )
    );
    address predicted = vm.computeCreate2Address(
      USER_ID,
      initCodeHash,
      address(factory)
    );
    address deployed = factory.deployWallet(USER_ID, owner);
    assertEq(deployed, predicted);
  }

  function test_deployWallet_emitsWalletDeployed() public {
    bytes32 initCodeHash = keccak256(
      abi.encodePacked(
        type(BeaconProxy).creationCode,
        abi.encode(
          factory.beaconImplementation(),
          abi.encodeWithSignature("initialize()")
        )
      )
    );
    address predicted = vm.computeCreate2Address(
      USER_ID,
      initCodeHash,
      address(factory)
    );
    vm.expectEmit(true, true, false, false, address(factory));
    emit SmartWalletFactory.WalletDeployed(USER_ID, predicted);
    factory.deployWallet(USER_ID, owner);
  }

  function test_deployWallet_initializesOwner() public {
    SmartWallet wallet = _deployWallet(USER_ID, owner);
    assertTrue(wallet.isWalletOwner(owner));
  }

  function test_deployWallet_ownerIsNotWhitelistedAutomatically() public {
    SmartWallet wallet = _deployWallet(USER_ID, owner);
    assertEq(wallet.whitelist(owner), 0);
  }

  function test_deployWallet_clearsParametersAfterDeploy() public {
    factory.deployWallet(USER_ID, owner);
    ISmartWalletFactory.Parameters memory p = factory.parameters();
    assertEq(p.wallet, address(0));
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  deployWalletWithPasskey (ES256)
  // ═══════════════════════════════════════════════════════════════════════

  function test_deployWalletWithPasskey_es256_registersPasskeyOwner()
    public
  {
    bytes32 credentialId = keccak256("cred1");
    bytes32 qx = bytes32(uint256(1));
    bytes32 qy = bytes32(uint256(2));

    SmartWalletFactory.InitialPasskey
      memory passkey = SmartWalletFactory.InitialPasskey({
        algo: ISmartWalletFactory.PasskeyAlgo.ES256,
        credentialId: credentialId,
        qx: qx,
        qy: qy,
        n: "",
        e: ""
      });

    SmartWallet wallet = SmartWallet(
      payable(factory.deployWalletWithPasskey(USER_ID, owner, passkey))
    );
    MultiSignerAuth.OwnerEntry[] memory owners = wallet.getOwners();

    assertEq(owners.length, 2); // EOA + ES256
    assertEq(
      uint8(owners[1].ownerType),
      uint8(MultiSignerAuth.AuthType.ES256)
    );
    assertEq(owners[1].credentialId, credentialId);
    assertEq(owners[1].qx, qx);
    assertEq(owners[1].qy, qy);
  }

  function test_deployWalletWithPasskey_noPasskey_singleOwner()
    public
  {
    SmartWalletFactory.InitialPasskey
      memory passkey = SmartWalletFactory.InitialPasskey({
        algo: ISmartWalletFactory.PasskeyAlgo.None,
        credentialId: 0,
        qx: 0,
        qy: 0,
        n: "",
        e: ""
      });

    SmartWallet wallet = SmartWallet(
      payable(factory.deployWalletWithPasskey(USER_ID, owner, passkey))
    );
    assertEq(wallet.getOwners().length, 1);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  computeWalletAddress
  // ═══════════════════════════════════════════════════════════════════════

  function test_computeWalletAddress_matchesActualDeploy() public {
    address predicted = factory.computeWalletAddress(USER_ID);
    address deployed = factory.deployWallet(USER_ID, owner);
    assertEq(predicted, deployed);
  }

  function test_computeWalletAddress_predictsBeforeDeploy() public {
    address predicted = factory.computeWalletAddress(USER_ID);
    assertEq(predicted.code.length, 0); // no code yet
    factory.deployWallet(USER_ID, owner);
    assertTrue(predicted.code.length > 0); // code exists after deploy
  }

  function test_computeWalletAddress_differentSaltsDifferentAddresses()
    public
  {
    address a = factory.computeWalletAddress(USER_ID);
    address b = factory.computeWalletAddress(USER_ID2);
    assertTrue(a != b);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  getWallets / registry
  // ═══════════════════════════════════════════════════════════════════════

  function test_getWallets_emptyBeforeDeploy() public {
    assertEq(factory.getWallets().length, 0);
  }

  function test_getWallets_returnsDeployedEntries() public {
    address addr1 = factory.deployWallet(USER_ID, owner);
    address addr2 = factory.deployWallet(USER_ID2, owner);

    SmartWalletFactory.WalletEntry[] memory entries = factory.getWallets();
    assertEq(entries.length, 2);
    assertEq(entries[0].walletId, USER_ID);
    assertEq(entries[0].wallet, addr1);
    assertEq(entries[1].walletId, USER_ID2);
    assertEq(entries[1].wallet, addr2);
  }

  function test_userIdToWallet_populatedAfterDeploy() public {
    address addr = factory.deployWallet(USER_ID, owner);
    assertEq(factory.walletIdToWallet(USER_ID), addr);
  }

  function test_walletToUserId_populatedAfterDeploy() public {
    address addr = factory.deployWallet(USER_ID, owner);
    assertEq(factory.walletToWalletId(addr), USER_ID);
  }

  function test_userIdToWallet_zeroForUnknownId() public {
    assertEq(factory.walletIdToWallet(USER_ID), address(0));
  }
}
