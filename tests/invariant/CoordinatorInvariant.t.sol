// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts-5/proxy/ERC1967/ERC1967Proxy.sol";
import {SmartWalletCoordinator} from "src/smartWallet/SmartWalletCoordinator.sol";

contract CoordinatorHandler is Test {
    SmartWalletCoordinator public coordinator;
    address[8] public wallets;
    address[8] public tokens;

    constructor() {
        address[] memory tokens_ = new address[](0);
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
                                allowedTokens: tokens_,
                                stakingToken: address(0),
                                stakingContract: address(0),
                                vestingContract: address(0),
                                relayer: address(0)
                            })
                        )
                    )
                )
            )
        );

        for (uint256 i = 0; i < 8; i++) {
            wallets[i] = makeAddr(string.concat("wallet", vm.toString(i)));
            tokens[i] = makeAddr(string.concat("token", vm.toString(i)));
        }
    }

    function allowToken(uint256 seed) public {
        coordinator.allowToken(tokens[seed % tokens.length]);
    }

    function disallowToken(uint256 seed) public {
        coordinator.disallowToken(tokens[seed % tokens.length]);
    }

    function blockWallet(uint256 seed) public {
        coordinator.blockWallet(wallets[seed % wallets.length]);
    }

    function unblockWallet(uint256 seed) public {
        coordinator.unblockWallet(wallets[seed % wallets.length]);
    }
}

contract CoordinatorInvariantTest is StdInvariant, Test {
    CoordinatorHandler handler;
    SmartWalletCoordinator coordinator;

    function setUp() public {
        handler = new CoordinatorHandler();
        coordinator = handler.coordinator();
        targetContract(address(handler));
    }

    function invariant_allowedTokenListMatchesMapping() public view {
        address[] memory tokens = coordinator.getAllowedTokens();

        for (uint256 i = 0; i < tokens.length; i++) {
            assertTrue(coordinator.allowedTokens(tokens[i]));
            for (uint256 j = i + 1; j < tokens.length; j++) {
                assertTrue(tokens[i] != tokens[j]);
            }
        }

        for (uint256 i = 0; i < 8; i++) {
            address token = handler.tokens(i);
            assertEq(coordinator.allowedTokens(token), _contains(tokens, token));
        }
    }

    function invariant_blockedWalletListMatchesMapping() public view {
        address[] memory wallets = coordinator.getBlockedWallets();

        for (uint256 i = 0; i < wallets.length; i++) {
            assertTrue(coordinator.blocked(wallets[i]));
            for (uint256 j = i + 1; j < wallets.length; j++) {
                assertTrue(wallets[i] != wallets[j]);
            }
        }

        for (uint256 i = 0; i < 8; i++) {
            address wallet = handler.wallets(i);
            assertEq(coordinator.blocked(wallet), _contains(wallets, wallet));
        }
    }

    function _contains(address[] memory list, address value) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == value) return true;
        }
        return false;
    }
}
