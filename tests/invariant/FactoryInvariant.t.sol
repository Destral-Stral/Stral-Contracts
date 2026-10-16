// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts-5/proxy/ERC1967/ERC1967Proxy.sol";
import {SmartWallet} from "src/smartWallet/SmartWallet.sol";
import {SmartWalletCoordinator} from "src/smartWallet/SmartWalletCoordinator.sol";
import {SmartWalletFactory} from "src/smartWallet/SmartWalletFactory.sol";

contract FactoryHandler is Test {
    SmartWalletCoordinator public coordinator;
    SmartWalletFactory public factory;
    SmartWallet public walletImpl;

    bytes32[8] public userIds;
    address[8] public owners;
    bytes32[] public deployedIds;
    mapping(bytes32 => bool) public deployed;

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
        walletImpl = new SmartWallet();
        factory = SmartWalletFactory(
            address(
                new ERC1967Proxy(
                    address(new SmartWalletFactory()),
                    abi.encodeCall(
                        SmartWalletFactory.initialize,
                        (address(coordinator), address(walletImpl))
                    )
                )
            )
        );
        coordinator.setFactory(address(factory));

        for (uint256 i = 0; i < 8; i++) {
            userIds[i] = keccak256(abi.encode("user", i));
            owners[i] = makeAddr(string.concat("owner", vm.toString(i)));
        }
    }

    function deployWallet(uint256 seed) public {
        uint256 index = seed % userIds.length;
        bytes32 userId = userIds[index];
        if (deployed[userId]) return;

        factory.deployWallet(userId, owners[index]);
        deployed[userId] = true;
        deployedIds.push(userId);
    }

    function deployedIdsLength() external view returns (uint256) {
        return deployedIds.length;
    }
}

contract FactoryInvariantTest is StdInvariant, Test {
    FactoryHandler handler;
    SmartWalletFactory factory;

    function setUp() public {
        handler = new FactoryHandler();
        factory = handler.factory();
        targetContract(address(handler));
    }

    function invariant_walletRegistryIsSymmetric() public view {
        uint256 len = handler.deployedIdsLength();
        SmartWalletFactory.WalletEntry[] memory entries = factory.getWallets();

        assertEq(entries.length, len);

        for (uint256 i = 0; i < len; i++) {
            bytes32 userId = handler.deployedIds(i);
            address wallet = factory.walletIdToWallet(userId);

            assertTrue(wallet != address(0));
            assertEq(factory.walletToWalletId(wallet), userId);
            assertEq(entries[i].walletId, userId);
            assertEq(entries[i].wallet, wallet);
        }
    }
}
