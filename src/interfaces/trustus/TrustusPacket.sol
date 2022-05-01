// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

struct TrustusPacket {
    bytes32 request;
    uint256 deadline;
    bytes payload;
    uint8 v;
    bytes32 r;
    bytes32 s;
}
