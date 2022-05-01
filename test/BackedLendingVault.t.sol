// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {IBackedNFTLoanFacilitator} from "../src/interfaces/backed/IBackedNFTLoanFacilitator.sol";
import {TrustusPacket} from "../src/interfaces/trustus/TrustusPacket.sol";
import {BackedLendingVault} from "../src/BackedLendingVault.sol";

contract LendingVaultTest is Test {
    ERC721 public wizards = ERC721(0x521f9C7505005CFA19A8E5786a9c3c9c9F5e6f42);

    IBackedNFTLoanFacilitator public immutable backed =
        IBackedNFTLoanFacilitator(0x0BacCDD05a729aB8B56e09Ef19c15f953E10885f);

    WETH public immutable weth =
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    BackedLendingVault public vault;

    uint256 public floorPriceOraclePk = uint256(0x01);
    address public floorPriceOracle = vm.addr(floorPriceOraclePk);

    // As of block 14693870.
    uint256 public tokenId = 124;
    address public borrower = 0xD584fE736E5aad97C437c579e884d15B17A54a51;
    address public lender = 0x6555e1CC97d3cbA6eAddebBCD7Ca51d75771e0B8;

    function setUp() public {
        vault = new BackedLendingVault(
            wizards,
            100,
            7 days,
            5000,
            floorPriceOracle
        );
    }

    function testLoanRepaid() public {
        // For ease of testing, clear the WETH balance of the borrower and lender.
        deal(address(weth), borrower, 0);
        deal(address(weth), lender, 1 ether);

        // Request loan on token.
        vm.prank(borrower);
        wizards.setApprovalForAll(address(backed), true);
        vm.prank(borrower);
        uint256 loanId = backed.createLoan(
            tokenId,
            address(wizards),
            150,
            false,
            1 ether,
            address(weth),
            7 days,
            borrower
        );

        assert(wizards.ownerOf(tokenId) == address(backed));

        // Provide liquidity to the vault.
        vm.prank(lender);
        weth.approve(address(vault), 1 ether);
        vm.prank(lender);
        vault.deposit(1 ether, lender);

        uint256 liquidityShares = vault.balanceOf(lender);
        assert(liquidityShares == 1 ether);

        // Have the oracle sign the twap floor price message.
        TrustusPacket memory packet;
        packet.request = keccak256(
            abi.encodePacked("twap", "contract", address(wizards))
        );
        packet.deadline = block.timestamp + 1 days;
        packet.payload = abi.encode(2 ether);
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

        // Relay the loan request to the vault.
        vault.borrow(packet, loanId);

        assert(weth.balanceOf(borrower) == 0.99 ether);

        // Fast-forward to the loan repayment deadline.
        vm.warp(block.timestamp + 7 days);

        // Repay and close loan.
        uint256 amountOwed = backed.totalOwed(loanId);
        deal(address(weth), borrower, amountOwed);
        vm.prank(borrower);
        weth.approve(address(backed), amountOwed);
        vm.prank(borrower);
        backed.repayAndCloseLoan(loanId);

        assert(wizards.ownerOf(tokenId) == borrower);
        assert(weth.balanceOf(address(vault)) == amountOwed);

        // Withdraw liquidity.
        vm.prank(lender);
        vault.withdraw(liquidityShares, lender, lender);

        // TODO: This doesn't work yet, we should account for the accrued interest in the vault.
        // assert(weth.balanceOf(lender) == amountOwed);
    }

    function testLoanDefaulted() public {
        // For ease of testing, clear the WETH balance of the borrower and lender.
        deal(address(weth), borrower, 0);
        deal(address(weth), lender, 1 ether);

        // Request loan on token.
        vm.prank(borrower);
        wizards.setApprovalForAll(address(backed), true);
        vm.prank(borrower);
        uint256 loanId = backed.createLoan(
            tokenId,
            address(wizards),
            150,
            false,
            1 ether,
            address(weth),
            7 days,
            borrower
        );

        assert(wizards.ownerOf(tokenId) == address(backed));

        // Provide liquidity to the vault.
        vm.prank(lender);
        weth.approve(address(vault), 1 ether);
        vm.prank(lender);
        vault.deposit(1 ether, lender);

        uint256 liquidityShares = vault.balanceOf(lender);
        assert(liquidityShares == 1 ether);

        // Have the oracle sign the twap floor price message.
        TrustusPacket memory packet;
        packet.request = keccak256(
            abi.encodePacked("twap", "contract", address(wizards))
        );
        packet.deadline = block.timestamp + 1 days;
        packet.payload = abi.encode(2 ether);
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

        // Relay the loan request to the vault.
        vault.borrow(packet, loanId);

        assert(weth.balanceOf(borrower) == 0.99 ether);

        // Fast-forward to the loan repayment deadline.
        vm.warp(block.timestamp + 7 days + 1 seconds);

        // Seize the loan's collateral.
        vault.seizeCollateral(loanId);

        assert(
            wizards.ownerOf(tokenId) ==
                address(vault.collateralContractNFTXVault())
        );
        assert(weth.balanceOf(address(vault)) > 1 ether);
    }
}
