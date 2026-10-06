// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {NetlistVM} from "tapeout/lib/NetlistVM.sol";

// Small imitations of TapeOut's factory, Transistors and Circuits for tests that do not need the fork.
// They copy the accounting of the verified sources (contracts/vendor/tapeout-xlayer/src) where the issuance
// contracts depend on it: who becomes `creator`, how `owed` accrues, the "nothing owed" revert, the exact
// tape-out fee, and what a tape-out burns (TapeOut's own `NetlistVM.burnOf`, compiled from the vendored
// source). Everything else (ERC-1155/721 plumbing, circuit evaluation) is left out.
// The fork suite runs the same flows against the real deployed bytecode.

contract MockTransistors {
    uint256 public constant NAND = 0;
    uint256 public constant LATCH = 1;

    struct Init {
        string name;
        string symbol;
        string story;
        address creator;
        uint256 supplyCap;
        uint256 mintPrice;
        address protocolWallet;
        uint256 protocolFee;
        address circuits;
    }

    address public creator;
    address public circuits;
    address public protocolWallet;
    uint256 public protocolFee;
    uint256 public mintPrice;
    uint256 public supplyCap;
    uint256 public minted;
    mapping(address => uint256) public owed;
    string public cpuName;
    string public cpuSymbol;
    string public story;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    /// @dev test knob: makes withdraw() fail with something other than "nothing owed"
    bool public withdrawBroken;

    constructor(Init memory i) {
        cpuName = i.name;
        cpuSymbol = i.symbol;
        story = i.story;
        creator = i.creator;
        supplyCap = i.supplyCap;
        mintPrice = i.mintPrice;
        protocolWallet = i.protocolWallet;
        protocolFee = i.protocolFee;
        circuits = i.circuits;
    }

    function mint(uint256 id, uint256 amount) external payable {
        require(id == NAND || id == LATCH, "bad id");
        require(amount > 0, "zero");
        require(minted + amount <= supplyCap, "supply cap");
        uint256 cost = mintPrice * amount + protocolFee;
        require(msg.value >= cost, "insufficient");

        minted += amount;
        owed[protocolWallet] += protocolFee;
        owed[creator] += mintPrice * amount;
        uint256 refund = msg.value - cost;
        if (refund > 0) owed[msg.sender] += refund;

        balanceOf[msg.sender][id] += amount;
    }

    function withdraw() external {
        require(!withdrawBroken, "broken");
        uint256 amt = owed[msg.sender];
        require(amt > 0, "nothing owed");
        owed[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "withdraw failed");
    }

    function burnFrom(address from, uint256 id, uint256 amount) external {
        require(msg.sender == circuits, "only circuits");
        balanceOf[from][id] -= amount;
    }

    function setWithdrawBroken(bool broken) external {
        withdrawBroken = broken;
    }
}

contract MockCircuits {
    uint256 public immutable TAPEOUT_FEE;
    address public transistors;
    uint256 public nextId;

    struct Circ {
        bytes netlist;
        address owner;
        uint32 nIn;
        uint32 nOut;
    }

    mapping(uint256 => Circ) internal _circ;

    constructor(uint256 tapeoutFee) {
        TAPEOUT_FEE = tapeoutFee;
    }

    function setTransistors(address transistors_) external {
        require(transistors == address(0), "set");
        transistors = transistors_;
    }

    function tapeout(bytes calldata nl, uint32 nIn, uint32 nOut) external payable returns (uint256 circuitId) {
        require(msg.value == TAPEOUT_FEE, "tapeout fee");
        require(nOut > 0, "no outputs");
        (uint256 nNand, uint256 nLatch) = NetlistVM.burnOf(nl);
        if (nNand > 0) MockTransistors(transistors).burnFrom(msg.sender, 0, nNand);
        if (nLatch > 0) MockTransistors(transistors).burnFrom(msg.sender, 1, nLatch);

        circuitId = ++nextId;
        _circ[circuitId] = Circ({netlist: nl, owner: msg.sender, nIn: nIn, nOut: nOut});
    }

    function netlist(uint256 circuitId) external view returns (bytes memory) {
        require(_circ[circuitId].owner != address(0), "no circuit");
        return _circ[circuitId].netlist;
    }

    function circuitInfo(uint256 circuitId) external view returns (uint32, uint32, uint32, uint32) {
        Circ storage c = _circ[circuitId];
        require(c.owner != address(0), "no circuit");
        (uint256 nNand, uint256 nLatch) = NetlistVM.burnOf(c.netlist);
        return (c.nIn, c.nOut, uint32(nLatch), uint32(nNand + nLatch));
    }

    function ownerOf(uint256 circuitId) external view returns (address owner) {
        owner = _circ[circuitId].owner;
        require(owner != address(0), "ERC721NonexistentToken");
    }

    function transferFrom(address from, address to, uint256 circuitId) external {
        require(_circ[circuitId].owner == from && msg.sender == from, "not owner");
        require(to != address(0), "zero");
        _circ[circuitId].owner = to;
    }

    /// @dev test knob: what a hostile logic upgrade could do to an existing circuit's netlist
    function overwriteNetlist(uint256 circuitId, bytes calldata nl) external {
        _circ[circuitId].netlist = nl;
    }
}

contract MockFactory {
    enum Sabotage {
        None,
        WrongCreator,
        WrongSupply,
        WrongPrice,
        CloneFeeDiffers,
        WrongCircuitsLink,
        WrongTransistorsLink,
        NotRegistered,
        StoryCut, // the story cut to 280 bytes, the limit of TapeOut's own creation form
        StoryOneCharacterOff, // same length, the last digit of the commit changed
        StoryPadded, // one space appended
        WrongName, // same length, first letter in lower case
        WrongSymbol, // same length, last letter in lower case
        SealsItself // the factory gives up its admin rights while it creates the processor
    }

    uint256 public deployFee = 0.0066 ether;
    uint256 public protocolFee = 0.00066 ether;
    uint256 public tapeoutFee = 0.0013 ether;
    address public protocolWallet = address(0xFEE);
    Sabotage public sabotage;
    /// @dev what TapeOut's `seal()` sets: no upgrade of processor logic is possible any more
    bool public isSealed;

    address[] public cpus;
    mapping(address => bool) public isCPU;
    mapping(address => uint256) public owed;

    function createCPU(
        string calldata name,
        string calldata symbol,
        string calldata story,
        uint256 transistorSupply,
        uint256 mintPrice
    ) external payable returns (address transistorsAddr, address circuitsAddr) {
        require(msg.value >= deployFee, "deploy fee");

        MockCircuits circuits = new MockCircuits(tapeoutFee);

        MockTransistors.Init memory i;
        i.name = sabotage == Sabotage.WrongName ? "covenant" : name;
        i.symbol = sabotage == Sabotage.WrongSymbol ? "CVNt" : symbol;
        i.story = _stored(story);
        i.creator = sabotage == Sabotage.WrongCreator ? address(this) : msg.sender;
        i.supplyCap = sabotage == Sabotage.WrongSupply ? transistorSupply - 1 : transistorSupply;
        i.mintPrice = sabotage == Sabotage.WrongPrice ? mintPrice + 1 : mintPrice;
        i.protocolWallet = protocolWallet;
        i.protocolFee = sabotage == Sabotage.CloneFeeDiffers ? protocolFee + 1 : protocolFee;
        i.circuits = sabotage == Sabotage.WrongCircuitsLink ? address(this) : address(circuits);
        MockTransistors transistors = new MockTransistors(i);

        circuits.setTransistors(sabotage == Sabotage.WrongTransistorsLink ? address(this) : address(transistors));

        if (sabotage == Sabotage.SealsItself) isSealed = true;

        cpus.push(address(circuits));
        isCPU[address(circuits)] = sabotage != Sabotage.NotRegistered;
        owed[protocolWallet] += deployFee;
        uint256 refund = msg.value - deployFee;
        if (refund > 0) owed[msg.sender] += refund;

        return (address(transistors), address(circuits));
    }

    function cpuCount() external view returns (uint256) {
        return cpus.length;
    }

    function setDeployFee(uint256 v) external {
        deployFee = v;
    }

    function setProtocolFee(uint256 v) external {
        protocolFee = v;
    }

    function setTapeoutFee(uint256 v) external {
        tapeoutFee = v;
    }

    function setSabotage(Sabotage s) external {
        sabotage = s;
    }

    function setSealed(bool v) external {
        isSealed = v;
    }

    /// @dev the story as the sabotaged factory stores it
    function _stored(string calldata story) internal view returns (string memory) {
        if (sabotage == Sabotage.StoryCut) return string(bytes(story)[:280]);
        if (sabotage == Sabotage.StoryPadded) return string.concat(story, " ");
        bytes memory b = bytes(story);
        if (sabotage == Sabotage.StoryOneCharacterOff) {
            // the story ends with the commit and a full stop
            b[b.length - 2] = b[b.length - 2] == "0" ? bytes1("1") : bytes1("0");
        }
        return string(b);
    }
}
