// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IBackedNFTLoanFacilitator {
    struct Loan {
        bool closed;
        uint16 perAnnumInterestRate;
        uint32 durationSeconds;
        uint40 lastAccumulatedTimestamp;
        address collateralContractAddress;
        bool allowLoanAmountIncrease;
        uint88 originationFeeRate;
        address loanAssetContractAddress;
        uint128 accumulatedInterest;
        uint128 loanAmount;
        uint256 collateralTokenId;
    }

    function loanInfoStruct(uint256 loanId) external view returns (Loan memory);

    function totalOwed(uint256 loanId) external view returns (uint256);

    function createLoan(
        uint256 collateralTokenId,
        address collateralContractAddress,
        uint16 maxPerAnnumInterest,
        bool allowLoanAmountIncrease,
        uint128 minLoanAmount,
        address loanAssetContractAddress,
        uint32 minDurationSeconds,
        address mintBorrowTicketTo
    ) external returns (uint256 id);

    function lend(
        uint256 loanId,
        uint16 interestRate,
        uint128 amount,
        uint32 durationSeconds,
        address sendLendTicketTo
    ) external;

    function seizeCollateral(uint256 loanId, address sendCollateralTo) external;

    function repayAndCloseLoan(uint256 loanId) external;
}
