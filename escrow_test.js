const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Escrow and EscrowFactory", function () {
  let Escrow, EscrowFactory;
  let escrowFactory, escrow;
  let owner, mediator, participant1, participant2, recipient1, recipient2;
  const etherAmount = ethers.parseEther("1"); // 1 Ether

  beforeEach(async function () {
    [owner, mediator, participant1, participant2, recipient1, recipient2] =
      await ethers.getSigners();

    // Deploy contracts
    Escrow = await ethers.getContractFactory("Escrow");
    EscrowFactory = await ethers.getContractFactory("EscrowFactory");
    escrowFactory = await EscrowFactory.deploy();

    await escrowFactory.waitForDeployment();
  });

  async function deployAndInitializeEscrow() {
    const participants = [
      { addr: participant1.address, share: 5000 },
      { addr: participant2.address, share: 5000 },
    ];
    const recipients = [
      { addr: recipient1.address, share: 7000 },
      { addr: recipient2.address, share: 3000 },
    ];
    const assets = [
      { token: ethers.ZeroAddress, requiredAmount: etherAmount },
    ];

    const tx = await escrowFactory.createEscrow(
      mediator.address,
      participants,
      recipients,
      assets,
      5000,
      86400,
      86400,
      86400
    );

    const receipt = await tx.wait();

    // Verificar el evento
    const event = receipt.logs
      .map((log) => escrowFactory.interface.parseLog(log))
      .find((parsedLog) => parsedLog.name === "EscrowCreated");

    if (!event) {
      throw new Error("EscrowCreated event not found");
    }

    const escrowAddress = event.args.escrowAddress;
    return await Escrow.attach(escrowAddress);
  }

  describe("EscrowFactory", function () {
    it("should create a new escrow", async function () {
      escrow = await deployAndInitializeEscrow();
      expect(await escrow.mediator()).to.equal(mediator.address);
      expect(await escrow.state()).to.equal(0); // State.INIT
    });

    it("should list all escrows", async function () {
      await deployAndInitializeEscrow();
      await deployAndInitializeEscrow();

      const escrows = await escrowFactory.getAllEscrows();
      expect(escrows.length).to.equal(2);
    });
  });

  describe("Escrow", function () {
    beforeEach(async function () {
      escrow = await deployAndInitializeEscrow();
    });

    describe("General Cases", function () {

      it("should allow ETH deposit and transition state", async function () {
        // Validar estado inicial
        expect(await escrow.state()).to.equal(0); // State.INIT

        // Depositar fondos
        await escrow.connect(participant1).depositETH({ value: etherAmount });
        const balance1 = await escrow.deposits(
          participant1.address,
          ethers.ZeroAddress
        );
        expect(balance1).to.equal(etherAmount);

        // Validar transición de estado
        expect(await escrow.state()).to.equal(1); // State.AWAITING_CONFIRMATION
      });

      it("should not allow deposits after funding period", async function () {
        await escrow.connect(participant1).depositETH({ value: etherAmount });

        // Cambiar a un estado diferente
        await escrow.connect(participant1).confirm();

        await expect(
          escrow.connect(participant2).depositETH({ value: etherAmount })
        ).to.be.revertedWith("Invalid state");
      });

      it("should not allow deposits after funding period ends", async function () {
        await ethers.provider.send("evm_increaseTime", [86400]); // Avanzar el tiempo
        await ethers.provider.send("evm_mine");

        await expect(
          escrow.connect(participant1).depositETH({ value: etherAmount })
        ).to.be.revertedWith("Funding period expired");
      });



      it("should allow confirmations and resolve escrow", async function () {
        // Depositar fondos
        await escrow.connect(participant1).depositETH({ value: etherAmount });

        expect(await escrow.state()).to.equal(1); // State.AWAITING_CONFIRMATION

        // Confirmaciones
        await escrow.connect(participant1).confirm();

        // Validar transición de estado
        expect(await escrow.state()).to.equal(3); // State.RESOLVED
      });

      it("should not resolve escrow if confirmations are insufficient", async function () {
        // Crear un escrow con umbral de confirmación del 70%
        const customEscrow = await escrowFactory.createEscrow(
          mediator.address,
          [
            { addr: participant1.address, share: 5000 }, // 50%
            { addr: participant2.address, share: 5000 }, // 50%
          ],
          [
            { addr: recipient1.address, share: 7000 }, // 70%
            { addr: recipient2.address, share: 3000 }, // 30%
          ],
          [{ token: ethers.ZeroAddress, requiredAmount: etherAmount }], // 1 ETH requerido
          7000, // Umbral del 70%
          86400, // Período de funding
          86400, // Período de confirmación
          86400 // Período de disputa
        );

        const receipt = await customEscrow.wait();
        const escrowAddress = receipt.logs[0].args.escrowAddress;
        const escrow = await Escrow.attach(escrowAddress);

        // Dividir etherAmount por 2 usando operaciones BigInt
        const halfEtherAmount = etherAmount / BigInt(2);

        // Depositar 1 ETH por parte de ambos participantes
        await escrow.connect(participant1).depositETH({ value: halfEtherAmount });
        await escrow.connect(participant2).depositETH({ value: halfEtherAmount });

        // Validar que el estado sea AWAITING_CONFIRMATION
        expect(await escrow.state()).to.equal(1); // State.AWAITING_CONFIRMATION

        // Solo el primer participante confirma
        await escrow.connect(participant1).confirm();

        // Validar que el estado siga siendo AWAITING_CONFIRMATION
        expect(await escrow.state()).to.equal(1); // State.AWAITING_CONFIRMATION
      });



      it("should raise and resolve disputes", async function () {
        // Depositar fondos
        await escrow.connect(participant1).depositETH({ value: etherAmount });

        // Adelantar el tiempo para simular el final del período de confirmación
        await ethers.provider.send("evm_increaseTime", [86400]);
        await ethers.provider.send("evm_mine");

        // Iniciar disputa
        await escrow.connect(participant1).raiseDispute();
        expect(await escrow.state()).to.equal(2); // State.DISPUTE

        // Resolver disputa
        await escrow.connect(mediator).resolveDisputeRefundAll();
        expect(await escrow.state()).to.equal(4); // State.REFUNDED
      });

      it("should not allow disputes before confirmation period ends", async function () {
        await escrow.connect(participant1).depositETH({ value: etherAmount });

        await expect(
          escrow.connect(participant1).raiseDispute()
        ).to.be.revertedWith("Confirmation period not ended");
      });

      it("should not allow duplicate confirmations", async function () {
        // Crear un escrow con umbral de confirmación del 50%
        const customEscrow = await escrowFactory.createEscrow(
          mediator.address,
          [
            { addr: participant1.address, share: 5000 }, // 50%
            { addr: participant2.address, share: 5000 }, // 50%
          ],
          [
            { addr: recipient1.address, share: 7000 }, // 70%
            { addr: recipient2.address, share: 3000 }, // 30%
          ],
          [{ token: ethers.ZeroAddress, requiredAmount: etherAmount }], // 1 ETH requerido
          7000, // Umbral del 50%
          86400, // Período de funding
          86400, // Período de confirmación
          86400 // Período de disputa
        );

        const receipt = await customEscrow.wait();
        const escrowAddress = receipt.logs[0].args.escrowAddress;
        const escrow = await Escrow.attach(escrowAddress);

        // Ambos participantes aportan el monto requerido
        const halfEtherAmount = etherAmount / BigInt(2);
        await escrow.connect(participant1).depositETH({ value: halfEtherAmount });
        await escrow.connect(participant2).depositETH({ value: halfEtherAmount });

        // Validar que el estado sea AWAITING_CONFIRMATION
        expect(await escrow.state()).to.equal(1); // State.AWAITING_CONFIRMATION

        // Participant 1 realiza su primera confirmación
        await escrow.connect(participant1).confirm();

        // Participant 1 intenta confirmar nuevamente
        await expect(escrow.connect(participant1).confirm()).to.be.revertedWith(
          "Already confirmed"
        );
      });


      it("should not allow withdrawal if no funds are available", async function () {
        // Depositar fondos y confirmar para alcanzar el estado RESOLVED
        await escrow.connect(participant1).depositETH({ value: etherAmount });
        await escrow.connect(participant1).confirm();

        // Intentar retirar fondos de una cuenta sin balance
        await expect(
          escrow.connect(participant2).withdraw(ethers.ZeroAddress)
        ).to.be.revertedWith("Nothing to withdraw");
      });


      it("should distribute funds correctly among recipients", async function () {
        await escrow.connect(participant1).depositETH({ value: etherAmount });
        await escrow.connect(participant1).confirm();

        const recipient1Balance = await escrow.balancesToWithdraw(
          recipient1.address,
          ethers.ZeroAddress
        );
        const recipient2Balance = await escrow.balancesToWithdraw(
          recipient2.address,
          ethers.ZeroAddress
        );

        expect(recipient1Balance).to.equal(ethers.parseEther("0.7"));
        expect(recipient2Balance).to.equal(ethers.parseEther("0.3"));
      });



      it("should allow withdrawals", async function () {
        // Depositar fondos
        await escrow.connect(participant1).depositETH({ value: etherAmount });

        // Confirmaciones
        await escrow.connect(participant1).confirm();

        expect(await escrow.state()).to.equal(3); // State.RESOLVED

        // Retiro
        const initialBalance = await ethers.provider.getBalance(
          recipient1.address
        );

        await escrow.connect(recipient1).withdraw(ethers.ZeroAddress);
        const finalBalance = await ethers.provider.getBalance(
          recipient1.address
        );

        expect(finalBalance).to.be.gt(initialBalance);
      });



      it("should not resolve escrow until confirmation threshold is met", async function () {
        // Configurar un umbral alto (70%) y crear un escrow
        const participants = [
          { addr: participant1.address, share: 3000 }, // 30%
          { addr: participant2.address, share: 7000 }  // 70%
        ];
        const recipients = [
          { addr: recipient1.address, share: 10000 }   // 100%
        ];
        const assets = [{ token: ethers.ZeroAddress, requiredAmount: etherAmount }];

        const tx = await escrowFactory.createEscrow(
          mediator.address,
          participants,
          recipients,
          assets,
          7000, // Umbral de confirmaciones (70%)
          86400,
          86400,
          86400
        );

        const receipt = await tx.wait();
        const event = receipt.logs
          .map((log) => escrowFactory.interface.parseLog(log))
          .find((parsedLog) => parsedLog.name === "EscrowCreated");

        if (!event) throw new Error("EscrowCreated event not found");
        const attachedEscrow = await Escrow.attach(event.args.escrowAddress);

        // Depositar el monto total
        await attachedEscrow.connect(participant1).depositETH({ value: etherAmount });
        expect(await attachedEscrow.state()).to.equal(1); // State.AWAITING_CONFIRMATION

        // Participant1 confirma (30%, por debajo del umbral)
        await attachedEscrow.connect(participant1).confirm();
        expect(await attachedEscrow.state()).to.equal(1); // Sigue AWAITING_CONFIRMATION

        // Participant2 confirma (alcanza el umbral del 70%)
        await attachedEscrow.connect(participant2).confirm();
        expect(await attachedEscrow.state()).to.equal(3); // State.RESOLVED
      });

      it("should allow multiple small deposits to fulfill the funding requirement", async function () {
        const smallDeposit = ethers.parseEther("0.5"); // Depósito pequeño
        const requiredAmount = ethers.parseEther("1"); // Cantidad requerida

        const participants = [
          { addr: participant1.address, share: 5000 },
          { addr: participant2.address, share: 5000 }
        ];
        const recipients = [
          { addr: recipient1.address, share: 10000 }
        ];
        const assets = [{ token: ethers.ZeroAddress, requiredAmount }];

        const tx = await escrowFactory.createEscrow(
          mediator.address,
          participants,
          recipients,
          assets,
          5000,
          86400,
          86400,
          86400
        );

        const receipt = await tx.wait();
        const event = receipt.logs
          .map((log) => escrowFactory.interface.parseLog(log))
          .find((parsedLog) => parsedLog.name === "EscrowCreated");

        if (!event) throw new Error("EscrowCreated event not found");
        const attachedEscrow = await Escrow.attach(event.args.escrowAddress);

        // Participant1 realiza el primer depósito
        await attachedEscrow.connect(participant1).depositETH({ value: smallDeposit });
        const asset1 = await attachedEscrow.assets(0);
        expect(asset1.depositedAmount).to.equal(smallDeposit);

        // Participant2 realiza el segundo depósito
        await attachedEscrow.connect(participant2).depositETH({ value: smallDeposit });
        const asset2 = await attachedEscrow.assets(0);
        expect(asset2.depositedAmount).to.equal(requiredAmount);

        // Estado debería cambiar a AWAITING_CONFIRMATION
        expect(await attachedEscrow.state()).to.equal(1); // State.AWAITING_CONFIRMATION
      });

      it("should allow the mediator to change the mediator", async function () {
        // Verificar el mediador inicial
        expect(await escrow.mediator()).to.equal(mediator.address);

        // Cambiar el mediador
        await escrow.connect(mediator).changeMediator(participant1.address);

        // Verificar que el mediador se haya actualizado correctamente
        expect(await escrow.mediator()).to.equal(participant1.address);

        // Intentar cambiar el mediador con una cuenta no autorizada
        await expect(
          escrow.connect(participant2).changeMediator(participant2.address)
        ).to.be.revertedWith("Not mediator");

        // Verificar que el mediador no cambió después del intento fallido
        expect(await escrow.mediator()).to.equal(participant1.address);
      });

    });

    describe("Event Cases", function () {
      // PRUEBAS DE EVENTOS
      it("should emit Deposited event on ETH deposit", async function () {
        // Participant 1 realiza un depósito de Ether
        const tx = await escrow.connect(participant1).depositETH({ value: etherAmount });

        // Verificar que el evento `Deposited` se emitió correctamente
        await expect(tx)
          .to.emit(escrow, "Deposited")
          .withArgs(participant1.address, ethers.ZeroAddress, etherAmount); // Verifica contenido
      });

      it("should emit Confirmed event on participant confirmation", async function () {
        // Participant 1 deposita Ether y confirma
        await escrow.connect(participant1).depositETH({ value: etherAmount });
        const tx = await escrow.connect(participant1).confirm();

        // Verificar que el evento `Confirmed` se emitió correctamente
        await expect(tx)
          .to.emit(escrow, "Confirmed")
          .withArgs(participant1.address); // Verifica el participante que confirmó
      });

      it("should emit DisputeRaised event when a dispute is raised", async function () {
        // Depositar Ether y avanzar el tiempo para permitir disputas
        await escrow.connect(participant1).depositETH({ value: etherAmount });
        await ethers.provider.send("evm_increaseTime", [86400]); // Avanzar el tiempo
        await ethers.provider.send("evm_mine");

        const tx = await escrow.connect(participant1).raiseDispute();

        // Verificar que el evento `DisputeRaised` se emitió correctamente
        await expect(tx)
          .to.emit(escrow, "DisputeRaised")
          .withArgs(participant1.address); // Verifica quién levantó la disputa
      });

      it("should emit FundsAllocated event when funds are distributed to recipients", async function () {
        // Depositar fondos y confirmar
        await escrow.connect(participant1).depositETH({ value: etherAmount });
        const tx = await escrow.connect(participant1).confirm();

        // Verificar que los fondos se asignaron correctamente a los receptores
        const recipient1Share = ethers.parseEther("0.7"); // 70% de 1 ETH
        const recipient2Share = ethers.parseEther("0.3"); // 30% de 1 ETH

        await expect(tx)
          .to.emit(escrow, "FundsAllocated")
          .withArgs(recipient1.address, recipient1Share, ethers.ZeroAddress);
        await expect(tx)
          .to.emit(escrow, "FundsAllocated")
          .withArgs(recipient2.address, recipient2Share, ethers.ZeroAddress);
      });

      it("should emit Withdrawn event on successful withdrawal", async function () {
        // Depositar fondos y confirmar
        await escrow.connect(participant1).depositETH({ value: etherAmount });
        await escrow.connect(participant1).confirm();

        // Calcular el monto esperado para recipient1
        const expectedBalance = ethers.parseEther("0.7"); // 70% de 1 ETH

        // Realizar el retiro
        const tx = await escrow.connect(recipient1).withdraw(ethers.ZeroAddress);

        // Verificar que el evento `Withdrawn` se emitió correctamente
        await expect(tx)
          .to.emit(escrow, "Withdrawn")
          .withArgs(recipient1.address, expectedBalance, ethers.ZeroAddress); // Verifica contenido
      });

      it("should emit StateChanged event on state transitions", async function () {
        // Estado inicial -> AWAITING_CONFIRMATION
        const firstDeposit = await escrow.connect(participant1).depositETH({ value: etherAmount });

        // Verificar transición de estado: INIT -> AWAITING_CONFIRMATION
        await expect(firstDeposit)
          .to.emit(escrow, "StateChanged")
          .withArgs(0, 1); // 0 = INIT, 1 = AWAITING_CONFIRMATION

        // Confirmar y verificar la transición a RESOLVED
        const confirmationTx = await escrow.connect(participant1).confirm();
        await expect(confirmationTx)
          .to.emit(escrow, "StateChanged")
          .withArgs(1, 3); // 1 = AWAITING_CONFIRMATION, 3 = RESOLVED
      });

    });

    describe("Error Cases", function () {
      it("should revert if a non-mediator tries to resolve a dispute", async function () {
        // Depositar fondos y NO confirmamos para permitir disputas
        await escrow.connect(participant1).depositETH({ value: etherAmount });

        // Adelantar el tiempo para finalizar el período de confirmación
        await ethers.provider.send("evm_increaseTime", [88400]); // 1 día
        await ethers.provider.send("evm_mine");

        // Iniciar una disputa
        await escrow.connect(participant1).raiseDispute();

        // Intentar resolver la disputa con una cuenta no autorizada
        await expect(
          escrow.connect(participant1).resolveDisputeToRecipients()
        ).to.be.revertedWith("Not mediator");
      });


      it("should revert if a non-mediator tries to change the mediator", async function () {
        await expect(
          escrow.connect(participant1).changeMediator(participant1.address)
        ).to.be.revertedWith("Not mediator");
      });

      it("should revert if a non-participant tries to confirm", async function () {
        await escrow.connect(participant1).depositETH({ value: etherAmount });
        await expect(
          escrow.connect(recipient1).confirm()
        ).to.be.revertedWith("Not a participant"); // Cambiado a coincidir con el contrato
      });

      it("should revert if trying to withdraw funds before state is RESOLVED", async function () {
        // Depositar fondos para alcanzar el estado AWAITING_CONFIRMATION
        await escrow.connect(participant1).depositETH({ value: etherAmount });

        // Verificar que el estado es AWAITING_CONFIRMATION
        expect(await escrow.state()).to.equal(1); // State.AWAITING_CONFIRMATION

        // Intentar retirar fondos antes de que el estado sea RESOLVED
        await expect(
          escrow.connect(recipient1).withdraw(ethers.ZeroAddress)
        ).to.be.revertedWith("Invalid state");
      });
    });


    describe("Extreme Cases", function () {

      it("should handle an escrow with 1 participant and 1 recipient", async function () {
        const participants = [{ addr: participant1.address, share: 10000 }]; // 100% share
        const recipients = [{ addr: recipient1.address, share: 10000 }]; // 100% share
        const assets = [{ token: ethers.ZeroAddress, requiredAmount: etherAmount }];

        const tx = await escrowFactory.createEscrow(
          mediator.address,
          participants,
          recipients,
          assets,
          10000, // 100% confirmations threshold
          86400,
          86400,
          86400
        );

        const receipt = await tx.wait();
        const event = receipt.logs
          .map((log) => escrowFactory.interface.parseLog(log))
          .find((parsedLog) => parsedLog.name === "EscrowCreated");

        if (!event) throw new Error("EscrowCreated event not found");
        const minimalEscrow = await Escrow.attach(event.args.escrowAddress);

        // Participant deposits funds
        await minimalEscrow.connect(participant1).depositETH({ value: etherAmount });

        // Confirm and ensure resolution
        await minimalEscrow.connect(participant1).confirm();
        expect(await minimalEscrow.state()).to.equal(3); // State.RESOLVED

        // Check recipient balance
        const recipientBalance = await minimalEscrow.balancesToWithdraw(
          recipient1.address,
          ethers.ZeroAddress
        );
        expect(recipientBalance).to.equal(etherAmount);
      });

      it("should handle an escrow with many participants and recipients", async function () {
        const numParticipants = 50;
        const numRecipients = 50;

        const participantShares = Math.floor(10000 / numParticipants);
        const recipientShares = Math.floor(10000 / numRecipients);

        const signers = await ethers.getSigners();

        // Genera participantes únicos
        const additionalParticipants = Array.from(
          { length: numParticipants - signers.length },
          () => ethers.Wallet.createRandom()
        );

        // Transfiere Ether a las cuentas adicionales
        const transferAmount = ethers.parseEther("1");
        for (const wallet of additionalParticipants) {
          await signers[0].sendTransaction({
            to: wallet.address,
            value: transferAmount,
          });
        }

        const participants = [
          ...signers.slice(0, numParticipants).map((signer) => ({
            addr: signer.address,
            share: participantShares,
          })),
          ...additionalParticipants.map((wallet) => ({
            addr: wallet.address,
            share: participantShares,
            privateKey: wallet.privateKey,
          })),
        ];

        // Genera receptores únicos
        const additionalRecipients = Array.from(
          { length: numRecipients - signers.length },
          () => ethers.Wallet.createRandom()
        );

        const recipients = [
          ...signers.slice(0, numRecipients).map((signer) => ({
            addr: signer.address,
            share: recipientShares,
          })),
          ...additionalRecipients.map((wallet, i) => ({
            addr: wallet.address,
            share: i === numRecipients - 1
              ? 10000 - recipientShares * (numRecipients - 1)
              : recipientShares,
          })),
        ];

        const assets = [{ token: ethers.ZeroAddress, requiredAmount: etherAmount }];

        const tx = await escrowFactory.createEscrow(
          mediator.address,
          participants.map(({ addr, share }) => ({ addr, share })),
          recipients.map(({ addr, share }) => ({ addr, share })),
          assets,
          5000, // 50% confirmations threshold
          86400,
          86400,
          86400
        );

        const receipt = await tx.wait();
        const event = receipt.logs
          .map((log) => escrowFactory.interface.parseLog(log))
          .find((parsedLog) => parsedLog.name === "EscrowCreated");

        if (!event) throw new Error("EscrowCreated event not found");
        const largeEscrow = await Escrow.attach(event.args.escrowAddress);

        // El primer participante deposita fondos
        await largeEscrow.connect(signers[0]).depositETH({ value: etherAmount });

        // Combina los signers existentes con los wallets adicionales
        const allParticipants = [
          ...signers.slice(0, numParticipants),
          ...additionalParticipants.map((wallet) =>
            new ethers.Wallet(wallet.privateKey, ethers.provider)
          ),
        ];

        // Confirm from multiple participants
        for (let i = 0; i < numParticipants / 2; i++) {
          await largeEscrow.connect(allParticipants[i]).confirm();
        }

        // Verifica la transición de estado
        expect(await largeEscrow.state()).to.equal(3); // State.RESOLVED
      });

      it("should handle multiple assets (ETH and ERC20 tokens)", async function () {
        // Deploy the mock ERC20 token
        const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
        const mockToken = await ERC20Mock.deploy("Mock Token", "MCK", ethers.parseEther("1000"));

        // Transfer tokens to participant1
        await mockToken.transfer(participant1.address, ethers.parseEther("10"));

        // Create the assets array
        const assets = [
          { token: ethers.ZeroAddress, requiredAmount: etherAmount }, // ETH asset
          { token: mockToken.target, requiredAmount: ethers.parseEther("10") }, // ERC20 asset
        ];

        const participants = [{ addr: participant1.address, share: 10000 }];
        const recipients = [{ addr: recipient1.address, share: 10000 }];

        // Create an escrow
        const tx = await escrowFactory.createEscrow(
          mediator.address,
          participants,
          recipients,
          assets,
          10000,
          86400,
          86400,
          86400
        );

        const receipt = await tx.wait();
        const event = receipt.logs
          .map((log) => escrowFactory.interface.parseLog(log))
          .find((parsedLog) => parsedLog.name === "EscrowCreated");

        if (!event) throw new Error("EscrowCreated event not found");
        const multiAssetEscrow = await Escrow.attach(event.args.escrowAddress);

        // Approve the Escrow contract to spend participant1's tokens
        await mockToken.connect(participant1).approve(multiAssetEscrow.target, ethers.parseEther("10"));

        // Deposit ETH
        await multiAssetEscrow.connect(participant1).depositETH({ value: etherAmount });

        // Deposit ERC20 tokens
        await multiAssetEscrow
          .connect(participant1)
          .depositToken(mockToken.target, ethers.parseEther("10"));

        // Ensure both assets are funded
        const ethAsset = await multiAssetEscrow.assets(0);
        const tokenAsset = await multiAssetEscrow.assets(1);
        expect(ethAsset.depositedAmount).to.equal(etherAmount);
        expect(tokenAsset.depositedAmount).to.equal(ethers.parseEther("10"));

        // Confirm and resolve
        await multiAssetEscrow.connect(participant1).confirm();
        expect(await multiAssetEscrow.state()).to.equal(3); // State.RESOLVED
      });
    });

    describe("Extreme Cases", function () {
      it("should simulate the full lifecycle of the escrow contract", async function () {
        const participants = [
          { addr: participant1.address, share: 5000 },
          { addr: participant2.address, share: 5000 },
        ];
        const recipients = [
          { addr: recipient1.address, share: 7000 },
          { addr: recipient2.address, share: 3000 },
        ];
        const assets = [
          { token: ethers.ZeroAddress, requiredAmount: ethers.parseEther("1") },
        ];
      
        const tx = await escrowFactory.createEscrow(
          mediator.address,
          participants,
          recipients,
          assets,
          5000,
          86400,
          86400,
          86400
        );
      
        const receipt = await tx.wait();
        const event = receipt.logs
          .map((log) => escrowFactory.interface.parseLog(log))
          .find((parsedLog) => parsedLog.name === "EscrowCreated");
      
        if (!event) throw new Error("EscrowCreated event not found");
        const escrowContract = await Escrow.attach(event.args.escrowAddress);
      
        // **1. Depósitos de los participantes**
        const depositAmount = ethers.parseEther("0.5");
        await escrowContract.connect(participant1).depositETH({ value: depositAmount });
        await escrowContract.connect(participant2).depositETH({ value: depositAmount });
      
        // **Validar estado después de los depósitos**
        const currentState = await escrowContract.state();
        expect(currentState).to.equal(1); // State.AWAITING_CONFIRMATION
      
        // **2. Confirmaciones**
        await escrowContract.connect(participant1).confirm();
      
        // **Validar estado después de las confirmaciones**
        expect(await escrowContract.state()).to.equal(3); // State.RESOLVED
      });
    });

  });
});
