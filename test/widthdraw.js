const BerezkaWithdraw = artifacts.require("./BerezkaWithdraw.sol");

contract("BerezkaWithdraw", accounts => {
  it("...should be deployed", async () => {
    await BerezkaWithdraw.deployed();
  });
});
