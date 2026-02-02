# RUNBOOK — Operación y Soporte
DM PSet 1 — QBO Backfill with Mage + Postgres (RAW)

Este documento describe cómo levantar la infraestructura, ejecutar, validar,
reintentar y dar soporte al pipeline de backfill histórico desde QuickBooks Online
hacia PostgreSQL utilizando Mage.

Este runbook asume que el lector clona el repositorio desde cero y no tiene
contexto previo del proyecto.

---

## 0. Requisitos Previos

Antes de ejecutar este proyecto, se debe contar con lo siguiente instalado
en el equipo local:

- Docker (versión reciente)
- Docker Compose
- Acceso a internet (para consumo de la API de QuickBooks Online)

No se requiere instalar Python, PostgreSQL ni dependencias adicionales fuera
de Docker.

---

## 0.1. Ubicación del Proyecto y Ejecución

El comando de ejecución debe correrse desde la raíz del repositorio clonado,
es decir, desde el directorio donde se encuentra el archivo:

docker-compose.yml

Pasos:

1. Clonar el repositorio.
2. Abrir una terminal en la carpeta raíz del proyecto.
3. Ejecutar:

docker compose up -d

Este comando levanta automáticamente todos los servicios necesarios
(PostgreSQL, PgAdmin y Mage).

---

## 1. Accesos Iniciales

Una vez levantado el proyecto, se utilizan los siguientes accesos:

- PgAdmin (administración de base de datos):  
  http://localhost:5050

- Mage (orquestador de pipelines):  
  http://localhost:6789

Credenciales de PgAdmin:
- Usuario: admin@admin.com
- Password: admin

---

## 2. Primer Acceso a PgAdmin

Al ingresar por primera vez a PgAdmin, se solicitará definir un *Master Password*.

Este paso:
- es obligatorio solo la primera vez,
- no afecta la ejecución de los pipelines,
- protege únicamente las contraseñas almacenadas en PgAdmin.

El valor del Master Password puede ser cualquiera y no se versiona.

Una vez ingresado, PgAdmin mostrará automáticamente la conexión
a PostgreSQL ya configurada.

---

## 3. Verificación Inicial de la Base de Datos

Desde PgAdmin:

1. Expandir el servidor PostgreSQL.
2. Verificar que existe el esquema `raw`.
3. Verificar que existen las tablas:
   - raw.qb_customers
   - raw.qb_items
   - raw.qb_invoices

En una ejecución inicial, las tablas pueden existir pero estar vacías.
Esto es un estado esperado antes de ejecutar los pipelines.

Ejemplo de verificación:

SELECT COUNT(*) FROM raw.qb_customers;

---

## 4. Contexto Operativo del Backfill

Se configuraron tres pipelines independientes en Mage:

- qb_customers_backfill
- qb_items_backfill
- qb_invoices_backfill

Cada pipeline está parametrizado con:
- fecha_inicio = 2026-01-01
- fecha_fin = 2026-01-31

Los pipelines cuentan con triggers one-time configurados para ejecutarse el:

- Fecha: 02 de febrero de 2026
- Hora local: 10:00 (America/Guayaquil)
- Hora UTC: 15:00 UTC

Una vez ejecutados exitosamente, los triggers se deshabilitan manualmente
para evitar relanzamientos accidentales.

---

## 5. Ejecución Manual del Pipeline (Run once)

Además del trigger one-time, es posible ejecutar los pipelines manualmente.

Pasos:

1. Ingresar a Mage: http://localhost:6789
2. Abrir el pipeline deseado.
3. Ir a la sección de ejecución.
4. Seleccionar la opción **Run once**.
5. Confirmar los parámetros fecha_inicio y fecha_fin.
6. Ejecutar.

Esta acción dispara inmediatamente el proceso de backfill, incluso si
existen triggers configurados para fechas pasadas o futuras.

---

## 6. Monitoreo de la Ejecución

Durante la ejecución, se deben observar logs similares a:

Processing Customers window 2026-01-10 → 2026-01-11  
Window completed | pages=1 rows=0 duration_s=1.04  

Al finalizar todo el rango:

==== QB CUSTOMERS BACKFILL SUMMARY ====  
window_start_utc=2026-01-01T00:00:00Z  
window_end_utc=2026-01-31T00:00:00Z  
total_rows=22  
duration_seconds=37.11  

En el exporter:

Export completed | inserted=0 updated=22 total=22

Estos logs indican:
- segmentación diaria correcta,
- paginación funcionando,
- idempotencia aplicada (sin duplicados).

---

## 7. Validación de Resultados en PostgreSQL

Desde PgAdmin, ejecutar:

Conteo total por entidad:

SELECT COUNT(*) FROM raw.qb_customers;
SELECT COUNT(*) FROM raw.qb_items;
SELECT COUNT(*) FROM raw.qb_invoices;

Conteo por ventana diaria:

SELECT extract_window_start_utc::date AS day, COUNT(*)
FROM raw.qb_customers
GROUP BY 1
ORDER BY 1;

Estas consultas permiten validar volumetría e integridad temporal.

---

## 8. Verificación de Idempotencia

Para verificar idempotencia:

1. Ejecutar nuevamente el mismo pipeline con los mismos parámetros.
2. Revisar los logs del exporter.

Resultado esperado:
- inserted = 0
- updated >= 0
- el conteo total de filas no aumenta.

---

## 9. Reintentar un Tramo Específico

Gracias a la segmentación diaria, es posible reprocesar solo una parte del rango.

Pasos:
1. Identificar el día que falló en los logs.
2. Ejecutar el pipeline con:
   - fecha_inicio = día_fallido
   - fecha_fin = día_siguiente
3. Validar resultados en PostgreSQL.

---

## 10. Error: invalid_grant (Refresh Token)

El error:

Token refresh failed: invalid_grant

indica que el refresh token de QuickBooks Online no es válido
(expirado, rotado o correspondiente a otro entorno).

### Procedimiento de Recuperación

1. Ingresar al portal de Intuit Developer.
2. Abrir la aplicación de QuickBooks Online del proyecto.
3. Ejecutar nuevamente el flujo "Connect to QuickBooks".
4. Autorizar la aplicación.
5. Copiar el nuevo refresh token.
6. Ingresar a Mage.
7. Actualizar el secret QBO_REFRESH_TOKEN.
8. Guardar y reejecutar el pipeline.

---

## 11. Operación Normal Esperada

Una ejecución correcta debe mostrar:
- inicio y cierre de cada ventana diaria,
- métricas por tramo,
- resumen final,
- exporter con conteo de insertados y actualizados.

Cualquier desviación debe investigarse siguiendo este runbook.
