import { FhevmType } from "@fhevm/hardhat-plugin";
import { BytesLike } from "ethers";
import { task, types } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

task("task:init", "Init the insurance contract").setAction(async function (taskArguments: TaskArguments, hre) {
  const { ethers, deployments, fhevm } = hre;
  await fhevm.initializeCLIApi();

  const FHEInsuranceDeployment = taskArguments.address
    ? { address: taskArguments.address }
    : await deployments.get("Insurance");
  console.log(`FHEInsurance: ${FHEInsuranceDeployment.address}`);

  const signers = await ethers.getSigners();

  const fheInsurance = await ethers.getContractAt("Insurance", FHEInsuranceDeployment.address);
  const tx = await fheInsurance.connect(signers[0]).Init();
  console.log(`Wait for tx:${tx.hash}...`);

  const receipt = await tx.wait();
  console.log(`tx:${tx.hash} status=${receipt?.status}`);
});

task("task:Evaluate", "Calls the Evaluate() function of the Insurance contract")
  .addVariadicPositionalParam(
    "attributes",
    "Array of [age, gender, health, duration, requested amount, isLife]",
    undefined,
    types.int,
  )
  .setAction(async function (taskArguments: TaskArguments, hre) {
    const { ethers, deployments, fhevm } = hre;
    await fhevm.initializeCLIApi();

    const attributes = taskArguments.attributes;
    console.log(attributes);
    if (attributes.length !== 6) {
      throw new Error(`Expected exactly 6 attributes, got ${attributes.length}`);
    }

    const FHEInsuranceDeployment = taskArguments.address
      ? { address: taskArguments.address }
      : await deployments.get("Insurance");
    console.log(`FHEInsurance: ${FHEInsuranceDeployment.address}`);

    const signers = await ethers.getSigners();

    const fheInsurance = await ethers.getContractAt("Insurance", FHEInsuranceDeployment.address);

    const params = [];
    const proofs = [];

    // age, gender, health
    for (let i = 0; i < 5; i++) {
      // Encrypt the value passed as argument
      const encryptedValue = await fhevm
        .createEncryptedInput(FHEInsuranceDeployment.address, signers[0].address)
        .add64(parseInt(attributes[i]))
        .encrypt();
      params[i] = encryptedValue.handles[0];
      proofs[i] = encryptedValue.inputProof;
    }

    const encryptedLife = await fhevm
      .createEncryptedInput(FHEInsuranceDeployment.address, signers[0].address)
      .addBool(attributes[5])
      .encrypt();

    const tx = await fheInsurance
      .connect(signers[0])
      .Evaluation(
        params as [BytesLike, BytesLike, BytesLike, BytesLike, BytesLike],
        proofs as [BytesLike, BytesLike, BytesLike, BytesLike, BytesLike],
        encryptedLife.handles[0],
        encryptedLife.inputProof,
      );
    console.log(`Wait for tx:${tx.hash}...`);

    const receipt = await tx.wait();
    console.log(`tx:${tx.hash} status=${receipt?.status}`);
    for (const log of receipt?.logs) {
      try {
        const parsedLog = fheInsurance.interface.parseLog(log);
        if (parsedLog && parsedLog.name === "UserEvaluation") {
          const decryptedValue = await fhevm.userDecryptEuint(
            FhevmType.euint64,
            parsedLog.args[1],
            FHEInsuranceDeployment.address,
            signers[0],
          );
          console.log(`Decrypted user evaluation: ${decryptedValue}`);
        }
      } catch (e) {
        console.log(e);
      }
    }

    console.log(`Evaluation completed`);
  });
