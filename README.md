# DM PSet 1 — QBO Backfill with Mage + Postgres (RAW)

## 1. Descripción del Proyecto

Este proyecto implementa un pipeline de backfill histórico desde QuickBooks Online (QBO) hacia PostgreSQL, utilizando Mage como orquestador. El objetivo es extraer datos históricos de entidades clave y almacenarlos en una capa RAW con payload completo y metadatos de ingesta, garantizando idempotencia, observabilidad y reprocesos seguros.

## 2. Arquitectura

La arquitectura se compone de:
- QuickBooks Online como fuente de datos (API REST, OAuth 2.0)
- Mage como motor de orquestación y ejecución de pipelines
- PostgreSQL como destino de la capa RAW
- Docker Compose para el despliegue local y la red entre servicios

## 3. Infraestructura y Despliegue

El proyecto se despliega mediante Docker Compose. Todos los servicios se levantan en la misma red para permitir comunicación por nombre de servicio.

Servicios:
- postgres: base de datos destino
- mage: orquestador de pipelines
- pgadmin: interfaz de administración de PostgreSQL

### Levantar el Proyecto: 
docker compose up

## 4. Gestión de secretos

Todos los valores sensibles se gestionan mediante Mage Secrets.

QuickBooks Online:
- QBO_CLIENT_ID: Identificador de la app
- QBO_CLIENT_SECRET: Secreto de la app
- QBO_REFRESH_TOKEN: Token de refresco OAuth
- QBO_REALM_ID: Identificador de la compañía
- QBO_ENV: Entorno (sandbox / prod)

PostgreSQL:
- POSTGRES_HOST
- POSTGRES_PORT
- POSTGRES_DB
- POSTGRES_USER
- POSTGRES_PASSWORD

Los secretos no se almacenan en el repositorio ni en variables de entorno expuestas. En caso de rotación del refresh token, el secret correspondiente se actualiza manualmente en Mage.

## 5. Diseño del pipeline qb_customers_backfill
El pipeline realiza un backfill histórico incremental utilizando el campo MetaData.LastUpdatedTime de QuickBooks Online.

### Parámetros

- fecha_inicio (ISO, UTC)
- fecha_fin (ISO, UTC)
- page_size (opcional)

### Segmentación

El rango de fechas se divide en ventanas diarias. Cada ventana se procesa de forma independiente, permitiendo reprocesos selectivos y control de volumen.

## 6. Autenticación y extracción
La autenticación se realiza mediante OAuth 2.0. En cada ejecución se obtiene un access token a partir del refresh token almacenado en Mage Secrets.
La extracción utiliza paginación con STARTPOSITION y MAXRESULTS. Se implementan reintentos con backoff exponencial y manejo explícito de errores 401 y 429.

## 7. Capa RAW en PostgreSQL
Los datos se almacenan en el esquema raw. Cada entidad tiene su propia tabla con la siguiente estructura:
- id (clave primaria)
- payload (JSONB)
- ingested_at_utc
- extract_window_start_utc
- extract_window_end_utc
- page_number
- page_size
- request_payload

La carga es idempotente mediante upsert por clave primaria.

## 8. Indempotencia y reprocesos

El pipeline puede ejecutarse múltiples veces sobre el mismo rango de fechas sin generar duplicados. En ejecuciones repetidas, los registros existentes se actualizan y no se insertan filas adicionales.

## 9. Observabilidad y métricas

Se registran métricas por ventana:
- páginas leídas
- filas procesadas
- duración por tramo

También se registran métricas globales por ejecución.

## 10. Trigger one-time
El backfill se ejecuta mediante un trigger tipo schedule configurado para una sola ejecución.

Ejemplo:
- Fecha/hora: 2026-02-01 15:30 UTC
- Equivalente: 2026-02-01 10:30 America/Guayaquil
- Parámetros: fecha_inicio=2026-01-01, fecha_fin=2026-01-31

Una vez completada la ejecución, el trigger fue deshabilitado para evitar relanzamientos accidentales.
