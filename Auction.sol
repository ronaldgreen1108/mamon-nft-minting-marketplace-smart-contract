// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

/**
 * @title Ownable
 * @dev The Ownable contract has an owner address, and provides basic authorization control
 * functions, this simplifies the implementation of "user permissions".
 */
contract Ownable {
  address public owner;


  /**
   * @dev The Ownable constructor sets the original `owner` of the contract to the sender
   * account.
   */
  constructor() {
    owner = msg.sender;
  }


  /**
   * @dev Throws if called by any account other than the owner.
   */
  modifier onlyOwner() {
    require(msg.sender == owner);
    _;
  }


  /**
   * @dev Allows the current owner to transfer control of the contract to a newOwner.
   * @param newOwner The address to transfer ownership to.
   */
  function transferOwnership(address newOwner) public onlyOwner {
    if (newOwner != address(0)) {
      owner = newOwner;
    }
  }

}



/// @title Interface for contracts conforming to ERC-721: Non-Fungible Tokens
contract ERC721 {
    // Required methods
    function totalSupply() public view returns (uint256 total) {}
    function balanceOf(address _owner) public view returns (uint256 balance) {}
    function ownerOf(uint256 _tokenId) external view returns (address owner) {}
    function approve(address _to, uint256 _tokenId) external {}
    function transfer(address _to, uint256 _tokenId) external {}
    function transferFrom(address _from, address _to, uint256 _tokenId) external {}

    // Events
    event Transfer(address from, address to, uint256 tokenId);
    event Approval(address owner, address approved, uint256 tokenId);

    // Optional
    // function name() public view returns (string name);
    // function symbol() public view returns (string symbol);
    // function tokensOfOwner(address _owner) external view returns (uint256[] tokenIds);
    // function tokenMetadata(uint256 _tokenId, string _preferredTransport) public view returns (string infoUrl);

    // ERC-165 Compatibility (https://github.com/ethereum/EIPs/issues/165)
    function supportsInterface(bytes4 _interfaceID) external view returns (bool) {}
}



contract ERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) public returns (bool) {}
    function approve(address spender, uint256 amount) public returns (bool) {}
    function transfer(address recipient, uint256 amount) public returns (bool) {}
    function allowance(address owner, address spender) public view returns (uint256) {}
}





/// @title Auction Core
/// @dev Contains models, variables, and internal methods for the auction.
contract ClockAuctionBase {

    // Represents an auction on an NFT
    struct Auction {
        // Current owner of NFT
        address seller;
        // Price (in wei) at beginning of auction
        uint256 startingPrice;
        // Price (in wei) at end of auction
        uint256 endingPrice;
        // Payment Type
        uint256 paymentType;
        // Duration (in seconds) of auction
        uint64 duration;
        // Time when auction started
        // NOTE: 0 if this auction has been concluded
        uint64 startedAt;
    }
    
    
    struct Bid {
        address applicant;
        uint256 price;
    }

    // Reference to contract tracking NFT ownership
    ERC721 public nonFungibleContract;
    
    ERC20 public wbnb;
    ERC20 public fast;
    ERC20 public duke;
    
    mapping (uint256 => ERC20) indexToPaymentType;

    // Cut owner takes on each auction, measured in basis points (1/100 of a percent).
    // Values 0-10,000 map to 0%-100%
    uint256 public ownerCut;

    // Map from token ID to their corresponding auction.
    mapping (uint256 => Auction) tokenIdToAuction;
    mapping (uint256 => Bid[]) tokenIdToBids;
    mapping (address => Bid) addressToBid;
    mapping(address => mapping(address => uint256)) public allowed;
    
    uint256[] tokenIdsAuction;
    mapping(uint256=>uint256) indexOfTokenIds;


    event AuctionCreated(uint256 tokenId, uint256 startingPrice, uint256 endingPrice, uint256 duration);
    event AuctionSuccessful(uint256 tokenId, uint256 totalPrice, address winner);
    event AuctionCancelled(uint256 tokenId);
    
    function getIdsAuction() public view returns(uint256[] memory){
        return tokenIdsAuction;
    }
    
    function getBids(uint256 tokenId) public view returns(Bid[] memory){
        return tokenIdToBids[tokenId];
    }

    function removeIdFromAuctions(uint256 _valueToFindAndRemove) internal {
    
        uint index = indexOfTokenIds[_valueToFindAndRemove];
        if(index>=0){
            if (tokenIdsAuction.length > 0) {
                tokenIdsAuction[index] = tokenIdsAuction[tokenIdsAuction.length-1];
                indexOfTokenIds[tokenIdsAuction[tokenIdsAuction.length-1]] = index;
            }
            tokenIdsAuction.pop(); 
        }
    }
    /// @dev Returns true if the claimant owns the token.
    /// @param _claimant - Address claiming to own the token.
    /// @param _tokenId - ID of token whose ownership to verify.
    function _owns(address _claimant, uint256 _tokenId) internal view returns (bool) {
        return (nonFungibleContract.ownerOf(_tokenId) == _claimant);
    }

    /// @dev Escrows the NFT, assigning ownership to this contract.
    function _escrow(address _owner, uint256 _tokenId) public {
        // it will throw if transfer fails
        nonFungibleContract.transferFrom(_owner, address(this), _tokenId);
    }

    /// @dev Transfers an NFT owned by this contract to another address.
    function _transfer(address _receiver, uint256 _tokenId) public {
        // it will throw if transfer fails
        nonFungibleContract.transferFrom(address(this), _receiver, _tokenId);
    }

    /// @dev Adds an auction to the list of open auctions. Also fires the
    function _addAuction(uint256 _tokenId, Auction memory _auction) internal {
        // Require that all auctions have a duration of
        // at least one minute. (Keeps our math from getting hairy!)
        require(_auction.duration >= 1 minutes);

        tokenIdToAuction[_tokenId] = _auction;
        indexOfTokenIds[_tokenId] = tokenIdsAuction.length;
        tokenIdsAuction.push(_tokenId);
        
        emit AuctionCreated(
            uint256(_tokenId),
            uint256(_auction.startingPrice),
            uint256(_auction.endingPrice),
            uint256(_auction.duration)
        );
    }

    /// @dev Cancels an auction unconditionally.
    function _cancelAuction(uint256 _tokenId, address _seller) internal {
        _removeAuction(_tokenId);
        _transfer(_seller, _tokenId);
        emit AuctionCancelled(_tokenId);
    }

    /// @dev Computes the price and transfers winnings.
    /// Does NOT transfer ownership of token.
    function _bid(uint256 _tokenId, uint256 _bidAmount, address _applicant)
        internal
        returns (uint256)
    {
        // Get a reference to the auction struct
        Auction storage auction = tokenIdToAuction[_tokenId];

        require(_isOnAuction(auction));

        // Check that the bid is greater than or equal to the current price
        uint256 price = _currentPrice(auction);
        require(_bidAmount >= price);

        // Grab a reference to the seller before the auction struct
        // gets deleted.
        address seller = auction.seller;
        
        Bid memory newBid = Bid(
            _applicant,
            uint128(_bidAmount)
        );
        tokenIdToBids[_tokenId].push(newBid);
        addressToBid[_applicant] = newBid;
        
        allowed[address(this)][seller] = _bidAmount;

        return price;
    }
    
    
    function _accept(uint256 _tokenId, address _applicant)
        internal
        returns (uint256)
    {
         // Get a reference to the auction struct
        Auction storage auction = tokenIdToAuction[_tokenId];

        // Explicitly check that this auction is currently live.
        // (Because of how Ethereum mappings work, we can't just count
        // on the lookup above failing. An invalid _tokenId will just
        // return an auction object that is all zeros.)
        require(_isOnAuction(auction));


        address seller = auction.seller;

        // The bid is good! Remove the auction before sending the fees
        // to the sender so we can't have a reentrancy attack.
        _removeAuction(_tokenId);
        
        Bid memory bid = addressToBid[_applicant];
        
        // Transfer proceeds to seller (if there are any!)
        indexToPaymentType[auction.paymentType].transferFrom(_applicant, seller, bid.price);
        
        //remove all candidate bids
        delete tokenIdToBids[_tokenId];
        
        // Tell the world!
        emit AuctionSuccessful(_tokenId, bid.price, msg.sender);

        return bid.price;
    }

    /// @dev Removes an auction from the list of open auctions.
    /// @param _tokenId - ID of NFT on auction.
    function _removeAuction(uint256 _tokenId) internal {
        delete tokenIdToAuction[_tokenId];
        removeIdFromAuctions(_tokenId);
    }

    /// @dev Returns true if the NFT is on auction.
    /// @param _auction - Auction to check.
    function _isOnAuction(Auction storage _auction) internal view returns (bool) {
        return (_auction.startedAt > 0);
    }

    /// @dev Returns current price of an NFT on auction. Broken into two
    ///  functions (this one, that computes the duration from the auction
    ///  structure, and the other that does the price computation) so we
    ///  can easily test that the price computation works correctly.
    function _currentPrice(Auction storage _auction)
        internal
        view
        returns (uint256)
    {
        uint256 secondsPassed = 0;

        // A bit of insurance against negative values (or wraparound).
        // Probably not necessary (since Ethereum guarnatees that the
        // now variable doesn't ever go backwards).
        if (block.timestamp > _auction.startedAt) {
            secondsPassed = block.timestamp - _auction.startedAt;
        }

        return _computeCurrentPrice(
            _auction.startingPrice,
            _auction.endingPrice,
            _auction.duration,
            secondsPassed
        );
    }

    /// @dev Computes the current price of an auction. Factored out
    ///  from _currentPrice so we can run extensive unit tests.
    ///  When testing, make this function public and turn on
    ///  `Current price computation` test suite.
    function _computeCurrentPrice(
        uint256 _startingPrice,
        uint256 _endingPrice,
        uint256 _duration,
        uint256 _secondsPassed
    )
        internal
        pure
        returns (uint256)
    {

        if (_secondsPassed >= _duration) {
            // We've reached the end of the dynamic pricing portion
            // of the auction, just return the end price.
            return _endingPrice;
        } else {
            // Starting price can be higher than ending price (and often is!), so
            // this delta can be negative.
            int256 totalPriceChange = int256(_endingPrice) - int256(_startingPrice);

            // This multiplication can't overflow, _secondsPassed will easily fit within
            // 64-bits, and totalPriceChange will easily fit within 128-bits, their product
            // will always fit within 256-bits.
            int256 currentPriceChange = totalPriceChange * int256(_secondsPassed) / int256(_duration);

            // currentPriceChange can be negative, but if so, will have a magnitude
            // less that _startingPrice. Thus, this result will always end up positive.
            int256 currentPrice = int256(_startingPrice) + currentPriceChange;

            return uint256(currentPrice);
        }
    }

    /// @dev Computes owner's cut of a sale.
    function _computeCut(uint256 _price) internal view returns (uint256) {

        return _price * ownerCut / 10000;
    }

}







/**
 * @title Pausable
 * @dev Base contract which allows children to implement an emergency stop mechanism.
 */
contract Pausable is Ownable {
  event Pause();
  event Unpause();

  bool public paused = false;


  /**
   * @dev modifier to allow actions only when the contract IS paused
   */
  modifier whenNotPaused() {
    require(!paused);
    _;
  }

  /**
   * @dev modifier to allow actions only when the contract IS NOT paused
   */
  modifier whenPaused {
    require(paused);
    _;
  }

  /**
   * @dev called by the owner to pause, triggers stopped state
   */
  function pause() public onlyOwner whenNotPaused returns (bool) {
    paused = true;
    emit Pause();
    return true;
  }

  /**
   * @dev called by the owner to unpause, returns to normal state
   */
  function unpause() public onlyOwner whenPaused returns (bool) {
    paused = false;
    emit Unpause();
    return true;
  }
}


/// @title Clock auction for non-fungible tokens.
/// @notice We omit a fallback function to prevent accidental sends to this contract.
contract ClockAuction is Pausable, ClockAuctionBase {

    /// @dev The ERC-165 interface signature for ERC-721.
    bytes4 constant InterfaceSignature_ERC721 = bytes4(0x9a20483d);

    /// @dev Constructor creates a reference to the NFT ownership contract
    ///  and verifies the owner cut is in the valid range.
    constructor(address _nftAddress, address _wbnb, address _fast, address _duke, uint256 _cut) {
        require(_cut <= 10000);
        ownerCut = _cut;

        ERC721 candidateContract = ERC721(_nftAddress);
        // require(candidateContract.supportsInterface(InterfaceSignature_ERC721));
        nonFungibleContract = candidateContract;
        wbnb = ERC20(_wbnb);
        fast = ERC20(_fast);
        duke = ERC20(_duke);
        
        indexToPaymentType[0] = wbnb;
        indexToPaymentType[1] = fast;
        indexToPaymentType[2] = duke;
    }

    /// @dev Remove all Ether from the contract, which is the owner's cuts
    function withdrawBalance() external returns (bool){
        address nftAddress = address(nonFungibleContract);

        require(
            msg.sender == owner ||
            msg.sender == nftAddress
        );
        // We are using this boolean method to make sure that even if one fails it will still work
        bool res = payable(nftAddress).send(address(this).balance);
        return res;
    }

    /// @dev Creates and begins a new auction.
    function createAuction(
        uint256 _tokenId,
        uint256 _startingPrice,
        uint256 _endingPrice,
        uint256 _duration,
        uint256 _payment,
        address _seller
    )
        external
        virtual
        whenNotPaused
    {
        // Sanity check that no inputs overflow how many bits we've allocated
        // to store them in the auction struct.
        require(_startingPrice == uint256(uint128(_startingPrice)));
        require(_endingPrice == uint256(uint128(_endingPrice)));
        require(_duration == uint256(uint64(_duration)));

        require(_owns(msg.sender, _tokenId));
        _escrow(msg.sender, _tokenId);
        //_escrow(nonFungibleContract, _tokenId);
        Auction memory auction = Auction(
            _seller,
            uint128(_startingPrice),
            uint128(_endingPrice),
            uint128(_payment),
            uint64(_duration),
            uint64(block.timestamp)
        );
        _addAuction(_tokenId, auction);
    }

    /// @dev Bids on an open auction, completing the auction and transferring
    function bid(uint256 _tokenId, uint256 _amount)
        external
        virtual
        whenNotPaused
    {
        // _bid will throw if the bid or funds transfer fails
        _bid(_tokenId, _amount, msg.sender);
        // _transfer(msg.sender, _tokenId);
    }
    
    function accept(uint256 _tokenId, address _applicant)
        external
        virtual
        payable
        whenNotPaused
    {
        // _bid will throw if the bid or funds transfer fails
        _accept(_tokenId, _applicant);
        _transfer(_applicant, _tokenId);
    }

    /// @dev Cancels an auction that hasn't been won yet.
    function cancelAuction(uint256 _tokenId)
        external
    {
        Auction storage auction = tokenIdToAuction[_tokenId];
        require(_isOnAuction(auction));
        address seller = auction.seller;
        require(msg.sender == seller);
        _cancelAuction(_tokenId, seller);
    }

    /// @dev Cancels an auction when the contract is paused.
    function cancelAuctionWhenPaused(uint256 _tokenId)
        whenPaused
        onlyOwner
        external
    {
        Auction storage auction = tokenIdToAuction[_tokenId];
        require(_isOnAuction(auction));
        _cancelAuction(_tokenId, auction.seller);
    }

    /// @dev Returns auction info for an NFT on auction.
    /// @param _tokenId - ID of NFT on auction.
    function getAuction(uint256 _tokenId)
        external
        view
        returns
    (
        address seller,
        uint256 startingPrice,
        uint256 endingPrice,
        uint256 paymentType,
        uint256 duration,
        uint256 startedAt
    ) {
        Auction storage auction = tokenIdToAuction[_tokenId];
        require(_isOnAuction(auction));
        return (
            auction.seller,
            auction.startingPrice,
            auction.endingPrice,
            auction.paymentType,
            auction.duration,
            auction.startedAt
        );
    }

    /// @dev Returns the current price of an auction.
    /// @param _tokenId - ID of the token price we are checking.
    function getCurrentPrice(uint256 _tokenId)
        external
        view
        returns (uint256)
    {
        Auction storage auction = tokenIdToAuction[_tokenId];
        require(_isOnAuction(auction));
        return _currentPrice(auction);
    }

}


/// @title Clock auction modified for sale of kitties
/// @notice We omit a fallback function to prevent accidental sends to this contract.
contract SaleClockAuction is ClockAuction {

    // @dev Sanity check that allows us to ensure that we are pointing to the
    //  right auction in our setSaleAuctionAddress() call.
    bool public isSaleClockAuction = true;
    
    // Tracks last 5 sale price of gen0 kitty sales
    uint256 public gen0SaleCount;
    uint256[5] public lastGen0SalePrices;

    // Delegate constructor
    constructor(address _nftAddr, address _wbnb, address _fast, address _duke, uint256 _cut) ClockAuction(_nftAddr, _wbnb, _fast, _duke, _cut) {}

    /// @dev Creates and begins a new auction.
    function createAuction(
        uint256 _tokenId,
        uint256 _startingPrice,
        uint256 _endingPrice,
        uint256 _payment,
        uint256 _duration,
        address _seller
    )
        external override
    {
        // Sanity check that no inputs overflow how many bits we've allocated
        // to store them in the auction struct.
        require(_startingPrice == uint256(uint128(_startingPrice)));
        require(_endingPrice == uint256(uint128(_endingPrice)));
        require(_duration == uint256(uint64(_duration)));

        // require(msg.sender == address(nonFungibleContract));
        _escrow(_seller, _tokenId);
        Auction memory auction = Auction(
            _seller,
            uint128(_startingPrice),
            uint128(_endingPrice),
            uint128(_payment),
            uint64(_duration),
            uint64(block.timestamp)
        );
        _addAuction(_tokenId, auction);
    }

    /// @dev Updates lastSalePrice if seller is the nft contract
    /// Otherwise, works the same as default bid method.
    function bid(uint256 _tokenId, uint256 _amount)
        external override
        // returns (address buyer, uint256 value, uint retPrice)
    {
        // _bid verifies token ID size
        tokenIdToAuction[_tokenId].seller;
        _bid(_tokenId, _amount, msg.sender);
        // return (seller, msg.value, price);
        // _transfer(msg.sender, _tokenId);

    }
    
    function accept(uint256 _tokenId, address _applicant)
        external
        override
        payable
        // returns (address buyer, uint256 value, uint retPrice)
    {
        // _bid verifies token ID size
        _accept(_tokenId, _applicant);
        // return (seller, msg.value, price);
        _transfer(_applicant, _tokenId);

    }

}
