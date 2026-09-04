'forge clean' running (wd: C:\Users\1136962520\chipworks-contracts)
'forge config --json' running
'forge build --build-info --deny never --skip ./test/** ./script/** --force' running (wd: C:\Users\1136962520\chipworks-contracts)
**THIS CHECKLIST IS NOT COMPLETE**. Use `--show-ignored-findings` to show all the results.
Summary
 - [weak-prng](#weak-prng) (2 results) (High)
 - [reentrancy-balance](#reentrancy-balance) (3 results) (High)
 - [divide-before-multiply](#divide-before-multiply) (4 results) (Medium)
 - [erc20-interface](#erc20-interface) (1 results) (Medium)
 - [incorrect-equality](#incorrect-equality) (10 results) (Medium)
 - [reentrancy-no-eth](#reentrancy-no-eth) (6 results) (Medium)
 - [uninitialized-local](#uninitialized-local) (13 results) (Medium)
 - [unused-return](#unused-return) (14 results) (Medium)
 - [shadowing-local](#shadowing-local) (15 results) (Low)
 - [missing-zero-check](#missing-zero-check) (6 results) (Low)
 - [calls-loop](#calls-loop) (28 results) (Low)
 - [reentrancy-benign](#reentrancy-benign) (5 results) (Low)
 - [reentrancy-events](#reentrancy-events) (3 results) (Low)
 - [return-bomb](#return-bomb) (11 results) (Low)
 - [timestamp](#timestamp) (25 results) (Low)
 - [pragma](#pragma) (1 results) (Informational)
 - [cyclomatic-complexity](#cyclomatic-complexity) (2 results) (Informational)
 - [low-level-calls](#low-level-calls) (15 results) (Informational)
 - [missing-inheritance](#missing-inheritance) (1 results) (Informational)
 - [redundant-statements](#redundant-statements) (1 results) (Informational)
 - [var-read-using-this](#var-read-using-this) (2 results) (Optimization)
## weak-prng
Impact: High
Confidence: Medium
 - [ ] ID-0
[ChipClaims._isOpenAt(uint64,uint32,uint32)](src/ChipClaims.sol#L439-L444) uses a weak PRNG: "[(uint256(ts - windowAnchor) % w) < d](src/ChipClaims.sol#L443)" 

src/ChipClaims.sol#L439-L444


 - [ ] ID-1
[ChipClaims._windowStateAt(uint64,uint32,uint32)](src/ChipClaims.sol#L446-L461) uses a weak PRNG: "[into = elapsed % w](src/ChipClaims.sol#L455)" 

src/ChipClaims.sol#L446-L461


## reentrancy-balance
Impact: High
Confidence: Medium
 - [ ] ID-2
Reentrancy in [ConversionRoutes._convert(address)](src/base/ConversionRoutes.sol#L146-L183):
	External call allowing reentrancy:
	- [IWETH(weth).deposit{value: amountIn - wethBalance}()](src/base/ConversionRoutes.sol#L158)
	Balance read before the call:
	- [amountIn = nextConversionAmount(token)](src/base/ConversionRoutes.sol#L149)
	Possible stale balance used after the call in a condition:
	- [quoteOut < minOut](src/base/ConversionRoutes.sol#L180)
		- stale variable `minOut`

src/base/ConversionRoutes.sol#L146-L183


 - [ ] ID-3
Reentrancy in [ConversionRoutes._convert(address)](src/base/ConversionRoutes.sol#L146-L183):
	External call allowing reentrancy:
	- [IUniswapV3SwapRouter(r.router).exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:token,tokenOut:quoteToken,fee:r.fee,recipient:address(this),amountIn:amountIn,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/base/ConversionRoutes.sol#L164-L175)
	Balance read before the call:
	- [amountIn = nextConversionAmount(token)](src/base/ConversionRoutes.sol#L149)
	Possible stale balance used after the call in a condition:
	- [quoteOut < minOut](src/base/ConversionRoutes.sol#L180)
		- stale variable `minOut`

src/base/ConversionRoutes.sol#L146-L183


 - [ ] ID-4
Reentrancy in [ConversionRoutes._convert(address)](src/base/ConversionRoutes.sol#L146-L183):
	External call allowing reentrancy:
	- [IUniswapV3SwapRouter(r.router).exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:token,tokenOut:quoteToken,fee:r.fee,recipient:address(this),amountIn:amountIn,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/base/ConversionRoutes.sol#L164-L175)
	Balance read before the call:
	- [before = IERC20(quoteToken).balanceOf(address(this))](src/base/ConversionRoutes.sol#L161)
	Possible stale balance used after the call in a condition:
	- [quoteOut < minOut](src/base/ConversionRoutes.sol#L180)
		- stale variable `quoteOut`

src/base/ConversionRoutes.sol#L146-L183


## divide-before-multiply
Impact: Medium
Confidence: Medium
 - [ ] ID-5
[ChipRounds._minOutFor(address,uint256)](src/ChipRounds.sol#L628-L640) performs a multiplication on the result of a division:
	- [spendUsd = (spendAmount * 1e18) / (10 ** registry.quoteDecimals())](src/ChipRounds.sol#L637)
	- [expectedOut = (spendUsd * (10 ** dec)) / price1e18](src/ChipRounds.sol#L638)

src/ChipRounds.sol#L628-L640


 - [ ] ID-6
[ChipRounds._minOutFor(address,uint256)](src/ChipRounds.sol#L628-L640) performs a multiplication on the result of a division:
	- [expectedOut = (spendUsd * (10 ** dec)) / price1e18](src/ChipRounds.sol#L638)
	- [(expectedOut * (BPS - maxSlippageBps(stock))) / BPS](src/ChipRounds.sol#L639)

src/ChipRounds.sol#L628-L640


 - [ ] ID-7
[ConversionRoutes.minOutFor(address,uint256)](src/base/ConversionRoutes.sol#L126-L140) performs a multiplication on the result of a division:
	- [gross = (amount * uint256(answer) * (10 ** quoteDecimals)) / (10 ** r.feedDecimals) / (10 ** r.tokenDecimals)](src/base/ConversionRoutes.sol#L137-L138)
	- [(gross * (BPS - r.maxSlippageBps)) / BPS](src/base/ConversionRoutes.sol#L139)

src/base/ConversionRoutes.sol#L126-L140


 - [ ] ID-8
[ChipRounds._weight(address,uint32,address)](src/ChipRounds.sol#L441-L447) performs a multiplication on the result of a division:
	- [w = (uint256(tierBps) * base) / BPS](src/ChipRounds.sol#L444)
	- [w = (w * boostBps) / BPS](src/ChipRounds.sol#L445)

src/ChipRounds.sol#L441-L447


## erc20-interface
Impact: Medium
Confidence: High
 - [ ] ID-9
[IERC721Approve](src/POLTreasury.sol#L396-L398) has incorrect ERC20 function interface:[IERC721Approve.approve(address,uint256)](src/POLTreasury.sol#L397)

src/POLTreasury.sol#L396-L398


## incorrect-equality
Impact: Medium
Confidence: High
 - [ ] ID-10
[Pot.sweepNonQuote(address,address)](src/Pot.sol#L162-L167) uses a dangerous strict equality:
	- [amount == 0](src/Pot.sol#L165)

src/Pot.sol#L162-L167


 - [ ] ID-11
[FeeSplitter.distributeToken(IERC20)](src/FeeSplitter.sol#L142-L151) uses a dangerous strict equality:
	- [balance == 0](src/FeeSplitter.sol#L149)

src/FeeSplitter.sol#L142-L151


 - [ ] ID-12
[FeeSplitter.distributeTokens(IERC20[])](src/FeeSplitter.sol#L155-L163) uses a dangerous strict equality:
	- [balance == 0](src/FeeSplitter.sol#L160)

src/FeeSplitter.sol#L155-L163


 - [ ] ID-13
[ChipRounds.nextRoundOpensAt()](src/ChipRounds.sol#L383-L385) uses a dangerous strict equality:
	- [lastRoundOpenedAt == 0](src/ChipRounds.sol#L384)

src/ChipRounds.sol#L383-L385


 - [ ] ID-14
[Pot.sweepEth(address)](src/Pot.sol#L169-L176) uses a dangerous strict equality:
	- [amount == 0](src/Pot.sol#L173-L174)

src/Pot.sol#L169-L176


 - [ ] ID-15
[POLTreasury.forwardIncome(address)](src/POLTreasury.sol#L328-L334) uses a dangerous strict equality:
	- [amount == 0](src/POLTreasury.sol#L331)

src/POLTreasury.sol#L328-L334


 - [ ] ID-16
[ConversionRoutes._convert(address)](src/base/ConversionRoutes.sol#L146-L183) uses a dangerous strict equality:
	- [minOut == 0](src/base/ConversionRoutes.sol#L153)

src/base/ConversionRoutes.sol#L146-L183


 - [ ] ID-17
[FeeSplitter.distributeAll(IERC20[])](src/FeeSplitter.sol#L167-L177) uses a dangerous strict equality:
	- [tokenBalance == 0](src/FeeSplitter.sol#L174)

src/FeeSplitter.sol#L167-L177


 - [ ] ID-18
[FeeSplitter.distributeETH()](src/FeeSplitter.sol#L135-L139) uses a dangerous strict equality:
	- [balance == 0](src/FeeSplitter.sol#L137)

src/FeeSplitter.sol#L135-L139


 - [ ] ID-19
[ConversionRoutes._convert(address)](src/base/ConversionRoutes.sol#L146-L183) uses a dangerous strict equality:
	- [amountIn == 0](src/base/ConversionRoutes.sol#L150)

src/base/ConversionRoutes.sol#L146-L183


## reentrancy-no-eth
Impact: Medium
Confidence: Medium
 - [ ] ID-20
Reentrancy in [ChipRounds.settleStock(uint256,address)](src/ChipRounds.sol#L509-L568):
	External calls:
	- [(executed,received,quoteSpent,reason) = _buy(stock,slice)](src/ChipRounds.sol#L535)
		- [uniswapRouter.exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,fee:s.fee,recipient:address(this),amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L672-L686)
		- [slipstreamRouter.exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,tickSpacing:s.tickSpacing,recipient:address(this),deadline:block.timestamp,amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L688-L703)
	- [heldBack = _sendHoldback(stock,received)](src/ChipRounds.sol#L549)
		- [(ok,None) = stock.call(abi.encodeCall(IERC20.transfer,(treasury,target)))](src/ChipRounds.sol#L603)
	State variables written after the call(s):
	- [r.spent += uint128(quoteSpent)](src/ChipRounds.sol#L553)
	[ChipRounds._rounds](src/ChipRounds.sol#L112) can be used in cross function reentrancies:
	- [ChipRounds.getRound(uint256)](src/ChipRounds.sol#L374-L376)

src/ChipRounds.sol#L509-L568


 - [ ] ID-21
Reentrancy in [ChipRounds.openRound()](src/ChipRounds.sol#L388-L411):
	External calls:
	- [got = pot.pullBudget(want)](src/ChipRounds.sol#L396)
	State variables written after the call(s):
	- [lastRoundOpenedAt = uint64(block.timestamp)](src/ChipRounds.sol#L407)
	[ChipRounds.lastRoundOpenedAt](src/ChipRounds.sol#L108) can be used in cross function reentrancies:
	- [ChipRounds.lastRoundOpenedAt](src/ChipRounds.sol#L108)
	- [ChipRounds.nextRoundOpensAt()](src/ChipRounds.sol#L383-L385)

src/ChipRounds.sol#L388-L411


 - [ ] ID-22
Reentrancy in [Anvil.shelve(address,uint256[])](src/anvil/Anvil.sol#L358-L368):
	External calls:
	- [IERC721(collection).transferFrom(msg.sender,address(this),id)](src/anvil/Anvil.sol#L363)
	State variables written after the call(s):
	- [sh.tokenIds.push(id)](src/anvil/Anvil.sol#L364)
	[Anvil._shelf](src/anvil/Anvil.sol#L88) can be used in cross function reentrancies:
	- [Anvil.nextOnShelf(address)](src/anvil/Anvil.sol#L290-L297)
	- [Anvil.shelfQueue(address)](src/anvil/Anvil.sol#L300-L309)
	- [Anvil.shelfRemaining(address)](src/anvil/Anvil.sol#L279-L285)
	- [Anvil.shelfState(address)](src/anvil/Anvil.sol#L322-L340)
	- [isListed[collection][id] = true](src/anvil/Anvil.sol#L365)
	[Anvil.isListed](src/anvil/Anvil.sol#L91) can be used in cross function reentrancies:
	- [Anvil.isListed](src/anvil/Anvil.sol#L91)
	- [Anvil.nextOnShelf(address)](src/anvil/Anvil.sol#L290-L297)
	- [Anvil.shelfQueue(address)](src/anvil/Anvil.sol#L300-L309)
	- [Anvil.shelfRemaining(address)](src/anvil/Anvil.sol#L279-L285)
	- [Anvil.shelfState(address)](src/anvil/Anvil.sol#L322-L340)

src/anvil/Anvil.sol#L358-L368


 - [ ] ID-23
Reentrancy in [ChipRounds.contributeWeights(uint256,address,uint256[])](src/ChipRounds.sol#L416-L438):
	External calls:
	- [added += _allocate(roundId,collection,tokenId,owner,weight)](src/ChipRounds.sol#L433)
		- [claims.creditWeight(roundId,stock,owner,weight)](src/ChipRounds.sol#L488)
	State variables written after the call(s):
	- [r.totalWeight += added](src/ChipRounds.sol#L436)
	[ChipRounds._rounds](src/ChipRounds.sol#L112) can be used in cross function reentrancies:
	- [ChipRounds.getRound(uint256)](src/ChipRounds.sol#L374-L376)
	- [counted[roundId][collection][tokenId] = true](src/ChipRounds.sol#L432)
	[ChipRounds.counted](src/ChipRounds.sol#L117) can be used in cross function reentrancies:
	- [ChipRounds.counted](src/ChipRounds.sol#L117)

src/ChipRounds.sol#L416-L438


 - [ ] ID-24
Reentrancy in [Anvil.unshelve(address,uint256,address)](src/anvil/Anvil.sol#L376-L399):
	External calls:
	- [IERC721(collection).transferFrom(address(this),to,id)](src/anvil/Anvil.sol#L393)
	State variables written after the call(s):
	- [sh.tokenIds.pop()](src/anvil/Anvil.sol#L387)
	[Anvil._shelf](src/anvil/Anvil.sol#L88) can be used in cross function reentrancies:
	- [Anvil.nextOnShelf(address)](src/anvil/Anvil.sol#L290-L297)
	- [Anvil.shelfQueue(address)](src/anvil/Anvil.sol#L300-L309)
	- [Anvil.shelfRemaining(address)](src/anvil/Anvil.sol#L279-L285)
	- [Anvil.shelfState(address)](src/anvil/Anvil.sol#L322-L340)
	- [isListed[collection][id] = false](src/anvil/Anvil.sol#L392)
	[Anvil.isListed](src/anvil/Anvil.sol#L91) can be used in cross function reentrancies:
	- [Anvil.isListed](src/anvil/Anvil.sol#L91)
	- [Anvil.nextOnShelf(address)](src/anvil/Anvil.sol#L290-L297)
	- [Anvil.shelfQueue(address)](src/anvil/Anvil.sol#L300-L309)
	- [Anvil.shelfRemaining(address)](src/anvil/Anvil.sol#L279-L285)
	- [Anvil.shelfState(address)](src/anvil/Anvil.sol#L322-L340)

src/anvil/Anvil.sol#L376-L399


 - [ ] ID-25
Reentrancy in [Furnace.depositStock(address,uint256[])](src/furnace/Furnace.sol#L259-L266):
	External calls:
	- [IERC721(collection).transferFrom(msg.sender,address(this),tokenIds[i])](src/furnace/Furnace.sol#L262)
	State variables written after the call(s):
	- [_stock[collection].push(tokenIds[i])](src/furnace/Furnace.sol#L263)
	[Furnace._stock](src/furnace/Furnace.sol#L72) can be used in cross function reentrancies:
	- [Furnace.depositStock(address,uint256[])](src/furnace/Furnace.sol#L259-L266)
	- [Furnace.nextOutput(uint8)](src/furnace/Furnace.sol#L228-L235)
	- [Furnace.stockQueue(address)](src/furnace/Furnace.sol#L238-L245)
	- [Furnace.stockRemainingFor(address)](src/furnace/Furnace.sol#L223-L225)

src/furnace/Furnace.sol#L259-L266


## uninitialized-local
Impact: Medium
Confidence: Medium
 - [ ] ID-26
[ChipRounds._minOutFor(address,uint256).price1e18](src/ChipRounds.sol#L630) is a local variable never initialized

src/ChipRounds.sol#L630


 - [ ] ID-27
[ChipRounds.setSplit(address,uint256,address[],uint8[]).p](src/ChipRounds.sol#L346) is a local variable never initialized

src/ChipRounds.sol#L346


 - [ ] ID-28
[Anvil.shelfQueue(address).k](src/anvil/Anvil.sol#L305) is a local variable never initialized

src/anvil/Anvil.sol#L305


 - [ ] ID-29
[StockRegistry._setVenue(address,Venue,address,uint24,int24).expected](src/StockRegistry.sol#L321) is a local variable never initialized

src/StockRegistry.sol#L321


 - [ ] ID-30
[ClaimRouter.claimEverything(ClaimRouter.ChipClaim[]).failed](src/ClaimRouter.sol#L116) is a local variable never initialized

src/ClaimRouter.sol#L116


 - [ ] ID-31
[ChipRounds.setSplit(address,uint256,address[],uint8[]).fee](src/ChipRounds.sol#L360) is a local variable never initialized

src/ChipRounds.sol#L360


 - [ ] ID-32
[ChipRounds.contributeWeights(uint256,address,uint256[]).accepted](src/ChipRounds.sol#L421) is a local variable never initialized

src/ChipRounds.sol#L421


 - [ ] ID-33
[ChipRounds._buy(address,uint256).ok](src/ChipRounds.sol#L670) is a local variable never initialized

src/ChipRounds.sol#L670


 - [ ] ID-34
[ChipRounds.setSplit(address,uint256,address[],uint8[]).sum](src/ChipRounds.sol#L344) is a local variable never initialized

src/ChipRounds.sol#L344


 - [ ] ID-35
[ChipRounds.contributeWeights(uint256,address,uint256[]).added](src/ChipRounds.sol#L420) is a local variable never initialized

src/ChipRounds.sol#L420


 - [ ] ID-36
[StockRegistry.enabledTokens().k](src/StockRegistry.sol#L217) is a local variable never initialized

src/StockRegistry.sol#L217


 - [ ] ID-37
[StockRegistry.enabledTokens().n](src/StockRegistry.sol#L211) is a local variable never initialized

src/StockRegistry.sol#L211


 - [ ] ID-38
[ChipRounds.setSplit(address,uint256,address[],uint8[]).s](src/ChipRounds.sol#L345) is a local variable never initialized

src/ChipRounds.sol#L345


## unused-return
Impact: Medium
Confidence: Medium
 - [ ] ID-39
[ChipRounds._buy(address,uint256)](src/ChipRounds.sol#L646-L717) ignores return value by [uniswapRouter.exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,fee:s.fee,recipient:address(this),amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L672-L686)

src/ChipRounds.sol#L646-L717


 - [ ] ID-40
[StockRegistry.priceUsd(address)](src/StockRegistry.sol#L230-L237) ignores return value by [(None,answer,None,updatedAt_,None) = IAggregatorV3(s.feed).latestRoundData()](src/StockRegistry.sol#L233)

src/StockRegistry.sol#L230-L237


 - [ ] ID-41
[NounLoans.borrow(address,uint256,uint8,uint256)](src/loans/NounLoans.sol#L233-L301) ignores return value by [(chipped,None,chipOwner) = activationSource.activation(collection,tokenId)](src/loans/NounLoans.sol#L262)

src/loans/NounLoans.sol#L233-L301


 - [ ] ID-42
[ChipRounds.isFeedStale(address)](src/ChipRounds.sol#L613-L624) ignores return value by [(updatedAt) = registry.priceUsd(stock)](src/ChipRounds.sol#L616-L623)

src/ChipRounds.sol#L613-L624


 - [ ] ID-43
[ChipClaims._usdValue(address,uint256)](src/ChipClaims.sol#L537-L544) ignores return value by [(price1e18) = registry.priceUsd(token)](src/ChipClaims.sol#L539-L543)

src/ChipClaims.sol#L537-L544


 - [ ] ID-44
[ChipRounds._roundValueUsd(uint256,address[])](src/ChipRounds.sol#L775-L789) ignores return value by [(price1e18) = registry.priceUsd(stock)](src/ChipRounds.sol#L784-L787)

src/ChipRounds.sol#L775-L789


 - [ ] ID-45
[NounLoans.isChippedFor(address,uint256,address)](src/loans/NounLoans.sol#L424-L427) ignores return value by [(chipped,None,chipOwner) = activationSource.activation(collection,tokenId)](src/loans/NounLoans.sol#L425)

src/loans/NounLoans.sol#L424-L427


 - [ ] ID-46
[ChipRounds._minOutFor(address,uint256)](src/ChipRounds.sol#L628-L640) ignores return value by [(p) = registry.priceUsd(stock)](src/ChipRounds.sol#L631-L635)

src/ChipRounds.sol#L628-L640


 - [ ] ID-47
[ConversionRoutes.minOutFor(address,uint256)](src/base/ConversionRoutes.sol#L126-L140) ignores return value by [(None,answer,None,updatedAt,None) = IAggregatorV3(r.feed).latestRoundData()](src/base/ConversionRoutes.sol#L130)

src/base/ConversionRoutes.sol#L126-L140


 - [ ] ID-48
[ConversionRoutes._convert(address)](src/base/ConversionRoutes.sol#L146-L183) ignores return value by [IUniswapV3SwapRouter(r.router).exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:token,tokenOut:quoteToken,fee:r.fee,recipient:address(this),amountIn:amountIn,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/base/ConversionRoutes.sol#L164-L175)

src/base/ConversionRoutes.sol#L146-L183


 - [ ] ID-49
[ChipRounds.finalizeRound(uint256)](src/ChipRounds.sol#L721-L747) ignores return value by [claims.freezeSchedule(roundId)](src/ChipRounds.sol#L741)

src/ChipRounds.sol#L721-L747


 - [ ] ID-50
[POLTreasury.collectAllFees()](src/POLTreasury.sol#L285-L292) ignores return value by [() = this.collectFees(positionIds[i])](src/POLTreasury.sol#L288-L290)

src/POLTreasury.sol#L285-L292


 - [ ] ID-51
[ChipRounds._buy(address,uint256)](src/ChipRounds.sol#L646-L717) ignores return value by [slipstreamRouter.exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,tickSpacing:s.tickSpacing,recipient:address(this),deadline:block.timestamp,amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L688-L703)

src/ChipRounds.sol#L646-L717


 - [ ] ID-52
[POLTreasury.forwardIncomeMany(address[])](src/POLTreasury.sol#L338-L344) ignores return value by [this.forwardIncome(tokens[i])](src/POLTreasury.sol#L340-L342)

src/POLTreasury.sol#L338-L344


## shadowing-local
Impact: Low
Confidence: High
 - [ ] ID-53
[POLTreasury.notifyCompound(address,address,uint256,uint256).owner](src/POLTreasury.sol#L354) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/POLTreasury.sol#L354


 - [ ] ID-54
[ChipRounds.contributeWeights(uint256,address,uint256[]).owner](src/ChipRounds.sol#L426) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipRounds.sol#L426


 - [ ] ID-55
[ChipRounds._allocate(uint256,address,uint256,address,uint256).owner](src/ChipRounds.sol#L463) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipRounds.sol#L463


 - [ ] ID-56
[ChipClaims.claimFor(address,uint256,address).owner](src/ChipClaims.sol#L232) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipClaims.sol#L232


 - [ ] ID-57
[ChipClaims._claim(uint256,address,address).owner](src/ChipClaims.sol#L253) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipClaims.sol#L253


 - [ ] ID-58
[ChipRounds._credit(uint256,address,address,uint256).owner](src/ChipRounds.sol#L483) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipRounds.sol#L483


 - [ ] ID-59
[ChipActivation.activation(address,uint256).owner](src/activation/ChipActivation.sol#L282) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/activation/ChipActivation.sol#L282


 - [ ] ID-60
[ClutchVaultAdapter.activation(address,uint256).owner](src/adapters/ClutchVaultAdapter.sol#L103) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/adapters/ClutchVaultAdapter.sol#L103


 - [ ] ID-61
[ClaimRouter.claimEverything(ClaimRouter.ChipClaim[]).owner](src/ClaimRouter.sol#L115) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ClaimRouter.sol#L115


 - [ ] ID-62
[ChipRounds._hasHoodie(address).owner](src/ChipRounds.sol#L452) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipRounds.sol#L452


 - [ ] ID-63
[ClaimRouter._claimChip(address,ClaimRouter.ChipClaim).owner](src/ClaimRouter.sol#L158) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ClaimRouter.sol#L158


 - [ ] ID-64
[ChipClaims.sweepExpired(uint256,address,uint256).owner](src/ChipClaims.sol#L326) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipClaims.sol#L326


 - [ ] ID-65
[ChipRounds._weight(address,uint32,address).owner](src/ChipRounds.sol#L441) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipRounds.sol#L441


 - [ ] ID-66
[ChipClaims.creditWeight(uint256,address,address,uint256).owner](src/ChipClaims.sol#L163) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipClaims.sol#L163


 - [ ] ID-67
[ChipClaims.claimable(uint256,address,address).owner](src/ChipClaims.sol#L213) shadows:
	- [Ownable.owner()](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L54-L56) (function)

src/ChipClaims.sol#L213


## missing-zero-check
Impact: Low
Confidence: Medium
 - [ ] ID-68
[POLTreasury.setRewards(address).newRewards](src/POLTreasury.sol#L125) lacks a zero-check on :
		- [rewards = newRewards](src/POLTreasury.sol#L127)

src/POLTreasury.sol#L125


 - [ ] ID-69
[ChipRounds.setChip(address,address).burnAddress](src/ChipRounds.sol#L221) lacks a zero-check on :
		- [chipBurnAddress = burnAddress](src/ChipRounds.sol#L223)

src/ChipRounds.sol#L221


 - [ ] ID-70
[ClutchVaultAdapter.effectiveOwner(address,uint256).collection](src/adapters/ClutchVaultAdapter.sol#L141) lacks a zero-check on :
		- [(ok,ret) = collection.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L142-L143)

src/adapters/ClutchVaultAdapter.sol#L141


 - [ ] ID-71
[ChipRounds.setChip(address,address).token](src/ChipRounds.sol#L221) lacks a zero-check on :
		- [chipToken = token](src/ChipRounds.sol#L222)

src/ChipRounds.sol#L221


 - [ ] ID-72
[ChipRounds.setHoodie(address,uint32).collection](src/ChipRounds.sol#L234) lacks a zero-check on :
		- [hoodieCollection = collection](src/ChipRounds.sol#L236)

src/ChipRounds.sol#L234


 - [ ] ID-73
[POLTreasury.setManager(address).newManager](src/POLTreasury.sol#L114) lacks a zero-check on :
		- [manager = newManager](src/POLTreasury.sol#L116)

src/POLTreasury.sol#L114


## calls-loop
Impact: Low
Confidence: Medium
 - [ ] ID-74
[Furnace.depositStock(address,uint256[])](src/furnace/Furnace.sol#L259-L266) has external calls inside a loop: [IERC721(collection).transferFrom(msg.sender,address(this),tokenIds[i])](src/furnace/Furnace.sol#L262)

src/furnace/Furnace.sol#L259-L266


 - [ ] ID-75
[ChipRounds._roundValueUsd(uint256,address[])](src/ChipRounds.sol#L775-L789) has external calls inside a loop: [valueUsd += (amount * 1e18) / (10 ** registry.quoteDecimals())](src/ChipRounds.sol#L781)
	Calls stack containing the loop:
		ChipRounds.finalizeRound(uint256)

src/ChipRounds.sol#L775-L789


 - [ ] ID-76
[FeeSplitter.distributeAll(IERC20[])](src/FeeSplitter.sol#L167-L177) has external calls inside a loop: [tokenBalance = token.balanceOf(address(this))](src/FeeSplitter.sol#L173)

src/FeeSplitter.sol#L167-L177


 - [ ] ID-77
[ChipRounds._allocate(uint256,address,uint256,address,uint256)](src/ChipRounds.sol#L463-L481) has external calls inside a loop: [registry.isEnabled(sp.stocks[i])](src/ChipRounds.sol#L477)
	Calls stack containing the loop:
		ChipRounds.contributeWeights(uint256,address,uint256[])

src/ChipRounds.sol#L463-L481


 - [ ] ID-78
[ChipRounds._hasHoodie(address)](src/ChipRounds.sol#L452-L458) has external calls inside a loop: [(ok,ret) = h.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC721.balanceOf,(owner)))](src/ChipRounds.sol#L455)
	Calls stack containing the loop:
		ChipRounds.contributeWeights(uint256,address,uint256[])
		ChipRounds._weight(address,uint32,address)

src/ChipRounds.sol#L452-L458


 - [ ] ID-79
[ChipRounds._credit(uint256,address,address,uint256)](src/ChipRounds.sol#L483-L489) has external calls inside a loop: [claims.creditWeight(roundId,stock,owner,weight)](src/ChipRounds.sol#L488)
	Calls stack containing the loop:
		ChipRounds.contributeWeights(uint256,address,uint256[])
		ChipRounds._allocate(uint256,address,uint256,address,uint256)

src/ChipRounds.sol#L483-L489


 - [ ] ID-80
[Anvil.unshelve(address,uint256,address)](src/anvil/Anvil.sol#L376-L399) has external calls inside a loop: [IERC721(collection).transferFrom(address(this),to,id)](src/anvil/Anvil.sol#L393)

src/anvil/Anvil.sol#L376-L399


 - [ ] ID-81
[ChipClaims._usdValue(address,uint256)](src/ChipClaims.sol#L537-L544) has external calls inside a loop: [(price1e18) = registry.priceUsd(token)](src/ChipClaims.sol#L539-L543)
	Calls stack containing the loop:
		ChipClaims.claimMany(uint256[],address[])
		ChipClaims._claim(uint256,address,address)

src/ChipClaims.sol#L537-L544


 - [ ] ID-82
[Furnace.forge(uint8,uint256[])](src/furnace/Furnace.sol#L154-L202) has external calls inside a loop: [lilCollection.transferFrom(msg.sender,BURN_ADDRESS,lilIds[i_scope_0])](src/furnace/Furnace.sol#L185)

src/furnace/Furnace.sol#L154-L202


 - [ ] ID-83
[POLTreasury.forwardIncomeMany(address[])](src/POLTreasury.sol#L338-L344) has external calls inside a loop: [this.forwardIncome(tokens[i])](src/POLTreasury.sol#L340-L342)

src/POLTreasury.sol#L338-L344


 - [ ] ID-84
[ChipRounds._roundValueUsd(uint256,address[])](src/ChipRounds.sol#L775-L789) has external calls inside a loop: [dec = registry.getStock(stock).tokenDecimals](src/ChipRounds.sol#L785)
	Calls stack containing the loop:
		ChipRounds.finalizeRound(uint256)

src/ChipRounds.sol#L775-L789


 - [ ] ID-85
[ChipClaims._usdValue(address,uint256)](src/ChipClaims.sol#L537-L544) has external calls inside a loop: [(amount * price1e18) / (10 ** registry.getStock(token).tokenDecimals)](src/ChipClaims.sol#L540)
	Calls stack containing the loop:
		ChipClaims.claimMany(uint256[],address[])
		ChipClaims._claim(uint256,address,address)

src/ChipClaims.sol#L537-L544


 - [ ] ID-86
[Furnace.withdrawStock(address,uint256,address)](src/furnace/Furnace.sol#L273-L285) has external calls inside a loop: [IERC721(collection).transferFrom(address(this),to,tokenId)](src/furnace/Furnace.sol#L282)

src/furnace/Furnace.sol#L273-L285


 - [ ] ID-87
[POLTreasury.collectAllFees()](src/POLTreasury.sol#L285-L292) has external calls inside a loop: [() = this.collectFees(positionIds[i])](src/POLTreasury.sol#L288-L290)

src/POLTreasury.sol#L285-L292


 - [ ] ID-88
[ClaimRouter._claimChip(address,ClaimRouter.ChipClaim)](src/ClaimRouter.sol#L158-L163) has external calls inside a loop: [(ok,ret) = address(rewards).call{gas: legGasLimit}(abi.encodeCall(IChipRewardsClaimable.claimFor,(owner,c.roundId,c.stock)))](src/ClaimRouter.sol#L159-L161)
	Calls stack containing the loop:
		ClaimRouter.claimEverything(ClaimRouter.ChipClaim[])

src/ClaimRouter.sol#L158-L163


 - [ ] ID-89
[ChipRounds.contributeWeights(uint256,address,uint256[])](src/ChipRounds.sol#L416-L438) has external calls inside a loop: [(active,tierBps,owner) = activationSource.activation(collection,tokenId)](src/ChipRounds.sol#L426)

src/ChipRounds.sol#L416-L438


 - [ ] ID-90
[ChipClaims._usdValue(address,uint256)](src/ChipClaims.sol#L537-L544) has external calls inside a loop: [(amount * 1e18) / (10 ** registry.quoteDecimals())](src/ChipClaims.sol#L538)
	Calls stack containing the loop:
		ChipClaims.claimMany(uint256[],address[])
		ChipClaims._claim(uint256,address,address)

src/ChipClaims.sol#L537-L544


 - [ ] ID-91
[Anvil.shelve(address,uint256[])](src/anvil/Anvil.sol#L358-L368) has external calls inside a loop: [IERC721(collection).transferFrom(msg.sender,address(this),id)](src/anvil/Anvil.sol#L363)

src/anvil/Anvil.sol#L358-L368


 - [ ] ID-92
[ChipRounds._roundValueUsd(uint256,address[])](src/ChipRounds.sol#L775-L789) has external calls inside a loop: [(price1e18) = registry.priceUsd(stock)](src/ChipRounds.sol#L784-L787)
	Calls stack containing the loop:
		ChipRounds.finalizeRound(uint256)

src/ChipRounds.sol#L775-L789


 - [ ] ID-93
[ChipClaims._claim(uint256,address,address)](src/ChipClaims.sol#L253-L289) has external calls inside a loop: [(noted,None) = polTreasury.call{gas: PROBE_GAS}(abi.encodeWithSignature(notifyCompound(address,address,uint256,uint256),owner,stock,amount,usd))](src/ChipClaims.sol#L280-L282)
	Calls stack containing the loop:
		ChipClaims.claimMany(uint256[],address[])

src/ChipClaims.sol#L253-L289


 - [ ] ID-94
[ChipRounds.setSplit(address,uint256,address[],uint8[])](src/ChipRounds.sol#L336-L368) has external calls inside a loop: [! registry.isEnabled(stocks[i])](src/ChipRounds.sol#L349)

src/ChipRounds.sol#L336-L368


 - [ ] ID-95
[ChipRounds._roundValueUsd(uint256,address[])](src/ChipRounds.sol#L775-L789) has external calls inside a loop: [amount = IChipClaimsView(address(claims)).acquired(roundId,stock)](src/ChipRounds.sol#L778)
	Calls stack containing the loop:
		ChipRounds.finalizeRound(uint256)

src/ChipRounds.sol#L775-L789


 - [ ] ID-96
[Furnace.forge(uint8,uint256[])](src/furnace/Furnace.sol#L154-L202) has external calls inside a loop: [lilCollection.ownerOf(lilIds[i]) != msg.sender](src/furnace/Furnace.sol#L168)

src/furnace/Furnace.sol#L154-L202


 - [ ] ID-97
[ClaimRouter._sweep(address,address[])](src/ClaimRouter.sol#L167-L181) has external calls inside a loop: [(okBal,balRet) = token.staticcall{gas: legGasLimit}(abi.encodeCall(IERC20.balanceOf,(address(this))))](src/ClaimRouter.sol#L172-L173)
	Calls stack containing the loop:
		ClaimRouter.sweepTo(address,address[])

src/ClaimRouter.sol#L167-L181


 - [ ] ID-98
[FeeSplitter.distributeTokens(IERC20[])](src/FeeSplitter.sol#L155-L163) has external calls inside a loop: [balance = token.balanceOf(address(this))](src/FeeSplitter.sol#L159)

src/FeeSplitter.sol#L155-L163


 - [ ] ID-99
[StockRegistry.clearsMinLiquidity(address)](src/StockRegistry.sol#L266-L274) has external calls inside a loop: [measured = this.poolLiquidityUsd(token)](src/StockRegistry.sol#L269-L273)
	Calls stack containing the loop:
		StockRegistry.liquidityReport()

src/StockRegistry.sol#L266-L274


 - [ ] ID-100
[ClaimRouter._sweep(address,address[])](src/ClaimRouter.sol#L167-L181) has external calls inside a loop: [(okXfer,None) = token.call{gas: legGasLimit}(abi.encodeCall(IERC20.transfer,(to,amount)))](src/ClaimRouter.sol#L178)
	Calls stack containing the loop:
		ClaimRouter.sweepTo(address,address[])

src/ClaimRouter.sol#L167-L181


 - [ ] ID-101
[StockRegistry.liquidityReport()](src/StockRegistry.sol#L278-L298) has external calls inside a loop: [m = this.poolLiquidityUsd(t)](src/StockRegistry.sol#L291-L295)

src/StockRegistry.sol#L278-L298


## reentrancy-benign
Impact: Low
Confidence: Medium
 - [ ] ID-102
Reentrancy in [ChipRounds.settleStock(uint256,address)](src/ChipRounds.sol#L509-L568):
	External calls:
	- [(executed,received,quoteSpent,reason) = _buy(stock,slice)](src/ChipRounds.sol#L535)
		- [uniswapRouter.exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,fee:s.fee,recipient:address(this),amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L672-L686)
		- [slipstreamRouter.exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,tickSpacing:s.tickSpacing,recipient:address(this),deadline:block.timestamp,amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L688-L703)
	State variables written after the call(s):
	- [stockSkipped[roundId][stock] = true](src/ChipRounds.sol#L540)

src/ChipRounds.sol#L509-L568


 - [ ] ID-103
Reentrancy in [ChipRounds.finalizeRound(uint256)](src/ChipRounds.sol#L721-L747):
	External calls:
	- [pot.noteReturned(unspent)](src/ChipRounds.sol#L737)
	- [claims.freezeSchedule(roundId)](src/ChipRounds.sol#L741)
	State variables written after the call(s):
	- [totalPaidUsd += valueUsd](src/ChipRounds.sol#L744)

src/ChipRounds.sol#L721-L747


 - [ ] ID-104
Reentrancy in [ChipRounds.openRound()](src/ChipRounds.sol#L388-L411):
	External calls:
	- [got = pot.pullBudget(want)](src/ChipRounds.sol#L396)
	State variables written after the call(s):
	- [_rounds[roundId] = Round({state:RoundState.Accumulating,openedAt:uint64(block.timestamp),finalizedAt:0,budget:uint128(got),spent:0,totalWeight:0})](src/ChipRounds.sol#L399-L406)
	- [committedQuote += got](src/ChipRounds.sol#L408)
	- [roundId = ++ roundCount](src/ChipRounds.sol#L398)

src/ChipRounds.sol#L388-L411


 - [ ] ID-105
Reentrancy in [ChipRounds.settleStock(uint256,address)](src/ChipRounds.sol#L509-L568):
	External calls:
	- [(executed,received,quoteSpent,reason) = _buy(stock,slice)](src/ChipRounds.sol#L535)
		- [uniswapRouter.exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,fee:s.fee,recipient:address(this),amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L672-L686)
		- [slipstreamRouter.exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams({tokenIn:quoteToken,tokenOut:stock,tickSpacing:s.tickSpacing,recipient:address(this),deadline:block.timestamp,amountIn:spendAmount,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/ChipRounds.sol#L688-L703)
	- [heldBack = _sendHoldback(stock,received)](src/ChipRounds.sol#L549)
		- [(ok,None) = stock.call(abi.encodeCall(IERC20.transfer,(treasury,target)))](src/ChipRounds.sol#L603)
	State variables written after the call(s):
	- [committedQuote -= quoteSpent](src/ChipRounds.sol#L552)

src/ChipRounds.sol#L509-L568


 - [ ] ID-106
Reentrancy in [POLTreasury.mintPosition(INonfungiblePositionManager.MintParams)](src/POLTreasury.sol#L192-L214):
	External calls:
	- [(tokenId,liquidity,amount0,amount1) = positionManager.mint(p)](src/POLTreasury.sol#L204)
	State variables written after the call(s):
	- [holdsPosition[tokenId] = true](src/POLTreasury.sol#L210)
	- [positionIds.push(tokenId)](src/POLTreasury.sol#L211)

src/POLTreasury.sol#L192-L214


## reentrancy-events
Impact: Low
Confidence: Medium
 - [ ] ID-107
Reentrancy in [Furnace.depositStock(address,uint256[])](src/furnace/Furnace.sol#L259-L266):
	External calls:
	- [IERC721(collection).transferFrom(msg.sender,address(this),tokenIds[i])](src/furnace/Furnace.sol#L262)
	Event emitted after the call(s):
	- [StockDeposited(collection,tokenIds[i],stockRemainingFor(collection))](src/furnace/Furnace.sol#L264)

src/furnace/Furnace.sol#L259-L266


 - [ ] ID-108
Reentrancy in [Pot.sweepEth(address)](src/Pot.sol#L169-L176):
	External calls:
	- [Address.sendValue(address(to),amount)](src/Pot.sol#L174-L175)
	Event emitted after the call(s):
	- [EthSwept(to,amount)](src/Pot.sol#L175-L176)

src/Pot.sol#L169-L176


 - [ ] ID-109
Reentrancy in [ConversionRoutes._convert(address)](src/base/ConversionRoutes.sol#L146-L183):
	External calls:
	- [IWETH(weth).deposit{value: amountIn - wethBalance}()](src/base/ConversionRoutes.sol#L158)
	- [IUniswapV3SwapRouter(r.router).exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({tokenIn:token,tokenOut:quoteToken,fee:r.fee,recipient:address(this),amountIn:amountIn,amountOutMinimum:minOut,sqrtPriceLimitX96:0}))](src/base/ConversionRoutes.sol#L164-L175)
	External calls sending eth:
	- [IWETH(weth).deposit{value: amountIn - wethBalance}()](src/base/ConversionRoutes.sol#L158)
	Event emitted after the call(s):
	- [Converted(token,amountIn,quoteOut,minOut,msg.sender)](src/base/ConversionRoutes.sol#L182)

src/base/ConversionRoutes.sol#L146-L183


## return-bomb
Impact: Low
Confidence: Medium
 - [ ] ID-110
[ChipClaims._balanceOf(address,address)](src/ChipClaims.sol#L547-L551) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC20.balanceOf,(who)))](src/ChipClaims.sol#L548)

src/ChipClaims.sol#L547-L551


 - [ ] ID-111
[ChipRounds._hasHoodie(address)](src/ChipRounds.sol#L452-L458) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = h.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC721.balanceOf,(owner)))](src/ChipRounds.sol#L455)

src/ChipRounds.sol#L452-L458


 - [ ] ID-112
[ChipActivation._effectiveOwner(address,uint256)](src/activation/ChipActivation.sol#L318-L330) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = collection.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/activation/ChipActivation.sol#L319)
	[(okB,retB) = holder.staticcall{gas: PROBE_GAS}(abi.encodeCall(IActivationCustodian.beneficiaryOf,(collection,tokenId)))](src/activation/ChipActivation.sol#L326-L327)

src/activation/ChipActivation.sol#L318-L330


 - [ ] ID-113
[ClutchVaultAdapter.activation(address,uint256)](src/adapters/ClutchVaultAdapter.sol#L99-L134) tries to limit the gas of an external call that controls implicit decoding
	[(okActive,activeRet) = vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.isActive,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L108-L109)
	[(okOwner,ownerRet) = vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.ownerOfRecord,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L114-L115)
	[(okTier,tierRet) = vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.tierOf,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L120-L121)

src/adapters/ClutchVaultAdapter.sol#L99-L134


 - [ ] ID-114
[ClaimRouter._sweep(address,address[])](src/ClaimRouter.sol#L167-L181) tries to limit the gas of an external call that controls implicit decoding
	[(okBal,balRet) = token.staticcall{gas: legGasLimit}(abi.encodeCall(IERC20.balanceOf,(address(this))))](src/ClaimRouter.sol#L172-L173)
	[(okXfer,None) = token.call{gas: legGasLimit}(abi.encodeCall(IERC20.transfer,(to,amount)))](src/ClaimRouter.sol#L178)

src/ClaimRouter.sol#L167-L181


 - [ ] ID-115
[ClutchVaultAdapter.effectiveOwner(address,uint256)](src/adapters/ClutchVaultAdapter.sol#L141-L146) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = collection.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L142-L143)

src/adapters/ClutchVaultAdapter.sol#L141-L146


 - [ ] ID-116
[ClaimRouter._claimChip(address,ClaimRouter.ChipClaim)](src/ClaimRouter.sol#L158-L163) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = address(rewards).call{gas: legGasLimit}(abi.encodeCall(IChipRewardsClaimable.claimFor,(owner,c.roundId,c.stock)))](src/ClaimRouter.sol#L159-L161)

src/ClaimRouter.sol#L158-L163


 - [ ] ID-117
[ClutchVaultAdapter._stillHeldBy(address,uint256,address)](src/adapters/ClutchVaultAdapter.sol#L149-L154) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = collection.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L150-L151)

src/adapters/ClutchVaultAdapter.sol#L149-L154


 - [ ] ID-118
[StockRegistry._checkedDecimals(address,uint8)](src/StockRegistry.sol#L359-L371) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = token.staticcall{gas: DECIMALS_PROBE_GAS}(abi.encodeWithSelector(IERC20Metadata.decimals.selector))](src/StockRegistry.sol#L360-L361)

src/StockRegistry.sol#L359-L371


 - [ ] ID-119
[ChipRounds._balanceOf(address,address)](src/ChipRounds.sol#L819-L823) tries to limit the gas of an external call that controls implicit decoding
	[(ok,ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC20.balanceOf,(who)))](src/ChipRounds.sol#L820)

src/ChipRounds.sol#L819-L823


 - [ ] ID-120
[ChipClaims._claim(uint256,address,address)](src/ChipClaims.sol#L253-L289) tries to limit the gas of an external call that controls implicit decoding
	[(noted,None) = polTreasury.call{gas: PROBE_GAS}(abi.encodeWithSignature(notifyCompound(address,address,uint256,uint256),owner,stock,amount,usd))](src/ChipClaims.sol#L280-L282)

src/ChipClaims.sol#L253-L289


## timestamp
Impact: Low
Confidence: Medium
 - [ ] ID-121
[ChipClaims.sweepExpired(uint256,address,uint256)](src/ChipClaims.sol#L310-L355) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp <= s.expiresAt](src/ChipClaims.sol#L317)

src/ChipClaims.sol#L310-L355


 - [ ] ID-122
[ChipClaims.windowsRemaining(uint256)](src/ChipClaims.sol#L402-L407) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp >= s.expiresAt](src/ChipClaims.sol#L405)

src/ChipClaims.sol#L402-L407


 - [ ] ID-123
[ChipRounds.openRound()](src/ChipRounds.sol#L388-L411) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < openableAt](src/ChipRounds.sol#L390)

src/ChipRounds.sol#L388-L411


 - [ ] ID-124
[NounLoans._loanAt(uint256)](src/loans/NounLoans.sol#L463-L466) uses timestamp for comparisons
	Dangerous comparisons:
	- [loanId >= _loans.length](src/loans/NounLoans.sol#L464)

src/loans/NounLoans.sol#L463-L466


 - [ ] ID-125
[NounLoans.executeTerms()](src/loans/NounLoans.sol#L558-L566) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < p.executableAt](src/loans/NounLoans.sol#L561)

src/loans/NounLoans.sol#L558-L566


 - [ ] ID-126
[NounLoans.isLiquidatable(uint256)](src/loans/NounLoans.sol#L453-L456) uses timestamp for comparisons
	Dangerous comparisons:
	- [! l.closed && block.timestamp > l.dueAt + GRACE_PERIOD](src/loans/NounLoans.sol#L455)

src/loans/NounLoans.sol#L453-L456


 - [ ] ID-127
[ChipRounds.isFeedStale(address)](src/ChipRounds.sol#L613-L624) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp > updatedAt + maxAge](src/ChipRounds.sol#L618)

src/ChipRounds.sol#L613-L624


 - [ ] ID-128
[ChipClaims._windowStateAt(uint64,uint32,uint32)](src/ChipClaims.sol#L446-L461) uses timestamp for comparisons
	Dangerous comparisons:
	- [ts < windowAnchor](src/ChipClaims.sol#L452)
	- [into < d || d >= w](src/ChipClaims.sol#L458)

src/ChipClaims.sol#L446-L461


 - [ ] ID-129
[ChipActivation.executeCosts(address)](src/activation/ChipActivation.sol#L436-L446) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < p.executableAt](src/activation/ChipActivation.sol#L439)

src/activation/ChipActivation.sol#L436-L446


 - [ ] ID-130
[ChipRounds.closeAccumulation(uint256)](src/ChipRounds.sol#L494-L503) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < closesAt](src/ChipRounds.sol#L498)

src/ChipRounds.sol#L494-L503


 - [ ] ID-131
[ChipClaims._isOpenAt(uint64,uint32,uint32)](src/ChipClaims.sol#L439-L444) uses timestamp for comparisons
	Dangerous comparisons:
	- [ts < windowAnchor](src/ChipClaims.sol#L441)
	- [(uint256(ts - windowAnchor) % w) < d](src/ChipClaims.sol#L443)

src/ChipClaims.sol#L439-L444


 - [ ] ID-132
[ChipClaims._claim(uint256,address,address)](src/ChipClaims.sol#L253-L289) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp > s.expiresAt](src/ChipClaims.sol#L256)

src/ChipClaims.sol#L253-L289


 - [ ] ID-133
[Anvil.executeSnipePremium()](src/anvil/Anvil.sol#L457-L465) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < p.executableAt](src/anvil/Anvil.sol#L460)

src/anvil/Anvil.sol#L457-L465


 - [ ] ID-134
[ChipRounds.cancelRound(uint256)](src/ChipRounds.sol#L754-L770) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < abandonedAt](src/ChipRounds.sol#L758)
	- [budget != 0](src/ChipRounds.sol#L764)

src/ChipRounds.sol#L754-L770


 - [ ] ID-135
[ChipActivation.isActive(address,uint256)](src/activation/ChipActivation.sol#L343-L347) uses timestamp for comparisons
	Dangerous comparisons:
	- [recorded == address(0)](src/activation/ChipActivation.sol#L345)
	- [_effectiveOwner(collection,tokenId) == recorded](src/activation/ChipActivation.sol#L346)

src/activation/ChipActivation.sol#L343-L347


 - [ ] ID-136
[ConversionRoutes.minOutFor(address,uint256)](src/base/ConversionRoutes.sol#L126-L140) uses timestamp for comparisons
	Dangerous comparisons:
	- [r.maxFeedAge != 0 && block.timestamp > updatedAt + r.maxFeedAge](src/base/ConversionRoutes.sol#L132)

src/base/ConversionRoutes.sol#L126-L140


 - [ ] ID-137
[ChipRounds.nextRoundOpensAt()](src/ChipRounds.sol#L383-L385) uses timestamp for comparisons
	Dangerous comparisons:
	- [lastRoundOpenedAt == 0](src/ChipRounds.sol#L384)

src/ChipRounds.sol#L383-L385


 - [ ] ID-138
[Anvil.executeQueuePrice(address)](src/anvil/Anvil.sol#L433-L441) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < p.executableAt](src/anvil/Anvil.sol#L436)

src/anvil/Anvil.sol#L433-L441


 - [ ] ID-139
[ChipActivation.executeTierBps()](src/activation/ChipActivation.sol#L468-L477) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < p.executableAt](src/activation/ChipActivation.sol#L471)

src/activation/ChipActivation.sol#L468-L477


 - [ ] ID-140
[Furnace.executeRecipeChange(uint8)](src/furnace/Furnace.sol#L313-L323) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < p.executableAt](src/furnace/Furnace.sol#L316)

src/furnace/Furnace.sol#L313-L323


 - [ ] ID-141
[ChipRounds.finalizeRound(uint256)](src/ChipRounds.sol#L721-L747) uses timestamp for comparisons
	Dangerous comparisons:
	- [unspent != 0](src/ChipRounds.sol#L734)

src/ChipRounds.sol#L721-L747


 - [ ] ID-142
[ChipClaims.isFinalized(uint256)](src/ChipClaims.sol#L374-L376) uses timestamp for comparisons
	Dangerous comparisons:
	- [_schedules[roundId].finalizedAt != 0](src/ChipClaims.sol#L375)

src/ChipClaims.sol#L374-L376


 - [ ] ID-143
[NounLoans.repay(uint256)](src/loans/NounLoans.sol#L314-L343) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp > deadline](src/loans/NounLoans.sol#L319)

src/loans/NounLoans.sol#L314-L343


 - [ ] ID-144
[ChipClaims._openingsIn(uint64,uint64,uint32)](src/ChipClaims.sol#L431-L437) uses timestamp for comparisons
	Dangerous comparisons:
	- [to <= from || w == 0](src/ChipClaims.sol#L432)
	- [to <= anchor](src/ChipClaims.sol#L434)
	- [from <= anchor](src/ChipClaims.sol#L435)
	- [toIdx > fromIdx](src/ChipClaims.sol#L436)

src/ChipClaims.sol#L431-L437


 - [ ] ID-145
[NounLoans.liquidate(uint256)](src/loans/NounLoans.sol#L352-L380) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp <= liquidatableAt](src/loans/NounLoans.sol#L357)

src/loans/NounLoans.sol#L352-L380


## pragma
Impact: Informational
Confidence: High
 - [ ] ID-146
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
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L2-L4)
	- Version constraint ^0.8.24 is used by:
		-[^0.8.24](src/ChipClaims.sol#L2)
		-[^0.8.24](src/ChipRounds.sol#L2)
		-[^0.8.24](src/ClaimRouter.sol#L2)
		-[^0.8.24](src/FeeSplitter.sol#L2)
		-[^0.8.24](src/POLTreasury.sol#L2)
		-[^0.8.24](src/Pot.sol#L1-L2)
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


## cyclomatic-complexity
Impact: Informational
Confidence: High
 - [ ] ID-147
[NounLoans.borrow(address,uint256,uint8,uint256)](src/loans/NounLoans.sol#L233-L301) has a high cyclomatic complexity (12).

src/loans/NounLoans.sol#L233-L301


 - [ ] ID-148
[Furnace.forge(uint8,uint256[])](src/furnace/Furnace.sol#L154-L202) has a high cyclomatic complexity (12).

src/furnace/Furnace.sol#L154-L202


## low-level-calls
Impact: Informational
Confidence: High
 - [ ] ID-149
Low level call in [ChipRounds._hasHoodie(address)](src/ChipRounds.sol#L452-L458):
	- [(ok,ret) = h.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC721.balanceOf,(owner)))](src/ChipRounds.sol#L455)

src/ChipRounds.sol#L452-L458


 - [ ] ID-150
Low level call in [StockRegistry._checkedDecimals(address,uint8)](src/StockRegistry.sol#L359-L371):
	- [(ok,ret) = token.staticcall{gas: DECIMALS_PROBE_GAS}(abi.encodeWithSelector(IERC20Metadata.decimals.selector))](src/StockRegistry.sol#L360-L361)

src/StockRegistry.sol#L359-L371


 - [ ] ID-151
Low level call in [Anvil._settle(address,uint256,uint256,bool)](src/anvil/Anvil.sol#L215-L240):
	- [(ok,None) = feeSplitter.call{value: price}()](src/anvil/Anvil.sol#L223)
	- [(refunded,None) = msg.sender.call{value: excess}()](src/anvil/Anvil.sol#L228)

src/anvil/Anvil.sol#L215-L240


 - [ ] ID-152
Low level call in [ChipClaims._claim(uint256,address,address)](src/ChipClaims.sol#L253-L289):
	- [(noted,None) = polTreasury.call{gas: PROBE_GAS}(abi.encodeWithSignature(notifyCompound(address,address,uint256,uint256),owner,stock,amount,usd))](src/ChipClaims.sol#L280-L282)

src/ChipClaims.sol#L253-L289


 - [ ] ID-153
Low level call in [ConversionRoutes._probeDecimals(address)](src/base/ConversionRoutes.sol#L235-L241):
	- [(ok,ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature(decimals()))](src/base/ConversionRoutes.sol#L236)

src/base/ConversionRoutes.sol#L235-L241


 - [ ] ID-154
Low level call in [ClutchVaultAdapter._stillHeldBy(address,uint256,address)](src/adapters/ClutchVaultAdapter.sol#L149-L154):
	- [(ok,ret) = collection.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L150-L151)

src/adapters/ClutchVaultAdapter.sol#L149-L154


 - [ ] ID-155
Low level call in [ClutchVaultAdapter.activation(address,uint256)](src/adapters/ClutchVaultAdapter.sol#L99-L134):
	- [(okActive,activeRet) = vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.isActive,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L108-L109)
	- [(okOwner,ownerRet) = vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.ownerOfRecord,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L114-L115)
	- [(okTier,tierRet) = vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.tierOf,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L120-L121)

src/adapters/ClutchVaultAdapter.sol#L99-L134


 - [ ] ID-156
Low level call in [ChipRounds._sendHoldback(address,uint256)](src/ChipRounds.sol#L594-L608):
	- [(ok,None) = stock.call(abi.encodeCall(IERC20.transfer,(treasury,target)))](src/ChipRounds.sol#L603)

src/ChipRounds.sol#L594-L608


 - [ ] ID-157
Low level call in [ClutchVaultAdapter.effectiveOwner(address,uint256)](src/adapters/ClutchVaultAdapter.sol#L141-L146):
	- [(ok,ret) = collection.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/adapters/ClutchVaultAdapter.sol#L142-L143)

src/adapters/ClutchVaultAdapter.sol#L141-L146


 - [ ] ID-158
Low level call in [ChipRounds._balanceOf(address,address)](src/ChipRounds.sol#L819-L823):
	- [(ok,ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC20.balanceOf,(who)))](src/ChipRounds.sol#L820)

src/ChipRounds.sol#L819-L823


 - [ ] ID-159
Low level call in [ChipRounds._deliver(uint256,address,uint256)](src/ChipRounds.sol#L573-L586):
	- [(ok,None) = stock.call(abi.encodeCall(IERC20.transfer,(address(claims),amount)))](src/ChipRounds.sol#L577)

src/ChipRounds.sol#L573-L586


 - [ ] ID-160
Low level call in [ClaimRouter._claimChip(address,ClaimRouter.ChipClaim)](src/ClaimRouter.sol#L158-L163):
	- [(ok,ret) = address(rewards).call{gas: legGasLimit}(abi.encodeCall(IChipRewardsClaimable.claimFor,(owner,c.roundId,c.stock)))](src/ClaimRouter.sol#L159-L161)

src/ClaimRouter.sol#L158-L163


 - [ ] ID-161
Low level call in [ClaimRouter._sweep(address,address[])](src/ClaimRouter.sol#L167-L181):
	- [(okBal,balRet) = token.staticcall{gas: legGasLimit}(abi.encodeCall(IERC20.balanceOf,(address(this))))](src/ClaimRouter.sol#L172-L173)
	- [(okXfer,None) = token.call{gas: legGasLimit}(abi.encodeCall(IERC20.transfer,(to,amount)))](src/ClaimRouter.sol#L178)

src/ClaimRouter.sol#L167-L181


 - [ ] ID-162
Low level call in [ChipActivation._effectiveOwner(address,uint256)](src/activation/ChipActivation.sol#L318-L330):
	- [(ok,ret) = collection.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC721.ownerOf,(tokenId)))](src/activation/ChipActivation.sol#L319)
	- [(okB,retB) = holder.staticcall{gas: PROBE_GAS}(abi.encodeCall(IActivationCustodian.beneficiaryOf,(collection,tokenId)))](src/activation/ChipActivation.sol#L326-L327)

src/activation/ChipActivation.sol#L318-L330


 - [ ] ID-163
Low level call in [ChipClaims._balanceOf(address,address)](src/ChipClaims.sol#L547-L551):
	- [(ok,ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC20.balanceOf,(who)))](src/ChipClaims.sol#L548)

src/ChipClaims.sol#L547-L551


## missing-inheritance
Impact: Informational
Confidence: High
 - [ ] ID-164
[ChipClaims](src/ChipClaims.sol#L38-L552) should inherit from [IChipRewardsClaimable](src/interfaces/IChipRewardsClaimable.sol#L5-L10)

src/ChipClaims.sol#L38-L552


## redundant-statements
Impact: Informational
Confidence: High
 - [ ] ID-165
Redundant expression "[noted](src/ChipClaims.sol#L283)" in[ChipClaims](src/ChipClaims.sol#L38-L552)

src/ChipClaims.sol#L283


## var-read-using-this
Impact: Optimization
Confidence: High
 - [ ] ID-166
The function [StockRegistry.liquidityReport()](src/StockRegistry.sol#L278-L298) reads [m = this.poolLiquidityUsd(t)](src/StockRegistry.sol#L291-L295) with `this` which adds an extra STATICCALL.

src/StockRegistry.sol#L278-L298


 - [ ] ID-167
The function [StockRegistry.clearsMinLiquidity(address)](src/StockRegistry.sol#L266-L274) reads [measured = this.poolLiquidityUsd(token)](src/StockRegistry.sol#L269-L273) with `this` which adds an extra STATICCALL.

src/StockRegistry.sol#L266-L274


