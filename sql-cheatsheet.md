# SQL Investigation Cheat Sheet

## Query Execution Order
SQL does NOT execute top-to-bottom like JavaScript. Actual order:
```
FROM → JOIN → WHERE → GROUP BY → (aggregates computed) → HAVING → SELECT (window functions computed here) → ORDER BY → LIMIT
```
This explains why:
- Aliases defined in SELECT cannot be used in WHERE or HAVING
- Aggregate functions (COUNT, SUM) cannot be used in WHERE
- ORDER BY can reference aliases (it runs after SELECT)
- Window function results (ROW_NUMBER, RANK, LAG, etc) can't be filtered in the same query's WHERE or HAVING, since those clauses run before window functions are computed. Always wrap in a subquery/CTE and filter in the outer layer.
- **GROUP BY + aggregates and window functions CAN combine in a single query, no CTE required for this reason alone.** Window functions run in the SELECT phase, after GROUP BY has already collapsed rows and resolved aggregates. So `ROW_NUMBER() OVER (... ORDER BY SUM(spend) DESC)` alongside `GROUP BY category, product` in the same SELECT is valid: by the time the window function runs, `SUM(spend)` is already a finished per-group value, not a raw per-row one. A CTE is often still clearer to read (one step per layer), but it isn't functionally required just to sequence aggregation before windowing.

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

This is a **per-column rule, not a column-count limit, and not "first column plain, rest aggregate."** It's per-column and order-independent: any number of columns are fine as long as each one individually is either the GROUP BY column or wrapped in an aggregate:
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

**GROUP BY silent group-fragmentation trap.** If a query fails full-GROUP-BY validation because a raw per-row expression (e.g. `cogs - total_sales`) is unaggregated in SELECT, adding that same expression to GROUP BY makes the query **valid syntax but usually wrong semantics**:
```sql
-- WRONG despite running without error: fragments groups, doesn't fix the real issue
SELECT manufacturer, COUNT(drug) AS drug_count, cogs - total_sales AS total_loss
FROM pharmacy_sales
WHERE cogs - total_sales > 0
GROUP BY manufacturer, total_loss   -- adding the raw expression here is the trap
ORDER BY total_loss DESC;

-- CORRECT: aggregate the expression itself instead of grouping by it
SELECT manufacturer, COUNT(drug) AS drug_count, SUM(cogs - total_sales) AS total_loss
FROM pharmacy_sales
WHERE cogs - total_sales > 0
GROUP BY manufacturer
ORDER BY total_loss DESC;
```
If the raw expression is near-unique per row, `GROUP BY manufacturer, total_loss` doesn't give one row per manufacturer, it gives close to one row per manufacturer-per-item, since each item's raw value differs. Any aggregate alongside it (like `COUNT`) then computes over these tiny fragmented buckets, coming out as mostly 1s, instead of the real per-manufacturer number. No error is thrown, the query just silently answers a different, wrong question. **This is more dangerous than the hard-rejection version of the rule**, since nothing signals the mistake except manually checking whether the output actually makes sense. The correct fix is always to aggregate the expression (`SUM`, `COUNT`, etc), never to add it to GROUP BY as a workaround.

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

## Window Functions

**Mental model:** every aggregate function (`SUM`, `COUNT`, `AVG`, `MAX`, `MIN`) collapses rows down into one summary row per group, that's what GROUP BY does. Window functions borrow the same "bucket" idea, `PARTITION BY` instead of `GROUP BY`, but **never collapse anything**. Every row survives, and each row gets a computed value describing its relationship to its partition (its position within it, its rank, a neighboring row's value, a running total, etc).

Use a window function whenever row-level detail must be preserved *and* something needs to be computed relative to a group that row belongs to, exactly the situations GROUP BY structurally can't handle.

### Syntax anatomy
```sql
function_name() OVER (PARTITION BY grouping_column ORDER BY sort_column)
```
- **`PARTITION BY`**: which rows belong together (optional; omitted = the whole table is one partition)
- **`ORDER BY`** (inside `OVER`): the order rows are considered in *within* their partition. Only matters for functions that care about sequence (ranking, previous/next row, running totals)
- Window functions are computed in the SELECT phase, after WHERE/GROUP BY/HAVING have already run (see Execution Order above). This means their results **cannot be filtered in the same query's WHERE or HAVING**, since those clauses execute before the window function's output exists. Always wrap the windowed query in a subquery or CTE and filter in the outer layer.
- **Combines freely with GROUP BY in the same query, no CTE required just for sequencing.** Since window functions run after GROUP BY/aggregates are resolved, an aggregate expression can be referenced directly inside a window function's `OVER (...)` in the same SELECT, e.g. `ROW_NUMBER() OVER (PARTITION BY category ORDER BY SUM(spend) DESC)` alongside `GROUP BY category, product`. A CTE is still often clearer for readability, but it isn't functionally necessary purely to pre-aggregate before windowing.

### ROW_NUMBER, RANK, DENSE_RANK — the ranking family
```sql
ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY spend DESC)
RANK()       OVER (PARTITION BY user_id ORDER BY spend DESC)
DENSE_RANK() OVER (PARTITION BY user_id ORDER BY spend DESC)
```
The difference is entirely about how they treat ties. Given spend values `100, 90, 90, 80`:

| spend | ROW_NUMBER | RANK | DENSE_RANK |
|---|---|---|---|
| 100 | 1 | 1 | 1 |
| 90 | 2 | 2 | 2 |
| 90 | 3 | 2 | 2 |
| 80 | 4 | 4 | 3 |

- **`ROW_NUMBER`**: always unique (1, 2, 3, 4), ties broken arbitrarily by whichever row the engine processes first. Use when exactly one row per rank position is required, e.g. "the Nth row" — ties or not, you need a single row. Breaks the moment there's a tie at the boundary you're filtering on, regardless of table size, e.g. two tied highest salaries means `rn = 2` returns the second copy of the *highest* salary, not the true second-highest distinct value.
- **`RANK`**: ties share a rank, but the next rank *skips* ahead (2, 2, then 4). Mirrors a race: two tied for 2nd, nobody gets 3rd. Danger: if ties exist above your target position, the exact number you're filtering for may never appear in the output at all (e.g. a tie at position 55 means rank 56 might not exist, jumping straight to 58).
- **`DENSE_RANK`**: ties share a rank, no skipping (2, 2, 3). Guarantees every position number appears in the output regardless of ties above it, making it the safer choice for "find the Nth distinct value" questions.

This is the actual fix for the "Top N per group" ties problem flagged elsewhere in this sheet: `ORDER BY ... LIMIT N` arbitrarily picks one of the tied rows with no guaranteed stability. `RANK`/`DENSE_RANK` make the tie explicit in the output instead of hiding it.

### Finding the Nth row per group
```sql
SELECT user_id, spend, transaction_date
FROM (
    SELECT user_id, spend, transaction_date,
           ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY transaction_date ASC) AS rn
    FROM transactions
) numbered_transactions
WHERE rn = 3;
```
Numbers every user's transactions in date order without collapsing any rows; the outer query then filters to `rn = 3`, which by construction is each user's third transaction. Users with fewer than 3 transactions never produce an `rn = 3` row, so they're automatically excluded, no separate `HAVING COUNT >= 3` check needed, the filtering falls out of the numbering itself.

### LAG and LEAD — looking at neighboring rows
```sql
LAG(spend) OVER (PARTITION BY user_id ORDER BY transaction_date) AS previous_spend
LEAD(spend) OVER (PARTITION BY user_id ORDER BY transaction_date) AS next_spend
```
`LAG` pulls the value from the previous row in the ordered partition; `LEAD` pulls it from the next row. The first row's `LAG` (and the last row's `LEAD`) has nothing to reference and returns NULL, unless a default is supplied as a second argument.

This is the standard tool for "how did this compare to last time" questions, e.g. spend change transaction-to-transaction. It's a genuinely different comparison from the row-vs-group-average CTE pattern below: that pattern measures distance from a *fixed group baseline*, `LAG`/`LEAD` measure distance from the *adjacent row specifically*, which is awkward to express without a window function at all.

### Aggregates as window functions (running totals, group totals without collapsing)
```sql
-- Running cumulative sum per user (order matters for "running")
SUM(spend) OVER (PARTITION BY user_id ORDER BY transaction_date) AS running_total

-- Full per-user total repeated on every row (no ORDER BY inside OVER)
SUM(spend) OVER (PARTITION BY user_id) AS user_total_spend
```
The same aggregate functions already covered can run in "window mode." With `ORDER BY` inside `OVER`, the aggregate becomes cumulative (a running total). Without it, the aggregate computes once per partition and repeats that value on every row in the partition, useful for showing each row alongside a group total without needing the CTE+JOIN pattern from Row-Level Value vs Per-Group Baseline below, this does it in one pass.

### Frame Clauses: Controlling How Much of the Partition Each Row Sees
`PARTITION BY`/`ORDER BY` define which rows exist in a partition and their order. They don't by default control *how much* of that ordered partition each row's calculation actually looks at, that's what an explicit frame clause is for, needed for genuine rolling/moving calculations (e.g. "3-day rolling average") rather than a full running total.

```sql
-- 3-calendar-day rolling average (today + 2 preceding calendar days)
AVG(tweet_count) OVER (
    PARTITION BY user_id
    ORDER BY tweet_date
    RANGE BETWEEN INTERVAL '2' DAY PRECEDING AND CURRENT ROW
)
```
- **`BETWEEN ... AND ...`**: the sliding window's boundaries, relative to the current row
- **`INTERVAL '2' DAY PRECEDING`**: window start, 2 days before the current row's date
- **`CURRENT ROW`**: window end, the row itself
- **`RANGE`**: boundary measured by actual *value* distance (here, calendar days), not row count. Correctly includes "everything within 2 calendar days" even across date gaps in the data, a user with a missing day still gets the right calendar window, not a fixed row count that could span more or less real time than intended.

**`RANGE` vs `ROWS`:** `ROWS BETWEEN 2 PRECEDING AND CURRENT ROW` measures by literal row count instead, "the 2 rows before this one," regardless of what dates those rows actually fall on. If the data has gaps (missing dates), `ROWS` and `RANGE` can give different results for what's supposed to be the same "3-day" window. Use `RANGE` with an `INTERVAL` when the requirement is genuinely calendar-based and gaps are possible; `ROWS` is more broadly supported across dialects and fine when one row per period is guaranteed with no gaps.

**Default frame when omitted:** if `ORDER BY` is present inside `OVER` but no explicit frame clause is given, most engines default to `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, i.e. "everything from the start of the partition through the current row." This is why a plain running total (`SUM(x) OVER (PARTITION BY ... ORDER BY ...)`, no frame clause written) already works as shown above, that behavior is the implicit default frame, not something requiring extra syntax. An explicit frame clause is only needed to narrow that default window, e.g. to a fixed number of preceding days/rows instead of the whole partition history.

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

**What goes inside THEN determines what's being aggregated.** `THEN 1` counts matching *rows* (occurrences). `THEN <column>` sums that column's actual *value* across matching rows. These give genuinely different numbers, e.g. "how many send events happened" (THEN 1) vs "how much total time was spent on send events" (THEN time_spent). Check the question's phrasing: "how many"/"count of"/"number of" → THEN 1; "total"/"sum of"/"amount of [quantity]" → THEN the actual column.

### FILTER (WHERE...) — Postgres alternative to SUM(CASE WHEN...)
```sql
-- Equivalent to SUM(CASE WHEN activity_type = 'send' THEN time_spent ELSE 0 END)
SUM(time_spent) FILTER (WHERE activity_type = 'send') AS send_time
```
[FACT] Functionally equivalent to `SUM(CASE WHEN condition THEN column ELSE 0 END)`, just more explicit: "only feed rows matching this condition into the aggregate," stated directly rather than simulated through conditional zeroing. **Dialect gap: PostgreSQL supports `FILTER` natively; MySQL and SQL Server do not support it at all** (syntax error). `SUM(CASE WHEN...)` remains the portable choice across dialects; `FILTER` is a cleaner Postgres-specific shorthand when the target engine is known to be Postgres.

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
- Also the standard way to build two-level aggregation (the histogram pattern), or to isolate a window function so its result can be filtered (see Window Functions above)
- Watch out: chaining two CTEs and then INNER JOINing them (e.g. one CTE per category) silently drops entities that only appear in one CTE. Check whether a single-pass GROUP BY + CASE avoids this risk entirely before reaching for the two-CTE-plus-JOIN pattern
- Not strictly required to sequence GROUP BY before a window function in the same query, since window functions naturally run after GROUP BY resolves (see Execution Order above); still often used for readability even when not functionally necessary

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

### Sum a raw per-row expression per group
```sql
SELECT manufacturer, COUNT(drug) AS drug_count, SUM(cogs - total_sales) AS total_loss
FROM pharmacy_sales
WHERE cogs - total_sales > 0
GROUP BY manufacturer
ORDER BY total_loss DESC;
```
E.g. total loss per manufacturer where loss = cogs - total_sales per drug. Filter rows first if needed, then SUM the raw expression grouped by the entity, alongside COUNT for a per-group count. **Do not add the raw expression itself to GROUP BY** to satisfy the full-GROUP-BY rule, that silently fragments groups (see GROUP BY silent group-fragmentation trap above).

### Conditional breakdown by category, including time/quantity totals not just counts
```sql
SELECT
    age.age_bucket,
    SUM(CASE WHEN activities.activity_type = 'send' THEN activities.time_spent ELSE 0 END) AS send_time,
    SUM(CASE WHEN activities.activity_type = 'open' THEN activities.time_spent ELSE 0 END) AS open_time
FROM activities
INNER JOIN age_breakdown AS age ON activities.user_id = age.user_id
WHERE activities.activity_type IN ('send', 'open')
GROUP BY age.age_bucket;
```
Same SUM+CASE shape as a simple category breakdown, but summing an actual quantity column instead of counting 1/0 flags, see "what goes inside THEN" note above. When the relevant dimension (e.g. age bucket) lives in a different table than the raw event data, join first, then group by the target dimension in the same query.

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
Example: each login's distance from that user's average login date. Needed whenever the output must stay at row-level granularity while comparing against a group-level aggregate — GROUP BY alone collapses rows and can't do this, so use a CTE/subquery to compute the per-group baseline, then JOIN back to the row-level table. (A windowed aggregate, e.g. `AVG(...) OVER (PARTITION BY user_id)`, can also solve this shape in one pass, see Window Functions above.)

**Verification trick:** deviations from an average should sum to approximately 0 (mathematical property of the mean). Sum the deviation column per group as a sanity check on the average calculation; small non-zero sums (e.g. off by 1) are expected rounding/truncation error, not a bug.

### Distribution/histogram of a per-entity count
See Two-Level Aggregation under GROUP BY above. Not a special SQL feature, just GROUP BY twice, once to build the per-entity number (typically in a CTE), once to group by that number.

### Nth row per group, or first/last row per group with full row data
```sql
SELECT user_id, spend, transaction_date
FROM (
    SELECT user_id, spend, transaction_date,
           ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY transaction_date ASC) AS rn
    FROM transactions
) numbered_transactions
WHERE rn = 3;
```
GROUP BY collapses rows and loses access to other columns, so this needs a window function: `ROW_NUMBER() OVER (PARTITION BY group_col ORDER BY date_col ASC/DESC)`, then filter on `rn` in an outer query. See Window Functions above.

### Top N per group, using aggregated totals, with ties
```sql
SELECT category, product, total_spend
FROM (
    SELECT category, product, SUM(spend) AS total_spend,
           ROW_NUMBER() OVER (PARTITION BY category ORDER BY SUM(spend) DESC) AS rnk
    FROM product_spend
    WHERE transaction_date >= '2022-01-01' AND transaction_date < '2023-01-01'
    GROUP BY category, product
) ranked
WHERE rnk IN (1, 2);
```
Top N *by an aggregated total* (e.g. total spend per product, not raw per-row spend) needs the aggregation and the ranking together: GROUP BY the entity being ranked (here, product within category) first so duplicate rows for the same entity are combined, then rank by that aggregate. GROUP BY and the window function can coexist in one query (see Execution Order above), a separate CTE purely to sequence them isn't required, though it can aid readability. Use `IN (1, 2)` rather than `= 1 OR rnk = 2` to select multiple rank positions safely, see the IN vs OR precedence note below.

### Top N per group ranking, with ties (simple, non-aggregated case)
```sql
SELECT sender_id, COUNT(*) AS message_count
FROM messages
GROUP BY sender_id
ORDER BY message_count DESC
LIMIT 2;
```
`ORDER BY ... LIMIT N` only works safely if no ties are expected in the data. If ties are possible and must be handled correctly, use `RANK()` or `DENSE_RANK()` instead (see Window Functions above) — `LIMIT` arbitrarily picks one of the tied rows with no guaranteed stability, while `RANK`/`DENSE_RANK` make the tie explicit in the output.

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

**Real case study — a date filter silently bypassed:**
```sql
-- BROKEN: the date range only applies to the rn = 1 branch
WHERE transaction_date >= '2022-01-01' AND transaction_date < '2023-01-01' AND rnk = 1 OR rnk = 2

-- Actually parses as:
WHERE (transaction_date >= '2022-01-01' AND transaction_date < '2023-01-01' AND rnk = 1)
   OR (rnk = 2)
```
Any row with `rnk = 2`, from **any date**, passes the WHERE clause, the date filter is completely bypassed for that branch. Two fixes, both eliminate the bare `OR`:
```sql
-- Fix 1: brackets
WHERE transaction_date >= '2022-01-01' AND transaction_date < '2023-01-01' AND (rnk = 1 OR rnk = 2)

-- Fix 2: IN, when the OR'd conditions are all equality checks on the same column
WHERE transaction_date >= '2022-01-01' AND transaction_date < '2023-01-01' AND rnk IN (1, 2)
```

**IN vs the AND/OR precedence trap — what IN actually replaces.** `column IN (val1, val2, ...)` is a single self-contained condition, equivalent to `column = val1 OR column = val2 OR ...` collapsed into one. It combines freely with `AND`, with no precedence risk, e.g. `date >= x AND date < y AND status IN ('open', 'pending')` needs no brackets. **This is not because `IN` has a special relationship with `AND`.** The precedence danger is specifically about a literal `OR` sitting in the same WHERE clause as an `AND`; `IN` sidesteps it only because it removes the `OR` from the query entirely by expressing the "any of these values" logic as one condition instead of several OR'd ones. When several OR'd equality checks against the *same column* are mixed with AND, prefer `IN` over manual OR + brackets, both work, but `IN` removes the ambiguity source rather than just working around it.

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
- When a raw per-row expression triggers a full-GROUP-BY error, aggregate the expression, never add it to GROUP BY as a workaround
- Prefer `IN (val1, val2, ...)` over multiple OR'd equality checks on the same column, especially when combined with AND elsewhere in the WHERE clause, it removes the AND/OR precedence risk rather than requiring careful bracketing
- Write for the reader who hasn't already internalized your reasoning, not just for someone with identical background/experience
