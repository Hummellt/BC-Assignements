// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EscrowContract} from "src/EscrowContract.sol";

contract EscrowContractEnhancedTest is Test {
    EscrowContract meetup;

    address participant1;
    address participant2;
    address participant3;

    uint256 constant PK1 = 0x1;
    uint256 constant PK2 = 0x2;
    uint256 constant PK3 = 0x3;

    uint256 meetingTime;
    uint256 deposit = 1 ether;
    uint256 penaltyRate = 200; // 2% per minute

    // new test config values matching updated constructor
    uint8 constant HONESTY_PERCENT = 50;
    uint256 constant REPORTING_WINDOW = 3600;

    function setUp() public {
        participant1 = vm.addr(PK1);
        participant2 = vm.addr(PK2);
        participant3 = vm.addr(PK3);

        vm.deal(participant1, 5 ether);
        vm.deal(participant2, 5 ether);
        vm.deal(participant3, 5 ether);

        meetingTime = block.timestamp + 1 hours;
    }

    function testConfirmArrival_RevertsOnSelfAttestOrDuplicateAttester() public {
        address[] memory parts = new address[](3);
        parts[0] = participant1;
        parts[1] = participant2;
        parts[2] = participant3;
        meetup = new EscrowContract(parts, meetingTime, deposit, penaltyRate, HONESTY_PERCENT, REPORTING_WINDOW);

        vm.prank(participant1);
        meetup.deposit{value: deposit}();

        vm.warp(meetingTime + 60);

        // create digest signed by participant1 (self attest)
        bytes32 digest = meetup.hashAttestation(participant1, participant1, participant2, block.timestamp);
        bytes memory sig = _sign(PK1, digest);

        vm.startPrank(participant1);
        vm.expectRevert("Attesters cannot be the arriver");
        meetup.confirmArrival(participant1, participant2, block.timestamp, sig, sig, "ipfs://x");
        vm.stopPrank();

        // duplicate attesters
        digest = meetup.hashAttestation(participant1, participant2, participant2, block.timestamp);
        sig = _sign(PK2, digest);

        vm.startPrank(participant1);
        vm.expectRevert("Attesters must be distinct");
        meetup.confirmArrival(participant2, participant2, block.timestamp, sig, sig, "ipfs://x");
        vm.stopPrank();
    }

    function testConfirmArrival_OrderAgnosticSignaturesAndFinalizePenaltyDistribution() public {
        address[] memory parts = new address[](3);
        parts[0] = participant1;
        parts[1] = participant2;
        parts[2] = participant3;
        meetup = new EscrowContract(parts, meetingTime, deposit, penaltyRate, HONESTY_PERCENT, REPORTING_WINDOW);

        // everyone deposits
        vm.prank(participant1); meetup.deposit{value: deposit}();
        vm.prank(participant2); meetup.deposit{value: deposit}();
        vm.prank(participant3); meetup.deposit{value: deposit}();

        // participant1 and participant2 arrive on time
        vm.warp(meetingTime + 0);
        uint256 t_on = block.timestamp;
        bytes32 d12 = meetup.hashAttestation(participant1, participant2, participant3, t_on);
        bytes memory s_2 = _sign(PK2, d12);
        bytes memory s_3 = _sign(PK3, d12);

        vm.startPrank(participant1);
        meetup.confirmArrival(participant2, participant3, t_on, s_2, s_3, "ipfs://p1");
        vm.stopPrank();

        // participant2 needs signatures for an attestation where the arriver is participant2
        bytes32 d21 = meetup.hashAttestation(participant2, participant1, participant3, t_on);
        bytes memory s_1 = _sign(PK1, d21);
        bytes memory s_3_b = _sign(PK3, d21);
        vm.startPrank(participant2);
        meetup.confirmArrival(participant1, participant3, t_on, s_1, s_3_b, "ipfs://p1");
        vm.stopPrank();

        // participant3 is late by 10 minutes
        vm.warp(meetingTime + 10 minutes);
        uint256 t_late = block.timestamp;
        bytes32 d3 = meetup.hashAttestation(participant3, participant1, participant2, t_late);
        bytes memory sig1 = _sign(PK1, d3);
        bytes memory sig2 = _sign(PK2, d3);

        vm.startPrank(participant3);
        meetup.confirmArrival(participant1, participant2, t_late, sig1, sig2, "ipfs://p3");
        vm.stopPrank();

        // advance to allow finalize
        vm.warp(meetingTime + 2 hours);
        meetup.finalize();

        // deposit = 1 ether. penalty for 10 min at 2%/min = 20% i.e. 0.2 ether
        uint256 expectedPenalty = (deposit * 10 * penaltyRate) / 10000;
        // punctualParticipantsCount = 2 -> reward per punctual = expectedPenalty / 2
        uint256 rewardPerPunctual = expectedPenalty / 2;

        // participant3 balance should have been reduced by expectedPenalty
        assertEq(meetup.balances(participant3), deposit - expectedPenalty);
        // punctual ones each got reward
        assertEq(meetup.balances(participant1), deposit + rewardPerPunctual);
        assertEq(meetup.balances(participant2), deposit + rewardPerPunctual);

        // withdrawals work
        vm.prank(participant1);
        meetup.withdraw();
        vm.prank(participant2);
        meetup.withdraw();
        vm.prank(participant3);
        meetup.withdraw();
    }

    function testConfirmMutualArrival_Success() public {
        address[] memory parts = new address[](2);
        parts[0] = participant1;
        parts[1] = participant2;
        meetup = new EscrowContract(parts, meetingTime, deposit, penaltyRate, HONESTY_PERCENT, REPORTING_WINDOW);

        // both deposit
        vm.prank(participant1); meetup.deposit{value: deposit}();
        vm.prank(participant2); meetup.deposit{value: deposit}();

        // Advance time to after meeting
        vm.warp(meetingTime + 10 minutes);
        uint256 ts = block.timestamp;

        // Build mutual digests and signatures:
        // participant2 signs mutual attestation for (a=participant1,b=participant2,ts) -> this is "sigOtherForCaller" when caller is participant1
        bytes32 d_for_p1 = meetup.hashMutualAttestation(participant1, participant2, ts);
        bytes memory sig2_for_p1 = _sign(PK2, d_for_p1);

        // participant1 signs mutual attestation for (a=participant2,b=participant1,ts) -> this is "sigCallerForOther" when caller is participant1
        bytes32 d_for_p2 = meetup.hashMutualAttestation(participant2, participant1, ts);
        bytes memory sig1_for_p2 = _sign(PK1, d_for_p2);

        // Caller (participant1) submits both signatures to confirm mutual arrival
        vm.startPrank(participant1);
        meetup.confirmMutualArrival(participant2, ts, sig2_for_p1, sig1_for_p2, "ipfs://mutual");
        vm.stopPrank();

        assertEq(meetup.arrivalTimes(participant1), ts, "Arrival time for p1 incorrect");
        assertEq(meetup.arrivalTimes(participant2), ts, "Arrival time for p2 incorrect");
        assertEq(meetup.arrivalProofIPFS(participant1), "ipfs://mutual");
        assertEq(meetup.arrivalProofIPFS(participant2), "ipfs://mutual");
    }

    // helper to avoid stack-too-deep in tests
    function _sign(uint256 pk, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}