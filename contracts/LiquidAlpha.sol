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


/// @title LiquidAlpha
/// @notice This contract *itself* is an ERC-20 token (“LiquidAlpha”) that represents a claim on a
///         pooled Alpha position in Bittensor.  Users:
///
///  • **depositTao**   — send native TAO to the contract → TAO is staked, and the caller receives
///                       freshly-minted LiquidAlpha tokens proportional to their contribution.
///
///  • **withdrawAsAlpha** — burn LiquidAlpha to redeem your pro-rata share of the *Alpha* principal **plus any accrued Alpha rewards**.
///
///  • **withdrawAsTao**   — burn LiquidAlpha to redeem your pro-rata share of the *TAO*
//                           principal **plus any accrued TAO rewards**.
//                           The contract first unstakes the needed amount then forwards the proceeds in native TAO.
contract LiquidAlpha is ERC20, ERC20Permit, Ownable, ReentrancyGuard {

    /* ---------------------------------------------------------------------- */
    /*                                 CONSTANTS                              */
    /* ---------------------------------------------------------------------- */
    uint256 DECIMAL_SCALE_FACTOR = 10**9;

    /* ---------------------------------------------------------------------- */
    /*                              STATE VARIABLES                           */
    /* ---------------------------------------------------------------------- */
    IStaking public immutable staking;     
    IMetagraph public immutable metagraph; 
    ISubtensorBalanceTransfer public immutable balance_transfer; 

    uint256 public minDeposit; // Minimum TAO deposit

    /// @notice Subnet → validator UID mapping used when staking
    uint16 public netuid;
    uint16 public validatorUid;

    BLAKE2b private blake2bInstance;
    bytes32 public contractSS58Pub;

    /* ---------------------------------------------------------------------- */
    /*                                   EVENTS                               */
    /* ---------------------------------------------------------------------- */
    event MinDepositUpdated(uint256 oldMin, uint256 newMin);
    event StakeTargetUpdated(uint16 old_uid, uint16 new_uid);

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

    /* ---------------------------------------------------------------------- */
    /*                                 CONSTRUCTOR                            */
    /* ---------------------------------------------------------------------- */
    /// @param _name        Name of the token
    /// @param _symbol      Symbol of the token
    /// @param _netuid      Netuid of underlying alpha token
    /// @param _validatorUid  Uid that is used as the staking target
    /// @param _minDeposit  Minimum deposit (Wei)
    constructor(
        string memory _name,
        string memory _symbol,
        uint16 _netuid,
        uint16 _validatorUid,
        uint256 _minDeposit
    )
        ERC20(_name, _symbol)
        ERC20Permit(_name)
        Ownable(msg.sender)
    {
        staking = IStaking(ISTAKING_ADDRESS);
        metagraph = IMetagraph(IMetagraph_ADDRESS);
        balance_transfer = ISubtensorBalanceTransfer(ISUBTENSOR_BALANCE_TRANSFER_ADDRESS);
        minDeposit = _minDeposit;
        validatorUid = _validatorUid;
        netuid = _netuid;
        blake2bInstance = new BLAKE2b();
        contractSS58Pub = addressToSS58Pub(address(this));
    }


    /* ---------------------------------------------------------------------- */
    /*                    ADMIN: MANAGEMENT                      */
    /* ---------------------------------------------------------------------- */

    function setMinDeposit(uint256 _minDeposit) external onlyOwner {
        minDeposit = _minDeposit;
        emit MinDepositUpdated(minDeposit, _minDeposit);
    }

    /// @notice Move stake target to new_uid, moving stake to the new target.
    function setStakeTarget(uint16 new_uid) external onlyOwner {
        require(new_uid < 256, "uid too large");
        uint16 old_uid = validatorUid;
        bytes32 old_hotkey = _validatorHotkey();
        uint256 current_alpha = staking.getStake(old_hotkey, contractSS58Pub, netuid);
        validatorUid = new_uid;
        bytes32 new_hotkey = _validatorHotkey();

         (bool success, ) = address(staking).call{ gas: gasleft() }(
            abi.encodeWithSelector(
                IStaking.moveStake.selector,
                old_hotkey,
                new_hotkey,
                uint256(netuid),
                uint256(netuid),
                current_alpha
            )
        );
        require(success, "Move Stake Failed");

        emit StakeTargetUpdated(old_uid, new_uid);
    }

    /* ---------------------------------------------------------------------- */
    /*                        USER-FACING CORE LOGIC                          */
    /* ---------------------------------------------------------------------- */

    /// @notice Deposit native TAO → stake → mint LiquidAlpha.
    function depositTao(address to) external payable nonReentrant {
        uint256 amount = msg.value;
        require(amount >= minDeposit, "below minDeposit");
        require(to != address(0), "to zero");

        uint256 paid = amount / DECIMAL_SCALE_FACTOR;

        // stake into default (netuid 0) validator
        bytes32 hotkey = _validatorHotkey();
        uint256 current_alpha = staking.getStake(hotkey, contractSS58Pub, netuid);
        (bool success, ) = address(staking).call{ gas: gasleft() }(
            abi.encodeWithSelector(
                IStaking.addStake.selector,
                hotkey,
                paid,
                uint256(netuid)
            )
        );
        require(success, "stake failed");
        uint256 new_alpha = staking.getStake(hotkey, contractSS58Pub, netuid);
        uint256 added_alpha = (new_alpha - current_alpha) * DECIMAL_SCALE_FACTOR;

        _mint(to, added_alpha);

        emit DepositTao(msg.sender, amount, added_alpha, to);
    }

    /// @notice Burn LiquidAlpha → Transfer Alpha to 'to' address.
    function withdrawAsAlpha(uint256 amount, bytes32 to) external nonReentrant {
        require(amount > 0, "zero amount");
        bytes32 hotkey = _validatorHotkey();
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

    /// @notice Burn LiquidAlpha → unstake TAO → send TAO to 'to' address.
    function withdrawAsTao(uint256 amount, bytes32 to) external nonReentrant {
         require(amount > 0, "zero amount");

        bytes32 hotkey = _validatorHotkey();
        uint256 current_alpha = staking.getStake(hotkey, contractSS58Pub, netuid);
        uint256 alphaOut = (current_alpha * amount) / totalSupply();
        require(alphaOut > 0, "alphaOut zero");
        _burn(msg.sender, amount);
        uint256 current_tao_balance = address(this).balance;
        (bool success, ) = address(staking).call{ gas: gasleft() }(
            abi.encodeWithSelector(
                IStaking.removeStake.selector,
                hotkey,
                alphaOut,
                uint256(netuid)
            )
        );
        require(success, "unstake failed");
        uint256 new_tao_balance = address(this).balance;
        uint256 taoOut = new_tao_balance - current_tao_balance;
        require(taoOut > 0, "No tao to transfer");
        (bool transfer_success, ) = address(balance_transfer).call{ value: taoOut, gas: gasleft() }(
            abi.encodeWithSelector(
                ISubtensorBalanceTransfer.transfer.selector,
                to
            )
        );
        require(transfer_success, "Transfer Failed");
        emit WithdrawAsTao(msg.sender, amount, taoOut, to);
    }

    /* ---------------------------------------------------------------------- */
    /*                    Helper Functions                                    */
    /* ---------------------------------------------------------------------- */

    /// @dev Helper function to calculate the SS58 public key from an evm address.
    function addressToSS58Pub(address addr) public view returns (bytes32) {
        bytes memory evm_prefix = abi.encodePacked(bytes4("evm:"));
        bytes memory address_bytes = abi.encodePacked(addr);
        bytes memory input = new bytes(24);
        for (uint i = 0; i < 4; i++) {
            input[i] = evm_prefix[i];
        }
        for (uint i = 0; i < 20; i++) {
            input[i + 4] = address_bytes[i];
        }
        return blake2bInstance.blake2b_256(input);
    }

    /// @dev Helper to fetch the current validator hotkey from the metagraph
    function _validatorHotkey() private view returns (bytes32) {
        return metagraph.getHotkey(netuid, validatorUid);
    }



    /* ---------------------------------------------------------------------- */
    /*                          RECEIVE & FALLBACK                            */
    /* ---------------------------------------------------------------------- */
    /// @dev Reject plain TAO transfers; must use `depositTao(...)` so we can credit shares.
    receive() external payable {
        revert("Direct TAO transfers not allowed; use depositTao");
    }

    /// @dev Reject any calls to non-existent functions (or calldata) with TAO attached.
    fallback() external payable {
        revert("Direct TAO transfers not allowed; use depositTao");
    }
}
