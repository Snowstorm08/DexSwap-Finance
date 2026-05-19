// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

/*
    Optimized DexSwap Router
    - Solidity 0.8.x
    - Custom errors
    - ReentrancyGuard
    - Gas optimizations
    - Unchecked increments
    - Cached variables
    - Modern ETH transfer handling
*/

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IDexSwapFactory.sol";
import "./interfaces/IDexSwapPair.sol";
import "./interfaces/IDexSwapRouter.sol";

import "./libraries/TransferHelper.sol";
import "./libraries/DexSwapLibrary.sol";

contract DexSwapRouter is IDexSwapRouter, ReentrancyGuard {

    address public immutable override factory;
    address public immutable override WETH;

    // =============================================================
    //                           ERRORS
    // =============================================================

    error Expired();
    error InvalidPath();
    error InsufficientAAmount();
    error InsufficientBAmount();
    error InsufficientOutputAmount();
    error ExcessiveInputAmount();
    error TransferFailed();

    // =============================================================
    //                          MODIFIER
    // =============================================================

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert Expired();
        _;
    }

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(address _factory, address _WETH) {
        factory = _factory;
        WETH = _WETH;
    }

    // =============================================================
    //                          RECEIVE
    // =============================================================

    receive() external payable {
        require(msg.sender == WETH, "ONLY_WETH");
    }

    // =============================================================
    //                    INTERNAL ETH WRAP
    // =============================================================

    function _wrapETH(
        uint256 amount,
        address pair
    ) internal {
        IWETH(WETH).deposit{value: amount}();

        bool success = IWETH(WETH).transfer(pair, amount);

        require(success, "WETH_TRANSFER_FAILED");
    }

    // =============================================================
    //                     INTERNAL SWAP
    // =============================================================

    function _swap(
        uint256[] memory amounts,
        address[] calldata path,
        address _to
    ) internal {

        uint256 length = path.length;
        address _factory = factory;

        for (uint256 i; i < length - 1;) {

            address input = path[i];
            address output = path[i + 1];

            (address token0,) =
                DexSwapLibrary.sortTokens(input, output);

            uint256 amountOut = amounts[i + 1];

            (uint256 amount0Out, uint256 amount1Out) =
                input == token0
                    ? (uint256(0), amountOut)
                    : (amountOut, uint256(0));

            address to =
                i < length - 2
                    ? DexSwapLibrary.pairFor(
                        _factory,
                        output,
                        path[i + 2]
                    )
                    : _to;

            address pair =
                DexSwapLibrary.pairFor(
                    _factory,
                    input,
                    output
                );

            IDexSwapPair(pair).swap(
                amount0Out,
                amount1Out,
                to,
                hex""
            );

            unchecked {
                ++i;
            }
        }
    }

    // =============================================================
    //                  ADD LIQUIDITY INTERNAL
    // =============================================================

    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    )
        internal
        returns (
            uint256 amountA,
            uint256 amountB
        )
    {

        address _factory = factory;

        if (
            IDexSwapFactory(_factory).getPair(
                tokenA,
                tokenB
            ) == address(0)
        ) {
            IDexSwapFactory(_factory).createPair(
                tokenA,
                tokenB
            );
        }

        (
            uint256 reserveA,
            uint256 reserveB
        ) = DexSwapLibrary.getReserves(
                _factory,
                tokenA,
                tokenB
            );

        if (reserveA == 0 && reserveB == 0) {

            (amountA, amountB) =
                (amountADesired, amountBDesired);

        } else {

            uint256 amountBOptimal =
                DexSwapLibrary.quote(
                    amountADesired,
                    reserveA,
                    reserveB
                );

            if (amountBOptimal <= amountBDesired) {

                if (amountBOptimal < amountBMin)
                    revert InsufficientBAmount();

                (amountA, amountB) =
                    (amountADesired, amountBOptimal);

            } else {

                uint256 amountAOptimal =
                    DexSwapLibrary.quote(
                        amountBDesired,
                        reserveB,
                        reserveA
                    );

                if (amountAOptimal < amountAMin)
                    revert InsufficientAAmount();

                (amountA, amountB) =
                    (amountAOptimal, amountBDesired);
            }
        }
    }

    // =============================================================
    //                      ADD LIQUIDITY
    // =============================================================

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        override
        ensure(deadline)
        nonReentrant
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {

        (amountA, amountB) =
            _addLiquidity(
                tokenA,
                tokenB,
                amountADesired,
                amountBDesired,
                amountAMin,
                amountBMin
            );

        address pair =
            DexSwapLibrary.pairFor(
                factory,
                tokenA,
                tokenB
            );

        TransferHelper.safeTransferFrom(
            tokenA,
            msg.sender,
            pair,
            amountA
        );

        TransferHelper.safeTransferFrom(
            tokenB,
            msg.sender,
            pair,
            amountB
        );

        liquidity =
            IDexSwapPair(pair).mint(to);
    }

    // =============================================================
    //                    ADD LIQUIDITY ETH
    // =============================================================

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        override
        ensure(deadline)
        nonReentrant
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        )
    {

        (amountToken, amountETH) =
            _addLiquidity(
                token,
                WETH,
                amountTokenDesired,
                msg.value,
                amountTokenMin,
                amountETHMin
            );

        address pair =
            DexSwapLibrary.pairFor(
                factory,
                token,
                WETH
            );

        TransferHelper.safeTransferFrom(
            token,
            msg.sender,
            pair,
            amountToken
        );

        _wrapETH(amountETH, pair);

        liquidity =
            IDexSwapPair(pair).mint(to);

        if (msg.value > amountETH) {

            TransferHelper.safeTransferETH(
                msg.sender,
                msg.value - amountETH
            );
        }
    }

    // =============================================================
    //                         SWAPS
    // =============================================================

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        override
        ensure(deadline)
        nonReentrant
        returns (uint256[] memory amounts)
    {

        if (path.length < 2)
            revert InvalidPath();

        amounts =
            DexSwapLibrary.getAmountsOut(
                factory,
                amountIn,
                path
            );

        if (
            amounts[amounts.length - 1]
                < amountOutMin
        ) {
            revert InsufficientOutputAmount();
        }

        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            DexSwapLibrary.pairFor(
                factory,
                path[0],
                path[1]
            ),
            amounts[0]
        );

        _swap(amounts, path, to);
    }

    // =============================================================
    //                  SWAP EXACT ETH FOR TOKENS
    // =============================================================

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        payable
        override
        ensure(deadline)
        nonReentrant
        returns (uint256[] memory amounts)
    {

        if (path[0] != WETH)
            revert InvalidPath();

        amounts =
            DexSwapLibrary.getAmountsOut(
                factory,
                msg.value,
                path
            );

        if (
            amounts[amounts.length - 1]
                < amountOutMin
        ) {
            revert InsufficientOutputAmount();
        }

        address pair =
            DexSwapLibrary.pairFor(
                factory,
                path[0],
                path[1]
            );

        _wrapETH(amounts[0], pair);

        _swap(amounts, path, to);
    }

    // =============================================================
    //                 SWAP EXACT TOKENS FOR ETH
    // =============================================================

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        override
        ensure(deadline)
        nonReentrant
        returns (uint256[] memory amounts)
    {

        if (
            path[path.length - 1] != WETH
        ) {
            revert InvalidPath();
        }

        amounts =
            DexSwapLibrary.getAmountsOut(
                factory,
                amountIn,
                path
            );

        if (
            amounts[amounts.length - 1]
                < amountOutMin
        ) {
            revert InsufficientOutputAmount();
        }

        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            DexSwapLibrary.pairFor(
                factory,
                path[0],
                path[1]
            ),
            amounts[0]
        );

        _swap(
            amounts,
            path,
            address(this)
        );

        uint256 amountOut =
            amounts[amounts.length - 1];

        IWETH(WETH).withdraw(amountOut);

        (bool success,) =
            to.call{value: amountOut}("");

        if (!success)
            revert TransferFailed();
    }

    // =============================================================
    //                   LIBRARY FUNCTIONS
    // =============================================================

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    )
        external
        pure
        override
        returns (uint256 amountB)
    {
        return DexSwapLibrary.quote(
            amountA,
            reserveA,
            reserveB
        );
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 swapFee
    )
        external
        pure
        override
        returns (uint256 amountOut)
    {
        return DexSwapLibrary.getAmountOut(
            amountIn,
            reserveIn,
            reserveOut,
            swapFee
        );
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 swapFee
    )
        external
        pure
        override
        returns (uint256 amountIn)
    {
        return DexSwapLibrary.getAmountIn(
            amountOut,
            reserveIn,
            reserveOut,
            swapFee
        );
    }

    function getAmountsOut(
        uint256 amountIn,
        address[] memory path
    )
        external
        view
        override
        returns (uint256[] memory amounts)
    {
        return DexSwapLibrary.getAmountsOut(
            factory,
            amountIn,
            path
        );
    }

    function getAmountsIn(
        uint256 amountOut,
        address[] memory path
    )
        external
        view
        override
        returns (uint256[] memory amounts)
    {
        return DexSwapLibrary.getAmountsIn(
            factory,
            amountOut,
            path
        );
    }
}
