// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV3QuoterV2, ISlipstreamQuoterV2} from "src/interfaces/IVenueQuoters.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MockDepthPool {
    uint128 public liquidity;

    function setLiquidity(uint128 value) external {
        liquidity = value;
    }
}

/// @dev Capacity and exchange rate are explicitly configured, independent of ERC20 balances.
///      Writes on quote ensure a STATICCALL-based implementation cannot pass these tests.
contract MockDepthQuoter {
    address public immutable factory;
    uint256 public calls;
    bool public fail;
    mapping(address => uint256) public capacity;
    mapping(address => uint256) public numerator;
    mapping(address => uint256) public denominator;
    uint24 public lastFee;
    int24 public lastTickSpacing;
    address public lastTokenIn;

    constructor(address factory_) {
        factory = factory_;
    }

    function setFail(bool value) external {
        fail = value;
    }

    function setQuote(address token, uint256 cap, uint256 num, uint256 denom) external {
        capacity[token] = cap;
        numerator[token] = num;
        denominator[token] = denom;
    }

    function quoteExactInputSingle(IUniswapV3QuoterV2.QuoteExactInputSingleParams memory p)
        external
        returns (uint256, uint160, uint32, uint256)
    {
        lastFee = p.fee;
        lastTokenIn = p.tokenIn;
        return _quote(p.tokenOut, p.amountIn);
    }

    function quoteExactInputSingle(ISlipstreamQuoterV2.QuoteExactInputSingleParams memory p)
        external
        returns (uint256, uint160, uint32, uint256)
    {
        lastTickSpacing = p.tickSpacing;
        lastTokenIn = p.tokenIn;
        return _quote(p.tokenOut, p.amountIn);
    }

    function _quote(address token, uint256 amount) internal returns (uint256, uint160, uint32, uint256) {
        require(!fail, "quote failed");
        ++calls;
        if (amount > capacity[token] || denominator[token] == 0) return (0, 0, 0, 0);
        return (Math.mulDiv(amount, numerator[token], denominator[token]), uint160(1 << 96), 0, 50_000);
    }
}
