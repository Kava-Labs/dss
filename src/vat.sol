/// vat.sol -- Dai CDP database

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

contract Vat {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) public note auth { wards[usr] = 1; }
    function deny(address usr) public note auth { wards[usr] = 0; }
    modifier auth { require(wards[msg.sender] == 1); _; }

    mapping(address => mapping (address => uint)) public can;
    function hope(address usr) public { can[msg.sender][usr] = 1; }
    function nope(address usr) public { can[msg.sender][usr] = 0; }
    function wish(address bit, address usr) internal view returns (bool) {
        return bit == usr || can[bit][usr] == 1;
    }

    // --- Data ---
    struct Ilk {
        uint256 Art;   // Total Normalised Debt     [wad]
        uint256 rate;  // Accumulated Rates         [ray] "accumulated stability fees"
        uint256 spot;  // Price with Safety Margin  [ray] maxium amount of Dai alowed to be drawn per unit collateral // This is the price feed for a collateral type. It is the price of the collateral in DAi x the liquidation ratio
        uint256 line;  // Debt Ceiling              [rad] maxium total dai drawn
        uint256 dust;  // Urn Debt Floor            [rad]
    }
    struct Urn {
        uint256 ink;   // Locked Collateral  [wad]
        uint256 art;   // Normalised Debt    [wad]
    }

    mapping (bytes32 => Ilk)                       public ilks;
    mapping (bytes32 => mapping (address => Urn )) public urns;
    mapping (bytes32 => mapping (address => uint)) public gem;  // [wad]
    mapping (address => uint256)                   public dai;  // [rad]
    mapping (address => uint256)                   public sin;  // [rad]

    uint256 public debt;  // Total Dai Issued    [rad]
    uint256 public vice;  // Total Unbacked Dai  [rad]
    uint256 public Line;  // Total Debt Ceiling  [wad]
    uint256 public live;  // Access Flag

    // --- Logs ---
    modifier note {
        _;
        assembly {
            // log an 'anonymous' event with a constant 6 words of calldata
            // and four indexed topics: the selector and the first three args
            let mark := msize                      // end of memory ensures zero
            mstore(0x40, add(mark, 288))           // update free memory pointer
            mstore(mark, 0x20)                     // bytes type data offset
            mstore(add(mark, 0x20), 224)           // bytes size (padded)
            calldatacopy(add(mark, 0x40), 0, 224)  // bytes payload
            log4(mark, 288,                        // calldata
                 shr(224, calldataload(0)),        // msg.sig
                 calldataload(4),                  // arg1
                 calldataload(36),                 // arg2
                 calldataload(68)                  // arg3
                )
        }
    }

    // --- Init ---
    constructor() public {
        wards[msg.sender] = 1;
        live = 1;
    }

    // --- Math ---
    function add(uint x, int y) internal pure returns (uint z) {
        z = x + uint(y);
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }
    function sub(uint x, int y) internal pure returns (uint z) {
        z = x - uint(y);
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }
    function mul(uint x, int y) internal pure returns (int z) {
        z = int(x) * y;
        require(int(x) >= 0);
        require(y == 0 || z / y == int(x));
    }
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---
    function init(bytes32 ilk) public note auth {
        require(ilks[ilk].rate == 0);
        ilks[ilk].rate = 10 ** 27;
    }
    function file(bytes32 what, uint data) public note auth {
        if (what == "Line") Line = data;
    }
    function file(bytes32 ilk, bytes32 what, uint data) public note auth {
        if (what == "spot") ilks[ilk].spot = data; // this is how the price feed is fed in
        if (what == "line") ilks[ilk].line = data;
        if (what == "dust") ilks[ilk].dust = data;
    }

    // --- Fungibility ---
    // add a type of gem to an address
    function slip(bytes32 ilk, address usr, int256 wad) public note auth {
        gem[ilk][usr] = add(gem[ilk][usr], wad);
    }
    // transfer (a particular type of) gems between addresses
    function flux(bytes32 ilk, address src, address dst, uint256 wad) public note {
        require(wish(src, msg.sender));
        gem[ilk][src] = sub(gem[ilk][src], wad);
        gem[ilk][dst] = add(gem[ilk][dst], wad);
    }
    // transfer dai between addresses
    function move(address src, address dst, uint256 rad) public note {
        require(wish(src, msg.sender));
        dai[src] = sub(dai[src], rad);
        dai[dst] = add(dai[dst], rad);
    }

    // --- CDP Manipulation ---
    // Add or remove collateral or dai from a CDP. (includes creating a CDP?)
    function frob(bytes32 i, address u, address v, address w, int dink, int dart) public note {
        Urn storage urn = urns[i][u];
        Ilk storage ilk = ilks[i];

        // add or remove collateral or dai to/from the CDP
        urn.ink = add(urn.ink, dink);
        urn.art = add(urn.art, dart);
        ilk.Art = add(ilk.Art, dart);

        // update the user's free balances of collateral and dai
        gem[i][v] = sub(gem[i][v], dink);
        dai[w]    = add(dai[w], mul(ilk.rate, dart));
        // update the total debt
        debt      = add(debt,   mul(ilk.rate, dart));

        bool cool = dart <= 0; // true when the stablecoin debt does not increase
        bool firm = dink >= 0; // true when the collateral balance does not decrease
        bool nice = cool && firm;
        bool calm = mul(ilk.Art, ilk.rate) <= ilk.line && debt <= Line; // true when the CDP remains under both collateral and total debt ceilings
        bool safe = mul(urn.art, ilk.rate) <= mul(urn.ink, ilk.spot); // true when the CDP's ratio of collateral to debt is above the collateral's liquidation ratio

        require((calm || cool) && (nice || safe));

        // authorisation
        require(wish(u, msg.sender) ||  nice);
        require(wish(v, msg.sender) || !firm);
        require(wish(w, msg.sender) || !cool);

        require(mul(urn.art, ilk.rate) >= ilk.dust || urn.art == 0);
        require(ilk.rate != 0);
        require(live == 1);
    }
    // --- CDP Fungibility ---
    // move collateral and/or debt between two user's CDPs
    function fork(bytes32 ilk, address src, address dst, int dink, int dart) public note {
        Urn storage u = urns[ilk][src];
        Urn storage v = urns[ilk][dst];
        Ilk storage i = ilks[ilk];

        u.ink = sub(u.ink, dink);
        u.art = sub(u.art, dart);
        v.ink = add(v.ink, dink);
        v.art = add(v.art, dart);

        // both sides consent
        require(wish(src, msg.sender) && wish(dst, msg.sender));

        // both sides safe
        require(mul(u.art, i.rate) <= mul(u.ink, i.spot));
        require(mul(v.art, i.rate) <= mul(v.ink, i.spot));

        // both sides non-dusty
        require(mul(u.art, i.rate) >= i.dust || u.art == 0);
        require(mul(v.art, i.rate) >= i.dust || v.art == 0);
    }
    // --- CDP Confiscation ---
    function grab(bytes32 i, address u, address v, address w, int dink, int dart) public note auth { // grab is only called on Cat.bite where dink and dart are negative
        Urn storage urn = urns[i][u];
        Ilk storage ilk = ilks[i];

        // Subtract collateral and dai from the CDP
        urn.ink = add(urn.ink, dink);
        urn.art = add(urn.art, dart);
        ilk.Art = add(ilk.Art, dart);

        // Add the CDP's collateral (gems) to the v's free gems. When this is called by Cat.bite, v is the cat contract
        gem[i][v] = sub(gem[i][v], dink);
        // Add the debt to the total debt (vice) and to w's debt (sin). When this is called by Cat.bite, w is the vow contract
        sin[w]    = sub(sin[w], mul(ilk.rate, dart));
        vice      = sub(vice,   mul(ilk.rate, dart));
    }

    // --- Settlement ---
    // destroy (or create) equal amounts of debt and dai
    function heal(address u, address v, int rad) public note auth {
        sin[u] = sub(sin[u], rad);
        dai[v] = sub(dai[v], rad);
        vice   = sub(vice,   rad);
        debt   = sub(debt,   rad);
    }

    // --- Rates ---
    function fold(bytes32 i, address u, int rate) public note auth { // this is only called by Jug.drip, where u is the Vow contract address
        Ilk storage ilk = ilks[i];
        ilk.rate = add(ilk.rate, rate); // rate is accumulated stabilty fee
        int rad  = mul(ilk.Art, rate); // stability fee must be repaid so the total debt increases
        dai[u]   = add(dai[u], rad);
        debt     = add(debt,   rad);
    }
}
