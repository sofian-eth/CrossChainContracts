// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "../anytoken/ArmswapV1ERC20.sol";

contract ArmswapV1ERC20Deployer {
    address immutable deployer;

    constructor() {
        deployer = msg.sender;
    }

    modifier deployerOnly() {
        require(msg.sender == deployer, "Only deployer can call this function");
        _;
    }

    function deployNewPair(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _underlying,
        address _vault,
        address _wNative,
        address _initialMinter,
        address _rewardController
    ) external deployerOnly returns (address) {
        ArmswapV1ERC20 newPool = new ArmswapV1ERC20(
            _name,
            _symbol,
            _decimals,
            _underlying,
            _vault,
            _wNative,
            _initialMinter,
            _rewardController
        );

        return address(newPool);
    }
}
