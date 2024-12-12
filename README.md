
# SimpleEscrow, sistema de escrow en Solidity

Este sistema implementa un mecanismo de custodia ("escrow") sobre fondos en Ether y/o tokens ERC20. Permite depositar fondos, requerir confirmaciones de las partes involucradas, resolver disputas a través de un mediador, y finalmente retirar los fondos asignados usando un modelo "pull payment".

## Características Principales

-  **Soporte para Ether y ERC20:**

Se pueden definir uno o varios activos requeridos, incluyendo Ether (dirección 0x0) y tokens ERC20.

-  **Múltiples Participantes y Receptores:**

- Los participantes aportan fondos. Cada participante tiene un porcentaje (`share`) sobre el total de los participantes.

- Los receptores reciben los fondos según sus porcentajes (`share`), debiendo sumar 10000 entre todos (100%).

-  **Confirmaciones y Quórum:**

Una vez depositados todos los fondos requeridos, se pasa a `AWAITING_CONFIRMATION`.

Los participantes llaman a `confirm()` para indicar su acuerdo. Si se alcanza un umbral (`confirmationsThreshold`) sobre el total de shares de los participantes, el escrow se resuelve.

-  **Mediación de Disputas:**

Si no se alcanza un acuerdo a tiempo, se puede `raiseDispute()`.

El mediador (definido en el inicio) puede resolver la disputa a favor de los receptores (`resolveDisputeToRecipients()`) o reembolsar a los participantes (`resolveDisputeRefundAll()`).

-  **Pull Payments (Retiro Individual):**

Una vez en `RESOLVED` o `REFUNDED`, los fondos se asignan internamente.

Cada receptor o participante llama a `withdraw(token)` para obtener su parte, evitando transacciones masivas que consuman demasiado gas. 

## Estados del Contrato

-  `INIT`: Inicial, esperando el fondeo completo.

-  `AWAITING_CONFIRMATION`: Todos los fondos depositados, esperando confirmaciones.

-  `DISPUTE`: Disputa iniciada, esperando decisión del mediador.

-  `RESOLVED`: Escrow resuelto a favor de los receptores.

-  `REFUNDED`: Escrow finalizado reembolsando a los participantes.

## Parámetros de Tiempo y Umbrales  

-  `fundingPeriod`: Tiempo máximo para completar los depósitos.

-  `confirmationPeriod`: Tiempo máximo para confirmar después del fondeo.

-  `disputePeriod`: Tiempo máximo para que el mediador resuelva la disputa.  

Si alguno de estos plazos se agota sin la acción requerida, se puede `forceRefund()`.

## Ejemplo de Uso con Direcciones

Supongamos las siguientes direcciones:

- Mediador:

`0x5B38Da6a701c568545dCfcB03FcB875f56beddC4`

- Participantes:

-  `0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2` con share = 5000

-  `0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db` con share = 5000

(Total participantes: 10000)

- Receptor:

-  `0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB` con share = 10000 (100%)

- Activos requeridos (solo Ether):

- Token: `0x0000000000000000000000000000000000000000` (ETH)

- requiredAmount: `1000000000000000000` (1 ETH)

-  `confirmationsThreshold = 5000` (50%)

-  `fundingPeriod = 600` segundos

-  `confirmationPeriod = 600` segundos

-  `disputePeriod = 600` segundos

## Ejemplo de Llamada a `createEscrow()` en Remix
  
Al usar `EscrowFactory.createEscrow(...)` debes llenar los parámetros así:

- mediator (address): 0x5B38Da6a701c568545dCfcB03FcB875f56beddC4

- participants (tuple[]):

Debe ser un array de arrays con `[direccion, share]`.

En Remix, introdúcelo así (con comillas para las direcciones, sin comillas para los números):
    [
     [“0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2”, 5000],
     [“0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db”, 5000]
    ]
- recipients (tuple[]):
Solo un receptor con 10000:
    [
     [“0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB”, 10000]
    ]
- requiredAssets (tuple[]):
Un solo asset (Ether) con 1 ETH requerido:
    [
     [“0x0000000000000000000000000000000000000000”, 1000000000000000000]
    ]
- confirmationsThreshold (uint256):
    5000
- fundingPeriod (uint256):
    600
- confirmationPeriod (uint256):
    600
- disputePeriod (uint256):
    600

Tras hacer clic en "transact", se desplegará un nuevo contrato `Escrow`. El evento `EscrowCreated` mostrará la dirección del nuevo contrato.

## Flujo Posterior

1. **Depósitos:**

Cada participante deposita su parte de fondos. Por ejemplo, uno deposita 1 ETH total usando `depositETH()` (con `value = 1 ETH`), cambiando el estado a `AWAITING_CONFIRMATION`.

2. **Confirmaciones:**

Los participantes llaman a `confirm()`. Si llega al 50% (5000 de 10000 en este ejemplo), el estado pasa a `RESOLVED`.

3. **Retiro (Withdraw):**

El receptor llama a `withdraw("0x0000000000000000000000000000000000000000")` para retirar el ETH asignado.

Así cada uno retira su parte cuando lo desee, evitando transacciones masivas.

## Disputas y Reembolsos

- Si no se confirma a tiempo, se llama a `raiseDispute()`. El mediador puede usar `resolveDisputeToRecipients()` para asignar a receptores, o `resolveDisputeRefundAll()` para reembolsar a participantes.

- Si el mediador no actúa a tiempo, `forceRefund()` puede usarse para reembolsar a los participantes.

  De esta forma, el sistema provee un escrow flexible, seguro y escalable.