// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts-5/proxy/ERC1967/ERC1967Proxy.sol";
import {SmartWalletCoordinator} from "src/smartWallet/SmartWalletCoordinator.sol";
import {SmartWalletFactory} from "src/smartWallet/SmartWalletFactory.sol";
import {SmartWallet} from "src/smartWallet/SmartWallet.sol";
import {MultiSignerAuth} from "src/module/MultiSignerAuth.sol";
import {MockERC20} from "fixtures/MockERC20.sol";

/// @dev Shared fixture: coordinator + factory + wallet implementation + allowed token.
///      All tests inherit from this. Admin is the test contract itself (coordinator.owner())
///      and also acts as the relayer allowed to deploy wallets.
///      Implementations disable initializers, so contracts are deployed behind proxies with
///      atomic initialization — mirroring the production deployment.
abstract contract BaseTest is Test {
    SmartWalletCoordinator coordinator;
    SmartWalletFactory factory;
    SmartWallet walletImpl;
    MockERC20 token;

    address strategy = makeAddr("strategy");
    uint256 constant DELAY = 1 days;
    /// @dev Deadline placeholder for tests that don't exercise expiry (ignored for Direct auth).
    uint256 constant NO_DEADLINE = type(uint256).max;

    function setUp() public virtual {
        // Forge defaults to block.timestamp = 1, which collides with the whitelist sentinel value 1.
        // Warp to a realistic timestamp so addToWhitelist entries are unambiguously > 1.
        vm.warp(1_000_000);

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
        coordinator.setStrategyAddress(strategy);
        coordinator.setWithdrawalDelay(DELAY);

        token = new MockERC20("Test Token", "TST");
        coordinator.allowToken(address(token));
    }

    /// @dev Returns a Direct-auth credential (msg.sender must be a registered wallet owner).
    function _directAuth() internal pure returns (MultiSignerAuth.Auth memory) {
        return MultiSignerAuth.Auth({authType: MultiSignerAuth.AuthType.Direct, payload: ""});
    }

    /// @dev Deploys a SmartWallet via the factory for the given EOA owner.
    function _deployWallet(bytes32 userId, address owner) internal returns (SmartWallet) {
        return SmartWallet(payable(factory.deployWallet(userId, owner)));
    }

    /// @dev Computes the EIP-712 domain separator for a SmartWallet proxy.
    ///      SmartWallet uses name="SmartWallet" version="1" (set in __MultiSignerAuth_init).
    function _walletDomainSeparator(address walletAddr) internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("SmartWallet")),
            keccak256(bytes("1")),
            block.chainid,
            walletAddr
        ));
    }

    /// @dev Builds a full EIP-712 digest for a SmartWallet struct hash.
    function _walletDigest(address walletAddr, bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _walletDomainSeparator(walletAddr), structHash));
    }
}
