# 2-hour build: EDL files → SQL → Power BI

The fastest path to a working replica of the five original dashboards. It uses only SSMS and Power BI Desktop (no Python packages beyond pandas, no ODBC setup).

| Time | Step | Done when |
|---|---|---|
| 0:00–0:10 | 1. Make the EDL files | `data/edl_source/` holds 9 CSVs |
| 0:10–0:25 | 2. Load and transform in SQL Server | the check queries at the end of the script return rows |
| 0:25–0:45 | 3. Power BI: import + relationships | model view looks like a star |
| 0:45–1:05 | 4. DAX measures | a card shows 260 open activities |
| 1:05–1:50 | 5. Five dashboard pages + Data Quality page | cross-filtering works on Engineer Load |
| 1:50–2:00 | 6. Screenshots + push to GitHub | README shows the images |

---

## Step 1 — Make the EDL files (10 min)

```bash
pip install pandas numpy
python data/generate_data.py --as-of 2026-09-30
python data/make_edl_files.py
```
The files in `data/edl_source/` are the "data lake" tables: `Unit`, `Platform`, `Function`, `Location`, `Engineer`, `Project`, `Activity`, `ActivityStateHistory`, `ExtractInfo`. They deliberately contain bad rows (duplicates, a missing engineer, invalid states, impossible dates) for the SQL checks to catch.

## Step 2 — SQL Server (15 min)

1. Open `sql/quick_build/quick_build.sql` in SSMS.
2. Change `@path` in section 2 to your `data\edl_source\` folder (keep the trailing `\`). The SQL Server service must be able to read that folder; if BULK INSERT says "access denied", copy the folder to `C:\temp\edl_source\` and point `@path` there.
3. Press F5. You should see:
   - **Data-quality checks:** 4 duplicates removed, 5 missing engineers, 3 unknown engineers, 2–3 invalid states, 3 completed-before-started, 2 closed-without-date, 4 percentages clipped.
   - **Activities by state:** about 522 Closed, 176 Active, 30 Planning, 25 Proposed, 18 Review, 11 Report (about 782 clean activities from 802 raw rows; SQL Server may keep one more, because it matches `closed ` to `Closed` and standardises it).

What the script builds:

| Layer | Object | Purpose |
|---|---|---|
| edl | 9 raw tables | Files loaded as-is, no keys, like a data lake |
| rpt | `vw_DataQualityChecks` | One row per check, counted on every refresh |
| rpt | `vw_FactActivity` | **The extraction query.** Dedupe, multi-table join, state standardisation, business flags. One row = one activity |
| rpt | `vw_ActivityReport` | Same data flat, with names, for checking in SSMS |
| rpt | `vw_Dim*`, `vw_Calendar` | Dimensions for the star schema |
| rpt | `vw_ActivityMonthly` | Month-end snapshot rebuilt from state history (range join) |
| rpt | `vw_StateEntries` | Date each activity entered each state (for Closed + Review by month) |

## Step 3 — Power BI: import and model (20 min)

1. **Get data → SQL Server** → Server `localhost` (or `localhost\SQLEXPRESS`), Database `EngineeringActivity`, **Import**.
2. Tick the `rpt` views below and **Transform Data**. Rename each query (double-click) to the name in the right column, then **Close & Apply**.

| View | Query name |
|---|---|
| rpt.vw_FactActivity | FactActivity |
| rpt.vw_ActivityMonthly | ActivityMonthly |
| rpt.vw_StateEntries | StateEntries |
| rpt.vw_DimEngineer | Engineer |
| rpt.vw_DimProject | Project |
| rpt.vw_DimUnit | Unit |
| rpt.vw_DimPlatform | Platform |
| rpt.vw_DimFunction | Function |
| rpt.vw_DimLocation | Location |
| rpt.vw_DimState | State |
| rpt.vw_Calendar | Calendar |
| rpt.vw_DataQualityChecks | DQ |

3. **Model view.** Delete auto-detected relationships, then create these (all one-to-many, single direction):

| One side | Many side | Active? |
|---|---|---|
| Engineer[EngineerID] | FactActivity[ActivityEngineerID] | Yes |
| Engineer[EngineerID] | FactActivity[GuideApproverID] | **No** (untick Active) |
| Engineer[EngineerID] | ActivityMonthly[ActivityEngineerID] | Yes |
| Project[ProjectID] | FactActivity[ProjectID] | Yes |
| Unit[UnitID] | FactActivity[UnitID], ActivityMonthly[UnitID], StateEntries[UnitID] | Yes |
| Platform[PlatformID] | FactActivity[PlatformID] | Yes |
| Function[FunctionID] | FactActivity[FunctionID], ActivityMonthly[FunctionID], StateEntries[FunctionID] | Yes |
| Location[LocationID] | FactActivity[LocationID] | Yes |
| State[State] | FactActivity[State], ActivityMonthly[State], StateEntries[State] | Yes |
| Calendar[Date] | ActivityMonthly[MonthEndDate] | Yes |
| Calendar[Date] | StateEntries[EnteredDate] | Yes |

4. Calendar → **Mark as date table** (column `Date`). Sort `State[State]` by `StateOrder` and `Calendar[MonthName]` by `MonthNum`.
5. Check types: dates are Date; `IsOpen`, `IsInFlight`, `IsOverdue` are Whole number (0/1).

## Step 4 — DAX measures (20 min)

**Home → Enter data** → name it `_Measures` → Load. Add these measures to it:

```dax
Activities = DISTINCTCOUNT ( FactActivity[ActivityID] )

Open Activities = CALCULATE ( [Activities], FactActivity[IsOpen] = 1 )

Active = CALCULATE ( [Activities], State[State] = "Active" )
Planning = CALCULATE ( [Activities], State[State] = "Planning" )
Proposed = CALCULATE ( [Activities], State[State] = "Proposed" )
Review = CALCULATE ( [Activities], State[State] = "Review" )
Report = CALCULATE ( [Activities], State[State] = "Report" )

Overdue Activities = CALCULATE ( [Activities], FactActivity[IsOverdue] = 1 )

-- Activity Status: count at the LAST month-end in context (a snapshot is not summed over months)
Activities at Month End =
VAR LastMonthEnd = MAX ( ActivityMonthly[MonthEndDate] )
RETURN
    CALCULATE ( DISTINCTCOUNT ( ActivityMonthly[ActivityID] ), ActivityMonthly[MonthEndDate] = LastMonthEnd )

-- Closed dashboard: activities that reached the completion stage (Review or Closed) in the period
Reached Completion Stage =
CALCULATE ( DISTINCTCOUNT ( StateEntries[ActivityID] ), State[State] IN { "Review", "Closed" } )

-- Engineer Load: in-flight activities where the engineer is the PRIMARY activity engineer
Engineer Load = CALCULATE ( [Activities], FactActivity[IsInFlight] = 1 )

-- Same activities counted through the guide/approver role (shown, NOT added to load)
Activities as Guide =
CALCULATE ( [Engineer Load], USERELATIONSHIP ( Engineer[EngineerID], FactActivity[GuideApproverID] ) )

Engineer Capacity = SUM ( Engineer[Capacity] )

Load Ratio = DIVIDE ( [Engineer Load], [Engineer Capacity] )

Overloaded Engineers = COUNTROWS ( FILTER ( VALUES ( Engineer[EngineerID] ), [Load Ratio] > 1 ) )

Engineer Detail Title =
"Activities for " & SELECTEDVALUE ( Engineer[EngineerName], "all engineers" )

DQ Rows Affected = SUM ( DQ[RowsAffected] )
```
Format `Load Ratio` as a percentage. **Check:** a card with `[Open Activities]` = 260, and `[Active]` = 176.

## Step 5 — The pages (45 min)

Put the same slicers on the left of every page (**View → Sync slicers**): Unit[UnitName], Platform[PlatformName], Function[FunctionName], Engineer[EngineerName], Location[LocationName].

**Page 1 — Activity Load** (*how many activities are in each state, by platform, unit, function, engineer*)
- Clustered column: X `State[State]`, Y `[Open Activities]`, data labels on.
- Cards: `[Open Activities]`, `[Active]`, `[Overdue Activities]`.

**Page 2 — Activity Status** (*monthly snapshot of Active, Planning and Report*)
- Line chart: X `Calendar[YearMonth]`, Y `[Activities at Month End]`, Legend `State[State]`; filter the visual to Active, Planning, Report.
- Slicer: `Calendar[Year]`.

**Page 3 — Competency-wise** (*distinct activities per discipline for Active, Planning, Report*)
- Clustered bar: Y `Function[FunctionName]`, X `[Active]`, `[Planning]`, `[Report]`.
- Matrix: rows `Function[FunctionName]`, columns `State[State]`, values `[Activities]`, colour-scale background.

**Page 4 — Closed Activity** (*activities reaching Closed or Review, by unit and month*)
- Stacked column: X `Calendar[YearMonth]`, Y `[Reached Completion Stage]`, Legend `Unit[UnitName]`.
- Matrix: rows `Calendar[Year]` → `Calendar[MonthName]`, columns `Unit[UnitName]`, values `[Reached Completion Stage]`.

**Page 5 — Engineer Load** (*load per engineer, and the activities behind it*)
- Bar chart: Y `Engineer[EngineerName]`, X `[Engineer Load]` and `[Engineer Capacity]`, sorted by load. Conditional bar colour: rules on `[Load Ratio]` (> 100% red).
- Table: `Project[ProjectTitle]`, `FactActivity[ActivityTitle]`, `FactActivity[State]`, `FactActivity[PercentComplete]`, `FactActivity[Deadline]`, `FactActivity[GuideApproverName]`. Visual filter `FactActivity[IsInFlight]` = 1. Title: **fx → [Engineer Detail Title]**.
- Table: `Engineer[EngineerName]`, `[Engineer Load]`, `[Activities as Guide]`, `[Engineer Capacity]`, `[Load Ratio]`.
- Card: `[Overloaded Engineers]`.
- **Cross-filtering:** select the bar chart → **Format → Edit interactions** → set the activity table and the cards to **Filter**. Click an engineer: the table lists exactly their activities.

**Page 6 — Data Quality** (*did the source pass its checks?*)
- Table: `DQ[CheckName]`, `DQ[RowsAffected]`, `DQ[ActionTaken]`, conditional formatting on RowsAffected.

## Step 6 — Finish (10 min)

1. Save as `powerbi/engineering_activity_analytics.pbix`.
2. Export one screenshot per page into `docs/images/` (`01_activity_load.png` … `06_data_quality.png`).
3. Commit and push:
```bash
git init
git add .
git commit -m "Engineering Activity Analytics: EDL files, SQL layer, Power BI report"
git branch -M main
git remote add origin https://github.com/avinashd144/engineering-activity-analytics.git
git push -u origin main
```
Create the empty repository on GitHub first (no README, so the push does not conflict).

**Short on time?** Pages 1, 5 and 6 are the ones to show: current load, the engineer cross-filter, and the data checks.
