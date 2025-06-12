// This setup uses Hardhat Ignition to manage smart contract deployments.
// Learn more about it at https://hardhat.org/ignition
const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");
const hre = require("hardhat");



module.exports = buildModule("LiquidAlphaDeploy", (m) => {
  const nameParam = m.getParameter('name', "LiquidAlpha");
  const symbolParam = m.getParameter('symbol', "lsAlpha")
  const netuidParam = m.getParameter("netuid", 1);
  const uidParam = m.getParameter("uid", 0);
  const minPayment = hre.ethers.parseUnits("0.00055", 18);

  const ls_alpha = m.contract("LiquidAlpha", 
    [nameParam, symbolParam, netuidParam, uidParam, minPayment]
  );

  return { ls_alpha };
});