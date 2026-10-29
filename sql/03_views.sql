/* =============================================================================
   03_views.sql  —  reporting layer
   The joins and business rules live here, once, so Power BI imports clean,
   report-shaped tables and the DAX stays simple.

   Imported by Power BI (star schema facts):
     vw_fact_activity          one row per activity, with unit/platform and status flags
     vw_fact_activity_monthly  month-end snapshot rebuilt from state history
     vw_fact_timesheet         weekly hours with activity context
     vw_fact_escalation        escalations with activity context
     vw_dim_engineer           engineer with home function and location names
     vw_dq_latest              latest data-quality results
   Analysis / reconciliation views (SQL-side answers to the same questions):
     vw_engineer_load, vw_closed_by_month, vw_escalations_monthly
   ============================================================================= */
USE EngineeringActivity;
GO

/* ---------------------------------------------------------------------------
   Business rules (documented once, used everywhere)
     open        : state <> 'Closed'
     in-flight   : state IN ('Active','Review','Report')  -> counts towards engineer load
     overdue     : open AND deadline_date < as-of date of the latest refresh
     cycle time  : start_date -> closed_date, in days
   --------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_fact_activity
AS
SELECT
    a.activity_id,
    a.project_id,
    p.unit_id,
    p.platform_id,
    a.function_id,
    a.activity_engineer_id,
    a.guide_approver_id,
    a.location_id,
    a.state,
    a.activity_title,
    a.created_date,
    a.start_date,
    a.deadline_date,
    a.report_date,
    a.closed_date,
    a.percent_complete,
    a.planned_hours,
    r.as_of_date,
    s.is_open,
    CAST(CASE WHEN a.state IN ('Active', 'Review', 'Report') THEN 1 ELSE 0 END AS BIT)        AS is_in_flight,
    CAST(CASE WHEN s.is_open = 1 AND a.deadline_date < r.as_of_date THEN 1 ELSE 0 END AS BIT) AS is_overdue,
    CASE WHEN s.is_open = 1 AND a.deadline_date < r.as_of_date
         THEN DATEDIFF(DAY, a.deadline_date, r.as_of_date) END                               AS days_overdue,
    CASE WHEN s.is_open = 1 THEN DATEDIFF(DAY, a.created_date, r.as_of_date) END              AS age_days,
    DATEDIFF(DAY, a.start_date, a.closed_date)                                                AS cycle_time_days
FROM dbo.fact_activity AS a
JOIN dbo.dim_project   AS p ON p.project_id = a.project_id
JOIN dbo.dim_state     AS s ON s.state      = a.state
CROSS JOIN (SELECT MAX(as_of_date) AS as_of_date FROM dbo.etl_refresh_log) AS r;
GO

/* Month-end snapshot: which state was each activity in on the last day of each month?
   Rebuilt from the state-history table with a range join, so the trend page does not
   need a separate snapshot load. Grain: one row per activity per month-end. */
CREATE OR ALTER VIEW dbo.vw_fact_activity_monthly
AS
SELECT
    d.[date]                AS month_end_date,
    h.activity_id,
    h.state,
    a.function_id,
    p.unit_id,
    a.activity_engineer_id,
    CAST(CASE WHEN h.state <> 'Closed' AND a.deadline_date < d.[date] THEN 1 ELSE 0 END AS BIT) AS is_overdue_at_month_end
FROM dbo.dim_date               AS d
JOIN dbo.activity_state_history AS h
      ON h.valid_from <= d.[date]
     AND (h.valid_to IS NULL OR h.valid_to > d.[date])
JOIN dbo.fact_activity          AS a ON a.activity_id = h.activity_id
JOIN dbo.dim_project            AS p ON p.project_id  = a.project_id
WHERE d.is_month_end = 1
  AND d.[date] <= (SELECT MAX(as_of_date) FROM dbo.etl_refresh_log);
GO

CREATE OR ALTER VIEW dbo.vw_fact_timesheet
AS
SELECT
    t.timesheet_id,
    t.week_start,
    t.engineer_id,
    t.activity_id,
    a.project_id,
    p.unit_id,
    a.function_id,
    t.hours
FROM dbo.fact_timesheet AS t
JOIN dbo.fact_activity  AS a ON a.activity_id = t.activity_id
JOIN dbo.dim_project    AS p ON p.project_id  = a.project_id;
GO

CREATE OR ALTER VIEW dbo.vw_fact_escalation
AS
SELECT
    e.escalation_id,
    e.escalation_date,
    e.activity_id,
    a.project_id,
    p.unit_id,
    a.function_id,
    a.activity_engineer_id,
    e.reason,
    e.raised_by
FROM dbo.fact_escalation AS e
JOIN dbo.fact_activity   AS a ON a.activity_id = e.activity_id
JOIN dbo.dim_project     AS p ON p.project_id  = a.project_id;
GO

/* Engineer dimension with home function and location names, so the Engineer Load page
   can slice engineers by their own function (capacity belongs to the engineer, not the activity). */
CREATE OR ALTER VIEW dbo.vw_dim_engineer
AS
SELECT
    e.engineer_id,
    e.engineer_name,
    e.[role],
    e.home_function_id,
    f.function_name       AS home_function_name,
    e.location_id,
    l.location_name,
    e.capacity_activities,
    e.is_active
FROM dbo.dim_engineer AS e
JOIN dbo.dim_function AS f ON f.function_id = e.home_function_id
JOIN dbo.dim_location AS l ON l.location_id = e.location_id;
GO

CREATE OR ALTER VIEW dbo.vw_dq_latest
AS
SELECT q.*
FROM dbo.dq_check_results AS q
WHERE q.refresh_id = (SELECT MAX(refresh_id) FROM dbo.etl_refresh_log);
GO

/* ---------------------------------------------------------------------------
   Engineer load: in-flight activities vs capacity, ranked inside each function.
   Uses a CTE for the aggregate and window functions for rank and function average.
   --------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_engineer_load
AS
WITH in_flight AS (
    SELECT activity_engineer_id               AS engineer_id,
           COUNT(DISTINCT activity_id)        AS in_flight_activities,
           SUM(CAST(is_overdue AS INT))       AS overdue_activities
    FROM dbo.vw_fact_activity
    WHERE is_in_flight = 1
    GROUP BY activity_engineer_id
),
as_guide AS (
    SELECT guide_approver_id AS engineer_id, COUNT(DISTINCT activity_id) AS guiding_activities
    FROM dbo.vw_fact_activity
    WHERE is_in_flight = 1 AND guide_approver_id IS NOT NULL
    GROUP BY guide_approver_id
),
eng_load AS (
    SELECT e.engineer_id,
           e.engineer_name,
           e.[role],
           f.function_name,
           l.location_name,
           e.capacity_activities,
           COALESCE(i.in_flight_activities, 0) AS in_flight_activities,
           COALESCE(i.overdue_activities, 0)   AS overdue_activities,
           COALESCE(g.guiding_activities, 0)   AS guiding_activities,
           CAST(COALESCE(i.in_flight_activities, 0) * 1.0 / NULLIF(e.capacity_activities, 0) AS DECIMAL(5,2)) AS load_ratio
    FROM dbo.dim_engineer  AS e
    JOIN dbo.dim_function  AS f ON f.function_id = e.home_function_id
    JOIN dbo.dim_location  AS l ON l.location_id = e.location_id
    LEFT JOIN in_flight    AS i ON i.engineer_id = e.engineer_id
    LEFT JOIN as_guide     AS g ON g.engineer_id = e.engineer_id
    WHERE e.is_active = 1
)
SELECT
    eng_load.*,
    CASE WHEN load_ratio > 1.0  THEN 'Overloaded'
         WHEN load_ratio < 0.5  THEN 'Under-utilised'
         ELSE 'Balanced' END                                                     AS load_band,
    DENSE_RANK() OVER (PARTITION BY function_name ORDER BY in_flight_activities DESC) AS rank_in_function,
    CAST(AVG(in_flight_activities * 1.0) OVER (PARTITION BY function_name) AS DECIMAL(5,2)) AS function_avg_load,
    in_flight_activities
      - CAST(AVG(in_flight_activities * 1.0) OVER (PARTITION BY function_name) AS DECIMAL(5,2)) AS load_vs_function_avg
FROM eng_load;
GO

/* Closures per unit per month, with month-on-month change and running total. */
CREATE OR ALTER VIEW dbo.vw_closed_by_month
AS
WITH closed AS (
    SELECT p.unit_id,
           DATEFROMPARTS(YEAR(a.closed_date), MONTH(a.closed_date), 1) AS month_start,
           COUNT(DISTINCT a.activity_id)                               AS closed_activities
    FROM dbo.fact_activity AS a
    JOIN dbo.dim_project   AS p ON p.project_id = a.project_id
    WHERE a.state = 'Closed'
    GROUP BY p.unit_id, DATEFROMPARTS(YEAR(a.closed_date), MONTH(a.closed_date), 1)
)
SELECT
    c.unit_id,
    u.unit_name,
    c.month_start,
    c.closed_activities,
    LAG(c.closed_activities) OVER (PARTITION BY c.unit_id ORDER BY c.month_start)          AS prev_month_closed,
    SUM(c.closed_activities) OVER (PARTITION BY c.unit_id ORDER BY c.month_start
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)       AS cumulative_closed
FROM closed      AS c
JOIN dbo.dim_unit AS u ON u.unit_id = c.unit_id;
GO

/* Escalations per month, normalised by month-end in-flight activities, with
   month-on-month change. A rate per 100 in-flight activities is fairer than a raw count
   when the size of the portfolio changes. */
CREATE OR ALTER VIEW dbo.vw_escalations_monthly
AS
WITH esc AS (
    SELECT EOMONTH(escalation_date) AS month_end_date, COUNT(*) AS escalations
    FROM dbo.fact_escalation
    GROUP BY EOMONTH(escalation_date)
),
inflight AS (
    SELECT month_end_date, COUNT(DISTINCT activity_id) AS in_flight_at_month_end
    FROM dbo.vw_fact_activity_monthly
    WHERE state IN ('Active', 'Review', 'Report')
    GROUP BY month_end_date
)
SELECT
    i.month_end_date,
    COALESCE(e.escalations, 0)                                                         AS escalations,
    i.in_flight_at_month_end,
    CAST(100.0 * COALESCE(e.escalations, 0) / NULLIF(i.in_flight_at_month_end, 0) AS DECIMAL(6,2)) AS escalations_per_100_in_flight,
    COALESCE(e.escalations, 0)
      - LAG(COALESCE(e.escalations, 0)) OVER (ORDER BY i.month_end_date)               AS change_vs_prev_month
FROM inflight AS i
LEFT JOIN esc AS e ON e.month_end_date = i.month_end_date;
GO
