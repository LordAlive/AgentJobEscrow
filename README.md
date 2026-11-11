# AgentJobEscrow

Escrow for an AI-agent marketplace. A client locks payment (ETH or an ERC-20) for a job, the agent delivers,
and the funds are released, refunded, or split by an arbiter.

- Contract: [`src/AgentJobEscrow.sol`](src/AgentJobEscrow.sol), interface in [`src/interfaces/`](src/interfaces/IAgentJobEscrow.sol)
- Design, risks, gaps, agent usage: [`NOTES.md`](NOTES.md)


## Setup

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recursive <repo-url> && cd AgentJobEscrow
```

Already cloned without `--recursive`? One setup command:

```bash
git submodule update --init --recursive
```

## Build and test

```bash
forge build
```

```bash
forge test
```

```bash
forge coverage --ir-minimum --no-match-coverage "(test|script)"
```

| Suite | What it covers |
|-------|----------------|
| `test/AgentJobEscrow.t.sol` | Every function and allowed path; wrong caller / state / time reverts; ETH and ERC-20; no-return-value token; fee-on-transfer rejection; failed ETH and blocklisted-token payouts followed by withdraw; gas-burning receiver; reentrancy |
| `test/AgentJobEscrow.fuzz.t.sol` | Split math for any `uint256` amount and bps (value conserved, fee <= 10%); end-to-end approve and resolve payouts; deadline and review-window boundaries |
| `test/invariant/` | Escrow balance per token == open job amounts + uncollected credits; fee never above 10% |

Contract coverage: 99.3% lines, 100% branches, 100% functions.

## Run on anvil

Terminal 1:

```bash
anvil
```

Terminal 2, deploy. Anvil's dev accounts are unlocked, so no private key is needed:

```bash
forge script script/Deploy.s.sol --rpc-url anvil --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

The first deployment on a fresh anvil lands at `0x5FbDB2315678afecb367f032d93F642f64180aa3`. Run one full
job (create → deliver → approve, printing balances):

```bash
ESCROW_ADDRESS=0x5FbDB2315678afecb367f032d93F642f64180aa3 forge script script/FullJob.s.sol --rpc-url anvil --broadcast --unlocked --sender 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
```

Client and provider default to anvil accounts #1 and #2; override with `CLIENT`, `PROVIDER`, `JOB_AMOUNT`.

## Arbitrum Sepolia (optional)

Use a throwaway wallet stored in an encrypted keystore (never a raw key in `.env`):

```bash
cast wallet import throwaway --interactive
```

```bash
source .env && forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia --account throwaway --broadcast --verify
```

Deployed address: _not deployed yet_.

## Configuration

| Setting | Default | Who | Bounds |
|---------|---------|-----|--------|
| `feeBps` | constructor arg (script: 250) | owner | ≤ 1,000 (10%), enforced in code |
| `feeRecipient` | constructor arg | owner | non-zero |
| `reviewPeriod` | 3 days | owner | 1 hour … 30 days |

Fee and review period are snapshotted per job at creation, so owner changes never affect existing jobs.
Ownership uses `Ownable2Step`.

## Time spent and AI tools

- Time spent: 3.5 hrs approx
- AI tools: used Claude opus5.5, used to draft tests, scripts and docs. I've done 70% manual and 30% AI.
