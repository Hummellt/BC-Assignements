// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/utils/Address.sol";

contract MeetupContract {
    address payable public participant1;  
    address payable public participant2;  
    uint256 public meetingTime;
    uint256 public depositAmount;
    bool public arrived1;
    bool public arrived2;
    bool public finalized;
    uint256 public penaltyRatePerMinute; // e.g., 200 = 2% per minute
    uint256 public cancellationTimeout = 5 minutes;
    bool public cancelRequest1;
    bool public cancelRequest2;

    // NEW: stores IPFS hashes with the arrival proofs
    mapping(address => string) public arrivalProofIPFS;

    // Events
    event Deposited(address indexed participant, uint256 amount);
    event Arrived(address indexed participant, uint256 arrivalTime);
    event ArrivalProofSubmitted(address indexed participant, string ipfsHash);
    event Cancelled(address indexed initiator);
    event Finalized(address indexed participant1, address indexed participant2, bool success);

    constructor(
        address payable _participant1,
        address payable _participant2, 
        uint256 _meetingTime,
        uint256 _depositAmount,
        uint256 _penaltyRatePerMinute
    ) {
        require(_meetingTime > block.timestamp, "Meeting time must be in the future");
        require(_participant1 != _participant2, "Participants must be different");
        require(_depositAmount > 0, "Deposit must be > 0");

        participant1 = _participant1;  
        participant2 = _participant2; 
        meetingTime = _meetingTime;
        depositAmount = _depositAmount;
        penaltyRatePerMinute = _penaltyRatePerMinute;
    }

    function deposit() external payable {
        require(msg.sender == participant1 || msg.sender == participant2, "Not a participant");
        require(msg.value == depositAmount, "Incorrect deposit amount");
        require(!finalized, "Already finalized");

        emit Deposited(msg.sender, msg.value);
    }

    // -------------------------
    //  Arrival confirmation
    // -------------------------
    /**
     * @dev Participant confirms arrival and attaches an IPFS CID of a photo.
     * The photo is uploaded off-chain to IPFS; the contract only stores the hash.
     */
    function confirmArrival(string calldata ipfsHash) external {
        require(msg.sender == participant1 || msg.sender == participant2, "Not a participant");
        require(block.timestamp >= meetingTime, "Meeting time not reached");
        require(!finalized, "Already finalized");
        require(bytes(ipfsHash).length > 0, "IPFS hash required");

        // store IPFS hash as proof for this participant
        arrivalProofIPFS[msg.sender] = ipfsHash;
        emit ArrivalProofSubmitted(msg.sender, ipfsHash);

        if (msg.sender == participant1) {
            arrived1 = true;
        } else {
            arrived2 = true;
        }

        emit Arrived(msg.sender, block.timestamp);
    }

    // Cancellation function (both must agree, within 5 minutes)
    //@dev not yet working
    function cancel() external {
        require(!finalized, "Already finalized");
        require(block.timestamp < meetingTime + cancellationTimeout, "Cancellation window expired");
        require(msg.sender == participant1 || msg.sender == participant2, "Not a participant");

        if (msg.sender == participant1) cancelRequest1 = true;
        else cancelRequest2 = true;

        require(cancelRequest1 && cancelRequest2, "Both participants must agree");

        finalized = true;
        _refundBoth();
        emit Cancelled(msg.sender);
    }

    // Mutual confirmation logic
    function confirmOtherArrival() external {
        require(!finalized, "Already finalized");
        require(
            (msg.sender == participant1 && arrived2) ||
            (msg.sender == participant2 && arrived1),
            "Other participant not confirmed yet"
        );

        finalized = true;
        _finalize();
    }

    // Finalization logic
    function _finalize() private {
        bool bothArrived = arrived1 && arrived2;

        if (bothArrived) {
            uint256 penalty1 = _calculatePenalty();
            uint256 penalty2 = _calculatePenalty();

            if (penalty1 == 0 && penalty2 == 0) {
                _refundBoth();
            } else if (penalty1 > penalty2) {
                _transferWithRevert(participant2, penalty1);
                _transferWithRevert(participant1, depositAmount - penalty1);
            } else if (penalty2 > penalty1) {
                _transferWithRevert(participant1, penalty2);
                _transferWithRevert(participant2, depositAmount - penalty2);
            } else {
                // Both equally late → no penalty
                _refundBoth();
            }

            emit Finalized(participant1, participant2, true);
        } else {
            // Only one participant arrived
            address payable lateParticipant = !arrived1 ? participant1 : participant2;
            address payable onTimeParticipant = arrived1 ? participant1 : participant2;
            uint256 penalty = _calculatePenalty();
            _transferWithRevert(onTimeParticipant, penalty);
            _transferWithRevert(lateParticipant, depositAmount - penalty);
            emit Finalized(participant1, participant2, false);
        }
    }

    function _refundBoth() private {
        _transferWithRevert(participant1, depositAmount);
        _transferWithRevert(participant2, depositAmount);
    }    

    function _calculatePenalty() private view returns (uint256) {
        if (block.timestamp <= meetingTime) return 0;
        uint256 minutesLate = (block.timestamp - meetingTime) / 60;
        uint256 penalty = (depositAmount * minutesLate * penaltyRatePerMinute) / 10000;
        if (penalty > depositAmount) penalty = depositAmount;
        return penalty;
    }

    function _transferWithRevert(address payable to, uint256 amount) private {
        if (amount == 0) return;
        (bool success, ) = to.call{value: amount}("");
        require(success, "Transfer failed");
    }

    receive() external payable {}
}
