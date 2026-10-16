// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UpgradeableBeacon} from "@openzeppelin/contracts-5/proxy/beacon/UpgradeableBeacon.sol";
import {BaseTest} from "fixtures/BaseTest.sol";
import {SmartWallet} from "src/smartWallet/SmartWallet.sol";
import {SmartWalletFactory} from "src/smartWallet/SmartWalletFactory.sol";
import {MultiSignerAuth} from "src/module/MultiSignerAuth.sol";
import {ISmartWalletFactory} from "src/interfaces/ISmartWalletFactory.sol";

contract FactoryResilienceTest is BaseTest {
    bytes32 constant USER_ID = keccak256("user1");
    address owner = makeAddr("owner");

    function test_deployWallet_revertsForDuplicateUserId() public {
        factory.deployWallet(USER_ID, owner);

        vm.expectRevert();
        factory.deployWallet(USER_ID, owner);
    }

    function test_deployWalletWithPasskey_rs256_registersPasskeyOwner() public {
        bytes memory n = new bytes(256);
        bytes memory e = hex"010001";
        bytes32 credentialId = keccak256("rsaCred");
        n[0] = 0x01;

        SmartWalletFactory.InitialPasskey memory passkey = SmartWalletFactory.InitialPasskey({
            algo: ISmartWalletFactory.PasskeyAlgo.RS256,
            credentialId: credentialId,
            qx: 0,
            qy: 0,
            n: n,
            e: e
        });

        SmartWallet wallet = SmartWallet(payable(factory.deployWalletWithPasskey(USER_ID, owner, passkey)));
        MultiSignerAuth.OwnerEntry[] memory owners = wallet.getOwners();

        assertEq(owners.length, 2);
        assertEq(uint8(owners[1].ownerType), uint8(MultiSignerAuth.AuthType.RS256));
        assertEq(owners[1].credentialId, credentialId);
        assertEq(owners[1].n, n);
        assertEq(owners[1].e, e);
    }

    function test_upgradeTo_preservesExistingWalletState() public {
        SmartWallet wallet = _deployWallet(USER_ID, owner);
        address recipient = makeAddr("recipient");
        token.mint(address(wallet), 100 ether);

        vm.prank(owner);
        wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());
        uint256 addedAt = wallet.whitelist(recipient);

        SmartWallet newImpl = new SmartWallet();
        factory.upgradeTo(address(newImpl));

        assertEq(UpgradeableBeacon(factory.beaconImplementation()).implementation(), address(newImpl));
        assertEq(address(wallet.factory()), address(factory));
        assertEq(address(wallet.coordinator()), address(coordinator));
        assertTrue(wallet.isWalletOwner(owner));
        assertEq(wallet.whitelist(owner), 0);
        assertEq(wallet.whitelist(recipient), addedAt);
        assertEq(token.balanceOf(address(wallet)), 100 ether);
    }

    function test_deployWallet_revertsWithoutAnyOwner() public {
        vm.expectRevert(SmartWallet.NoInitialOwner.selector);
        factory.deployWallet(USER_ID, address(0));
    }

    function test_deployWalletWithPasskey_passkeyOnly_es256() public {
        bytes32 credentialId = keccak256("soloCred");
        SmartWalletFactory.InitialPasskey memory passkey = SmartWalletFactory.InitialPasskey({
            algo: ISmartWalletFactory.PasskeyAlgo.ES256,
            credentialId: credentialId,
            qx: bytes32(uint256(10)),
            qy: bytes32(uint256(20)),
            n: "",
            e: ""
        });

        SmartWallet wallet = SmartWallet(payable(factory.deployWalletWithPasskey(USER_ID, address(0), passkey)));
        MultiSignerAuth.OwnerEntry[] memory owners = wallet.getOwners();

        assertEq(owners.length, 1);
        assertEq(uint8(owners[0].ownerType), uint8(MultiSignerAuth.AuthType.ES256));
        assertEq(owners[0].credentialId, credentialId);

        // No EOA owner and no whitelist entry.
        (address[] memory recipients,) = wallet.getWhitelist();
        assertEq(recipients.length, 0);
    }

    function test_deployWalletWithPasskey_passkeyOnly_emptyEs256KeyReverts() public {
        SmartWalletFactory.InitialPasskey memory passkey = SmartWalletFactory.InitialPasskey({
            algo: ISmartWalletFactory.PasskeyAlgo.ES256,
            credentialId: keccak256("emptyCred"),
            qx: 0,
            qy: 0,
            n: "",
            e: ""
        });

        vm.expectRevert(SmartWallet.NoInitialOwner.selector);
        factory.deployWalletWithPasskey(USER_ID, address(0), passkey);
    }

    function test_deployWalletWithPasskey_passkeyOnly_emptyRs256KeyReverts() public {
        SmartWalletFactory.InitialPasskey memory passkey = SmartWalletFactory.InitialPasskey({
            algo: ISmartWalletFactory.PasskeyAlgo.RS256,
            credentialId: keccak256("emptyRsaCred"),
            qx: 0,
            qy: 0,
            n: "",
            e: ""
        });

        vm.expectRevert(SmartWallet.NoInitialOwner.selector);
        factory.deployWalletWithPasskey(USER_ID, address(0), passkey);
    }

    function test_deployWalletWithPasskey_noneIgnoresPasskeyFields() public {
        SmartWalletFactory.InitialPasskey memory passkey = SmartWalletFactory.InitialPasskey({
            algo: ISmartWalletFactory.PasskeyAlgo.None,
            credentialId: keccak256("ignoredCred"),
            qx: bytes32(uint256(1)),
            qy: bytes32(uint256(2)),
            n: hex"01",
            e: hex"010001"
        });

        SmartWallet wallet = SmartWallet(payable(factory.deployWalletWithPasskey(USER_ID, owner, passkey)));

        assertEq(wallet.getOwners().length, 1);
        assertTrue(wallet.isWalletOwner(owner));
    }
}
