# Olist E-Commerce — SQL Data Integrity Investigation

A structured data integrity investigation using a real-world Brazilian e-commerce dataset, applying SQL investigation patterns used in Support Operations and Data Engineering roles — orphaned records, SLA breach analysis, payment anomaly detection, and query performance diagnostics.

**Author:** mmtovarl  
**Database:** PostgreSQL (local)  
**Dataset:** [Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) — Kaggle  
**Status:** In progress

---

## Dataset Overview

The Olist dataset represents real transactional data from a Brazilian e-commerce marketplace. It covers the full order lifecycle across multiple relational tables.

| Table | Description | Rows |
|---|---|---|
| `orders` | Order lifecycle — status, timestamps, delivery dates | 99,441 |
| `order_items` | Line items per order — product, seller, price, freight | 112,650 |
| `order_payments` | Payment records — type, installments, value | 103,886 |
| `order_reviews` | Customer reviews linked to orders | — |
| `customers` | Customer identity and location | — |
| `sellers` | Seller identity and location | — |
| `products` | Product catalogue with category | — |

---

## Project Structure

```
olist-ecommerce/
├── README.md
└── investigations/
    └── 01-payment-anomaly-sla-breach.md
```

Each investigation is a self-contained markdown file containing the objective, query, raw results, findings, and open questions. Investigations are numbered in sequence and named by finding type.

---

## Investigation Index

| # | Title | Tables | Type | Status |
|---|---|---|---|---|
| 01 | [Payment Anomaly & Confirmed SLA Breach](investigations/01-payment-anomaly-sla-breach.md) | `orders`, `order_payments` | Orphaned record, SLA analysis | Open |

---

## SQL Patterns Applied

- `LEFT JOIN + IS NULL` — orphaned record detection across related tables
- Timestamp comparison — SLA breach identification and delivery anomaly detection
- Aggregate cross-checking — payment totals vs order totals (upcoming)
- `EXPLAIN ANALYZE` — query performance diagnostics and index analysis (upcoming)

---

## Methodology

Each investigation follows a consistent structure:

1. **Objective** — what question is being asked and why it matters
2. **Query** — the SQL used, with pattern explanation
3. **Result** — raw output presented as a table
4. **Findings** — labeled findings with competing hypotheses clearly distinguished from confirmed facts
5. **Open Questions** — what cannot be resolved from the data alone
6. **Next Steps** — what additional data or access is required to close the finding

This mirrors the escalation format used in real Support Operations and Tier 3 investigation workflows.

---

*Dataset used under its original Kaggle license for analytical and portfolio purposes. No customer PII was retained or published.*
