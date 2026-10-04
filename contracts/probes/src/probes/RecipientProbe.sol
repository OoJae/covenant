// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDirectedVault} from "../interfaces/IDirectedVault.sol";
import {IIgnixManager, CurveToken} from "../interfaces/IIgnix.sol";
import {CurveQuote} from "../CurveQuote.sol";
import {IIgnixToken} from "../interfaces/IIgnixToken.sol";
import {IUniswapV2Router02} from "../interfaces/IUniswapV2.sol";

/// @title RecipientProbe: a stand-in for the Covenant kernel, used ONLY in fork tests.
/// @notice It is the RECIPIENT of an IGNIX Directed vault (either deployed and launched against, or etched
///         over a live recipient address). It has no constructor state so `vm.etch` gives a working copy.
///         Never deployed to mainnet; holds no keys; has no owner.
contract RecipientProbe {
    /// @dev How receive() behaves.
    enum Mode {
        Accept, // 0: accept and do nothing (one storage read to pick the mode)
        Record, // 1: non-trivial receive(): 4 cold SSTOREs + an event (about 90k gas)
        Refuse, // 2: revert
        Reenter, // 3: call vault.claim(address(0)) again from inside receive()
        OnlyKnown, // 4: accept only from allow-listed senders (the plan's "vault and manager only")
        Burn, // 5: consume all forwarded gas (infinite loop)
        OnlyOwnClaim // 6: accept native only from the vault AND only while this contract itself is claiming
    }

    Mode public mode;
    bool public inOwnClaim;
    address public reenterVault;
    mapping(address => bool) public known;

    uint256 public receiveCount;
    uint256 public receivedTotal;
    uint256 public lastGasAtReceive;
    address public lastSender;
    bytes public lastReenterRevert;

    event Received(address indexed from, uint256 amount, uint256 gasAtEntry);

    error RefuseNative();
    error UnknownSender(address sender);
    error NotInOwnClaim();

    receive() external payable {
        uint256 g = gasleft();
        Mode m = mode;
        if (m == Mode.Accept) return;
        if (m == Mode.Refuse) revert RefuseNative();
        if (m == Mode.Burn) {
            while (true) {}
        }
        if (m == Mode.OnlyKnown && !known[msg.sender]) revert UnknownSender(msg.sender);
        if (m == Mode.OnlyOwnClaim) {
            if (!known[msg.sender]) revert UnknownSender(msg.sender);
            if (!inOwnClaim) revert NotInOwnClaim();
            return;
        }
        if (m == Mode.Reenter) {
            (bool ok, bytes memory ret) =
                reenterVault.call(abi.encodeCall(IDirectedVault.claim, (address(0))));
            ok;
            lastReenterRevert = ret;
        }
        receiveCount += 1;
        receivedTotal += msg.value;
        lastGasAtReceive = g;
        lastSender = msg.sender;
        emit Received(msg.sender, msg.value, g);
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setReenterVault(address v) external {
        reenterVault = v;
    }

    function setKnown(address a, bool ok) external {
        known[a] = ok;
    }

    // ───────────────────────────── vault ─────────────────────────────

    /// @return ret what the vault returned, @return delta the real balance change, @return gasUsed of the call
    function claim(IDirectedVault vault, address asset)
        external
        returns (uint256 ret, uint256 delta, uint256 gasUsed)
    {
        uint256 b0 = _bal(asset);
        uint256 g0 = gasleft();
        ret = vault.claim(asset);
        gasUsed = g0 - gasleft();
        delta = _bal(asset) - b0;
    }

    /// @dev claim() with the "I am claiming" flag raised, for Mode.OnlyOwnClaim.
    function claimGated(IDirectedVault vault, address asset) external returns (uint256 ret, uint256 delta) {
        uint256 b0 = _bal(asset);
        inOwnClaim = true;
        ret = vault.claim(asset);
        inOwnClaim = false;
        delta = _bal(asset) - b0;
    }

    /// @dev Same, but never reverts: mirrors the kernel's `try vault.claim(asset) catch`.
    function tryClaim(IDirectedVault vault, address asset)
        external
        returns (bool ok, bytes memory err, uint256 delta, uint256 gasUsed)
    {
        uint256 b0 = _bal(asset);
        uint256 g0 = gasleft();
        try vault.claim(asset) returns (uint256) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        gasUsed = g0 - gasleft();
        delta = _bal(asset) - b0;
    }

    // ───────────────────────────── curve ─────────────────────────────

    /// @notice The kernel's buy-and-lock leg: native OKB from this contract, tokens to `to`.
    function buyTo(IIgnixManager manager, address token, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 tokenDelta, uint256 nativeSpent, uint256 gasUsed)
    {
        uint256 t0 = IIgnixToken(token).balanceOf(to);
        uint256 n0 = address(this).balance;
        uint256 g0 = gasleft();
        manager.buyTo{value: amountIn}(token, amountIn, minOut, to);
        gasUsed = g0 - gasleft();
        tokenDelta = IIgnixToken(token).balanceOf(to) - t0;
        // if `to` is this contract any overbuy refund has already come back
        nativeSpent = n0 - address(this).balance;
    }

    function tryBuyTo(IIgnixManager manager, address token, uint256 amountIn, uint256 minOut, address to)
        external
        returns (bool ok, bytes memory err, uint256 tokenDelta, uint256 gasUsed)
    {
        uint256 t0 = IIgnixToken(token).balanceOf(to);
        uint256 g0 = gasleft();
        try manager.buyTo{value: amountIn}(token, amountIn, minOut, to) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        gasUsed = g0 - gasleft();
        tokenDelta = IIgnixToken(token).balanceOf(to) - t0;
    }

    // ───────────────────────────── token ─────────────────────────────

    function tokenTransfer(address token, address to, uint256 amount) external returns (uint256 gasUsed) {
        uint256 g0 = gasleft();
        IIgnixToken(token).transfer(to, amount);
        gasUsed = g0 - gasleft();
    }

    // ───────────────────────────── Uniswap V2 ─────────────────────────────

    /// @notice The kernel's post-graduation buy leg: native OKB in, project tokens to `to`.
    function swapNativeForTokens(
        IUniswapV2Router02 router,
        address token,
        uint256 amountIn,
        uint256 minOut,
        address to
    ) external returns (uint256 tokenDelta, uint256 gasUsed) {
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = token;
        uint256 t0 = IIgnixToken(token).balanceOf(to);
        uint256 g0 = gasleft();
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountIn}(
            minOut, path, to, block.timestamp
        );
        gasUsed = g0 - gasleft();
        tokenDelta = IIgnixToken(token).balanceOf(to) - t0;
    }

    // ───────────────────────────── one epoch, as the kernel would run it ─────────────────────────────

    /// @notice The external legs of a curve-phase settle, in one transaction: claim native tax (caught),
    ///         read the curve, quote, buyTo itself with the exact quote as minOut.
    /// @return gasByLeg [claim, reads (tokens + snipeBpsNow + pairOf), buyTo]
    function curveEpoch(IDirectedVault vault, IIgnixManager manager, address token, uint256 buyAmount)
        external
        returns (uint256[3] memory gasByLeg, uint256 claimed, uint256 bought)
    {
        (gasByLeg[0], claimed) = _claimLeg(vault, address(0));
        bool skip;
        uint256 minOut;
        (gasByLeg[1], buyAmount, minOut, skip) = _readLeg(manager, token, buyAmount);
        if (skip) return (gasByLeg, claimed, 0);
        (gasByLeg[2], bought) = _buyLeg(manager, token, buyAmount, minOut);
    }

    function _claimLeg(IDirectedVault vault, address asset) private returns (uint256 gasUsed, uint256 delta) {
        uint256 b0 = _bal(asset);
        uint256 g = gasleft();
        try vault.claim(asset) {} catch {}
        gasUsed = g - gasleft();
        delta = _bal(asset) - b0;
    }

    /// @dev tokens + snipeBpsNow + pairOf, then the pure quote. Skips while anti-snipe is on or after
    ///      graduation, and shrinks the buy so it can never sell the curve out.
    function _readLeg(IIgnixManager manager, address token, uint256 want)
        private
        view
        returns (uint256 gasUsed, uint256 amount, uint256 minOut, bool skip)
    {
        uint256 g = gasleft();
        CurveToken memory t = manager.tokens(token);
        uint256 snipe = manager.snipeBpsNow(token);
        address pair = manager.pairOf(token);
        gasUsed = g - gasleft();
        if (pair != address(0) || snipe != 0) return (gasUsed, 0, 0, true);

        CurveQuote.Curve memory c =
            CurveQuote.Curve(t.buyFeeBps, t.taxBuyBps, t.vQuote, t.vToken, t.sold, t.sellable);
        uint256 cap = CurveQuote.maxNonGraduatingBuy(c, snipe);
        amount = want > cap ? cap : want;
        minOut = CurveQuote.tokensOut(c, snipe, amount);
        skip = minOut == 0;
    }

    function _buyLeg(IIgnixManager manager, address token, uint256 amount, uint256 minOut)
        private
        returns (uint256 gasUsed, uint256 bought)
    {
        uint256 t0 = IIgnixToken(token).balanceOf(address(this));
        uint256 g = gasleft();
        try manager.buyTo{value: amount}(token, amount, minOut, address(this)) {} catch {}
        gasUsed = g - gasleft();
        bought = IIgnixToken(token).balanceOf(address(this)) - t0;
    }

    /// @notice The external legs of a graduated-phase settle: claim token tax, claim residual native tax
    ///         (both caught), send `burnBps` of the token balance to 0x...dEaD.
    /// @return gasByLeg [claim(token), claim(native), transfer to dead]
    function graduatedEpoch(IDirectedVault vault, address token, uint256 burnBps)
        external
        returns (uint256[3] memory gasByLeg, uint256 tokenClaimed, uint256 burned)
    {
        (gasByLeg[0], tokenClaimed) = _claimLeg(vault, token);
        (gasByLeg[1],) = _claimLeg(vault, address(0));
        (gasByLeg[2], burned) =
            _burnLeg(token, (IIgnixToken(token).balanceOf(address(this)) * burnBps) / 10_000);
    }

    function _burnLeg(address token, uint256 amount) private returns (uint256 gasUsed, uint256 burned) {
        address dead = 0x000000000000000000000000000000000000dEaD;
        uint256 d0 = IIgnixToken(token).balanceOf(dead);
        uint256 g = gasleft();
        try IIgnixToken(token).transfer(dead, amount) {} catch {}
        gasUsed = g - gasleft();
        burned = IIgnixToken(token).balanceOf(dead) - d0;
    }

    // ───────────────────────────── generic ─────────────────────────────

    /// @notice Arbitrary call from the probe's address; returns instead of reverting so tests can read
    ///         the exact revert data.
    function exec(address target, uint256 value, bytes calldata data)
        external
        returns (bool ok, bytes memory ret, uint256 gasUsed)
    {
        uint256 g0 = gasleft();
        (ok, ret) = target.call{value: value}(data);
        gasUsed = g0 - gasleft();
    }

    /// @notice Same, with an explicit gas limit on the call (to find the smallest limit a leg needs).
    function execGas(address target, uint256 value, bytes calldata data, uint256 gasLimit)
        external
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = target.call{value: value, gas: gasLimit}(data);
    }

    function _bal(address asset) private view returns (uint256) {
        return asset == address(0) ? address(this).balance : IIgnixToken(asset).balanceOf(address(this));
    }
}
