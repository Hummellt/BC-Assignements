// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/utils/Address.sol";

contract MeetupContract {
    address payable public participant1;  
    address payable public participant2;  
    uint256 public meetingTime;
    // meeting coordinates stored as signed integers scaled by 1e6 (microdegrees)
    int256 public meetingLat;
    int256 public meetingLon;
    uint256 public depositAmount;
    bool public arrived1;
    bool public arrived2;
    bool public finalized;
    uint256 public penaltyRatePerMinute; // e.g., 200 = 2% per minute
    uint256 public cancellationTimeout = 5 minutes;
    bool public cancelRequest1;
    bool public cancelRequest2;

    // stores IPFS hashes with the arrival proofs
    mapping(address => string) public arrivalProofIPFS;

    // Secure withdrawal pattern state
    mapping(address => uint256) public balances;

    // Store individual arrival times to fix penalty calculation
    mapping(address => uint256) public arrivalTimes;

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
        int256 _meetingLat,
        int256 _meetingLon,
        uint256 _depositAmount,
        uint256 _penaltyRatePerMinute
    ) {
        require(_meetingTime > block.timestamp, "Meeting time must be in the future");
        require(_participant1 != _participant2, "Participants must be different");
        require(_depositAmount > 0, "Deposit must be > 0");

        participant1 = _participant1;  
        participant2 = _participant2; 
        meetingTime = _meetingTime;
        // store scaled coordinates
        meetingLat = _meetingLat;
        meetingLon = _meetingLon;
        depositAmount = _depositAmount;
        penaltyRatePerMinute = _penaltyRatePerMinute;
    }

    function deposit() external payable {
        require(msg.sender == participant1 || msg.sender == participant2, "Not a participant");
        require(msg.value == depositAmount, "Incorrect deposit amount");
        require(!finalized, "Already finalized");

        balances[msg.sender] += msg.value;
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

        uint256 arrival = block.timestamp;
        arrivalTimes[msg.sender] = arrival;

        if (msg.sender == participant1) {
            arrived1 = true;
        } else {
            arrived2 = true;
        }
        emit Arrived(msg.sender, arrival);
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
            uint256 penalty1 = _calculatePenalty(arrivalTimes[participant1]);
            uint256 penalty2 = _calculatePenalty(arrivalTimes[participant2]);

            if (penalty1 == 0 && penalty2 == 0) {
                _refundBoth();
            } else if (penalty1 > penalty2) {
                balances[participant2] += penalty1;
                balances[participant1] += depositAmount - penalty1;
            } else if (penalty2 > penalty1) {
                balances[participant1] += penalty2;
                balances[participant2] += depositAmount - penalty2;
            } else {
                // Both equally late → no penalty
                _refundBoth();
            }

            emit Finalized(participant1, participant2, true);
        } else {
            // Only one participant arrived
            address lateParticipant = !arrived1 ? participant1 : participant2;
            address onTimeParticipant = arrived1 ? participant1 : participant2;
            uint256 penalty = _calculatePenalty(arrivalTimes[onTimeParticipant]);

            balances[onTimeParticipant] += penalty;
            balances[lateParticipant] += depositAmount - penalty;
            emit Finalized(participant1, participant2, false);
        }
    }

    function _refundBoth() private {
        balances[participant1] += depositAmount;
        balances[participant2] += depositAmount;
    }    

    function _calculatePenalty(uint256 arrivalTime) private view returns (uint256) {
        if (arrivalTime <= meetingTime) return 0;
        uint256 minutesLate = (arrivalTime - meetingTime) / 60;
        uint256 penalty = (depositAmount * minutesLate * penaltyRatePerMinute) / 10000;
        if (penalty > depositAmount) penalty = depositAmount;
        return penalty;
    }

    /**
     * @dev Allows participants to withdraw their balance after finalization.
     * This is the secure "pull-over-push" pattern.
     */
    function withdraw() external {
        require(finalized, "Contract not finalized");
        uint256 amount = balances[msg.sender];
        require(amount > 0, "No balance to withdraw");

        // Checks-Effects-Interactions Pattern to prevent re-entrancy
        balances[msg.sender] = 0;
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }

    receive() external payable {}
}
