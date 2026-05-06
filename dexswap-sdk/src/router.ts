import invariant from 'tiny-invariant'
import { TradeType } from './constants'
import { validateAndParseAddress } from './utils'
import { Currency, CurrencyAmount, Percent, Trade } from './entities'

/**
 * Options for producing the arguments to send call to the router.
 */
export interface TradeOptions {
  /**
   * How much the execution price is allowed to move unfavorably from the trade execution price.
   */
  allowedSlippage: Percent

  /**
   * How long the swap is valid until it expires, in seconds.
   * This will be used to produce a `deadline` parameter which is computed from when
   * the swap call parameters are generated.
   */
  ttl: number

  /**
   * The account that should receive the output of the swap.
   */
  recipient: string

  /**
   * Whether any of the tokens in the path are fee-on-transfer tokens,
   * which should be handled with special router methods.
   */
  feeOnTransfer?: boolean
}

export interface TradeOptionsDeadline extends Omit<TradeOptions, 'ttl'> {
  /**
   * When the transaction expires.
   * This is an alternative to specifying the ttl, for when you do not want to use local time.
   */
  deadline: number
}

/**
 * The parameters to use in the call to the Uniswap V2 Router to execute a trade.
 */
export interface SwapParameters {
  /**
   * The method to call on the Uniswap V2 Router.
   */
  methodName: string

  /**
   * The arguments to pass to the method, all hex encoded.
   */
  args: (string | string[])[]

  /**
   * The amount of wei to send in hex.
   */
  value: string
}

type HexString = `0x${string}`

const ZERO_HEX: HexString = '0x0'

function toHex(currencyAmount: CurrencyAmount): HexString {
  return `0x${currencyAmount.raw.toString(16)}`
}

function numberToHex(value: number): HexString {
  invariant(Number.isFinite(value), 'INVALID_HEX_NUMBER')
  invariant(Number.isInteger(value), 'INVALID_HEX_NUMBER')
  invariant(value >= 0, 'INVALID_HEX_NUMBER')

  return `0x${value.toString(16)}`
}

function hasTTL(options: TradeOptions | TradeOptionsDeadline): options is TradeOptions {
  return 'ttl' in options
}

function getDeadline(options: TradeOptions | TradeOptionsDeadline): HexString {
  if (hasTTL(options)) {
    invariant(Number.isFinite(options.ttl), 'TTL')
    invariant(Number.isInteger(options.ttl), 'TTL')
    invariant(options.ttl > 0, 'TTL')

    const currentTimestamp = Math.floor(Date.now() / 1000)
    return numberToHex(currentTimestamp + options.ttl)
  }

  invariant(Number.isFinite(options.deadline), 'DEADLINE')
  invariant(Number.isInteger(options.deadline), 'DEADLINE')
  invariant(options.deadline > 0, 'DEADLINE')

  return numberToHex(options.deadline)
}

interface SwapContext {
  etherIn: boolean
  etherOut: boolean
  amountIn: string
  amountOut: string
  path: string[]
  to: string
  deadline: string
  useFeeOnTransfer: boolean
}

function buildExactInputSwap({
  etherIn,
  etherOut,
  amountIn,
  amountOut,
  path,
  to,
  deadline,
  useFeeOnTransfer
}: SwapContext): SwapParameters {
  if (etherIn) {
    return {
      methodName: useFeeOnTransfer
        ? 'swapExactETHForTokensSupportingFeeOnTransferTokens'
        : 'swapExactETHForTokens',
      args: [amountOut, path, to, deadline],
      value: amountIn
    }
  }

  if (etherOut) {
    return {
      methodName: useFeeOnTransfer
        ? 'swapExactTokensForETHSupportingFeeOnTransferTokens'
        : 'swapExactTokensForETH',
      args: [amountIn, amountOut, path, to, deadline],
      value: ZERO_HEX
    }
  }

  return {
    methodName: useFeeOnTransfer
      ? 'swapExactTokensForTokensSupportingFeeOnTransferTokens'
      : 'swapExactTokensForTokens',
    args: [amountIn, amountOut, path, to, deadline],
    value: ZERO_HEX
  }
}

function buildExactOutputSwap({
  etherIn,
  etherOut,
  amountIn,
  amountOut,
  path,
  to,
  deadline,
  useFeeOnTransfer
}: SwapContext): SwapParameters {
  invariant(!useFeeOnTransfer, 'EXACT_OUT_FOT')

  if (etherIn) {
    return {
      methodName: 'swapETHForExactTokens',
      args: [amountOut, path, to, deadline],
      value: amountIn
    }
  }

  if (etherOut) {
    return {
      methodName: 'swapTokensForExactETH',
      args: [amountOut, amountIn, path, to, deadline],
      value: ZERO_HEX
    }
  }

  return {
    methodName: 'swapTokensForExactTokens',
    args: [amountOut, amountIn, path, to, deadline],
    value: ZERO_HEX
  }
}

/**
 * Represents the Uniswap V2 Router, and has static methods for helping execute trades.
 */
export abstract class Router {
  /**
   * Cannot be constructed.
   */
  private constructor() {}

  /**
   * Produces the on-chain method name to call and the hex encoded parameters
   * to pass as arguments for a given trade.
   *
   * @param trade Trade to produce call parameters for.
   * @param options Options for the call parameters.
   */
  public static swapCallParameters(
    trade: Trade,
    options: TradeOptions | TradeOptionsDeadline
  ): SwapParameters {
    const nativeCurrency = Currency.getNative(trade.chainId)

    const etherIn = trade.inputAmount.currency === nativeCurrency
    const etherOut = trade.outputAmount.currency === nativeCurrency

    // The router does not support both native currency input and native currency output.
    invariant(!(etherIn && etherOut), 'ETHER_IN_OUT')

    const to = validateAndParseAddress(options.recipient)
    const amountIn = toHex(trade.maximumAmountIn(options.allowedSlippage))
    const amountOut = toHex(trade.minimumAmountOut(options.allowedSlippage))
    const path = trade.route.path.map(token => token.address)
    const deadline = getDeadline(options)
    const useFeeOnTransfer = Boolean(options.feeOnTransfer)

    invariant(path.length >= 2, 'INVALID_PATH')

    const context: SwapContext = {
      etherIn,
      etherOut,
      amountIn,
      amountOut,
      path,
      to,
      deadline,
      useFeeOnTransfer
    }

    switch (trade.tradeType) {
      case TradeType.EXACT_INPUT:
        return buildExactInputSwap(context)

      case TradeType.EXACT_OUTPUT:
        return buildExactOutputSwap(context)

      default:
        throw new Error('INVALID_TRADE_TYPE')
    }
  }
}
