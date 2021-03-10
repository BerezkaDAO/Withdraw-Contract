pragma solidity 0.5.17;

import "./provableAPI.sol";
import "./IERC20.sol";
import "./Ownable.sol";
import "./IAgent.sol";
import "./ITokens.sol";

// This contract provides Withdraw function for Berezka DAO
// Basic flow is:
//  1. User creates a withdraw request, specifying what token he wants to exchange to stable conin
//  2. Oracle request is sent for an actual current token price
//  3. Oracle calls back with reliable price. Then an exchange is happening
//  4. In an event of Oracle failing, cancel function can be called by Owner to cancel request
//
contract BerezkaWithdraw is usingProvable, Ownable {
    
    // Information about withdrawal request
    //
    struct WithdrawRequest {
        bytes32 requestId; // Identifier (also an Oracle Service Query ID)
        address sender; // Who is withdrawing tokens
        uint256 amount; // What amount of tokens
        address token; // What exact token
        address targetToken; // What token he want to receive
        uint256 lastValidBlock; // Last block when this request is valid
    }
    
    // Information about DAO
    struct Dao {
        address agent; // Address of Aragon DAO Agent App
        address tokens; // Address of Aragon DAO Tokens App
    }
    
    // Token whitelist to withdraw
    //
    mapping(address => bool) public whitelist;

    // Each token have an agent to withdraw tokens from
    //
    mapping(address => Dao) public daoConfig;

    // Each user (address) can have at most one pending withdraw query
    //
    mapping(address => bytes32) public pendingQueries;

    // Remember withdraw requests
    //
    mapping(bytes32 => WithdrawRequest) public pendingRequests;

    uint256 public lastExchangePrice;
    
    // Address (IPFS Hash) of Oracle Script
    //
    string public oracleAddress = "QmZKqPPYNpKxBgaVBdMeEAL67wSxxr6aDnLeqgtEpVMHDA";
    
    // Gas required to call callback method
    //
    uint256 public oracleCallbackGas = 300000;
    
    // How many blocks requests are valid to receive callbacks?
    // By default use 1 hour (360 blocks)
    //
    uint256 public requestValidityDurationBlocks = 360;
    
    // Event used to log a creation of withdraw request
    //
    event WithdrawRequestCreated(
        uint256 _amountToWithdraw,
        address _tokenToWithraw,
        address _withdrawTo,
        bytes32 _queryId
    );

    // Event used to log a success completion of withdraw request
    //
    event WithdrawRequestSucceeded(
        uint256 _finalPrice,
        bytes32 _queryId
    );
    
    // Event used to log a failure to complete a withdraw request
    //
    event WithdrawRequestFailed(
        bytes32 _queryId
    );

    // Creates new instance
    //
    constructor() public {}

    // Main function. Allows user (msg.sender) to withdraw funds from DAO.
    // _amount - amount of DAO tokens to exhange
    // _token - token of DAO to exchange
    // _targetToken - token to receive in exchange
    // _optimisticPrice - an optimistic price of DAO token. Used to check if DAO Agent 
    //                    have enough funds on it's balance. Is not used to calculare
    //                    use returns
    function withdraw(
        uint256 _amount,
        address _token,
        address _targetToken,
        uint256 _optimisticPrice
    ) 
        public
        payable 
    {
        // Require that amount is positive
        //
        require(_amount > 0, 
            "ZERO_TOKEN_AMOUNT"
        );
        // Require that an optimistic price is set
        //
        require(_optimisticPrice > 0, 
            "ZERO_OPTIMISTIC_PRICE"
        );
        
        // Check that token to withdraw is whitelisted
        //
        require(whitelist[_targetToken],
            "INVALID_TOKEN_TO_WITHDRAW"
        );
    
        // Require no pending queries for this address
        //
        require(pendingQueries[msg.sender] == 0,
            "PENDING_REQUEST_IN_PROGRESS"
        );
        
        // Require that there is an agent (vault) address for  a given token
        //
        address agent = daoConfig[_token].agent;
        require(agent != address(0), 
            "NO_DAO_FOR_TOKEN"
        );
        
        // Require that an agent have funds to fullfill request (optimisitcally)
        // And that this contract can withdraw neccesary amount of funds from agent
        //
        IERC20 targetToken = IERC20(_targetToken);
        uint256 optimisticAmount = computeExchange(_amount, _optimisticPrice, _targetToken);
        require(optimisticAmount > 0, 
            "INVALID_TOKEN_AMOUNT"
        );
        require(targetToken.balanceOf(agent) >= optimisticAmount, 
            "INSUFFICIENT_FUNDS_ON_AGENT"
        );
        
        // Set gas price for provable equal gas price of current transaction
        //
        provable_setCustomGasPrice(tx.gasprice);
        
        // Check funds for oracle call
        //
        require(provable_getPrice("computation") <= address(this).balance, 
            "INSUFFICIENT_FUNDS_FOR_ORACLE_CALL"
        );
        
        // Send oracle query for price verification. Transfer from agent to sender 
        // will happen in oracle callback
        //
        bytes32 queryId =
            provable_query(
                "computation",
                [
                    oracleAddress,
                    strConcat("0x", _toAsciiString(_token))
                ],
                oracleCallbackGas
            );
        
        // queryId can be 0 as indication that something goes wrong on Oracle Side
        //
        if (queryId != 0) {
            // Add pending query for account
            //
            pendingQueries[msg.sender] = queryId;
            
            // Add pending request for processing
            //
            pendingRequests[queryId] = WithdrawRequest(
                queryId,
                msg.sender,
                _amount,
                _token,
                _targetToken,
                block.number + requestValidityDurationBlocks
            );
    
            emit WithdrawRequestCreated(_amount, _token, msg.sender, queryId);
        }
    }

    // Oracle callback function. Oracle will supply us with reliable price, so 
    // actual exchange action happens here
    // _queryID - withdraw request ID
    // _result - encoded as string reliable price
    //
    function __callback(
        bytes32 _queryID,
        string memory _result
    ) public {
        // Check that sender of transaction is indeed oracle service
        //
        require(msg.sender == provable_cbAddress(),
            "INVALID_CALLBACK_SENDER"
        );
        
        // Extract price from oracle response
        //
        lastExchangePrice = parseInt(_result);
        WithdrawRequest memory request = pendingRequests[_queryID];
        require(request.requestId == _queryID, 
            "REQUEST_IS_CANCELLED"
        );
        
        // Check that request is not expired
        //
        require(request.lastValidBlock >= block.number, 
            "REQUEST_IS_EXPIRED"
        );
        
        // Positive scenario - we've got a valid price from oracle
        //
        if (lastExchangePrice > 0) {
            uint256 finalAmount = computeExchange(request.amount, lastExchangePrice, request.targetToken);
            // Transfer target token from agent to owner
            //
            IAgent agent = IAgent(daoConfig[request.token].agent);
            agent.transfer(request.targetToken, request.sender, finalAmount);
            
            // Burn tokens
            //
            IERC20 token = IERC20(request.token);
            require(token.balanceOf(request.sender) >= request.amount, 
                "NOT_ENOUGH_TOKENS_TO_BURN_ON_BALANCE"
            );
            ITokens tokens = ITokens(daoConfig[request.token].tokens); // TODO ???
            tokens.burn(request.sender, request.amount);
            
            // Emit event that everything is fine
            //
            emit WithdrawRequestSucceeded(lastExchangePrice, _queryID);
        } else {
            // Emit event that something has failed
            //
            emit WithdrawRequestFailed(_queryID);
        }
        
        // Clean up
        //
        delete pendingQueries[request.sender];
        delete pendingRequests[_queryID];
    }
    
    // Computes an amount of _targetToken that user will get in exchange for
    // a given amount for DAO tokens
    // _amount - amount of DAO tokens
    // _price - price in 6 decimals per 10e18 of DAO token
    // _targetToken - target token to receive
    //
    function computeExchange(
        uint256 _amount,
        uint256 _price,
        address _targetToken
    )
        public 
        view 
        returns (uint256)
    {
        IERC20 targetToken = IERC20(_targetToken);
        return _amount * _price * 10 ** (targetToken.decimals() - 6) / 10**18;
    }
    
    // Cancels a current pending request withdraw query (in an event of Oracle failing to answer)
    // Can be performed by sender address
    // _queryId - ID of request to cancel
    //
    function cancel() 
        public 
    {
        
        _cancel(pendingQueries[msg.sender]);
    }
    
    // --- Administrative functions --- 
    
    // Adds new DAO to contract.
    // _token - DAO token
    // _tokens - corresponding Tokens service in Aragon, that manages _token
    // _agent - agent contract in Aragon (fund holder)
    //
    function addDao(
        address _token,
        address _tokens,
        address _agent
    )
        public 
        onlyOwner 
    {
        require(_token != address(0), 
            "INVALID_TOKEN_ADDRESS"
        );
        require(_agent != address(0), 
            "INVALID_TOKEN_ADDRESS"
        );
        require(_tokens != address(0),
            "INVALID_TOKENS_ADDRESS"
        );
        
        daoConfig[_token] = Dao(_agent, _tokens);
    }
    
    // Removes DAO from contract
    // _token - token to remove
    //
    function deleteDao(
        address _token
    ) 
        public 
        onlyOwner 
    {
        require(_token != address(0), 
            "INVALID_TOKEN_ADDRESS"
        );
        delete daoConfig[_token];
    }
    
    // Sets an address (IPFS Hash) of Oracle Script
    // _oracleAddres - IPFS Hash of Oracle Script
    //
    function setOracleAddress(
        string memory _oracleAddres    
    ) 
        public 
        onlyOwner 
    {
        oracleAddress = _oracleAddres;
    }
    
    // Sets amount of Gas used to call __callback function
    // _oracleCallbackGas - amount of gas
    //
    function setOracleGas(
        uint256 _oracleCallbackGas
    ) 
        public 
        onlyOwner 
    {
        oracleCallbackGas = _oracleCallbackGas;
    }
    
    // Sets duration (in blocks) for how long withdrawal request is still valid
    // _duration - duration in blocks
    //
    function setRequestDuration(
        uint256 _duration    
    ) 
        public
        onlyOwner
    {
        requestValidityDurationBlocks = _duration;
    }
    
    // Adds possible tokens (stableconins) to withdraw to
    // _whitelisted - list of stableconins to withdraw to
    //
    function addWhitelistTokens(
        address[] memory _whitelisted
    ) 
        public 
        onlyOwner 
    {
        for (uint256 i = 0; i < _whitelisted.length; i++) {
            whitelist[_whitelisted[i]] = true;
        }
    }
    
    // Removes possible tokens (stableconins) to withdraw to
    // _whitelisted - list of stableconins to withdraw to
    //
    function removeWhitelistTokens(
        address[] memory _whitelisted
    ) 
        public 
        onlyOwner 
    {
        for (uint256 i = 0; i < _whitelisted.length; i++) {
            whitelist[_whitelisted[i]] = false;
        }
    }
    
    // Cancels a pending withdraw query (in an event of Oracle failing to answer)
    // _queryId - ID of request to cancel
    //
    function cancel(
        bytes32 _queryId
    ) 
        public 
        onlyOwner 
    {
        _cancel(_queryId);
    }
    
    // --- Internal functions --- 
    
    // Cancels a pending withdraw query (in an event of Oracle failing to answer)
    // _queryId - ID of request to cancel
    //
    function _cancel(
        bytes32 _queryId
    ) 
        internal 
    {
        require(pendingRequests[_queryId].sender != address(0), 
            "REQUEST_NOT_EXISTS"
        );
        
        WithdrawRequest memory request = pendingRequests[_queryId];
        delete pendingQueries[request.sender];
        delete pendingRequests[_queryId];
    }

    // Converts address to string (for Oracle Service call)
    // _x - address to convert
    //
    function _toAsciiString(
        address _x
    )
        internal 
        pure 
        returns (string memory)
    {
        bytes memory s = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint256(uint160(_x)) / (2**(8 * (19 - i)))));
            bytes1 hi = bytes1(uint8(b) / 16);
            bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
            s[2 * i] = _char(hi);
            s[2 * i + 1] = _char(lo);
        }
        return string(s);
    }

    // Converts byte to char (for string conversion for Oracle Service call)
    // _b - byte to convert to char
    //
    function _char(
        bytes1 _b
    ) 
        internal 
        pure 
        returns (bytes1 c) 
    {
        if (uint8(_b) < 10) return bytes1(uint8(_b) + 0x30);
        else return bytes1(uint8(_b) + 0x57);
    }
}
