# Notes

## Design

- Single contract, jobs keyed by an incrementing id starting at 1. `State.None` doubles as "job does not exist". The `Job` struct packs into 6 slots. Types, events and errors live in `IAgentJobEscrow`.
- `address(0)` means native ETH. ETH jobs require `msg.value == amount`; ERC-20 jobs reject any `msg.value`.
- `feeBps` and `reviewPeriod` are copied into the job when it is funded, so admin changes never alter a live deal.
- Time windows are inclusive on one side and never overlap: delivery `<= deadline`, refund `> deadline`; dispute `<= reviewEndsAt`, claim `> reviewEndsAt`. `approve` stays open for as long as the job is Delivered.
- `computeSplit` uses `mulDiv` and rounds both divisions down, then assigns remainders by subtraction. Provider + client + fee always equals the amount, and rounding dust never goes to the platform. The fee is only taken from the provider's share.
- Payouts are pushed, and a failed push is credited to `pendingWithdrawals[account][token]` (`PayoutDeferred`). The credit is pulled with `withdraw(token)` or redirected with `withdrawTo(token, to)`. A settlement never reverts because of one recipient.
- Delivery is stored as a `bytes32` (hash or CID digest of the artifact). The URI itself is expected off-chain.
- Rejected at creation: provider equal to client, arbiter equal to client or provider, and the escrow's own address as provider, arbiter, fee recipient or `withdrawTo` target (funds sent there would be unrecoverable).
- `Ownable2Step`; fee capped at 1,000 bps in the constructor, the setter and `computeSplit`.

## Risks considered

| Risk | Mitigation |
|------|-----------|
| Paying twice via reentrancy | Every mutating entry point is `nonReentrant`, and state moves to a terminal value before any transfer. Credits are zeroed before sending. Covered by a re-entering provider test. |
| Receiver reverts on ETH | Amount is credited; the owner of the credit can withdraw later or to another address. |
| Receiver burns gas / return bomb | ETH pushes forward 50k gas and copy no return data. Anything needing more is credited and pulls with full gas. |
| Token blocklists a recipient (USDC/USDT) | `trySafeTransfer` credits instead of reverting; the blocked account uses `withdrawTo`. |
| Token returns no bool | Supported through `SafeERC20`, tested with a USDT-style mock. |
| Fee-on-transfer token | Rejected on purpose: the received balance delta must equal `amount`. |
| Rebasing / later-upgraded token behaviour | Not supported. A negative rebase would leave the last withdrawers short. |
| Address without code used as token | Reverts at deposit. |
| Owner overreach | Fee cap in code, per-job snapshots; the owner cannot move escrowed funds or change job state. |
| Caller starves a payout of gas | Worst case the recipient is credited rather than paid; no value is lost. |
| Timestamp skew (Arbitrum sequencer) | Windows are hours to days, so seconds of skew are irrelevant. |
| Forced ETH via `selfdestruct` | No `receive`; forced ETH only creates surplus and never affects accounting. |

## Out of scope / next steps

- Arbiter liveness. A disputed job waits on its arbiter indefinitely. Next step would be a dispute timeout with a fallback (default split or a platform arbiter), which is a product decision, so I left it out rather than guess.
- With no arbiter, the client has no recourse after delivery beyond approving or letting the window lapse. That is the spec, and the client opts into it by choosing `arbiter = 0`.
- Surplus sweep for the owner (`balance - owed`), token allowlist, pausing new jobs, permit / meta-transactions, milestones, deadline extensions, arbiter fees.
- Arbitrum Sepolia deployment and verification (script and config are in place).

## Using it from an agent

1. Index `JobCreated` with `provider == self`. Before starting work, read `getJob(id)` and check the token, amount, deadline and arbiter (an arbiter the client controls could zero the payout). Net pay is `computeSplit(amount, 10_000, job.feeBps)`.
2. Upload the deliverable and call `submitDelivery(id, hash)` before `deadline`.
3. Watch for `JobReleased` or `JobDisputed`. If neither arrives, call `claimAfterReview(id)` after `reviewEndsAt`.
4. On `PayoutDeferred` for its own address, call `withdraw(token)` or `withdrawTo`.
5. As a client: `createJob`, verify the hash against the fetched artifact, then `approve` or `dispute` within the window; `refund` after a missed deadline.

Every revert is a typed custom error carrying the relevant values (`ReviewWindowOpen(jobId, reviewEndsAt)` and so on), so an agent can decide whether and when to retry without a human reading logs.
