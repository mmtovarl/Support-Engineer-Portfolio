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

**Watch out:** a LEFT JOIN followed by a WHERE condition on the right table's column silently behaves like an INNER JOIN. Unmatched rows get NULL on the right side, and any comparison against NULL (`=`, `!=`, `>`, `<`) evaluates to NULL, not TRUE, so WHERE drops those rows anyway. If a LEFT JOIN isn't preserving unmatched rows in practice, check whether a WHERE clause is silently filtering them back out.

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

**The full-GROUP-BY rule:** every column in SELECT must be either inside an aggregate function or listed in GROUP BY. No third option (a fixed literal also qualifies, since it's the same value across every row in the group). PostgreSQL and MySQL 5.7+ (`ONLY_FULL_GROUP_BY` default) both reject queries that violate this. Older MySQL used to silently pick an arbitrary row's value instead, which is dangerous since the result looks valid but is meaningless.

This is a **per-column rule, not a column-count limit**. Any number of columns are fine as long as each one individually is either the GROUP BY column or wrapped in an aggregate:
```sql
-- All fine, six columns after the GROUP BY column, all aggregated
SELECT sender_id,
       COUNT(*) AS message_count,
       MAX(sent_date) AS last_message_date,
       MIN(sent_date) AS first_message_date,
       SUM(CASE WHEN sent_date >= '2022-08-15' THEN 1 ELSE 0 END) AS late_august_count,
       AVG(LENGTH(message_text)) AS avg_message_length
FROM messages
GROUP BY sender_id;
```

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

## Comments
```sql
-- single line comment, everything after -- on this line is ignored

/*
multi-line block comment,
useful for temporarily disabling
a chunk of the query while testing
*/
```
Practical use: comment out a JOIN or WHERE condition to isolate whether it's causing an unexpected result, instead of deleting and retyping it. Core to predict-then-verify debugging.

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

### SUM + CASE (conditional counting / pivoting)
```sql
SELECT
    SUM(CASE WHEN device_type = 'laptop' THEN 1 ELSE 0 END) AS laptop_views,
    SUM(CASE WHEN device_type IN ('tablet', 'phone') THEN 1 ELSE 0 END) AS mobile_views
FROM viewership;
```
- `CASE WHEN condition THEN 1 ELSE 0 END` turns a row-level true/false condition into a 0/1 flag
- `SUM()` over that flag counts how many rows matched
- One pass over the table counts multiple buckets at once, instead of separate filtered queries per condition
- Combine with GROUP BY to get the same breakdown per group (e.g. per date)

### COUNT(*) vs COUNT(column)
- `COUNT(*)` counts all rows, regardless of NULLs
- `COUNT(column)` counts only non-NULL values in that column
- Only identical if the column can never be NULL
- Default to `COUNT(*)` unless specifically counting non-null occurrences of one column; `COUNT(column)` silently undercounts if that column can contain NULLs

---

## Date / Timestamp Functions (dialect-specific, watch out)

Date columns are numeric under the hood, which is why arithmetic works on them (subtract dates, extract parts, add intervals). The display format you see in a results grid (e.g. `08/03/2022 00:00:00`) is applied by the client/UI rendering the results, it is not what's actually stored. String literals used in comparisons get parsed by the engine into that same underlying value.

**Always write date literals as ISO 8601 `YYYY-MM-DD`.** It's universally parsed correctly across dialects. Ambiguous formats like `MM/DD/YYYY` risk silent misparsing (wrong date, no error) or outright rejection depending on engine/locale.

### DATEDIFF
- **MySQL**: `DATEDIFF(later_date, earlier_date)` returns days. Order matters, reversed order gives a negative number.
- If comparing a row value against a baseline (e.g. a row's date vs a group average) and the sign should mean before/after, use `DATEDIFF(row_value, baseline)` so positive = after the baseline, negative = before.
- **PostgreSQL**: just subtract dates directly, `MAX(d) - MIN(d)`.
- **SQL Server**: `DATEDIFF(day, earlier, later)`, unit argument first, order reversed vs MySQL.
- **SQLite**: no native DATEDIFF, use `julianday(d1) - julianday(d2)`.

### YEAR() / MONTH()
- **MySQL only**: extracts year/month as an integer.
- **PostgreSQL/ANSI**: `EXTRACT(YEAR FROM date_col)` / `EXTRACT(MONTH FROM date_col)`.
- **SQLite**: `strftime('%Y', date_col)` / `strftime('%m', date_col)`.

DataLemur questions can be solved in either MySQL or Postgres syntax depending on which dialect is selected for the question. Check which one before reaching for DATEDIFF/YEAR (MySQL) vs EXTRACT (Postgres).

### Dialect-agnostic range filter (preferred when possible)
```sql
WHERE date_col >= '2022-08-01' AND date_col < '2022-09-01'
```
Works identically across every dialect, no function lookup needed. Also better for index usage, since wrapping a column in a function (like `YEAR(date_col)`) can prevent the database from using an index on that column.

### Averaging a date/timestamp in MySQL
`AVG()` doesn't work directly on a `DATE` type. Convert to numeric first:
```sql
DATE(FROM_UNIXTIME(AVG(UNIX_TIMESTAMP(date_col))))
```
Note: `DATE()` truncates the result rather than rounding, so summed deviations from this average may be off by 1 due to truncation. That's expected behavior, not a query bug.

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
- WHERE only includes rows where the condition is TRUE, so NULL comparisons silently exclude rows
- LEFT JOIN + IS NULL is the standard pattern for finding missing related records

---

## NOT IN vs NOT EXISTS

```sql
-- NOT IN: dangerous if the subquery can return NULL
SELECT * FROM customers
WHERE customer_id NOT IN (
    SELECT customer_id FROM orders
);
```
If that subquery returns even a single NULL, `NOT IN` silently returns **zero rows**, no error. `NOT IN` is internally a chain of `!=` comparisons ORed together, and any comparison against NULL evaluates to NULL, which poisons the whole chain.

```sql
-- NOT EXISTS: the safer equivalent
SELECT * FROM customers c
WHERE NOT EXISTS (
    SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id
);
```
`NOT EXISTS` checks for row existence via a correlated subquery, not value comparison against a list, so NULLs in the subquery's result don't matter.

**Rule of thumb:** if the subquery column could ever contain NULL, use `NOT EXISTS`. Only use `NOT IN` when the column is guaranteed NOT NULL.

---

## CTEs (WITH clause)

A named, temporary result set scoped to one query.
```sql
WITH high_value_customers AS (
    SELECT customer_id, SUM(total_amount) AS lifetime_spend
    FROM orders
    GROUP BY customer_id
    HAVING SUM(total_amount) > 1000
)
SELECT customers.name, high_value_customers.lifetime_spend
FROM high_value_customers
JOIN customers ON customers.customer_id = high_value_customers.customer_id;
```
Multiple CTEs chain with commas:
```sql
WITH step1 AS (
    SELECT ...
),
step2 AS (
    SELECT ... FROM step1 WHERE ...
)
SELECT * FROM step2;
```
- Defined once, can be referenced multiple times in the outer query, unlike a subquery which must be retyped each time
- Best for multi-step investigations (raw data -> flag anomalies -> aggregate), since each step gets a readable name instead of nested parentheses

---

## Subqueries

A subquery is a SELECT inside another SELECT. The inner query runs first, its result is used by the outer query. Subqueries can appear almost anywhere, not just WHERE:

- **SELECT list (scalar subquery)** — must return exactly one value per outer row. Only correlated to the outer query if it explicitly references an outer column; otherwise it runs independently.
- **FROM (derived table)** — acts as a temporary table.
- **HAVING** — same rules as WHERE.

### 1. Subquery in WHERE with IN (list of values)
```sql
SELECT *
FROM customers
WHERE customers.customer_id IN (
    SELECT orders.customer_id
    FROM orders
    WHERE orders.order_status = 'completed'
);
```
Same result as a JOIN + GROUP BY, but sometimes clearer to read. Prefer JOIN for large datasets (better performance).

### 2. Subquery in WHERE with single aggregate value
```sql
SELECT customer_id, total_amount
FROM orders
WHERE total_amount > (
    SELECT AVG(total_amount) FROM orders
);
```
This is where subqueries genuinely outperform JOINs: JOINs can't cleanly express "compare against a single aggregate of the whole table."

### 3. Correlated Subquery
```sql
SELECT * FROM products
WHERE products.price > (
    SELECT MIN(order_items.unit_price)
    FROM order_items
    WHERE order_items.product_id = products.product_id
);
```
Inner query references `products.product_id` from the outer query, running once per product row (slow on large tables). Must use an aggregate if multiple rows could match, otherwise SQLite may run silently with unreliable results (PostgreSQL/SQL Server would throw an error). Usually replaceable with a JOIN.

### When to use subqueries vs JOINs
- Prefer JOIN: combining data from multiple tables for display, or when performance matters on large datasets
- Prefer subquery: comparing against a single aggregate value (AVG, MAX, MIN), or when the logic reads more clearly as a nested question
- Avoid correlated subqueries on large tables, they run once per row and are slow
- **Avoid subqueries entirely when GROUP BY + aggregate answers the question** (see recurring mistake pattern below)

---

## Common Investigation Patterns

### Find missing related records
```sql
SELECT *
FROM bookings
LEFT JOIN payments ON bookings.booking_id = payments.booking_id
WHERE payments.payment_id IS NULL;
```
Or a `NOT EXISTS` correlated subquery as the NULL-safe alternative.

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
- Sum of payments > order total = overpayment, investigate immediately

### Find duplicate records generally (e.g. duplicate job listings)
```sql
SELECT COUNT(DISTINCT company_id) AS duplicate_companies
FROM (
    SELECT company_id
    FROM job_listings
    GROUP BY company_id, title, description
    HAVING COUNT(*) > 1
) duplicated_listings;
```
GROUP BY the columns that define "duplicate", then HAVING COUNT(*) > 1. **Don't reach for a self-join here** — it's a common instinct but creates unnecessary row-multiplication and is easy to get wrong (see the LEFT JOIN + WHERE trap above). GROUP BY + HAVING COUNT(*) > 1 is simpler, faster, and directly matches the actual question ("does more than one of this combination exist").

### Conditional breakdown by category
```sql
SELECT
    date,
    SUM(CASE WHEN device_type = 'laptop' THEN 1 ELSE 0 END) AS laptop_views,
    SUM(CASE WHEN device_type IN ('tablet', 'phone') THEN 1 ELSE 0 END) AS mobile_views
FROM viewership
GROUP BY date;
```

### Gap between first/last event per group
```sql
SELECT user_id,
    DATEDIFF(MAX(post_date), MIN(post_date)) AS days_between
FROM posts
WHERE post_date >= '2021-01-01' AND post_date < '2022-01-01'
GROUP BY user_id
HAVING COUNT(*) >= 2;
```
`HAVING COUNT(*) >= 2` excludes single-event groups where the gap is meaningless. No subquery needed, this is a GROUP BY + aggregate problem. Filter on the actual stated condition (row count), not a proxy that happens to correlate on current sample data — e.g. `days_between > 0` is NOT equivalent to `COUNT(*) >= 2`, it breaks silently on duplicate-date rows.

### Row-level value vs per-group baseline
```sql
WITH average AS (
    SELECT user_id,
        DATE(FROM_UNIXTIME(AVG(UNIX_TIMESTAMP(login_date)))) AS average_login
    FROM sessions
    GROUP BY user_id
)
SELECT sessions.user_id,
    sessions.login_date,
    average.average_login,
    DATEDIFF(sessions.login_date, average.average_login) AS difference
FROM sessions
LEFT JOIN average ON sessions.user_id = average.user_id;
```
Example: each login's distance from that user's average login date. Needed whenever the output must stay at row-level granularity while comparing against a group-level aggregate — GROUP BY alone collapses rows and can't do this, so use a CTE/subquery to compute the per-group baseline, then JOIN back to the row-level table.

**Verification trick:** deviations from an average should sum to approximately 0 (mathematical property of the mean). Sum the deviation column per group as a sanity check on the average calculation; small non-zero sums (e.g. off by 1) are expected rounding/truncation error, not a bug.

### Top N per group ranking
```sql
SELECT sender_id, COUNT(*) AS message_count
FROM messages
GROUP BY sender_id
ORDER BY message_count DESC
LIMIT 2;
```
`ORDER BY ... LIMIT N` only works safely if no ties are expected in the data. If ties are possible and must be handled correctly, use `RANK()` (a window function) instead — `LIMIT` arbitrarily picks one of the tied rows with no guaranteed stability.

### First/last row per group with full row data
Not yet covered in depth — flagged as the next topic. GROUP BY collapses rows and loses access to other columns, so this needs a window function: `ROW_NUMBER() OVER (PARTITION BY group_col ORDER BY date_col ASC/DESC)`.

---

## Recurring Mistake Pattern to Watch For

Reaching for a subquery or self-join by default when the real need is GROUP BY + aggregate.

**Test before writing the query:** am I comparing across genuinely separate/unrelated data (subquery), or do I just need a value computed within a group I already have (GROUP BY + aggregate, no subquery)?

**Deeper version of the test:** does the output need to stay at row-level granularity, or collapse to one row per group?
- If row-level detail must be kept alongside a group-level or whole-table aggregate (e.g. each row vs its group's average), GROUP BY alone cannot do it — you need a subquery/CTE+JOIN or a window function, even when the comparison is within the "same column."
- Finding duplicates specifically is almost always `GROUP BY + HAVING COUNT(*) > 1`, not a self-join.

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
- Use `=` for exact matches (strings or numbers), `LIKE` only when using `%` or `_` wildcards for pattern matching. Never use `LIKE` without a wildcard, it works but is slower and communicates wrong intent
- Table aliases are most useful when referencing the same table twice in one query (e.g. correlated subqueries), not just for saving keystrokes
