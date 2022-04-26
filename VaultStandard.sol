// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;


import {ERC20} from "https://github.com/Rari-Capital/solmate/blob/main/src/tokens/ERC20.sol";
import {SafeTransferLib} from "https://github.com/Rari-Capital/solmate/blob/main/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "https://github.com/Rari-Capital/solmate/blob/main/src/utils/FixedPointMathLib.sol";

/// @notice Minimal ERC4626 tokenized Vault implementation.
/// @author Solmate (https://github.com/Rari-Capital/solmate/blob/main/src/mixins/ERC4626.sol)
 contract ERC4626 is ERC20 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);

    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/


    ERC20 public immutable asset;
    //at deployment, input address of asset token, name, and symbol. All info stored as 'asset' in contract
    constructor(
        ERC20 _asset,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol, _asset.decimals()) {
        asset = _asset;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    
    //function takes in specified amount of assets and first transfers asset to contract, then mints 
    //corresponding amount of shares to specified receiver
    //note share amount is rounded down
    function deposit(uint256 assets, address receiver) public virtual returns (uint256 shares) {
        // Check for rounding error since we round down in previewDeposit. 
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    //function takes in specified number of desired shares and receiver of those shares
    //asset amount needed to mint that number of shares is calculated from previewMint (rounds up)
    //first transfers asset amount from msg.sender to contract, then mints corresponding number of shares
    //different from deposit in that amount of shares desired is specified instead of a given amount of asset to deposit
    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    //function takes in specified number of desired assets to be withrawn, who receives them, and who the owner is
    //corresponding number of shares needed in exchange to withdraw desired amount of asset calculated from previewWithdraw
    //previewWithdraw rounds up since calculating shares to go to contract
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual returns (uint256 shares) {
        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.
        //checks to see if msg.sender owner. If not, must check to see how much of owner's balance msg.sender allowed to use
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.
            //if msg.sender not given infinite allowance, then take away withdraw amount of shares from allowed
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        beforeWithdraw(assets, shares);
        //burn shares of owner first before transferring
        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        asset.safeTransfer(receiver, assets);
    }

    //function takes in specified number of shares to be redeemed, who receivees them, and who the owner is
    //different from withdraw in that the amount of shares to be redeemed for asset specified, rather than specifying amount of asset to be withdraw
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public returns (uint256 assets) {
        //checks to see if msg.sender owner. If not, must check to see how much of owner's balance msg.sender allowed to use
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.
            //if msg.sender not given infinite allowance, then take away withdraw amount of shares from allowed
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        // Check for rounding error since we round down in previewRedeem.
        //assets rounded down because contract supplying the assets in exchange
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        beforeWithdraw(assets, shares);
        //burn shares of owner first before transferring
        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        asset.safeTransfer(receiver, assets);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    //keeps track of amount of asset in contract + amount of asset in farms
    //this is the 'total supply' for assets.
    //needs to be written in
    function totalAssets() public virtual view returns (uint256) {
    return asset.balanceOf(address(this));
    
    }

    //converts asset amount to shares amount
    //note conversion rounds down for amount of shares returned
    function convertToShares(uint256 assets) public view returns (uint256) {
        //supply is total supply of shares
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.
        //if supply is 0, share amount is asset amount
        //else, share amount = [(asset amount)*(total shares)]/totalAssets
        //formula comes from (share amount)/(total shares) = (asset amount)/(totalAssets)
        return supply == 0 ? assets : assets.mulDivDown(supply, totalAssets());
    }

    //converts share amount to asset amount
    //note conversion rounds down for amount of assets returned
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        //if supply is 0, asset amount equals shares amount
        //else, asset amount = (share amount)*(totalAssets)/(total shares)
        return supply == 0 ? shares : shares.mulDivDown(totalAssets(), supply);
    }
    //returns a preview of share amount issued to user for given asset amount 
    //note amount returned is rounded down. 
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    //returns a preview of asset amount user must supply to receive a given amount of shares
    //note amount returned is rounded up here
    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : shares.mulDivUp(totalAssets(), supply);
    }

    //returns a preview of share amount user must supply to receive a given amount of asset
    //note amount returned is rounded up
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? assets : assets.mulDivUp(supply, totalAssets());
    }

    //returns a preview of asset amount issued to user for given share amount
    //note amount returned is rounded down
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /*//////////////////////////////////////////////////////////////
                     DEPOSIT/WITHDRAWAL LIMIT LOGIC
    //////////////////////////////////////////////////////////////*/

    //returns the largest possible amount of asset that can be deposited: 2^256
    function maxDeposit(address) public view returns (uint256) {
        return type(uint256).max;
    }

    //returns the largest possible amount of shares that can be minted: 2^256
    function maxMint(address) public view returns (uint256) {
        return type(uint256).max;
    }

    //returns the maximum amount the owner of an asset can withdraw
    //return amount is the asset balance of the owner (calculated by converting share amount to asset amount).
    function maxWithdraw(address owner) public view returns (uint256) {
        return convertToAssets(balanceOf[owner]);
    }

    //returns the maximum amount of shares that an owner can redeem
    //return amount is the share balance of the owner
    function maxRedeem(address owner) public view returns (uint256) {
        return balanceOf[owner];
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HOOKS LOGIC
    //////////////////////////////////////////////////////////////*/

    function beforeWithdraw(uint256 assets, uint256 shares) internal {}

    function afterDeposit(uint256 assets, uint256 shares) internal {}
}