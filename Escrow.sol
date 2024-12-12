// SPDX-License-Identifier: PropietarioUnico
pragma solidity ^0.8.28;

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns(bool);
    function transfer(address recipient, uint256 amount) external returns(bool);
}

contract Escrow {
    // Datos de entrada para constructor (para evitar stack too deep)
    struct ParticipantInput {
        address addr;
        uint256 share;
    }

    struct RecipientInput {
        address addr;
        uint256 share;
    }

    struct AssetInput {
        address token; // 0x0 si es Ether
        uint256 requiredAmount;
    }

    struct Asset {
        address token; 
        uint256 requiredAmount;
        uint256 depositedAmount;
    }

    enum State { INIT, AWAITING_CONFIRMATION, DISPUTE, RESOLVED, REFUNDED }

    address public mediator;

    address[] public participantsList; 
    mapping(address => uint256) public participantShares; 
    uint256 public totalParticipantShare;

    address[] public recipientsList;
    mapping(address => uint256) public recipientShares; // deben sumar 10000

    Asset[] public assets;
    mapping(address => uint256) public assetIndexByToken; 

    State public state;
    uint256 public confirmationsThreshold; 
    uint256 public fundingPeriod;       
    uint256 public confirmationPeriod;  
    uint256 public disputePeriod;       

    uint256 public creationTime;
    uint256 public fundedTime;
    uint256 public disputeStartTime;

    mapping(address => bool) public hasConfirmed;
    uint256 public confirmationsWeight;

    // Depósitos por participante y token
    mapping(address => mapping(address => uint256)) public deposits; 

    // Balances pendientes de retirar (pull payments)
    mapping(address => mapping(address => uint256)) public balancesToWithdraw;

    bool public disputeRaised;

    event StateChanged(State oldState, State newState);
    event Deposited(address indexed participant, address token, uint256 amount);
    event Confirmed(address indexed participant);
    event DisputeRaised(address indexed who);
    event ResolvedByMediator(address indexed mediator);
    event FundsAllocated(address indexed user, uint256 amount, address token);
    event Refunded(address indexed participant, uint256 amount, address token);
    event Withdrawn(address indexed user, uint256 amount, address token);

    modifier onlyMediator() {
        require(msg.sender == mediator, "Not mediator");
        _;
    }

    modifier inState(State _s) {
        require(state == _s, "Invalid state");
        _;
    }

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

        uint256 sumShares = 0;
        for (uint i = 0; i < _participants.length; i++) {
            participantsList.push(_participants[i].addr);
            participantShares[_participants[i].addr] = _participants[i].share;
            sumShares += _participants[i].share;
        }
        totalParticipantShare = sumShares;

        uint256 sumRecipients = 0;
        for (uint i = 0; i < _recipients.length; i++) {
            recipientsList.push(_recipients[i].addr);
            recipientShares[_recipients[i].addr] = _recipients[i].share;
            sumRecipients += _recipients[i].share;
        }
        require(sumRecipients == 10000, "Recipients shares must sum to 10000");

        for (uint i = 0; i < _assets.length; i++) {
            assets.push(Asset({
                token: _assets[i].token,
                requiredAmount: _assets[i].requiredAmount,
                depositedAmount: 0
            }));
            assetIndexByToken[_assets[i].token] = i+1;
        }

        state = State.INIT;
    }

    // -------------------
    // Depósito de Fondos
    // -------------------
    function depositETH() external payable inState(State.INIT) {
        require(msg.value > 0, "No ETH sent");
        _checkFundingDeadline();

        uint256 idx = assetIndexByToken[address(0)];
        require(idx != 0, "No ETH asset required");
        uint256 assetIdx = idx - 1;

        assets[assetIdx].depositedAmount += msg.value;
        deposits[msg.sender][address(0)] += msg.value;

        emit Deposited(msg.sender, address(0), msg.value);

        _checkAllDepositsCompleted();
    }

    function depositToken(address token, uint256 amount) external inState(State.INIT) {
        require(token != address(0), "Invalid token");
        require(amount > 0, "No token amount");
        _checkFundingDeadline();

        uint256 idx = assetIndexByToken[token];
        require(idx != 0, "Token asset not required");
        uint256 assetIdx = idx - 1;

        IERC20(token).transferFrom(msg.sender, address(this), amount);

        assets[assetIdx].depositedAmount += amount;
        deposits[msg.sender][token] += amount;

        emit Deposited(msg.sender, token, amount);

        _checkAllDepositsCompleted();
    }

    function _checkAllDepositsCompleted() internal {
        for (uint i = 0; i < assets.length; i++) {
            if (assets[i].depositedAmount < assets[i].requiredAmount) {
                return;
            }
        }

        State oldState = state;
        state = State.AWAITING_CONFIRMATION;
        fundedTime = block.timestamp;
        emit StateChanged(oldState, state);
    }

    function _checkFundingDeadline() internal view {
        require(block.timestamp <= creationTime + fundingPeriod, "Funding period expired");
    }

    // -------------------
    // Confirmaciones
    // -------------------
    function confirm() external inState(State.AWAITING_CONFIRMATION) {
        uint256 pShare = participantShares[msg.sender];
        require(pShare > 0, "Not participant");
        require(!hasConfirmed[msg.sender], "Already confirmed");

        hasConfirmed[msg.sender] = true;
        confirmationsWeight += pShare;
        emit Confirmed(msg.sender);

        uint256 confirmationsPercent = (confirmationsWeight * 10000) / totalParticipantShare;
        if (confirmationsPercent >= confirmationsThreshold) {
            _allocateFundsToRecipients();
        }
    }

    function _allocateFundsToRecipients() internal {
        require(state == State.AWAITING_CONFIRMATION, "Wrong state");
        State oldState = state;
        state = State.RESOLVED;
        emit StateChanged(oldState, state);

        // Asignamos fondos a balancesToWithdraw, no transferimos en masa
        for (uint i = 0; i < assets.length; i++) {
            Asset memory asset = assets[i];
            uint256 totalAmount = asset.depositedAmount;
            for (uint r = 0; r < recipientsList.length; r++) {
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
        require(block.timestamp > fundedTime + confirmationPeriod, "Confirmation period not ended");
        
        disputeRaised = true;
        State oldState = state;
        state = State.DISPUTE;
        disputeStartTime = block.timestamp;
        emit StateChanged(oldState, state);
        emit DisputeRaised(msg.sender);
    }

    // Resolver disputa por el mediador
    function resolveDisputeToRecipients() external onlyMediator inState(State.DISPUTE) {
        _checkDisputeDeadline();
        _allocateFundsToRecipients();
        emit ResolvedByMediator(msg.sender);
    }

    function resolveDisputeRefundAll() external onlyMediator inState(State.DISPUTE) {
        _checkDisputeDeadline();
        _allocateRefundToParticipants();
        emit ResolvedByMediator(msg.sender);
    }

    function _checkDisputeDeadline() internal view {
        require(block.timestamp <= disputeStartTime + disputePeriod, "Dispute period expired");
    }

    // -------------------
    // Refund (Reembolso)
    // -------------------
    function forceRefund() external {
        if (state == State.INIT) {
            require(block.timestamp > creationTime + fundingPeriod, "Funding period not ended");
        } else if (state == State.AWAITING_CONFIRMATION) {
            require(block.timestamp > fundedTime + confirmationPeriod, "Confirmation period not ended");
        } else if (state == State.DISPUTE) {
            require(block.timestamp > disputeStartTime + disputePeriod, "Dispute period not ended");
        } else {
            revert("No refund allowed in current state");
        }

        _allocateRefundToParticipants();
    }

    function _allocateRefundToParticipants() internal {
        require(state != State.RESOLVED && state != State.REFUNDED, "Already resolved or refunded");
        State oldState = state;
        state = State.REFUNDED;
        emit StateChanged(oldState, state);

        // Asignamos a cada participante lo que depositó
        for (uint p = 0; p < participantsList.length; p++) {
            address participantAddr = participantsList[p];
            for (uint a = 0; a < assets.length; a++) {
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
    function withdraw(address token) external {
        uint256 amount = balancesToWithdraw[msg.sender][token];
        require(amount > 0, "Nothing to withdraw");

        balancesToWithdraw[msg.sender][token] = 0;

        if (token == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "ETH withdraw failed");
            emit Withdrawn(msg.sender, amount, address(0));
        } else {
            IERC20(token).transfer(msg.sender, amount);
            emit Withdrawn(msg.sender, amount, token);
        }
    }

    receive() external payable {}
}


contract EscrowFactory {
    event EscrowCreated(address indexed escrowAddress, address indexed creator, address mediator);

    address[] public allEscrows;

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

    function getAllEscrows() external view returns (address[] memory) {
        return allEscrows;
    }
}