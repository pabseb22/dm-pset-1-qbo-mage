# RUNBOOK — Operación y Soporte
DM PSet 1 — QBO Backfill with Mage + Postgres (RAW)

Este documento describe cómo operar, reintentar y solucionar problemas del backfill histórico desde QuickBooks Online hacia PostgreSQL utilizando Mage.

---

## 1. Contexto Operativo

Se configuraron tres pipelines independientes:

- qb_customers_backfill
- qb_items_backfill
- qb_invoices_backfill

Todos los pipelines fueron programados mediante triggers one-time para ejecutarse el:

- Fecha de ejecución: 02 de febrero de 2026
- Hora: 10:00 (America/Guayaquil)
- Equivalente UTC: 15:00 UTC

Cada pipeline procesa el mismo rango histórico:

- fecha_inicio = 2026-01-01
- fecha_fin = 2026-01-31

Los triggers se deshabilitan manualmente una vez completada la ejecución para evitar relanzamientos accidentales.

---

## 2. Reintentar un Tramo Específico

Si una ejecución falla o si se requiere reprocesar un rango específico, se debe:

1. Ejecutar nuevamente el pipeline correspondiente desde Mage.
2. Usar los mismos parámetros fecha_inicio y fecha_fin (o un subrango específico).
3. Confirmar que el pipeline finaliza correctamente.

El diseño del pipeline es idempotente, por lo que:
- No se generan duplicados.
- Los registros existentes se actualizan mediante upsert.
- Es seguro reprocesar el mismo tramo múltiples veces.

---

## 3. Reanudar una Ejecución Parcial

Debido a la segmentación diaria, es posible identificar ventanas que fallaron revisando los logs.

Para reanudar:
1. Identificar el día o rango que falló.
2. Ejecutar el pipeline solo para ese subrango (por ejemplo, un solo día).
3. Verificar métricas y resultados en PostgreSQL.

No es necesario reprocesar todo el mes si solo falló un tramo específico.

---

## 4. Validación de Resultados en PostgreSQL

Para verificar que los datos se cargaron correctamente:

Conteo total de registros por entidad:
SELECT COUNT(*) FROM raw.qb_customers;
SELECT COUNT(*) FROM raw.qb_items;
SELECT COUNT(*) FROM raw.qb_invoices;

Conteo por ventana diaria:
SELECT extract_window_start_utc::date AS day, COUNT(*)
FROM raw.qb_customers
GROUP BY 1
ORDER BY 1;

Estas consultas permiten validar volumetría y detectar días sin datos inesperados.

---

## 5. Verificación de Idempotencia

Para comprobar que el pipeline es idempotente:

1. Ejecutar nuevamente el mismo pipeline con los mismos parámetros.
2. Verificar en los logs que:
   - inserted = 0
   - updated > 0 (o 0 si no hubo cambios)
3. Confirmar que el conteo total de registros no aumenta.

---

## 6. Error: invalid_grant (Refresh Token)

### Descripción del Error

El error `invalid_grant` indica que el refresh token de QuickBooks Online no es válido. Esto puede ocurrir por:

- Expiración del refresh token.
- Rotación del token no reflejada en Mage Secrets.
- Uso de un token correspondiente a otro entorno (sandbox vs production).
- Reautorización previa de la app que invalida el token anterior.

Cuando este error ocurre, el pipeline no puede obtener un access token y la ejecución falla.

---

### Proceso de Regeneración del Refresh Token

Para solucionar el error `invalid_grant`, se debe seguir el siguiente proceso:

1. Ingresar al portal de Intuit Developer.
2. Acceder a la aplicación de QuickBooks Online utilizada por el proyecto.
3. Ejecutar nuevamente el flujo de autorización (Connect to QuickBooks).
4. Autorizar la aplicación en la cuenta de QuickBooks correspondiente.
5. Copiar el nuevo refresh token generado.
6. Ingresar a Mage.
7. Actualizar el valor del secret:
   - QBO_REFRESH_TOKEN
8. Guardar el secret.
9. Reejecutar el pipeline que falló.

No es necesario modificar ningún otro secret ni el código del pipeline.

---

## 7. Errores de Rate Limit (HTTP 429)

El pipeline maneja automáticamente los errores de rate limit mediante:

- reintentos con backoff exponencial,
- pausas entre intentos,
- abortado controlado si se excede el número máximo de reintentos.

Si los errores persisten:
- reducir el tamaño de página (page_size),
- reducir el rango de fechas por ejecución.

---

## 8. Errores de Autenticación (HTTP 401)

Un error 401 indica que el access token expiró durante la ejecución.  
El pipeline intenta automáticamente refrescar el token y continuar.

Si el error persiste, revisar el estado del refresh token siguiendo el procedimiento descrito en la sección 6.

---

## 9. Consideraciones de Zona Horaria

Todos los filtros y timestamps se manejan exclusivamente en UTC.

Las fechas proporcionadas al pipeline deben estar en UTC, incluso si la ejecución se programa en horario local (America/Guayaquil).

---

## 10. Operación Normal Esperada

Una ejecución exitosa del pipeline debe mostrar en los logs:

- inicio y fin de cada ventana diaria,
- métricas por tramo (páginas y filas),
- resumen final con total de filas procesadas,
- ejecución del exporter con conteo de insertados y actualizados.

Cualquier desviación significativa debe investigarse siguiendo este runbook.

