// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OrebotPFP
 * @notice 1000 pixel-art PFP bots on BNB Smart Chain. 0.001 BNB per mint, paid
 *         straight to the project wallet in the same transaction that mints the
 *         token. Tier is rolled onchain at mint time. Burning a bot records a
 *         one-time OREBOT reward claim for a later distributor.
 *
 * Design notes (deliberate):
 *  - The fee receiver is immutable. There is no withdraw function and no path by
 *    which this contract or its owner can hold or redirect minter funds.
 *  - Payment and mint are atomic, so a minter never pays without receiving a bot.
 *  - Art and metadata live offchain (baseMetadataURI); only ownership, tier and
 *    redeem history are onchain, because that is the part that must be trustless.
 *  - Tier uses block.prevrandao mixed with caller and token id. Validators can
 *    influence prevrandao, and a minter can re-roll by spending gas on a fresh
 *    attempt. For a cosmetic tier with a future offchain payout this is an
 *    accepted, documented limitation - not a substitute for a VRF.
 */
contract OrebotPFP is ERC721, Ownable, ReentrancyGuard {
    // ---------------------------------------------------------------- supply
    uint256 public constant MAX_SUPPLY = 1000;
    uint256 public constant MINT_PRICE = 0.001 ether;

    /// @notice Receives every mint payment. Immutable by design.
    address payable public immutable feeReceiver;

    uint256 public totalSupply;
    uint256 public totalRedeemed;

    // ----------------------------------------------------------------- tiers
    uint8 public constant TIER_COMMON = 1;
    uint8 public constant TIER_RARE = 2;
    uint8 public constant TIER_EPIC = 3;
    uint8 public constant TIER_ULTIMATE = 4;

    /// @dev Cumulative upper bounds out of 10_000.
    uint16 private constant ROLL_ULTIMATE = 300; //   3%
    uint16 private constant ROLL_EPIC = 1500; //  12%  (cumulative)
    uint16 private constant ROLL_RARE = 4000; //  25%  (cumulative)
    // remainder (6000) is common -> 60%

    mapping(uint256 tokenId => uint8) public tierOf;
    mapping(uint8 tier => uint256) public mintedOfTier;
    mapping(uint8 tier => uint256) public redeemedOfTier;
    /// @notice How many bots an address has burned (reward claims it owns).
    mapping(address holder => uint256) public redeemedBy;

    // ------------------------------------------------------------- metadata
    /// @notice Offchain metadata base, e.g. "https://host/nft/" -> "<base><id>.json".
    string public baseMetadataURI;
    /// @notice OREBOT token address, wired when the token is live.
    address public rewardToken;

    uint256 private _rollNonce;

    // --------------------------------------------------------------- events
    event Minted(uint256 indexed tokenId, address indexed to, uint8 tier, uint256 pricePaid);
    event Redeemed(uint256 indexed tokenId, address indexed holder, uint8 tier, uint256 tokenReward);
    event BaseMetadataURISet(string uri);
    event RewardTokenSet(address indexed token);

    constructor(address payable feeReceiver_, address owner_)
        ERC721("Orebot PFP", "OREBOTPFP")
        Ownable(owner_)
    {
        require(feeReceiver_ != address(0), "fee receiver required");
        feeReceiver = feeReceiver_;
    }

    // ---------------------------------------------------------------- mint
    /**
     * @notice Mint one bot. Sends MINT_PRICE to feeReceiver in the same call.
     * @dev EOA-only so a contract cannot atomically inspect and revert on a bad
     *      tier roll, which would hand snipers a free re-roll loop.
     */
    function mint() external payable nonReentrant returns (uint256 tokenId) {
        require(msg.sender == tx.origin, "EOA only");
        require(msg.value == MINT_PRICE, "exactly 0.001 BNB");
        require(totalSupply < MAX_SUPPLY, "sold out");

        tokenId = totalSupply + 1;
        totalSupply = tokenId;

        uint8 tier = _rollTier(tokenId);
        tierOf[tokenId] = tier;
        mintedOfTier[tier] += 1;

        _safeMint(msg.sender, tokenId);

        (bool paid, ) = feeReceiver.call{value: msg.value}("");
        require(paid, "fee transfer failed");

        emit Minted(tokenId, msg.sender, tier, msg.value);
    }

    function _rollTier(uint256 tokenId) private returns (uint8) {
        uint256 seed = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao, block.timestamp, block.number, msg.sender, tokenId, _rollNonce++
                )
            )
        );
        uint256 roll = seed % 10_000;
        if (roll < ROLL_ULTIMATE) return TIER_ULTIMATE;
        if (roll < ROLL_EPIC) return TIER_EPIC;
        if (roll < ROLL_RARE) return TIER_RARE;
        return TIER_COMMON;
    }

    // -------------------------------------------------------------- redeem
    /**
     * @notice Burn a bot to claim its one-time OREBOT reward.
     * @dev The burn is the receipt: a burned id can never be redeemed again.
     *      Payout happens later from a distributor that reads the Redeemed event
     *      and/or redeemedBy accounting, once the token and distributor exist.
     */
    function redeem(uint256 tokenId) external nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "not your bot");
        uint8 tier = tierOf[tokenId];
        uint256 reward = rewardFor(tier);

        delete tierOf[tokenId];
        totalRedeemed += 1;
        redeemedOfTier[tier] += 1;
        redeemedBy[msg.sender] += 1;

        _burn(tokenId);

        emit Redeemed(tokenId, msg.sender, tier, reward);
    }

    // ---------------------------------------------------------------- views
    /// @notice OREBOT reward for a tier, in 18-decimal units.
    function rewardFor(uint8 tier) public pure returns (uint256) {
        if (tier == TIER_ULTIMATE) return 500_000e18;
        if (tier == TIER_EPIC) return 100_000e18;
        if (tier == TIER_RARE) return 30_000e18;
        if (tier == TIER_COMMON) return 10_000e18;
        return 0;
    }

    function tierName(uint8 tier) public pure returns (string memory) {
        if (tier == TIER_ULTIMATE) return "Ultimate";
        if (tier == TIER_EPIC) return "Epic";
        if (tier == TIER_RARE) return "Rare";
        if (tier == TIER_COMMON) return "Common";
        return "None";
    }

    function remaining() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (bytes(baseMetadataURI).length == 0) return "";
        return string.concat(baseMetadataURI, _toString(tokenId), ".json");
    }

    // ---------------------------------------------------------------- admin
    /// @dev No funds can be moved by the owner; these only point at metadata/art.
    function setBaseMetadataURI(string calldata uri) external onlyOwner {
        baseMetadataURI = uri;
        emit BaseMetadataURISet(uri);
    }

    function setRewardToken(address token) external onlyOwner {
        rewardToken = token;
        emit RewardTokenSet(token);
    }

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
