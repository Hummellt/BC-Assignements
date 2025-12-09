// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract EscrowContract is EIP712 {
    enum State { Created, InProgress, Finalized }

    // state Vars
    address[] public participants;
    mapping(address => bool) public isParticipant;

    // make these immutable where possible (set in constructor once)
    uint256 public immutable meetingTime;
    uint256 public immutable depositAmount;
    uint256 public immutable penaltyRatePerMinute; // e.g., 200 = 2% per minute
    State public contractState;

    // Stores the first valid arrival time for each participant
    mapping(address => uint256) public arrivalTimes;

    // Stores IPFS proof CID for each participant
    mapping(address => string) public arrivalProofIPFS;

    // Secure withdrawal pattern state
    mapping(address => uint256) public balances;

    event Deposited(address indexed participant, uint256 amount);
    event Arrived(address indexed participant, uint256 arrivalTime);
    event ArrivalProofSubmitted(address indexed participant, string ipfsHash);
    event ReportedOnlyArrived(address indexed reporter, address indexed punctual);
    event ContractCancelled();
    event Finalized(uint256 finalizationTime);
    event Withdrawn(address indexed participant, uint256 amount);

    // EIP-712 typehash for Attestation
    bytes32 private constant ATTESTATION_TYPEHASH = keccak256(
        "Attestation(address arriver,address attester1,address attester2,uint256 timestamp)"
    );

    // EIP-712 typehash for MutualAttestation (two-way, used when only two participants mutually attest)
    bytes32 private constant MUTUAL_TYPEHASH = keccak256(
        "MutualAttestation(address a,address b,uint256 timestamp)"
    );

    // config for voting-based resolution (make smaller type immutable)
    // Percentage (0..100) of deposit returned to honest absentees when voting resolution triggers.
    uint8 public immutable honestyRatePercent;
    uint256 public immutable reportingWindowSeconds;

    // Voting storage: voter => candidate they reported as the only arriver
    mapping(address => address) public onlyArrivedVote;
    // Candidate -> number of votes
    mapping(address => uint256) public voteCounts;
    uint256 public totalVotes;

    constructor(
        address[] memory _participants,
        uint256 _meetingTime,
        uint256 _depositAmount,
        uint256 _penaltyRatePerMinute,
        uint8 _honestyRatePercent,
        uint256 _reportingWindowSeconds
    ) EIP712("MeetupAttestation", "1") {
        require(_meetingTime > block.timestamp, "Meeting time must be in the future");
        require(_participants.length >= 2, "Must have at least 2 participants");
        require(_depositAmount > 0, "Deposit must be > 0");
        require(_honestyRatePercent <= 100, "honestyRatePercent must be 0..100");

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

        honestyRatePercent = _honestyRatePercent;
        reportingWindowSeconds = _reportingWindowSeconds;
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

        arrivalProofIPFS[msg.sender] = ipfsHash;
        emit ArrivalProofSubmitted(msg.sender, ipfsHash);
    }

    // mutual arrival confirmation for two participants using mutual attestations.
    // Allows one submitter to provide both signatures so A and B (two people) can attest each other
    // in a single on-chain call.
    function confirmMutualArrival(
        address other,
        uint256 timestamp,
        bytes calldata signatureOtherForCaller,
        bytes calldata signatureCallerForOther,
        string calldata ipfsHash
    ) external {
        require(isParticipant[msg.sender], "Not a participant");
        require(isParticipant[other], "Other must be a participant");
        require(msg.sender != other, "Other cannot be self");
        require(contractState != State.Finalized, "Already finalized");
        require(bytes(ipfsHash).length > 0, "IPFS hash required");
        require(timestamp >= meetingTime, "Attestation cannot be from before the meeting time");
        require(signatureOtherForCaller.length == 65 && signatureCallerForOther.length == 65, "Invalid signature length");

        // Recover 'other' signing the digest where arriver = msg.sender
        bytes32 digestCaller = hashMutualAttestation(msg.sender, other, timestamp);
        address recovered = ECDSA.recover(digestCaller, signatureOtherForCaller);
        if (recovered != other) {
            recovered = ECDSA.recover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digestCaller)), signatureOtherForCaller);
        }
        require(recovered == other, "Other's signature invalid for caller");

        // Recover 'msg.sender' signing the digest where arriver = other
        bytes32 digestOther = hashMutualAttestation(other, msg.sender, timestamp);
        recovered = ECDSA.recover(digestOther, signatureCallerForOther);
        if (recovered != msg.sender) {
            recovered = ECDSA.recover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digestOther)), signatureCallerForOther);
        }
        require(recovered == msg.sender, "Caller signature invalid for other");

        // Mark both arrivals (if not already set)
        if (arrivalTimes[msg.sender] == 0) {
            arrivalTimes[msg.sender] = timestamp;
            emit Arrived(msg.sender, timestamp);
            arrivalProofIPFS[msg.sender] = ipfsHash;
            emit ArrivalProofSubmitted(msg.sender, ipfsHash);
        }

        if (arrivalTimes[other] == 0) {
            arrivalTimes[other] = timestamp;
            emit Arrived(other, timestamp);
            arrivalProofIPFS[other] = ipfsHash;
            emit ArrivalProofSubmitted(other, ipfsHash);
        }

        if (contractState == State.Created) {
            contractState = State.InProgress;
        }
    }

    // participants can report (vote) who was the only arriver.
    // Only participants who deposited can vote.
    // Voting allowed within [meetingTime, meetingTime + reportingWindowSeconds]
    function reportOnlyArrived(address punctual) external {
        require(isParticipant[msg.sender], "Not a participant");
        require(isParticipant[punctual], "Punctual must be a participant");
        require(block.timestamp >= meetingTime, "Reporting not yet open");
        require(block.timestamp <= meetingTime + reportingWindowSeconds, "Reporting window closed");
        require(onlyArrivedVote[msg.sender] == address(0), "Already reported");
        require(balances[msg.sender] == depositAmount, "Only deposited participants may report");

        onlyArrivedVote[msg.sender] = punctual;
        voteCounts[punctual] += 1;
        totalVotes += 1;

        emit ReportedOnlyArrived(msg.sender, punctual);
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

    // count recorded on-chain arrivals
    function _countRecordedArrivals() internal view returns (uint256) {
        uint256 cnt = 0;
        for (uint i = 0; i < participants.length; i++) {
            if (arrivalTimes[participants[i]] != 0) cnt++;
        }
        return cnt;
    }

    // @dev Finalizes the contract, calculating penalties and distributing funds.
    function finalize() external {
        bool votingWindowExpired = block.timestamp > meetingTime + reportingWindowSeconds;
        uint256 recorded = _countRecordedArrivals();
        require(
            block.timestamp > meetingTime + 1 hours || (votingWindowExpired && recorded == 0),
            "Finalization window not yet open"
        );
        require(contractState != State.Finalized, "Contract already finalized");

        uint256 n = participants.length;

        // If NO on-chain arrivals recorded and voting was used, check for 2/3 majority and apply voting resolution
        if (recorded == 0 && votingWindowExpired && totalVotes > 0) {
            // compute quorum = ceil(2N/3)
            uint256 quorum = (2 * n + 2) / 3; // ceil(2n/3)
            // find candidate with highest votes
            address winning = address(0);
            uint256 winningCount = 0;
            for (uint i = 0; i < n; ) {
                address cand = participants[i];
                uint256 c = voteCounts[cand];
                if (c > winningCount) {
                    winningCount = c;
                    winning = cand;
                }
                unchecked { ++i; }
            }

            if (winning != address(0) && winningCount >= quorum) {
                // apply distribution based on votes:
                // - honest absentees (voted for winning) get honestyRatePercent% back
                // - dishonest voters / non-voters (did not vote for winning) lose their deposit
                // - winning gets their deposit plus remainder from others
                uint256 winnerBalance = 0;
                // start with winner's own deposit if they deposited
                if (balances[winning] == depositAmount) {
                    winnerBalance += balances[winning];
                    balances[winning] = 0;
                }

                for (uint i = 0; i < n; ) {
                    address p = participants[i];
                    if (p == winning) {
                        unchecked { ++i; }
                        continue;
                    }
                    if (balances[p] != depositAmount) {
                        // didn't deposit -> nothing to move
                        continue;
                    }

                    address voted = onlyArrivedVote[p];
                    if (voted == winning) {
                        // honest absentee: give back honestyRatePercent% and transfer remainder to winner
                        uint256 honestBack = (depositAmount * honestyRatePercent) / 100;
                        uint256 remainder = depositAmount - honestBack;
                        balances[p] = honestBack;
                        winnerBalance += remainder;
                    } else {
                        // punished: lose deposit entirely; transfer whole deposit to winner
                        balances[p] = 0;
                        winnerBalance += depositAmount;
                    }
                    unchecked { ++i; }
                }

                // set winner final balance
                balances[winning] = winnerBalance;

                contractState = State.Finalized;
                emit Finalized(block.timestamp);
                return;
            }
            // else: no adequate quorum via voting -> fall through to normal finalize logic
        }

        uint256 totalPenalties = 0;
        // only need punctual flags in memory; don't allocate penalties[] (never read later)
        bool[] memory punctual = new bool[](n);

        // First pass: compute penalties and count punctual participants
        for (uint i = 0; i < n; ) {
            address p = participants[i];
            uint256 bal = balances[p];
            if (bal == depositAmount) { // Ensure they deposited
                uint256 arrival = arrivalTimes[p];
                uint256 penalty = _calculatePenalty(arrival);
                if (penalty == 0 && arrival != 0) {
                    punctual[i] = true;
                }
                totalPenalties += penalty;
                // immediately update balance once (store write)
                balances[p] = bal - penalty;
            }
            unchecked { ++i; }
        }

        // Second pass: Distribute penalties to punctual participants
        if (totalPenalties > 0) {
            uint256 punctualCount = 0;
            for (uint i = 0; i < n; ) {
                if (punctual[i]) { punctualCount++; }
                unchecked { ++i; }
            }

            if (punctualCount > 0) {
                uint256 rewardPerPunctual = totalPenalties / punctualCount;
                for (uint i = 0; i < n; ) {
                    if (punctual[i]) {
                        address p = participants[i];
                        balances[p] += rewardPerPunctual;
                    }
                    unchecked { ++i; }
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

    // hash for mutual two-way attestation
    function hashMutualAttestation(
        address a,
        address b,
        uint256 timestamp
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            MUTUAL_TYPEHASH,
            a,
            b,
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
