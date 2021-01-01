// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IUniswapV2Router02} from "../interfaces/IUniswapV2Router.sol";
import {
    IOToken,
    IOptionsExchange,
    IUniswapFactory,
    UniswapExchangeInterface,
    CompoundOracleInterface
} from "../interfaces/OpynV1Interface.sol";
import {IProtocolAdapter, OptionType} from "./IProtocolAdapter.sol";
import {
    ILendingPool,
    ILendingPoolAddressesProvider
} from "../lib/aave/Interfaces.sol";
import {OpynV1FlashLoaner} from "./OpynV1FlashLoaner.sol";

contract OpynV1Adapter is IProtocolAdapter, ReentrancyGuard, OpynV1FlashLoaner {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    string private constant _name = "OPYN_V1";
    bool private constant _nonFungible = false;
    uint256 private constant _swapDeadline = 900; // 15 minutes

    constructor(ILendingPoolAddressesProvider _addressProvider)
        public
        OpynV1FlashLoaner(_addressProvider)
    {}

    function initialize(
        address _owner,
        address _dojiFactory,
        ILendingPoolAddressesProvider _provider,
        address router,
        address weth
    ) public initializer {
        owner = _owner;
        dojiFactory = _dojiFactory;
        _addressesProvider = _provider;
        _lendingPool = ILendingPool(
            ILendingPoolAddressesProvider(_provider).getLendingPool()
        );
        _uniswapRouter = router;
        _weth = weth;
    }

    function protocolName() public override pure returns (string memory) {
        return _name;
    }

    function nonFungible() external override pure returns (bool) {
        return _nonFungible;
    }

    function optionsExist(
        address underlying,
        address strikeAsset,
        uint256 expiry,
        uint256 strikePrice,
        OptionType optionType
    ) public override view returns (bool) {
        address oToken = lookupOToken(
            underlying,
            strikeAsset,
            expiry,
            strikePrice,
            optionType
        );
        return oToken != address(0);
    }

    function getOptionsAddress(
        address underlying,
        address strikeAsset,
        uint256 expiry,
        uint256 strikePrice,
        OptionType optionType
    ) external override view returns (address) {
        address oToken = lookupOToken(
            underlying,
            strikeAsset,
            expiry,
            strikePrice,
            optionType
        );

        require(oToken != address(0), "No oToken found");
        return oToken;
    }

    function premium(
        address underlying,
        address strikeAsset,
        uint256 expiry,
        uint256 strikePrice,
        OptionType optionType,
        uint256 purchaseAmount
    ) public override view returns (uint256 cost) {
        address oToken = lookupOToken(
            underlying,
            strikeAsset,
            expiry,
            strikePrice,
            optionType
        );
        UniswapExchangeInterface uniswapExchange = getUniswapExchangeFromOToken(
            oToken
        );
        cost = uniswapExchange.getEthToTokenOutputPrice(
            scaleDownDecimals(IOToken(oToken), purchaseAmount)
        );
    }

    function exerciseProfit(
        address oToken,
        uint256 optionID,
        uint256 exerciseAmount,
        address underlying
    ) public override view returns (uint256 profit) {
        IOToken oTokenContract = IOToken(oToken);
        address oTokenCollateral = oTokenContract.collateral();

        uint256 strikeAmountOut = getStrikeAssetOutAmount(
            oTokenContract,
            exerciseAmount
        );
        uint256 collateralToPay = OpynV1FlashLoaner.calculateCollateralToPay(
            oTokenContract,
            exerciseAmount
        );
        require(false, uint2str(collateralToPay));

        // if we exercised here, the collateral returned will be less than what Uniswap is giving us
        // which means we're at a loss, so don't exercise
        if (collateralToPay < strikeAmountOut) {
            return 0;
        }

        if (underlying != oTokenCollateral) {
            IUniswapV2Router02 router = IUniswapV2Router02(_uniswapRouter);
            address[] memory path = new address[](2);
            path[0] = oTokenCollateral;
            path[1] = underlying;

            uint256[] memory amountsOut = router.getAmountsOut(
                collateralToPay,
                path
            );
            return amountsOut[1];
        }
        return collateralToPay;
    }

    function purchase(
        address underlying,
        address strikeAsset,
        uint256 expiry,
        uint256 strikePrice,
        OptionType optionType,
        uint256 amount
    )
        external
        override
        payable
        nonReentrant
        onlyInstrument
        returns (uint256 optionID)
    {
        uint256 cost = premium(
            underlying,
            strikeAsset,
            expiry,
            strikePrice,
            optionType,
            amount
        );
        require(msg.value >= cost, "Value does not cover cost");

        address oToken = lookupOToken(
            underlying,
            strikeAsset,
            expiry,
            strikePrice,
            optionType
        );

        uint256 scaledAmount = swapForOToken(oToken, cost, amount);

        emit Purchased(
            msg.sender,
            _name,
            underlying,
            strikeAsset,
            expiry,
            strikePrice,
            optionType,
            scaledAmount,
            cost,
            0
        );
    }

    function swapForOToken(
        address oToken,
        uint256 tokenCost,
        uint256 purchaseAmount
    ) private returns (uint256 scaledAmount) {
        scaledAmount = scaleDownDecimals(IOToken(oToken), purchaseAmount);

        uint256 ethSold = getUniswapExchangeFromOToken(oToken)
            .ethToTokenSwapOutput{value: tokenCost}(
            scaledAmount,
            block.timestamp + _swapDeadline
        );

        (bool changeSuccess, ) = msg.sender.call{value: msg.value - ethSold}(
            ""
        );
        require(changeSuccess, "Transfer of change failed");
    }

    function exercise(
        address oToken,
        uint256 optionID,
        uint256 amount,
        address underlying,
        address account
    ) external override payable onlyInstrument nonReentrant {
        IOToken oTokenContract = IOToken(oToken);
        require(!oTokenContract.hasExpired(), "Options contract expired");
        uint256 scaledAmount = scaleDownDecimals(oTokenContract, amount);
        OpynV1FlashLoaner.exerciseOTokens(oToken, scaledAmount, underlying);
    }

    function setOTokenWithTerms(
        uint256 strikePrice,
        OptionType optionType,
        address oToken
    ) external onlyOwner {
        IOToken oTokenContract = IOToken(oToken);

        (address underlying, address strikeAsset) = getAssets(
            oTokenContract,
            optionType
        );
        uint256 expiry = oTokenContract.expiry();

        bytes memory optionTerms = abi.encode(
            underlying,
            strikeAsset,
            expiry,
            strikePrice,
            optionType
        );
        optionTermsToOToken[optionTerms] = oToken;
    }

    function getAssets(IOToken oTokenContract, OptionType optionType)
        private
        view
        returns (address underlying, address strikeAsset)
    {
        if (optionType == OptionType.Call) {
            underlying = oTokenContract.collateral();
            strikeAsset = oTokenContract.underlying();
        } else if (optionType == OptionType.Put) {
            underlying = oTokenContract.underlying();
            strikeAsset = oTokenContract.collateral();
        }
    }

    function setVaults(address oToken, address payable[] memory vaultOwners)
        public
        onlyOwner
    {
        for (uint256 i = 0; i < vaultOwners.length; i++) {
            vaults[oToken].push(vaultOwners[i]);
        }
    }

    function lookupOToken(
        address underlying,
        address strikeAsset,
        uint256 expiry,
        uint256 strikePrice,
        OptionType optionType
    ) public view returns (address oToken) {
        bytes memory optionTerms = abi.encode(
            underlying,
            strikeAsset,
            expiry,
            strikePrice,
            optionType
        );
        return optionTermsToOToken[optionTerms];
    }

    function getUniswapExchangeFromOToken(address oToken)
        private
        view
        returns (UniswapExchangeInterface uniswapExchange)
    {
        IOptionsExchange optionsExchange = IOToken(oToken).optionsExchange();
        IUniswapFactory uniswapFactory = optionsExchange.UNISWAP_FACTORY();
        uniswapExchange = UniswapExchangeInterface(
            uniswapFactory.getExchange(oToken)
        );
    }

    function getStrikeAssetOutAmount(IOToken oToken, uint256 exerciseAmount)
        private
        view
        returns (uint256)
    {
        address strikeAsset = oToken.strike();
        address oTokenUnderlying = oToken.underlying();
        uint256 underlyingDecimals = uint256(-oToken.underlyingExp());

        CompoundOracleInterface compoundOracle = CompoundOracleInterface(
            oToken.COMPOUND_ORACLE()
        );
        uint256 price = compoundOracle.getPrice(oTokenUnderlying);

        IUniswapV2Router02 router = IUniswapV2Router02(_uniswapRouter);
        address[] memory path = new address[](3);
        path[0] = oTokenUnderlying == address(0) ? _weth : oTokenUnderlying;
        path[1] = _weth;
        path[2] = strikeAsset == address(0) ? _weth : strikeAsset;

        uint256[] memory amountsOut = router.getAmountsOut(
            exerciseAmount.mul(10**underlyingDecimals).div(
                10**oToken.decimals()
            ),
            path
        );
        require(false, toAsciiString(oTokenUnderlying));
        require(false, uint2str(price));
        return amountsOut[1];
    }
}
