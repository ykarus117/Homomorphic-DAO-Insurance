import { ethers } from "ethers";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  const deployFHEInsurance = await deploy("Insurance", {
    args: ["test", "T", "test", ethers.ZeroAddress],
    from: deployer,
    log: true,
  });

  console.log(`FHEInsurance contract: `, deployFHEInsurance.address);
};
export default func;
func.id = "deploy_fheInsurance"; // id required to prevent reexecution
func.tags = ["FHEInsurance"];
