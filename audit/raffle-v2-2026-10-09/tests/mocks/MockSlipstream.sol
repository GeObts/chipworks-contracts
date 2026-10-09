// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISlipstreamSwapRouter} from "../../src/interfaces/ISwapRouters.sol";

/// @notice Slipstream pool double: settable spot (sqrtPrice + tick) and a TWAP tick the oracle
///         reports exactly over any window. `observe` reverts "OLD" past `maxAge` or when told to.
contract MockSlipstreamPool {
    address public token0;
    address public token1;
    int24 public tickSpacing;

    uint160 public sqrtPriceX96;
    int24 public spotTick;
    int24 public twapTick;
    /// @dev Added to the newest cumulative only, to exercise the mean's rounding.
    int56 public cumulativeExtra;
    uint32 public maxAge = type(uint32).max;
    bool public observeReverts;

    constructor(address t0, address t1, int24 spacing) {
        token0 = t0;
        token1 = t1;
        tickSpacing = spacing;
    }

    function setSpot(uint160 sqrtP, int24 tick) external {
        sqrtPriceX96 = sqrtP;
        spotTick = tick;
    }

    function setTwapTick(int24 t) external {
        twapTick = t;
    }

    function setCumulativeExtra(int56 e) external {
        cumulativeExtra = e;
    }

    function setMaxAge(uint32 a) external {
        maxAge = a;
    }

    function setObserveReverts(bool v) external {
        observeReverts = v;
    }

    function setTickSpacing(int24 s) external {
        tickSpacing = s;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (sqrtPriceX96, spotTick, 0, 2048, 2048, true);
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory cum, uint160[] memory spl) {
        require(!observeReverts, "OLD");
        cum = new int56[](secondsAgos.length);
        spl = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            require(secondsAgos[i] <= maxAge, "OLD");
            cum[i] = int56(twapTick) * int56(uint56(10_000_000 - secondsAgos[i]));
            if (secondsAgos[i] == 0) cum[i] += cumulativeExtra;
        }
    }
}

/// @notice Slipstream factory double: getPool is symmetric in the token pair.
contract MockSlipstreamFactory {
    mapping(address => mapping(address => mapping(int24 => address))) internal _pools;

    function setPool(address a, address b, int24 spacing, address pool) external {
        _pools[a][b][spacing] = pool;
        _pools[b][a][spacing] = pool;
    }

    function getPool(address a, address b, int24 spacing) external view returns (address) {
        return _pools[a][b][spacing];
    }
}

/// @notice Slipstream router double. Pulls `amountIn` into the pool and pays a fill the TEST
///         sets (`fillOut`) from the router's own stock balance, enforcing `amountOutMinimum`
///         like the real router. Modes model a reverting router and two lying ones.
contract MockSlipstreamRouter {
    enum Mode {
        Normal,
        Revert, // reverts with a reason
        IgnoreMin, // pays `fillOut` even below amountOutMinimum (a lying router)
        PartialSpend // pulls only half the input
    }

    address public factory;
    Mode public mode;
    uint256 public fillOut;
    uint256 public lastMinOut;
    uint256 public lastAmountIn;
    uint256 public swaps;

    constructor(address factory_) {
        factory = factory_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setFillOut(uint256 out) external {
        fillOut = out;
    }

    function exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        require(p.deadline >= block.timestamp, "Transaction too old");
        if (mode == Mode.Revert) revert("router down");
        lastMinOut = p.amountOutMinimum;
        lastAmountIn = p.amountIn;
        uint256 pull = mode == Mode.PartialSpend ? p.amountIn / 2 : p.amountIn;
        address pool = MockSlipstreamFactory(factory).getPool(p.tokenIn, p.tokenOut, p.tickSpacing);
        require(pool != address(0), "no pool");
        IERC20(p.tokenIn).transferFrom(msg.sender, pool, pull);
        amountOut = fillOut;
        if (mode != Mode.IgnoreMin) require(amountOut >= p.amountOutMinimum, "Too little received");
        IERC20(p.tokenOut).transfer(p.recipient, amountOut);
        swaps++;
    }
}
