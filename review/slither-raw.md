'forge clean' running (wd: C:\Users\1136962520\chipworks-contracts)
'forge config --json' running
'forge build --build-info --deny never --skip ./test/** ./script/** --force' running (wd: C:\Users\1136962520\chipworks-contracts)
**THIS CHECKLIST IS NOT COMPLETE**. Use `--show-ignored-findings` to show all the results.
Summary
 - [weak-prng](#weak-prng) (2 results) (High)
 - [reentrancy-balance](#reentrancy-balance) (4 results) (High)
 - [reentrancy-eth](#reentrancy-eth) (2 results) (High)
 - [divide-before-multiply](#divide-before-multiply) (4 results) (Medium)
 - [erc20-interface](#erc20-interface) (1 results) (Medium)
 - [incorrect-equality](#incorrect-equality) (13 results) (Medium)
 - [reentrancy-no-eth](#reentrancy-no-eth) (6 results) (Medium)
 - [uninitialized-local](#uninitialized-local) (16 results) (Medium)
 - [unused-return](#unused-return) (16 results) (Medium)
 - [shadowing-local](#shadowing-local) (13 results) (Low)
 - [missing-zero-check](#missing-zero-check) (4 results) (Low)
 - [calls-loop](#calls-loop) (41 results) (Low)
 - [reentrancy-benign](#reentrancy-benign) (9 results) (Low)
 - [reentrancy-events](#reentrancy-events) (4 results) (Low)
 - [return-bomb](#return-bomb) (16 results) (Low)
 - [timestamp](#timestamp) (28 results) (Low)
 - [assembly](#assembly) (1 results) (Informational)
 - [pragma](#pragma) (1 results) (Informational)
 - [costly-loop](#costly-loop) (1 results) (Informational)
 - [cyclomatic-complexity](#cyclomatic-complexity) (2 results) (Informational)
 - [low-level-calls](#low-level-calls) (26 results) (Informational)
 - [redundant-statements](#redundant-statements) (1 results) (Informational)
 - [var-read-using-this](#var-read-using-this) (2 results) (Optimization)
## weak-prng
Impact: High
Confidence: Medium
 - [ ] ID-0
[ChipClaims._isOpenAt(uint64,uint32,uint32)](src/ChipClaims.sol#L459-L464) uses a weak PRNG: "[(uint256(ts - windowAnchor) % w) < d](src/ChipClaims.sol#L463)" 

src/ChipClaims.sol#L459-L464


 - [ ] ID-1
[ChipClaims._windowStateAt(uint64,uint32,uint32)](src/ChipClaims.sol#L466-L481) uses a weak PRNG: "[into = elapsed % w](src/ChipClaims.sol#L475)" 

src/ChipClaims.sol#L466-L481


## reentrancy-balance
Impact: High
Confidence: Medium
 - [ ] ID-2
Reentrancy in [ConversionRoutes._convert(address,uint256)](src/base/ConversionRoutes.sol#L216-L257):
	External call allowing reentrancy:
	- [IWETH(weth).deposit{value: amountIn - wethBalance}()](src/base/ConversionRoutes.sol#L232)
	Balance read before the call:
	- [amountIn = nextConversionAmount(token)](src/base/ConversionRoutes.sol#L219)
	Possible stale balance used after the call in a condition:
	- [quoteOut < minOut](src/base/ConversionRoutes.sol#L254)
		- stale variable `minOut`

src/base/ConversionRoutes.sol#L216-L257


 - [ ] ID-3
Reentrancy in [ChipBurner.burnAll()](src/ChipBurner.sol#L114-L136):
	External call allowing reentrancy:
	- [IChipOwnable(address(chipToken)).burn(balanceBefore)](src/ChipBurner.sol#L119)
	Balance read before the call:
	- [balanceBefore = chipToken.balanceOf(address(this))](src/ChipBurner.sol#L115)
	Possible stale balance used after the call in a condition:
	- [balanceAfter >= balanceBefore](src/ChipBurner.sol#L126)
		- stale variable `balanceBefore`

src/ChipBurner.sol#L114-L136


 - [ ] ID-4
Reentrancy in [ConversionRoutes._convert(address,uint256)](src/base/ConversionRoutes.sol#L216-L257):
	External call allowing reentrancy:
	- [IUniswapV3SwapRouter(r.router).exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:token,tokenOut:quoteToken,fee:r.fee,recipient:address(this),amountIn:amountIn,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/base/ConversionRoutes.sol#L238-L249)
	Balance read before the call:
	- [before = IERC20(quoteToken).balanceOf(address(this))](src/base/ConversionRoutes.sol#L235)
	Possible stale balance used after the call in a condition:
	- [quoteOut < minOut](src/base/ConversionRoutes.sol#L254)
		- stale variable `quoteOut`

src/base/ConversionRoutes.sol#L216-L257


 - [ ] ID-5
Reentrancy in [ConversionRoutes._convert(address,uint256)](src/base/ConversionRoutes.sol#L216-L257):
	External call allowing reentrancy:
	- [IUniswapV3SwapRouter(r.router).exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:token,tokenOut:quoteToken,fee:r.fee,recipient:address(this),amountIn:amountIn,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/base/ConversionRoutes.sol#L238-L249)
	Balance read before the call:
	- [amountIn = nextConversionAmount(token)](src/base/ConversionRoutes.sol#L219)
	Possible stale balance used after the call in a condition:
	- [quoteOut < minOut](src/base/ConversionRoutes.sol#L254)
		- stale variable `minOut`

src/base/ConversionRoutes.sol#L216-L257


## reentrancy-eth
Impact: High
Confidence: Medium
 - [ ] ID-6
Reentrancy in [FeeSplitter._splitETH(uint256)](src/FeeSplitter.sol#L312-L318):
	External calls:
	- [_payEth(pot,potAmount)](src/FeeSplitter.sol#L315)
		- [(ok,None) = address(to).call{gas: PAYOUT_GAS,value: amount}()](src/FeeSplitter.sol#L325)
	- [_payEth(ops,opsAmount)](src/FeeSplitter.sol#L316)
		- [(ok,None) = address(to).call{gas: PAYOUT_GAS,value: amount}()](src/FeeSplitter.sol#L325)
	State variables written after the call(s):
	- [_payEth(ops,opsAmount)](src/FeeSplitter.sol#L316)
		- [owedEth[to] += amount](src/FeeSplitter.sol#L328)
	[FeeSplitter.owedEth](src/FeeSplitter.sol#L78) can be used in cross function reentrancies:
	- [FeeSplitter.owedEth](src/FeeSplitter.sol#L78)
	- [_payEth(ops,opsAmount)](src/FeeSplitter.sol#L316)
		- [totalOwedEth += amount](src/FeeSplitter.sol#L329)
	[FeeSplitter.totalOwedEth](src/FeeSplitter.sol#L81) can be used in cross function reentrancies:
	- [FeeSplitter.distributableEth()](src/FeeSplitter.sol#L164-L168)
	- [FeeSplitter.totalOwedEth](src/FeeSplitter.sol#L81)

src/FeeSplitter.sol#L312-L318


 - [ ] ID-7
Reentrancy in [FeeSplitter._splitETH(uint256)](src/FeeSplitter.sol#L312-L318):
	External calls:
	- [_payEth(pot,potAmount)](src/FeeSplitter.sol#L315)
		- [(ok,None) = address(to).call{gas: PAYOUT_GAS,value: amount}()](src/FeeSplitter.sol#L325)
	- [_payEth(ops,opsAmount)](src/FeeSplitter.sol#L316)
		- [(ok,None) = address(to).call{gas: PAYOUT_GAS,value: amount}()](src/FeeSplitter.sol#L325)
	- [_payEth(polTreasury,polAmount)](src/FeeSplitter.sol#L317)
		- [(ok,None) = address(to).call{gas: PAYOUT_GAS,value: amount}()](src/FeeSplitter.sol#L325)
	State variables written after the call(s):
	- [_payEth(polTreasury,polAmount)](src/FeeSplitter.sol#L317)
		- [owedEth[to] += amount](src/FeeSplitter.sol#L328)
	[FeeSplitter.owedEth](src/FeeSplitter.sol#L78) can be used in cross function reentrancies:
	- [FeeSplitter.owedEth](src/FeeSplitter.sol#L78)
	- [_payEth(polTreasury,polAmount)](src/FeeSplitter.sol#L317)
		- [totalOwedEth += amount](src/FeeSplitter.sol#L329)
	[FeeSplitter.totalOwedEth](src/FeeSplitter.sol#L81) can be used in cross function reentrancies:
	- [FeeSplitter.distributableEth()](src/FeeSplitter.sol#L164-L168)
	- [FeeSplitter.totalOwedEth](src/FeeSplitter.sol#L81)

src/FeeSplitter.sol#L312-L318


## divide-before-multiply
Impact: Medium
Confidence: Medium
 - [ ] ID-8
[ChipRounds._minOutFor(address,uint256)](src/ChipRounds.sol#L885-L897) performs a multiplication on the result of a division:
	- [expectedOut = (spendUsd * (10 ** dec)) / price1e18](src/ChipRounds.sol#L895)
	- [(expectedOut * (BPS - maxSlippageBps(stock))) / BPS](src/ChipRounds.sol#L896)

src/ChipRounds.sol#L885-L897


 - [ ] ID-9
[ChipRounds._minOutFor(address,uint256)](src/ChipRounds.sol#L885-L897) performs a multiplication on the result of a division:
	- [spendUsd = (spendAmount * 1e18) / (10 ** registry.quoteDecimals())](src/ChipRounds.sol#L894)
	- [expectedOut = (spendUsd * (10 ** dec)) / price1e18](src/ChipRounds.sol#L895)

src/ChipRounds.sol#L885-L897


 - [ ] ID-10
[POLTreasury._requirePoolOnMark(address,address)](src/POLTreasury.sol#L726-L734) performs a multiplication on the result of a division:
	- [mark = (_readFeed(a.feed,a.maxFeedAge) * (10 ** quoteDecimals)) / (10 ** a.feedDecimals)](src/POLTreasury.sol#L728)
	- [tolerance = (mark * a.maxDeviationBps) / BPS](src/POLTreasury.sol#L731)

src/POLTreasury.sol#L726-L734


 - [ ] ID-11
[ConversionRoutes.minOutFor(address,uint256)](src/base/ConversionRoutes.sol#L175-L184) performs a multiplication on the result of a division:
	- [gross = (amount * answer * (10 ** quoteDecimals)) / (10 ** r.feedDecimals) / (10 ** r.tokenDecimals)](src/base/ConversionRoutes.sol#L182)
	- [(gross * (BPS - r.maxSlippageBps)) / BPS](src/base/ConversionRoutes.sol#L183)

src/base/ConversionRoutes.sol#L175-L184


## erc20-interface
Impact: Medium
Confidence: High
 - [ ] ID-12
[IERC721Approve](src/POLTreasury.sol#L783-L785) has incorrect ERC20 function interface:[IERC721Approve.approve(address,uint256)](src/POLTreasury.sol#L784)

src/POLTreasury.sol#L783-L785


## incorrect-equality
Impact: Medium
Confidence: High
 - [ ] ID-13
[ChipBurner.burnAll()](src/ChipBurner.sol#L114-L136) uses a dangerous strict equality:
	- [balanceBefore == 0](src/ChipBurner.sol#L116)

src/ChipBurner.sol#L114-L136


 - [ ] ID-14
[FeeSplitter._payToken(IERC20,address,uint256)](src/FeeSplitter.sol#L368-L374) uses a dangerous strict equality:
	- [amount == 0](src/FeeSplitter.sol#L369)

src/FeeSplitter.sol#L368-L374


 - [ ] ID-15
[FeeSplitter.distributeETH()](src/FeeSplitter.sol#L192-L196) uses a dangerous strict equality:
	- [balance == 0](src/FeeSplitter.sol#L194)

src/FeeSplitter.sol#L192-L196


 - [ ] ID-16
[FeeSplitter.distributeAll(IERC20[])](src/FeeSplitter.sol#L225-L236) uses a dangerous strict equality:
	- [tokenBalance == 0](src/FeeSplitter.sol#L233)

src/FeeSplitter.sol#L225-L236


 - [ ] ID-17
[ChipRounds.nextRoundOpensAt()](src/ChipRounds.sol#L568-L570) uses a dangerous strict equality:
	- [lastRoundOpenedAt == 0](src/ChipRounds.sol#L569)

src/ChipRounds.sol#L568-L570


 - [ ] ID-18
[FeeSplitter._payEth(address,uint256)](src/FeeSplitter.sol#L323-L331) uses a dangerous strict equality:
	- [amount == 0](src/FeeSplitter.sol#L324)

src/FeeSplitter.sol#L323-L331


 - [ ] ID-19
[FeeSplitter.distributeToken(IERC20)](src/FeeSplitter.sol#L199-L208) uses a dangerous strict equality:
	- [balance == 0](src/FeeSplitter.sol#L206)

src/FeeSplitter.sol#L199-L208


 - [ ] ID-20
[ConversionRoutes._convert(address,uint256)](src/base/ConversionRoutes.sol#L216-L257) uses a dangerous strict equality:
	- [amountIn == 0](src/base/ConversionRoutes.sol#L220)

src/base/ConversionRoutes.sol#L216-L257


 - [ ] ID-21
[FeeSplitter.distributeTokens(IERC20[])](src/FeeSplitter.sol#L212-L221) uses a dangerous strict equality:
	- [balance == 0](src/FeeSplitter.sol#L218)

src/FeeSplitter.sol#L212-L221


 - [ ] ID-22
[Pot.sweepEth(address)](src/Pot.sol#L221-L227) uses a dangerous strict equality:
	- [amount == 0](src/Pot.sol#L224)

src/Pot.sol#L221-L227


 - [ ] ID-23
[POLTreasury.forwardIncome(address)](src/POLTreasury.sol#L593-L599) uses a dangerous strict equality:
	- [amount == 0](src/POLTreasury.sol#L596)

src/POLTreasury.sol#L593-L599


 - [ ] ID-24
[Pot.sweepNonQuote(address,address)](src/Pot.sol#L211-L218) uses a dangerous strict equality:
	- [amount == 0](src/Pot.sol#L215)

src/Pot.sol#L211-L218


 - [ ] ID-25
[ConversionRoutes._convert(address,uint256)](src/base/ConversionRoutes.sol#L216-L257) uses a dangerous strict equality:
	- [minOut == 0](src/base/ConversionRoutes.sol#L226)

src/base/ConversionRoutes.sol#L216-L257


## reentrancy-no-eth
Impact: Medium
Confidence: Medium
 - [ ] ID-26
Reentrancy in [Anvil.unshelve(address,uint256,address)](src/anvil/Anvil.sol#L476-L510):
	External calls:
	- [IERC721(collection).transferFrom(address(this),to,id)](src/anvil/Anvil.sol#L507)
	State variables written after the call(s):
	- [sh.slots.pop()](src/anvil/Anvil.sol#L490)
	[Anvil._shelf](src/anvil/Anvil.sol#L115) can be used in cross function reentrancies:
	- [Anvil.nextOnShelf(address)](src/anvil/Anvil.sol#L379-L387)
	- [Anvil.shelfQueue(address)](src/anvil/Anvil.sol#L390-L400)
	- [Anvil.shelfRemaining(address)](src/anvil/Anvil.sol#L372-L374)
	- [Anvil.shelfState(address)](src/anvil/Anvil.sol#L413-L424)
	- [sh.slots.pop()](src/anvil/Anvil.sol#L500)
	[Anvil._shelf](src/anvil/Anvil.sol#L115) can be used in cross function reentrancies:
	- [Anvil.nextOnShelf(address)](src/anvil/Anvil.sol#L379-L387)
	- [Anvil.shelfQueue(address)](src/anvil/Anvil.sol#L390-L400)
	- [Anvil.shelfRemaining(address)](src/anvil/Anvil.sol#L372-L374)
	- [Anvil.shelfState(address)](src/anvil/Anvil.sol#L413-L424)
	- [-- sh.listed](src/anvil/Anvil.sol#L503)
	[Anvil._shelf](src/anvil/Anvil.sol#L115) can be used in cross function reentrancies:
	- [Anvil.nextOnShelf(address)](src/anvil/Anvil.sol#L379-L387)
	- [Anvil.shelfQueue(address)](src/anvil/Anvil.sol#L390-L400)
	- [Anvil.shelfRemaining(address)](src/anvil/Anvil.sol#L372-L374)
	- [Anvil.shelfState(address)](src/anvil/Anvil.sol#L413-L424)

src/anvil/Anvil.sol#L476-L510


 - [ ] ID-27
Reentrancy in [ChipRounds.openRound()](src/ChipRounds.sol#L573-L598):
	External calls:
	- [got = pot.pullBudget(availableInPot)](src/ChipRounds.sol#L582)
	State variables written after the call(s):
	- [lastRoundOpenedAt = uint64(block.timestamp)](src/ChipRounds.sol#L594)
	[ChipRounds.lastRoundOpenedAt](src/ChipRounds.sol#L195) can be used in cross function reentrancies:
	- [ChipRounds.lastRoundOpenedAt](src/ChipRounds.sol#L195)
	- [ChipRounds.nextRoundOpensAt()](src/ChipRounds.sol#L568-L570)

src/ChipRounds.sol#L573-L598


 - [ ] ID-28
Reentrancy in [ChipRounds.contributeWeights(uint256,address,uint256[])](src/ChipRounds.sol#L603-L625):
	External calls:
	- [added += _allocate(roundId,collection,tokenId,owner,weight)](src/ChipRounds.sol#L620)
		- [claims.creditWeight(roundId,stock,owner,weight)](src/ChipRounds.sol#L674)
	State variables written after the call(s):
	- [r.totalWeight += added](src/ChipRounds.sol#L623)
	[ChipRounds._rounds](src/ChipRounds.sol#L199) can be used in cross function reentrancies:
	- [ChipRounds.getRound(uint256)](src/ChipRounds.sol#L559-L561)
	- [counted[roundId][collection][tokenId] = true](src/ChipRounds.sol#L619)
	[ChipRounds.counted](src/ChipRounds.sol#L204) can be used in cross function reentrancies:
	- [ChipRounds.counted](src/ChipRounds.sol#L204)

src/ChipRounds.sol#L603-L625


 - [ ] ID-29
Reentrancy in [Anvil.shelve(address,uint256[])](src/anvil/Anvil.sol#L446-L455):
	External calls:
	- [IERC721(collection).transferFrom(msg.sender,address(this),id)](src/anvil/Anvil.sol#L451)
	State variables written after the call(s):
	- [_list(collection,id)](src/anvil/Anvil.sol#L452)
		- [sh.slots.push(id + 1)](src/anvil/Anvil.sol#L336)
		- [++ sh.listed](src/anvil/Anvil.sol#L339)
	[Anvil._shelf](src/anvil/Anvil.sol#L115) can be used in cross function reentrancies:
	- [Anvil.nextOnShelf(address)](src/anvil/Anvil.sol#L379-L387)
	- [Anvil.shelfQueue(address)](src/anvil/Anvil.sol#L390-L400)
	- [Anvil.shelfRemaining(address)](src/anvil/Anvil.sol#L372-L374)
	- [Anvil.shelfState(address)](src/anvil/Anvil.sol#L413-L424)
	- [_list(collection,id)](src/anvil/Anvil.sol#L452)
		- [_slotOf[collection][id] = sh.slots.length](src/anvil/Anvil.sol#L337)
	[Anvil._slotOf](src/anvil/Anvil.sol#L121) can be used in cross function reentrancies:
	- [Anvil.isListed(address,uint256)](src/anvil/Anvil.sol#L363-L365)

src/anvil/Anvil.sol#L446-L455


 - [ ] ID-30
Reentrancy in [Furnace.depositStock(address,uint256[])](src/furnace/Furnace.sol#L503-L510):
	External calls:
	- [IERC721(collection).transferFrom(msg.sender,address(this),tokenIds[i])](src/furnace/Furnace.sol#L506)
	State variables written after the call(s):
	- [_stock[collection].push(tokenIds[i])](src/furnace/Furnace.sol#L507)
	[Furnace._stock](src/furnace/Furnace.sol#L156) can be used in cross function reentrancies:
	- [Furnace.executeStockSkip(address)](src/furnace/Furnace.sol#L564-L577)
	- [Furnace.nextOutput(uint8)](src/furnace/Furnace.sol#L467-L474)
	- [Furnace.queueStockSkip(address)](src/furnace/Furnace.sol#L548-L557)
	- [Furnace.stockQueue(address)](src/furnace/Furnace.sol#L477-L484)
	- [Furnace.stockRemainingFor(address)](src/furnace/Furnace.sol#L462-L464)

src/furnace/Furnace.sol#L503-L510


 - [ ] ID-31
Reentrancy in [ChipRounds.settleStock(uint256,address)](src/ChipRounds.sol#L708-L783):
	External calls:
	- [(executed,received,quoteSpent,reason) = _buy(stock,spend)](src/ChipRounds.sol#L750)
		- [uniswapRouter.exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,fee:s.fee,recipient:address(this),amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L949-L963)
		- [slipstreamRouter.exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,tickSpacing:s.tickSpacing,recipient:address(this),deadline:block.timestamp,amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L965-L980)
	- [heldBack = _sendHoldback(stock,received)](src/ChipRounds.sol#L764)
		- [(ok,None) = stock.call(abi.encodeCall(IERC20.transfer,(treasury,target)))](src/ChipRounds.sol#L860)
	State variables written after the call(s):
	- [r.spent += uint128(quoteSpent)](src/ChipRounds.sol#L768)
	[ChipRounds._rounds](src/ChipRounds.sol#L199) can be used in cross function reentrancies:
	- [ChipRounds.getRound(uint256)](src/ChipRounds.sol#L559-L561)

src/ChipRounds.sol#L708-L783


## uninitialized-local
Impact: Medium
Confidence: Medium
 - [ ] ID-32
[ChipRounds._minOutFor(address,uint256).price1e18](src/ChipRounds.sol#L887) is a local variable never initialized

src/ChipRounds.sol#L887


 - [ ] ID-33
[ChipRounds.setSplit(address,uint256,address[],uint8[]).p](src/ChipRounds.sol#L524) is a local variable never initialized

src/ChipRounds.sol#L524


 - [ ] ID-34
[Anvil.shelfQueue(address).k](src/anvil/Anvil.sol#L395) is a local variable never initialized

src/anvil/Anvil.sol#L395


 - [ ] ID-35
[StockRegistry._setVenue(address,Venue,address,uint24,int24).expected](src/StockRegistry.sol#L321) is a local variable never initialized

src/StockRegistry.sol#L321


 - [ ] ID-36
[ClaimRouter.claimEverything(ClaimRouter.ChipClaim[]).failed](src/ClaimRouter.sol#L152) is a local variable never initialized

src/ClaimRouter.sol#L152


 - [ ] ID-37
[ChipRounds.setSplit(address,uint256,address[],uint8[]).fee](src/ChipRounds.sol#L538) is a local variable never initialized

src/ChipRounds.sol#L538


 - [ ] ID-38
[ChipRounds.contributeWeights(uint256,address,uint256[]).accepted](src/ChipRounds.sol#L608) is a local variable never initialized

src/ChipRounds.sol#L608


 - [ ] ID-39
[ChipRounds._buy(address,uint256).ok](src/ChipRounds.sol#L947) is a local variable never initialized

src/ChipRounds.sol#L947


 - [ ] ID-40
[Furnace._forge(uint8,uint256[],uint256,bool).trueBurned](src/furnace/Furnace.sol#L361) is a local variable never initialized

src/furnace/Furnace.sol#L361


 - [ ] ID-41
[ChipRounds.setSplit(address,uint256,address[],uint8[]).sum](src/ChipRounds.sol#L522) is a local variable never initialized

src/ChipRounds.sol#L522


 - [ ] ID-42
[ChipRounds.contributeWeights(uint256,address,uint256[]).added](src/ChipRounds.sol#L607) is a local variable never initialized

src/ChipRounds.sol#L607


 - [ ] ID-43
[StockRegistry.enabledTokens().k](src/StockRegistry.sol#L217) is a local variable never initialized

src/StockRegistry.sol#L217


 - [ ] ID-44
[ChipRounds._deliver(uint256,address,uint256).sent](src/ChipRounds.sol#L824) is a local variable never initialized

src/ChipRounds.sol#L824


 - [ ] ID-45
[StockRegistry.enabledTokens().n](src/StockRegistry.sol#L211) is a local variable never initialized

src/StockRegistry.sol#L211


 - [ ] ID-46
[ChipRounds.setSplit(address,uint256,address[],uint8[]).s](src/ChipRounds.sol#L523) is a local variable never initialized

src/ChipRounds.sol#L523


 - [ ] ID-47
[Anvil.unshelve(address,uint256,address).id](src/anvil/Anvil.sol#L494) is a local variable never initialized

src/anvil/Anvil.sol#L494


## unused-return
Impact: Medium
Confidence: Medium
 - [ ] ID-48
[ChipRounds._buy(address,uint256)](src/ChipRounds.sol#L923-L994) ignores return value by [slipstreamRouter.exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,tickSpacing:s.tickSpacing,recipient:address(this),deadline:block.timestamp,amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L965-L980)

src/ChipRounds.sol#L923-L994


 - [ ] ID-49
[ConversionRoutes._readFeed(address,uint64)](src/base/ConversionRoutes.sol#L199-L208) ignores return value by [(None,raw,None,updatedAt,None) = IAggregatorV3(feed).latestRoundData()](src/base/ConversionRoutes.sol#L202)

src/base/ConversionRoutes.sol#L199-L208


 - [ ] ID-50
[StockRegistry.priceUsd(address)](src/StockRegistry.sol#L230-L237) ignores return value by [(None,answer,None,updatedAt_,None) = IAggregatorV3(s.feed).latestRoundData()](src/StockRegistry.sol#L233)

src/StockRegistry.sol#L230-L237


 - [ ] ID-51
[ConversionRoutes._convert(address,uint256)](src/base/ConversionRoutes.sol#L216-L257) ignores return value by [IUniswapV3SwapRouter(r.router).exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:token,tokenOut:quoteToken,fee:r.fee,recipient:address(this),amountIn:amountIn,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/base/ConversionRoutes.sol#L238-L249)

src/base/ConversionRoutes.sol#L216-L257


 - [ ] ID-52
[ChipRounds._roundValueUsd(uint256,address[])](src/ChipRounds.sol#L1062-L1078) ignores return value by [(price1e18) = registry.priceUsd(stock)](src/ChipRounds.sol#L1071-L1076)

src/ChipRounds.sol#L1062-L1078


 - [ ] ID-53
[NounLoans.isChippedFor(address,uint256,address)](src/loans/NounLoans.sol#L503-L506) ignores return value by [(chipped,None,chipOwner) = activationSource.activation(collection,tokenId)](src/loans/NounLoans.sol#L504)

src/loans/NounLoans.sol#L503-L506


 - [ ] ID-54
[ChipRounds._buy(address,uint256)](src/ChipRounds.sol#L923-L994) ignores return value by [uniswapRouter.exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,fee:s.fee,recipient:address(this),amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L949-L963)

src/ChipRounds.sol#L923-L994


 - [ ] ID-55
[ChipRounds.finalizeRound(uint256)](src/ChipRounds.sol#L998-L1024) ignores return value by [claims.freezeSchedule(roundId)](src/ChipRounds.sol#L1018)

src/ChipRounds.sol#L998-L1024


 - [ ] ID-56
[ChipClaims._usdValue(address,uint256)](src/ChipClaims.sol#L633-L640) ignores return value by [(price1e18) = registry.priceUsd(token)](src/ChipClaims.sol#L635-L639)

src/ChipClaims.sol#L633-L640


 - [ ] ID-57
[ChipRounds._minOutFor(address,uint256)](src/ChipRounds.sol#L885-L897) ignores return value by [(p) = registry.priceUsd(stock)](src/ChipRounds.sol#L888-L892)

src/ChipRounds.sol#L885-L897


 - [ ] ID-58
[ConversionRoutes._requireSequencerUp()](src/base/ConversionRoutes.sol#L268-L279) ignores return value by [(None,up,startedAt,None,None) = IAggregatorV3(feed).latestRoundData()](src/base/ConversionRoutes.sol#L272)

src/base/ConversionRoutes.sol#L268-L279


 - [ ] ID-59
[POLTreasury.collectAllFees()](src/POLTreasury.sol#L487-L494) ignores return value by [() = this.collectFees(positionIds[i])](src/POLTreasury.sol#L490-L492)

src/POLTreasury.sol#L487-L494


 - [ ] ID-60
[POLTreasury.forwardIncomeMany(address[])](src/POLTreasury.sol#L603-L609) ignores return value by [this.forwardIncome(tokens[i])](src/POLTreasury.sol#L605-L607)

src/POLTreasury.sol#L603-L609


 - [ ] ID-61
[NounLoans.borrow(address,uint256,uint8,uint256)](src/loans/NounLoans.sol#L270-L342) ignores return value by [(chipped,None,chipOwner) = activationSource.activation(collection,tokenId)](src/loans/NounLoans.sol#L299)

src/loans/NounLoans.sol#L270-L342


 - [ ] ID-62
[POLTreasury._positionPool(uint256)](src/POLTreasury.sol#L706-L710) ignores return value by [(None,None,token0,token1,tickSpacing,None,None,None,None,None,None,None) = positionManager.positions(tokenId)](src/POLTreasury.sol#L708)

src/POLTreasury.sol#L706-L710


 - [ ] ID-63
[ChipRounds.isFeedStale(address)](src/ChipRounds.sol#L870-L881) ignores return value by [(updatedAt) = registry.priceUsd(stock)](src/ChipRounds.sol#L873-L880)

src/ChipRounds.sol#L870-L881


## shadowing-local
Impact: Low
Confidence: High
 - [ ] ID-64
[POLTreasury.notifyCompound(address,address,uint256,uint256).owner](src/POLTreasury.sol#L619) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/POLTreasury.sol#L619


 - [ ] ID-65
[ChipRounds.contributeWeights(uint256,address,uint256[]).owner](src/ChipRounds.sol#L613) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipRounds.sol#L613


 - [ ] ID-66
[ChipRounds._allocate(uint256,address,uint256,address,uint256).owner](src/ChipRounds.sol#L649) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipRounds.sol#L649


 - [ ] ID-67
[ChipClaims.claimFor(address,uint256,address).owner](src/ChipClaims.sol#L252) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipClaims.sol#L252


 - [ ] ID-68
[ChipClaims._claim(uint256,address,address).owner](src/ChipClaims.sol#L273) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipClaims.sol#L273


 - [ ] ID-69
[ChipRounds._credit(uint256,address,address,uint256).owner](src/ChipRounds.sol#L669) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipRounds.sol#L669


 - [ ] ID-70
[ChipActivation.activation(address,uint256).owner](src/activation/ChipActivation.sol#L499) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/activation/ChipActivation.sol#L499


 - [ ] ID-71
[ClutchVaultAdapter.activation(address,uint256).owner](src/adapters/ClutchVaultAdapter.sol#L103) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/adapters/ClutchVaultAdapter.sol#L103


 - [ ] ID-72
[ClaimRouter.claimEverything(ClaimRouter.ChipClaim[]).owner](src/ClaimRouter.sol#L151) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ClaimRouter.sol#L151


 - [ ] ID-73
[ClaimRouter._claimChip(address,ClaimRouter.ChipClaim).owner](src/ClaimRouter.sol#L210) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ClaimRouter.sol#L210


 - [ ] ID-74
[ChipClaims.sweepExpired(uint256,address,uint256).owner](src/ChipClaims.sol#L346) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipClaims.sol#L346


 - [ ] ID-75
[ChipClaims.creditWeight(uint256,address,address,uint256).owner](src/ChipClaims.sol#L183) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipClaims.sol#L183


 - [ ] ID-76
[ChipClaims.claimable(uint256,address,address).owner](src/ChipClaims.sol#L233) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipClaims.sol#L233


## missing-zero-check
Impact: Low
Confidence: Medium
 - [ ] ID-77
[ClutchVaultAdapter.effectiveOwner(address,uint256).collection](src/adapters/ClutchVaultAdapter.sol#L141) lacks a zero-check on :
		- [(ok,ret) = collection.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L142-L143)

src/adapters/ClutchVaultAdapter.sol#L141


 - [ ] ID-78
[POLTreasury.setManager(address).newManager](src/POLTreasury.sol#L210) lacks a zero-check on :
		- [manager = newManager](src/POLTreasury.sol#L212)

src/POLTreasury.sol#L210


 - [ ] ID-79
[POLTreasury.setRewards(address).newRewards](src/POLTreasury.sol#L221) lacks a zero-check on :
		- [rewards = newRewards](src/POLTreasury.sol#L223)

src/POLTreasury.sol#L221


 - [ ] ID-80
[ChipRounds.setChip(address).token](src/ChipRounds.sol#L326) lacks a zero-check on :
		- [chipToken = token](src/ChipRounds.sol#L327)

src/ChipRounds.sol#L326


## calls-loop
Impact: Low
Confidence: Medium
 - [ ] ID-81
[ChipRounds._roundValueUsd(uint256,address[])](src/ChipRounds.sol#L1062-L1078) has external calls inside a loop: [valueUsd += (amount * 1e18) / (10 ** registry.quoteDecimals())](src/ChipRounds.sol#L1068)
	Calls stack containing the loop:
		ChipRounds.finalizeRound(uint256)

src/ChipRounds.sol#L1062-L1078


 - [ ] ID-82
[ChipRounds.contributeWeights(uint256,address,uint256[])](src/ChipRounds.sol#L603-L625) has external calls inside a loop: [(active,tierBps,owner) = activationSource.activation(collection,tokenId)](src/ChipRounds.sol#L613)

src/ChipRounds.sol#L603-L625


 - [ ] ID-83
[POLTreasury.forwardIncomeMany(address[])](src/POLTreasury.sol#L603-L609) has external calls inside a loop: [this.forwardIncome(tokens[i])](src/POLTreasury.sol#L605-L607)

src/POLTreasury.sol#L603-L609


 - [ ] ID-84
[Furnace._consumeFuel(uint256)](src/furnace/Furnace.sol#L419-L430) has external calls inside a loop: [fuelCollection.transferFrom(msg.sender,BURN_ADDRESS,tokenId)](src/furnace/Furnace.sol#L427)
	Calls stack containing the loop:
		Furnace.forge(uint8,uint256[])
		Furnace._forge(uint8,uint256[],uint256,bool)

src/furnace/Furnace.sol#L419-L430


 - [ ] ID-85
[Furnace._consumeFuel(uint256)](src/furnace/Furnace.sol#L419-L430) has external calls inside a loop: [(ok,None) = address(fuelCollection).call{gas: FUEL_BURN_GAS}(abi.encodeWithSignature(burn(uint256),tokenId))](src/furnace/Furnace.sol#L420)
	Calls stack containing the loop:
		Furnace.forge(uint8,uint256[],uint256)
		Furnace._forge(uint8,uint256[],uint256,bool)

src/furnace/Furnace.sol#L419-L430


 - [ ] ID-86
[Furnace._fuelExists(uint256)](src/furnace/Furnace.sol#L433-L437) has external calls inside a loop: [(ok,ret) = address(fuelCollection).staticcall{gas: FUEL_BURN_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/furnace/Furnace.sol#L434-L435)
	Calls stack containing the loop:
		Furnace.forge(uint8,uint256[],uint256)
		Furnace._forge(uint8,uint256[],uint256,bool)
		Furnace._consumeFuel(uint256)

src/furnace/Furnace.sol#L433-L437


 - [ ] ID-87
[ClaimRouter._balanceOfSelf(address)](src/ClaimRouter.sol#L258-L263) has external calls inside a loop: [(ok,ret) = token.staticcall{gas: legGasLimit}(abi.encodeCall(IERC20.balanceOf,(address(this))))](src/ClaimRouter.sol#L259-L260)
	Calls stack containing the loop:
		ClaimRouter.sweepTo(address,address[])
		ClaimRouter._sweep(address,address[])

src/ClaimRouter.sol#L258-L263


 - [ ] ID-88
[ChipRounds._credit(uint256,address,address,uint256)](src/ChipRounds.sol#L669-L675) has external calls inside a loop: [claims.creditWeight(roundId,stock,owner,weight)](src/ChipRounds.sol#L674)
	Calls stack containing the loop:
		ChipRounds.contributeWeights(uint256,address,uint256[])
		ChipRounds._allocate(uint256,address,uint256,address,uint256)

src/ChipRounds.sol#L669-L675


 - [ ] ID-89
[Furnace._consumeFuel(uint256)](src/furnace/Furnace.sol#L419-L430) has external calls inside a loop: [fuelCollection.ownerOf(tokenId) != BURN_ADDRESS](src/furnace/Furnace.sol#L428)
	Calls stack containing the loop:
		Furnace.forge(uint8,uint256[],uint256)
		Furnace._forge(uint8,uint256[],uint256,bool)

src/furnace/Furnace.sol#L419-L430


 - [ ] ID-90
[ClaimRouter._claimChip(address,ClaimRouter.ChipClaim)](src/ClaimRouter.sol#L210-L215) has external calls inside a loop: [(ok,ret) = address(rewards).call{gas: legGasLimit}(abi.encodeCall(IChipRewardsClaimable.claimFor,(owner,c.roundId,c.stock)))](src/ClaimRouter.sol#L211-L213)
	Calls stack containing the loop:
		ClaimRouter.claimEverything(ClaimRouter.ChipClaim[])

src/ClaimRouter.sol#L210-L215


 - [ ] ID-91
[FeeSplitter.distributeAll(IERC20[])](src/FeeSplitter.sol#L225-L236) has external calls inside a loop: [tokenBalance = token.balanceOf(address(this))](src/FeeSplitter.sol#L232)

src/FeeSplitter.sol#L225-L236


 - [ ] ID-92
[Furnace.depositStock(address,uint256[])](src/furnace/Furnace.sol#L503-L510) has external calls inside a loop: [IERC721(collection).transferFrom(msg.sender,address(this),tokenIds[i])](src/furnace/Furnace.sol#L506)

src/furnace/Furnace.sol#L503-L510


 - [ ] ID-93
[FeeSplitter._payToken(IERC20,address,uint256)](src/FeeSplitter.sol#L368-L374) has external calls inside a loop: [remaining = token.balanceOf(address(this))](src/FeeSplitter.sol#L372)
	Calls stack containing the loop:
		FeeSplitter.distributeAll(IERC20[])
		FeeSplitter._splitToken(IERC20,uint256)

src/FeeSplitter.sol#L368-L374


 - [ ] ID-94
[ChipRounds._roundValueUsd(uint256,address[])](src/ChipRounds.sol#L1062-L1078) has external calls inside a loop: [dec = registry.getStock(stock).tokenDecimals](src/ChipRounds.sol#L1072)
	Calls stack containing the loop:
		ChipRounds.finalizeRound(uint256)

src/ChipRounds.sol#L1062-L1078


 - [ ] ID-95
[ChipRounds._allocate(uint256,address,uint256,address,uint256)](src/ChipRounds.sol#L649-L667) has external calls inside a loop: [registry.isEnabled(sp.stocks[i])](src/ChipRounds.sol#L663)
	Calls stack containing the loop:
		ChipRounds.contributeWeights(uint256,address,uint256[])

src/ChipRounds.sol#L649-L667


 - [ ] ID-96
[Furnace._consumeFuel(uint256)](src/furnace/Furnace.sol#L419-L430) has external calls inside a loop: [fuelCollection.transferFrom(msg.sender,BURN_ADDRESS,tokenId)](src/furnace/Furnace.sol#L427)
	Calls stack containing the loop:
		Furnace.forge(uint8,uint256[],uint256)
		Furnace._forge(uint8,uint256[],uint256,bool)

src/furnace/Furnace.sol#L419-L430


 - [ ] ID-97
[ChipRounds._roundValueUsd(uint256,address[])](src/ChipRounds.sol#L1062-L1078) has external calls inside a loop: [amount = IChipClaimsView(address(claims)).acquired(roundId,stock)](src/ChipRounds.sol#L1065)
	Calls stack containing the loop:
		ChipRounds.finalizeRound(uint256)

src/ChipRounds.sol#L1062-L1078


 - [ ] ID-98
[Anvil.shelve(address,uint256[])](src/anvil/Anvil.sol#L446-L455) has external calls inside a loop: [IERC721(collection).transferFrom(msg.sender,address(this),id)](src/anvil/Anvil.sol#L451)

src/anvil/Anvil.sol#L446-L455


 - [ ] ID-99
[ChipRounds._roundValueUsd(uint256,address[])](src/ChipRounds.sol#L1062-L1078) has external calls inside a loop: [(price1e18) = registry.priceUsd(stock)](src/ChipRounds.sol#L1071-L1076)
	Calls stack containing the loop:
		ChipRounds.finalizeRound(uint256)

src/ChipRounds.sol#L1062-L1078


 - [ ] ID-100
[ChipClaims._usdValue(address,uint256)](src/ChipClaims.sol#L633-L640) has external calls inside a loop: [(amount * 1e18) / (10 ** registry.quoteDecimals())](src/ChipClaims.sol#L634)
	Calls stack containing the loop:
		ChipClaims.claimMany(uint256[],address[])
		ChipClaims._claim(uint256,address,address)

src/ChipClaims.sol#L633-L640


 - [ ] ID-101
[FeeSplitter._splitToken(IERC20,uint256)](src/FeeSplitter.sol#L351-L365) has external calls inside a loop: [remaining = token.balanceOf(address(this))](src/FeeSplitter.sol#L360)
	Calls stack containing the loop:
		FeeSplitter.distributeTokens(IERC20[])

src/FeeSplitter.sol#L351-L365


 - [ ] ID-102
[ClaimRouter._sweep(address,address[])](src/ClaimRouter.sol#L236-L253) has external calls inside a loop: [(okXfer,None) = token.call{gas: legGasLimit}(abi.encodeCall(IERC20.transfer,(to,before)))](src/ClaimRouter.sol#L244)
	Calls stack containing the loop:
		ClaimRouter.sweepTo(address,address[])

src/ClaimRouter.sol#L236-L253


 - [ ] ID-103
[ChipClaims._usdValue(address,uint256)](src/ChipClaims.sol#L633-L640) has external calls inside a loop: [(amount * price1e18) / (10 ** registry.getStock(token).tokenDecimals)](src/ChipClaims.sol#L636)
	Calls stack containing the loop:
		ChipClaims.claimMany(uint256[],address[])
		ChipClaims._claim(uint256,address,address)

src/ChipClaims.sol#L633-L640


 - [ ] ID-104
[Furnace.withdrawStock(address,uint256,address)](src/furnace/Furnace.sol#L517-L529) has external calls inside a loop: [IERC721(collection).transferFrom(address(this),to,tokenId)](src/furnace/Furnace.sol#L526)

src/furnace/Furnace.sol#L517-L529


 - [ ] ID-105
[FeeSplitter._payToken(IERC20,address,uint256)](src/FeeSplitter.sol#L368-L374) has external calls inside a loop: [before = token.balanceOf(address(this))](src/FeeSplitter.sol#L370)
	Calls stack containing the loop:
		FeeSplitter.distributeAll(IERC20[])
		FeeSplitter._splitToken(IERC20,uint256)

src/FeeSplitter.sol#L368-L374


 - [ ] ID-106
[FeeSplitter._payToken(IERC20,address,uint256)](src/FeeSplitter.sol#L368-L374) has external calls inside a loop: [before = token.balanceOf(address(this))](src/FeeSplitter.sol#L370)
	Calls stack containing the loop:
		FeeSplitter.distributeTokens(IERC20[])
		FeeSplitter._splitToken(IERC20,uint256)

src/FeeSplitter.sol#L368-L374


 - [ ] ID-107
[ChipClaims._usdValue(address,uint256)](src/ChipClaims.sol#L633-L640) has external calls inside a loop: [(price1e18) = registry.priceUsd(token)](src/ChipClaims.sol#L635-L639)
	Calls stack containing the loop:
		ChipClaims.claimMany(uint256[],address[])
		ChipClaims._claim(uint256,address,address)

src/ChipClaims.sol#L633-L640


 - [ ] ID-108
[ChipRounds.setSplit(address,uint256,address[],uint8[])](src/ChipRounds.sol#L514-L553) has external calls inside a loop: [! registry.isEnabled(stocks[i])](src/ChipRounds.sol#L527)

src/ChipRounds.sol#L514-L553


 - [ ] ID-109
[FeeSplitter.distributeTokens(IERC20[])](src/FeeSplitter.sol#L212-L221) has external calls inside a loop: [balance = token.balanceOf(address(this))](src/FeeSplitter.sol#L217)

src/FeeSplitter.sol#L212-L221


 - [ ] ID-110
[Furnace._consumeFuel(uint256)](src/furnace/Furnace.sol#L419-L430) has external calls inside a loop: [(ok,None) = address(fuelCollection).call{gas: FUEL_BURN_GAS}(abi.encodeWithSignature(burn(uint256),tokenId))](src/furnace/Furnace.sol#L420)
	Calls stack containing the loop:
		Furnace.forge(uint8,uint256[])
		Furnace._forge(uint8,uint256[],uint256,bool)

src/furnace/Furnace.sol#L419-L430


 - [ ] ID-111
[Furnace._fuelExists(uint256)](src/furnace/Furnace.sol#L433-L437) has external calls inside a loop: [(ok,ret) = address(fuelCollection).staticcall{gas: FUEL_BURN_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/furnace/Furnace.sol#L434-L435)
	Calls stack containing the loop:
		Furnace.forge(uint8,uint256[])
		Furnace._forge(uint8,uint256[],uint256,bool)
		Furnace._consumeFuel(uint256)

src/furnace/Furnace.sol#L433-L437


 - [ ] ID-112
[Furnace._forge(uint8,uint256[],uint256,bool)](src/furnace/Furnace.sol#L321-L384) has external calls inside a loop: [fuelCollection.ownerOf(fuelIds[i]) != msg.sender](src/furnace/Furnace.sol#L350)
	Calls stack containing the loop:
		Furnace.forge(uint8,uint256[],uint256)

src/furnace/Furnace.sol#L321-L384


 - [ ] ID-113
[StockRegistry.clearsMinLiquidity(address)](src/StockRegistry.sol#L266-L274) has external calls inside a loop: [measured = this.poolLiquidityUsd(token)](src/StockRegistry.sol#L269-L273)
	Calls stack containing the loop:
		StockRegistry.liquidityReport()

src/StockRegistry.sol#L266-L274


 - [ ] ID-114
[POLTreasury.collectAllFees()](src/POLTreasury.sol#L487-L494) has external calls inside a loop: [() = this.collectFees(positionIds[i])](src/POLTreasury.sol#L490-L492)

src/POLTreasury.sol#L487-L494


 - [ ] ID-115
[FeeSplitter._splitToken(IERC20,uint256)](src/FeeSplitter.sol#L351-L365) has external calls inside a loop: [remaining = token.balanceOf(address(this))](src/FeeSplitter.sol#L360)
	Calls stack containing the loop:
		FeeSplitter.distributeAll(IERC20[])

src/FeeSplitter.sol#L351-L365


 - [ ] ID-116
[Furnace._consumeFuel(uint256)](src/furnace/Furnace.sol#L419-L430) has external calls inside a loop: [fuelCollection.ownerOf(tokenId) != BURN_ADDRESS](src/furnace/Furnace.sol#L428)
	Calls stack containing the loop:
		Furnace.forge(uint8,uint256[])
		Furnace._forge(uint8,uint256[],uint256,bool)

src/furnace/Furnace.sol#L419-L430


 - [ ] ID-117
[Furnace._forge(uint8,uint256[],uint256,bool)](src/furnace/Furnace.sol#L321-L384) has external calls inside a loop: [fuelCollection.ownerOf(fuelIds[i]) != msg.sender](src/furnace/Furnace.sol#L350)
	Calls stack containing the loop:
		Furnace.forge(uint8,uint256[])

src/furnace/Furnace.sol#L321-L384


 - [ ] ID-118
[StockRegistry.liquidityReport()](src/StockRegistry.sol#L278-L298) has external calls inside a loop: [m = this.poolLiquidityUsd(t)](src/StockRegistry.sol#L291-L295)

src/StockRegistry.sol#L278-L298


 - [ ] ID-119
[FeeSplitter._payToken(IERC20,address,uint256)](src/FeeSplitter.sol#L368-L374) has external calls inside a loop: [remaining = token.balanceOf(address(this))](src/FeeSplitter.sol#L372)
	Calls stack containing the loop:
		FeeSplitter.distributeTokens(IERC20[])
		FeeSplitter._splitToken(IERC20,uint256)

src/FeeSplitter.sol#L368-L374


 - [ ] ID-120
[Anvil.unshelve(address,uint256,address)](src/anvil/Anvil.sol#L476-L510) has external calls inside a loop: [IERC721(collection).transferFrom(address(this),to,id)](src/anvil/Anvil.sol#L507)

src/anvil/Anvil.sol#L476-L510


 - [ ] ID-121
[ChipClaims._claim(uint256,address,address)](src/ChipClaims.sol#L273-L309) has external calls inside a loop: [(noted,None) = polTreasury.call{gas: PROBE_GAS}(abi.encodeWithSignature(notifyCompound(address,address,uint256,uint256),owner,stock,amount,usd))](src/ChipClaims.sol#L300-L302)
	Calls stack containing the loop:
		ChipClaims.claimMany(uint256[],address[])

src/ChipClaims.sol#L273-L309


## reentrancy-benign
Impact: Low
Confidence: Medium
 - [ ] ID-122
Reentrancy in [ChipRounds.settleStock(uint256,address)](src/ChipRounds.sol#L708-L783):
	External calls:
	- [(executed,received,quoteSpent,reason) = _buy(stock,spend)](src/ChipRounds.sol#L750)
		- [uniswapRouter.exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,fee:s.fee,recipient:address(this),amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L949-L963)
		- [slipstreamRouter.exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,tickSpacing:s.tickSpacing,recipient:address(this),deadline:block.timestamp,amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L965-L980)
	State variables written after the call(s):
	- [stockSkipped[roundId][stock] = true](src/ChipRounds.sol#L755)

src/ChipRounds.sol#L708-L783


 - [ ] ID-123
Reentrancy in [ChipRounds.settleStock(uint256,address)](src/ChipRounds.sol#L708-L783):
	External calls:
	- [(executed,received,quoteSpent,reason) = _buy(stock,spend)](src/ChipRounds.sol#L750)
		- [uniswapRouter.exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,fee:s.fee,recipient:address(this),amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L949-L963)
		- [slipstreamRouter.exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,tickSpacing:s.tickSpacing,recipient:address(this),deadline:block.timestamp,amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L965-L980)
	- [heldBack = _sendHoldback(stock,received)](src/ChipRounds.sol#L764)
		- [(ok,None) = stock.call(abi.encodeCall(IERC20.transfer,(treasury,target)))](src/ChipRounds.sol#L860)
	State variables written after the call(s):
	- [committedQuote -= quoteSpent](src/ChipRounds.sol#L767)

src/ChipRounds.sol#L708-L783


 - [ ] ID-124
Reentrancy in [Anvil.unshelve(address,uint256,address)](src/anvil/Anvil.sol#L476-L510):
	External calls:
	- [IERC721(collection).transferFrom(address(this),to,id)](src/anvil/Anvil.sol#L507)
	State variables written after the call(s):
	- [_slotOf[collection][id] = 0](src/anvil/Anvil.sol#L501)

src/anvil/Anvil.sol#L476-L510


 - [ ] ID-125
Reentrancy in [POLTreasury.mintPosition(INonfungiblePositionManager.MintParams)](src/POLTreasury.sol#L371-L396):
	External calls:
	- [(tokenId,liquidity,amount0,amount1) = positionManager.mint(p)](src/POLTreasury.sol#L389)
	State variables written after the call(s):
	- [_register(tokenId)](src/POLTreasury.sol#L394)
		- [holdsPosition[tokenId] = true](src/POLTreasury.sol#L677)
	- [_register(tokenId)](src/POLTreasury.sol#L394)
		- [positionIds.push(tokenId)](src/POLTreasury.sol#L678)

src/POLTreasury.sol#L371-L396


 - [ ] ID-126
Reentrancy in [Furnace._forge(uint8,uint256[],uint256,bool)](src/furnace/Furnace.sol#L321-L384):
	External calls:
	- [_consumeFuel(fuelIds[i_scope_0])](src/furnace/Furnace.sol#L363)
		- [(ok,None) = address(fuelCollection).call{gas: FUEL_BURN_GAS}(abi.encodeWithSignature(burn(uint256),tokenId))](src/furnace/Furnace.sol#L420)
		- [fuelCollection.transferFrom(msg.sender,BURN_ADDRESS,tokenId)](src/furnace/Furnace.sol#L427)
	State variables written after the call(s):
	- [totalFuelTrueBurned += trueBurned](src/furnace/Furnace.sol#L365)

src/furnace/Furnace.sol#L321-L384


 - [ ] ID-127
Reentrancy in [FeeSplitter._payEth(address,uint256)](src/FeeSplitter.sol#L323-L331):
	External calls:
	- [(ok,None) = address(to).call{gas: PAYOUT_GAS,value: amount}()](src/FeeSplitter.sol#L325)
	State variables written after the call(s):
	- [owedEth[to] += amount](src/FeeSplitter.sol#L328)
	- [totalOwedEth += amount](src/FeeSplitter.sol#L329)

src/FeeSplitter.sol#L323-L331


 - [ ] ID-128
Reentrancy in [ChipBurner.burnAll()](src/ChipBurner.sol#L114-L136):
	External calls:
	- [IChipOwnable(address(chipToken)).burn(balanceBefore)](src/ChipBurner.sol#L119)
	State variables written after the call(s):
	- [++ burnCount](src/ChipBurner.sol#L133)
	- [totalBurned += burned](src/ChipBurner.sol#L132)

src/ChipBurner.sol#L114-L136


 - [ ] ID-129
Reentrancy in [ChipRounds.openRound()](src/ChipRounds.sol#L573-L598):
	External calls:
	- [got = pot.pullBudget(availableInPot)](src/ChipRounds.sol#L582)
	State variables written after the call(s):
	- [_rounds[roundId] = Round({state:RoundState.Accumulating,openedAt:uint64(block.timestamp),finalizedAt:0,budget:uint128(got),spent:0,totalWeight:0})](src/ChipRounds.sol#L586-L593)
	- [committedQuote += got](src/ChipRounds.sol#L595)
	- [roundId = ++ roundCount](src/ChipRounds.sol#L585)

src/ChipRounds.sol#L573-L598


 - [ ] ID-130
Reentrancy in [ChipRounds.finalizeRound(uint256)](src/ChipRounds.sol#L998-L1024):
	External calls:
	- [pot.noteReturned(unspent)](src/ChipRounds.sol#L1014)
	- [claims.freezeSchedule(roundId)](src/ChipRounds.sol#L1018)
	State variables written after the call(s):
	- [totalPaidUsd += valueUsd](src/ChipRounds.sol#L1021)

src/ChipRounds.sol#L998-L1024


## reentrancy-events
Impact: Low
Confidence: Medium
 - [ ] ID-131
Reentrancy in [ChipBurner.updateTokenUri(string)](src/ChipBurner.sol#L150-L153):
	External calls:
	- [_passThrough(abi.encodeWithSignature(updateTokenURI(string),uri))](src/ChipBurner.sol#L151)
		- [(ok,ret) = address(chipToken).call(data)](src/ChipBurner.sol#L178)
	Event emitted after the call(s):
	- [TokenUriUpdated(uri)](src/ChipBurner.sol#L152)

src/ChipBurner.sol#L150-L153


 - [ ] ID-132
Reentrancy in [ConversionRoutes._convert(address,uint256)](src/base/ConversionRoutes.sol#L216-L257):
	External calls:
	- [IWETH(weth).deposit{value: amountIn - wethBalance}()](src/base/ConversionRoutes.sol#L232)
	- [IUniswapV3SwapRouter(r.router).exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:token,tokenOut:quoteToken,fee:r.fee,recipient:address(this),amountIn:amountIn,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/base/ConversionRoutes.sol#L238-L249)
	External calls sending eth:
	- [IWETH(weth).deposit{value: amountIn - wethBalance}()](src/base/ConversionRoutes.sol#L232)
	Event emitted after the call(s):
	- [Converted(token,amountIn,quoteOut,minOut,msg.sender)](src/base/ConversionRoutes.sol#L256)

src/base/ConversionRoutes.sol#L216-L257


 - [ ] ID-133
Reentrancy in [ChipBurner.transferTokenOwnership(address)](src/ChipBurner.sol#L165-L169):
	External calls:
	- [_passThrough(abi.encodeWithSignature(transferOwnership(address),newOwner))](src/ChipBurner.sol#L167)
		- [(ok,ret) = address(chipToken).call(data)](src/ChipBurner.sol#L178)
	Event emitted after the call(s):
	- [TokenOwnershipTransferred(newOwner)](src/ChipBurner.sol#L168)

src/ChipBurner.sol#L165-L169


 - [ ] ID-134
Reentrancy in [Pot.sweepEth(address)](src/Pot.sol#L221-L227):
	External calls:
	- [Address.sendValue(address(to),amount)](src/Pot.sol#L225)
	Event emitted after the call(s):
	- [EthSwept(to,amount)](src/Pot.sol#L226)

src/Pot.sol#L221-L227


## return-bomb
Impact: Low
Confidence: Medium
 - [ ] ID-135
[Furnace._consumeFuel(uint256)](src/furnace/Furnace.sol#L419-L430) tries to limit the gas of an external call that controls implicit decoding
	[(ok,None) = address(fuelCollection).call{gas: FUEL_BURN_GAS}(abi.encodeWithSignature(burn(uint256),tokenId))](src/furnace/Furnace.sol#L420)

src/furnace/Furnace.sol#L419-L430


 - [ ] ID-136
[ClaimRouter._balanceOfSelf(address)](src/ClaimRouter.sol#L258-L263) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = token.staticcall{gas: legGasLimit}(abi.encodeCall(IERC20.balanceOf,(address(this))))](src/ClaimRouter.sol#L259-L260)

src/ClaimRouter.sol#L258-L263


 - [ ] ID-137
[ClutchVaultAdapter.activation(address,uint256)](src/adapters/ClutchVaultAdapter.sol#L99-L134) tries to limit the gas of an external call that controls implicit decoding
	[(okActive,activeRet) = vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.isActive,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L108-L109)
	[(okOwner,ownerRet) = vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.ownerOfRecord,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L114-L115)
	[(okTier,tierRet) = vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.tierOf,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L120-L121)

src/adapters/ClutchVaultAdapter.sol#L99-L134


 - [ ] ID-138
[ChipActivation._tokenExists(address,uint256)](src/activation/ChipActivation.sol#L385-L389) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = collection.staticcall{gas: TOKEN_BURN_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/activation/ChipActivation.sol#L386-L387)

src/activation/ChipActivation.sol#L385-L389


 - [ ] ID-139
[ChipActivation._consumeToken(address,uint256)](src/activation/ChipActivation.sol#L376-L383) tries to limit the gas of an external call that controls implicit decoding
	[(ok,None) = collection.call{gas: TOKEN_BURN_GAS}(abi.encodeWithSignature(burn(uint256),tokenId))](src/activation/ChipActivation.sol#L377)

src/activation/ChipActivation.sol#L376-L383


 - [ ] ID-140
[ClaimRouter._sweep(address,address[])](src/ClaimRouter.sol#L236-L253) tries to limit the gas of an external call that controls implicit decoding
	[(okXfer,None) = token.call{gas: legGasLimit}(abi.encodeCall(IERC20.transfer,(to,before)))](src/ClaimRouter.sol#L244)

src/ClaimRouter.sol#L236-L253


 - [ ] ID-141
[ClaimRouter._claimChip(address,ClaimRouter.ChipClaim)](src/ClaimRouter.sol#L210-L215) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = address(rewards).call{gas: legGasLimit}(abi.encodeCall(IChipRewardsClaimable.claimFor,(owner,c.roundId,c.stock)))](src/ClaimRouter.sol#L211-L213)

src/ClaimRouter.sol#L210-L215


 - [ ] ID-142
[ChipRounds._balanceOf(address,address)](src/ChipRounds.sol#L1108-L1112) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC20.balanceOf,(who)))](src/ChipRounds.sol#L1109)

src/ChipRounds.sol#L1108-L1112


 - [ ] ID-143
[ChipClaims._balanceOf(address,address)](src/ChipClaims.sol#L643-L647) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC20.balanceOf,(who)))](src/ChipClaims.sol#L644)

src/ChipClaims.sol#L643-L647


 - [ ] ID-144
[Furnace._fuelExists(uint256)](src/furnace/Furnace.sol#L433-L437) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = address(fuelCollection).staticcall{gas: FUEL_BURN_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/furnace/Furnace.sol#L434-L435)

src/furnace/Furnace.sol#L433-L437


 - [ ] ID-145
[ClutchVaultAdapter.effectiveOwner(address,uint256)](src/adapters/ClutchVaultAdapter.sol#L141-L146) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = collection.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L142-L143)

src/adapters/ClutchVaultAdapter.sol#L141-L146


 - [ ] ID-146
[ChipRounds._maxSpendFor(address)](src/ChipRounds.sol#L907-L917) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = address(registry).staticcall{gas: DEPTH_PROBE_GAS}(abi.encodeCall(IStockRegistry.poolLiquidityUsd,(stock)))](src/ChipRounds.sol#L908-L909)

src/ChipRounds.sol#L907-L917


 - [ ] ID-147
[ClutchVaultAdapter._stillHeldBy(address,uint256,address)](src/adapters/ClutchVaultAdapter.sol#L149-L154) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = collection.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L150-L151)

src/adapters/ClutchVaultAdapter.sol#L149-L154


 - [ ] ID-148
[StockRegistry._checkedDecimals(address,uint8)](src/StockRegistry.sol#L359-L371) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = token.staticcall{gas: DECIMALS_PROBE_GAS}(abi.encodeWithSelector(IERC20Metadata.decimals.selector))](src/StockRegistry.sol#L360-L361)

src/StockRegistry.sol#L359-L371


 - [ ] ID-149
[ChipActivation._effectiveOwner(address,uint256)](src/activation/ChipActivation.sol#L535-L547) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = collection.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/activation/ChipActivation.sol#L536)
	[(okB,retB) = holder.staticcall{gas: PROBE_GAS}(abi.encodeCall(IActivationCustodian.beneficiaryOf,(collection,tokenId)))](src/activation/ChipActivation.sol#L543-L544)

src/activation/ChipActivation.sol#L535-L547


 - [ ] ID-150
[ChipClaims._claim(uint256,address,address)](src/ChipClaims.sol#L273-L309) tries to limit the gas of an external call that controls implicit decoding
	[(noted,None) = polTreasury.call{gas: PROBE_GAS}(abi.encodeWithSignature(notifyCompound(address,address,uint256,uint256),owner,stock,amount,usd))](src/ChipClaims.sol#L300-L302)

src/ChipClaims.sol#L273-L309


## timestamp
Impact: Low
Confidence: Medium
 - [ ] ID-151
[Furnace.executeRecipeChange(uint8)](src/furnace/Furnace.sol#L614-L624) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < p.executableAt](src/furnace/Furnace.sol#L617)

src/furnace/Furnace.sol#L614-L624


 - [ ] ID-152
[NounLoans.executeTerms()](src/loans/NounLoans.sol#L690-L698) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < p.executableAt](src/loans/NounLoans.sol#L693)

src/loans/NounLoans.sol#L690-L698


 - [ ] ID-153
[ChipRounds.openRound()](src/ChipRounds.sol#L573-L598) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < openableAt](src/ChipRounds.sol#L575)

src/ChipRounds.sol#L573-L598


 - [ ] ID-154
[ChipRounds.cancelRound(uint256)](src/ChipRounds.sol#L1031-L1047) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < abandonedAt](src/ChipRounds.sol#L1035)
	- [budget != 0](src/ChipRounds.sol#L1041)

src/ChipRounds.sol#L1031-L1047


 - [ ] ID-155
[NounLoans._lateFeeOn(NounLoans.Loan)](src/loans/NounLoans.sol#L407-L410) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp <= l.dueAt + l.gracePeriod](src/loans/NounLoans.sol#L408)

src/loans/NounLoans.sol#L407-L410


 - [ ] ID-156
[ChipClaims.sweepExpired(uint256,address,uint256)](src/ChipClaims.sol#L330-L375) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp <= s.expiresAt](src/ChipClaims.sol#L337)

src/ChipClaims.sol#L330-L375


 - [ ] ID-157
[Anvil._requireInWindow(uint64)](src/anvil/Anvil.sol#L557-L561) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < executableAt](src/anvil/Anvil.sol#L558)
	- [block.timestamp > expiresAt](src/anvil/Anvil.sol#L560)

src/anvil/Anvil.sol#L557-L561


 - [ ] ID-158
[ChipClaims.executePolTreasury()](src/ChipClaims.sol#L557-L564) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < p.executableAt](src/ChipClaims.sol#L560)

src/ChipClaims.sol#L557-L564


 - [ ] ID-159
[ChipRounds.nextRoundOpensAt()](src/ChipRounds.sol#L568-L570) uses timestamp for comparisons
	Dangerous comparisons:
	- [lastRoundOpenedAt == 0](src/ChipRounds.sol#L569)

src/ChipRounds.sol#L568-L570


 - [ ] ID-160
[ChipClaims._windowStateAt(uint64,uint32,uint32)](src/ChipClaims.sol#L466-L481) uses timestamp for comparisons
	Dangerous comparisons:
	- [ts < windowAnchor](src/ChipClaims.sol#L472)
	- [into < d || d >= w](src/ChipClaims.sol#L478)

src/ChipClaims.sol#L466-L481


 - [ ] ID-161
[ConversionRoutes._readFeed(address,uint64)](src/base/ConversionRoutes.sol#L199-L208) uses timestamp for comparisons
	Dangerous comparisons:
	- [maxAge != 0 && block.timestamp > updatedAt + maxAge](src/base/ConversionRoutes.sol#L204)

src/base/ConversionRoutes.sol#L199-L208


 - [ ] ID-162
[Furnace.executeStockSkip(address)](src/furnace/Furnace.sol#L564-L577) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < p.executableAt](src/furnace/Furnace.sol#L567)

src/furnace/Furnace.sol#L564-L577


 - [ ] ID-163
[ChipActivation.executeCosts(address)](src/activation/ChipActivation.sol#L671-L681) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < p.executableAt](src/activation/ChipActivation.sol#L674)

src/activation/ChipActivation.sol#L671-L681


 - [ ] ID-164
[ChipClaims.windowsRemaining(uint256)](src/ChipClaims.sol#L422-L427) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp >= s.expiresAt](src/ChipClaims.sol#L425)

src/ChipClaims.sol#L422-L427


 - [ ] ID-165
[ConversionRoutes._requireSequencerUp()](src/base/ConversionRoutes.sol#L268-L279) uses timestamp for comparisons
	Dangerous comparisons:
	- [grace != 0 && block.timestamp < startedAt + grace](src/base/ConversionRoutes.sol#L276)

src/base/ConversionRoutes.sol#L268-L279


 - [ ] ID-166
[NounLoans.liquidate(uint256)](src/loans/NounLoans.sol#L426-L459) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp <= liquidatableAt](src/loans/NounLoans.sol#L431)

src/loans/NounLoans.sol#L426-L459


 - [ ] ID-167
[ChipRounds.isFeedStale(address)](src/ChipRounds.sol#L870-L881) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp > updatedAt + maxAge](src/ChipRounds.sol#L875)

src/ChipRounds.sol#L870-L881


 - [ ] ID-168
[ChipRounds.finalizeRound(uint256)](src/ChipRounds.sol#L998-L1024) uses timestamp for comparisons
	Dangerous comparisons:
	- [unspent != 0](src/ChipRounds.sol#L1011)

src/ChipRounds.sol#L998-L1024


 - [ ] ID-169
[ChipClaims._claim(uint256,address,address)](src/ChipClaims.sol#L273-L309) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp > s.expiresAt](src/ChipClaims.sol#L276)

src/ChipClaims.sol#L273-L309


 - [ ] ID-170
[NounLoans._loanAt(uint256)](src/loans/NounLoans.sol#L570-L573) uses timestamp for comparisons
	Dangerous comparisons:
	- [loanId >= _loans.length](src/loans/NounLoans.sol#L571)

src/loans/NounLoans.sol#L570-L573


 - [ ] ID-171
[ChipClaims._openingsIn(uint64,uint64,uint32)](src/ChipClaims.sol#L451-L457) uses timestamp for comparisons
	Dangerous comparisons:
	- [to <= from || w == 0](src/ChipClaims.sol#L452)
	- [to <= anchor](src/ChipClaims.sol#L454)
	- [from <= anchor](src/ChipClaims.sol#L455)
	- [toIdx > fromIdx](src/ChipClaims.sol#L456)

src/ChipClaims.sol#L451-L457


 - [ ] ID-172
[ChipClaims._isOpenAt(uint64,uint32,uint32)](src/ChipClaims.sol#L459-L464) uses timestamp for comparisons
	Dangerous comparisons:
	- [ts < windowAnchor](src/ChipClaims.sol#L461)
	- [(uint256(ts - windowAnchor) % w) < d](src/ChipClaims.sol#L463)

src/ChipClaims.sol#L459-L464


 - [ ] ID-173
[ChipRounds.closeAccumulation(uint256)](src/ChipRounds.sol#L680-L689) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < closesAt](src/ChipRounds.sol#L684)

src/ChipRounds.sol#L680-L689


 - [ ] ID-174
[ChipClaims.executeRounds()](src/ChipClaims.sol#L519-L526) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < p.executableAt](src/ChipClaims.sol#L522)

src/ChipClaims.sol#L519-L526


 - [ ] ID-175
[ChipClaims.isFinalized(uint256)](src/ChipClaims.sol#L394-L396) uses timestamp for comparisons
	Dangerous comparisons:
	- [_schedules[roundId].finalizedAt != 0](src/ChipClaims.sol#L395)

src/ChipClaims.sol#L394-L396


 - [ ] ID-176
[NounLoans.isLiquidatable(uint256)](src/loans/NounLoans.sol#L559-L562) uses timestamp for comparisons
	Dangerous comparisons:
	- [! l.closed && block.timestamp > l.dueAt + l.gracePeriod](src/loans/NounLoans.sol#L561)

src/loans/NounLoans.sol#L559-L562


 - [ ] ID-177
[ChipActivation.isActive(address,uint256)](src/activation/ChipActivation.sol#L560-L564) uses timestamp for comparisons
	Dangerous comparisons:
	- [recorded == address(0)](src/activation/ChipActivation.sol#L562)
	- [_effectiveOwner(collection,tokenId) == recorded](src/activation/ChipActivation.sol#L563)

src/activation/ChipActivation.sol#L560-L564


 - [ ] ID-178
[ChipActivation.executeTierBps()](src/activation/ChipActivation.sol#L703-L712) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < p.executableAt](src/activation/ChipActivation.sol#L706)

src/activation/ChipActivation.sol#L703-L712


## assembly
Impact: Informational
Confidence: High
 - [ ] ID-179
[POLTreasury._poolQuotePerAsset(address,address,uint8)](src/POLTreasury.sol#L740-L760) uses assembly
	- [INLINE ASM](src/POLTreasury.sol#L746-L748)

src/POLTreasury.sol#L740-L760


## pragma
Impact: Informational
Confidence: High
 - [ ] ID-180
2 different versions of Solidity are used:
	- Version constraint ^0.8.20 is used by:
		-[^0.8.20](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Address.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Context.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Errors.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Panic.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol#L3-L5)
	- Version constraint ^0.8.24 is used by:
		-[^0.8.24](src/ChipBurner.sol#L2)
		-[^0.8.24](src/ChipClaims.sol#L2)
		-[^0.8.24](src/ChipRounds.sol#L2)
		-[^0.8.24](src/ClaimRouter.sol#L2)
		-[^0.8.24](src/FeeSplitter.sol#L2)
		-[^0.8.24](src/POLTreasury.sol#L2)
		-[^0.8.24](src/Pot.sol#L2)
		-[^0.8.24](src/StockRegistry.sol#L2)
		-[^0.8.24](src/activation/ChipActivation.sol#L2)
		-[^0.8.24](src/adapters/ClutchVaultAdapter.sol#L2)
		-[^0.8.24](src/anvil/Anvil.sol#L2)
		-[^0.8.24](src/base/ConversionRoutes.sol#L2)
		-[^0.8.24](src/furnace/Furnace.sol#L2)
		-[^0.8.24](src/interfaces/IActivationCustodian.sol#L2)
		-[^0.8.24](src/interfaces/IActivationSource.sol#L2)
		-[^0.8.24](src/interfaces/IAggregatorV3.sol#L2)
		-[^0.8.24](src/interfaces/IAmmFactories.sol#L2)
		-[^0.8.24](src/interfaces/IChipClaims.sol#L2)
		-[^0.8.24](src/interfaces/IChipRewardsClaimable.sol#L2)
		-[^0.8.24](src/interfaces/IChipRounds.sol#L2)
		-[^0.8.24](src/interfaces/IClutchVaultRegistry.sol#L2)
		-[^0.8.24](src/interfaces/INonfungiblePositionManager.sol#L2)
		-[^0.8.24](src/interfaces/IPot.sol#L2)
		-[^0.8.24](src/interfaces/ISoftStakingVault.sol#L2)
		-[^0.8.24](src/interfaces/IStockRegistry.sol#L2)
		-[^0.8.24](src/interfaces/ISwapRouters.sol#L2)
		-[^0.8.24](src/interfaces/IWETH.sol#L2)
		-[^0.8.24](src/loans/NounLoans.sol#L2)

lib/openzeppelin-contracts/contracts/access/Ownable.sol#L2-L4


## costly-loop
Impact: Informational
Confidence: Medium
 - [ ] ID-181
[POLTreasury.prunePosition(uint256)](src/POLTreasury.sol#L517-L532) has costly operations inside a loop:
	- [positionIds.pop()](src/POLTreasury.sol#L527)

src/POLTreasury.sol#L517-L532


## cyclomatic-complexity
Impact: Informational
Confidence: High
 - [ ] ID-182
[NounLoans.borrow(address,uint256,uint8,uint256)](src/loans/NounLoans.sol#L270-L342) has a high cyclomatic complexity (12).

src/loans/NounLoans.sol#L270-L342


 - [ ] ID-183
[Furnace._forge(uint8,uint256[],uint256,bool)](src/furnace/Furnace.sol#L321-L384) has a high cyclomatic complexity (14).

src/furnace/Furnace.sol#L321-L384


## low-level-calls
Impact: Informational
Confidence: High
 - [ ] ID-184
Low level call in [ChipActivation._effectiveOwner(address,uint256)](src/activation/ChipActivation.sol#L535-L547):
	- [(ok,ret) = collection.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/activation/ChipActivation.sol#L536)
	- [(okB,retB) = holder.staticcall{gas: PROBE_GAS}(abi.encodeCall(IActivationCustodian.beneficiaryOf,(collection,tokenId)))](src/activation/ChipActivation.sol#L543-L544)

src/activation/ChipActivation.sol#L535-L547


 - [ ] ID-185
Low level call in [StockRegistry._checkedDecimals(address,uint8)](src/StockRegistry.sol#L359-L371):
	- [(ok,ret) = token.staticcall{gas: DECIMALS_PROBE_GAS}(abi.encodeWithSelector(IERC20Metadata.decimals.selector))](src/StockRegistry.sol#L360-L361)

src/StockRegistry.sol#L359-L371


 - [ ] ID-186
Low level call in [ChipRounds._sendHoldback(address,uint256)](src/ChipRounds.sol#L851-L865):
	- [(ok,None) = stock.call(abi.encodeCall(IERC20.transfer,(treasury,target)))](src/ChipRounds.sol#L860)

src/ChipRounds.sol#L851-L865


 - [ ] ID-187
Low level call in [ConversionRoutes._requireInBand(address,int256)](src/base/ConversionRoutes.sol#L294-L311):
	- [(okAgg,aggRet) = feed.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature(aggregator()))](src/base/ConversionRoutes.sol#L295)
	- [(okMin,minRet) = agg.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature(minAnswer()))](src/base/ConversionRoutes.sol#L300)
	- [(okMax,maxRet) = agg.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature(maxAnswer()))](src/base/ConversionRoutes.sol#L306)

src/base/ConversionRoutes.sol#L294-L311


 - [ ] ID-188
Low level call in [Furnace._consumeFuel(uint256)](src/furnace/Furnace.sol#L419-L430):
	- [(ok,None) = address(fuelCollection).call{gas: FUEL_BURN_GAS}(abi.encodeWithSignature(burn(uint256),tokenId))](src/furnace/Furnace.sol#L420)

src/furnace/Furnace.sol#L419-L430


 - [ ] ID-189
Low level call in [ChipBurner._passThrough(bytes)](src/ChipBurner.sol#L177-L180):
	- [(ok,ret) = address(chipToken).call(data)](src/ChipBurner.sol#L178)

src/ChipBurner.sol#L177-L180


 - [ ] ID-190
Low level call in [ChipClaims._balanceOf(address,address)](src/ChipClaims.sol#L643-L647):
	- [(ok,ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC20.balanceOf,(who)))](src/ChipClaims.sol#L644)

src/ChipClaims.sol#L643-L647


 - [ ] ID-191
Low level call in [ClaimRouter._balanceOfSelf(address)](src/ClaimRouter.sol#L258-L263):
	- [(ok,ret) = token.staticcall{gas: legGasLimit}(abi.encodeCall(IERC20.balanceOf,(address(this))))](src/ClaimRouter.sol#L259-L260)

src/ClaimRouter.sol#L258-L263


 - [ ] ID-192
Low level call in [Anvil._settle(address,uint256,uint256,bool)](src/anvil/Anvil.sol#L259-L284):
	- [(ok,None) = feeSplitter.call{value: price}()](src/anvil/Anvil.sol#L267)
	- [(refunded,None) = msg.sender.call{value: excess}()](src/anvil/Anvil.sol#L272)

src/anvil/Anvil.sol#L259-L284


 - [ ] ID-193
Low level call in [ClutchVaultAdapter._stillHeldBy(address,uint256,address)](src/adapters/ClutchVaultAdapter.sol#L149-L154):
	- [(ok,ret) = collection.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L150-L151)

src/adapters/ClutchVaultAdapter.sol#L149-L154


 - [ ] ID-194
Low level call in [POLTreasury._poolQuotePerAsset(address,address,uint8)](src/POLTreasury.sol#L740-L760):
	- [(ok,ret) = pool.staticcall(abi.encodeWithSignature(slot0()))](src/POLTreasury.sol#L741)

src/POLTreasury.sol#L740-L760


 - [ ] ID-195
Low level call in [ClaimRouter._sweep(address,address[])](src/ClaimRouter.sol#L236-L253):
	- [(okXfer,None) = token.call{gas: legGasLimit}(abi.encodeCall(IERC20.transfer,(to,before)))](src/ClaimRouter.sol#L244)

src/ClaimRouter.sol#L236-L253


 - [ ] ID-196
Low level call in [ChipRounds._maxSpendFor(address)](src/ChipRounds.sol#L907-L917):
	- [(ok,ret) = address(registry).staticcall{gas: DEPTH_PROBE_GAS}(abi.encodeCall(IStockRegistry.poolLiquidityUsd,(stock)))](src/ChipRounds.sol#L908-L909)

src/ChipRounds.sol#L907-L917


 - [ ] ID-197
Low level call in [ChipActivation._tokenExists(address,uint256)](src/activation/ChipActivation.sol#L385-L389):
	- [(ok,ret) = collection.staticcall{gas: TOKEN_BURN_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/activation/ChipActivation.sol#L386-L387)

src/activation/ChipActivation.sol#L385-L389


 - [ ] ID-198
Low level call in [ClutchVaultAdapter.activation(address,uint256)](src/adapters/ClutchVaultAdapter.sol#L99-L134):
	- [(okActive,activeRet) = vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.isActive,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L108-L109)
	- [(okOwner,ownerRet) = vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.ownerOfRecord,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L114-L115)
	- [(okTier,tierRet) = vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.tierOf,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L120-L121)

src/adapters/ClutchVaultAdapter.sol#L99-L134


 - [ ] ID-199
Low level call in [FeeSplitter._payEth(address,uint256)](src/FeeSplitter.sol#L323-L331):
	- [(ok,None) = address(to).call{gas: PAYOUT_GAS,value: amount}()](src/FeeSplitter.sol#L325)

src/FeeSplitter.sol#L323-L331


 - [ ] ID-200
Low level call in [ChipClaims._claim(uint256,address,address)](src/ChipClaims.sol#L273-L309):
	- [(noted,None) = polTreasury.call{gas: PROBE_GAS}(abi.encodeWithSignature(notifyCompound(address,address,uint256,uint256),owner,stock,amount,usd))](src/ChipClaims.sol#L300-L302)

src/ChipClaims.sol#L273-L309


 - [ ] ID-201
Low level call in [ClutchVaultAdapter.effectiveOwner(address,uint256)](src/adapters/ClutchVaultAdapter.sol#L141-L146):
	- [(ok,ret) = collection.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L142-L143)

src/adapters/ClutchVaultAdapter.sol#L141-L146


 - [ ] ID-202
Low level call in [ChipRounds._requireRouterOnFactory(address,address)](src/ChipRounds.sol#L374-L385):
	- [(ok,ret) = router.staticcall(abi.encodeWithSignature(factory()))](src/ChipRounds.sol#L378)

src/ChipRounds.sol#L374-L385


 - [ ] ID-203
Low level call in [ClaimRouter._claimChip(address,ClaimRouter.ChipClaim)](src/ClaimRouter.sol#L210-L215):
	- [(ok,ret) = address(rewards).call{gas: legGasLimit}(abi.encodeCall(IChipRewardsClaimable.claimFor,(owner,c.roundId,c.stock)))](src/ClaimRouter.sol#L211-L213)

src/ClaimRouter.sol#L210-L215


 - [ ] ID-204
Low level call in [ConversionRoutes._probeDecimals(address)](src/base/ConversionRoutes.sol#L389-L395):
	- [(ok,ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature(decimals()))](src/base/ConversionRoutes.sol#L390)

src/base/ConversionRoutes.sol#L389-L395


 - [ ] ID-205
Low level call in [ChipRounds._deliver(uint256,address,uint256)](src/ChipRounds.sol#L818-L843):
	- [(ok,None) = stock.call(abi.encodeCall(IERC20.transfer,(address(claims),amount)))](src/ChipRounds.sol#L822)

src/ChipRounds.sol#L818-L843


 - [ ] ID-206
Low level call in [Furnace._fuelExists(uint256)](src/furnace/Furnace.sol#L433-L437):
	- [(ok,ret) = address(fuelCollection).staticcall{gas: FUEL_BURN_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/furnace/Furnace.sol#L434-L435)

src/furnace/Furnace.sol#L433-L437


 - [ ] ID-207
Low level call in [ChipRounds._balanceOf(address,address)](src/ChipRounds.sol#L1108-L1112):
	- [(ok,ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC20.balanceOf,(who)))](src/ChipRounds.sol#L1109)

src/ChipRounds.sol#L1108-L1112


 - [ ] ID-208
Low level call in [ConversionRoutes._requireUniswapV3Router(address)](src/base/ConversionRoutes.sol#L379-L384):
	- [(ok,ret) = router.staticcall(abi.encodeWithSignature(factory()))](src/base/ConversionRoutes.sol#L381)

src/base/ConversionRoutes.sol#L379-L384


 - [ ] ID-209
Low level call in [ChipActivation._consumeToken(address,uint256)](src/activation/ChipActivation.sol#L376-L383):
	- [(ok,None) = collection.call{gas: TOKEN_BURN_GAS}(abi.encodeWithSignature(burn(uint256),tokenId))](src/activation/ChipActivation.sol#L377)

src/activation/ChipActivation.sol#L376-L383


## redundant-statements
Impact: Informational
Confidence: High
 - [ ] ID-210
Redundant expression "[noted](src/ChipClaims.sol#L303)" in[ChipClaims](src/ChipClaims.sol#L39-L648)

src/ChipClaims.sol#L303


## var-read-using-this
Impact: Optimization
Confidence: High
 - [ ] ID-211
The function [StockRegistry.liquidityReport()](src/StockRegistry.sol#L278-L298) reads [m = this.poolLiquidityUsd(t)](src/StockRegistry.sol#L291-L295) with `this` which adds an extra STATICCALL.

src/StockRegistry.sol#L278-L298


 - [ ] ID-212
The function [StockRegistry.clearsMinLiquidity(address)](src/StockRegistry.sol#L266-L274) reads [measured = this.poolLiquidityUsd(token)](src/StockRegistry.sol#L269-L273) with `this` which adds an extra STATICCALL.

src/StockRegistry.sol#L266-L274


