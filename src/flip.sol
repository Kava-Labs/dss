/// flip.sol -- Collateral auction

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

import "./lib.sol";

contract VatLike {
    function move(address,address,uint) public;
    function flux(bytes32,address,address,uint) public;
}

/*
   This thing lets you flip some gems for a given amount of dai.
   Once the given amount of dai is raised, gems are forgone instead.

 - `lot` gems for sale
 - `tab` total dai wanted
 - `bid` dai paid
 - `gal` receives dai income
 - `urn` receives gem forgone
 - `ttl` single bid lifetime
 - `beg` minimum bid increase
 - `end` max auction duration
*/

contract Flipper is DSNote {
    // --- Data ---
    struct Bid {
        uint256 bid; // quantity being offered for 'lot'
        uint256 lot; // quantity up for auction
        address guy;  // high bidder
        uint48  tic;  // expiry time
        uint48  end;  // "when the auction will end". How is this different from tic?
        address urn;
        address gal; // recipient of auction income
        uint256 tab; // total dai to be raised in auction
    }

    mapping (uint => Bid) public bids;

    VatLike public   vat;
    bytes32 public   ilk;

    uint256 constant ONE = 1.00E27;
    uint256 public   beg = 1.05E27;  // 5% minimum bid increase
    uint48  public   ttl = 3 hours;  // 3 hours bid duration
    uint48  public   tau = 2 days;   // 2 days total auction length
    uint256 public kicks = 0;

    // --- Events ---
    event Kick(
      uint256 id,
      uint256 lot,
      uint256 bid,
      uint256 tab,
      address indexed urn,
      address indexed gal
    );

    // --- Init ---
    constructor(address vat_, bytes32 ilk_) public {
        vat = VatLike(vat_);
        ilk = ilk_;
    }

    // --- Math ---
    function add(uint48 x, uint48 y) internal pure returns (uint48 z) {
        require((z = x + y) >= x);
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Auction ---
    // Create a bid object (that will expire in two days) and move the collateral being sold to this flip contract
    function kick(address urn, address gal, uint tab, uint lot, uint bid) // initiate an auction
    //                        vow addresss     dai   collateral     0
        public note returns (uint id)
    {
        require(kicks < uint(-1));
        id = ++kicks;

        bids[id].bid = bid;
        bids[id].lot = lot;
        bids[id].guy = msg.sender; // configurable??
        bids[id].end = add(uint48(now), tau);
        bids[id].urn = urn;
        bids[id].gal = gal;
        bids[id].tab = tab;
        // note: tic not set

        vat.flux(ilk, msg.sender, address(this), lot); // transfer 'lot' collateral (of type 'ilk') from msg.sender to this flip contract

        emit Kick(id, lot, bid, tab, urn, gal);
    }
    // Extend the duration of auction if no one has placed a bid yet ?
    function tick(uint id) public note {
        require(bids[id].end < now);
        require(bids[id].tic == 0);
        bids[id].end = add(uint48(now), tau);
    }
    // Place a bid for the collateral. This can only be called until the dai offered in the auction equals the dai debt required by the liquidated CDP. At that point further bids must be placed by calling 'dent'.
    function tend(uint id, uint lot, uint bid) public note { // compete for increasing bid amounts of gem. stops once tab amount raised?
        require(bids[id].guy != address(0));
        require(bids[id].tic > now || bids[id].tic == 0); // follow up bids must be submitted within 3 hours of previous bid?
        require(bids[id].end > now);

        require(lot == bids[id].lot);
        require(bid <= bids[id].tab);
        require(bid >  bids[id].bid);
        require(mul(bid, ONE) >= mul(beg, bids[id].bid) || bid == bids[id].tab); // check for minimum bid size

        // transfer dai
        vat.move(msg.sender, bids[id].guy, bids[id].bid); // pay off previous bidder
        vat.move(msg.sender, bids[id].gal, bid - bids[id].bid); // pay extra dai to ultimate receiver

        bids[id].guy = msg.sender; // 'guy' tracks who the last bidder was, so that their dai can be returned to them when new bids come in
        bids[id].bid = bid;
        bids[id].tic = add(uint48(now), ttl); // ttl = 3 hours
    }
    // Place a bid for the collateral. This can only be called after the "tend phase" is over (see above).
    // Incremental bids are placed by offering to take less and less of the collateral for the same amount of dai (rather than offering up more dai for a fixed amount of collateral, as happens in the tend phase).
    // The collateral that is not taken is returned to the original CDP, hence to the original owner.
    function dent(uint id, uint lot, uint bid) public note { // compete for decreasing lot amounts of gem
        require(bids[id].guy != address(0));
        require(bids[id].tic > now || bids[id].tic == 0);
        require(bids[id].end > now);

        require(bid == bids[id].bid);
        require(bid == bids[id].tab);
        require(lot < bids[id].lot);
        require(mul(beg, lot) <= mul(bids[id].lot, ONE)); // beg > 1, this ensures a minimum bid size

        // transfer dai
        vat.move(msg.sender, bids[id].guy, bid); // pay off previous bidder
        // transfer "unsold" collateral back to the original urn, hence original owner. (Cat.bite confiscates all the collateral to start off with, so this is the mechanism whereby not all their collateral is taken)
        vat.flux(ilk, address(this), bids[id].urn, bids[id].lot - lot);

        bids[id].guy = msg.sender;
        bids[id].lot = lot;
        bids[id].tic = add(uint48(now), ttl);
    }
    // Claim the winning bid after the auction has timed out.
    function deal(uint id) public note {
        require(bids[id].tic != 0 && (bids[id].tic < now || bids[id].end < now)); // check auction expired
        // transfer collateral
        vat.flux(ilk, address(this), bids[id].guy, bids[id].lot);
        delete bids[id];
    }
}
