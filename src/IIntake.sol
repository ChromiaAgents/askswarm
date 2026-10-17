// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The parts of IdentityMD Intake v2 (0xa43e6f75ee006411f79ac1c84120606c2330de82, same address on
/// every chain) that AskSwarmRegistry calls. Verified source: eth.blockscout.com, contract "Intake".
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId);

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 requestId);

    function priceOf(bytes32 action, address asset) external view returns (uint256);
    function writer() external view returns (address);
    function requests(bytes32 requestId)
        external
        view
        returns (address payer, address callbackTarget, bytes4 callbackSelector, bool completed);
    function complete(bytes32 requestId, uint8 status, bytes32 resultHash, string calldata uri, bytes calldata args)
        external;
}

/// @notice The oracle attestation the plane signs (EIP-712 domain "IdentityMD Oracle" v2; verifyingContract is
/// the callback contract when there is one, the body's `consumer` if named, else zero) and delivers to a
/// callback as `(bytes32 intakeRequestId, OracleAttestation a, bytes signature)`.
struct OracleAttestation {
    bytes32 requestId;
    uint256 chainId;
    bytes32 questionHash;
    uint8 answerType; // 0 bool, 1 address, 2 bytes32, 3 uint256, 4 address[], 5 bytes32[]
    bytes answer;
    uint256 figure;
    uint64 fromBlock;
    uint64 toBlock;
    bytes32 blockHash;
    bytes32 panelJobId;
    uint16 panelSize;
    uint16 quorum;
    uint16 agreed;
    uint64 issuedAt;
    uint64 expiresAt;
}
