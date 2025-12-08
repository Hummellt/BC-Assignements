// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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

    // EIP-712 typehash for Attestation
    bytes32 private constant ATTESTATION_TYPEHASH = keccak256(
        "Attestation(address arriver,address attester1,address attester2,uint256 timestamp)"
    );

    constructor(
        address[] memory _participants,
        uint256 _meetingTime,
        uint256 _depositAmount,
        uint256 _penaltyRatePerMinute
    ) EIP712("MeetupAttestation", "1") {
        require(_meetingTime > block.timestamp, "Meeting time must be in the future");
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
        require(attester1 != msg.sender && attester2 != msg.sender, "Attesters cannot be the arriver");
        require(attester1 != attester2, "Attesters must be distinct");
        require(contractState != State.Finalized, "Already finalized");

        require(bytes(ipfsHash).length > 0, "IPFS hash required");
        require(timestamp >= meetingTime, "Attestation cannot be from before the meeting time");
        require(signature1.length == 65 && signature2.length == 65, "Invalid signature length");

        // Use the public helper so tests and contract build the same digest
        bytes32 digest = hashAttestation(msg.sender, attester1, attester2, timestamp);

        // Prefixed digest for eth_sign compatibility
        bytes32 prefixed = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));

        address signer1 = ECDSA.recover(digest, signature1);
        if (signer1 != attester1 && signer1 != attester2) {
            signer1 = ECDSA.recover(prefixed, signature1);
        }

        address signer2 = ECDSA.recover(digest, signature2);
        if (signer2 != attester1 && signer2 != attester2) {
            signer2 = ECDSA.recover(prefixed, signature2);
        }

        require(signer1 != address(0) && signer2 != address(0), "Invalid signatures");
        require(
            (signer1 == attester1 && signer2 == attester2) ||
            (signer1 == attester2 && signer2 == attester1),
            "Signatures must be from two distinct attesters"
        );

        if (arrivalTimes[msg.sender] == 0) {
            arrivalTimes[msg.sender] = timestamp;
            emit Arrived(msg.sender, timestamp);
        }

        if (contractState == State.Created) {
            contractState = State.InProgress;
        }

        emit ArrivalProofSubmitted(msg.sender, ipfsHash);
    }


    // @dev Allows cancellation before any arrivals, refunding all participants.
    function cancelBeforeArrivals() external {
        require(contractState != State.Finalized, "Already finalized");
        require(contractState == State.Created, "Cannot cancel after arrivals have begun");
        require(isParticipant[msg.sender], "Not a participant");

        // Refund all participants who have deposited
        // The balances are already set from deposit(), only need to enable withdrawal.
        contractState = State.Finalized;
        emit ContractCancelled();
    }

    // @dev Finalizes the contract, calculating penalties and distributing funds.
    // by anyone after a reasonable time has passed since the meeting.
    function finalize() external {
        require(block.timestamp > meetingTime + 1 hours, "Finalization window not yet open");
        require(contractState != State.Finalized, "Contract already finalized");

        uint256 totalPenalties = 0;
        uint256 punctualParticipantsCount = 0;

        // First pass: Calculate total penalties and count punctual participants
        for (uint i = 0; i < participants.length; i++) {
            address p = participants[i];
            if (balances[p] == depositAmount) { // Ensure they deposited
                uint256 penalty = _calculatePenalty(arrivalTimes[p]);
                if (penalty == 0 && arrivalTimes[p] != 0) {
                    punctualParticipantsCount++;
                }
                totalPenalties += penalty;
                balances[p] -= penalty; // Deduct penalty from their balance
            }
        }

        // Second pass: Distribute penalties to punctual participants
        if (totalPenalties > 0 && punctualParticipantsCount > 0) {
            uint256 rewardPerPunctual = totalPenalties / punctualParticipantsCount;
            for (uint i = 0; i < participants.length; i++) {
                address p = participants[i];
                // A participant is punctual if they deposited, arrived, and had no penalty
                if (balances[p] == (depositAmount - _calculatePenalty(arrivalTimes[p])) && arrivalTimes[p] != 0 && _calculatePenalty(arrivalTimes[p]) == 0) {
                    balances[p] += rewardPerPunctual;
                }
            }
        }

        contractState = State.Finalized;
        emit Finalized(block.timestamp);
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

    // @dev Public helper to produce the EIP-712 digest for an attestation (useful for tests/signing)
    function hashAttestation(
        address arriver,
        address attester1,
        address attester2,
        uint256 timestamp
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            ATTESTATION_TYPEHASH,
            arriver,
            attester1,
            attester2,
            timestamp
        ));
        return _hashTypedDataV4(structHash);
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

        emit Withdrawn(msg.sender, amount);
    }
}
