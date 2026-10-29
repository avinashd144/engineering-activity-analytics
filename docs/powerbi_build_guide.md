# Power BI build guide

Step-by-step instructions to build `powerbi/engineering_activity_analytics.pbix` in Power BI Desktop. Allow about 3–4 hours.

**Before you start:** run `sql/01_schema.sql`, then `python pipeline/weekly_refresh.py --as-of 2026-09-30` (or `--load`), then `sql/02_load.sql` if you did not use `--load`, then `sql/03_views.sql`.

---

## Step 1 — Get data (Import mode)

1. **Home → Get data → SQL Server.** Server: `localhost` (or `localhost\SQLEXPRESS`). Database: `EngineeringActivity`. Data connectivity mode: **Import**.
2. In the Navigator, tick these and click **Transform Data** (not Load):

| Source object | Rename the query to |
|---|---|
| `vw_fact_activity` | `fact_activity` |
| `vw_fact_activity_monthly` | `fact_activity_monthly` |
| `vw_fact_timesheet` | `fact_timesheet` |
| `vw_fact_escalation` | `fact_escalation` |
| `vw_dim_engineer` | `dim_engineer` |
| `dim_date`, `dim_state`, `dim_function`, `dim_unit`, `dim_platform`, `dim_project`, `dim_location` | keep names |
| `etl_refresh_log` | `refresh_log` |
| `vw_dq_latest` | `dq_latest` |

**Why Import, not DirectQuery?** The data changes weekly, the model is small, and managers filter heavily, so interactivity matters more than second-by-second freshness. Import gives fast cross-filtering, and the scheduled refresh keeps it current.

## Step 2 — Power Query checks

In Power Query Editor:
1. Check data types: all `*_date` columns **Date**; `is_*` columns **True/False**; `hours` **Decimal**; `percent_complete`, `planned_hours`, `capacity_activities` **Whole number**.
2. Check **View → Column quality**. Key columns should show 0% errors and 0% empty, except `start_date`, `report_date`, `closed_date`, `days_overdue` and `cycle_time_days`, which are empty by design for activities that have not reached that stage.
3. Confirm query folding: right-click the last step of `fact_activity` → **View Native Query** should be available (the work is done by SQL Server).
4. **Close & Apply.**

## Step 3 — Model view: relationships

Delete any relationships Power BI auto-detected, then create these (Manage relationships → New). All are **one-to-many, single cross-filter direction**.

| One side | Many side | Active |
|---|---|---|
| dim_date[date] | fact_activity[created_date] | ✅ |
| dim_date[date] | fact_activity[closed_date] | ❌ untick "Make this relationship active" |
| dim_date[date] | fact_activity_monthly[month_end_date] | ✅ |
| dim_date[date] | fact_timesheet[week_start] | ✅ |
| dim_date[date] | fact_escalation[escalation_date] | ✅ |
| dim_engineer[engineer_id] | fact_activity[activity_engineer_id] | ✅ |
| dim_engineer[engineer_id] | fact_activity[guide_approver_id] | ❌ |
| dim_engineer[engineer_id] | fact_activity_monthly[activity_engineer_id] | ✅ |
| dim_engineer[engineer_id] | fact_timesheet[engineer_id] | ✅ |
| dim_engineer[engineer_id] | fact_escalation[activity_engineer_id] | ✅ |
| dim_state[state] | fact_activity[state] | ✅ |
| dim_state[state] | fact_activity_monthly[state] | ✅ |
| dim_function[function_id] | fact_activity / fact_activity_monthly / fact_timesheet / fact_escalation [function_id] | ✅ |
| dim_unit[unit_id] | fact_activity / fact_activity_monthly / fact_timesheet / fact_escalation [unit_id] | ✅ |
| dim_project[project_id] | fact_activity / fact_timesheet / fact_escalation [project_id] | ✅ |
| dim_platform[platform_id] | fact_activity[platform_id] | ✅ |
| dim_location[location_id] | fact_activity[location_id] | ✅ |

Then:
1. Select `dim_date` → **Table tools → Mark as date table** → column `date`.
2. Sort columns: `dim_date[month_name]` and `month_short` by `month_num`; `dim_state[state]` by `state_order`.
3. Hide every ID/key column on the fact tables (right-click → Hide in report view). Report authors should only see dimension attributes and measures.
4. Arrange the diagram as a star with the facts in the middle. Take a screenshot for `docs/images/model.png`.

## Step 4 — Measures

1. **Home → Enter data**, name the table `_Measures`, load it, then delete its default column once the first measure exists.
2. Create every measure in `dax/measures.dax`. Set **Display folder** in the Properties pane as given in each section header.
3. Formats: `% of Open Activities`, `Overdue % of Open`, `Load Ratio`, `Closed MoM %`, `Escalations MoM %`, `On-Time Closure %`, `Utilisation (Last 4 Weeks)` → Percentage, 0 decimals. Day measures → whole number.

**Check against SQL before building visuals** (run `sql/04_analysis_queries.sql`, Q1 and Q11): a card with `[Open Activities]` must equal `distinct_open`, and a table of `dim_state[state]` × `[Open Activities]` must match Q1 row for row.

## Step 5 — Report pages

Use the same layout on every page: title top left, the `[Data As Of Label]` card top right, a slicer panel on the left (Unit, Function, Platform, Location), visuals on the right. Sync slicers across pages: **View → Sync slicers**.

### Page 1 — Activity Load (current status)
*Question: how many activities are in each state right now, and where?*
- Cards: `[Open Activities]`, `[Active Activities]`, `[Overdue Activities]`, `[Overdue % of Open]`, `[Projects with Open Activities]`.
- Clustered bar: Axis `dim_state[state]` (filter `is_open` = True), Value `[Open Activities]`, tooltip `[% of Open Activities]`.
- Stacked bar: Axis `dim_function[function_name]`, Legend `dim_state[state]`, Value `[Open Activities]`.
- Matrix: Rows `dim_unit[unit_name]` → `dim_project[project_title]`, Columns `dim_state[state]`, Values `[Open Activities]`. Enable drill-down (+/−).

### Page 2 — Status Trend (month-end history)
*Question: how has the status mix changed over time?*
- Slicer: `dim_date[fiscal_year]`.
- Stacked column: Axis `dim_date[year_month]`, Legend `dim_state[state]` (exclude Closed), Value `[Activities at Month End]`.
- Line: Axis `dim_date[year_month]`, Values `[Active at Month End]`, `[Overdue at Month End]`.
- Card: `[Active Change vs Prev Month]` (shows the latest month in context).

### Page 3 — Function View
*Question: where is the workload concentrated by discipline?*
- Matrix: Rows `dim_function[function_name]`, Columns `dim_state[state]`, Values `[Open Activities]`, with conditional-format background (colour scale) on values.
- Clustered bar: `dim_function[function_name]` × `[Overdue Activities]`.
- Scatter: Details `dim_function[function_name]`, X `[Open Activities]`, Y `[Avg Days Overdue]`.

### Page 4 — Closed Activity (throughput)
*Question: how much work is being completed, by unit and month?*
- Cards: `[Closed Activities FYTD]`, `[Avg Cycle Time (days)]`, `[On-Time Closure %]`.
- Clustered column: Axis `dim_date[year_month]`, Legend `dim_unit[unit_name]`, Value `[Closed Activities]`.
- Line: `[Closed Activities]` and `[Closed Activities 3M Avg]` by `dim_date[year_month]`.
- Cross-check: the monthly totals must match `vw_closed_by_month` in SQL.

### Page 5 — Engineer Load (resource balancing)
*Question: who is overloaded, who has room, and which activities make up each person's load?*
- Slicer: `dim_engineer[home_function_name]`, `dim_engineer[location_name]`.
- Cards: `[Overloaded Engineers]`, `[Under-utilised Engineers]`, `[Engineer Load]`, `[Engineer Capacity]`.
- Bar chart: Axis `dim_engineer[engineer_name]`, Values `[Engineer Load]` and `[Engineer Capacity]`, sorted by `[Engineer Load]` descending. Conditional formatting: bar colour by rules on `[Load Ratio]` (> 1 red, < 0.5 grey).
- Table under the chart: `dim_project[project_title]`, `fact_activity[activity_title]`, `dim_state[state]`, `fact_activity[percent_complete]`, `fact_activity[deadline_date]`, `fact_activity[is_overdue]`. Filter: `fact_activity[is_in_flight]` = True. Title: **fx → `[Engineer Detail Title]`**.
- Table: `dim_engineer[engineer_name]`, `[Engineer Load]`, `[Function Avg Load]`, `[Load vs Function Avg]`, `[Activities as Guide]`, `[Load Band]`, `[Hours Logged (Last 4 Weeks)]`.

**Cross-filtering (the core of this page):**
1. Select the bar chart → **Format → Edit interactions**.
2. On the activity detail table, set the icon to **Filter**, so clicking an engineer's bar shows only their activities.
3. On the cards, set **Filter** as well, so they show the selected engineer's numbers.
4. Turn Edit interactions off. Ctrl+click two bars to compare two engineers.

**Drill-through (optional):** add a page "Engineer Detail" with `dim_engineer[engineer_name]` in the Drill-through well, a timesheet line chart (`dim_date[week_start]` × `[Hours Logged]`) and the activity table. Right-click an engineer anywhere → Drill through.

### Page 6 — Escalations
- Column + line: `dim_date[year_month]` × `[Escalations]` (columns) and `[Escalations per 100 In-Flight]` (line).
- Bar: `fact_escalation[reason]` × `[Escalations]`.
- Card: `[Escalations Rolling 3M]`.

### Page 7 — Data Quality
- Table from `dq_latest`: `table_name`, `check_name`, `severity`, `rows_affected`, `action`, `status`, with conditional formatting on `status` (ERROR red, WARN amber, PASS green).
- Cards: `[DQ Checks Run]`, `[DQ Checks Failed]`, `[Rows Quarantined]`.
- Line from `refresh_log`: `as_of_date` × `activities_loaded`.

## Step 6 — Finish and test

1. **View → Performance analyzer → Start recording → Refresh visuals.** Every visual should render in well under a second. Note the slowest DAX query for your README.
2. Test one slicer combination per page against an SQL query.
3. Save as `powerbi/engineering_activity_analytics.pbix`.
4. Export a screenshot of each page into `docs/images/` (names in the README).

## Step 7 — Publish and schedule refresh (optional, needs a Power BI account)

1. **Home → Publish** to a workspace.
2. Because SQL Server runs on your machine, install the **on-premises data gateway** (personal mode is fine for a portfolio), sign in, and map the `EngineeringActivity` data source in the semantic model's settings.
3. Semantic model → **Settings → Scheduled refresh**: weekly, the morning after the pipeline runs (see `docs/automation.md`).
4. Optional: package the pages as a **workspace App** for managers.
