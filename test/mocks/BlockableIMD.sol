// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Stand-in for Robinhood Chain's IMD (0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127), an owner-controlled
/// OFT with `setBlocked(address,bool)`: any transfer to or from a blocked address reverts.
contract BlockableIMD {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;
    address public owner = msg.sender;

    function setBlocked(address a, bool b) external {
        require(msg.sender == owner, "owner");
        blocked[a] = b;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(!blocked[from] && !blocked[to], "blocked");
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
