// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract EscrowContract is EIP712 {
    enum State { Created, InProgress, Finalized }

    // state Vars
    address[] public participants;
    mapping(address => bool) public isParticipant;

    uint256 public meetingTime;
    uint256 public depositAmount;
    uint256 public penaltyRatePerMinute; // e.g., 200 = 2% per minute
    State public contractState;

    // Stores the first valid arrival time for each participant
    mapping(address => uint256) public arrivalTimes;

    // Secure withdrawal pattern state
    mapping(address => uint256) public balances;

    event Deposited(address indexed participant, uint256 amount);
    event Arrived(address indexed participant, uint256 arrivalTime);
    event ArrivalProofSubmitted(address indexed participant, string ipfsHash);
    event ContractCancelled();
    event Finalized(uint256 finalizationTime);
    event Withdrawn(address indexed participant, uint256 amount);

    constructor(
        address[] memory _participants,
        uint256 _meetingTime,
        uint256 _depositAmount,
        uint256 _penaltyRatePerMinute
    ) {
        require(_meetingTime > block.timestamp, "Meeting time must be in the future");
        // EIP712 constructor
        _initializeEIP712("MeetupAttestation", "1");
        require(_participants.length >= 2, "Must have at least 2 participants");
        require(_depositAmount > 0, "Deposit must be > 0");

        for (uint i = 0; i < _participants.length; i++) {
            address p = _participants[i];
            require(p != address(0), "Invalid participant address");
            require(!isParticipant[p], "Duplicate participant"); // Ensure no duplicate participants
            isParticipant[p] = true;
        }
        participants = _participants;

        meetingTime = _meetingTime;
        depositAmount = _depositAmount;
        penaltyRatePerMinute = _penaltyRatePerMinute;
        contractState = State.Created;
    }

    function deposit() external payable {
        require(isParticipant[msg.sender], "Not a participant");
        require(msg.value == depositAmount, "Incorrect deposit amount");
        require(contractState == State.Created, "Deposits are closed");

        balances[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    //  Arrival confirmation
    function confirmArrival(
        address attester1,
        address attester2,
        uint256 timestamp,
        bytes calldata signature1,
        bytes calldata signature2,
        string calldata ipfsHash
    ) external {
        require(isParticipant[msg.sender], "Not a participant");
        require(isParticipant[attester1] && isParticipant[attester2], "Attesters must be participants");
        require(contractState != State.Finalized, "Already finalized");
        require(timestamp >= meetingTime, "Attestation cannot be from before the meeting time");

        // Verify the signatures
        bytes32 structHash = _hashTypedDataV4(keccak256(abi.encode(
            keccak256("Attestation(address attester1,address attester2,uint256 timestamp)"),
            attester1,
            attester2,
            timestamp
        )));

        address recovered1 = ECDSA.recover(structHash, signature1);
        address recovered2 = ECDSA.recover(structHash, signature2);

        require(
            (recovered1 == attester1 && recovered2 == attester2) || (recovered1 == attester2 && recovered2 == attester1),
            "Invalid signatures"
        );

        // Record arrival time for both participants in the attestation, if not already recorded.
        // This ensures the first valid proof sets their arrival time.
        if (arrivalTimes[attester1] == 0) {
            arrivalTimes[attester1] = timestamp;
            emit Arrived(attester1, timestamp);
        }
        if (arrivalTimes[attester2] == 0) {
            arrivalTimes[attester2] = timestamp;
            emit Arrived(attester2, timestamp);
        }

        // Transition state if this is the first arrival confirmation
        if (contractState == State.Created) {
            contractState = State.InProgress;
        }

        emit ArrivalProofSubmitted(msg.sender, ipfsHash);
    }

    function _calculatePenalty(uint256 arrivalTime) private view returns (uint256) {
        if (arrivalTime == 0 || arrivalTime <= meetingTime) return 0; // No arrival or on time
        uint256 minutesLate = (arrivalTime - meetingTime) / 60;
        uint256 penalty = (depositAmount * minutesLate * penaltyRatePerMinute) / 10000;
        if (penalty > depositAmount) penalty = depositAmount;
        return penalty;
    }

    // @dev EIP-712 hash for the attestation structure.
    function _hashTypedDataV4(bytes32 structHash) internal view virtual override returns (bytes32) {
        return EIP712._hashTypedDataV4(structHash);
    }

    /**
     * @dev Allows participants to withdraw their balance after finalization.
     * This is the secure "pull-over-push" pattern.
     */
    function withdraw() external {
        require(contractState == State.Finalized, "Contract not finalized");
        uint256 amount = balances[msg.sender];
        require(amount > 0, "No balance to withdraw");

        // Checks-Effects-Interactions Pattern to prevent re-entrancy
        balances[msg.sender] = 0;
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }
}
