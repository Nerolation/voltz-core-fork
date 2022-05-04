import { BigNumber, utils } from "ethers";
import { toBn } from "evm-bn";
import { consts } from "../../../helpers/constants";
import { advanceTimeAndBlock } from "../../../helpers/time";
import {
  ALPHA,
  APY_LOWER_MULTIPLIER,
  APY_UPPER_MULTIPLIER,
  BETA,
  encodeSqrtRatioX96,
  MAX_SQRT_RATIO,
  MIN_DELTA_IM,
  MIN_DELTA_LM,
  TICK_SPACING,
  T_MAX,
  XI_LOWER,
  XI_UPPER,
} from "../../../shared/utilities";
import { e2eParameters } from "../e2eSetup";
import { ScenarioRunner } from "../general";

const e2eParams: e2eParameters = {
  duration: consts.ONE_MONTH.mul(3),
  numActors: 4,
  marginCalculatorParams: {
    apyUpperMultiplierWad: APY_UPPER_MULTIPLIER,
    apyLowerMultiplierWad: APY_LOWER_MULTIPLIER,
    minDeltaLMWad: MIN_DELTA_LM,
    minDeltaIMWad: MIN_DELTA_IM,
    sigmaSquaredWad: toBn("0.15"),
    alphaWad: ALPHA,
    betaWad: BETA,
    xiUpperWad: XI_UPPER,
    xiLowerWad: XI_LOWER,
    tMaxWad: T_MAX,

    devMulLeftUnwindLMWad: toBn("0.5"),
    devMulRightUnwindLMWad: toBn("0.5"),
    devMulLeftUnwindIMWad: toBn("0.8"),
    devMulRightUnwindIMWad: toBn("0.8"),

    fixedRateDeviationMinLeftUnwindLMWad: toBn("0.1"),
    fixedRateDeviationMinRightUnwindLMWad: toBn("0.1"),

    fixedRateDeviationMinLeftUnwindIMWad: toBn("0.3"),
    fixedRateDeviationMinRightUnwindIMWad: toBn("0.3"),

    gammaWad: toBn("1.0"),
    minMarginToIncentiviseLiquidators: 0, // keep zero for now then do tests with the min liquidator incentive
  },
  lookBackWindowAPY: consts.ONE_MONTH.mul(3),
  startingPrice: encodeSqrtRatioX96(1, 1),
  feeProtocol: 0,
  fee: toBn("0"),
  tickSpacing: TICK_SPACING,
  positions: [
    [0, -TICK_SPACING, TICK_SPACING],
    [1, -3 * TICK_SPACING, -TICK_SPACING],
    [2, -TICK_SPACING, TICK_SPACING],
    [3, -TICK_SPACING, TICK_SPACING],
  ],
  skipped: false,
};

class ScenarioRunnerInstance extends ScenarioRunner {
  override async run() {
    await this.exportSnapshot("START");

    {
      const mintOrBurnParameters = {
        marginEngine: this.marginEngineTest.address,
        tickLower: this.positions[0][1],
        tickUpper: this.positions[0][2],
        notional: toBn("6000"),
        isMint: true,
        marginDelta: toBn("210"),
      };

      // add 1,000,000 liquidity to Position 0
      await this.e2eSetup.mintOrBurnViaPeriphery(
        this.positions[0][0],
        mintOrBurnParameters
      );
    }

    // two days pass and set reserve normalised income
    await this.advanceAndUpdateApy(consts.ONE_DAY.mul(2), 1, 1.0081); // advance 2 days
    console.log(
      "historical apy:",
      utils.formatEther(
        await this.marginEngineTest.callStatic.getHistoricalApy()
      )
    );

    // Trader 0 engages in a swap that (almost) consumes all of the liquidity of Position 0
    await this.exportSnapshot("BEFORE FIRST SWAP");

    {
      // Trader 0 buys 2,995 VT
      const swapParameters = {
        marginEngine: this.marginEngineTest.address,
        isFT: true,
        notional: toBn("2995"),
        // sqrtPriceLimitX96: BigNumber.from(MIN_SQRT_RATIO.add(1)),
        sqrtPriceLimitX96: BigNumber.from(MAX_SQRT_RATIO.sub(1)),
        tickLower: this.positions[2][1],
        tickUpper: this.positions[2][2],
        marginDelta: toBn("1000"),
      };
      await this.e2eSetup.swapViaPeriphery(
        this.positions[2][0],
        swapParameters
      );
    }

    await this.exportSnapshot("AFTER FIRST SWAP");

    await this.updateCurrentTick();

    // one week passes
    await this.advanceAndUpdateApy(consts.ONE_WEEK, 2, 1.01);
    console.log(
      "historical apy:",
      utils.formatEther(
        await this.marginEngineTest.callStatic.getHistoricalApy()
      )
    );

    // add 5,000,000 liquidity to Position 1

    // print the position margin requirement
    // await this.getAPYboundsAndPositionMargin(this.positions[1]);

    await this.advanceAndUpdateApy(consts.ONE_WEEK.mul(4), 4, 1.04); // advance eight weeks (4 days before maturity)
    console.log(
      "historical apy:",
      utils.formatEther(
        await this.marginEngineTest.callStatic.getHistoricalApy()
      )
    );

    await this.advanceAndUpdateApy(consts.ONE_WEEK.mul(4), 4, 1.05); // advance eight weeks (4 days before maturity)
    console.log(
      "historical apy:",
      utils.formatEther(
        await this.marginEngineTest.callStatic.getHistoricalApy()
      )
    );

    await this.advanceAndUpdateApy(consts.ONE_WEEK.mul(2), 4, 1.06); // advance eight weeks (4 days before maturity)
    console.log(
      "historical apy:",
      utils.formatEther(
        await this.marginEngineTest.callStatic.getHistoricalApy()
      )
    );

    await advanceTimeAndBlock(consts.ONE_DAY.mul(15), 2); // advance 5 days to reach maturity
    console.log(
      "historical apy:",
      utils.formatEther(
        await this.marginEngineTest.callStatic.getHistoricalApy()
      )
    );

    // settle positions and traders
    await this.settlePositions();

    await this.exportSnapshot("FINAL");

    console.log(
      "balance of minter: ",
      utils.formatEther(await this.token.balanceOf(this.positions[0][0]))
    );

    console.log(
      "balance of VT: ",
      utils.formatEther(await this.token.balanceOf(this.positions[2][0]))
    );
  }
}

const test = async () => {
  console.log("scenario", 16);
  const scenario = new ScenarioRunnerInstance(
    e2eParams,
    "test/end_to_end/general_setup/scenario16/console.txt"
  );
  await scenario.init();
  await scenario.run();
};

it("scenario 16", test);
