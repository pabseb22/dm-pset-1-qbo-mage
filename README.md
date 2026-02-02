# DM PSet 1 — QBO Backfill with Mage + Postgres (RAW)

## Elaborado por: Pablo Alvarado - 00344965

Este proyecto fue desarrollado como parte del DM PSet 1, con el objetivo de aplicar conceptos de ingeniería de datos relacionados con ingesta histórica, orquestación de pipelines y diseño de capas RAW, utilizando herramientas modernas y buenas prácticas de seguridad y observabilidad.

---

## Objetivo del Deber

El objetivo de este deber es diseñar e implementar un pipeline de backfill histórico que permita extraer información desde una API real (QuickBooks Online) y almacenarla en una base de datos relacional, garantizando:

- uso correcto de OAuth 2.0 para autenticación,
- orquestación parametrizada mediante Mage,
- ejecución controlada mediante triggers one-time,
- diseño de una capa RAW con payload completo y metadatos de ingesta,
- idempotencia, reprocesos seguros y observabilidad,
- gestión segura de credenciales mediante Mage Secrets.

El enfoque del proyecto prioriza la trazabilidad de los datos, la reproducibilidad de las ejecuciones y la claridad operativa del pipeline.



## 1. Descripción del Proyecto

Este proyecto implementa un pipeline de backfill histórico desde QuickBooks Online (QBO) hacia PostgreSQL, utilizando Mage como orquestador. El objetivo es extraer información histórica de las entidades Customers, Items e Invoices y almacenarla en una capa RAW con payload completo y metadatos de ingesta.

El diseño prioriza idempotencia, observabilidad, reprocesos seguros y una gestión adecuada de credenciales mediante Mage Secrets.

---

## 2. Arquitectura

La arquitectura del sistema se compone de los siguientes elementos:

- QuickBooks Online (QBO) como fuente de datos, accedida mediante API REST y OAuth 2.0.
- Mage como motor de orquestación y ejecución de pipelines.
- PostgreSQL como base de datos destino, utilizando un esquema RAW sin transformaciones.
- Docker Compose para el despliegue local y la red entre servicios.

Todos los servicios se comunican dentro de la misma red Docker utilizando el nombre del servicio como host.

---

## 3. Infraestructura y Despliegue

El proyecto se despliega mediante Docker Compose. Al levantar el entorno se inicializan automáticamente Mage, PostgreSQL y PgAdmin.

Servicios incluidos:
- postgres: base de datos destino.
- mage: orquestador de pipelines.
- pgadmin: herramienta de administración de PostgreSQL.

Para levantar el entorno completo se utiliza el comando:

docker compose up

No es necesario modificar el archivo docker-compose.yml.  
El esquema RAW y las tablas se crean automáticamente mediante scripts SQL incluidos en el directorio db/init.

---

## 4. Gestión de Secretos

Todos los valores sensibles se gestionan exclusivamente mediante Mage Secrets.  
No existen credenciales almacenadas en el repositorio ni en variables de entorno expuestas.

### Secretos de QuickBooks Online

- QBO_CLIENT_ID  
  Propósito: Identificador de la aplicación registrada en Intuit Developer.

- QBO_CLIENT_SECRET  
  Propósito: Secreto asociado a la aplicación QBO para el flujo OAuth 2.0.

- QBO_REFRESH_TOKEN  
  Propósito: Token de refresco utilizado para obtener access tokens en cada ejecución del pipeline.

- QBO_REALM_ID  
  Propósito: Identificador de la compañía de QuickBooks Online desde la cual se extraen los datos.

- QBO_ENV  
  Propósito: Define el entorno de ejecución (sandbox o production).

### Secretos de PostgreSQL

- POSTGRES_HOST  
  Propósito: Host de la base de datos (nombre del servicio Docker).

- POSTGRES_PORT  
  Propósito: Puerto de conexión a PostgreSQL.

- POSTGRES_DB  
  Propósito: Nombre de la base de datos destino.

- POSTGRES_USER  
  Propósito: Usuario de conexión a la base de datos.

- POSTGRES_PASSWORD  
  Propósito: Contraseña del usuario de PostgreSQL.

### Proceso de Rotación de Secretos

En caso de rotación del refresh token de QuickBooks Online (por expiración o invalidación), el nuevo token se obtiene mediante el proceso de autorización en Intuit Developer y se actualiza manualmente en Mage Secrets.

### Responsables

La creación, actualización y rotación de secretos es responsabilidad del operador del pipeline.

---

## 5. Pipelines Implementados

Se implementaron tres pipelines independientes en Mage:

- qb_customers_backfill
- qb_items_backfill
- qb_invoices_backfill

Cada pipeline sigue el mismo patrón de diseño y operación.

---

## 6. Diseño Funcional de los Pipelines qb_<entidad>_backfill

### Parámetros de Entrada

Cada pipeline acepta los siguientes parámetros, definidos al momento de ejecutar el trigger:

- fecha_inicio: fecha inicial del backfill (formato ISO, UTC).
- fecha_fin: fecha final del backfill (formato ISO, UTC).
- page_size (opcional): tamaño de página para la paginación de la API.

### Segmentación Temporal

El rango de fechas se divide en ventanas diarias.  
Cada ventana se procesa de forma independiente, lo que permite:

- controlar el volumen de datos,
- reintentar ventanas específicas,
- reanudar ejecuciones fallidas sin reprocesar todo el rango.

---

## 7. Autenticación y Extracción de Datos

La autenticación se realiza mediante OAuth 2.0 utilizando el flujo de refresh token.  
En cada ejecución del pipeline se obtiene un access token válido a partir del refresh token almacenado en Mage Secrets.

La extracción de datos incluye:

- filtros históricos basados en MetaData.LastUpdatedTime en UTC,
- paginación mediante STARTPOSITION y MAXRESULTS,
- manejo de rate limits y errores temporales,
- reintentos con backoff exponencial ante errores 429 y 5xx,
- reintento automático de autenticación ante errores 401.

---

## 8. Capa RAW en PostgreSQL

Los datos se almacenan en el esquema raw de PostgreSQL.  
Cada entidad cuenta con su propia tabla:

- raw.qb_customers
- raw.qb_items
- raw.qb_invoices

### Estructura de las Tablas RAW

Cada tabla incluye las siguientes columnas:

- id: clave primaria de la entidad en QBO.
- payload: objeto completo de la entidad en formato JSONB.
- ingested_at_utc: timestamp de carga del registro.
- extract_window_start_utc: inicio de la ventana de extracción.
- extract_window_end_utc: fin de la ventana de extracción.
- page_number: número de página leída.
- page_size: tamaño de página utilizado.
- request_payload: información de la consulta ejecutada.

---

## 9. Idempotencia y Reprocesos

La carga de datos es idempotente.  
Se utiliza un upsert por clave primaria, lo que garantiza que:

- al reejecutar un mismo rango no se generan duplicados,
- los registros existentes se actualizan con la información más reciente.

Esto permite reprocesar ventanas específicas de forma segura.

---

## 10. Observabilidad y Métricas

Durante la ejecución de los pipelines se registran métricas por ventana:

- número de páginas leídas,
- número de registros procesados,
- duración de cada tramo.

Además, al final de cada ejecución se registra un resumen global con el total de filas procesadas y el tiempo total de ejecución.

## 10.1 Interpretación de Logs, Idempotencia y Uso de LastUpdatedTime

### Comportamiento de los Logs y Control de Duplicados

Durante la ejecución de los pipelines, los logs muestran métricas claras sobre la cantidad de registros insertados y actualizados en cada corrida. El exporter implementa un mecanismo de upsert por clave primaria (id), lo que implica el siguiente comportamiento:

- Si un registro no existe previamente en la tabla RAW, se inserta.
- Si un registro ya existe (mismo id), no se vuelve a insertar.
- En caso de existir, el registro se actualiza, incluyendo el payload y los metadatos de ingesta, para mantener consistencia y trazabilidad.

Este comportamiento se refleja en los logs del exporter mediante métricas explícitas de:
- inserted
- updated
- total

De esta forma, la ausencia de nuevas inserciones en ejecuciones posteriores no indica un error, sino que confirma que la idempotencia está funcionando correctamente.

---

### Uso de LastUpdatedTime como Criterio de Extracción

Los pipelines utilizan el campo MetaData.LastUpdatedTime provisto por QuickBooks Online para filtrar los registros históricos dentro del rango de fechas definido. Esto significa que:

- Solo se extraen registros que hayan sido creados o modificados dentro de la ventana temporal solicitada.
- Los registros que no han tenido cambios en ese período no son devueltos por la API.
- Por esta razón, es posible observar un número reducido de registros para ciertos rangos de fechas, especialmente en entornos sandbox con baja actividad.

Este diseño es intencional y responde a un patrón de backfill incremental, enfocado en capturar cambios y no en generar snapshots completos de toda la entidad en cada ejecución.

---

### Consideración sobre Creación vs. Actualización

El criterio de extracción se basa en la última actualización (LastUpdatedTime) y no exclusivamente en la fecha de creación del registro. Esto implica que:

- Un registro creado antes del rango de fechas y no modificado posteriormente no será extraído.
- Un registro creado antes pero modificado dentro del rango sí será extraído.
- Este comportamiento es consistente con pipelines incrementales y permite un control eficiente del volumen de datos.

Si se requiere capturar todos los registros independientemente de su última actualización, el pipeline puede ajustarse para realizar un snapshot completo sin filtros temporales o utilizando otro criterio de fecha. Sin embargo, para este proyecto se priorizó el enfoque incremental alineado con el enunciado del deber.

---

### Conclusión Operativa

En resumen:
- Los logs reflejan correctamente el comportamiento idempotente del pipeline.
- La actualización de registros existentes garantiza consistencia en la información almacenada.
- El uso de LastUpdatedTime explica la variabilidad en la cantidad de registros por tramo y es una decisión de diseño consciente y documentada.


---

## 11. Trigger One-Time

Cada pipeline se ejecuta mediante un trigger tipo schedule configurado para una sola ejecución.

Ejemplo de configuración:

- Fecha y hora de ejecución: 2026-02-01 15:30 UTC
- Equivalente en America/Guayaquil: 2026-02-01 10:30
- Parámetros:
  - fecha_inicio = 2026-01-01
  - fecha_fin = 2026-01-31

Una vez finalizada la ejecución, el trigger fue deshabilitado para evitar relanzamientos accidentales.

---

## 12. Validaciones y Volumetría

Para validar la correcta ejecución del pipeline se realizan las siguientes comprobaciones:

- conteo total de registros por entidad,
- conteo de registros por ventana diaria,
- verificación de timestamps en UTC,
- comparación de resultados entre ejecuciones repetidas para validar idempotencia.

Estas validaciones permiten detectar regresiones, días vacíos inesperados o inconsistencias temporales.

---

## 13. Troubleshooting

### Error invalid_grant
Indica que el refresh token no es válido o expiró.  
Solución: reautorizar la aplicación en Intuit Developer y actualizar el secret QBO_REFRESH_TOKEN en Mage.

### Rate limits (HTTP 429)
El pipeline implementa reintentos automáticos con backoff exponencial. Si el error persiste, se debe reducir el tamaño de página o el rango temporal.

### Problemas de timezone
Todos los filtros y marcas de tiempo se manejan en UTC. Las fechas ingresadas por trigger deben estar en UTC.

### Problemas de almacenamiento o permisos
Verificar que los volúmenes Docker estén correctamente montados y que PostgreSQL se haya inicializado sin errores.

---

## 14. Checklist de Aceptación

✔ Mage y Postgres se comunican por nombre de servicio.
✔ Todos los secretos están gestionados en Mage Secrets.
✔ Los pipelines aceptan fecha_inicio y fecha_fin en UTC.
✔ Los triggers one-time están configurados y deshabilitados tras la ejecución.
✔ El esquema RAW incluye payload completo y metadatos.
✔ La idempotencia fue verificada mediante reprocesos.
✔ La paginación, reintentos y rate limits están manejados.
✔ Existen evidencias de volumetría y validaciones.
✔ Se cuenta con documentación y runbook operativo.


## Conclusiones

A lo largo de este proyecto se implementó un pipeline de backfill histórico funcional y robusto, capaz de extraer datos reales desde QuickBooks Online y almacenarlos en una capa RAW bien definida en PostgreSQL.

El uso de segmentación temporal, paginación e idempotencia permitió controlar el volumen de datos y garantizar ejecuciones reproducibles sin duplicados. La orquestación mediante Mage facilitó la parametrización, el monitoreo y la ejecución controlada mediante triggers one-time.

Asimismo, la gestión centralizada de secretos y la documentación detallada del proceso aseguran que el pipeline sea operable, seguro y fácil de auditar. En conjunto, el proyecto cumple con los objetivos planteados en el deber y refleja un diseño alineado con prácticas reales de ingeniería de datos.
