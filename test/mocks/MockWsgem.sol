// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice A wsgem price feed that can be driven into the states the oracle must handle.
/// @dev `REVERTING` exercises upstream call failure handling.
contract MockPip {
    enum Mode {
        NORMAL,
        REVERTING
    }

    uint256 public price;
    Mode public mode;

    constructor(uint256 price_) {
        price = price_;
    }

    /// @notice Publish a new NAV. `0` is how the real feed signals a pause.
    function poke(uint256 price_) external {
        price = price_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function read() external view returns (uint256) {
        if (mode == Mode.REVERTING) revert("pip: unreadable");
        return price;
    }
}

/// @notice Minimal token exposing `decimals()`.
contract MockToken {
    uint8 public decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}

/// @notice The subset of a wsgem the oracle reads.
/// @dev Quotes are stored independently from the pip so tests can pause the pip while the gate
///      continues to return nonzero values.
contract MockWsgem {
    enum Mode {
        NORMAL,
        REVERTING
    }

    address public gem;
    address public pip;
    uint8 public decimals;
    Mode public mode;

    uint256 internal _navprice;
    uint256 internal _burncost;
    uint256 internal _mintcost;

    constructor(address gem_, address pip_, uint8 decimals_) {
        gem = gem_;
        pip = pip_;
        decimals = decimals_;
    }

    function setQuotes(uint256 navprice_, uint256 burncost_, uint256 mintcost_) external {
        _navprice = navprice_;
        _burncost = burncost_;
        _mintcost = mintcost_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }

    modifier answering() {
        if (mode == Mode.REVERTING) revert("wsgem: unreadable");
        _;
    }

    // The real wrapper computes these through its gate; here they are stored values behind the
    // mode switch, allowing gate and pip failures to be tested independently.
    function navprice() external view answering returns (uint256) {
        return _navprice;
    }

    function burncost() external view answering returns (uint256) {
        return _burncost;
    }

    function mintcost() external view answering returns (uint256) {
        return _mintcost;
    }
}
