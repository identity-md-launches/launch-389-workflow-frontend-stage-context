// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {WhaleToken} from "../src/WhaleToken.sol";
import {WhaleTaxHook} from "../src/WhaleTaxHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @title DeployWhaleTax
/// @notice Reference deployment of WHAL and WhaleTaxHook. The launch factory performs the real
/// Sepolia deployment with the same creation code and a salt mined the same way; this script is
/// the reviewable rehearsal of that shape and a manual fallback. It holds no secrets: every
/// parameter is a constant here, and `run()` reads nothing from the environment.
///
/// Under `forge script --broadcast`, a salted `new` goes through the deterministic CREATE2 deployer
/// proxy, so the salt is mined against that proxy's address. When `deploy` is called directly (as
/// the tests do), the CREATE2 sender is this contract, so pass `address(this)` as `create2Deployer`.
contract DeployWhaleTax is Script {
    /// @notice Uniswap v4 PoolManager on Sepolia (chain id 11155111).
    address public constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    /// @notice The deterministic CREATE2 deployer proxy forge routes salted creates through.
    address public constant CREATE2_DEPLOYER_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 public constant MAX_SALT_ATTEMPTS = 2_000_000;

    struct Config {
        IPoolManager poolManager;
        address create2Deployer;
    }

    struct Deployment {
        WhaleToken token;
        WhaleTaxHook hook;
        bytes32 hookSalt;
    }

    function run() external returns (Deployment memory deployment) {
        Config memory cfg =
            Config({poolManager: IPoolManager(SEPOLIA_POOL_MANAGER), create2Deployer: CREATE2_DEPLOYER_PROXY});
        vm.startBroadcast();
        deployment = deploy(cfg);
        vm.stopBroadcast();
    }

    /// @notice The hook's full creation code for a given PoolManager: what the factory attests.
    function hookCreationCode(IPoolManager poolManager) public pure returns (bytes memory) {
        return abi.encodePacked(type(WhaleTaxHook).creationCode, abi.encode(poolManager));
    }

    /// @notice Mines the salt that places the hook on an address with exactly the 0x00C4 bits.
    function mineSalt(Config memory cfg) public pure returns (address hook, bytes32 salt) {
        return
            HookMiner.find(
                cfg.create2Deployer, HookFlags.WHALE_TAX, hookCreationCode(cfg.poolManager), MAX_SALT_ATTEMPTS
            );
    }

    /// @notice Deploys the token (supply to the caller) and the hook at its mined address.
    function deploy(Config memory cfg) public returns (Deployment memory deployment) {
        deployment.token = new WhaleToken();
        (address predicted, bytes32 salt) = mineSalt(cfg);
        deployment.hookSalt = salt;
        deployment.hook = new WhaleTaxHook{salt: salt}(cfg.poolManager);
        require(address(deployment.hook) == predicted, "hook address mismatch");
    }
}
