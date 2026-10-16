// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "fixtures/BaseTest.sol";
import {SmartWallet} from "src/smartWallet/SmartWallet.sol";
import {MultiSignerAuth} from "src/module/MultiSignerAuth.sol";
import {RevertingERC20, FalseReturnERC20, FeeOnTransferERC20} from "fixtures/AdversarialTokens.sol";
import {ReentrantStaking} from "fixtures/ReentrantStaking.sol";

contract WalletAdversarialTest is BaseTest {
    SmartWallet wallet;
    address owner = makeAddr("owner");

    function setUp() public override {
        super.setUp();
        wallet = _deployWallet(keccak256("wallet"), owner);
    }

    function test_transferAssets_revertsWhenAllowedTokenReverts() public {
        RevertingERC20 badToken = new RevertingERC20();
        badToken.mint(address(wallet), 100 ether);
        coordinator.allowToken(address(badToken));

        vm.prank(owner);
        vm.expectRevert(RevertingERC20.TransferFailed.selector);
        wallet.transferAssets(address(badToken), 10 ether, NO_DEADLINE, _directAuth());
    }

    function test_transferAssets_revertsWhenAllowedTokenReturnsFalse() public {
        FalseReturnERC20 badToken = new FalseReturnERC20();
        badToken.mint(address(wallet), 100 ether);
        coordinator.allowToken(address(badToken));

        vm.prank(owner);
        vm.expectRevert();
        wallet.transferAssets(address(badToken), 10 ether, NO_DEADLINE, _directAuth());
    }

    function test_withdrawAssets_respectsFeeOnTransferBehavior() public {
        address feeSink = makeAddr("feeSink");
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20(feeSink);
        feeToken.mint(address(wallet), 100 ether);
        coordinator.allowToken(address(feeToken));

        vm.prank(owner);
        wallet.addToWhitelist(owner, NO_DEADLINE, _directAuth());
        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(owner);
        wallet.withdrawAssets(owner, address(feeToken), 10 ether, NO_DEADLINE, _directAuth());

        assertEq(feeToken.balanceOf(owner), 9.9 ether);
        assertEq(feeToken.balanceOf(feeSink), 0.1 ether);
        assertEq(feeToken.balanceOf(address(wallet)), 90 ether);
    }

    function test_stake_revertsWhenTokenTransferFromReturnsFalse() public {
        FalseReturnERC20 badToken = new FalseReturnERC20();
        ReentrantStaking staking = new ReentrantStaking(badToken);
        badToken.mint(address(wallet), 100 ether);
        coordinator.setStakingToken(address(badToken));
        coordinator.setStakingContract(address(staking));

        vm.prank(owner);
        vm.expectRevert();
        wallet.stake(10 ether, NO_DEADLINE, _directAuth());
    }

    function test_stake_reentrantDirectAuthAttemptDoesNotDrainStrategy() public {
        ReentrantStaking staking = new ReentrantStaking(token);
        token.mint(address(wallet), 100 ether);
        coordinator.setStakingToken(address(token));
        coordinator.setStakingContract(address(staking));

        vm.prank(owner);
        wallet.stake(10 ether, NO_DEADLINE, _directAuth());

        assertTrue(staking.attempted());
        assertFalse(staking.reentered());
        assertEq(token.balanceOf(strategy), 0);
        assertEq(token.balanceOf(address(staking)), 10 ether);
    }

    function test_withdrawAssets_succeedsExactlyAtDelayBoundary() public {
        address recipient = makeAddr("recipient");
        token.mint(address(wallet), 100 ether);

        vm.prank(owner);
        wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());
        uint256 addedAt = wallet.whitelist(recipient);

        vm.warp(addedAt + DELAY - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SmartWallet.WithdrawalDelayNotMet.selector, addedAt + DELAY));
        wallet.withdrawAssets(recipient, address(token), 1 ether, NO_DEADLINE, _directAuth());

        vm.warp(addedAt + DELAY);
        vm.prank(owner);
        wallet.withdrawAssets(recipient, address(token), 1 ether, NO_DEADLINE, _directAuth());

        assertEq(token.balanceOf(recipient), 1 ether);
    }

    function test_withdrawAssets_usesCurrentCoordinatorDelay() public {
        address recipient = makeAddr("recipient");
        token.mint(address(wallet), 100 ether);

        vm.prank(owner);
        wallet.addToWhitelist(recipient, NO_DEADLINE, _directAuth());
        uint256 addedAt = wallet.whitelist(recipient);
        coordinator.setWithdrawalDelay(2 days);

        vm.warp(addedAt + DELAY + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SmartWallet.WithdrawalDelayNotMet.selector, addedAt + 2 days));
        wallet.withdrawAssets(recipient, address(token), 1 ether, NO_DEADLINE, _directAuth());
    }
}
