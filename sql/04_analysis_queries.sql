/* =============================================================================
   04_analysis_queries.sql  —  ad-hoc analysis and reconciliation queries
   The questions managers asked of the dashboards, answered in SQL.
   Useful for checking Power BI numbers and as SQL interview practice
   (joins, CTEs, window functions, range joins, anti-joins).
   ============================================================================= */
USE EngineeringActivity;
GO

/* Q1. Current activity load by state, with share of total (window aggregate) */
SELECT  s.state_order,
        f.state,
        COUNT(DISTINCT f.activity_id)                                         AS activities,
        CAST(100.0 * COUNT(DISTINCT f.activity_id)
             / SUM(COUNT(DISTINCT f.activity_id)) OVER () AS DECIMAL(5,1))    AS pct_of_total
FROM dbo.vw_fact_activity AS f
JOIN dbo.dim_state        AS s ON s.state = f.state
WHERE f.is_open = 1
GROUP BY s.state_order, f.state
ORDER BY s.state_order;

/* Q2. Open activities by unit and function (multi-table join + conditional aggregation) */
SELECT  u.unit_name,
        fn.function_name,
        COUNT(DISTINCT a.activity_id)                                AS open_activities,
        SUM(CASE WHEN a.state = 'Active' THEN 1 ELSE 0 END)          AS active,
        SUM(CAST(a.is_overdue AS INT))                               AS overdue
FROM dbo.vw_fact_activity AS a
JOIN dbo.dim_unit         AS u  ON u.unit_id      = a.unit_id
JOIN dbo.dim_function     AS fn ON fn.function_id = a.function_id
WHERE a.is_open = 1
GROUP BY u.unit_name, fn.function_name
ORDER BY u.unit_name, open_activities DESC;

/* Q3. Top 3 most loaded engineers in each function (ROW_NUMBER inside a CTE) */
WITH ranked AS (
    SELECT  function_name, engineer_name, in_flight_activities, capacity_activities, load_ratio,
            ROW_NUMBER() OVER (PARTITION BY function_name
                               ORDER BY in_flight_activities DESC, load_ratio DESC) AS rn
    FROM dbo.vw_engineer_load
)
SELECT function_name, engineer_name, in_flight_activities, capacity_activities, load_ratio
FROM ranked
WHERE rn <= 3
ORDER BY function_name, rn;

/* Q4. Rebalancing candidates: overloaded and under-utilised engineers in the same function */
WITH lb AS (SELECT * FROM dbo.vw_engineer_load)
SELECT  o.function_name,
        o.engineer_name          AS overloaded_engineer,
        o.in_flight_activities   AS overloaded_count,
        u.engineer_name          AS available_engineer,
        u.in_flight_activities   AS available_count
FROM lb AS o
JOIN lb AS u
  ON u.function_name = o.function_name
 AND u.load_band     = 'Under-utilised'
WHERE o.load_band = 'Overloaded'
ORDER BY o.function_name, o.in_flight_activities DESC;

/* Q5. Engineers with no in-flight work (anti-join with NOT EXISTS) */
SELECT e.engineer_id, e.engineer_name, e.[role]
FROM dbo.dim_engineer AS e
WHERE e.is_active = 1
  AND NOT EXISTS (SELECT 1
                  FROM dbo.vw_fact_activity AS a
                  WHERE a.activity_engineer_id = e.engineer_id
                    AND a.is_in_flight = 1);

/* Q6. Average days spent in each state, by function (state history + DATEDIFF) */
SELECT  fn.function_name,
        h.state,
        COUNT(*)                                                         AS completed_stays,
        AVG(DATEDIFF(DAY, h.valid_from, h.valid_to) * 1.0)               AS avg_days_in_state
FROM dbo.activity_state_history AS h
JOIN dbo.fact_activity          AS a  ON a.activity_id  = h.activity_id
JOIN dbo.dim_function           AS fn ON fn.function_id = a.function_id
WHERE h.valid_to IS NOT NULL          -- only finished stays
GROUP BY fn.function_name, h.state
ORDER BY fn.function_name, MIN(h.valid_from);

/* Q7. The same transition data with LEAD: what state did each activity move to next? */
SELECT TOP (20)
        activity_id,
        state                                                            AS from_state,
        LEAD(state) OVER (PARTITION BY activity_id ORDER BY valid_from)  AS to_state,
        valid_from,
        valid_to
FROM dbo.activity_state_history
ORDER BY activity_id, valid_from;

/* Q8. Monthly closures with 3-month moving average (window frame) */
WITH monthly AS (
    SELECT EOMONTH(closed_date) AS month_end, COUNT(*) AS closed_activities
    FROM dbo.fact_activity
    WHERE state = 'Closed'
    GROUP BY EOMONTH(closed_date)
)
SELECT  month_end,
        closed_activities,
        LAG(closed_activities) OVER (ORDER BY month_end)                               AS prev_month,
        CAST(AVG(closed_activities * 1.0) OVER (ORDER BY month_end
             ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS DECIMAL(6,1))                AS moving_avg_3m
FROM monthly
ORDER BY month_end;

/* Q9. Overdue open activities, bucketed by how late they are */
SELECT  CASE WHEN days_overdue <= 14 THEN '1. Up to 2 weeks'
             WHEN days_overdue <= 42 THEN '2. 2-6 weeks'
             ELSE '3. Over 6 weeks' END          AS overdue_bucket,
        COUNT(*)                                  AS activities
FROM dbo.vw_fact_activity
WHERE is_overdue = 1
GROUP BY CASE WHEN days_overdue <= 14 THEN '1. Up to 2 weeks'
              WHEN days_overdue <= 42 THEN '2. 2-6 weeks'
              ELSE '3. Over 6 weeks' END
ORDER BY overdue_bucket;

/* Q10. Before/after comparison of escalations around a go-live date.
   Compares the escalation RATE (per 100 in-flight activities), not the raw count,
   so a smaller or larger portfolio does not distort the result. */
DECLARE @go_live DATE = '2025-10-01', @months INT = 6;

WITH periods AS (
    SELECT  m.month_end_date,
            m.escalations,
            m.in_flight_at_month_end,
            CASE WHEN m.month_end_date <  @go_live THEN 'Before' ELSE 'After' END AS period
    FROM dbo.vw_escalations_monthly AS m
    WHERE m.month_end_date >= DATEADD(MONTH, -@months, @go_live)
      AND m.month_end_date <  DATEADD(MONTH,  @months, @go_live)
)
SELECT  period,
        COUNT(*)                                                         AS months,
        SUM(escalations)                                                 AS escalations,
        AVG(in_flight_at_month_end * 1.0)                                AS avg_in_flight,
        CAST(100.0 * SUM(escalations) / NULLIF(SUM(in_flight_at_month_end), 0) AS DECIMAL(6,2))
                                                                         AS escalations_per_100_in_flight
FROM periods
GROUP BY period;

/* Q11. Reconciliation: dashboard total must equal the sum of its parts.
   If the activity count by state does not add up to the distinct total, a join is fanning out. */
SELECT  (SELECT COUNT(DISTINCT activity_id) FROM dbo.vw_fact_activity WHERE is_open = 1)      AS distinct_open,
        (SELECT SUM(n) FROM (SELECT COUNT(DISTINCT activity_id) AS n
                             FROM dbo.vw_fact_activity WHERE is_open = 1 GROUP BY state) x) AS sum_by_state,
        (SELECT COUNT(*) FROM dbo.vw_fact_activity)                                          AS view_rows,
        (SELECT COUNT(*) FROM dbo.fact_activity)                                             AS table_rows;

/* Q12. Duplicate check pattern (run against any staging table) */
SELECT activity_id, COUNT(*) AS copies
FROM dbo.fact_activity
GROUP BY activity_id
HAVING COUNT(*) > 1;
GO
