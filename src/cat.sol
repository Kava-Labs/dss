/// cat.sol -- Dai liquidation module

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

import "./lib.sol";

contract Flippy {
    function kick(address urn, address gal, uint tab, uint lot, uint bid)
        public returns (uint);
}

contract VatLike {
    struct Ilk {
        uint256 Art;   // wad
        uint256 rate;  // ray
        uint256 spot;  // ray
        uint256 line;  // rad
    }
    struct Urn {
        uint256 ink;   // wad
        uint256 art;   // wad
    }
    function ilks(bytes32) public view returns (Ilk memory);
    function urns(bytes32,address) public view returns (Urn memory);
    function grab(bytes32,address,address,address,int,int) public;
    function hope(address) public;
}

contract VowLike {
    function fess(uint) public;
}

contract Cat is DSNote {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) public note auth { wards[usr] = 1; }
    function deny(address usr) public note auth { wards[usr] = 0; }
    modifier auth { require(wards[msg.sender] == 1); _; }

    // --- Data ---
    struct Ilk {
        address flip;  // Liquidator
        uint256 chop;  // Liquidation Penalty   [ray]
        uint256 lump;  // Liquidation Quantity  [rad]
    }
    struct Flip {
        bytes32 ilk;  // Collateral Type
        address urn;  // CDP Identifier
        uint256 ink;  // Collateral Quantity [wad]
        uint256 tab;  // Debt Outstanding    [rad]
    }

    mapping (bytes32 => Ilk)  public ilks;
    mapping (uint256 => Flip) public flips;
    uint256                   public nflip;

    uint256 public live;
    VatLike public vat;
    VowLike public vow;

    // --- Events ---
    event Bite(
      bytes32 indexed ilk,
      address indexed urn,
      uint256 ink,
      uint256 art,
      uint256 tab,
      uint256 flip
    );

    event FlipKick(
      uint256 nflip,
      uint256 bid
    );

    // --- Init ---
    constructor(address vat_) public {
        wards[msg.sender] = 1;
        vat = VatLike(vat_);
        live = 1;
    }

    // --- Math ---
    uint constant ONE = 10 ** 27;

    function mul(uint x, uint y) internal pure returns (uint z) {
        z = x * y;
        require(y == 0 || z / y == x);
    }
    function rmul(uint x, uint y) internal pure returns (uint z) {
        z = x * y;
        require(y == 0 || z / y == x);
        z = z / ONE;
    }

    // --- Administration ---
    function file(bytes32 what, address data) public note auth {
        if (what == "vow") vow = VowLike(data);
    }
    function file(bytes32 ilk, bytes32 what, uint data) public note auth {
        if (what == "chop") ilks[ilk].chop = data;
        if (what == "lump") ilks[ilk].lump = data;
    }
    function file(bytes32 ilk, bytes32 what, address flip) public note auth {
        if (what == "flip") ilks[ilk].flip = flip; vat.hope(flip);
    }

    // --- CDP Liquidation ---
    // Mark a CDP for liquidation. ie confiscate an unsafe CDP
    function bite(bytes32 ilk, address urn) public returns (uint) {
        require(live == 1);
        VatLike.Ilk memory i = vat.ilks(ilk);
        VatLike.Urn memory u = vat.urns(ilk, urn);

        uint tab = mul(u.art, i.rate); // calculate amount of DAI to be raised in the flip auction (rate is accumulated stability fees)

        require(mul(u.ink, i.spot) < tab);  // !safe

        vat.grab(ilk, urn, address(this), address(vow), -int(u.ink), -int(u.art)); // confiscate the CDP - ie destroy it and give collateral to cat contract and debt to vow contract
        vow.fess(tab); // add debt to the queue

        flips[nflip] = Flip(ilk, urn, u.ink, tab); // create a flip object recording collateral and dai to be raised

        emit Bite(ilk, urn, u.ink, u.art, tab, nflip);

        return nflip++;
    }
    // Initate a liquidation auction
    function flip(uint n, uint rad) public note returns (uint id) {
        require(live == 1);
        Flip storage f = flips[n];
        Ilk  storage i = ilks[f.ilk];

        require(rad <= f.tab); // tab is amount of dai to be raised at auction
        require(rad == i.lump || (rad < i.lump && rad == f.tab));

        uint tab = f.tab; // total dai to be raised
        uint ink = mul(f.ink, rad) / tab; // "f.ink * (rad/tab)" scale ink sold in this auction by the amount flip is called with

        f.tab -= rad;
        f.ink -= ink;

        id = Flippy(i.flip).kick({ urn: f.urn
                                 , gal: address(vow)
                                 , tab: rmul(rad, i.chop) // chop is the liquidation penalty
                                 , lot: ink
                                 , bid: 0
                                 });
        emit FlipKick(n, id);
    }
}
