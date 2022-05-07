# Peer-to-protocol NFT lending

A basic example of building a peer-to-protocol NFT lending protocol (like [JPEGd](https://jpegd.io/)) on top of an existing peer-to-peer protocol (in this case [Backed](https://www.withbacked.xyz/)). The way it works is by having designated lending vaults that are designed to accept any loans that match certain minimum criteria (eg. interest rate, duration, amount borrowed relative to the collection's floor price). In case a loan gets repaid on time, the interest goes back to the lending vault's owner. If the loan defaults, the NFT collateral will get seized and transferred to the vault owner (who can then liquidate as they desire).

A few notes:

- Each lending vault is owned by a single user (eg. no shared deposits).
- Each lending vault can only handle loans having a specific collateral NFT. However, this could easily be extended to support multiple NFT contracts.
- The NFT floor price oracle is built on the [Trustus](https://github.com/ZeframLou/trustus) standard (the actual pricing data fetched can be fetched via [Reservoir](https://api.reservoir.tools/#/2.%20Aggregator/getOracleCollectionsCollectionFlooraskV1)).

# Usage

```bash
# Install
forge install

# Build
forge build --via-ir

# Test
forge test --fork-url https://eth-mainnet.alchemyapi.io/v2/${ALCHEMY_KEY} -vvv
```
