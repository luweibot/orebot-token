# AGENTS.md - OREBOT project context

Read this before touching anything. It is the build plan and the state of the world as of
**2026-11-01**. Facts marked VERIFIED were read from BNB Chain, not inferred. Never trust a number
here over a fresh `eth_call`.

---

## 1. What this project is

Two products that share one identity gate:

| Layer | Artifact | State |
|---|---|---|
| Token | **OREBOT** - Flap Tax Token V3 on BNB Chain, Agent ID gated | not launched |
| NFT | **OrebotPFP** - 1,000 pixel-bot PFPs, mined then burned for OREBOT | source ready, not deployed |
| Site | token landing page + mining rig | live on GitHub Pages |

Owner: Luwei (crypto trader, timezone Asia/Rangoon). Public handle `@orebot_network`.
Related but separate project: Sentinel Mesh (x402 USDC paid data API on Base) and the crypto copy
trading system. Do not mix their secrets, chains, or repos.

## 2. Live URLs and repo

- Landing page: https://luweibot.github.io/orebot-token/
- Mining rig: https://luweibot.github.io/orebot-token/mine.html  (append `?qa=1` for a 9s test window)
- Repo: https://github.com/luweibot/orebot-token (public, GitHub Pages from `main`, root = site)

```
orebot-token/
├── index.html            token landing dashboard, "Go Mining" icon box links to mine.html
├── mine.html             mining rig + mint UI (all logic inline, no build step)
├── AGENTS.md             this file
└── contracts/OrebotPFP.sol   ERC-721 source (compiles, not deployed)
```

Hosting note: Base44 `upload_file` is unavailable (integration credits exhausted), so the site is
served by GitHub Pages. Vercel is an option later if a serverless backend is needed; the Vercel
account currently has 4 projects and **none of them is this project**.

## 3. Public addresses

| Name | Address |
|---|---|
| NFT mint fee receiver (set at deploy, immutable) | `0xdAc8133DDf95dE0d0a35F711f5348b1d709ed35f` |
| Project EVM wallet (launch wallet, contract deployer) | `0x0Bee61D45d42D7342D57Ea7581D17581203447A8` |
| BSC bounty claim wallet (user-held, no sandbox key) | `0xAB39Aa1e2db4036e01CF7e919b3f239b3ff90160` |
| Predicted OREBOT token address (from mined salt) | `0xDf5b8b780fc9B9141BC0A814d81e9f9e3c4D7777` |
| Binance Agent ID collection (SPACE ID Agent ID, symbol `AI`) | `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` |
| Flap Portal | `0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0` |
| Flap Tax Token V3 implementation | `0x024f18294970B5c76c0691b87f138A0317156422` |
| Flap VaultPortal (not used here) | `0x90497450f2a706f1951b5bdda52B4E5d16f34C06` |

Never put a private key or API token in this repo. Keys live in agent secrets only.

## 4. Machine-readable config

```json
{
  "chainId": 56,
  "rpc": "https://bsc-dataseed.binance.org",
  "token": {
    "name": "Orebot",
    "symbol": "OREBOT",
    "standard": "flap-tax-v3",
    "quoteToken": "0x0000000000000000000000000000000000000000",
    "buyTaxBps": 100,
    "sellTaxBps": 100,
    "taxDurationDays": 36500,
    "antiFarmerDays": 3,
    "mktBps": 10000, "deflationBps": 0, "dividendBps": 0, "lpBps": 0,
    "minimumShareBalance": 0,
    "beneficiary": "0x0Bee61D45d42D7342D57Ea7581D17581203447A8",
    "agentGateCollection": "0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F",
    "minAgentNftBalance": 1,
    "devBuyTokens": 20000000,
    "devBuyQuoteAmtBnb": 0.117,
    "salt": "0x337a352a4825210154c16369cd7fe5bf314667cba8cb004e6b6c2f2ecbea8dd6"
  },
  "nft": {
    "collection": "OrebotPFP",
    "maxSupply": 1000,
    "mintPriceWei": "1000000000000000",
    "tiers": { "common": {"bps": 6000, "reward": 10000}, "rare": {"bps": 2500, "reward": 30000},
               "epic": {"bps": 1200, "reward": 100000}, "ultimate": {"bps": 300, "reward": 500000} },
    "agentGated": false
  },
  "site": { "contractAddress": "" }
}
```

## 5. Token launch: exact parameters and math

Skill: `.agents/skills/launch-bnb-token-on-flap/` (SKILL.md + 8 references). Read the reference for
the step you are on, not all at once.

- Call `newTokenV6` on Portal; no vault. Token lands as a minimal proxy clone; the salt must produce
  an address ending `7777`.
- **Salt already mined** (VERIFIED empty at that address): see config above. CREATE2 uses the
  Portal as deployer even for vault launches. Because name/symbol are not part of the clone salt,
  the same salt always yields `0xDf5b…7777`.
- **Curve model** (VERIFIED against a live token): constant product with virtual quote reserve
  `r = 6.14 BNB`, virtual token reserve `h + 1e9 - circulating`, `K = r * (h + 1e9)` with
  `h = 107,036,752` and supply `1e9`. Price in wei reproduced exactly for a real token, so this
  model is trustworthy for sizing the dev buy.
- **Dev buy**: 2% of supply = `20,000,000` tokens, which equals the per-origin cap (`maxBuyPerOrigin`
  = 200 bps). A buy above the remaining allowance fills to the cap and refunds the excess in the
  same transaction, so send `0.117 BNB` and let the contract refund the remainder rather than
  computing to the wei.
- Net tokens are reduced by the 1% Portal fee and the 1% buy tax, so the exact input for exactly
  20,000,000 net is ~`0.1153 BNB`. Use 0.117 and rely on the refund.
- Gas is negligible: BSC gas price is 0.05 gwei (VERIFIED 2026-11-01).

## 6. NFT rig: contract, gas, and redemption economics

`contracts/OrebotPFP.sol` - ERC-721 + Ownable + ReentrancyGuard (OZ 5.0.2), solc 0.8.24, optimizer 200.

- 1,000 supply, `MINT_PRICE = 0.001 ether`, `feeReceiver` **immutable**, set to
  `0xdAc8133DDf95dE0d0a35F711f5348b1d709ed35f` in the constructor, so mint payments land there inside
  the same transaction that mints. No withdrawal function, no pause. Changing it after deploy means
  redeploying.
- Tier rolled onchain in `mint()`: ultimate 3%, epic 12%, rare 25%, common 60%.
- `redeem(tokenId)` burns the NFT and emits `Redeemed(tokenId, holder, tier, reward)` - one-time by
  construction. Payouts are not onchain yet: they need OREBOT plus a distributor that reads those
  events.
- `msg.sender == tx.origin` in `mint()` blocks atomic re-roll contracts. Residual risk: a minter
  with many fresh EOAs can re-roll a bad tier for gas cost. Disclose it; VRF is the proper fix.
- Metadata is offchain via `setBaseMetadataURI` (media belongs offchain, per ethskills `ship`).
- Compiled size: creation 8,636 bytes, runtime 7,750 bytes (limit 24,576).
- **Deploy gas VERIFIED by `eth_estimateGas`: 1,849,481 gas = 0.0000925 BNB (~$0.065 @ $703).**
  Breakdown: 21,000 base + 137,184 calldata (8,700 bytes) + 141,297 constructor + 1,550,000 code
  deposit (7,750 × 200).
- Redemption economics: expected 40,500 OREBOT per bot, so **40.5M total across all 1,000 = 4.05% of
  the 1B supply**; ~30 ultimates expected, not 300. Reserve **50M OREBOT** in the distributor.
  Absolute worst case (all ultimate) is 500M - cap ultimate mints if that risk is unacceptable.

## 7. Front-end facts an agent will need

`mine.html` calls the chain directly through `window.ethereum`, no library, no build step. Function
selectors are hardcoded and were computed, not remembered:

| Function | Selector |
|---|---|
| `mint()` | `0x1249c58b` |
| `redeem(uint256)` | `0xdb006a75` |
| `totalSupply()` | `0x18160ddd` |
| `tierOf(uint256)` | `0x53f96df2` |
| `ownerOf(uint256)` | `0x6352211e` |
| `rewardFor(uint8)` | `0x78aafe42` |
| `getTokenV8Safe(address)` (Portal) | `0x62fafcca` |

`0.001 BNB` as hex value is `0x38d7ea4c68000`. Set `CONFIG.contract` to turn minting on; until then
the rig runs in preview mode. Mining window is 5–10 min, random per session, persisted under
`localStorage` key `orebot.mine.v1.<wallet>`, so a refresh resumes instead of re-rolling.
The rig animation is presentation - say so in any user-facing copy.

## 8. The merge design (agreed direction, not yet implemented)

One identity at every gate: **Agent ID is the door, the rig is the on-ramp, the token is settlement.**

1. Add `IERC721(agentIdCollection).balanceOf(msg.sender) >= 1` to `mint()` (~2,600 gas).
2. Seed the rig from the Agent ID tokenId so each `.ai` has a persistent miner identity.
3. Fund a distributor with ~50M OREBOT before redemption opens.

Hard constraint: Flap's `nft_gated` checks a collection **Flap** has whitelisted. Only
`0x60B9…022F` is whitelisted for this launch; our own PFP collection cannot gate the token.

## 9. Order of operations

1. Get `haku85.ai` into the launch wallet (`0x0Bee…47A8`) - it currently sits in the Binance
   Agentic Wallet and `balanceOf` for both our wallets is **0** (VERIFIED 2026-11-01).
2. Fund `0x0Bee…47A8` with ~0.15 BNB (0.117 dev buy + gas + margin).
3. Upload artwork/description, then launch via `newTokenV6` with the salt above.
4. Deploy `OrebotPFP` (0.0000925 BNB), paste the address into `CONFIG.contract`.
5. Fund the reward distributor, then enable `redeem()` in the UI.

## 10. Conventions

- Verify every address and number onchain before use; never hallucinate an address.
- Read `https://ethskills.com/SKILL.md` before writing or shipping Solidity, then the topic skills.
- One contract, immutable fee path, no admin withdrawals. Owner functions only for metadata URI and
  the future reward token.
- Recompute selectors and gas with viem rather than trusting this file.
- Test client-side changes against real pages in a browser, and unit-test the renderer: a scoping bug
  once broke 260 of the 1,000 bots while the page still looked fine.
- Never print secrets in chat; they are stored encrypted and revealed only in Settings → Security.
