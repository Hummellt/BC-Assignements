// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EscrowContract} from "src/EscrowContract.sol";

contract EscrowContractTest is Test {
    EscrowContract public meetup;

    address public owner; // Not explicitly used in contract, but good for general testing
    address public participant1;
    address public participant2;
    address public participant3; // For multi-participant scenarios
    address public nonParticipant;

    uint256 public immutable TEST_DEPOSIT_AMOUNT = 1 ether;
    uint256 public immutable TEST_PENALTY_RATE = 200; // 2% per minute
    uint256 public TEST_MEETING_TIME;

    // --- Events to test ---
    event Deposited(address indexed participant, uint256 amount);
    event Arrived(address indexed participant, uint256 arrivalTime);
    event ArrivalProofSubmitted(address indexed participant, string ipfsHash);

    function setUp() public {
        // Set up test accounts
        owner = makeAddr("owner");
        participant1 = makeAddr("participant1");
        participant2 = makeAddr("participant2");
        participant3 = makeAddr("participant3");
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
            TEST_PENALTY_RATE
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
            TEST_PENALTY_RATE
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
            TEST_PENALTY_RATE
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
            TEST_PENALTY_RATE
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
            TEST_PENALTY_RATE
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
        meetup = new EscrowContract(participants_, TEST_MEETING_TIME, TEST_DEPOSIT_AMOUNT, TEST_PENALTY_RATE);

        vm.startPrank(participant1);
        vm.expectRevert("Incorrect deposit amount");
        meetup.deposit{value: TEST_DEPOSIT_AMOUNT - 1}(); // Send less than required
        vm.stopPrank();
    }

    function testDeposit_RevertsOnNonParticipant() public {
        address[] memory participants_ = new address[](2);
        participants_[0] = participant1;
        participants_[1] = participant2;
        meetup = new EscrowContract(participants_, TEST_MEETING_TIME, TEST_DEPOSIT_AMOUNT, TEST_PENALTY_RATE);

        vm.prank(nonParticipant);
        // Expect a revert with the specific error string from the require statement.
        vm.expectRevert("Not a participant");
        meetup.deposit{value: TEST_DEPOSIT_AMOUNT}();
    }

    // --- Confirm Arrival Tests ---

    function testConfirmArrival_Success() public {
        address[] memory participants_ = new address[](2);
        participants_[0] = participant1;
        participants_[1] = participant2;
        meetup = new EscrowContract(participants_, TEST_MEETING_TIME, TEST_DEPOSIT_AMOUNT, TEST_PENALTY_RATE);

        // Deposit first
        vm.prank(participant1);
        meetup.deposit{value: TEST_DEPOSIT_AMOUNT}();

        // Advance time to after the meeting
        vm.warp(TEST_MEETING_TIME + 10 minutes);

        vm.startPrank(participant1);
        vm.expectEmit(true, false, false, true); // ArrivalProofSubmitted(address indexed, string)
        emit ArrivalProofSubmitted(participant1, "ipfs://proof1"); // check topic1 (participant) and data (ipfsHash)
        vm.expectEmit(true, false, false, true); // Arrived(address indexed, uint256)
        emit Arrived(participant1, block.timestamp);
        meetup.confirmArrival("ipfs://proof1");
        vm.stopPrank();

        assertEq(meetup.arrivalTimes(participant1), TEST_MEETING_TIME + 10 minutes, "Arrival time incorrect");
        assertEq(meetup.arrivalProofIPFS(participant1), "ipfs://proof1", "IPFS hash not stored");
        assertEq(uint8(meetup.contractState()), uint8(EscrowContract.State.InProgress), "State not InProgress after first arrival");
    }

    function testConfirmArrival_RevertsBeforeMeetingTime() public {
        address[] memory participants_ = new address[](2);
        participants_[0] = participant1;
        participants_[1] = participant2;
        meetup = new EscrowContract(participants_, TEST_MEETING_TIME, TEST_DEPOSIT_AMOUNT, TEST_PENALTY_RATE);

        // Deposit first
        vm.prank(participant1);
        meetup.deposit{value: TEST_DEPOSIT_AMOUNT}();

        // Time is still before TEST_MEETING_TIME (from setUp)
        vm.startPrank(participant1);
        vm.expectRevert("Meeting time not reached");
        meetup.confirmArrival("ipfs://proof1");
        vm.stopPrank();
    }

    function testConfirmArrival_RevertsOnEmptyIpfsHash() public {
        address[] memory participants_ = new address[](2);
        participants_[0] = participant1;
        participants_[1] = participant2;
        meetup = new EscrowContract(participants_, TEST_MEETING_TIME, TEST_DEPOSIT_AMOUNT, TEST_PENALTY_RATE);

        vm.prank(participant1);
        meetup.deposit{value: TEST_DEPOSIT_AMOUNT}();

        vm.warp(TEST_MEETING_TIME + 10 minutes);

        vm.startPrank(participant1);
        vm.expectRevert("IPFS hash required");
        meetup.confirmArrival("");
        vm.stopPrank();
    }
}
