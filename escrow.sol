// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/utils/Address.sol";
contract MeetupContract {
    enum State { Created, InProgress, Finalized }

    // state Vars
    address[] public participants;
    mapping(address => bool) public isParticipant;

    uint256 public meetingTime;
    uint256 public depositAmount;
    uint256 public penaltyRatePerMinute; // e.g., 200 = 2% per minute
    State public contractState;

    // stores IPFS hashes with the arrival proofs
    mapping(address => string) public arrivalProofIPFS;

    // Secure withdrawal pattern state
    mapping(address => uint256) public balances;

    // Store individual arrival times to fix penalty calculation
    mapping(address => uint256) public arrivalTimes;

    event Deposited(address indexed participant, uint256 amount);
    event Arrived(address indexed participant, uint256 arrivalTime);
    event ArrivalProofSubmitted(address indexed participant, string ipfsHash);
    event Cancelled(address indexed initiator);
    event Finalized(uint256 finalizationTime);
    event Withdrawn(address indexed participant, uint256 amount);

    constructor(
        address[] memory _participants,
        uint256 _meetingTime,
        uint256 _depositAmount,
        uint256 _penaltyRatePerMinute
    ) {
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

    // -------------------------
    //  Arrival confirmation
    // -------------------------
    /**
     * @dev Participant confirms arrival and attaches an IPFS CID of a photo.
     * The photo is uploaded off-chain to IPFS; the contract only stores the hash.
     */
    function confirmArrival(string calldata ipfsHash) external {
        require(isParticipant[msg.sender], "Not a participant");
        require(block.timestamp >= meetingTime, "Meeting time not reached"); // needs to be updated
        require(contractState != State.Finalized, "Already finalized");
        require(bytes(ipfsHash).length > 0, "IPFS hash required");

        // store IPFS hash as proof for this participant
        arrivalProofIPFS[msg.sender] = ipfsHash;
        emit ArrivalProofSubmitted(msg.sender, ipfsHash);

        uint256 arrival = block.timestamp;
        arrivalTimes[msg.sender] = arrival;

        // Transition state if this is the first arrival confirmation
        if (contractState == State.Created) {
            contractState = State.InProgress;
        }
        emit Arrived(msg.sender, arrival);
    }

    // Cancellation function (both must agree, within 5 minutes)
    function cancel() external {
        require(contractState != State.Finalized, "Already finalized");
        require(block.timestamp < meetingTime + 5 minutes, "Cancellation window expired"); // Hardcoded 5 minutes for now
        require(isParticipant[msg.sender], "Not a participant");

        // cancellation logic needs overhaul for multiple participants.
        // This is a temporary placeholder.
        bool anyArrivals = false;
        for (uint i = 0; i < participants.length; i++) {
            if (arrivalTimes[participants[i]] != 0) {
                anyArrivals = true;
                break;
            }
        }
        require(!anyArrivals, "Cannot cancel after any participant has arrived");

        contractState = State.Finalized; // Mark as finalized to prevent further actions
        _refundBoth();
        emit Cancelled(msg.sender);
    }

    // Mutual confirmation logic
    function confirmOtherArrival() external {
        // This function is specific to the two-participant model and will be removed.
        revert("confirmOtherArrival is deprecated in this version");
        _finalize();
    }

    // Finalization logic
    function _finalize() private {
        // This function will be completely rewritten for the multi-participant quorum logic.
        // For now it revert to indicate it's deprecated.
        revert("_finalize logic is deprecated in this version");
    }

    function _refundBoth() private {
        // two-participant model and will be removed.
        revert("_refundBoth is deprecated in this version");
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
        require(contractState == State.Finalized, "Contract not finalized");
        uint256 amount = balances[msg.sender];
        require(amount > 0, "No balance to withdraw");

        // Checks-Effects-Interactions Pattern to prevent re-entrancy
        balances[msg.sender] = 0;
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }

    receive() external payable {}
}
