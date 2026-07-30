# SQL Investigation Cheat Sheet

## Query Execution Order
SQL does NOT execute top-to-bottom like JavaScript. Actual order:
```
FROM → JOIN → WHERE → GROUP BY → (aggregates computed) → HAVING → SELECT → ORDER BY → LIMIT
```
This explains why:
- Aliases defined in SELECT cannot be used in WHERE or HAVING
- Aggregate functions (COUNT, SUM) cannot be used in WHERE
- ORDER BY can reference aliases (it runs after SELECT)

---

## Core Clauses

### SELECT
```sql
SELECT column1, column2, expression AS alias
FROM table;
```
- `*` returns all columns (avoid in production queries, be explicit)
- No way to exclude specific columns in standard SQL (no `SELECT * EXCEPT`)
- Aliases are for display and ORDER BY only, not for WHERE/HAVING

### WHERE
```sql
WHERE column = 'value'
WHERE column > 100
WHERE column IS NULL
WHERE column IS NOT NULL
WHERE column != 'value'
WHERE (quantity_on_hand - quantity_reserved) < 5  -- use brackets for clarity
```
- Filters individual rows BEFORE grouping
- Cannot use aggregate functions here
- Cannot reference SELECT aliases here
- Always use IS NULL / IS NOT NULL, never = NULL or != NULL

### JOIN Types
```sql
-- INNER JOIN (same as JOIN): only rows with matches in both tables
FROM orders
INNER JOIN payments ON orders.order_id = payments.order_id

-- LEFT JOIN: all rows from left table, NULLs where no match on right
FROM orders
LEFT JOIN payments ON orders.order_id = payments.order_id

-- Multiple JOINs: each gets its own ON clause
FROM bookings
LEFT JOIN payments ON bookings.booking_id = payments.booking_id
LEFT JOIN sync_log ON bookings.booking_id = sync_log.booking_id
```
- Use LEFT JOIN when you need to find missing records (NULL on right side)
- Never chain ON clauses: `ON table1.id = table2.id = table3.id` is invalid
- Always use table.column notation in ON clauses for clarity

### GROUP BY + HAVING
```sql
SELECT action_type, COUNT(action_type) AS count_action
FROM user_activity
GROUP BY action_type
HAVING COUNT(action_type) > 50
ORDER BY COUNT(action_type) DESC;
```
- GROUP BY groups rows, then aggregates are computed per group
- HAVING filters groups AFTER aggregation (WHERE equivalent for groups)
- Cannot use aliases in HAVING, must repeat the expression
- Always comes before ORDER BY

### ORDER BY
```sql
ORDER BY column DESC                          -- single column
ORDER BY column1 DESC, column2 ASC           -- multiple columns
ORDER BY ABS(difference) DESC                 -- order by expression
ORDER BY                                      -- deprioritize cancelled orders
  CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END,
  ABS(difference) DESC;
```
- Goes at the very end of the query
- Can reference SELECT aliases (unlike WHERE/HAVING)
- Multiple conditions: comma-separated, evaluated left to right

---

## Useful Functions

### ROUND
```sql
ROUND(SUM(order_items.line_total), 2)  -- round to 2 decimal places
```
- Standard SQL, works across SQLite, PostgreSQL, MySQL, SQL Server
- Rounding in HAVING can mask small differences, consider checking raw values first

### ABS
```sql
ORDER BY ABS(difference) DESC  -- sort by magnitude, ignoring positive/negative
```
- Strips the sign, treats -419 and 419 as equal magnitude
- Essential for financial investigation where gaps can be in either direction

### CASE
```sql
CASE WHEN condition THEN value ELSE other_value END
```
- Used inline in SELECT, ORDER BY, WHERE
- Useful for conditional sorting, labeling, or categorization

---

## NULL Handling
```sql
-- Correct
WHERE payments.payment_id IS NULL
WHERE payments.payment_id IS NOT NULL

-- Wrong (never works in any database)
WHERE payments.payment_id = NULL
WHERE payments.payment_id != NULL
```
- NULL means "unknown/missing", not zero or empty string
- Any comparison against NULL (=, !=, >, <) returns NULL, not TRUE/FALSE
- WHERE only includes rows where condition is TRUE, so NULL comparisons silently exclude rows
- LEFT JOIN + IS NULL is the standard pattern for finding missing related records

---

## Common Investigation Patterns

### Find missing related records
```sql
SELECT *
FROM bookings
LEFT JOIN payments ON bookings.booking_id = payments.booking_id
WHERE payments.payment_id IS NULL;
```

### Find data mismatches across tables
```sql
SELECT orders.order_id, orders.total_amount,
       ROUND(SUM(order_items.line_total), 2) AS sum_of_items,
       ROUND((orders.total_amount - SUM(order_items.line_total)), 2) AS difference
FROM orders
LEFT JOIN order_items ON orders.order_id = order_items.order_id
GROUP BY orders.order_id
HAVING orders.total_amount != ROUND(SUM(order_items.line_total), 2)
ORDER BY
  CASE WHEN orders.order_status = 'cancelled' THEN 1 ELSE 0 END,
  ABS(difference) DESC;
```

### Find records below a threshold
```sql
SELECT inventory.product_id, products.name,
       inventory.quantity_on_hand,
       inventory.quantity_reserved,
       (inventory.quantity_on_hand - inventory.quantity_reserved) AS available
FROM inventory
LEFT JOIN products ON inventory.product_id = products.product_id
WHERE (inventory.quantity_on_hand - inventory.quantity_reserved) < 5;
```

### Correlate failures across three tables
```sql
SELECT *
FROM bookings
LEFT JOIN payments ON bookings.booking_id = payments.booking_id
LEFT JOIN sync_log ON bookings.booking_id = sync_log.booking_id
WHERE sync_log.sync_status = 'failed'
  AND (payments.payment_id IS NULL OR payments.status = 'failed');
```

### Find orders with no valid payment (completed/shipped but unpaid)
```sql
SELECT *
FROM orders
LEFT JOIN payments ON orders.order_id = payments.order_id
WHERE (orders.order_status = 'completed' OR orders.order_status = 'shipped')
  AND (payments.payment_id IS NULL OR payments.payment_status = 'failed');
```
- Brackets are critical here: AND evaluates before OR without them, giving wrong results
- Check payment_id IS NULL (missing row), not payment_status IS NULL (ambiguous)

### Find orders where sum of payments exceeds order total (overpayment/duplicate charges)
```sql
SELECT orders.order_id, orders.total_amount,
       SUM(payments.amount) AS sum_paid,
       SUM(payments.amount) - orders.total_amount AS overpayment
FROM orders
LEFT JOIN payments ON orders.order_id = payments.order_id
GROUP BY orders.order_id
HAVING SUM(payments.amount) > orders.total_amount;
```
- A foreign key (order_id in payments) is NOT unique, multiple payments can reference one order
- Two payment records for one order = either split payment or duplicate charge, check the amounts
- Sum of payments > order total = overpayment, investigate immediately

---

## Subqueries

A subquery is a SELECT inside another SELECT. The inner query runs first, its result is used by the outer query. Three places subqueries can live:

### 1. Subquery in WHERE with IN (list of values)
Use when you need to filter based on a list produced by another query.
```sql
-- Find all customers who have at least one completed order
SELECT *
FROM customers
WHERE customers.customer_id IN (
    SELECT orders.customer_id
    FROM orders
    WHERE orders.order_status = 'completed'
);
```
- Inner query runs first, returns a list of customer_ids
- Outer query filters customers to only those in that list
- Same result as a JOIN + GROUP BY, but sometimes clearer to read
- Prefer JOIN for large datasets (better performance)

### 2. Subquery in WHERE with single aggregate value
Use when you need to compare against a dynamically computed value (average, max, min).
```sql
-- Find all orders above the average order amount
SELECT customer_id, total_amount
FROM orders
WHERE total_amount > (
    SELECT AVG(total_amount) FROM orders
);
```
- Inner query computes one value (the average across all orders)
- Outer query uses that value as a dynamic filter
- Never hardcode the value, use the subquery so it recalculates if data changes
- This is where subqueries genuinely outperform JOINs: JOINs cannot cleanly express "compare against a single aggregate of the whole table"

### 3. Correlated Subquery
Use when the inner query needs to reference the current row of the outer query. Runs once per row of the outer query.
```sql
-- Find products where standard price is higher than the lowest unit price ever charged
SELECT * FROM products
WHERE products.price > (
    SELECT MIN(order_items.unit_price)
    FROM order_items
    WHERE order_items.product_id = products.product_id
);
```
- Inner query references `products.product_id` from the outer query
- Runs once per product row, making it slower on large tables
- Must use an aggregate (MIN, MAX, AVG) if multiple rows could match, otherwise SQLite may run silently but return unreliable results (PostgreSQL/SQL Server would throw an error)
- Usually replaceable with a JOIN, which is faster and clearer for this use case

### When to use subqueries vs JOINs
- Prefer JOIN: when combining data from multiple tables for display, or when performance matters on large datasets
- Prefer subquery: when comparing against a single aggregate value (AVG, MAX, MIN), or when the logic reads more clearly as a nested question
- Avoid correlated subqueries (inner query references outer query per row) on large tables, they run once per row and are slow
- Modern query optimizers often rewrite subqueries as JOINs internally anyway, so on small/medium datasets the difference is minimal

---

## Operator Precedence in WHERE

AND evaluates before OR, same as multiplication before addition in math:

```sql
-- This is ambiguous and likely wrong:
WHERE status = 'completed' OR status = 'shipped' AND payment_id IS NULL OR payment_status = 'failed'

-- SQL reads it as:
WHERE status = 'completed'
   OR (status = 'shipped' AND payment_id IS NULL)
   OR payment_status = 'failed'

-- What you probably meant (use brackets to be explicit):
WHERE (status = 'completed' OR status = 'shipped')
  AND (payment_id IS NULL OR payment_status = 'failed')
```
- Always use brackets when mixing AND and OR in the same WHERE clause
- If a query returns unexpected results, check your AND/OR grouping first

---

## Style Rules
- Always use `table.column` notation in multi-table queries
- Use brackets around expressions for clarity: `(quantity_on_hand - quantity_reserved) < 5`
- Use `IS NULL` / `IS NOT NULL`, never `= NULL`
- Keywords case-insensitive in SQL, but consistent casing improves readability
- Aliases use snake_case: `sum_of_items`, not `Sum Of Items` or `'Sum of Items'`
- One JOIN per line, aligned ON clauses for readability
