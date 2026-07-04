// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal mintable ERC20 standing in for the LINK token during local tests.
contract MockLinkToken is ERC20 {
    constructor() ERC20("Chainlink Token", "LINK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
