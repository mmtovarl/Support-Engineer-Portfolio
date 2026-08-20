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
- Always alias aggregate outputs explicitly (e.g. `SUM(amount) AS deposit_total`), never rely on the engine's implicit default column name (e.g. bare `sum`); it's ambiguous and dialect-dependent

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

-- FULL OUTER JOIN: all rows from BOTH tables, NULLs on whichever side has no match
FROM deposits
FULL OUTER JOIN withdrawals ON deposits.account_id = withdrawals.account_id

-- Multiple JOINs: each gets its own ON clause
FROM bookings
LEFT JOIN payments ON bookings.booking_id = payments.booking_id
LEFT JOIN sync_log ON bookings.booking_id = sync_log.booking_id
```
- Use LEFT JOIN when you need to find missing records (NULL on right side), or when you genuinely expect some rows might not have a match and want to keep them anyway
- Use INNER JOIN (or bare JOIN) when a match is expected to always exist
- Use FULL OUTER JOIN when combining two independently-aggregated result sets (e.g. two CTEs, one per category) and every entity from either side must appear in the output, even if it only has data on one side
- **`JOIN` and `INNER JOIN` are functionally identical** (INNER is the implicit default), but write `INNER JOIN` explicitly. It's a forcing function to consciously decide whether a match should always exist, rather than defaulting to LEFT JOIN out of habit because "it's worked so far." LEFT JOIN defaulting can mask real data integrity issues (orphaned rows with no valid foreign key) that are worth knowing about, not silently including
- **INNER JOIN between two separately-aggregated CTEs silently drops rows that exist in only one CTE** (e.g. an account with deposits but no withdrawals never appears in the result). If every entity must appear regardless of which side has data, use FULL OUTER JOIN + COALESCE, or better, check whether a single-pass GROUP BY + CASE avoids the join entirely (see Conditional Running Balance below)
- Never chain ON clauses: `ON table1.id = table2.id = table3.id` is invalid
- Always use table.column notation in ON clauses for clarity
- **Prefer `ON` over `USING`**, even when both tables share an identically-named column (e.g. `USING (user_id)`). `USING` merges the joined column into a single collapsed output column, losing the ability to reference `table.column` separately afterward, and it breaks the moment column names differ across tables, which happens constantly in real schemas

**Watch out:** a LEFT JOIN followed by a WHERE condition on the right table's column silently behaves like an INNER JOIN. Unmatched rows get NULL on the right side, and any comparison against NULL (`=`, `!=`, `>`, `<`) evaluates to NULL, not TRUE, so WHERE drops those rows anyway. If a LEFT JOIN isn't preserving unmatched rows in practice, check whether a WHERE clause is silently filtering them back out.

**When you need to filter the right table's columns (e.g. a date range) while still preserving unmatched left rows** (e.g. every employee, even those with zero matching activity), put that filter in the `ON` clause, not `WHERE`:
```sql
-- Correct: date filter in ON, every employee still appears even with 0 matches
SELECT employees.employee_id, COUNT(DISTINCT queries.query_id) AS unique_queries
FROM employees
LEFT JOIN queries
  ON employees.employee_id = queries.employee_id
  AND queries.query_starttime >= '2023-07-01' AND queries.query_starttime < '2023-10-01'
GROUP BY employees.employee_id;
```
Putting the date condition in `ON` means "only match rows in this range, but still keep every employee regardless." Putting it in `WHERE` instead would drop any employee whose only activity falls outside the range, or who has none at all, since the NULL-filled unmatched rows fail the WHERE condition.

### Self-Joins
Alias **both** sides symmetrically with role-based names (e.g. `emp`/`mgr`), never leave one side as the bare table name. A bare table name on one side of a self-join is legal but makes it easy to lose track of which alias represents which role, especially mid-debugging.

```sql
-- Compare employees against their managers
SELECT emp.employee_id, emp.name
FROM employee AS emp
LEFT JOIN employee AS mgr ON emp.manager_id = mgr.employee_id
WHERE emp.salary > mgr.salary;
```

Symmetric role-based aliasing makes the comparison direction visually obvious at every line and reduces risk of accidentally swapping the comparison (e.g. writing `mgr.salary > emp.salary` by mistake).

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

**Composite GROUP BY (multiple columns) — mental model: composite buckets.** `GROUP BY col1, col2` creates one bucket per unique **combination** of both values, not sequential grouping. `GROUP BY country, device_type` creates a distinct bucket for every `(country, device_type)` pair, e.g. `(US, Mobile)`, `(US, Laptop)`, `(UK, Mobile)`, not "group by country, then subdivide by device."

```sql
SELECT country, device_type, COUNT(user_id) AS total_users, SUM(view_count) AS total_views
FROM user_activity
GROUP BY country, device_type
ORDER BY country ASC, total_views DESC;
```

**GROUP BY + aliases, dialect note:** PostgreSQL allows referencing SELECT aliases in GROUP BY as a non-standard extension (e.g. `GROUP BY mth` where `mth` is a SELECT alias). This is **not universal**, MySQL/SQL Server support is inconsistent, and strict ANSI SQL doesn't guarantee it. Since queries may need to run on either MySQL or Postgres syntax depending on the target engine, the safer, portable habit is to repeat the full expression in GROUP BY rather than relying on the alias, even where the current dialect happens to allow it:
```sql
-- Fragile, Postgres-only
SELECT EXTRACT(MONTH FROM submit_date) AS mth, product_id AS product, ROUND(AVG(stars), 2) AS avg_stars
FROM reviews
GROUP BY mth, product;

-- Portable across dialects
SELECT EXTRACT(MONTH FROM submit_date) AS mth, product_id AS product, ROUND(AVG(stars), 2) AS avg_stars
FROM reviews
GROUP BY EXTRACT(MONTH FROM submit_date), product_id;
```

**Two-level aggregation ("histogram" pattern):** a distribution or histogram question isn't a special SQL feature, it's just GROUP BY applied twice. Step 1: compute a per-entity number via GROUP BY + aggregate. Step 2: wrap step 1 in a CTE, then GROUP BY the resulting number itself, counting how many entities landed on each value:
```sql
WITH employee_query_counts AS (
    SELECT employees.employee_id, COUNT(DISTINCT queries.query_id) AS unique_queries
    FROM employees
    LEFT JOIN queries
      ON employees.employee_id = queries.employee_id
      AND queries.query_starttime >= '2023-07-01' AND queries.query_starttime < '2023-10-01'
    GROUP BY employees.employee_id
)
SELECT unique_queries, COUNT(employee_id) AS employee_count
FROM employee_query_counts
GROUP BY unique_queries
ORDER BY unique_queries;
```
Recognize this pattern whenever a question asks for a distribution, a breakdown by count-of-something, or explicitly says "histogram." Translate unfamiliar terminology into "what per-entity number, then group by that number."

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
- Can reference SELECT aliases (unlike WHERE/HAVING), since ORDER BY runs after SELECT
- Multiple conditions: comma-separated, evaluated left to right
- Use it as a standing habit even when not strictly required by a question, to keep the syntax and clause ordering from becoming a lookup-every-time item

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

### ROUND vs TRUNCATE
```sql
ROUND(x, 2)      -- rounds to the nearest value at 2 decimal places
TRUNCATE(x, 2)   -- MySQL: chops off digits past 2 decimal places, no rounding
TRUNC(x, 2)      -- Postgres equivalent of TRUNCATE
```
- **ROUND**: standard across SQLite/Postgres/MySQL/SQL Server, rounds to the nearest value (round-half-up in most engines; some dialects/numeric types use round-half-to-even, "banker's rounding"). Use for standard reporting/financial metrics where the closest mathematical value is wanted, e.g. average star ratings, average prices. Rounding inside HAVING can mask small differences, check raw values first if a HAVING filter behaves unexpectedly.
- **TRUNCATE / TRUNC**: chops off digits past the specified decimal place entirely, no rounding logic, always moves toward zero regardless of how large the trailing digits are. Use when business logic prohibits partial credit or progression, e.g. completed years of age, payout thresholds, tier limits that require a full threshold before advancing.
- Don't default to ROUND when the question implies a floor/threshold semantic, and don't reach for TRUNCATE on something like an average rating where the closest value is actually wanted, that's ROUND's job.

### ROUND's Two-Argument Postgres Error (a hard error, distinct from truncation)
```
function round(double precision, integer) does not exist
```
[FACT] In PostgreSQL, `ROUND(value, decimal_places)`, the two-argument form, only exists for the `numeric` type. There's no `round(double precision, integer)` overload. This happens when a division or other expression fed into `ROUND` resolves to `double precision`/float instead of `numeric`.

**Fix:** cast to numeric before it reaches `ROUND`:
```sql
ROUND((SUM(a) / SUM(b))::numeric, 1)
```

This is a **different problem from integer division truncation** (below): truncation gives a silently wrong number with no error; this gives a hard error and no result at all. The same `::numeric` cast can fix both if placed correctly, but they're distinct failure modes worth telling apart. Dialect-specific: MySQL's `ROUND` accepts floats/doubles directly with no such restriction, this is a Postgres-only quirk, don't over-apply "always cast before ROUND" as a universal SQL law, it's "cast before ROUND specifically in Postgres if the value might be double precision."

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

### Conditional Running Balance (signed SUM+CASE)
Instead of flagging 1/0, flag with the signed value itself to compute a net balance in one pass, no join needed:
```sql
SELECT account_id,
    SUM(CASE 
        WHEN transaction_type = 'Deposit' THEN amount
        WHEN transaction_type = 'Withdrawal' THEN -amount
        ELSE 0
    END) AS final_balance
FROM transactions
GROUP BY account_id;
```
Beats splitting into two CTEs (one per category) and JOINing them: single table scan instead of multiple, and GROUP BY naturally includes every entity with ANY matching row, avoiding the INNER-JOIN-drops-rows bug entirely (no join to have the bug in). Always include an explicit `ELSE` (e.g. `ELSE 0`) rather than relying on `ELSE -amount` to catch "everything else" — if a third category could exist in the data, that silently miscounts unexpected values instead of ignoring them. Use `SELECT DISTINCT` on the category column first if unsure how many categories actually exist.

### Weighted Mean
```sql
SELECT ROUND(SUM(order_occurrences * item_count)::numeric / SUM(order_occurrences), 1) AS mean
FROM items_per_order;
```
E.g. computing a mean from pre-aggregated/compressed data where each row represents multiple occurrences. `SUM(weight * value) / SUM(weight)`, single GROUP BY pass, cast for decimal division (see Integer Division Truncation and Cast Timing below).

### COUNT(*) vs COUNT(column)
- `COUNT(*)` counts all rows, regardless of NULLs
- `COUNT(column)` counts only non-NULL values in that column
- Only identical if the column can never be NULL
- Default to `COUNT(*)` unless specifically counting non-null occurrences of one column; `COUNT(column)` silently undercounts if that column can contain NULLs

### COUNT(DISTINCT column)
Counts distinct non-NULL values only. Avoids double-counting duplicate rows for the same entity (e.g. multiple log rows for the same query_id), and naturally gives 0 for an entity with no matching rows at all, e.g. after a LEFT JOIN with no match.

### COUNT(CASE...) vs SUM(CASE...) — a silent trap
If the CASE has an `ELSE` that returns a real value (e.g. `ELSE 0`), **every** row produces a non-NULL result regardless of whether the condition matched. So:
```sql
-- WRONG: silently returns the TOTAL ROW COUNT, not the count of matches
COUNT(CASE WHEN event_type = 'click' THEN 1 ELSE 0 END)
```
No error, just a wrong number, since COUNT counts non-NULLs and both branches of the CASE are non-NULL.

Two correct patterns:
```sql
-- (1) SUM the flags — correct WITH an ELSE present
SUM(CASE WHEN event_type = 'click' THEN 1 ELSE 0 END)

-- (2) COUNT with no ELSE — non-matches implicitly return NULL, COUNT skips them
COUNT(CASE WHEN event_type = 'click' THEN 1 END)
```
**Rule:** CASE with an ELSE returning a value → use SUM. CASE with no ELSE (implicit NULL fallthrough) → COUNT works. Never mix the two (COUNT with an ELSE that returns 0).

### Integer Division Truncation
Dividing an integer by an integer truncates to an integer in most dialects (`3 / 7` = `0`, not `0.428...`). `SUM(CASE WHEN...THEN 1 ELSE 0 END)` produces an integer, so dividing two such SUMs truncates silently, no error:
```sql
-- Truncates silently if both SUMs are integers
100 * SUM(CASE WHEN event_type = 'click' THEN 1 ELSE 0 END)
    / SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END)
```
Fix by promoting to numeric/decimal **before** the division completes, via any one of:
```sql
-- (1) Decimal literal outside — the .0 promotes the whole expression
100.0 * SUM(...) / SUM(...)

-- (2) Decimal literal inside the CASE — makes the SUM itself numeric
SUM(CASE WHEN event_type = 'click' THEN 1.0 ELSE 0 END) / SUM(...)

-- (3) Explicit cast at the division point
SUM(...)::NUMERIC / SUM(...)                    -- Postgres shorthand
CAST(SUM(...) AS NUMERIC) / SUM(...)             -- standard
```
Only **one** coercion point is needed; stacking multiple isn't wrong but signals uncertainty about which fix is actually load-bearing. Casting at the division point is more self-documenting for a reader who hasn't hit this bug before, since the fix sits visually next to the actual risk. Don't assume a reader will recognize a bare `1.0` literal as a truncation fix without already knowing this specific gotcha — write for the reader who hasn't hit it yet, not just for someone with identical background.

See also ROUND's Two-Argument Postgres Error above, a related but distinct hard-error version of the same underlying "need numeric type" issue.

### Cast Timing: Overflow vs Truncation
Casting **late** (only at the final division or ROUND) protects only that specific operation. Casting **early**, at the column itself, before an intermediate operation like multiplication, protects every downstream step including that operation:
```sql
-- Only fixes division truncation
SUM(a * b)::numeric / SUM(c)

-- Also protects the multiplication a*b from integer overflow
SUM(a * b::numeric) / SUM(c)
```
The second form matters if `a * b` could exceed standard integer range (roughly ±2.1 billion), since the multiplication itself becomes decimal arithmetic instead of plain integer arithmetic, avoiding a silent overflow that a late cast wouldn't catch (the late cast only acts after the multiplication has already happened). `NUMERIC` and `DECIMAL` are aliases in Postgres, no difference between them.

**Rule of thumb:** cast at the earliest point in the expression where precision or range could matter, not just wherever the current error or wrong-number symptom happens to surface. It's more defensively correct and costs nothing extra.

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

### EXTRACT(DAY) is NOT Elapsed-Day Math — a common trap
`EXTRACT(DAY FROM date_col)` gives the day-of-month digit (1–31), **not** a running day count, it resets every month. Subtracting two `EXTRACT(DAY)` values only works if both dates fall in the same month, otherwise the arithmetic is meaningless:
```
Feb 1 minus Jan 30: EXTRACT(DAY) gives 1 - 30 = -29, not the real 2-day gap
```
`EXTRACT(YEAR)`/`EXTRACT(MONTH)` are fine as WHERE filters (checking which year/month a date falls in), but do not use `EXTRACT(DAY)` subtraction to compute elapsed time between two dates. Use `DATEDIFF` or direct date subtraction instead, those operate on the actual underlying date value, not an extracted piece of it.

### ::date Cast (Postgres shorthand for CAST(col AS DATE))
Strips the time component from a `TIMESTAMP`, leaving just the calendar date. Needed when comparing "did X happen exactly N days after Y" using timestamp columns, since raw subtraction can carry a fractional-day remainder from the time-of-day portion (e.g. signup at 11pm, confirmation at 1am the next day, is only ~2 hours apart, not a clean 1-day gap), which can throw off an exact day-count match. Cast both sides to date first when the question is about calendar-day differences, not exact elapsed time.

### YEAR() / MONTH()
- **MySQL only**: extracts year/month as an integer.
- **PostgreSQL/ANSI**: `EXTRACT(YEAR FROM date_col)` / `EXTRACT(MONTH FROM date_col)`.
- **SQLite**: `strftime('%Y', date_col)` / `strftime('%m', date_col)`.

Check which SQL dialect is in use before reaching for `DATEDIFF`/`YEAR` (MySQL) vs `EXTRACT` (Postgres), since syntax varies by target engine.

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

### COALESCE(value, fallback)
Returns the first non-NULL argument in the list:
```sql
COALESCE(deposit.deposit_total, 0) - COALESCE(withdrawal.withdrawal_total, 0)
```
Use to substitute a default when a value could be NULL from a join's unmatched side (e.g. after a FULL OUTER JOIN). Without it, `NULL - 5` or `5 - NULL` evaluates to NULL for the whole expression, silently losing an otherwise fully-knowable row.

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
- Also the standard way to build two-level aggregation (the histogram pattern): first CTE computes the per-entity number, outer query groups by that number
- Watch out: chaining two CTEs and then INNER JOINing them (e.g. one CTE per category) silently drops entities that only appear in one CTE. Check whether a single-pass GROUP BY + CASE avoids this risk entirely before reaching for the two-CTE-plus-JOIN pattern

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
- **Avoid subqueries entirely when GROUP BY + aggregate answers the question** (see Recurring Mistake Patterns below)

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
GROUP BY the columns that define "duplicate", then HAVING COUNT(*) > 1. **Don't reach for a self-join here** — it creates unnecessary row-multiplication and is easy to get wrong. GROUP BY + HAVING COUNT(*) > 1 is simpler, faster, and directly matches the actual question ("does more than one of this combination exist").

Note: this finds and counts duplicate *groups*, but collapses rows. If the actual need is to see the individual duplicate rows themselves, not just confirm duplicates exist, that needs a window function (`ROW_NUMBER() OVER (PARTITION BY <duplicate-defining columns>)`, then filter `WHERE rn > 1`) or a self-join back to the grouped result, since row-level detail is required there.

### Compare rows within the same table by role
```sql
SELECT emp.employee_id, emp.name
FROM employee AS emp
LEFT JOIN employee AS mgr ON emp.manager_id = mgr.employee_id
WHERE emp.salary > mgr.salary;
```
Self-join with symmetric role-based aliases (see Self-Joins section above). Join condition maps one role's foreign key to the other role's primary key, then filter/compare across the two aliases in WHERE.

### Net balance across categories
```sql
SELECT account_id,
    SUM(CASE 
        WHEN transaction_type = 'Deposit' THEN amount
        WHEN transaction_type = 'Withdrawal' THEN -amount
        ELSE 0
    END) AS final_balance
FROM transactions
GROUP BY account_id;
```
Signed SUM+CASE in a single GROUP BY pass (see Conditional Running Balance above). Avoid the two-CTE-plus-JOIN approach, it risks silently dropping entities that only have one category of row.

### Conditional breakdown by category
```sql
SELECT
    date,
    SUM(CASE WHEN device_type = 'laptop' THEN 1 ELSE 0 END) AS laptop_views,
    SUM(CASE WHEN device_type IN ('tablet', 'phone') THEN 1 ELSE 0 END) AS mobile_views
FROM viewership
GROUP BY date;
```

### Rate/ratio between two conditional counts
```sql
SELECT app_id,
    ROUND(
        100.0 * SUM(CASE WHEN event_type = 'click' THEN 1 ELSE 0 END)
              / SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END)
    , 2) AS ctr
FROM events
WHERE event_date >= '2022-01-01' AND event_date < '2023-01-01'
GROUP BY app_id;
```
E.g. click-through rate = clicks/impressions. `SUM(CASE WHEN...)` for numerator and denominator separately, watch for integer division truncation (see above), only one coercion point needed to fix it.

### Weighted mean from compressed/summarized data
```sql
SELECT ROUND(SUM(order_occurrences * item_count)::numeric / SUM(order_occurrences), 1) AS mean
FROM items_per_order;
```
See Weighted Mean above. Single GROUP BY pass, cast at the earliest point (see Cast Timing above) if overflow on the multiplication is a realistic concern.

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

### Exact N-day gap between two related events
E.g. confirmation exactly 1 day after signup. Join the two events (e.g. via a shared id), use `DATEDIFF` or date subtraction on the actual date columns, never `EXTRACT(DAY)` subtraction (see the trap above). Cast to `::date` first if columns are timestamps and the question means calendar days, not exact elapsed time.

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

### Distribution/histogram of a per-entity count
See Two-Level Aggregation under GROUP BY above. Not a special SQL feature, just GROUP BY twice, once to build the per-entity number (typically in a CTE), once to group by that number.

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

## Recurring Mistake Patterns to Watch For

**Reaching for a subquery, self-join, or multi-CTE-plus-JOIN by default when the real need is a single-pass GROUP BY + aggregate (possibly with CASE).**

Test before writing the query: am I comparing across genuinely separate/unrelated data, or do I just need a value computed within a group I already have?

Deeper test: does the output need to stay at row-level granularity, or collapse to one row per group?
- If row-level detail must be kept alongside a group-level or whole-table aggregate, GROUP BY alone cannot do it — need a subquery/CTE+JOIN or a window function.
- Finding duplicates specifically is almost always `GROUP BY + HAVING COUNT(*) > 1`, not a self-join, but remember GROUP BY collapses rows, so it only confirms/counts duplicates, it doesn't show them at row level.
- A distribution/histogram question is two-level GROUP BY, not a special feature. Don't be thrown by unfamiliar terminology, translate it into "what per-entity number, then group by that number."
- Splitting a category comparison into separate CTEs per category then INNER JOINing them is a common instinct but risks dropping entities that only appear in one category; check whether a single-pass signed SUM+CASE answers the question instead.

**Defaulting to LEFT JOIN out of habit rather than deliberately choosing JOIN type.**

"It's worked so far" isn't evidence the habit is safe, it just means the practice data hasn't exposed the gap yet. Ask which JOIN type reflects what's actually known or expected about the data before writing it.

**Filtering the right table's column in WHERE instead of ON, when a LEFT JOIN must preserve unmatched left rows.** See the LEFT JOIN section above.

**Using COUNT(CASE...) with an ELSE clause when SUM(CASE...) is needed.** See the COUNT vs SUM trap above.

**Forgetting integer division truncates and needs an explicit numeric coercion**, and separately, **hitting Postgres's `ROUND(double precision, integer) does not exist` error and not recognizing it as a numeric-cast issue distinct from truncation.** Two related but different failure modes, see above.

**Casting only at the final operation instead of at the earliest point precision/range could matter.** See Cast Timing above.

**Using EXTRACT(DAY) subtraction instead of DATEDIFF/date subtraction for elapsed-time math.** See the trap above.

**Assuming a reader will infer a fix's purpose without it being visually near the actual risk point** (e.g. a bare `1.0` literal placed far from the division it's fixing). Write for the reader who hasn't hit the specific gotcha yet, not just for someone with identical background/experience.

**Before asking outside for syntax help, check this cheat sheet first.** Several lookups have turned out to already be answered here.

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
- Table aliases are most useful when referencing the same table twice in one query (e.g. correlated subqueries, self-joins), not just for saving keystrokes
- Always spell out `INNER JOIN` rather than bare `JOIN`, even though they're identical, as a forcing function for deliberate JOIN-type choice
- Prefer `ON` over `USING` for JOINs, even when column names match exactly
- ALWAYS alias BOTH sides of a self-join symmetrically with role-based names, never leave one side unaliased
- Always explicitly alias aggregate function outputs, never rely on implicit default naming
- Cast to numeric/decimal at the earliest point in an expression where precision or range could matter, not just wherever the current symptom surfaces
- Use ORDER BY as a standing habit even when not strictly required, to keep it from becoming a lookup-every-time item
- Write for the reader who hasn't already internalized your reasoning, not just for someone with identical background/experience
