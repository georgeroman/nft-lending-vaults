// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {IBackedNFTLoanFacilitator} from "../src/interfaces/backed/IBackedNFTLoanFacilitator.sol";
import {TrustusPacket} from "../src/interfaces/trustus/TrustusPacket.sol";
import {LendingVault} from "../src/LendingVault.sol";

contract TestERC721 is ERC721 {
    constructor() ERC721("Test ERC721", "TEST") {}

    function mint(uint256 tokenId) external {
        _mint(msg.sender, tokenId);
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }
}

contract LendingVaultTest is Test {
    IBackedNFTLoanFacilitator public immutable backed =
        IBackedNFTLoanFacilitator(0x0BacCDD05a729aB8B56e09Ef19c15f953E10885f);

    WETH public immutable weth =
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    TestERC721 public token;
    LendingVault public vault;

    // Entities
    address public owner = vm.addr(0x01);
    address public borrower = vm.addr(0x02);
    uint256 public floorPriceOraclePk = uint256(0x03);
    address public floorPriceOracle = vm.addr(floorPriceOraclePk);

    // Vault terms
    uint16 public loanMinimumPerAnnumInterestRate = 100;
    uint32 public loanMaximumDurationSeconds = 7 days;
    uint16 public loanMaximumAmountBps = 5000;

    function setUp() public {
        token = new TestERC721();
        vault = new LendingVault(
            owner,
            address(token),
            loanMinimumPerAnnumInterestRate,
            loanMaximumDurationSeconds,
            loanMaximumAmountBps,
            floorPriceOracle
        );
    }

    // --- Helpers ---

    function getSignedPacket(
        address contractAddress,
        uint256 floorPrice,
        uint256 deadline
    ) public returns (TrustusPacket memory packet) {
        // Build the oracle floor price attestation.
        packet.request = keccak256(
            abi.encodePacked("twap", "contract", contractAddress)
        );
        packet.deadline = deadline;
        packet.payload = abi.encode(floorPrice);

        // Have the oracle sign the floor price attestation.
        {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(
                floorPriceOraclePk,
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        vault.DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "VerifyPacket(bytes32 request,uint256 deadline,bytes payload)"
                                ),
                                packet.request,
                                packet.deadline,
                                keccak256(packet.payload)
                            )
                        )
                    )
                )
            );
            packet.v = v;
            packet.r = r;
            packet.s = s;
        }
    }

    // --- Tests ---

    function testBorrow() public {
        uint256 tokenId = 100;
        uint128 floorPrice = 1 ether;
        uint128 amount = (floorPrice * vault.maximumAmountBps()) / 10000;

        vm.startPrank(borrower);
        token.mint(tokenId);
        token.setApprovalForAll(address(backed), true);
        uint256 loanId = backed.createLoan(
            tokenId,
            address(token),
            vault.minimumPerAnnumInterestRate(),
            false,
            amount,
            address(weth),
            vault.maximumDurationSeconds(),
            borrower
        );
        vm.stopPrank();

        deal(address(weth), owner, amount);
        vm.prank(owner);
        weth.approve(address(vault), amount);

        TrustusPacket memory packet = getSignedPacket(
            address(token),
            floorPrice,
            block.timestamp + 1
        );
        vault.borrow(packet, loanId);

        assert(
            weth.balanceOf(borrower) ==
                amount - (amount * backed.originationFeeRate()) / 1000
        );
    }

    function testBorrowViaTransfer() public {
        uint256 tokenId = 100;
        uint128 floorPrice = 1 ether;
        uint128 amount = (floorPrice * vault.maximumAmountBps()) / 10000;

        deal(address(weth), owner, amount);
        vm.prank(owner);
        weth.approve(address(vault), amount);

        TrustusPacket memory packet = getSignedPacket(
            address(token),
            floorPrice,
            block.timestamp + 1
        );

        vm.startPrank(borrower);
        token.mint(tokenId);
        token.safeTransferFrom(
            borrower,
            address(vault),
            tokenId,
            abi.encode(packet, amount)
        );

        assert(
            weth.balanceOf(borrower) ==
                amount - (amount * backed.originationFeeRate()) / 1000
        );
    }

    function testBorrowWithLoanRepaymentAndWithdraw() public {
        uint256 tokenId = 100;
        uint128 floorPrice = 1 ether;
        uint128 amount = (floorPrice * vault.maximumAmountBps()) / 10000;

        vm.startPrank(borrower);
        token.mint(tokenId);
        token.setApprovalForAll(address(backed), true);
        uint256 loanId = backed.createLoan(
            tokenId,
            address(token),
            vault.minimumPerAnnumInterestRate(),
            false,
            amount,
            address(weth),
            vault.maximumDurationSeconds(),
            borrower
        );
        vm.stopPrank();

        deal(address(weth), owner, amount);
        vm.prank(owner);
        weth.approve(address(vault), amount);

        TrustusPacket memory packet = getSignedPacket(
            address(token),
            floorPrice,
            block.timestamp + 1
        );

        vm.startPrank(borrower);
        vault.borrow(packet, loanId);

        assert(
            weth.balanceOf(borrower) ==
                amount - (amount * backed.originationFeeRate()) / 1000
        );

        vm.warp(block.timestamp + vault.maximumDurationSeconds());

        uint256 owed = backed.totalOwed(loanId);
        uint256 profit = owed - amount;
        deal(address(weth), borrower, owed);
        weth.approve(address(backed), owed);

        backed.repayAndCloseLoan(loanId);
        vm.stopPrank();

        assert(weth.balanceOf(address(vault)) == amount + profit);

        vm.prank(owner);
        vault.withdrawFunds(amount + profit, owner, false);

        assert(weth.balanceOf(owner) == amount + profit);
    }

    function testBorrowWithCollateralSeize() public {
        uint256 tokenId = 100;
        uint128 floorPrice = 1 ether;
        uint128 amount = (floorPrice * vault.maximumAmountBps()) / 10000;

        vm.startPrank(borrower);
        token.mint(tokenId);
        token.setApprovalForAll(address(backed), true);
        uint256 loanId = backed.createLoan(
            tokenId,
            address(token),
            vault.minimumPerAnnumInterestRate(),
            false,
            amount,
            address(weth),
            vault.maximumDurationSeconds(),
            borrower
        );
        vm.stopPrank();

        deal(address(weth), owner, amount);
        vm.prank(owner);
        weth.approve(address(vault), amount);

        TrustusPacket memory packet = getSignedPacket(
            address(token),
            floorPrice,
            block.timestamp + 1
        );

        vm.prank(borrower);
        vault.borrow(packet, loanId);

        assert(
            weth.balanceOf(borrower) ==
                amount - (amount * backed.originationFeeRate()) / 1000
        );

        vm.warp(block.timestamp + vault.maximumDurationSeconds() + 1);

        vm.prank(owner);
        vault.seizeCollateral(loanId, owner);

        assert(ERC721(token).ownerOf(tokenId) == owner);
    }

    function testFailBorrowWithInvalidTerms() public {
        uint256 tokenId = 100;
        uint128 floorPrice = 1 ether;
        // Borrow more than what the vault accepts.
        uint128 amount = (floorPrice * vault.maximumAmountBps()) / 10000 + 1;

        TrustusPacket memory packet = getSignedPacket(
            address(token),
            floorPrice,
            block.timestamp + 1
        );

        vm.startPrank(borrower);
        token.mint(tokenId);
        token.safeTransferFrom(
            borrower,
            address(vault),
            tokenId,
            abi.encode(packet, amount)
        );
    }

    function testFailBorrowWithNoApprovedFunds() public {
        uint256 tokenId = 100;
        uint128 floorPrice = 1 ether;
        uint128 amount = (floorPrice * vault.maximumAmountBps()) / 10000;

        TrustusPacket memory packet = getSignedPacket(
            address(token),
            floorPrice,
            block.timestamp + 1
        );

        vm.startPrank(borrower);
        token.mint(tokenId);
        token.safeTransferFrom(
            borrower,
            address(vault),
            tokenId,
            abi.encode(packet, amount)
        );
    }

    function testCannotBorrowWhenVaultIsInactive() public {
        uint256 tokenId = 100;
        uint128 floorPrice = 1 ether;
        uint128 amount = (floorPrice * vault.maximumAmountBps()) / 10000;

        vm.prank(owner);
        vault.setActive(false);

        TrustusPacket memory packet = getSignedPacket(
            address(token),
            floorPrice,
            block.timestamp + 1
        );

        vm.startPrank(borrower);
        token.mint(tokenId);

        vm.expectRevert("Inactive");
        token.safeTransferFrom(
            borrower,
            address(vault),
            tokenId,
            abi.encode(packet, amount)
        );
    }
}
