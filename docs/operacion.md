# Operación y controles

## Entrega de código

`scripts/ci.sh` instala `forge-std` si falta y ejecuta formato, compilación y pruebas. En Windows puede usarse `scripts/ci.ps1` con Foundry nativo. La CI de GitHub valida PR, `main`, `production` y el tag; `release-integrity` comprueba que `main`, `production` y `v1.0.0^{}` apunten al mismo commit. Un release de GitHub no despliega contratos en una red externa.

## Monitorización

Observar la antigüedad y rango de feeds, el ratio por vault, `totalDebt`, `totalShares`, repagos pendientes, bad debt, oferta VUSD, cobertura del Stability Pool y saldos de tesorería. Reconciliar eventos de emisión y quema con variaciones agregadas. Una posición liquidable requiere cotización actual: no se debe ejecutar a partir de una captura anterior al último precio.

Los controles administrativos deben separar operadores de precio, guardianes y administradores de parámetros. Revisar cualquier cambio de ratios, techos y fees como una modificación económica, aunque no altere bytecode. En una pausa, registrar causa, bloque y acciones afectadas; repago, liquidación y redención tienen consecuencias diferentes si quedan detenidos.

## Validación local

```bash
bash scripts/ci.sh
forge test --match-path tests/PortfolioLens.t.sol -vv
```

La suite local demuestra comportamiento bajo fixtures reproducibles. Una entrega en una red persistente necesita, por separado, configuración de claves, direcciones, permisos, oráculos y vigilancia.
