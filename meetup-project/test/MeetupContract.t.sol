// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {EscrowContract} from "src/EscrowContract.sol";

contract EscrowContractTest is Test, EIP712("MeetupAttestation", "1") {
    EscrowContract public meetup;

    address public owner; // Not explicitly used in contract, but good for general testing
    address public participant1;
    address public participant2;
    address public participant3; // For multi-participant scenarios
    address public nonParticipant;

    // Define private keys for test accounts for reproducible signatures
    uint256 public constant PARTICIPANT1_PK = 0x1;
    uint256 public constant PARTICIPANT2_PK = 0x2;
    uint256 public constant PARTICIPANT3_PK = 0x3;

    uint256 public immutable TEST_DEPOSIT_AMOUNT = 1 ether;
    uint256 public immutable TEST_PENALTY_RATE = 200; // 2% per minute
    uint256 public TEST_MEETING_TIME;

    // new test config values matching updated constructor
    uint8 public constant TEST_HONESTY_PERCENT = 50;
    uint256 public constant TEST_REPORTING_WINDOW_SECONDS = 3600;
    
    // --- Events to test ---
    event Deposited(address indexed participant, uint256 amount);
    event Arrived(address indexed participant, uint256 arrivalTime);
    event ArrivalProofSubmitted(address indexed participant, string ipfsHash);

    function setUp() public {
        // Set up test accounts
        owner = makeAddr("owner");
        participant1 = vm.addr(PARTICIPANT1_PK);
        participant2 = vm.addr(PARTICIPANT2_PK);
        participant3 = vm.addr(PARTICIPANT3_PK);
        nonParticipant = makeAddr("nonParticipant");

        // Fund participants for deposits
        vm.deal(participant1, TEST_DEPOSIT_AMOUNT * 2);
        vm.deal(participant2, TEST_DEPOSIT_AMOUNT * 2);
        vm.deal(participant3, TEST_DEPOSIT_AMOUNT * 2);
        vm.deal(nonParticipant, TEST_DEPOSIT_AMOUNT * 2); // Fund the non-participant as well

        // Set a future meeting time (e.g., 1 hour from now relative to test start)
        TEST_MEETING_TIME = block.timestamp + 1 hours;
    }

    // --- Constructor Tests ---

    function testConstructor_ValidDeployment() public {
        address[] memory participants_ = new address[](2);
        participants_[0] = participant1;
        participants_[1] = participant2;

        meetup = new EscrowContract(
            participants_,
            TEST_MEETING_TIME,
            TEST_DEPOSIT_AMOUNT,
            TEST_PENALTY_RATE,
            TEST_HONESTY_PERCENT,
            TEST_REPORTING_WINDOW_SECONDS
        );

        assertEq(meetup.meetingTime(), TEST_MEETING_TIME, "Meeting time mismatch");
        assertEq(meetup.depositAmount(), TEST_DEPOSIT_AMOUNT, "Deposit amount mismatch");
        assertEq(meetup.penaltyRatePerMinute(), TEST_PENALTY_RATE, "Penalty rate mismatch");
        assertEq(uint8(meetup.contractState()), uint8(EscrowContract.State.Created), "Initial state not Created");
        assertTrue(meetup.isParticipant(participant1), "Participant 1 not registered");
        assertTrue(meetup.isParticipant(participant2), "Participant 2 not registered");
        assertFalse(meetup.isParticipant(nonParticipant), "Non-participant incorrectly registered");
    }

    function testConstructor_RevertsOnPastMeetingTime() public {
        address[] memory participants_ = new address[](2);
        participants_[0] = participant1;
        participants_[1] = participant2;

        // Warp time to the future, then try to create a contract with a past meeting time
        vm.warp(TEST_MEETING_TIME + 1);

        vm.expectRevert("Meeting time must be in the future");
        new EscrowContract(
            participants_,
            TEST_MEETING_TIME, // This is now in the past relative to vm.warp
            TEST_DEPOSIT_AMOUNT,
            TEST_PENALTY_RATE,
            TEST_HONESTY_PERCENT,
            TEST_REPORTING_WINDOW_SECONDS
        );
    }

    function testConstructor_RevertsOnLessThanTwoParticipants() public {
        address[] memory participants_ = new address[](1);
        participants_[0] = participant1;

        vm.expectRevert("Must have at least 2 participants");
        new EscrowContract(
            participants_,
            TEST_MEETING_TIME,
            TEST_DEPOSIT_AMOUNT,
            TEST_PENALTY_RATE,
            TEST_HONESTY_PERCENT,
            TEST_REPORTING_WINDOW_SECONDS
        );
    }

    function testConstructor_RevertsOnZeroDeposit() public {
        address[] memory participants_ = new address[](2);
        participants_[0] = participant1;
        participants_[1] = participant2;

        vm.expectRevert("Deposit must be > 0");
        new EscrowContract(
            participants_,
            TEST_MEETING_TIME,
            0, // Zero deposit
            TEST_PENALTY_RATE,
            TEST_HONESTY_PERCENT,
            TEST_REPORTING_WINDOW_SECONDS
        );
    }

    // --- Deposit Tests ---

    function testDeposit_Success() public {
        address[] memory participants_ = new address[](2);
        participants_[0] = participant1;
        participants_[1] = participant2;

        meetup = new EscrowContract(
            participants_,
            TEST_MEETING_TIME,
            TEST_DEPOSIT_AMOUNT,
            TEST_PENALTY_RATE,
            TEST_HONESTY_PERCENT,
            TEST_REPORTING_WINDOW_SECONDS
        );

        vm.startPrank(participant1);
        vm.expectEmit(true, false, false, true); // topic1: participant, data: amount
        emit Deposited(participant1, TEST_DEPOSIT_AMOUNT);
        meetup.deposit{value: TEST_DEPOSIT_AMOUNT}();
        vm.stopPrank();

        assertEq(meetup.balances(participant1), TEST_DEPOSIT_AMOUNT, "Participant 1 balance incorrect");
        assertEq(address(meetup).balance, TEST_DEPOSIT_AMOUNT, "Contract balance incorrect");
    }

    function testDeposit_RevertsOnIncorrectAmount() public {
        address[] memory participants_ = new address[](2);
        participants_[0] = participant1;
        participants_[1] = participant2;
        meetup = new EscrowContract(participants_, TEST_MEETING_TIME, TEST_DEPOSIT_AMOUNT, TEST_PENALTY_RATE, TEST_HONESTY_PERCENT, TEST_REPORTING_WINDOW_SECONDS);

        vm.startPrank(participant1);
        vm.expectRevert("Incorrect deposit amount");
        meetup.deposit{value: TEST_DEPOSIT_AMOUNT - 1}(); // Send less than required
        vm.stopPrank();
    }

    function testDeposit_RevertsOnNonParticipant() public {
        address[] memory participants_ = new address[](2);
        participants_[0] = participant1;
        participants_[1] = participant2;
        meetup = new EscrowContract(participants_, TEST_MEETING_TIME, TEST_DEPOSIT_AMOUNT, TEST_PENALTY_RATE, TEST_HONESTY_PERCENT, TEST_REPORTING_WINDOW_SECONDS);

        vm.prank(nonParticipant);
        // Expect a revert with the specific error string from the require statement.
        vm.expectRevert("Not a participant");
        meetup.deposit{value: TEST_DEPOSIT_AMOUNT}();
    }

    // --- Confirm Arrival Tests ---

    function testConfirmArrival_Success() public {
        address[] memory participants_ = new address[](3);
        participants_[0] = participant1;
        participants_[1] = participant2;
        participants_[2] = participant3;
        meetup = new EscrowContract(participants_, TEST_MEETING_TIME, TEST_DEPOSIT_AMOUNT, TEST_PENALTY_RATE, TEST_HONESTY_PERCENT, TEST_REPORTING_WINDOW_SECONDS);

        // Deposit first
        vm.prank(participant1);
        meetup.deposit{value: TEST_DEPOSIT_AMOUNT}();
        vm.prank(participant2);
        meetup.deposit{value: TEST_DEPOSIT_AMOUNT}();
        vm.prank(participant3);
        meetup.deposit{value: TEST_DEPOSIT_AMOUNT}();

        // Advance time to after the meeting
        vm.warp(TEST_MEETING_TIME + 10 minutes);
        uint256 arrivalTimestamp = block.timestamp;

        // Create and sign the attestation from participant2 and participant3 for participant1
        // Get the exact digest as the EscrowContract expects and sign it.
        bytes32 digest = meetup.hashAttestation(participant1, participant2, participant3, arrivalTimestamp);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(PARTICIPANT2_PK, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(PARTICIPANT3_PK, digest);
        bytes memory signature1 = abi.encodePacked(r1, s1, v1);
        bytes memory signature2 = abi.encodePacked(r2, s2, v2);

        vm.startPrank(participant1);
        // Events must be checked in the order they are emitted.
        // By specifying the contract address, we can stack multiple event checks.
        // 1. Arrived event - check participant (topic1) and arrivalTime (data)
        vm.expectEmit(true, false, false, true, address(meetup));
        emit Arrived(participant1, arrivalTimestamp);
        // 2. ArrivalProofSubmitted event - check participant (topic1) and ipfsHash (data)
        vm.expectEmit(true, false, false, true, address(meetup));
        emit ArrivalProofSubmitted(participant1, "ipfs://proof1");
        meetup.confirmArrival(participant2, participant3, arrivalTimestamp, signature1, signature2, "ipfs://proof1");
        vm.stopPrank();

        assertEq(meetup.arrivalTimes(participant1), arrivalTimestamp, "Arrival time incorrect");
        assertEq(uint8(meetup.contractState()), uint8(EscrowContract.State.InProgress), "State not InProgress after first arrival");
    }

    function testConfirmArrival_RevertsBeforeMeetingTime() public {
        address[] memory participants_ = new address[](3);
        participants_[0] = participant1;
        participants_[1] = participant2;
        participants_[2] = participant3;
        meetup = new EscrowContract(participants_, TEST_MEETING_TIME, TEST_DEPOSIT_AMOUNT, TEST_PENALTY_RATE, TEST_HONESTY_PERCENT, TEST_REPORTING_WINDOW_SECONDS);

        // Deposit first
        vm.prank(participant1);
        meetup.deposit{value: TEST_DEPOSIT_AMOUNT}();

        // !Note: We don't need to create valid signatures here as the time check comes first.
        // Time is still before TEST_MEETING_TIME (from setUp)
        vm.startPrank(participant1);
        vm.expectRevert("Attestation cannot be from before the meeting time");
        meetup.confirmArrival(participant2, participant3, block.timestamp, "", "", "ipfs://proof1");
        vm.stopPrank();
    }

    function testConfirmArrival_RevertsOnEmptyIpfsHash() public {
        address[] memory participants_ = new address[](3);
        participants_[0] = participant1;
        participants_[1] = participant2;
        participants_[2] = participant3;
        meetup = new EscrowContract(participants_, TEST_MEETING_TIME, TEST_DEPOSIT_AMOUNT, TEST_PENALTY_RATE, TEST_HONESTY_PERCENT, TEST_REPORTING_WINDOW_SECONDS);

        vm.prank(participant1);
        meetup.deposit{value: TEST_DEPOSIT_AMOUNT}();

        vm.warp(TEST_MEETING_TIME + 10 minutes);
        
        // We don't need valid signatures because the IPFS hash check comes first
        vm.startPrank(participant1);
        vm.expectRevert("IPFS hash required");
        meetup.confirmArrival(participant2, participant3, block.timestamp, "", "", "");
        vm.stopPrank();
    }

    // voting-based resolution when nobody shows up
    function testVotingResolution_NoOneShowsUp() public {
        // 3 participants: p1 & p2 deposit and vote that p3 was the only arriver
        address[] memory participants_ = new address[](3);
        participants_[0] = participant1;
        participants_[1] = participant2;
        participants_[2] = participant3;

        meetup = new EscrowContract(
            participants_,
            TEST_MEETING_TIME,
            TEST_DEPOSIT_AMOUNT,
            TEST_PENALTY_RATE,
            TEST_HONESTY_PERCENT,
            TEST_REPORTING_WINDOW_SECONDS
        );

        // Only p1 and p2 deposit (they will be voters). p3 does not deposit.
        vm.prank(participant1); meetup.deposit{value: TEST_DEPOSIT_AMOUNT}();
        vm.prank(participant2); meetup.deposit{value: TEST_DEPOSIT_AMOUNT}();

        // Advance into reporting window and submit votes
        vm.warp(TEST_MEETING_TIME + 10);
        vm.prank(participant1); meetup.reportOnlyArrived(participant3);
        vm.prank(participant2); meetup.reportOnlyArrived(participant3);

        // Advance past reporting window to allow finalize via voting path
        vm.warp(TEST_MEETING_TIME + TEST_REPORTING_WINDOW_SECONDS + 1);

        // finalize should apply voting resolution (quorum for n=3 is 2)
        meetup.finalize();

        // compute expected outcomes:
        // honestBack = deposit * honesty% = 1 ether * 50% = 0.5 ether
        uint256 honestBack = (TEST_DEPOSIT_AMOUNT * TEST_HONESTY_PERCENT) / 100;
        uint256 remainder = TEST_DEPOSIT_AMOUNT - honestBack;
        // p1 and p2 each should be left with honestBack
        assertEq(meetup.balances(participant1), honestBack);
        assertEq(meetup.balances(participant2), honestBack);
        // winner (participant3) should receive remainders from p1 and p2 => 2 * remainder
        uint256 expectedWinner = remainder * 2;
        assertEq(meetup.balances(participant3), expectedWinner);

        // contract should be finalized
        assertEq(uint8(meetup.contractState()), uint8(EscrowContract.State.Finalized));

        // Withdrawals should work
        vm.prank(participant1); meetup.withdraw();
        vm.prank(participant2); meetup.withdraw();
        vm.prank(participant3); meetup.withdraw();

        // After withdrawals, contract balance should be zero
        assertEq(address(meetup).balance, 0);
    }
}
