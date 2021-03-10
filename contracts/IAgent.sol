pragma solidity 0.5.17;


interface IAgent {
   
   function transfer(address _token, address _to, uint256 _value) external;
   
}