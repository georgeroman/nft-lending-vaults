# Peer-to-protocol NFT lending

A basic example of building a peer-to-protocol NFT lending protocol (like [JPEGd](https://jpegd.io/)) on top of an existing peer-to-peer protocol (in this case [Backed](https://www.withbacked.xyz/)). The way it works is by having designated lending vaults that are designed to accept any loans that match certain minimum criteria (eg. interest rate, duration, amount borrowed relative to the collection's floor price). In case a loan gets repaid on time, the interest goes back to the lending vault's liquidity providers in a pro-rata fashion. If the loan defaults, the NFT collateral is liquidated via NFTX with the proceeds going to the liqudity providers.

A few notes:

- Each lending vault can only handle loans having a specific collateral NFT. However, this could easily be extended to support multiple NFT contracts.
- Since liquidation is done via NFTX, its important that the NFT collateral has a liquid NFTX vault, otherwise in case of loan defaults, the vault might get stuck with the NFT collateral.
- The NFT floor price oracle is built on the [Trustus](https://github.com/ZeframLou/trustus) standard (the actual pricing data fetched can be fetched via [Reservoir](https://api.reservoir.tools/#/2.%20Aggregator/getOracleCollectionsCollectionFlooraskV1)).
- This is just a proof of concept, the code is not fully tested and there are some issues with the accounting logic.

# Usage

```bash
# Install
forge install

# Build
forge build

# Test
forge test --fork-url https://eth-mainnet.alchemyapi.io/v2/${ALCHEMY_KEY} --fork-block-number 14693870 -vvv
```
