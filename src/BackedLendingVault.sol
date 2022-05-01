// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721, ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {IBackedNFTLoanFacilitator} from "./interfaces/backed/IBackedNFTLoanFacilitator.sol";
import {INFTXVaultFactory} from "./interfaces/nftx/INFTXVaultFactory.sol";
import {INFTXVault} from "./interfaces/nftx/INFTXVault.sol";
import {TrustusPacket} from "./interfaces/trustus/TrustusPacket.sol";
import {IUniswapRouter} from "./interfaces/uniswap/IUniswapRouter.sol";

contract BackedLendingVault is ERC4626, ERC721TokenReceiver {
    IBackedNFTLoanFacilitator public immutable backed =
        IBackedNFTLoanFacilitator(0x0BacCDD05a729aB8B56e09Ef19c15f953E10885f);

    INFTXVaultFactory public immutable nftx =
        INFTXVaultFactory(0xBE86f647b167567525cCAAfcd6f881F1Ee558216);

    IUniswapRouter public immutable sushiswap =
        IUniswapRouter(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

    WETH public immutable weth =
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    ERC721 public collateralContract;
    ERC20 public collateralContractNFTXVault;

    uint256 public minimumPerAnnumInterestRate;
    uint256 public maximumDurationSeconds;
    uint256 public maximumAmountBps;

    address public floorPriceOracle;

    uint256 public totalAmountLent;

    constructor(
        ERC721 loanCollateralContract,
        uint256 loanMinimumPerAnnumInterestRate,
        uint256 loanMaximumDurationSeconds,
        uint256 loanMaximumAmountBps,
        address floorPriceOracleAddress
    )
        ERC4626(
            weth,
            string.concat(
                "Backed Lending Vault - ",
                loanCollateralContract.name()
            ),
            string.concat("blv", loanCollateralContract.symbol())
        )
    {
        collateralContract = loanCollateralContract;
        collateralContractNFTXVault = ERC20(
            nftx.vaultsForAsset(address(loanCollateralContract))[0]
        );

        minimumPerAnnumInterestRate = loanMinimumPerAnnumInterestRate;
        maximumDurationSeconds = loanMaximumDurationSeconds;
        maximumAmountBps = loanMaximumAmountBps;

        floorPriceOracle = floorPriceOracleAddress;
    }

    function borrow(TrustusPacket calldata packet, uint256 loanId) external {
        // Fetch the loan requirements.
        IBackedNFTLoanFacilitator.Loan memory loan = backed.loanInfoStruct(
            loanId
        );

        // Verify that the packet is valid.
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

        // Validate the packet's signature.
        address signer = ecrecover(
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR(),
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

        // Approve WETH and lend.
        weth.approve(address(backed), loan.loanAmount);
        backed.lend(
            loanId,
            loan.perAnnumInterestRate,
            loan.loanAmount,
            loan.durationSeconds,
            address(this)
        );

        // Keep track of the total amount lent.
        totalAmountLent += loan.loanAmount;
    }

    function seizeCollateral(uint256 loanId) external {
        // Fetch the loan requirements.
        IBackedNFTLoanFacilitator.Loan memory loan = backed.loanInfoStruct(
            loanId
        );

        // Since the loan defaulted, seize the collateral.
        backed.seizeCollateral(loanId, address(this));

        // Send the seized token to the NFTX vault.
        collateralContract.approve(
            address(collateralContractNFTXVault),
            loan.collateralTokenId
        );
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = loan.collateralTokenId;
        uint256[] memory amounts = new uint256[](0);
        INFTXVault(address(collateralContractNFTXVault)).mint(
            tokenIds,
            amounts
        );

        // Fetch the NFTX vault token balance.
        uint256 balance = collateralContractNFTXVault.balanceOf(address(this));
        collateralContractNFTXVault.approve(address(sushiswap), balance);

        // Swap the NFTX vault token to WETH on Sushiswap.
        address[] memory path = new address[](2);
        path[0] = address(collateralContractNFTXVault);
        path[1] = address(weth);
        sushiswap.swapExactTokensForTokens(
            balance,
            1,
            path,
            address(this),
            block.timestamp
        );
    }

    // ERC4626 overrides

    function totalAssets() public view override returns (uint256) {
        return totalAmountLent + weth.balanceOf(address(this));
    }
}
