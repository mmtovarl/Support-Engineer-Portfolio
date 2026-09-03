# SQL Investigation Practice: Correlating Booking and Payment Data

## Setup

To build SQL skills for real integration troubleshooting, I created a synthetic PMS environment with three tables representing the actual systems involved in a booking-to-sync workflow: bookings (the core reservation data), payments (the financial records), and sync_log (the record of attempts to push data to an external system). The tables intentionally include failure patterns that mirror real integration problems: missing payments, failed transactions, and sync timeouts.

This isn't production data, but the investigation pattern is directly transferable. A real incident would have the same shape: data exists in one system but not another, amounts don't match, or external systems reject records without explaining why. The queries here demonstrate how to surface those gaps systematically.

## Query 1: Bookings with Missing Payment Records

**Question**: Which bookings exist in the system but have no corresponding payment record at all?

**Query**:
```sql
SELECT * 
FROM bookings
LEFT JOIN payments ON bookings.booking_id = payments.booking_id
WHERE payments.payment_id IS NULL;
```

**Finding**: Two bookings (IDs 7 and 15) have no payment record. These represent a complete failure mode, not a failed transaction, but an absence of any transaction attempt. The booking was created, but payment processing never happened, or never created a record if it did.

**What this reveals**: A missing payment record points immediately upstream to the payment system, this is where the chain broke. Either the payment request was never sent, or it failed silently without writing a record back to the booking system. This is a data consistency issue at the system boundary, not a typo or configuration problem.

## Query 2: Bookings with Payment Amount Mismatches or Missing Payments

**Question**: Which bookings have either no payment at all, or a payment recorded at a different amount than the booking?

**Query**:
```sql
SELECT * 
FROM bookings
LEFT JOIN payments ON bookings.booking_id = payments.booking_id
WHERE bookings.amount != payments.amount 
   OR payments.payment_id IS NULL;
```

**Finding**: Three bookings with data anomalies: two with no payment (IDs 7, 15) and one with a mismatch (ID 12 booked for 540 but payment recorded for 500).

**What this reveals**: The amount mismatch (booking 12) is a different failure category than the missing payment. A recorded-but-wrong amount suggests the payment processed, but the amount got corrupted or miscalculated somewhere between systems. Unlike the missing payment, there's a transaction to trace. Unlike a failed payment status, there's no explicit error message, just data that doesn't add up. This requires checking: did the customer actually pay the wrong amount, did a discount get applied without updating the booking, or is this a transcription error during sync?

## Query 3: Bookings with Failed Syncs and Upstream Payment Problems

**Question**: How many bookings failed to sync to the external system, and did those failures correlate with payment problems?

**Query**:
```sql
SELECT *
FROM bookings
LEFT JOIN payments ON bookings.booking_id = payments.booking_id
LEFT JOIN sync_log ON bookings.booking_id = sync_log.booking_id
WHERE sync_log.sync_status = 'failed' 
  AND (payments.payment_id IS NULL OR payments.status = 'failed');
```

**Finding**: All four bookings with failed syncs (IDs 4, 7, 11, 15) also had payment problems: either no payment record or an explicit failed status. The sync errors give additional context:
- Booking 4: Payment declined, sync failed with "Payment declined"
- Booking 7: No payment, sync failed with "Timeout"
- Booking 11: Failed payment, sync failed with "Invalid payment amount"
- Booking 15: No payment, sync failed with "Booking not found in PMS"

**What this reveals**: The 100% correlation between sync failures and upstream payment problems is significant. It suggests the sync failures are downstream symptoms of payment problems, not independent issues. When troubleshooting, this pattern tells you to fix the payment side first, the sync will likely succeed once the upstream data is correct. This is exactly the kind of triage information that transforms a diffuse problem ("syncs are failing") into a focused one ("payment system isn't recording data").

## What This Demonstrates

The investigation moved through three layers of sophistication: finding missing data (LEFT JOIN with NULL check), finding data mismatches (comparison operators on joined columns), and finally correlating across three systems to identify causality. Each query was built with a hypothesis first (before looking at results), then checked against the actual data. The ability to distinguish between "this booking has no payment" (complete data absence), "this payment has the wrong amount" (data corruption), and "this payment failed with an error" (explicit failure signal) is the core of real incident investigation, each scenario points to a different root cause and different fix.

The other key lesson: NULL handling in SQL is not a quirk to work around, it's a critical signal. When a joined field comes back NULL, that's the database telling you data that should be present isn't there. Building queries that surface those NULLs deliberately, rather than silently filtering them out, is often the difference between finding a bug and missing it.
