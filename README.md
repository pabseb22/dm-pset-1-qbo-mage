# DM PSet 1 — QBO Backfill with Mage + Postgres (RAW)

This repository contains three historical backfill pipelines for **QuickBooks Online (QBO)**:
- Customers
- Items
- Invoices

The pipelines are orchestrated with **Mage** and load data into a **Postgres RAW layer** (JSON payload + ingestion metadata).
Everything runs locally via **Docker Compose**.

## Requirements
- Docker + Docker Compose

## Quick start
```bash
docker compose up -d
```

## Services

Mage: http://localhost:6789

PgAdmin: http://localhost:5050

Postgres: localhost:5432 (db: warehouse, user: postgres, password: postgres)

Repository structure (WIP)

db/init/ → SQL initialization scripts executed automatically by Postgres on first boot.


---