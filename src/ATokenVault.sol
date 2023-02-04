// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

// Upgradeability
import {ERC4626Upgradeable} from "openzeppelin/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin/access/OwnableUpgradeable.sol";
import {SafeERC20Upgradeable} from "openzeppelin/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {IERC20Upgradeable} from "openzeppelin/interfaces/IERC20Upgradeable.sol";
import {EIP712Upgradeable} from "openzeppelin/utils/cryptography/EIP712Upgradeable.sol";
import {MathUpgradeable} from "openzeppelin/utils/math/MathUpgradeable.sol";

import {WadRayMath} from "aave/protocol/libraries/math/WadRayMath.sol";
import {DataTypes as AaveDataTypes} from "aave/protocol/libraries/types/DataTypes.sol";
import {IPoolAddressesProvider} from "aave/interfaces/IPoolAddressesProvider.sol";
import {IRewardsController} from "aave-periphery/rewards/interfaces/IRewardsController.sol";
import {IPool} from "aave/interfaces/IPool.sol";
import {IAToken} from "aave/interfaces/IAToken.sol";

// Interface
import {IATokenVaultEvents} from "./interfaces/IATokenVaultEvents.sol";
import {IATokenVaultTypes} from "./interfaces/IATokenVaultTypes.sol";

// Libraries
import {MetaTxHelpers} from "./libraries/MetaTxHelpers.sol";
import "./libraries/Constants.sol";

/**
 * @title ATokenVault
 * @author Aave Protocol
 *
 * @notice An ERC-4626 vault for ERC20 assets supported by Aave v3, with a potential
 * vault fee on yield earned. Some alterations override the base implementation.
 * Fees are accrued and claimable as aTokens.
 */
contract ATokenVault is ERC4626Upgradeable, OwnableUpgradeable, EIP712Upgradeable, IATokenVaultEvents, IATokenVaultTypes {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using MathUpgradeable for uint256;
    // using FixedPointMathLib for uint256;

    IPoolAddressesProvider public immutable POOL_ADDRESSES_PROVIDER;
    IPool public immutable AAVE_POOL;
    IAToken public immutable ATOKEN;
    IERC20Upgradeable public immutable UNDERLYING;
    uint16 public immutable REFERRAL_CODE;

    mapping(address => uint256) internal _sigNonces;

    uint256 internal _lastUpdated; // timestamp of last accrueYield action
    uint256 internal _lastVaultBalance; // total aToken incl. fees
    uint256 internal _fee; // as a fraction of 1e18
    uint256 internal _accumulatedFees; // fees accrued since last updated

    /**
     * @param underlying The underlying ERC20 asset which can be supplied to Aave
     * @param referralCode The Aave referral code to use for deposits from this vault
     * @param poolAddressesProvider The address of the Aave v3 Pool Addresses Provider
     */
    constructor(
        address underlying,
        uint16 referralCode,
        IPoolAddressesProvider poolAddressesProvider
    ) {
        _disableInitializers();
        POOL_ADDRESSES_PROVIDER = poolAddressesProvider;
        AAVE_POOL = IPool(poolAddressesProvider.getPool());
        REFERRAL_CODE = referralCode;
        UNDERLYING = IERC20Upgradeable(underlying);

        address aTokenAddress = AAVE_POOL.getReserveData(address(underlying)).aTokenAddress;
        require(aTokenAddress != address(0), "ASSET_NOT_SUPPORTED");
        ATOKEN = IAToken(aTokenAddress);
    }


    /** 
     * @notice Initializes the vault, setting the initial parameters and initializing inherited 
     * contracts. This also requires an initial non-zero deposit to prevent a frontrunning attack.
     * This deposit is done in underlying tokens, not aTokens.
     *
     * Note that care should be taken to provide a non-trivial amount, but this depends on the 
     * underlying asset's decimals.
     *
     * Note that we do not initialize the OwnableUpgradeable contract to avoid setting the proxy
     * admin as the owner.
     *
     * @param owner The owner to set
     * @param initialFee The initial fee to set, expressed in wad, where 1e18 is 100%
     * @param shareName The name to set for this vault
     * @param shareSymbol The symbol to set for this vault
     * @param initialLockDeposit The initial amount of underlying assets to deposit
     */
    function initialize(
        address owner,
        uint256 initialFee,
        string memory shareName,
        string memory shareSymbol,
        uint256 initialLockDeposit
    ) external initializer {
        require(initialLockDeposit != 0, "ZERO_INITIAL_LOCK_DEPOSIT");
        _transferOwnership(owner);
        __ERC4626_init(UNDERLYING);
        __ERC20_init(shareName, shareSymbol);
        __EIP712_init(shareName, "1");
        _setFee(initialFee);
        UNDERLYING.safeApprove(address(AAVE_POOL), type(uint256).max);

        // Execute initial deposit and burn to prevent frontrun attack.
        _handleDeposit(initialLockDeposit, address(this), msg.sender, false);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits a specified amount of assets into the vault, minting a corresponding amount of shares.
     *
     * @param assets The amount of underlying asset to deposit
     * @param receiver The address to receive the shares
     *
     * @return shares The amount of shares minted to the receiver
     */
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        shares = _handleDeposit(assets, receiver, msg.sender, false);
    }

    /**
     * @notice Deposits a specified amount of aToken assets into the vault, minting a corresponding amount of
     * shares.
     *
     * @param assets The amount of aToken assets to deposit
     * @param receiver The address to receive the shares
     *
     * @return shares The amount of shares minted to the receiver
     */
    function depositATokens(uint256 assets, address receiver) public returns (uint256 shares) {
        shares = _handleDeposit(assets, receiver, msg.sender, true);
    }

    /**
     * @notice Deposits a specified amount of assets into the vault, minting a corresponding amount of shares,
     * using an EIP712 signature to enable a third-party to call this function on behalf of the depositor.
     *
     * @param assets The amount of underlying asset to deposit
     * @param receiver The address to receive the shares
     * @param depositor The address from which to pull the assets for the deposit
     * @param sig An EIP712 signature from the depositor to allow this function to be called on their behalf
     *
     * @return shares The amount of shares minted to the receiver
     */
    function depositWithSig(
        uint256 assets,
        address receiver,
        address depositor,
        EIP712Signature calldata sig
    ) public returns (uint256 shares) {
        unchecked {
            MetaTxHelpers._validateRecoveredAddress(
                MetaTxHelpers._calculateDigest(
                    keccak256(
                        abi.encode(
                            DEPOSIT_WITH_SIG_TYPEHASH,
                            assets,
                            receiver,
                            depositor,
                            _sigNonces[depositor]++,
                            sig.deadline
                        )
                    ),
                    _domainSeparatorV4()
                ),
                depositor,
                sig
            );
        }
        shares = _handleDeposit(assets, receiver, depositor, false);
    }

    /**
     * @notice Deposits a specified amount of aToken assets into the vault, minting a corresponding amount of
     * shares, using an EIP712 signature to enable a third-party to call this function on behalf of the depositor.
     *
     * @param assets The amount of aToken assets to deposit
     * @param receiver The address to receive the shares
     * @param depositor The address from which to pull the aToken assets for the deposit
     * @param sig An EIP712 signature from the depositor to allow this function to be called on their behalf
     *
     * @return shares The amount of shares minted to the receiver
     */
    function depositATokensWithSig(
        uint256 assets,
        address receiver,
        address depositor,
        EIP712Signature calldata sig
    ) public returns (uint256 shares) {
        unchecked {
            MetaTxHelpers._validateRecoveredAddress(
                MetaTxHelpers._calculateDigest(
                    keccak256(
                        abi.encode(
                            DEPOSIT_ATOKENS_WITH_SIG_TYPEHASH,
                            assets,
                            receiver,
                            depositor,
                            _sigNonces[depositor]++,
                            sig.deadline
                        )
                    ),
                    _domainSeparatorV4()
                ),
                depositor,
                sig
            );
        }
        shares = _handleDeposit(assets, receiver, depositor, true);
    }

    /**
     * @notice Mints a specified amount of shares to the receiver, depositing the corresponding amount of assets.
     *
     * @param shares The amount of shares to mint
     * @param receiver The address to receive the shares
     *
     * @return assets The amount of assets deposited by the caller
     */
    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        assets = _handleMint(shares, receiver, msg.sender, false);
    }

    /**
     * @notice Mints a specified amount of shares to the receiver, depositing the corresponding amount of aToken
     * assets.
     *
     * @param shares The amount of shares to mint
     * @param receiver The address to receive the shares
     *
     * @return assets The amount of aToken assets deposited by the caller
     */
    function mintWithATokens(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = _handleMint(shares, receiver, msg.sender, true);
    }

    /**
     * @notice Mints a specified amount of shares to the receiver, depositing the corresponding amount of assets,
     * using an EIP712 signature to enable a third-party to call this function on behalf of the depositor.
     *
     * @param shares The amount of shares to mint
     * @param receiver The address to receive the shares
     * @param depositor The address from which to pull the assets for the deposit
     * @param sig An EIP712 signature from the depositor to allow this function to be called on their behalf
     *
     * @return assets The amount of assets deposited by the depositor
     */
    function mintWithSig(
        uint256 shares,
        address receiver,
        address depositor,
        EIP712Signature calldata sig
    ) public returns (uint256 assets) {
        unchecked {
            MetaTxHelpers._validateRecoveredAddress(
                MetaTxHelpers._calculateDigest(
                    keccak256(
                        abi.encode(MINT_WITH_SIG_TYPEHASH, shares, receiver, depositor, _sigNonces[depositor]++, sig.deadline)
                    ),
                    _domainSeparatorV4()
                ),
                depositor,
                sig
            );
        }
        assets = _handleMint(shares, receiver, depositor, false);
    }

    /**
     * @notice Mints a specified amount of shares to the receiver, depositing the corresponding amount of aToken
     * assets, using an EIP712 signature to enable a third-party to call this function on behalf of the depositor.
     *
     * @param shares The amount of shares to mint
     * @param receiver The address to receive the shares
     * @param depositor The address from which to pull the aToken assets for the deposit
     * @param sig An EIP712 signature from the depositor to allow this function to be called on their behalf
     *
     * @return assets The amount of aToken assets deposited by the depositor
     */
    function mintWithATokensWithSig(
        uint256 shares,
        address receiver,
        address depositor,
        EIP712Signature calldata sig
    ) public returns (uint256 assets) {
        unchecked {
            MetaTxHelpers._validateRecoveredAddress(
                MetaTxHelpers._calculateDigest(
                    keccak256(
                        abi.encode(
                            MINT_WITH_ATOKENS_WITH_SIG_TYPEHASH,
                            shares,
                            receiver,
                            depositor,
                            _sigNonces[depositor]++,
                            sig.deadline
                        )
                    ),
                    _domainSeparatorV4()
                ),
                depositor,
                sig
            );
        }
        assets = _handleMint(shares, receiver, depositor, true);
    }

    /**
     * @notice Withdraws a specified amount of assets from the vault, burning the corresponding amount of shares.
     *
     * @param assets The amount of assets to withdraw
     * @param receiver The address to receive the assets
     * @param owner The address from which to pull the shares for the withdrawal
     *
     * @return shares The amount of shares burnt in the withdrawal process
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256 shares) {
        shares = _handleWithdraw(assets, receiver, owner, msg.sender, false);
    }

    /**
     * @notice Withdraws a specified amount of aToken assets from the vault, burning the corresponding amount of
     * shares.
     *
     * @param assets The amount of aToken assets to withdraw
     * @param receiver The address to receive the aToken assets
     * @param owner The address from which to pull the shares for the withdrawal
     *
     * @return shares The amount of shares burnt in the withdrawal process
     */
    function withdrawATokens(
        uint256 assets,
        address receiver,
        address owner
    ) public returns (uint256 shares) {
        shares = _handleWithdraw(assets, receiver, owner, msg.sender, true);
    }

    /**
     * @notice Withdraws a specified amount of assets from the vault, burning the corresponding amount of shares,
     * using an EIP712 signature to enable a third-party to call this function on behalf of the owner.
     *
     * @param assets The amount of assets to withdraw
     * @param receiver The address to receive the assets
     * @param owner The address from which to pull the shares for the withdrawal
     * @param sig An EIP712 signature from the owner to allow this function to be called on their behalf
     *
     * @return shares The amount of shares burnt in the withdrawal process
     */
    function withdrawWithSig(
        uint256 assets,
        address receiver,
        address owner,
        EIP712Signature calldata sig
    ) public returns (uint256 shares) {
        unchecked {
            MetaTxHelpers._validateRecoveredAddress(
                MetaTxHelpers._calculateDigest(
                    keccak256(
                        abi.encode(WITHDRAW_WITH_SIG_TYPEHASH, assets, receiver, owner, _sigNonces[owner]++, sig.deadline)
                    ),
                    _domainSeparatorV4()
                ),
                owner,
                sig
            );
        }
        shares = _handleWithdraw(assets, receiver, owner, owner, false);
    }

    /**
     * @notice Withdraws a specified amount of aToken assets from the vault, burning the corresponding amount of
     * shares, using an EIP712 signature to enable a third-party to call this function on behalf of the owner.
     *
     * @param assets The amount of aToken assets to withdraw
     * @param receiver The address to receive the aToken assets
     * @param owner The address from which to pull the shares for the withdrawal
     * @param sig An EIP712 signature from the owner to allow this function to be called on their behalf
     *
     * @return shares The amount of shares burnt in the withdrawal process
     */
    function withdrawATokensWithSig(
        uint256 assets,
        address receiver,
        address owner,
        EIP712Signature calldata sig
    ) public returns (uint256 shares) {
        unchecked {
            MetaTxHelpers._validateRecoveredAddress(
                MetaTxHelpers._calculateDigest(
                    keccak256(
                        abi.encode(
                            WITHDRAW_ATOKENS_WITH_SIG_TYPEHASH,
                            assets,
                            receiver,
                            owner,
                            _sigNonces[owner]++,
                            sig.deadline
                        )
                    ),
                    _domainSeparatorV4()
                ),
                owner,
                sig
            );
        }
        shares = _handleWithdraw(assets, receiver, owner, owner, true);
    }

    /**
     * @notice Burns a specified amount of shares from the vault, withdrawing the corresponding amount of assets.
     *
     * @param shares The amount of shares to burn
     * @param receiver The address to receive the assets
     * @param owner The address from which to pull the shares for the withdrawal
     *
     * @return assets The amount of assets withdrawn by the receiver
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256 assets) {
        assets = _handleRedeem(shares, receiver, owner, msg.sender, false);
    }

    /**
     * @notice Burns a specified amount of shares from the vault, withdrawing the corresponding amount of aToken
     * assets.
     *
     * @param shares The amount of shares to burn
     * @param receiver The address to receive the aToken assets
     * @param owner The address from which to pull the shares for the withdrawal
     *
     * @return assets The amount of aToken assets withdrawn by the receiver
     */
    function redeemAsATokens(
        uint256 shares,
        address receiver,
        address owner
    ) public returns (uint256 assets) {
        assets = _handleRedeem(shares, receiver, owner, msg.sender, true);
    }

    /**
     * @notice Burns a specified amount of shares from the vault, withdrawing the corresponding amount of assets,
     * using an EIP712 signature to enable a third-party to call this function on behalf of the owner.
     *
     * @param shares The amount of shares to burn
     * @param receiver The address to receive the assets
     * @param owner The address from which to pull the shares for the withdrawal
     * @param sig An EIP712 signature from the owner to allow this function to be called on their behalf
     *
     * @return assets The amount of assets withdrawn by the receiver
     */
    function redeemWithSig(
        uint256 shares,
        address receiver,
        address owner,
        EIP712Signature calldata sig
    ) public returns (uint256 assets) {
        unchecked {
            MetaTxHelpers._validateRecoveredAddress(
                MetaTxHelpers._calculateDigest(
                    keccak256(abi.encode(REDEEM_WITH_SIG_TYPEHASH, shares, receiver, owner, _sigNonces[owner]++, sig.deadline)),
                    _domainSeparatorV4()
                ),
                owner,
                sig
            );
        }
        assets = _handleRedeem(shares, receiver, owner, owner, false);
    }

    /**
     * @notice Burns a specified amount of shares from the vault, withdrawing the corresponding amount of aToken
     * assets, using an EIP712 signature to enable a third-party to call this function on behalf of the owner.
     *
     * @param shares The amount of shares to burn
     * @param receiver The address to receive the aToken assets
     * @param owner The address from which to pull the shares for the withdrawal
     * @param sig An EIP712 signature from the owner to allow this function to be called on their behalf
     *
     * @return assets The amount of aToken assets withdrawn by the receiver
     */
    function redeemWithATokensWithSig(
        uint256 shares,
        address receiver,
        address owner,
        EIP712Signature calldata sig
    ) public returns (uint256 assets) {
        unchecked {
            MetaTxHelpers._validateRecoveredAddress(
                MetaTxHelpers._calculateDigest(
                    keccak256(
                        abi.encode(
                            REDEEM_WITH_ATOKENS_WITH_SIG_TYPEHASH,
                            shares,
                            receiver,
                            owner,
                            _sigNonces[owner]++,
                            sig.deadline
                        )
                    ),
                    _domainSeparatorV4()
                ),
                owner,
                sig
            );
        }
        assets = _handleRedeem(shares, receiver, owner, owner, true);
    }

    /**
     * @notice Maximum amount of assets that can be deposited into the vault,
     * given Aave market limitations.
     *
     * @return Maximum amount of assets that can be deposited into the vault
     */
    function maxDeposit(address) public view override returns (uint256) {
        return _maxAssetsSuppliableToAave();
    }

    /**
     * @notice Maximum amount of shares that can be minted for the vault,
     * given Aave market limitations.
     *
     * @return Maximum amount of shares that can be minted for the vault
     */
    function maxMint(address) public view override returns (uint256) {
        return convertToShares(_maxAssetsSuppliableToAave());
    }

    /**
     * @notice returns the domain separator.
     *
     * @return Domain separator
     */
    function domainSeparator() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /*//////////////////////////////////////////////////////////////
                          ONLY OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the fee the vault levies on yield earned, only callable by the owner.
     *
     * @param newFee The new fee to set, expressed in wad, where 1e18 is 100%
     */
    function setFee(uint256 newFee) public onlyOwner {
        _accrueYield();
        _setFee(newFee);
    }

    /**
     * @notice Withdraws fees earned by the vault, in the form of aTokens, to a specified address. Only callable by the owner.
     *
     * @param to The address to receive the fees
     * @param amount The amount of fees to withdraw
     */
    function withdrawFees(address to, uint256 amount) public onlyOwner {
        uint256 claimableFees = getClaimableFees();
        require(amount <= claimableFees, "INSUFFICIENT_FEES"); // will underflow below anyway, error msg for clarity

        _accumulatedFees = claimableFees - amount;
        _lastVaultBalance = ATOKEN.balanceOf(address(this)) - amount;
        _lastUpdated = block.timestamp;

        ATOKEN.transfer(to, amount);

        emit FeesWithdrawn(to, amount, _lastVaultBalance, _accumulatedFees);
    }

    /**
     * @notice Claims any additional Aave rewards earned from vault deposits. Only callable by the owner.
     *
     * @param to The address to receive any rewards tokens
     */
    function claimRewards(address to) public onlyOwner {
        require(to != address(0), "CANNOT_CLAIM_TO_ZERO_ADDRESS");

        address[] memory assets = new address[](1);
        assets[0] = address(ATOKEN);
        (address[] memory rewardsList, uint256[] memory claimedAmounts) = IRewardsController(
            POOL_ADDRESSES_PROVIDER.getAddress(REWARDS_CONTROLLER_ID)
        ).claimAllRewards(assets, to);

        emit RewardsClaimed(to, rewardsList, claimedAmounts);
    }

    /**
     * @notice Allows the owner to rescue any tokens other than the vault's aToken which may have accidentally
     * been transferred to this contract
     *
     * @param token The address of the token to rescue
     * @param to The address to receive rescued tokens
     * @param amount The amount of tokens to transfer
     */
    function emergencyRescue(
        address token,
        address to,
        uint256 amount
    ) public onlyOwner {
        require(token != address(ATOKEN), "CANNOT_RESCUE_ATOKEN");

        IERC20Upgradeable(token).safeTransfer(to, amount);

        emit EmergencyRescue(token, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the total assets less claimable fees.
     *
     * @return The total assets less claimable fees
     */
    function totalAssets() public view override returns (uint256) {
        // Report only the total assets net of fees, for vault share logic
        return ATOKEN.balanceOf(address(this)) - getClaimableFees();
    }

    /**
     * @notice Returns the claimable fees.
     *
     * @return The claimable fees
     */
    function getClaimableFees() public view returns (uint256) {
        if (block.timestamp == _lastUpdated) {
            // Accumulated fees already up to date
            return _accumulatedFees;
        } else {
            // Calculate new fees since last accrueYield
            uint256 newVaultBalance = ATOKEN.balanceOf(address(this));
            uint256 newYield = newVaultBalance - _lastVaultBalance;
            uint256 newFees = newYield.mulDiv(_fee, SCALE, MathUpgradeable.Rounding.Down);

            return _accumulatedFees + newFees;
        }
    }

    /** 
     * @notice Returns the signing nonce for meta-transactions for the given signer.
     *
     * @return The passed signer's nonce
     */
    function getSigNonce(address signer) public view returns (uint256) {
        return _sigNonces[signer];
    }

    /** 
     * @notice Returns the latest timestamp where yield was accrued.
     *
     * @return The last update timestamp
     */
    function getLastUpdated() public view returns (uint256) {
        return _lastUpdated;
    }

    /** 
     * @notice Returns the vault balance at the latest update timestamp.
     *
     * @return The latest vault balance
     */
    function getLastVaultBalance() public view returns (uint256) {
        return _lastVaultBalance;
    }

    /** 
     * @notice Returns the current fee ratio.
     *
     * @return The current fee ratio, expressed in wad, where 1e18 is 100%
     */
    function getFee() public view returns (uint256) {
        return _fee;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _setFee(uint256 newFee) internal {
        require(newFee <= SCALE, "FEE_TOO_HIGH");

        uint256 oldFee = _fee;
        _fee = newFee;

        emit FeeUpdated(oldFee, newFee);
    }

    function _accrueYield() internal {
        if (block.timestamp != _lastUpdated) {
            uint256 newVaultBalance = ATOKEN.balanceOf(address(this));
            uint256 newYield = newVaultBalance - _lastVaultBalance;
            uint256 newFeesEarned = newYield.mulDiv(_fee, SCALE, MathUpgradeable.Rounding.Down);

            _accumulatedFees += newFeesEarned;
            _lastVaultBalance = newVaultBalance;
            _lastUpdated = block.timestamp;

            emit YieldAccrued(newYield, newFeesEarned, newVaultBalance);
        }
    }

    function _handleDeposit(
        uint256 assets,
        address receiver,
        address depositor,
        bool asAToken
    ) internal returns (uint256 shares) {
        _accrueYield();
        shares = previewDeposit(assets);
        require(shares != 0, "ZERO_SHARES"); // Check for rounding error since we round down in previewDeposit.
        _baseDeposit(assets, shares, depositor, receiver, asAToken);
    }

    function _handleMint(
        uint256 shares,
        address receiver,
        address depositor,
        bool asAToken
    ) internal returns (uint256 assets) {
        _accrueYield();
        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.
        _baseDeposit(assets, shares, depositor, receiver, asAToken);
    }

    function _handleWithdraw(
        uint256 assets,
        address receiver,
        address owner,
        address allowanceTarget,
        bool asAToken
    ) internal returns (uint256 shares) {
        _accrueYield();
        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.
        _baseWithdraw(assets, shares, owner, receiver, allowanceTarget, asAToken);
    }

    function _handleRedeem(
        uint256 shares,
        address receiver,
        address owner,
        address allowanceTarget,
        bool asAToken
    ) internal returns (uint256 assets) {
        _accrueYield();
        assets = previewRedeem(shares);
        require(assets != 0, "ZERO_ASSETS"); // Check for rounding error since we round down in previewRedeem.
        _baseWithdraw(assets, shares, owner, receiver, allowanceTarget, asAToken);
    }

    function _maxAssetsSuppliableToAave() internal view returns (uint256) {
        // returns 0 if reserve is not active, frozen, or paused
        // returns max uint256 value if supply cap is 0 (not capped)
        // returns supply cap - current amount supplied as max suppliable if there is a supply cap for this reserve

        AaveDataTypes.ReserveData memory reserveData = AAVE_POOL.getReserveData(address(UNDERLYING));

        uint256 reserveConfigMap = reserveData.configuration.data;
        uint256 supplyCap = (reserveConfigMap & ~AAVE_SUPPLY_CAP_MASK) >> AAVE_SUPPLY_CAP_BIT_POSITION;

        if (
            (reserveConfigMap & ~AAVE_ACTIVE_MASK == 0) ||
            (reserveConfigMap & ~AAVE_FROZEN_MASK != 0) ||
            (reserveConfigMap & ~AAVE_PAUSED_MASK != 0)
        ) {
            return 0;
        } else if (supplyCap == 0) {
            return type(uint256).max;
        } else {
            // Reserve's supply cap - current amount supplied
            // See similar logic in Aave v3 ValidationLogic library, in the validateSupply function
            // https://github.com/aave/aave-v3-core/blob/a00f28e3ad7c0e4a369d8e06e0ac9fd0acabcab7/contracts/protocol/libraries/logic/ValidationLogic.sol#L71-L78
            return
                (supplyCap * 10**decimals()) -
                WadRayMath.rayMul(
                    (ATOKEN.scaledTotalSupply() + uint256(reserveData.accruedToTreasury)),
                    reserveData.liquidityIndex
                );
        }
    }

    function _baseDeposit(
        uint256 assets,
        uint256 shares,
        address depositor,
        address receiver,
        bool asAToken
    ) private {
        // Need to transfer before minting or ERC777s could reenter.
        if (asAToken) {
            ATOKEN.transferFrom(depositor, address(this), assets);
        } else {
            UNDERLYING.safeTransferFrom(depositor, address(this), assets);
            AAVE_POOL.supply(address(UNDERLYING), assets, address(this), REFERRAL_CODE);
        }

        _lastVaultBalance += assets;
        _mint(receiver, shares);

        emit Deposit(depositor, receiver, assets, shares);
    }

    function _baseWithdraw(
        uint256 assets,
        uint256 shares,
        address owner,
        address receiver,
        address allowanceTarget,
        bool asAToken
    ) private {
        if (allowanceTarget != owner) {
            _spendAllowance(owner, allowanceTarget, shares);
        }

        _lastVaultBalance -= assets;
        _burn(owner, shares);

        // Withdraw assets from Aave v3 and send to receiver
        if (asAToken) {
            ATOKEN.transfer(receiver, assets);
        } else {
            AAVE_POOL.withdraw(address(UNDERLYING), assets, receiver);
        }

        emit Withdraw(allowanceTarget, receiver, owner, assets, shares);
    }
}
