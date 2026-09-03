# Investigation 01 — Payment Anomaly & Confirmed SLA Breach

**Dataset:** Brazilian E-Commerce Public Dataset (Olist)  
**Tables:** `orders`, `order_payments`  
**Type:** Data Integrity Investigation  
**Status:** Open — pending business context

---

## Objective

Cross-reference the `orders` and `order_payments` tables to identify orders with no matching payment record. A delivered order with no payment row represents either a pipeline failure, a misconfigured payment method, or a data integrity issue requiring engineering review.

---

## Query

```sql
SELECT *
FROM orders o
LEFT JOIN order_payments p ON o.order_id = p.order_id
WHERE p.order_id IS NULL;
```

**Pattern:** LEFT JOIN + IS NULL — returns all rows from the left table (`orders`) where no matching row exists in the right table (`order_payments`).

---

## Result

1 record returned out of 99,441 orders.

| Field | Value |
|---|---|
| `order_id` | `bfbd0f9bdef84302105ad712db648a6c` |
| `customer_id` | `86dc2ffce2dfff336de2f386a786e574` |
| `order_status` | `delivered` |
| `order_purchase_timestamp` | `2016-09-15 12:16:38` |
| `order_approved_at` | `2016-09-15 12:16:38` |
| `order_delivered_carrier_date` | `2016-11-07 17:11:53` |
| `order_delivered_customer_date` | `2016-11-09 07:47:38` |
| `order_estimated_delivery_date` | `2016-10-04 00:00:00` |

---

## Findings

### Finding 1 — Missing Payment Record

Order `bfbd0f9bdef84302105ad712db648a6c` has a status of `delivered` but no corresponding row in the `order_payments` table. This is anomalous: a successfully delivered order is expected to have at least one payment record.

**Two competing hypotheses — neither confirmed without additional data:**

1. **Payment pipeline error.** A failure in the payment processing step may have prevented a record from being written to `order_payments`, while the order continued through the fulfilment pipeline regardless.

2. **Coupon or loyalty redemption.** If the order total was covered entirely by store credit, loyalty points, or a promotional coupon, some payment systems are configured to skip writing a payment row for zero-monetary-value settlements. This would explain the missing record without indicating a bug.

**Supporting observation:** `order_purchase_timestamp` and `order_approved_at` are identical to the second (`2016-09-15 12:16:38`). This is consistent with an instant, automated approval (e.g. a loyalty redemption processed with no payment gateway delay), but is also consistent with a data pipeline issue where the approval timestamp was incorrectly copied from the purchase timestamp.

---

### Finding 2 — Confirmed SLA Breach

The order was delivered 35 days past its estimated delivery date.

| Metric | Value |
|---|---|
| Purchase date | 2016-09-15 |
| Estimated delivery | 2016-10-04 |
| Actual delivery | 2016-11-09 |
| Days to deliver | 55 days |
| Days past SLA | 35 days |

This is a confirmed customer-facing SLA failure, independent of the payment anomaly. Whether the delivery delay is related to the missing payment record or a separate logistics failure is unknown without internal order history.

---

## Open Questions

1. Does the company operate a loyalty points or promotional coupon programme? If so, are zero-value redemptions expected to produce no `order_payments` row?
2. Was order `bfbd0f9bdef84302105ad712db648a6c` flagged internally at any point during its 55-day fulfilment window?
3. Is the delivery delay linked to the payment anomaly, or are these two independent failures on the same order?

---

## Next Steps

- Obtain loyalty/coupon programme configuration to confirm or rule out hypothesis 2
- Request internal order event log for the flagged `order_id` to establish whether the delivery delay was tracked and actioned
- Expand investigation to check whether other `delivered` orders exist with anomalous approval timing (purchase timestamp = approval timestamp)

---

*Investigation conducted against the Olist Brazilian E-Commerce public dataset. Findings reflect data integrity analysis only — no customer PII was accessed or retained.*
