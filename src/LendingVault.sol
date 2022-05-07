// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721, ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {IBackedNFTLoanFacilitator} from "./interfaces/backed/IBackedNFTLoanFacilitator.sol";
import {TrustusPacket} from "./interfaces/trustus/TrustusPacket.sol";

contract LendingVault is ERC721TokenReceiver {
    // --- Constants ---

    IBackedNFTLoanFacilitator public immutable backed =
        IBackedNFTLoanFacilitator(0x0BacCDD05a729aB8B56e09Ef19c15f953E10885f);

    WETH public immutable weth =
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    bytes32 public immutable DOMAIN_SEPARATOR =
        keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("SingleUserBackedLendingVault"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );

    // --- Fields ---

    // The owner of the vault.
    address public owner;

    // Indicates whether the vault is accepting borrow requests or not.
    bool public active;

    // The NFT collateral contract the vault accepts.
    ERC721 public collateralContract;

    // Minimum viable terms for the vault to accept borrow requests.
    uint16 public minimumPerAnnumInterestRate;
    uint32 public maximumDurationSeconds;
    uint16 public maximumAmountBps;

    // Address of the oracle responsible for floor price attestations.
    address public floorPriceOracle;

    // --- Modifiers ---

    modifier onlyOwner() {
        require(msg.sender == owner, "Unauthorized");
        _;
    }

    modifier isActive() {
        require(active, "Inactive");
        _;
    }

    // --- Constructor ---

    constructor(
        address ownerAddress,
        address loanCollateralContractAddress,
        uint16 loanMinimumPerAnnumInterestRate,
        uint32 loanMaximumDurationSeconds,
        uint16 loanMaximumAmountBps,
        address floorPriceOracleAddress
    ) {
        owner = ownerAddress;
        active = true;

        collateralContract = ERC721(loanCollateralContractAddress);

        minimumPerAnnumInterestRate = loanMinimumPerAnnumInterestRate;
        maximumDurationSeconds = loanMaximumDurationSeconds;
        maximumAmountBps = loanMaximumAmountBps;

        floorPriceOracle = floorPriceOracleAddress;
    }

    receive() external payable {
        // For unwrapping WETH.
    }

    // --- Restricted ---

    function setActive(bool _active) external onlyOwner {
        active = _active;
    }

    function setMinimumPerAnnumInterestRate(uint16 _minimumPerAnnumInterestRate)
        external
        onlyOwner
    {
        minimumPerAnnumInterestRate = _minimumPerAnnumInterestRate;
    }

    function setMaximumDurationSeconds(uint32 _maximumDurationSeconds)
        external
        onlyOwner
    {
        maximumDurationSeconds = _maximumDurationSeconds;
    }

    function setMaximumAmountBps(uint16 _maximumAmountBps) external onlyOwner {
        maximumAmountBps = _maximumAmountBps;
    }

    function seizeCollateral(uint256 loanId, address receiver)
        external
        onlyOwner
    {
        // Since the loan defaulted, seize the collateral token.
        backed.seizeCollateral(loanId, receiver);
    }

    function withdrawFunds(
        uint256 amount,
        address receiver,
        bool unwrap
    ) external onlyOwner {
        if (unwrap) {
            weth.withdraw(amount);
            (bool success, ) = payable(receiver).call{value: amount}("");
            require(success, "ETH payment failed");
        } else {
            weth.transfer(receiver, amount);
        }
    }

    // --- Public ---

    function borrow(TrustusPacket calldata packet, uint256 loanId)
        public
        isActive
    {
        // Fetch the loan requirements.
        IBackedNFTLoanFacilitator.Loan memory loan = backed.loanInfoStruct(
            loanId
        );

        // Verify that the Trustus packet is valid.
        require(packet.deadline >= block.timestamp, "Packet expired");
        require(
            packet.request ==
                keccak256(
                    abi.encodePacked(
                        "twap",
                        "contract",
                        loan.collateralContractAddress
                    )
                ),
            "Invalid packet"
        );

        // Validate the Trustus packet's signature.
        address signer = ecrecover(
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR,
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
            ),
            packet.v,
            packet.r,
            packet.s
        );
        require(signer == floorPriceOracle, "Unauthorized signer");

        // Extract the oracle's attestation of the colleteral contract's floor price.
        uint256 floorPrice = abi.decode(packet.payload, (uint256));

        // Make sure that the loan matches the vault's criteria.
        require(
            !loan.closed &&
                loan.lastAccumulatedTimestamp == 0 &&
                loan.perAnnumInterestRate >= minimumPerAnnumInterestRate &&
                loan.durationSeconds <= maximumDurationSeconds &&
                loan.collateralContractAddress == address(collateralContract) &&
                !loan.allowLoanAmountIncrease &&
                loan.loanAssetContractAddress == address(weth) &&
                loan.loanAmount <= (floorPrice * maximumAmountBps) / 10000,
            "Loan does not match criteria"
        );

        // Transfer WETH from the owner, approve and lend.
        weth.transferFrom(owner, address(this), loan.loanAmount);
        weth.approve(address(backed), loan.loanAmount);
        backed.lend(
            loanId,
            loan.perAnnumInterestRate,
            loan.loanAmount,
            loan.durationSeconds,
            address(this)
        );
    }

    // ERC721 overrides

    function onERC721Received(
        address, // operator
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        // Decode the transfer data.
        (TrustusPacket memory packet, uint128 amount) = abi.decode(
            data,
            (TrustusPacket, uint128)
        );

        // Create a loan request on behalf of the borrower.
        ERC721(msg.sender).approve(address(backed), tokenId);
        uint256 loanId = backed.createLoan(
            tokenId,
            msg.sender,
            minimumPerAnnumInterestRate,
            false,
            amount,
            address(weth),
            maximumDurationSeconds,
            from
        );

        // Accept the loan request.
        this.borrow(packet, loanId);

        return ERC721TokenReceiver.onERC721Received.selector;
    }
}
