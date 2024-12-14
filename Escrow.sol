// SPDX-License-Identifier: PropietarioUnico
pragma solidity ^0.8.28;

// Interfaz simplificada de ERC20 para transferencias y transferFrom
interface IERC20 {
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    function transfer(
        address recipient,
        uint256 amount
    ) external returns (bool);
}

contract Escrow {
    // Estructuras de entrada para el constructor
    struct ParticipantInput {
        address addr;
        uint256 share; // Ej: 5000 = 50%, 10000 = 100%
    }

    struct RecipientInput {
        address addr;
        uint256 share; // Deben sumar 10000 entre todos los receptores
    }

    struct AssetInput {
        address token; // 0x0 si es Ether nativo
        uint256 requiredAmount; // Cantidad requerida para considerar el asset fondeado
    }

    // Representa un activo en el escrow (Ether o un token específico)
    struct Asset {
        address token;
        uint256 requiredAmount;
        uint256 depositedAmount; // Cantidad actualmente depositada
    }

    // Posibles estados del escrow
    enum State {
        INIT, // Inicial, esperando fondos
        AWAITING_CONFIRMATION, // Fondos completos, esperando confirmaciones
        DISPUTE, // En disputa, el mediador debe resolver
        RESOLVED, // Resuelto a favor de los receptores
        REFUNDED // Reembolsado a los participantes
    }

    // Dirección del mediador que resolverá disputas
    address public mediator;

    // Listado de participantes y mapping de sus shares
    address[] public participantsList;
    mapping(address => uint256) public participantShares;
    uint256 public totalParticipantShare;

    // Listado de receptores y sus shares, deben sumar 10000
    address[] public recipientsList;
    mapping(address => uint256) public recipientShares;

    // Lista de assets requeridos y un mapping para buscar su índice por token
    Asset[] public assets;
    mapping(address => uint256) public assetIndexByToken;

    // Estado actual del escrow
    State public state;

    // Umbral de confirmaciones requerido (en base 10000)
    uint256 public confirmationsThreshold;

    // Períodos de tiempo en segundos
    uint256 public fundingPeriod;
    uint256 public confirmationPeriod;
    uint256 public disputePeriod;

    // Timestamps clave
    uint256 public creationTime;
    uint256 public fundedTime;
    uint256 public disputeStartTime;

    // Confirmaciones de participantes
    mapping(address => bool) public hasConfirmed;
    uint256 public confirmationsWeight; // Suma de shares confirmados

    // Depósitos (participante -> token -> amount)
    mapping(address => mapping(address => uint256)) public deposits;

    // Saldo pendiente de retirar (pull payments)
    mapping(address => mapping(address => uint256)) public balancesToWithdraw;

    bool public disputeRaised; // Indica si se inició una disputa

    // Eventos para monitorear el flujo del contrato
    event StateChanged(State oldState, State newState);
    event Deposited(address indexed participant, address token, uint256 amount);
    event Confirmed(address indexed participant);
    event DisputeRaised(address indexed who);
    event ResolvedByMediator(address indexed mediator);
    event FundsAllocated(address indexed user, uint256 amount, address token);
    event Refunded(address indexed participant, uint256 amount, address token);
    event Withdrawn(address indexed user, uint256 amount, address token);
    event DebugState(State state); // Evento para depuración
    event DebugIndex(uint256 index);

    modifier onlyMediator() {
        require(msg.sender == mediator, "Not mediator");
        _;
    }

    modifier onlyParticipant() {
        require(participantShares[msg.sender] > 0, "Not a participant");
        _;
    }

    modifier inState(State _s) {
        emit DebugState(state); // Evento para confirmar el estado actual
        require(state == _s, "Invalid state");
        _;
    }

    // Constructor: configura el escrow con participantes, receptores, assets y tiempos
    constructor(
        address _mediator,
        ParticipantInput[] memory _participants,
        RecipientInput[] memory _recipients,
        AssetInput[] memory _assets,
        uint256 _confirmationsThreshold,
        uint256 _fundingPeriod,
        uint256 _confirmationPeriod,
        uint256 _disputePeriod
    ) {
        mediator = _mediator;
        confirmationsThreshold = _confirmationsThreshold;
        fundingPeriod = _fundingPeriod;
        confirmationPeriod = _confirmationPeriod;
        disputePeriod = _disputePeriod;
        creationTime = block.timestamp;

        // Registrar participantes y sumar sus shares
        uint256 sumShares = 0;
        for (uint256 i = 0; i < _participants.length; i++) {
            participantsList.push(_participants[i].addr);
            participantShares[_participants[i].addr] = _participants[i].share;
            sumShares += _participants[i].share;
        }
        totalParticipantShare = sumShares;

        // Registrar receptores y verificar que sumen 10000
        uint256 sumRecipients = 0;
        for (uint256 i = 0; i < _recipients.length; i++) {
            recipientsList.push(_recipients[i].addr);
            recipientShares[_recipients[i].addr] = _recipients[i].share;
            sumRecipients += _recipients[i].share;
        }
        require(sumRecipients == 10000, "Recipients shares must sum to 10000");

        // Registrar assets requeridos
        for (uint256 i = 0; i < _assets.length; i++) {
            assets.push(
                Asset({
                    token: _assets[i].token,
                    requiredAmount: _assets[i].requiredAmount,
                    depositedAmount: 0
                })
            );
            assetIndexByToken[_assets[i].token] = i + 1;
        }

        state = State.INIT;
    }

    // Funciones para obtener conteos, facilitan las llamadas desde fuera
    function participantsCount() external view returns (uint256) {
        return participantsList.length;
    }

    function recipientsCount() external view returns (uint256) {
        return recipientsList.length;
    }

    function assetsCount() external view returns (uint256) {
        return assets.length;
    }

    // -------------------
    // Depósito de Fondos
    // -------------------

    // Depósito de Ether nativo
    function depositETH() external payable inState(State.INIT) {
        require(msg.value > 0, "No ETH sent");
        _checkFundingDeadline();

        uint256 idx = assetIndexByToken[address(0)];
        emit DebugIndex(idx); // Agregar este evento para verificar el índice
        require(idx != 0, "No ETH asset required");
        uint256 assetIdx = idx - 1;

        // Registrar depósito
        assets[assetIdx].depositedAmount += msg.value;
        deposits[msg.sender][address(0)] += msg.value;

        emit Deposited(msg.sender, address(0), msg.value);

        _checkAllDepositsCompleted();
    }

    // Depósito de tokens ERC20
    function depositToken(
        address token,
        uint256 amount
    ) external inState(State.INIT) {
        require(token != address(0), "Invalid token");
        require(amount > 0, "No token amount");
        _checkFundingDeadline();

        uint256 idx = assetIndexByToken[token];
        require(idx != 0, "Token asset not required");
        uint256 assetIdx = idx - 1;

        // Transferencia del token al contrato
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        assets[assetIdx].depositedAmount += amount;
        deposits[msg.sender][token] += amount;

        emit Deposited(msg.sender, token, amount);

        _checkAllDepositsCompleted();
    }

    // Verifica si todos los assets requeridos están completos
    function _checkAllDepositsCompleted() internal {
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].depositedAmount < assets[i].requiredAmount) {
                return; // Si algún asset no está fondeado, salir
            }
        }

        // Si todos los assets están fondeados, cambiar el estado
        if (state == State.INIT) {
            State oldState = state;
            state = State.AWAITING_CONFIRMATION;
            fundedTime = block.timestamp;
            emit StateChanged(oldState, state);
        }
    }

    function _checkFundingDeadline() internal view {
        require(
            block.timestamp <= creationTime + fundingPeriod,
            "Funding period expired"
        );
    }

    // -------------------
    // Confirmaciones
    // -------------------
    function confirm()
        external
        inState(State.AWAITING_CONFIRMATION)
        onlyParticipant
    {
        // Verificar si el participante ya confirmó
        require(!hasConfirmed[msg.sender], "Already confirmed");

        // Registrar la confirmación del participante
        hasConfirmed[msg.sender] = true;
        confirmationsWeight += participantShares[msg.sender];

        emit Confirmed(msg.sender);

        // Verificar si se alcanzó el umbral de confirmación
        uint256 confirmationsPercent = (confirmationsWeight * 10000) /
            totalParticipantShare;
        if (confirmationsPercent >= confirmationsThreshold) {
            _allocateFundsToRecipients();
        }
    }

    // Asigna fondos a receptores en estado RESOLVED
    function _allocateFundsToRecipients() internal {
        require(state == State.AWAITING_CONFIRMATION, "Wrong state");
        State oldState = state;
        state = State.RESOLVED;
        emit StateChanged(oldState, state);

        // Distribuir fondos según las shares de los receptores
        for (uint256 i = 0; i < assets.length; i++) {
            Asset memory asset = assets[i];
            uint256 totalAmount = asset.depositedAmount;
            for (uint256 r = 0; r < recipientsList.length; r++) {
                address rcpt = recipientsList[r];
                uint256 share = recipientShares[rcpt];
                uint256 amountToAllocate = (totalAmount * share) / 10000;

                balancesToWithdraw[rcpt][asset.token] += amountToAllocate;
                emit FundsAllocated(rcpt, amountToAllocate, asset.token);
            }
        }
    }

    // -------------------
    // Disputas
    // -------------------
    function raiseDispute() external inState(State.AWAITING_CONFIRMATION) {
        require(
            block.timestamp > fundedTime + confirmationPeriod,
            "Confirmation period not ended"
        );

        disputeRaised = true;
        State oldState = state;
        state = State.DISPUTE;
        disputeStartTime = block.timestamp;
        emit StateChanged(oldState, state);
        emit DisputeRaised(msg.sender);
    }

    // El mediador puede resolver a favor de los receptores
    function resolveDisputeToRecipients()
        external
        onlyMediator
        inState(State.DISPUTE)
    {
        _checkDisputeDeadline();
        _allocateFundsToRecipients();
        emit ResolvedByMediator(msg.sender);
    }

    // El mediador puede resolver reembolsando a los participantes
    function resolveDisputeRefundAll()
        external
        onlyMediator
        inState(State.DISPUTE)
    {
        _checkDisputeDeadline();
        _allocateRefundToParticipants();
        emit ResolvedByMediator(msg.sender);
    }

    function _checkDisputeDeadline() internal view {
        require(
            block.timestamp <= disputeStartTime + disputePeriod,
            "Dispute period expired"
        );
    }

    // -------------------
    // Refund (Reembolso)
    // -------------------
    function forceRefund() external {
        if (state == State.INIT) {
            require(
                block.timestamp > creationTime + fundingPeriod,
                "Funding period not ended"
            );
        } else if (state == State.AWAITING_CONFIRMATION) {
            require(
                block.timestamp > fundedTime + confirmationPeriod,
                "Confirmation period not ended"
            );
        } else if (state == State.DISPUTE) {
            require(
                block.timestamp > disputeStartTime + disputePeriod,
                "Dispute period not ended"
            );
        } else {
            revert("No refund allowed in current state");
        }

        _allocateRefundToParticipants();
    }

    // Reembolsar a participantes sus aportes iniciales
    function _allocateRefundToParticipants() internal {
        require(
            state != State.RESOLVED && state != State.REFUNDED,
            "Already resolved or refunded"
        );
        State oldState = state;
        state = State.REFUNDED;
        emit StateChanged(oldState, state);

        // Devolver a cada participante lo que aportó
        for (uint256 p = 0; p < participantsList.length; p++) {
            address participantAddr = participantsList[p];
            for (uint256 a = 0; a < assets.length; a++) {
                address token = assets[a].token;
                uint256 amount = deposits[participantAddr][token];
                if (amount > 0) {
                    deposits[participantAddr][token] = 0;
                    balancesToWithdraw[participantAddr][token] += amount;
                    emit FundsAllocated(participantAddr, amount, token);
                }
            }
        }
    }

    // -------------------
    // Withdraw (Pull Payment)
    // -------------------
    // Cada usuario retira sus fondos asignados tras RESOLVED o REFUNDED
    function withdraw(address token) external {
        // Verificar que el estado sea válido para permitir retiros
        require(
            state == State.RESOLVED || state == State.REFUNDED,
            "Invalid state"
        );

        uint256 amount = balancesToWithdraw[msg.sender][token];
        require(amount > 0, "Nothing to withdraw");

        balancesToWithdraw[msg.sender][token] = 0;

        // Enviar Ether o tokens
        if (token == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "ETH withdraw failed");
            emit Withdrawn(msg.sender, amount, address(0));
        } else {
            IERC20(token).transfer(msg.sender, amount);
            emit Withdrawn(msg.sender, amount, token);
        }
    }

    // Cambiar la dirección del mediador
    function changeMediator(address newMediator) external onlyMediator {
        require(
            newMediator != address(0),
            "New mediator cannot be zero address"
        );
        mediator = newMediator;
    }

    // Para recibir Ether
    receive() external payable {}
}

contract EscrowFactory {
    event EscrowCreated(
        address indexed escrowAddress,
        address indexed creator,
        address mediator
    );

    address[] public allEscrows;

    // Estructura para devolver todos los detalles del Escrow sin problemas de stack
    struct EscrowDetails {
        Escrow.State state_;
        address mediator_;
        address[] participants;
        uint256[] participantShares_;
        address[] recipients;
        uint256[] recipientShares_;
        address[] assetTokens;
        uint256[] assetRequiredAmounts;
        uint256[] assetDepositedAmounts;
        uint256 confirmationsThreshold_;
        uint256 fundingPeriod_;
        uint256 confirmationPeriod_;
        uint256 disputePeriod_;
        uint256 creationTime_;
        uint256 fundedTime_;
        uint256 disputeStartTime_;
        bool disputeRaised_;
    }

    // Crear un nuevo escrow a través del factory
    function createEscrow(
        address mediator,
        Escrow.ParticipantInput[] calldata participants,
        Escrow.RecipientInput[] calldata recipients,
        Escrow.AssetInput[] calldata requiredAssets,
        uint256 confirmationsThreshold,
        uint256 fundingPeriod,
        uint256 confirmationPeriod,
        uint256 disputePeriod
    ) external returns (address) {
        Escrow newEscrow = new Escrow(
            mediator,
            participants,
            recipients,
            requiredAssets,
            confirmationsThreshold,
            fundingPeriod,
            confirmationPeriod,
            disputePeriod
        );

        allEscrows.push(address(newEscrow));
        emit EscrowCreated(address(newEscrow), msg.sender, mediator);

        return address(newEscrow);
    }

    // Devuelve todos los escrows creados
    function getAllEscrows() external view returns (address[] memory) {
        return allEscrows;
    }

    // Obtiene la lista de escrows en estado DISPUTE
    function getEscrowsInDispute() external view returns (address[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < allEscrows.length; i++) {
            Escrow e = Escrow(payable(allEscrows[i]));
            if (e.state() == Escrow.State.DISPUTE) {
                count++;
            }
        }

        address[] memory disputes = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allEscrows.length; i++) {
            Escrow e = Escrow(payable(allEscrows[i]));
            if (e.state() == Escrow.State.DISPUTE) {
                disputes[index] = allEscrows[i];
                index++;
            }
        }

        return disputes;
    }

    // Retorna detalles completos de un escrow específico
    function getEscrowDetails(
        address escrowAddress
    ) external view returns (EscrowDetails memory details) {
        Escrow e = Escrow(payable(escrowAddress));

        details.state_ = e.state();
        details.mediator_ = e.mediator();
        details.confirmationsThreshold_ = e.confirmationsThreshold();
        details.fundingPeriod_ = e.fundingPeriod();
        details.confirmationPeriod_ = e.confirmationPeriod();
        details.disputePeriod_ = e.disputePeriod();
        details.creationTime_ = e.creationTime();
        details.fundedTime_ = e.fundedTime();
        details.disputeStartTime_ = e.disputeStartTime();
        details.disputeRaised_ = e.disputeRaised();

        uint256 pCount = e.participantsCount();
        uint256 rCount = e.recipientsCount();
        uint256 aCount = e.assetsCount();

        details.participants = new address[](pCount);
        details.participantShares_ = new uint256[](pCount);

        for (uint256 i = 0; i < pCount; i++) {
            address p = e.participantsList(i);
            details.participants[i] = p;
            details.participantShares_[i] = e.participantShares(p);
        }

        details.recipients = new address[](rCount);
        details.recipientShares_ = new uint256[](rCount);
        for (uint256 i = 0; i < rCount; i++) {
            address r_ = e.recipientsList(i);
            details.recipients[i] = r_;
            details.recipientShares_[i] = e.recipientShares(r_);
        }

        details.assetTokens = new address[](aCount);
        details.assetRequiredAmounts = new uint256[](aCount);
        details.assetDepositedAmounts = new uint256[](aCount);

        for (uint256 i = 0; i < aCount; i++) {
            (address token, uint256 requiredAmount, uint256 depositedAmount) = e
                .assets(i);
            details.assetTokens[i] = token;
            details.assetRequiredAmounts[i] = requiredAmount;
            details.assetDepositedAmounts[i] = depositedAmount;
        }
    }
}
