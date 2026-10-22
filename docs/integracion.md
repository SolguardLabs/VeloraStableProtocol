# Integración

Una integración debe fijar red, direcciones, código esperado, activo y decimales. Antes de abrir un vault se consulta `CollateralRegistry.getConfig` y el precio vigente; se aprueba el colateral al `VaultManager` y se verifica el saldo. `openVault` devuelve el identificador. Para emitir, `mintStablecoin` calcula una comisión, por lo que la deuda final debe leerse tras confirmar la transacción.

Para repagar, el pagador aprueba VUSD al manager y llama `repayDebt`. Para retirar, el controlador consulta `riskSnapshot` y considera posibles cambios de precio antes de que la transacción entre en un bloque. `adjustVault` agrupa depósito, retiro y cambio de deuda en una única llamada; los campos de importe cero indican una acción omitida, no un valor por defecto seguro para toda la estructura.

El lens ofrece una consulta por lotes:

```solidity
uint256[] memory ids = new uint256[](2);
ids[0] = 1;
ids[1] = 2;
VeloraPortfolioLens.VaultView[] memory positions = lens.batchVaults(ids);
```

Los lotes grandes pueden exceder límites de gas o del proveedor RPC: paginar desde el cliente. La lectura no bloquea el estado; antes de firmar una operación sensible, simularla sobre un bloque reciente y aplicar límites de salida donde exista ese parámetro.
