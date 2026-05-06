// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.5.16;

import './interfaces/IDexSwapFactory.sol';
import './interfaces/IDexSwapPair.sol';
import './DexSwapPair.sol';

contract DexSwapFactory is IDexSwapFactory {
    address public feeTo;
    address public feeToSetter;

    // Protocol fee denominator used by DexSwapPair.
    // Example behavior depends on the pair implementation.
    uint8 public protocolFeeDenominator = 9;

    bytes32 public constant INIT_CODE_PAIR_HASH =
        keccak256(abi.encodePacked(type(DexSwapPair).creationCode));

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairCount);
    event FeeToUpdated(address indexed oldFeeTo, address indexed newFeeTo);
    event FeeToSetterUpdated(address indexed oldFeeToSetter, address indexed newFeeToSetter);
    event ProtocolFeeUpdated(uint8 oldProtocolFeeDenominator, uint8 newProtocolFeeDenominator);
    event SwapFeeUpdated(address indexed pair, uint32 newSwapFee);

    modifier onlyFeeToSetter() {
        require(msg.sender == feeToSetter, 'DexSwapFactory: FORBIDDEN');
        _;
    }

    constructor(address _feeToSetter) public {
        require(_feeToSetter != address(0), 'DexSwapFactory: ZERO_FEE_SETTER');
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);

        require(getPair[token0][token1] == address(0), 'DexSwapFactory: PAIR_EXISTS');

        bytes memory bytecode = type(DexSwapPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        require(pair != address(0), 'DexSwapFactory: CREATE2_FAILED');

        IDexSwapPair(pair).initialize(token0, token1);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;

        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external onlyFeeToSetter {
        emit FeeToUpdated(feeTo, _feeTo);
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external onlyFeeToSetter {
        require(_feeToSetter != address(0), 'DexSwapFactory: ZERO_FEE_SETTER');

        emit FeeToSetterUpdated(feeToSetter, _feeToSetter);
        feeToSetter = _feeToSetter;
    }

    function setProtocolFee(uint8 _protocolFeeDenominator) external onlyFeeToSetter {
        require(_protocolFeeDenominator > 0, 'DexSwapFactory: FORBIDDEN_FEE');

        emit ProtocolFeeUpdated(protocolFeeDenominator, _protocolFeeDenominator);
        protocolFeeDenominator = _protocolFeeDenominator;
    }

    function setSwapFee(address _pair, uint32 _swapFee) external onlyFeeToSetter {
        require(_pair != address(0), 'DexSwapFactory: ZERO_PAIR');

        address token0 = IDexSwapPair(_pair).token0();
        address token1 = IDexSwapPair(_pair).token1();

        require(getPair[token0][token1] == _pair, 'DexSwapFactory: INVALID_PAIR');

        IDexSwapPair(_pair).setSwapFee(_swapFee);

        emit SwapFeeUpdated(_pair, _swapFee);
    }

    function sortTokens(address tokenA, address tokenB) private pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'DexSwapFactory: IDENTICAL_ADDRESSES');

        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        require(token0 != address(0), 'DexSwapFactory: ZERO_ADDRESS');
    }
}
