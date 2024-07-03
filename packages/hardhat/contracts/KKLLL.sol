// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract KKLLL is ERC20, Ownable, Pausable, ReentrancyGuard {
    using SafeMath for uint256;

    uint256 private immutable INITIAL_SUPPLY;

    struct VestingTier {
        uint256 cliffPeriod;
        uint256 duration;
        uint256 releaseRate;
    }

    struct VestingSchedule {
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 startTime;
        uint256 lastClaimTime;
        uint256 tierId;
    }

    VestingTier[] public vestingTiers;
    mapping(address => VestingSchedule) public vestingSchedules;
    mapping(address => bool) public whitelist;

    event TokensVested(address indexed beneficiary, uint256 amount);
    event VestingScheduleCreated(address indexed beneficiary, uint256 amount, uint256 tierId);
    event VestingTierCreated(uint256 tierId, uint256 cliffPeriod, uint256 duration, uint256 releaseRate);
    event AddressWhitelisted(address indexed account);
    event AddressRemovedFromWhitelist(address indexed account);
    event EmergencyWithdraw(address indexed owner, uint256 amount);

    constructor(string memory name_, string memory symbol_, uint256 initialSupply_) ERC20(name_, symbol_) {
        INITIAL_SUPPLY = initialSupply_ * 10**decimals();
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    modifier onlyWhitelisted(address account) {
        require(whitelist[account], "Account is not whitelisted");
        _;
    }

    function mint(address to, uint256 amount) public onlyOwner onlyWhitelisted(to) {
        _mint(to, amount);
    }

    function burn(uint256 amount) public onlyWhitelisted(msg.sender) {
        _burn(msg.sender, amount);
    }

    function createVestingTier(uint256 cliffPeriod, uint256 duration, uint256 releaseRate) public onlyOwner {
        require(duration > 0, "Duration must be greater than zero");
        require(releaseRate > 0 && releaseRate <= 10000, "Release rate must be between 1 and 10000 basis points");
        
        vestingTiers.push(VestingTier({
            cliffPeriod: cliffPeriod,
            duration: duration,
            releaseRate: releaseRate
        }));

        emit VestingTierCreated(vestingTiers.length - 1, cliffPeriod, duration, releaseRate);
    }

    function createVestingSchedule(
        address beneficiary,
        uint256 amount,
        uint256 startTime,
        uint256 tierId
    ) public onlyOwner onlyWhitelisted(beneficiary) {
        require(beneficiary != address(0), "Beneficiary address cannot be zero");
        require(amount > 0, "Vesting amount must be greater than zero");
        require(tierId < vestingTiers.length, "Invalid vesting tier");
        require(vestingSchedules[beneficiary].totalAmount == 0, "Vesting schedule already exists");

        vestingSchedules[beneficiary] = VestingSchedule({
            totalAmount: amount,
            releasedAmount: 0,
            startTime: startTime,
            lastClaimTime: startTime,
            tierId: tierId
        });

        _transfer(msg.sender, address(this), amount);

        emit VestingScheduleCreated(beneficiary, amount, tierId);
    }

    function releaseVestedTokens(address beneficiary) public whenNotPaused onlyWhitelisted(beneficiary) nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[beneficiary];
        require(schedule.totalAmount > 0, "No vesting schedule found");

        uint256 vestedAmount = calculateVestedAmount(beneficiary);
        uint256 releaseableAmount = vestedAmount.sub(schedule.releasedAmount);

        require(releaseableAmount > 0, "No tokens available for release");

        schedule.releasedAmount = schedule.releasedAmount.add(releaseableAmount);
        schedule.lastClaimTime = block.timestamp;
        _transfer(address(this), beneficiary, releaseableAmount);

        emit TokensVested(beneficiary, releaseableAmount);
    }

    function calculateVestedAmount(address beneficiary) public view returns (uint256) {
        VestingSchedule memory schedule = vestingSchedules[beneficiary];
        VestingTier memory tier = vestingTiers[schedule.tierId];

        if (block.timestamp <= schedule.startTime.add(tier.cliffPeriod)) {
            return 0;
        }

        uint256 elapsedTime = block.timestamp.sub(schedule.lastClaimTime);
        uint256 vestingDuration = tier.duration;

        if (schedule.lastClaimTime.add(vestingDuration) <= block.timestamp) {
            return schedule.totalAmount;
        }

        uint256 vestedAmount = schedule.totalAmount.mul(elapsedTime).mul(tier.releaseRate).div(vestingDuration).div(10000);
        return vestedAmount.add(schedule.releasedAmount);
    }

    function getVestingSchedule(address beneficiary) public view returns (
        uint256 totalAmount,
        uint256 releasedAmount,
        uint256 startTime,
        uint256 lastClaimTime,
        uint256 tierId
    ) {
        VestingSchedule memory schedule = vestingSchedules[beneficiary];
        return (
            schedule.totalAmount,
            schedule.releasedAmount,
            schedule.startTime,
            schedule.lastClaimTime,
            schedule.tierId
        );
    }

    function getVestingTier(uint256 tierId) public view returns (
        uint256 cliffPeriod,
        uint256 duration,
        uint256 releaseRate
    ) {
        require(tierId < vestingTiers.length, "Invalid vesting tier");
        VestingTier memory tier = vestingTiers[tierId];
        return (tier.cliffPeriod, tier.duration, tier.releaseRate);
    }

    function addToWhitelist(address account) public onlyOwner {
        require(account != address(0), "Cannot whitelist zero address");
        whitelist[account] = true;
        emit AddressWhitelisted(account);
    }

    function removeFromWhitelist(address account) public onlyOwner {
        require(account != address(0), "Cannot remove zero address from whitelist");
        whitelist[account] = false;
        emit AddressRemovedFromWhitelist(account);
    }

    function transfer(address recipient, uint256 amount) public virtual override onlyWhitelisted(recipient) returns (bool) {
        return super.transfer(recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) public virtual override onlyWhitelisted(recipient) returns (bool) {
        return super.transferFrom(sender, recipient, amount);
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function emergencyWithdraw() public onlyOwner nonReentrant {
        uint256 balance = balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");
        _transfer(address(this), owner(), balance);
        emit EmergencyWithdraw(owner(), balance);
    }
}