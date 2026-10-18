// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Test-only token: fail a selected caller's nth transfer/approval, after mutating balances.
/// This probes transaction atomicity; it does not claim that mainnet IMD has these behaviors.
contract WagerFaultToken {
    enum Reply {
        True,
        Empty,
        False,
        Revert,
        Short,
        NonBoolean
    }

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address private faultCaller;
    bytes4 private faultSelector;
    uint256 private faultOrdinal;
    uint256 public calls;
    Reply private reply;

    error TokenFailure();

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function configure(address caller, bytes4 selector, uint256 ordinal, Reply mode) external {
        faultCaller = caller;
        faultSelector = selector;
        faultOrdinal = ordinal;
        reply = mode;
        calls = 0;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return _reply();
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return _reply();
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[from][msg.sender];
        require(permitted >= amount, "allowance");
        if (permitted != type(uint256).max) allowance[from][msg.sender] = permitted - amount;
        _move(from, to, amount);
        return _reply();
    }

    function _move(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _reply() private returns (bool) {
        if (faultCaller != address(0) && faultCaller != msg.sender) return true;
        if (faultSelector != bytes4(0) && faultSelector != msg.sig) return true;
        ++calls;
        if (faultOrdinal != 0 && calls != faultOrdinal) return true;
        Reply mode = reply;
        if (mode == Reply.Revert) revert TokenFailure();
        if (mode == Reply.Empty) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (mode == Reply.Short) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (mode == Reply.NonBoolean) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return mode != Reply.False;
    }
}
