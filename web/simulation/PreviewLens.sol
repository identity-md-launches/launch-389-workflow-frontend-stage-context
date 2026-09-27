// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

struct Key { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
struct Params { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
interface Manager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(Key calldata key, Params calldata params, bytes calldata hookData) external returns (int256);
}
interface State {
    function getSlot0(bytes32 id) external view returns (uint160, int24, uint24, uint24);
}
interface Hook {
    function accruedFees(address currency) external view returns (uint256);
    function priceMoveBps(uint160 beforePrice, uint160 afterPrice) external pure returns (uint256);
    function feeBpsForMove(uint256 move) external pure returns (uint256);
}
/// @notice Ephemeral eth_call-only lens. Supplied as a code state override, NEVER deployed.
/// The callback always reverts, rolling back the swap before settlement is required.
/// Does not fake liquidity, balances, prices, token storage or hook state.
contract PreviewLens {
    error PreviewResult(bytes result);
    error UnexpectedUnlock();
    function quote(address manager, address state, Key calldata key, Params calldata params)
        external returns (int256 delta, uint160 beforePrice, uint160 afterPrice, uint256 move, uint256 rate, uint256 fee)
    {
        try Manager(manager).unlock(abi.encode(manager, state, key, params)) { revert UnexpectedUnlock(); }
        catch (bytes memory reason) {
            bytes4 selector;
            assembly ("memory-safe") { selector := mload(add(reason, 32)) }
            if (selector != PreviewResult.selector) {
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            }
            bytes memory payload = new bytes(reason.length - 4);
            for (uint256 i; i < payload.length; ++i) payload[i] = reason[i + 4];
            return abi.decode(abi.decode(payload, (bytes)), (int256, uint160, uint160, uint256, uint256, uint256));
        }
    }
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        (address manager, address state, Key memory key, Params memory params) = abi.decode(raw, (address, address, Key, Params));
        require(msg.sender == manager, "Only manager");
        bytes32 id = keccak256(abi.encode(key));
        (uint160 beforePrice,,,) = State(state).getSlot0(id);
        address currency = params.zeroForOne ? key.currency1 : key.currency0;
        uint256 prior = Hook(key.hooks).accruedFees(currency);
        int256 delta = Manager(manager).swap(key, params, "");
        (uint160 afterPrice,,,) = State(state).getSlot0(id);
        uint256 move = Hook(key.hooks).priceMoveBps(beforePrice, afterPrice);
        revert PreviewResult(abi.encode(delta, beforePrice, afterPrice, move, Hook(key.hooks).feeBpsForMove(move), Hook(key.hooks).accruedFees(currency) - prior));
    }
}
