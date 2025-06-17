// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./BalanceTransfer.sol";
import "./StakingInterface.sol";
import "./MetagraphInterface.sol";
import './BLAKE2b.sol';

/// @title AlphaYieldPool
/// @notice Represents a pooled Alpha position in Bittensor.  Users:
///
///  • **depositTao(WithLimit)**   — send native TAO to the contract → stake → mint pool tokens
///  • **withdrawAsTao(WithLimit)**   — burn pool tokens → redeem TAO rewards
///  • **withdrawAsAlpha** — burn pool tokens → redeem Alpha rewards
contract AlphaYieldPool is ERC20, ERC20Permit, ReentrancyGuard {

    uint256 DECIMAL_SCALE_FACTOR = 10**9;

    IStaking public immutable staking;
    IMetagraph public immutable metagraph;
    ISubtensorBalanceTransfer public immutable balance_transfer;

    uint16 public netuid;
    uint16 public validatorUid;

    BLAKE2b private blake2bInstance;
    bytes32 public contractSS58Pub;

    event DepositTao(
        address indexed sender,
        uint256 taoAmount,
        uint256 sharesMinted,
        address indexed to
    );
    event WithdrawAsAlpha(
        address indexed sender,
        uint256 sharesBurned,
        uint256 alphaAmount,
        bytes32 indexed to
    );
    event WithdrawAsTao(
        address indexed sender,
        uint256 sharesBurned,
        uint256 taoAmount,
        bytes32 indexed to
    );

    constructor(
        string memory _name,
        string memory _symbol,
        uint16 _netuid,
        uint16 _validatorUid
    ) ERC20(_name, _symbol) ERC20Permit(_name) {
        staking = IStaking(ISTAKING_ADDRESS);
        metagraph = IMetagraph(IMetagraph_ADDRESS);
        balance_transfer = ISubtensorBalanceTransfer(ISUBTENSOR_BALANCE_TRANSFER_ADDRESS);
        validatorUid = _validatorUid;
        netuid = _netuid;
        blake2bInstance = new BLAKE2b();
        contractSS58Pub = addressToSS58Pub(address(this));
    }

    /* ---------------------------------------------------------------------- */
    /*                        USER-FACING CORE LOGIC                          */
    /* ---------------------------------------------------------------------- */

    /// @notice Deposit native TAO → stake (plain)
    function depositTao(address to)
        external
        payable
        nonReentrant
    {
        _deposit(to, false, 0, false);
    }

    /// @notice Deposit native TAO → stake with price limit
    function depositTaoWithLimit(
        address to,
        uint256 limitPrice,
        bool allowPartial
    ) external payable nonReentrant {
        _deposit(to, true, limitPrice, allowPartial);
    }    

    /// @notice Burn pool tokens → unstake & redeem TAO (plain)
    function withdrawAsTao(
        uint256 shares,
        bytes32 to
    ) external nonReentrant {
        _withdrawTao(shares, to, false, 0, false);
    }

    /// @notice Burn pool tokens → unstake & redeem TAO with price limit
    function withdrawAsTaoWithLimit(
        uint256 shares,
        bytes32 to,
        uint256 limitPrice,
        bool allowPartial
    ) external nonReentrant {
        _withdrawTao(shares, to, true, limitPrice, allowPartial);
    }

    function withdrawAsAlpha(uint256 amount, bytes32 to) external nonReentrant {
        require(amount > 0, "zero amount");
        bytes32 hotkey = validatorHotkey();
        uint256 current_alpha = staking.getStake(hotkey, contractSS58Pub, netuid);
        uint256 alphaOut = (current_alpha * amount) / totalSupply();
        require(alphaOut > 0, "alphaOut zero");
        _burn(msg.sender, amount);
        (bool success, ) = address(staking).call{ gas: gasleft() }(
            abi.encodeWithSelector(
                IStaking.transferStake.selector,
                to,
                hotkey,
                uint256(netuid),
                uint256(netuid),
                alphaOut
            )
        );
        require(success, "stake transfer failed");
        emit WithdrawAsAlpha(msg.sender, amount, alphaOut, to);
    }

    /* ---------------------------------------------------------------------- */
    /*                    HELPER FUNCTIONS                          */
    /* ---------------------------------------------------------------------- */

    /// @dev Shared logic for deposits (plain vs. limit)
    function _deposit(
        address to,
        bool useLimit,
        uint256 limitPrice,
        bool allowPartial
    ) internal {
        require(to != address(0), "to zero");
        uint256 rawTao = msg.value;
        uint256 scaled = rawTao / DECIMAL_SCALE_FACTOR;

        bytes32 hotkey = validatorHotkey();
        uint256 minted = _doStake(hotkey, scaled, limitPrice, allowPartial, useLimit);

        _mint(to, minted);
        emit DepositTao(msg.sender, rawTao, minted, to);
    }

    /// @dev Core stake call: plain or limit mode
    function _doStake(
        bytes32 hotkey,
        uint256 amount,
        uint256 limitPrice,
        bool allowPartial,
        bool useLimit
    ) internal returns (uint256) {
        uint256 preAlpha = staking.getStake(hotkey, contractSS58Pub, netuid);
        bytes memory payload;

        if (useLimit) {
            payload = abi.encodeWithSelector(
                IStaking.addStakeLimit.selector,
                hotkey,
                amount,
                limitPrice,
                allowPartial,
                uint256(netuid)
            );
        } else {
            payload = abi.encodeWithSelector(
                IStaking.addStake.selector,
                hotkey,
                amount,
                uint256(netuid)
            );
        }

        (bool ok, ) = address(staking).call{ gas: gasleft() }(payload);
        require(ok, "stake failed");

        uint256 postAlpha = staking.getStake(hotkey, contractSS58Pub, netuid);
        return (postAlpha - preAlpha) * DECIMAL_SCALE_FACTOR;
    }

    /// @dev Shared logic for TAO withdrawals
    function _withdrawTao(
        uint256 shares,
        bytes32 to,
        bool useLimit,
        uint256 limitPrice,
        bool allowPartial
    ) internal {
        require(shares > 0, "zero amount");

        bytes32 hotkey = validatorHotkey();
        uint256 currentAlpha = staking.getStake(hotkey, contractSS58Pub, netuid);
        uint256 alphaOut = (currentAlpha * shares) / totalSupply();
        require(alphaOut > 0, "alphaOut zero");

        _burn(msg.sender, shares);

        uint256 beforeBal = address(this).balance;
        _doUnstake(hotkey, alphaOut, limitPrice, allowPartial, useLimit);
        uint256 afterBal = address(this).balance;

        uint256 taoOut = afterBal - beforeBal;
        require(taoOut > 0, "No tao to transfer");

        (bool sent, ) = address(balance_transfer).call{ value: taoOut, gas: gasleft() }(
            abi.encodeWithSelector(
                ISubtensorBalanceTransfer.transfer.selector,
                to
            )
        );
        require(sent, "Transfer Failed");

        emit WithdrawAsTao(msg.sender, shares, taoOut, to);
    }

    /// @dev Core unstake call: plain or limit mode
    function _doUnstake(
        bytes32 hotkey,
        uint256 alphaAmount,
        uint256 limitPrice,
        bool allowPartial,
        bool useLimit
    ) internal {
        bytes memory payload;

        if (useLimit) {
            payload = abi.encodeWithSelector(
                IStaking.removeStakeLimit.selector,
                hotkey,
                alphaAmount,
                limitPrice,
                allowPartial,
                uint256(netuid)
            );
        } else {
            payload = abi.encodeWithSelector(
                IStaking.removeStake.selector,
                hotkey,
                alphaAmount,
                uint256(netuid)
            );
        }

        (bool ok, ) = address(staking).call{ gas: gasleft() }(payload);
        require(ok, "unstake failed");
    }
    

    function addressToSS58Pub(address addr) public view returns (bytes32) {
        bytes memory evm_prefix = abi.encodePacked(bytes4("evm:"));
        bytes memory address_bytes = abi.encodePacked(addr);
        bytes memory input = new bytes(24);
        for (uint i = 0; i < 4; i++) { input[i] = evm_prefix[i]; }
        for (uint i = 0; i < 20; i++) { input[i + 4] = address_bytes[i]; }
        return blake2bInstance.blake2b_256(input);
    }

    function validatorHotkey() public view returns (bytes32) {
        return metagraph.getHotkey(netuid, validatorUid);
    }

    function shareToAlpha(uint256 amount) public view returns (uint256) {
        bytes32 hotkey = validatorHotkey();
        uint256 current_alpha = staking.getStake(hotkey, contractSS58Pub, netuid);
        return (current_alpha * amount) / totalSupply();
    }

    receive() external payable { revert("Direct TAO transfers not allowed; use depositTao"); }
    fallback() external payable { revert("Direct TAO transfers not allowed; use depositTao"); }
}
