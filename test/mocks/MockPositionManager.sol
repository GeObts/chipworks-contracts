// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {INonfungiblePositionManager, ISlipstreamGauge} from "../../src/interfaces/INonfungiblePositionManager.sol";

/// @notice Slipstream position manager test double. Pulls the deposited tokens, mints an
///         NFT, and pays out configurable owed fees on collect.
contract MockPositionManager is ERC721, INonfungiblePositionManager {
    using SafeERC20 for IERC20;

    uint256 public nextId = 1;

    struct Pos {
        address token0;
        address token1;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
    }

    mapping(uint256 => Pos) public pos;
    mapping(uint256 => bool) public collectReverts;

    constructor() ERC721("Slipstream Position NFT v1", "AERO-CL-POS") {}

    function setOwedFees(uint256 tokenId, uint128 a0, uint128 a1) external {
        pos[tokenId].owed0 = a0;
        pos[tokenId].owed1 = a1;
    }

    function setCollectReverts(uint256 tokenId, bool v) external {
        collectReverts[tokenId] = v;
    }

    function mint(MintParams calldata p)
        external
        payable
        override
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        IERC20(p.token0).safeTransferFrom(msg.sender, address(this), p.amount0Desired);
        IERC20(p.token1).safeTransferFrom(msg.sender, address(this), p.amount1Desired);

        tokenId = nextId++;
        liquidity = uint128(p.amount0Desired + p.amount1Desired);
        pos[tokenId] = Pos(p.token0, p.token1, liquidity, 0, 0);
        _safeMint(p.recipient, tokenId);
        return (tokenId, liquidity, p.amount0Desired, p.amount1Desired);
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata p)
        external
        payable
        override
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        Pos storage s = pos[p.tokenId];
        IERC20(s.token0).safeTransferFrom(msg.sender, address(this), p.amount0Desired);
        IERC20(s.token1).safeTransferFrom(msg.sender, address(this), p.amount1Desired);
        liquidity = uint128(p.amount0Desired + p.amount1Desired);
        s.liquidity += liquidity;
        return (liquidity, p.amount0Desired, p.amount1Desired);
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata p)
        external
        payable
        override
        returns (uint256 amount0, uint256 amount1)
    {
        Pos storage s = pos[p.tokenId];
        require(s.liquidity >= p.liquidity, "too much");
        s.liquidity -= p.liquidity;
        // Withdrawn tokens become collectable, as in the real contract.
        s.owed0 += uint128(p.liquidity / 2);
        s.owed1 += uint128(p.liquidity / 2);
        return (p.liquidity / 2, p.liquidity / 2);
    }

    function collect(CollectParams calldata p) external payable override returns (uint256 amount0, uint256 amount1) {
        require(!collectReverts[p.tokenId], "collect failed");
        Pos storage s = pos[p.tokenId];
        amount0 = s.owed0;
        amount1 = s.owed1;
        s.owed0 = 0;
        s.owed1 = 0;
        if (amount0 != 0) IERC20(s.token0).safeTransfer(p.recipient, amount0);
        if (amount1 != 0) IERC20(s.token1).safeTransfer(p.recipient, amount1);
    }

    function positions(uint256 tokenId)
        external
        view
        override
        returns (uint96, address, address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Pos storage s = pos[tokenId];
        return (0, address(0), s.token0, s.token1, 100, -887200, 887200, s.liquidity, 0, 0, s.owed0, s.owed1);
    }

    function factory() external pure override returns (address) {
        return address(0);
    }

    function ownerOf(uint256 tokenId) public view override(ERC721, INonfungiblePositionManager) returns (address) {
        return ERC721.ownerOf(tokenId);
    }
}

/// @notice Aerodrome gauge test double: takes custody of the position, pays a reward token.
contract MockGauge is ISlipstreamGauge {
    using SafeERC20 for IERC20;

    address public immutable npm;
    address public immutable override rewardToken;
    mapping(uint256 => address) public depositor;
    mapping(uint256 => uint256) public pending;

    constructor(address npm_, address rewardToken_) {
        npm = npm_;
        rewardToken = rewardToken_;
    }

    function setPendingReward(uint256 tokenId, uint256 amount) external {
        pending[tokenId] = amount;
    }

    function deposit(uint256 tokenId) external override {
        depositor[tokenId] = msg.sender;
        MockPositionManager(npm).transferFrom(msg.sender, address(this), tokenId);
    }

    function withdraw(uint256 tokenId) external override {
        require(depositor[tokenId] == msg.sender, "not depositor");
        MockPositionManager(npm).transferFrom(address(this), msg.sender, tokenId);
    }

    function getReward(uint256 tokenId) external override {
        uint256 amount = pending[tokenId];
        pending[tokenId] = 0;
        if (amount != 0) IERC20(rewardToken).safeTransfer(depositor[tokenId], amount);
    }
}
