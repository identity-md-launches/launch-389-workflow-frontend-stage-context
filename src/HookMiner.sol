// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "./HookFlags.sol";

/// @title HookMiner
/// @notice Finds a CREATE2 salt that places a hook on an address carrying exactly the requested
/// permission bits. Used by the deploy script and by the tests; it is never deployed.
library HookMiner {
    error NoSaltFound(uint160 flags, uint256 attempts);

    /// @notice Predicts the CREATE2 address of `initCodeHash` deployed by `deployer` with `salt`.
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @notice Scans salts `0, 1, 2, ...` until one produces an address whose low 14 bits equal
    /// `flags` exactly (all other permission bits clear).
    /// @param deployer The address that will execute CREATE2 (the factory, the deterministic deployer proxy, or a test).
    /// @param flags The permission bits the address must carry, e.g. `HookFlags.WHALE_TAX`.
    /// @param creationCode The full creation code, constructor arguments included.
    /// @param maxAttempts Upper bound on salts tried before reverting.
    function find(address deployer, uint160 flags, bytes memory creationCode, uint256 maxAttempts)
        internal
        pure
        returns (address hook, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < maxAttempts; i++) {
            salt = bytes32(i);
            hook = computeAddress(deployer, salt, initCodeHash);
            if (HookFlags.matches(hook, flags)) return (hook, salt);
        }
        revert NoSaltFound(flags, maxAttempts);
    }
}
