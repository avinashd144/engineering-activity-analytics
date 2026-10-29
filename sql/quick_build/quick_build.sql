/* =============================================================================
   quick_build.sql  —  EDL files -> SQL -> Power BI, in one script
   Engineering Activity Analytics (portfolio project, synthetic data)

   Run in SSMS (SQL Server 2019+). Takes under a minute.
     1. Set @path (section 2) to your data\edl_source\ folder.
     2. Execute the whole script (F5).

   Layers
     edl.*  raw source tables, loaded exactly as the files arrive (no keys, no
            constraints, defects included), the way a data lake holds them
     rpt.*  reporting views: data-quality checks, the cleaned and joined
            activity dataset, dimensions, month-end snapshot. Power BI imports these.
   ============================================================================= */

IF DB_ID('EngineeringActivity') IS NULL CREATE DATABASE EngineeringActivity;
GO
USE EngineeringActivity;
GO
IF SCHEMA_ID('edl') IS NULL EXEC('CREATE SCHEMA edl');
GO
IF SCHEMA_ID('rpt') IS NULL EXEC('CREATE SCHEMA rpt');
GO

/* ============================================================================
   1. EDL raw tables (permissive types, no constraints: raw lake data)
   ============================================================================ */
DROP TABLE IF EXISTS edl.Unit, edl.Platform, edl.[Function], edl.Location, edl.Engineer,
                     edl.Project, edl.Activity, edl.ActivityStateHistory, edl.ExtractInfo;

CREATE TABLE edl.Unit     (UnitID VARCHAR(10), UnitName NVARCHAR(60));
CREATE TABLE edl.Platform (PlatformID VARCHAR(10), PlatformName NVARCHAR(60), UnitID VARCHAR(10));
CREATE TABLE edl.[Function] (FunctionID VARCHAR(10), FunctionName NVARCHAR(60), FunctionCode VARCHAR(10));
CREATE TABLE edl.Location (LocationID VARCHAR(10), LocationName NVARCHAR(60), Country NVARCHAR(40));
CREATE TABLE edl.Engineer (EngineerID VARCHAR(10), EngineerName NVARCHAR(80), HomeFunctionID VARCHAR(10),
                           LocationID VARCHAR(10), [Role] VARCHAR(30), Capacity INT, IsActive INT);
CREATE TABLE edl.Project  (ProjectID VARCHAR(10), ProjectTitle NVARCHAR(120), UnitID VARCHAR(10),
                           PlatformID VARCHAR(10), ProjectStartDate DATE);
CREATE TABLE edl.Activity (ActivityID VARCHAR(10), ProjectID VARCHAR(10), ActivityTitle NVARCHAR(120),
                           FunctionID VARCHAR(10), ActivityEngineerID VARCHAR(10), GuideApproverID VARCHAR(10),
                           LocationID VARCHAR(10), [State] VARCHAR(30), CreatedDate DATE, StartDate DATE,
                           Deadline DATE, ReportDate DATE, CompletionDate DATE, PercentComplete INT,
                           PlannedHours INT);
CREATE TABLE edl.ActivityStateHistory (ActivityID VARCHAR(10), [State] VARCHAR(30), ValidFrom DATE, ValidTo DATE);
CREATE TABLE edl.ExtractInfo (AsOfDate DATE);
GO

/* ============================================================================
   2. Load the EDL files  (change @path)
   ============================================================================ */
DECLARE @path NVARCHAR(400) = N'C:\repos\engineering-activity-analytics\data\edl_source\';
DECLARE @t SYSNAME, @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT t FROM (VALUES ('Unit'),('Platform'),('Function'),('Location'),('Engineer'),('Project'),
                          ('Activity'),('ActivityStateHistory'),('ExtractInfo')) v(t);
OPEN c;
FETCH NEXT FROM c INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'BULK INSERT edl.' + QUOTENAME(@t) + N' FROM ''' + @path + @t + N'.csv'''
             + N' WITH (FORMAT = ''CSV'', FIRSTROW = 2, CODEPAGE = ''65001'');';
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM c INTO @t;
END;
CLOSE c; DEALLOCATE c;

SELECT 'Activity' AS edl_table, COUNT(*) AS rows_loaded FROM edl.Activity
UNION ALL SELECT 'ActivityStateHistory', COUNT(*) FROM edl.ActivityStateHistory
UNION ALL SELECT 'Engineer', COUNT(*) FROM edl.Engineer
UNION ALL SELECT 'Project', COUNT(*) FROM edl.Project;
GO

/* ============================================================================
   3. Data-quality checks: one row per check, re-run on every refresh.
      Power BI shows this as the Data Quality page; anything non-zero is
      excluded from (or corrected in) rpt.vw_FactActivity below.
   ============================================================================ */
CREATE OR ALTER VIEW rpt.vw_DataQualityChecks
AS
WITH a AS (SELECT * FROM edl.Activity),
dup AS (SELECT ActivityID FROM a GROUP BY ActivityID HAVING COUNT(*) > 1)
SELECT 'Duplicate ActivityID rows' AS CheckName, 'Removed (one copy kept)' AS ActionTaken,
       (SELECT COUNT(*) FROM a) - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM a) d) AS RowsAffected
UNION ALL
SELECT 'Missing activity engineer', 'Excluded', COUNT(*) FROM a WHERE ActivityEngineerID IS NULL
UNION ALL
SELECT 'Activity engineer not in Engineer table', 'Excluded', COUNT(*)
FROM a WHERE ActivityEngineerID IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM edl.Engineer e WHERE e.EngineerID = a.ActivityEngineerID)
UNION ALL
SELECT 'State not in allowed list', 'Excluded', COUNT(*)
FROM a WHERE LTRIM(RTRIM(a.[State])) NOT IN ('Proposed','Planning','Active','Review','Report','Closed')
UNION ALL
SELECT 'State with stray spaces or wrong case', 'Standardised', COUNT(*)
FROM a WHERE LTRIM(RTRIM(a.[State])) IN ('Proposed','Planning','Active','Review','Report','Closed')
         AND (DATALENGTH(a.[State]) <> DATALENGTH(LTRIM(RTRIM(a.[State])))
              OR LTRIM(RTRIM(a.[State])) COLLATE Latin1_General_CS_AS
                 NOT IN ('Proposed','Planning','Active','Review','Report','Closed'))
UNION ALL
SELECT 'Completed before it started', 'Excluded', COUNT(*) FROM a WHERE CompletionDate < StartDate
UNION ALL
SELECT 'Closed with no completion date', 'Excluded', COUNT(*)
FROM a WHERE LTRIM(RTRIM([State])) = 'Closed' AND CompletionDate IS NULL
UNION ALL
SELECT 'Percent complete outside 0-100', 'Clipped to 0-100', COUNT(*)
FROM a WHERE PercentComplete < 0 OR PercentComplete > 100
UNION ALL
SELECT 'Project not in Project table', 'Excluded', COUNT(*)
FROM a WHERE NOT EXISTS (SELECT 1 FROM edl.Project p WHERE p.ProjectID = a.ProjectID);
GO

/* ============================================================================
   4. The core extraction query: one clean row per activity.
      Multi-table join across the EDL tables + business rules.
      Grain: ONE ROW = ONE ACTIVITY.
   ============================================================================ */
CREATE OR ALTER VIEW rpt.vw_FactActivity
AS
WITH deduped AS (                         -- exact duplicate rows sent twice -> one copy
    SELECT DISTINCT * FROM edl.Activity
),
uniq AS (                                 -- same ID with different values -> can't tell which is right
    SELECT *, COUNT(*) OVER (PARTITION BY ActivityID) AS copies FROM deduped
),
as_of AS (SELECT MAX(AsOfDate) AS AsOfDate FROM edl.ExtractInfo),
states AS (
    SELECT * FROM (VALUES ('Proposed',1),('Planning',2),('Active',3),('Review',4),('Report',5),('Closed',6))
           s([State], StateOrder)
)
SELECT
    a.ActivityID,
    a.ProjectID,
    p.UnitID,
    p.PlatformID,
    a.FunctionID,
    a.ActivityEngineerID,
    a.GuideApproverID,
    ga.EngineerName                                        AS GuideApproverName,
    a.LocationID,
    st.[State],                                            -- standardised spelling
    st.StateOrder,
    a.ActivityTitle,
    a.CreatedDate,
    a.StartDate,
    a.Deadline,
    a.ReportDate,
    a.CompletionDate,
    CASE WHEN a.PercentComplete < 0 THEN 0
         WHEN a.PercentComplete > 100 THEN 100
         ELSE a.PercentComplete END                        AS PercentComplete,
    as_of.AsOfDate,
    CASE WHEN st.[State] <> 'Closed' THEN 1 ELSE 0 END    AS IsOpen,
    CASE WHEN st.[State] IN ('Active','Review','Report') THEN 1 ELSE 0 END AS IsInFlight,
    CASE WHEN st.[State] <> 'Closed' AND a.Deadline < as_of.AsOfDate THEN 1 ELSE 0 END AS IsOverdue,
    CASE WHEN st.[State] <> 'Closed' AND a.Deadline < as_of.AsOfDate
         THEN DATEDIFF(DAY, a.Deadline, as_of.AsOfDate) END AS DaysOverdue
FROM uniq             AS a
JOIN states           AS st ON st.[State]     = LTRIM(RTRIM(a.[State]))   -- drops invalid states
JOIN edl.Project      AS p  ON p.ProjectID    = a.ProjectID               -- drops orphan projects
JOIN edl.[Function]   AS f  ON f.FunctionID   = a.FunctionID
JOIN edl.Engineer     AS ae ON ae.EngineerID  = a.ActivityEngineerID      -- drops missing / unknown engineers
LEFT JOIN edl.Engineer AS ga ON ga.EngineerID = a.GuideApproverID         -- guide/approver is optional
CROSS JOIN as_of
WHERE a.copies = 1
  AND (a.CompletionDate IS NULL OR a.StartDate IS NULL OR a.CompletionDate >= a.StartDate)   -- NULL-safe
  AND NOT (st.[State] = 'Closed' AND a.CompletionDate IS NULL);
GO

/* The same data as ONE flat, readable table (names instead of IDs).
   Useful for checking numbers in SSMS or for a quick flat Power BI table. */
CREATE OR ALTER VIEW rpt.vw_ActivityReport
AS
SELECT
    fa.ActivityID, fa.ActivityTitle,
    p.ProjectID, p.ProjectTitle,
    u.UnitName, pl.PlatformName, f.FunctionName,
    ae.EngineerName  AS ActivityEngineer,
    ga.EngineerName  AS GuideApprover,
    l.LocationName,
    fa.[State], fa.StartDate, fa.Deadline, fa.ReportDate, fa.CompletionDate,
    fa.PercentComplete, fa.IsOpen, fa.IsInFlight, fa.IsOverdue, fa.DaysOverdue
FROM rpt.vw_FactActivity AS fa
JOIN edl.Project      AS p  ON p.ProjectID   = fa.ProjectID
JOIN edl.Unit         AS u  ON u.UnitID      = p.UnitID
JOIN edl.Platform     AS pl ON pl.PlatformID = p.PlatformID
JOIN edl.[Function]   AS f  ON f.FunctionID  = fa.FunctionID
JOIN edl.Engineer     AS ae ON ae.EngineerID = fa.ActivityEngineerID
LEFT JOIN edl.Engineer AS ga ON ga.EngineerID = fa.GuideApproverID
JOIN edl.Location     AS l  ON l.LocationID  = fa.LocationID;
GO

/* ============================================================================
   5. Dimensions for the Power BI star schema
   ============================================================================ */
CREATE OR ALTER VIEW rpt.vw_DimEngineer AS
SELECT e.EngineerID, e.EngineerName, e.[Role], f.FunctionName AS HomeFunction,
       l.LocationName, e.Capacity
FROM edl.Engineer e
JOIN edl.[Function] f ON f.FunctionID = e.HomeFunctionID
JOIN edl.Location   l ON l.LocationID = e.LocationID;
GO
CREATE OR ALTER VIEW rpt.vw_DimProject AS
SELECT p.ProjectID, p.ProjectTitle, p.ProjectStartDate FROM edl.Project p;
GO
CREATE OR ALTER VIEW rpt.vw_DimUnit     AS SELECT UnitID, UnitName FROM edl.Unit;
GO
CREATE OR ALTER VIEW rpt.vw_DimPlatform AS SELECT PlatformID, PlatformName FROM edl.Platform;
GO
CREATE OR ALTER VIEW rpt.vw_DimFunction AS SELECT FunctionID, FunctionName, FunctionCode FROM edl.[Function];
GO
CREATE OR ALTER VIEW rpt.vw_DimLocation AS SELECT LocationID, LocationName, Country FROM edl.Location;
GO
CREATE OR ALTER VIEW rpt.vw_DimState AS
SELECT [State], StateOrder, CASE WHEN [State] = 'Closed' THEN 0 ELSE 1 END AS IsOpen
FROM (VALUES ('Proposed',1),('Planning',2),('Active',3),('Review',4),('Report',5),('Closed',6)) s([State], StateOrder);
GO

/* Calendar: every day from the earliest activity to the end of the latest deadline year.
   Built from a 10 x 10 x 10 x 10 numbers table (no recursion limit to worry about). */
CREATE OR ALTER VIEW rpt.vw_Calendar
AS
WITH d AS (SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) v(n)),
nums AS (SELECT a.n + 10 * b.n + 100 * c.n + 1000 * e.n AS n FROM d a CROSS JOIN d b CROSS JOIN d c CROSS JOIN d e),
bounds AS (SELECT MIN(CreatedDate) AS d0,
                  DATEFROMPARTS(YEAR(MAX(Deadline)), 12, 31) AS d1 FROM edl.Activity),
days AS (SELECT DATEADD(DAY, n.n, b.d0) AS [Date] FROM nums n CROSS JOIN bounds b
         WHERE DATEADD(DAY, n.n, b.d0) <= b.d1)
SELECT [Date],
       YEAR([Date])                                      AS [Year],
       MONTH([Date])                                     AS MonthNum,
       DATENAME(MONTH, [Date])                           AS MonthName,
       FORMAT([Date], 'yyyy-MM')                         AS YearMonth,
       CASE WHEN [Date] = EOMONTH([Date]) THEN 1 ELSE 0 END AS IsMonthEnd
FROM days;
GO

/* ============================================================================
   6. History views for the trend and closed dashboards
   ============================================================================ */
-- Month-end snapshot: the state each activity was in on the last day of each month.
-- Rebuilt from state history with a range join (ValidFrom <= month end < ValidTo).
CREATE OR ALTER VIEW rpt.vw_ActivityMonthly
AS
SELECT c.[Date] AS MonthEndDate, h.ActivityID, h.[State],
       fa.FunctionID, fa.UnitID, fa.ActivityEngineerID
FROM rpt.vw_Calendar AS c
JOIN edl.ActivityStateHistory AS h
  ON h.ValidFrom <= c.[Date]
 AND (h.ValidTo IS NULL OR h.ValidTo > c.[Date])
JOIN rpt.vw_FactActivity AS fa ON fa.ActivityID = h.ActivityID      -- clean activities only
WHERE c.IsMonthEnd = 1
  AND c.[Date] <= (SELECT MAX(AsOfDate) FROM edl.ExtractInfo);
GO

-- The date each activity ENTERED each state (for "reached Review / Closed in month X").
CREATE OR ALTER VIEW rpt.vw_StateEntries
AS
SELECT h.ActivityID, h.[State], h.ValidFrom AS EnteredDate, fa.UnitID, fa.FunctionID
FROM edl.ActivityStateHistory AS h
JOIN rpt.vw_FactActivity AS fa ON fa.ActivityID = h.ActivityID;
GO

/* ============================================================================
   7. Checks before you open Power BI: these numbers should match the report
   ============================================================================ */
SELECT * FROM rpt.vw_DataQualityChecks;

SELECT [State], COUNT(DISTINCT ActivityID) AS Activities
FROM rpt.vw_FactActivity
GROUP BY [State], StateOrder
ORDER BY StateOrder;

SELECT TOP (10) ActivityEngineer, COUNT(*) AS InFlight
FROM rpt.vw_ActivityReport
WHERE IsInFlight = 1
GROUP BY ActivityEngineer
ORDER BY InFlight DESC;
GO
