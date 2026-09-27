// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Whale Tax (WHAL)
/// @notice Fixed-supply ERC-20. The whole supply of 1,000,000,000 WHAL (18 decimals) is minted once,
/// in the constructor, to the deployer. There is no owner, no admin, no mint, no burn, no pause and
/// no upgrade path: after construction the contract is a plain OpenZeppelin ERC-20 and nothing else.
/// @dev Zero constructor arguments so the launch factory can deploy it and receive the supply.
contract WhaleToken is ERC20 {
    /// @notice The only supply that will ever exist.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Whale Tax", "WHAL") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
