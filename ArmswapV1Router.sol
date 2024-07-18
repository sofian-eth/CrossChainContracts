// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../access/MPCAdminPausableControl.sol";
import "./interfaces/IArmcallExecutor.sol";
import "./interfaces/IRouterSecurity.sol";
import "./interfaces/IUnderlying.sol";
import "./interfaces/IwNATIVE.sol";
import "./interfaces/IArmswapERC20Auth.sol";
import "./interfaces/IRouterMintBurn.sol";
import "./ArmswapV1ERC20Deployer.sol";

contract ArmswapV1Router is MPCAdminPausableControl, ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC20;

    bytes32 public constant Swapin_Paused_ROLE =
        keccak256("Swapin_Paused_ROLE");
    bytes32 public constant Swapout_Paused_ROLE =
        keccak256("Swapout_Paused_ROLE");
    bytes32 public constant Call_Paused_ROLE = keccak256("Call_Paused_ROLE");
    bytes32 public constant Exec_Paused_ROLE = keccak256("Exec_Paused_ROLE");
    bytes32 public constant Retry_Paused_ROLE = keccak256("Retry_Paused_ROLE");

    address public immutable wNATIVE;
    ArmswapV1ERC20Deployer private deployer;
    address public immutable armCallExecutor;
    address public rewardController;

    address public routerSecurity;

    struct ProxyInfo {
        bool supported;
        bool acceptAnyToken;
    }

    mapping(address => ProxyInfo) public armCallProxyInfo;
    mapping(bytes32 => bytes32) public retryRecords; // retryHash -> dataHash
    mapping(address => uint) public MPCfeeInPools;

    event LogAnySwapIn(
        string swapID,
        bytes32 indexed swapoutID,
        address indexed token,
        address indexed receiver,
        uint256 amount,
        uint256 fromChainID
    );
    event LogAnySwapOut(
        bytes32 indexed swapoutID,
        address indexed token,
        address indexed from,
        string receiver,
        uint256 amount,
        uint256 toChainID
    );

    event LogRetrySwapInAndExec(
        string swapID,
        bytes32 swapoutID,
        address token,
        address receiver,
        uint256 amount,
        uint256 fromChainID,
        bool dontExec,
        bool success,
        bytes result
    );
    event poolCreated(
        address pairAddress,
        uint dstID,
        string pairName,
        string pairSymbol,
        uint8 pairDecimals
    );

    constructor(
        address _admin,
        address _mpc,
        address _wNATIVE,
        address _anycallExecutor,
        address _routerSecurity,
        address _rewardController
    ) MPCAdminPausableControl(_admin, _mpc) {
        require(_admin != address(0), "admin cannot be zero address");
        require(_anycallExecutor != address(0), "zero anycall executor");
        armCallExecutor = _anycallExecutor;
        wNATIVE = _wNATIVE;
        routerSecurity = _routerSecurity;
        rewardController = _rewardController;
        deployer = ArmswapV1ERC20Deployer(deployDeployer());
    }

    receive() external payable {
        assert(msg.sender == wNATIVE); // only accept Native via fallback from the wNative contract
    }

    modifier onlyrewardController() {
        require(msg.sender == rewardController, "onlyrewardController");
        _;
    }

    function deployDeployer() internal returns (address) {
        ArmswapV1ERC20Deployer deploy = new ArmswapV1ERC20Deployer();
        return address(deploy);
    }

    function changeRewardController(
        address _rewardController
    ) external onlyAdmin {
        rewardController = _rewardController;
    }

    function createPool(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        uint _dstID
    ) external payable {
        address newPool = deployer.deployNewPair(
            _name,
            _symbol,
            _decimals,
            wNATIVE,
            admin,
            wNATIVE,
            address(this),
            rewardController
        );
        (bool success, ) = address(newPool).call{value: msg.value}(
            abi.encodeWithSignature("deposit(address)", msg.sender)
        );
        require(success, "Deposit failed");
        emit poolCreated(address(newPool), _dstID, _name, _symbol, _decimals);
    }

    function createERC20Pool(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _underlying,
        uint _liquidity,
        uint _dstID
    ) external {
        address newPool = deployer.deployNewPair(
            _name,
            _symbol,
            _decimals,
            _underlying,
            admin,
            wNATIVE,
            address(this),
            rewardController
        );
        require(
            IERC20(_underlying).transferFrom(
                msg.sender,
                address(this),
                _liquidity
            ),
            "transferFrom Failed"
        );
        IERC20(_underlying).approve(newPool, _liquidity);
        IERC20(newPool).deposit(_liquidity, msg.sender);
        emit poolCreated(address(newPool), _dstID, _name, _symbol, _decimals);
    }

    function setRouterSecurity(
        address _routerSecurity
    ) external nonReentrant onlyAdmin {
        routerSecurity = _routerSecurity;
    }

    function changeVault(
        address token,
        address newVault
    ) external nonReentrant onlyAdmin returns (bool) {
        return IArmswapERC20Auth(token).changeVault(newVault);
    }

    function _anySwapOutUnderlying(
        address token,
        uint256 amount
    ) internal whenNotPaused(Swapout_Paused_ROLE) returns (uint256) {
        address _underlying = IUnderlying(token).underlying();
        require(_underlying != address(0), "ArmswapRouter: zero underlying");
        uint256 old_balance = IERC20(_underlying).balanceOf(token);
        IERC20(_underlying).safeTransferFrom(msg.sender, token, amount);
        uint256 new_balance = IERC20(_underlying).balanceOf(token);
        require(
            new_balance >= old_balance && new_balance <= old_balance + amount
        );
        return new_balance - old_balance;
    }

    // Swaps `amount` `token` from this chain to `toChainID` chain with recipient `to` by minting with `underlying`
    function armSwapOutUnderlying(
        address token,
        string calldata to,
        uint256 amount,
        uint256 toChainID
    ) external nonReentrant {
        uint256 recvAmount = _anySwapOutUnderlying(token, amount);
        bytes32 swapoutID = IRouterSecurity(routerSecurity).registerSwapout(
            token,
            msg.sender,
            to,
            recvAmount,
            toChainID,
            "",
            ""
        );
        emit LogAnySwapOut(
            swapoutID,
            token,
            msg.sender,
            to,
            recvAmount,
            toChainID
        );
    }

    function _anySwapOutNative(
        address token
    ) internal whenNotPaused(Swapout_Paused_ROLE) returns (uint256) {
        require(wNATIVE != address(0), "ArmswapRouter: zero wNATIVE");
        require(
            IUnderlying(token).underlying() == wNATIVE,
            "ArmswapRouter: underlying is not wNATIVE"
        );
        uint256 old_balance = IERC20(wNATIVE).balanceOf(token);
        IwNATIVE(wNATIVE).deposit{value: msg.value}();
        IERC20(wNATIVE).safeTransfer(token, msg.value);
        uint256 new_balance = IERC20(wNATIVE).balanceOf(token);
        require(
            new_balance >= old_balance && new_balance <= old_balance + msg.value
        );
        return new_balance - old_balance;
    }

    // Swaps `msg.value` `Native` from this chain to `toChainID` chain with recipient `to`
    function armSwapOutNative(
        address token,
        string calldata to,
        uint256 toChainID
    ) external payable nonReentrant {
        uint256 recvAmount = _anySwapOutNative(token);
        bytes32 swapoutID = IRouterSecurity(routerSecurity).registerSwapout(
            token,
            msg.sender,
            to,
            recvAmount,
            toChainID,
            "",
            ""
        );
        emit LogAnySwapOut(
            swapoutID,
            token,
            msg.sender,
            to,
            recvAmount,
            toChainID
        );
    }

    function withdrawFee(
        address pool,
        address payable _to
    ) external onlyrewardController {
        address _underlying = IUnderlying(pool).underlying();
        uint amount = MPCfeeInPools[pool];

        if (
            _underlying != address(0) &&
            IERC20(_underlying).balanceOf(pool) >= amount
        ) {
            assert(IRouterMintBurn(pool).mint(address(this), amount));

            IUnderlying(pool).withdraw(amount, _to);
        }
    }

    // Swaps `amount` `token` in `fromChainID` to `to` on this chainID with `to` receiving `underlying` or `Native` if possible
    function anySwapInAuto(
        string calldata swapID,
        SwapInfo calldata swapInfo,
        uint gasFee
    ) external whenNotPaused(Swapin_Paused_ROLE) nonReentrant onlyMPC {
        IRouterSecurity(routerSecurity).registerSwapin(swapID, swapInfo);
        address _underlying = IUnderlying(swapInfo.token).underlying();
        uint amount = swapInfo.amount - gasFee;
        MPCfeeInPools[swapInfo.token] += gasFee;
        if (
            _underlying != address(0) &&
            IERC20(_underlying).balanceOf(swapInfo.token) >= amount
        ) {
            assert(IRouterMintBurn(swapInfo.token).mint(address(this), amount));
            if (_underlying == wNATIVE) {
                IUnderlying(swapInfo.token).withdraw(amount, swapInfo.receiver);
            } else {
                IUnderlying(swapInfo.token).withdraw(amount, swapInfo.receiver);
            }
        } else {
            assert(
                IRouterMintBurn(swapInfo.token).mint(swapInfo.receiver, amount)
            );
        }
        emit LogAnySwapIn(
            swapID,
            swapInfo.swapoutID,
            swapInfo.token,
            swapInfo.receiver,
            amount,
            swapInfo.fromChainID
        );
    }

    // extracts mpc fee from bridge fees
    function anySwapFeeTo(
        address token,
        uint256 amount
    ) external nonReentrant onlyAdmin {
        IRouterMintBurn(token).mint(address(this), amount);
        IUnderlying(token).withdraw(amount, msg.sender);
    }
}
