// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC8416, IERC8416AsyncRedeem} from "./IERC8416.sol";
import {IERC7540Operator, IERC7540Redeem, IERC7575Share} from "./IERC7540.sol";
import {IFixedRateStrategy} from "./IFixedRateStrategy.sol";

/// @notice ERC-8416 vault: synchronous deposits, asynchronous redemptions.
/// @dev Interest accrues into `totalAssets` on every state-changing call.
contract FixedRateVault is
    ERC4626,
    Ownable,
    IERC8416AsyncRedeem,
    IERC7540Redeem,
    IERC7540Operator,
    IERC7575Share,
    IERC165
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct ClaimableRedeem {
        uint256 shares;
        uint256 assets;
    }

    struct Epoch {
        uint256 rate;
        uint256 maxDeposits;
        uint256 deposited;
        uint256 start;
        uint256 entryWindowEnd;
        uint256 accrualStart;
        uint256 accrualEnd;
        uint256 exitWindowStart;
        uint256 end;
    }

    uint256 private constant YEAR = 365 days;
    uint256 private constant WAD = 1e18;
    uint256 private constant REQUEST_ID = 0;
    bytes4 private constant ERC7575_INTERFACE_ID = 0x2f0a18c5;

    IFixedRateStrategy public immutable strategy;

    mapping(uint256 => Epoch) private _epochs;
    uint256 public epochCount;
    bool public isTerminated;

    // Principal plus interest accrued up to `_lastAccrual`.
    uint256 private _accruingAssets;
    uint256 private _lastAccrual;
    uint256 private _lastAccrualEpochId;

    // Shares escrowed by the vault awaiting fulfillment.
    mapping(address => uint256) private _pendingRedeem;
    // Fulfilled shares and the assets locked for them.
    mapping(address => ClaimableRedeem) private _claimableRedeem;
    uint256 private _totalClaimableAssets;

    mapping(address => mapping(address => bool)) public isOperator;

    error InvalidEpoch();
    error OutsideEntryWindow();
    error OutsideExitWindow();
    error EpochCapacityExceeded();
    error VaultTerminated();
    error CannotTerminate();
    error ExceededMaxRequestRedeem();
    error ExceededClaimable();
    error NotControllerOrOperator();
    error AsyncRedeem();
    error AllocationFailed(uint256 expected, uint256 actual);
    error DeallocationFailed(uint256 expected, uint256 actual);

    constructor(
        IERC20 asset_,
        IFixedRateStrategy strategy_,
        string memory name_,
        string memory symbol_,
        address owner_
    ) ERC20(name_, symbol_) ERC4626(asset_) Ownable(owner_) {
        strategy = strategy_;
    }

    function addEpoch(Epoch memory e) external onlyOwner {
        if (isTerminated) revert VaultTerminated();
        if (e.start < block.timestamp) revert InvalidEpoch();
        if (e.start >= e.end) revert InvalidEpoch();
        if (e.start < _epochs[epochCount].end) revert InvalidEpoch();
        if (e.entryWindowEnd < e.start || e.entryWindowEnd > e.end) revert InvalidEpoch();
        if (e.accrualStart < e.start || e.accrualEnd > e.end) revert InvalidEpoch();
        if (e.accrualStart > e.accrualEnd) revert InvalidEpoch();
        if (e.exitWindowStart < e.start || e.exitWindowStart > e.end) revert InvalidEpoch();

        e.deposited = 0;
        uint256 id = ++epochCount;
        _epochs[id] = e;

        emit EpochAdded(
            id,
            e.rate,
            e.maxDeposits,
            e.start,
            e.entryWindowEnd,
            e.accrualStart,
            e.accrualEnd,
            e.exitWindowStart,
            e.end
        );
    }

    /// @dev Allowed only after the last epoch ends; withdraws all funds from the strategy.
    function terminate() external onlyOwner {
        if (isTerminated) revert VaultTerminated();
        uint256 id = epochId();
        if (id != epochCount || (id != 0 && block.timestamp < _epochs[id].end)) revert CannotTerminate();
        _accrueInterest();
        _deallocate(_accruingAssets);
        isTerminated = true;
        emit Terminated();
    }

    /// @dev Latest started epoch, or 0 if none.
    function epochId() public view returns (uint256 id) {
        for (id = epochCount; id > 0; --id) {
            if (_epochs[id].start <= block.timestamp) return id;
        }
    }

    function rate(uint256 id) external view returns (uint256) {
        return _epochs[id].rate;
    }

    function maxEpochDeposits(uint256 id) external view returns (uint256) {
        return _epochs[id].maxDeposits;
    }

    function epochPeriod(uint256 id) external view returns (uint256, uint256) {
        return (_epochs[id].start, _epochs[id].end);
    }

    function entryWindow(uint256 id) external view returns (uint256, uint256) {
        return (_epochs[id].start, _epochs[id].entryWindowEnd);
    }

    function accrualInterval(uint256 id) external view returns (uint256, uint256) {
        return (_epochs[id].accrualStart, _epochs[id].accrualEnd);
    }

    function exitWindow(uint256 id) external view returns (uint256, uint256) {
        return (_epochs[id].exitWindowStart, _epochs[id].end);
    }

    function currentRate() external view returns (uint256) {
        Epoch storage e = _epochs[epochId()];
        if (block.timestamp < e.accrualStart || block.timestamp >= e.accrualEnd) return 0;
        return e.rate;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IERC8416).interfaceId ||
            interfaceId == type(IERC7540Redeem).interfaceId ||
            interfaceId == type(IERC7540Operator).interfaceId ||
            interfaceId == ERC7575_INTERFACE_ID ||
            interfaceId == type(IERC165).interfaceId;
    }

    function share() external view returns (address) {
        return address(this);
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function totalAssets() public view override returns (uint256) {
        return _accruingAssets + _pendingInterest();
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (!_inEntryWindow()) return 0;
        Epoch storage e = _epochs[epochId()];
        return e.maxDeposits > e.deposited ? e.maxDeposits - e.deposited : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 assets = maxDeposit(receiver);
        return assets == type(uint256).max ? type(uint256).max : convertToShares(assets);
    }

    function maxRequestRedeem(address owner) public view returns (uint256) {
        return _canExit() ? balanceOf(owner) : 0;
    }

    /// @dev Escrows `shares` until the owner fulfills them.
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256) {
        if (shares > maxRequestRedeem(owner)) revert ExceededMaxRequestRedeem();
        if (msg.sender != owner && !isOperator[owner][msg.sender]) _spendAllowance(owner, msg.sender, shares);
        _transfer(owner, address(this), shares);
        _pendingRedeem[controller] += shares;
        emit RedeemRequest(controller, owner, REQUEST_ID, msg.sender, shares);
        return REQUEST_ID;
    }

    /// @dev Prices the request at the current share price.
    function fulfillRedeem(address controller) external onlyOwner returns (uint256) {
        return _fulfillRedeem(controller);
    }

    // After termination, pending requests are reported as claimable.
    function pendingRedeemRequest(uint256, address controller) external view returns (uint256) {
        return isTerminated ? 0 : _pendingRedeem[controller];
    }

    function claimableRedeemRequest(uint256, address controller) external view returns (uint256) {
        return maxRedeem(controller);
    }

    function maxRedeem(address controller) public view override returns (uint256 shares) {
        shares = _claimableRedeem[controller].shares;
        if (isTerminated) shares += _pendingRedeem[controller];
    }

    function maxWithdraw(address controller) public view override returns (uint256 assets) {
        assets = _claimableRedeem[controller].assets;
        if (isTerminated) assets += _convertToAssets(_pendingRedeem[controller], Math.Rounding.Floor);
    }

    function previewRedeem(uint256) public pure override returns (uint256) {
        revert AsyncRedeem();
    }

    function previewWithdraw(uint256) public pure override returns (uint256) {
        revert AsyncRedeem();
    }

    function redeem(uint256 shares, address receiver, address controller) public override returns (uint256 assets) {
        ClaimableRedeem storage c = _claimable(controller);
        if (shares > c.shares) revert ExceededClaimable();
        assets = shares == c.shares ? c.assets : shares.mulDiv(c.assets, c.shares, Math.Rounding.Floor);
        _claim(c, receiver, controller, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address controller) public override returns (uint256 shares) {
        ClaimableRedeem storage c = _claimable(controller);
        if (assets > c.assets) revert ExceededClaimable();
        shares = assets == c.assets ? c.shares : assets.mulDiv(c.shares, c.assets, Math.Rounding.Ceil);
        _claim(c, receiver, controller, assets, shares);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (!_inEntryWindow()) revert OutsideEntryWindow();
        Epoch storage e = _epochs[epochId()];
        if (e.maxDeposits != type(uint256).max) {
            if (e.deposited + assets > e.maxDeposits) revert EpochCapacityExceeded();
            e.deposited += assets;
        }
        _accrueInterest();
        _accruingAssets += assets;
        super._deposit(caller, receiver, assets, shares);
        _allocate(assets);
    }

    /// @dev Checks the caller; after termination, fulfills pending shares on the spot.
    function _claimable(address controller) private returns (ClaimableRedeem storage) {
        if (controller != msg.sender && !isOperator[controller][msg.sender]) revert NotControllerOrOperator();
        if (isTerminated) _fulfillRedeem(controller);
        return _claimableRedeem[controller];
    }

    function _claim(
        ClaimableRedeem storage c,
        address receiver,
        address controller,
        uint256 assets,
        uint256 shares
    ) private {
        c.shares -= shares;
        c.assets -= assets;
        _totalClaimableAssets -= assets;
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function _fulfillRedeem(address controller) private returns (uint256 assets) {
        uint256 shares = _pendingRedeem[controller];
        if (shares == 0) return 0;
        _accrueInterest();
        assets = _convertToAssets(shares, Math.Rounding.Floor);
        _pendingRedeem[controller] = 0;
        _accruingAssets -= assets;
        _totalClaimableAssets += assets;
        _claimableRedeem[controller].shares += shares;
        _claimableRedeem[controller].assets += assets;
        _burn(address(this), shares);
        if (!isTerminated) _deallocate(assets);
    }

    /// @dev The strategy must pull exactly `assets`.
    function _allocate(uint256 assets) private {
        if (assets == 0) return;
        IERC20 token = IERC20(asset());
        uint256 balance = token.balanceOf(address(this));
        token.forceApprove(address(strategy), assets);
        strategy.allocate(assets);
        token.forceApprove(address(strategy), 0);
        uint256 actual = balance - token.balanceOf(address(this));
        if (actual != assets) revert AllocationFailed(assets, actual);
    }

    /// @dev The strategy must return exactly `assets`.
    function _deallocate(uint256 assets) private {
        if (assets == 0) return;
        IERC20 token = IERC20(asset());
        uint256 balance = token.balanceOf(address(this));
        strategy.deallocate(assets);
        uint256 actual = token.balanceOf(address(this)) - balance;
        if (actual != assets) revert DeallocationFailed(assets, actual);
    }

    /// @dev Folds pending interest into `_accruingAssets` and moves the checkpoint.
    function _accrueInterest() private {
        uint256 pending = _pendingInterest();
        _lastAccrual = block.timestamp;
        _lastAccrualEpochId = epochId();
        if (pending == 0) return;
        _accruingAssets += pending;
    }

    /// @dev Interest since `_lastAccrual`, across every epoch's accrual interval.
    function _pendingInterest() private view returns (uint256 interest) {
        if (_accruingAssets == 0 || totalSupply() == 0) return 0;
        uint256 current = epochId();
        for (uint256 id = _lastAccrualEpochId == 0 ? 1 : _lastAccrualEpochId; id <= current; ++id) {
            Epoch storage e = _epochs[id];
            uint256 from = Math.max(e.accrualStart, _lastAccrual);
            uint256 to = Math.min(block.timestamp, e.accrualEnd);
            if (from >= to) continue;
            interest += ((_accruingAssets + interest) * e.rate * (to - from)) / (YEAR * WAD);
        }
    }

    function _inEntryWindow() private view returns (bool) {
        if (isTerminated) return false;
        uint256 id = epochId();
        if (id == 0) return false;
        Epoch storage e = _epochs[id];
        return block.timestamp >= e.start && block.timestamp < e.entryWindowEnd;
    }

    function _canExit() private view returns (bool) {
        if (isTerminated) return true;
        uint256 id = epochId();
        if (id == 0) return false;
        Epoch storage e = _epochs[id];
        return block.timestamp >= e.exitWindowStart && block.timestamp < e.end;
    }
}
