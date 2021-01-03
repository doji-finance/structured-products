const Factory = artifacts.require("DojimaFactory");
const AdminUpgradeabilityProxy = artifacts.require("AdminUpgradeabilityProxy");
const { encodeCall } = require("@openzeppelin/upgrades");
const { ether, constants } = require("@openzeppelin/test-helpers");
const {
  updateDeployedAddresses,
} = require("../scripts/helpers/updateDeployedAddresses");
const ADDRESSES = require("../constants/externalAddresses.json");

module.exports = async function (deployer, network, accounts) {
  const [admin, owner] = accounts;

  let wethAddress;
  if (network === "development") {
    wethAddress = constants.ZERO_ADDRESS;
  } else {
    wethAddress = ADDRESSES[network].assets.weth;
  }

  await deployFactory(deployer, admin, owner);
  await updateDeployedAddresses(
    network,
    "DojimaFactory",
    AdminUpgradeabilityProxy.address
  );
};

async function deployFactory(deployer, admin, owner) {
  await deployer.deploy(Factory);

  const initBytes = encodeCall(
    "initialize",
    ["address", "address", "address", "address"],
    [owner, admin]
  );
  await deployer.deploy(
    AdminUpgradeabilityProxy,
    Factory.address,
    admin,
    initBytes,
    {
      from: admin,
    }
  );
}
