require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config(); // Load .env file
/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.28",
  defaultNetwork: "bittensor_testnet",
  networks: {
    bittensor_testnet: {
      url: "https://test.chain.opentensor.ai",
      accounts: [process.env.PRIVATE_KEY],
      gasMultiplier: 2,
    },
    bittensor_local: {
      url: "http://localhost:9944/",
      accounts: [process.env.PRIVATE_KEY],
      gasMultiplier: 2,
      gasPrice: 1000000000,
    },
    bittensor_mainnet: {
      url: "https://lite.chain.opentensor.ai",
      gasMultiplier: 2,
    }
  },
  ignition: {
    requiredConfirmations: 1,
  }
};
