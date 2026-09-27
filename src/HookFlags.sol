// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HookFlags
/// @notice The 14 Uniswap v4 hook permission bits, as encoded in a hook's address, plus the helpers
/// the launch tooling and tests use to mine and check an address against a declared bit pattern.
/// @dev Mirrors `Hooks.*_FLAG` in v4-core exactly. It is a separate library so tooling that only
/// needs the bit layout does not have to import the whole `Hooks` library.
library HookFlags {
    uint160 internal constant BEFORE_INITIALIZE = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE = 1 << 12;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY = 1 << 10;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = 1 << 8;
    uint160 internal constant BEFORE_SWAP = 1 << 7;
    uint160 internal constant AFTER_SWAP = 1 << 6;
    uint160 internal constant BEFORE_DONATE = 1 << 5;
    uint160 internal constant AFTER_DONATE = 1 << 4;
    uint160 internal constant BEFORE_SWAP_RETURN_DELTA = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURN_DELTA = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURN_DELTA = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURN_DELTA = 1 << 0;

    /// @notice Mask covering every permission bit.
    uint160 internal constant ALL = (1 << 14) - 1;

    /// @notice The bits WhaleTaxHook is mined for: beforeSwap | afterSwap | afterSwapReturnDelta = 0x00C4.
    uint160 internal constant WHALE_TAX = BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURN_DELTA;

    /// @notice The permission bits carried by `hook`'s address.
    function flagsOf(address hook) internal pure returns (uint160) {
        return uint160(hook) & ALL;
    }

    /// @notice True when `hook`'s address carries exactly `flags` (all 14 bits compared, so an
    /// address advertising an extra permission does not match).
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return flagsOf(hook) == (flags & ALL);
    }
}
