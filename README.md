# CCIP NFT Bridge — Cross-Chain NFT Transfer with Metadata Preservation

A production-oriented, burn-and-mint NFT bridge between **Avalanche Fuji** and **Arbitrum
Sepolia**, built with [Foundry](https://book.getfoundry.sh/) and
[Chainlink CCIP](https://docs.chain.link/ccip). Includes a Node.js CLI for triggering
transfers and a Docker environment to run it in.

> **⚠️ Important — read this first.** This repository contains fully-written, ready-to-deploy
> Solidity contracts, Foundry scripts/tests, and a working CLI. It was authored in a sandboxed
> environment **without outbound access to RPC endpoints or funded testnet wallets**, so the
> contracts have **not actually been deployed on-chain** by me, and I could not run `forge
> build`/`forge test` myself to double-check compilation (the sandbox's network allowlist blocks
> `objects.githubusercontent.com`, which is where Foundry's binary releases are hosted, so
> `foundryup` couldn't even install `forge`). The `deployment.json` in this repo is a
> **placeholder** with syntactically-valid addresses so tooling that checks the file's shape
> works, but nothing is deployed at those addresses yet.
>
> To go from "code" to "working bridge" you need to: install Foundry, run `forge build`/`forge
> test` to confirm everything compiles (I've written it carefully against OpenZeppelin v5 +
> Chainlink CCIP APIs, but you should verify), fund a wallet with testnet AVAX/ETH/LINK, and run
> the deploy script in `script/Deploy.s.sol`, which will overwrite `deployment.json` with real
> addresses and mint the test NFT described below. Everything downstream (the CLI, the
> verification steps) is designed to work against whatever real addresses that script produces.

## Architecture

```
                     ┌─────────────────────┐                    ┌─────────────────────┐
                     │   Avalanche Fuji     │                    │   Arbitrum Sepolia   │
                     │                      │                    │                      │
   sendNFT() ───────▶│  CCIPNFTBridge       │──CCIP message─────▶│  CCIPNFTBridge       │
   (owner burns      │  - burns NFT         │  (tokenId,          │  - validates sender  │
   tokenId on Fuji)  │  - pays LINK fee     │   tokenURI,         │  - mints NFT with    │
                     │  - sends message     │   receiver)         │    same tokenId +    │
                     │                      │                    │    tokenURI          │
                     │  CrossChainNFT       │                    │  CrossChainNFT       │
                     │  (ERC-721)           │                    │  (ERC-721)           │
                     └─────────────────────┘                    └─────────────────────┘
                              ▲                                          │
                              │            CCIP Router (Chainlink DON)   │
                              └──────────────────────────────────────────┘
```

Design highlights:

- **Burn-and-mint, not lock-and-mint.** The NFT is destroyed on the source chain and an
  identical copy (same `tokenId` + `tokenURI`) is minted on the destination chain, so total
  supply across all chains stays constant — no wrapped/duplicate assets.
- **Bridge-only minting.** `CrossChainNFT.mint()` is guarded by an `onlyBridge` modifier; only
  the `CCIPNFTBridge` contract can ever create new tokens.
- **Sender + source-chain validation.** `_ccipReceive` rejects any message that doesn't come
  from an explicitly allowlisted `(sourceChainSelector, senderAddress)` pair — i.e., only the
  sibling `CCIPNFTBridge` deployment on an allowlisted chain can trigger a mint.
  Both allowlists (`allowlistedSourceChains`) and the specific sibling address per chain
  (`remoteBridges`) are checked, so a malicious contract on a permitted chain still can't spoof
  the deployment.
- **Idempotency.** Both `CrossChainNFT.mint()` (reverts if the tokenId already exists) and
  `CCIPNFTBridge._ccipReceive()` (tracks `processedMessages[messageId]` and checks
  `nft.exists(tokenId)` before minting) guard against double-minting, even though CCIP itself
  already guarantees exactly-once delivery per message id.

## Repository layout

```
├── foundry.toml              # Foundry config + RPC/etherscan profiles
├── remappings.txt
├── src/
│   ├── CrossChainNFT.sol     # ERC-721 with bridge-only mint
│   └── CCIPNFTBridge.sol     # CCIP send/receive logic
├── script/
│   └── Deploy.s.sol          # Multi-fork deploy + wire-up + test mint + deployment.json writer
├── test/
│   ├── CrossChainNFT.t.sol
│   ├── CCIPNFTBridge.t.sol
│   └── mocks/                # MockRouterClient, MockLinkToken (for isolated unit tests)
├── cli/
│   ├── transfer.js           # `npm run transfer` entry point
│   ├── status.js             # `npm run status` — poll destination chain for delivery
│   ├── config.js             # chain/env configuration, reads deployment.json
│   ├── abi/                  # hand-maintained ABIs (see note below)
│   └── lib/                  # argv parsing, logger, transfer-record store
├── data/
│   └── nft_transfers.json    # transfer audit trail (JSON array, schema below)
├── logs/
│   └── transfers.log         # append-only human-readable log
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── deployment.json           # placeholder — overwritten by script/Deploy.s.sol
└── package.json
```

> **Note on `cli/abi/*.json`:** These were hand-written to match the contracts exactly (rather
> than generated by `forge build`, since I couldn't run Foundry in this sandbox). After you run
> `forge build` locally, you can optionally swap the CLI to import
> `out/CCIPNFTBridge.sol/CCIPNFTBridge.json` / `out/CrossChainNFT.sol/CrossChainNFT.json`
> directly (their `.abi` field) for a single source of truth — the hand-written ABIs are a
> strict subset of the real one, so both work.

## Prerequisites

1. [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)
2. Node.js ≥ 18 and npm
3. Docker + Docker Compose (for the containerized CLI)
4. A wallet funded on **both** testnets:
   - Testnet AVAX on Avalanche Fuji — [faucet](https://faucets.chain.link/fuji)
   - Testnet ETH on Arbitrum Sepolia — [faucet](https://faucets.chain.link/arbitrum-sepolia)
   - Testnet LINK on **both** chains — [faucets.chain.link](https://faucets.chain.link/)
     (LINK is what pays the CCIP message fee — fund the **bridge contract**, not just your
     wallet, after deployment; see step 3 below)

## Setup

```bash
git clone <this-repo>
cd ccip-nft-bridge
cp .env.example .env        # fill in PRIVATE_KEY and RPC URLs at minimum
forge install                # pulls OpenZeppelin, Chainlink CCIP contracts, forge-std
npm install
```

`forge install` needs these libs (already referenced by `remappings.txt`, install if `lib/` is
empty):

```bash
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install smartcontractkit/ccip --no-commit
forge install foundry-rs/forge-std --no-commit
```

## Build & test

```bash
forge build
forge test -vv
```

The test suite (`test/CrossChainNFT.t.sol`, `test/CCIPNFTBridge.t.sol`) covers:
- Access control on `mint` (only bridge) and `setBridge` (only owner)
- `burn` requires ownership/approval
- Idempotent minting (reverts on duplicate `tokenId`)
- `sendNFT` reverts for non-owners, unallowlisted destinations, and insufficient LINK
- `_ccipReceive` (via the public `ccipReceive` entry point, called as the router) rejects
  unallowlisted source chains and unrecognized senders
- Duplicate CCIP message replay is rejected (`MessageAlreadyProcessed`)
- Full round-trip: burn on source → simulated CCIP delivery → mint on destination →
  `tokenURI` matches exactly

It uses a lightweight `MockRouterClient` rather than the full CCIP protocol stack so these are
fast, deterministic unit tests. For true end-to-end integration testing against live CCIP
infra, use the [CCIP Local Simulator](https://docs.chain.link/chainlink-local) fork-testing
guides, or simply deploy to the real testnets as below and watch the
[CCIP Explorer](https://ccip.chain.link/).

## Deploy

```bash
forge script script/Deploy.s.sol:Deploy --broadcast -vvvv
```

This single script (using Foundry's multi-fork scripting) will, in order:

1. Deploy `CrossChainNFT` + `CCIPNFTBridge` on **Avalanche Fuji**.
2. Mint test **tokenId `1`** to the deployer wallet on Fuji, with tokenURI:
   `ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/1.json`
   (see the "Test NFT" section below).
3. Deploy `CrossChainNFT` + `CCIPNFTBridge` on **Arbitrum Sepolia**.
4. Wire both bridges together: `allowlistDestinationChain`, `allowlistSourceChain`, and
   `setRemoteBridge` on each side, so each bridge trusts (and only trusts) its sibling.
5. Write all four addresses to `deployment.json` in the exact schema required.

**After deployment**, fund each `CCIPNFTBridge` contract with testnet LINK (it pays the CCIP
fee on `sendNFT`, not your EOA):

```bash
cast send $LINK_TOKEN_FUJI "transfer(address,uint256)" <FUJI_BRIDGE_ADDRESS> 5000000000000000000 \
  --rpc-url $FUJI_RPC_URL --private-key $PRIVATE_KEY
```

### Test NFT

| Field       | Value                                                                                  |
|-------------|-----------------------------------------------------------------------------------------|
| Chain       | Avalanche Fuji                                                                          |
| Contract    | `deployment.json` → `avalancheFuji.nftContractAddress`                                  |
| `tokenId`   | **`1`**                                                                                  |
| Owner       | the deployer address derived from `PRIVATE_KEY`                                         |
| `tokenURI`  | `ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/1.json`              |

Verify after deploying:

```bash
cast call <FUJI_NFT_ADDRESS> "ownerOf(uint256)(address)" 1 --rpc-url $FUJI_RPC_URL
```

## Using the CLI

Locally:

```bash
npm run transfer -- --tokenId=1 --from=avalanche-fuji --to=arbitrum-sepolia --receiver=0xYourReceiverAddress
npm run status -- --transferId=<uuid-from-previous-output>   # optional: poll for delivery
```

Or containerized:

```bash
docker-compose up -d --build
docker exec -it ccip-nft-bridge-cli npm run transfer -- --tokenId=1 --from=avalanche-fuji --to=arbitrum-sepolia --receiver=0xYourReceiverAddress
```

Supported `--from` / `--to` values: `avalanche-fuji`, `arbitrum-sepolia`.

What happens when you run it:

1. Loads `deployment.json` + the ABI for the source chain's `CCIPNFTBridge`/`CrossChainNFT`.
2. Connects to the source chain via `ethers.JsonRpcProvider` using the RPC URL for `--from`.
3. Verifies your wallet (`PRIVATE_KEY`) actually owns `--tokenId`.
4. Reads the current `tokenURI` (used both for the transfer record's `metadata` and to confirm
   what will be preserved on the destination chain).
5. Calls `estimateTransferCost()` for a fee estimate, logs it.
6. Calls `sendNFT(destinationChainSelector, receiver, tokenId)` on the source bridge — this
   burns the NFT and dispatches the CCIP message.
7. Extracts the `NFTSent` event's `messageId` from the transaction receipt.
8. Writes a full audit record to `data/nft_transfers.json` (status transitions:
   `initiated` → `in-progress` → `completed`, or `failed` on any error) and appends structured
   log lines to `logs/transfers.log`.
9. Prints a link to the [CCIP Explorer](https://ccip.chain.link/) to track final delivery —
   the destination-chain mint happens asynchronously (typically 3–20 minutes depending on
   finality settings) once the Chainlink DON delivers and executes the message.

Run `npm run status -- --transferId=<id>` any time afterward to check whether the NFT has
actually landed on the destination chain (`ownerOf`/`exists` there) and flip the record's status
to `delivered`.

### `data/nft_transfers.json` schema

```json
{
  "transferId": "uuid",
  "tokenId": "1",
  "sourceChain": "avalanche-fuji",
  "destinationChain": "arbitrum-sepolia",
  "sender": "0x...",
  "receiver": "0x...",
  "ccipMessageId": "0x... | null",
  "sourceTxHash": "0x... | null",
  "destinationTxHash": "0x... | null",
  "status": "initiated | in-progress | completed | failed | delivered",
  "metadata": { "name": "...", "description": "...", "image": "..." },
  "timestamp": "ISO-8601"
}
```

(`destinationTxHash` is intentionally left `null` from the CLI — the destination-chain
transaction is executed by the CCIP DON, not by this wallet; you can look it up on the CCIP
Explorer using `ccipMessageId` and backfill it via `status.js` if you extend it to do so.)

## Security notes

- `CrossChainNFT.mint` is restricted to `bridge` (`onlyBridge`), and `setBridge` is
  `onlyOwner` — no arbitrary account can mint.
- `CCIPNFTBridge._ccipReceive` checks both `allowlistedSourceChains[sourceChainSelector]` and
  that `abi.decode(message.sender, (address))` matches the registered `remoteBridges[...]` for
  that selector — a message from an unrecognized contract or an unrecognized chain is rejected
  before any state changes.
- `ccipReceive` itself (inherited from `CCIPReceiver`) is only callable by the configured CCIP
  Router (`onlyRouter`), so nothing but the Router can ever invoke `_ccipReceive`.
- Ownership of all admin functions (`allowlistDestinationChain`, `allowlistSourceChain`,
  `setRemoteBridge`, `withdrawLink`, `setGasLimitForDestination`) is gated by OpenZeppelin's
  `Ownable`.
- All custom errors are used instead of require-strings where possible for cheaper reverts and
  precise, typed failure information (both in tests and in the CLI's error surfacing).

## Troubleshooting

| Symptom                                          | Likely cause / fix                                                                 |
|---------------------------------------------------|--------------------------------------------------------------------------------------|
| `InsufficientLinkBalance` on `sendNFT`            | Fund the **bridge contract** (not your wallet) with LINK on the source chain.        |
| Transaction sent but NFT never appears on dest.   | Check the message on [ccip.chain.link](https://ccip.chain.link/) using the messageId printed by the CLI/log — could be `pending`, or failed due to too-low `gasLimitForDestination`. |
| `SenderNotAllowlisted` / `SourceChainNotAllowed`   | Re-run the wiring steps in `Deploy.s.sol` (`allowlistSourceChain` + `setRemoteBridge` on the destination bridge). |
| `forge: command not found`                        | Install Foundry: `curl -L https://foundry.paradigm.xyz \| bash && foundryup`.        |
| CLI: `deployment.json not found`                   | Run `forge script script/Deploy.s.sol:Deploy --broadcast` first.                     |

## FAQ

See the assignment brief's FAQ for background on fee mechanics — in short: `sendNFT` estimates
the fee via `router.getFee`, then `approve`s and pays the CCIP Router in LINK, which funds the
gas execution of `_ccipReceive` on the destination chain.
