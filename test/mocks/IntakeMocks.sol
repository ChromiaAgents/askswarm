// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Stand-in for Intake v2 when no mainnet fork is available. Etched at the real Intake address,
/// so it keeps no constructor state: configuration lives in immutables, which `vm.etch` copies with the code.
/// Mirrors what AskSwarmRegistry relies on: `priceOf`, `requestWithFailure` pulling exactly `amount`,
/// `requests`, `writer`, and `complete` calling the callback (status 0) or the failure hook (1, 2) once,
/// under a 200k gas stipend inside a try, emitting `Completed(..., delivered)`.
contract MockIntake {
    struct Req {
        address payer;
        address target;
        bytes4 selector;
        bytes4 onFailure;
        bool completed;
    }

    bytes32 public constant ACTION = bytes32("oracle.request@oracle-1");
    uint256 public constant PRICE = 0.5 ether;
    uint256 public constant STIPEND = 200_000;
    address public immutable writer;
    address public immutable imd;

    mapping(bytes32 => Req) internal _reqs;
    uint256 internal _nonce;

    event Completed(bytes32 indexed requestId, uint8 status, bytes32 resultHash, string uri, bool delivered);

    struct Callback {
        address target;
        bytes4 selector;
    }

    constructor(address writer_, address imd_) {
        writer = writer_;
        imd = imd_;
    }

    function priceOf(bytes32 action, address asset) public view returns (uint256) {
        return action == ACTION && asset == imd ? PRICE : 0;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 requestId) {
        uint256 p = priceOf(action, asset);
        require(p != 0 && amount == p, "ActionNotSold");
        require(MockERC20(asset).transferFrom(msg.sender, address(this), amount), "pull");
        requestId = keccak256(abi.encode(address(this), ++_nonce));
        _reqs[requestId] = Req(msg.sender, callback.target, callback.selector, onFailure, false);
    }

    function requests(bytes32 id) external view returns (address, address, bytes4, bool) {
        Req storage r = _reqs[id];
        return (r.payer, r.target, r.selector, r.completed);
    }

    function complete(bytes32 id, uint8 status, bytes32 resultHash, string calldata uri, bytes calldata args) external {
        require(msg.sender == writer, "NotWriter");
        Req storage r = _reqs[id];
        require(r.payer != address(0) && !r.completed, "BadRequest");
        r.completed = true;
        bytes4 sel = status == 0 ? r.selector : r.onFailure;
        bool delivered;
        if (r.target != address(0) && sel != bytes4(0)) {
            (delivered,) = r.target.call{gas: STIPEND}(abi.encodePacked(sel, args));
        }
        emit Completed(id, status, resultHash, uri, delivered);
    }
}

/// @notice Minimal ERC-20 for the IMD stand-in; `deal` finds its balance slot.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
