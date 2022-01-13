// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB)
    external
    returns (address pair);
}

interface IUniswapV2Router {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

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
    returns (
        uint256 amountToken,
        uint256 amountETH,
        uint256 liquidity
    );

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract AnonverseToken is ERC20Capped, Ownable, ReentrancyGuard {
    string public constant __NAME__ = "Anonverse";
    string public constant __SYMBOL__ = "ANON";
    uint256 public constant __CAP__ = 21 * (10 ** 10) * (10 ** 18);
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant LP_WBNB_USDT = 0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE;

    uint256 private sellFeePct;
    IUniswapV2Router public uniswapV2Router;
    address public uniswapV2Pair;

    address payable[] private treasuryList;
    uint256[] private treasuryRates;

    mapping(address => bool) private _isExcludedFromSenderFees;
    mapping(address => bool) private _isExcludedFromRecipientFees;

    mapping(address => bool) private _isIncludedInSenderFees;
    mapping(address => bool) private _isIncludedInRecipientFees;

    mapping(address => bool) internal blacklist;

    uint256 public constant SlippageScale = 100;
    uint256 public slippage;
    uint256 public timeoutLimit;

    uint256 public holdersNumber;

    constructor () public
    ERC20Capped(__CAP__)
    ERC20(__NAME__, __SYMBOL__)
    {
        sellFeePct = 16;

        // pancake routerV2 address
        uniswapV2Router = IUniswapV2Router(
            0x10ED43C718714eb63d5aA57B78B54704E256024E
        );

        // create ANON-BNB lp address
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), uniswapV2Router.WETH());

        // for addLP
        timeoutLimit = 10 minutes;
        slippage = 10;

        includeIntoRecipientFees(uniswapV2Pair, true);

        _approve(address(this), address(uniswapV2Router), ~uint256(0));
    }

    receive() external payable {}

    function initMintAll(address[] memory _init_accounts, uint256[] memory _init_percents) external onlyOwner {
        require(_init_accounts.length == _init_percents.length, "init length mismatch");
        uint256 totalPercent = 0;
        uint256 totalCap = 0;
        for (uint256 i = 0; i < _init_accounts.length; i++) {
            uint256 mintAmount = __CAP__ * _init_percents[i] / 100;
            totalPercent = totalPercent + _init_percents[i];
            totalCap = totalCap + mintAmount;
            _mint(_init_accounts[i], mintAmount);

            excludeFromSenderFees(_init_accounts[i], true);
        }
        require(totalPercent == 100, "invalid _init_percents");
        require(totalCap == __CAP__, "invalid _init_cap");
    }

    function changeTreasuryList(address payable[] memory _treasuryList, uint256[] memory _rates) external onlyOwner {
        require(_treasuryList.length > 0, "empty _treasuryList");
        require(_treasuryList.length == _rates.length, "_treasuryList length mismatch");

        for (uint256 i = 0; i < _treasuryList.length; i++) {
            require(_treasuryList[i] != address(0), "treasury address is the zero address");
        }

        uint256 totalRates = 0;
        for (uint256 i = 0; i < _rates.length; i++) {
            totalRates = totalRates + _rates[i];
        }
        require(totalRates == 100, "totalRates of treasuryList fee is not 100");

        treasuryList = _treasuryList;
        treasuryRates = _rates;

        for (uint256 i = 0; i < _treasuryList.length; i++) {
            excludeFromSenderFees(_treasuryList[i], true);
            excludeFromRecipientFees(_treasuryList[i], true);
        }
    }

    function setSellFeeRate(uint256 newSellFeeRate) external onlyOwner {
        require(newSellFeeRate <= 100, "invalid newSellFeeRate");
        sellFeePct = newSellFeeRate;
    }

    function includeIntoSenderFees(address account, bool flag) public onlyOwner {
        _isIncludedInSenderFees[account] = flag;
    }

    function includeIntoRecipientFees(address account, bool flag) public onlyOwner {
        _isIncludedInRecipientFees[account] = flag;
    }

    function excludeFromSenderFees(address account, bool flag) public onlyOwner {
        _isExcludedFromSenderFees[account] = flag;
    }

    function excludeFromRecipientFees(address account, bool flag) public onlyOwner {
        _isExcludedFromRecipientFees[account] = flag;
    }

    function setBatchIncludeSenderFeeList(address[] memory users, bool flag) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            _isIncludedInSenderFees[users[i]] = flag;
        }
    }

    function setBatchIncludeRecipientFeeList(address[] memory users, bool flag) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            _isIncludedInRecipientFees[users[i]] = flag;
        }
    }

    function setBatchExcludeFeeList(address[] memory users, bool flag) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            _isExcludedFromSenderFees[users[i]] = flag;
            _isExcludedFromRecipientFees[users[i]] = flag;
        }
    }

    function setBatchBlacklists(address[] memory users, bool[] memory flags) external onlyOwner {
        require(users.length == flags.length, "length mismatch");

        for (uint256 i = 0; i < users.length; i++) {
            blacklist[users[i]] = flags[i];
        }
    }

    // transfer back mis-transferred token to users
    // since address(this) does not hold any ANON while initial deployment, no secure problem
    function transferBack(address tokenAddress, address payable to, uint256 amount) external onlyOwner {
        // transfer BNB
        if (tokenAddress == address(0)) {
            _safeTransferETH(to, amount);
        } else {
            IERC20(tokenAddress).transfer(to, amount);
        }
    }

    function setAddLpConfig(uint256 _slippage, uint256 _timeoutLimit) onlyOwner external {
        require(_slippage <= SlippageScale, "invalid slippage");
        slippage = _slippage;
        timeoutLimit = _timeoutLimit;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override {
        require(!blacklist[sender], "ANON: in blacklist");

        uint256 remainingAmount = amount;

        uint256 recipientBeforeBalance = balanceOf(recipient);

        if (
            amount > 0 &&
            sellFeePct > 0 &&
            sender != address(this) &&
            recipient != address(this) &&
            !_isExcludedFromSenderFees[sender] &&
            !_isExcludedFromRecipientFees[recipient] &&
            (_isIncludedInSenderFees[sender] || _isIncludedInRecipientFees[recipient])
        ) {
            uint256 _ANONTokenFee = amount * sellFeePct / 100;

            super._transfer(sender, address(this), _ANONTokenFee);

            _swapAndTransferToTreasury(_ANONTokenFee);

            remainingAmount = amount - _ANONTokenFee;
        }

        super._transfer(sender, recipient, remainingAmount);

        // statistic
        if (remainingAmount > 0) {
            if (recipientBeforeBalance == 0) {
                holdersNumber++;
            }

            if (balanceOf(sender) == 0) {
                holdersNumber--;
            }
        }
    }

    function _swapAndTransferToTreasury(uint256 _ANONFee) private nonReentrant {
        uint256 initBalance = address(this).balance;

        _swapTokensForEth(_ANONFee);

        uint256 addedBalance = address(this).balance - initBalance;

        _distributeFee(addedBalance);
    }

    function _swapTokensForEth(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function _distributeFee(uint256 _fee) private {
        require(treasuryList.length > 0, "treasuryList is none");

        uint256 distributedFee = 0;
        uint256 treasuryFee;
        for (uint256 i = 0; i < treasuryList.length; i++) {
            if (i < treasuryList.length - 1) {
                treasuryFee = _fee * treasuryRates[i] / 100;
                distributedFee = distributedFee + treasuryFee;
                _safeTransferETH(treasuryList[i], treasuryFee);
            } else {
                treasuryFee = _fee - distributedFee;
                _safeTransferETH(treasuryList[i], treasuryFee);
            }
        }
    }

    function _safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{gas : 2300, value : value}("");
        require(success, "transfer eth failed");
    }

    function batchTransferAmount(address[] calldata receivers, uint256 amount) external {
        for (uint256 i = 0; i < receivers.length; i++) {
            _transfer(msg.sender, receivers[i], amount);
        }
    }

    function batchTransfer(address[] calldata receivers, uint256[] calldata amounts) external {
        require(receivers.length == amounts.length, "length mismatch");
        for (uint256 i = 0; i < receivers.length; i++) {
            _transfer(msg.sender, receivers[i], amounts[i]);
        }
    }

    function addLP(uint amountTokenDesired)
    external
    payable
    nonReentrant
    {
        _transfer(msg.sender, address(this), amountTokenDesired);
        IUniswapV2Router(uniswapV2Router).addLiquidityETH{
        value: msg.value
        }(
            address(this),
            amountTokenDesired,
            amountTokenDesired - amountTokenDesired * slippage / SlippageScale,
            msg.value - msg.value * slippage / SlippageScale,
            msg.sender,
            block.timestamp + timeoutLimit
        );
    }

    function isIncludedInSenderFees(address account) public view returns (bool) {
        return _isIncludedInSenderFees[account];
    }

    function isIncludedInRecipientFees(address account) public view returns (bool) {
        return _isIncludedInRecipientFees[account];
    }

    function isExcludedFromSenderFees(address account) public view returns (bool) {
        return _isExcludedFromSenderFees[account];
    }

    function isExcludedFromRecipientFees(address account) public view returns (bool) {
        return _isExcludedFromRecipientFees[account];
    }

    function getTokenPrices()
    public
    view
    returns(uint256 priceInUsd, uint256 priceInWBNB) {

        // WBNB  uniswapV2Router.WETH()
        // LP_BNB_ANON  uniswapV2Pair
        uint256 WBNBBalanceAtANONPair = IERC20(uniswapV2Router.WETH()).balanceOf(uniswapV2Pair);
        uint256 ANONBalanceAtANONPair = IERC20(address(this)).balanceOf(uniswapV2Pair);
        priceInWBNB =  WBNBBalanceAtANONPair * 1e18 / ANONBalanceAtANONPair;

        uint256 USDTBalanceAtPair = IERC20(USDT).balanceOf(LP_WBNB_USDT);
        uint256 WBNBBalanceAtPair = IERC20(uniswapV2Router.WETH()).balanceOf(LP_WBNB_USDT);

        // WBNB Price * WBNB amount * 2 / total lp supply
        priceInUsd = priceInWBNB * USDTBalanceAtPair / WBNBBalanceAtPair;
    }
}
