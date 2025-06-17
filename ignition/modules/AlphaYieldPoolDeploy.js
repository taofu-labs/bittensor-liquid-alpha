// This setup uses Hardhat Ignition to manage smart contract deployments.
// Learn more about it at https://hardhat.org/ignition
const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");
const hre = require("hardhat");



module.exports = buildModule("AlphaYieldPoolDeploy", (m) => {
  const nameParam = m.getParameter('name', "AlphaYieldPool");
  const symbolParam = m.getParameter('symbol', "AlphaYP")
  const netuidParam = m.getParameter("netuid", 1);
  const uidParam = m.getParameter("uid", 0);

  const alpha_yp = m.contract("AlphaYieldPool", 
    [nameParam, symbolParam, netuidParam, uidParam]
  );

  return { alpha_yp };
});