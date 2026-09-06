// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Minimal Uniswap v4 swap helper for Robinhood Chain.
// Talks to the standard v4 PoolManager directly (unlock -> swap -> settle -> take),
// bypassing RH's modified Universal Router. Exact-input, single-hop, hookless pools.
// Pattern proven by jumpboxtech/rhcswap (MIT).

type Currency is address;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24  fee;
    int24   tickSpacing;
    address hooks;
}
struct SwapParams {
    bool    zeroForOne;
    int256  amountSpecified; // negative = exact input
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData) external returns (int256);
    function sync(Currency currency) external;
    function settle() external payable returns (uint256);
    function take(Currency currency, address to, uint256 amount) external;
}

interface IERC20x {
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract V4Swap {
    IPoolManager public immutable pm;
    uint160 constant MIN_SQRT = 4295128739;
    uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;

    constructor(address _pm) { pm = IPoolManager(_pm); }

    struct CB { PoolKey key; bool zeroForOne; uint256 amountIn; uint256 minOut; address to; address payer; }

    /// swap exact `amountIn` of the input token for the output token; reverts if out < minOut
    function swap(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut, address to)
        external returns (uint256 out)
    {
        address tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        require(IERC20x(tokenIn).transferFrom(msg.sender, address(this), amountIn), "pull");
        bytes memory res = pm.unlock(abi.encode(CB(key, zeroForOne, amountIn, minOut, to, msg.sender)));
        out = abi.decode(res, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "!pm");
        CB memory c = abi.decode(data, (CB));

        address  tokenIn = c.zeroForOne ? Currency.unwrap(c.key.currency0) : Currency.unwrap(c.key.currency1);
        Currency curIn   = c.zeroForOne ? c.key.currency0 : c.key.currency1;
        Currency curOut  = c.zeroForOne ? c.key.currency1 : c.key.currency0;

        int256 delta = pm.swap(
            c.key,
            SwapParams({
                zeroForOne: c.zeroForOne,
                amountSpecified: -int256(c.amountIn),                       // exact input
                sqrtPriceLimitX96: c.zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1
            }),
            ""
        );

        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        int128 outLeg  = c.zeroForOne ? amount1 : amount0;                   // the token we receive
        int128 inLeg   = c.zeroForOne ? amount0 : amount1;                   // the token we owe
        require(outLeg > 0 && inLeg < 0, "bad delta");
        uint256 outAmt = uint256(int256(outLeg));
        uint256 owed   = uint256(int256(-inLeg));                            // actual consumed input
        require(outAmt >= c.minOut, "slippage");

        // pay exactly what we owe: sync -> transfer -> settle
        pm.sync(curIn);
        IERC20x(tokenIn).transfer(address(pm), owed);
        pm.settle();

        // refund any unconsumed input (partial fill at price limit)
        if (owed < c.amountIn) IERC20x(tokenIn).transfer(c.payer, c.amountIn - owed); // refund the PAYER

        // collect the output for the user
        pm.take(curOut, c.to, outAmt);

        return abi.encode(outAmt);
    }
}
