// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

/// @notice Test router that performs several swaps on one pool inside a single `unlock`, settling
/// the net position once at the end. Exists to exercise the hook's transient slot across swaps in
/// one transaction.
contract BatchSwapRouter is IUnlockCallback {
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    struct CallbackData {
        address payer;
        PoolKey key;
        SwapParams[] swaps;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swapMany(PoolKey memory key, SwapParams[] memory swaps)
        external
        payable
        returns (BalanceDelta[] memory deltas)
    {
        deltas = abi.decode(manager.unlock(abi.encode(CallbackData(msg.sender, key, swaps))), (BalanceDelta[]));
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta[] memory deltas = new BalanceDelta[](data.swaps.length);
        for (uint256 i = 0; i < data.swaps.length; i++) {
            deltas[i] = manager.swap(data.key, data.swaps[i], "");
        }

        _settle(data.key.currency0, data.payer);
        _settle(data.key.currency1, data.payer);
        return abi.encode(deltas);
    }

    function _settle(Currency currency, address payer) internal {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) currency.settle(manager, payer, uint256(-delta), false);
        if (delta > 0) currency.take(manager, payer, uint256(delta), false);
    }
}
