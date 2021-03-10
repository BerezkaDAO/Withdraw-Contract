var BerezkaWithdraw = artifacts.require("./BerezkaWithdraw.sol");

module.exports = function(deployer) {
  deployer.deploy(BerezkaWithdraw);
};
