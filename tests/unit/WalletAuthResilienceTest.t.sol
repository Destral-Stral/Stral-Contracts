// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "fixtures/BaseTest.sol";
import {SmartWallet} from "src/smartWallet/SmartWallet.sol";
import {MultiSignerAuth} from "src/module/MultiSignerAuth.sol";

contract WalletAuthResilienceTest is BaseTest {
    uint256 ownerKey = uint256(keccak256("ownerKey"));
    address owner;
    SmartWallet wallet;

    function setUp() public override {
        super.setUp();
        owner = vm.addr(ownerKey);
        wallet = _deployWallet(keccak256("wallet"), owner);
        token.mint(address(wallet), 1_000 ether);
    }

    function test_eoaSig_revertsWhenSignedForAnotherWallet() public {
        SmartWallet otherWallet = _deployWallet(keccak256("otherWallet"), owner);
        address recipient = makeAddr("recipient");
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("AddToWhitelist(address recipient,uint256 nonce,uint256 deadline)"),
                recipient,
                wallet.nonce(),
                NO_DEADLINE
            )
        );

        vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
        wallet.addToWhitelist(recipient, NO_DEADLINE, _signedAuth(address(otherWallet), structHash));

        assertEq(wallet.nonce(), 0);
        assertEq(wallet.whitelist(recipient), 0);
    }

    function test_eoaSig_revertsWhenSignedWithFutureNonce() public {
        address recipient = makeAddr("recipient");
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("AddToWhitelist(address recipient,uint256 nonce,uint256 deadline)"),
                recipient,
                wallet.nonce() + 1,
                NO_DEADLINE
            )
        );

        vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
        wallet.addToWhitelist(recipient, NO_DEADLINE, _signedAuth(address(wallet), structHash));

        assertEq(wallet.nonce(), 0);
    }

    function test_eoaSig_revertsWhenReusedForDifferentOperation() public {
        address recipient = makeAddr("recipient");
        bytes32 addStructHash = keccak256(
            abi.encode(
                keccak256("AddToWhitelist(address recipient,uint256 nonce,uint256 deadline)"),
                recipient,
                wallet.nonce(),
                NO_DEADLINE
            )
        );

        vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
        wallet.withdrawAssets(
            recipient, address(token), 1 ether, NO_DEADLINE, _signedAuth(address(wallet), addStructHash)
        );

        assertEq(wallet.nonce(), 0);
    }

    function test_eoaSig_revertsWithoutConsumingNonceForWrongSigner() public {
        uint256 wrongKey = uint256(keccak256("wrongKey"));
        address recipient = makeAddr("recipient");
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("AddToWhitelist(address recipient,uint256 nonce,uint256 deadline)"),
                recipient,
                wallet.nonce(),
                NO_DEADLINE
            )
        );
        bytes32 digest = _walletDigest(address(wallet), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        MultiSignerAuth.Auth memory auth =
            MultiSignerAuth.Auth({authType: MultiSignerAuth.AuthType.EOASig, payload: abi.encodePacked(r, s, v)});

        vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
        wallet.addToWhitelist(recipient, NO_DEADLINE, auth);

        assertEq(wallet.nonce(), 0);
    }

    function test_eoaSig_revertsWithoutConsumingNonceForMalformedPayload() public {
        MultiSignerAuth.Auth memory auth =
            MultiSignerAuth.Auth({authType: MultiSignerAuth.AuthType.EOASig, payload: hex"1234"});

        vm.expectRevert();
        wallet.addToWhitelist(makeAddr("recipient"), NO_DEADLINE, auth);

        assertEq(wallet.nonce(), 0);
    }

    function test_eoaSig_revertsWithoutConsumingNonceAfterDeadline() public {
        address recipient = makeAddr("recipient");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("AddToWhitelist(address recipient,uint256 nonce,uint256 deadline)"),
                recipient,
                wallet.nonce(),
                deadline
            )
        );
        MultiSignerAuth.Auth memory auth = _signedAuth(address(wallet), structHash);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(MultiSignerAuth.SignatureExpired.selector, deadline));
        wallet.addToWhitelist(recipient, deadline, auth);

        assertEq(wallet.nonce(), 0);
    }

    function test_eoaSig_succeedsExactlyAtDeadline() public {
        address recipient = makeAddr("recipient");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("AddToWhitelist(address recipient,uint256 nonce,uint256 deadline)"),
                recipient,
                wallet.nonce(),
                deadline
            )
        );
        MultiSignerAuth.Auth memory auth = _signedAuth(address(wallet), structHash);

        vm.warp(deadline);
        wallet.addToWhitelist(recipient, deadline, auth);

        assertEq(wallet.nonce(), 1);
        assertEq(wallet.whitelist(recipient), block.timestamp);
    }

    function test_eoaSig_deadlineMismatchBetweenArgAndSigReverts() public {
        address recipient = makeAddr("recipient");
        uint256 signedDeadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("AddToWhitelist(address recipient,uint256 nonce,uint256 deadline)"),
                recipient,
                wallet.nonce(),
                signedDeadline
            )
        );
        MultiSignerAuth.Auth memory auth = _signedAuth(address(wallet), structHash);

        // Passing a different deadline than the signed one changes the digest -> recovery fails.
        vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
        wallet.addToWhitelist(recipient, signedDeadline + 1, auth);

        assertEq(wallet.nonce(), 0);
    }

    function test_eoaSig_validTransferAssetsConsumesNonce() public {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("TransferAssets(address assets,uint256 amount,uint256 nonce,uint256 deadline)"),
                address(token),
                12 ether,
                wallet.nonce(),
                NO_DEADLINE
            )
        );

        wallet.transferAssets(address(token), 12 ether, NO_DEADLINE, _signedAuth(address(wallet), structHash));

        assertEq(wallet.nonce(), 1);
        assertEq(token.balanceOf(strategy), 12 ether);
    }

    function test_eoaSig_validWithdrawAssetsConsumesNonce() public {
        vm.prank(owner);
        wallet.addToWhitelist(owner, NO_DEADLINE, _directAuth());
        vm.warp(block.timestamp + DELAY + 1);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("WithdrawAssets(address to,address assets,uint256 amount,uint256 nonce,uint256 deadline)"),
                owner,
                address(token),
                12 ether,
                wallet.nonce(),
                NO_DEADLINE
            )
        );

        wallet.withdrawAssets(owner, address(token), 12 ether, NO_DEADLINE, _signedAuth(address(wallet), structHash));

        assertEq(wallet.nonce(), 1);
        assertEq(token.balanceOf(owner), 12 ether);
    }

    function test_directRemovingLastOwnerReverts() public {
        vm.prank(owner);
        vm.expectRevert(MultiSignerAuth.CannotRemoveLastOwner.selector);
        wallet.removeWalletOwner(owner, NO_DEADLINE, _directAuth());

        assertTrue(wallet.isWalletOwner(owner));
        assertEq(wallet.getOwners().length, 1);
    }

    function test_directRemovingNonLastOwnerSucceeds() public {
        address secondOwner = makeAddr("secondOwner");
        vm.prank(owner);
        wallet.addWalletOwner(secondOwner, NO_DEADLINE, _directAuth());

        vm.prank(owner);
        wallet.removeWalletOwner(owner, NO_DEADLINE, _directAuth());

        assertFalse(wallet.isWalletOwner(owner));
        assertTrue(wallet.isWalletOwner(secondOwner));
        assertEq(wallet.getOwners().length, 1);
    }

    function _signedAuth(address verifyingContract, bytes32 structHash)
        private
        view
        returns (MultiSignerAuth.Auth memory)
    {
        bytes32 digest = _walletDigest(verifyingContract, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        return MultiSignerAuth.Auth({authType: MultiSignerAuth.AuthType.EOASig, payload: abi.encodePacked(r, s, v)});
    }
}
