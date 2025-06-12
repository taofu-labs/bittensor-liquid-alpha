const hre = require("hardhat");
const LiquidAlphaDeploy = require("../ignition/modules/LiquidAlphaDeploy.js");

async function main() {

  const { ls_alpha } = await hre.ignition.deploy(LiquidAlphaDeploy, {
    parameters: {
        "LiquidAlphaDeploy": {
            "name": "LiquidAlpha3",
            "symbol": "lstA3",
            "netuid": 3,
            "uid": 6
        }
    }
  });
  const taoIn   = hre.ethers.parseUnits("0.1", 18);

  console.log("Liquid Alpha address:", await ls_alpha.getAddress());

  const receiving_address = '';
  const paymentTx = await ls_alpha.depositTao(receiving_address, {value: taoIn})

  await paymentTx.wait();
  console.log("Tx mined:", paymentTx.hash);
}

main().catch(console.error);
