/* =============================================================================
   02_load.sql  —  manual load path (use this if you are not running
   `python pipeline/weekly_refresh.py --load`)

   Loads the validated CSVs from data/processed/ in one transaction.
   1. Run `python pipeline/weekly_refresh.py` first, so data/processed/ exists.
   2. Set @path below to that folder on the machine running SQL Server
      (the SQL Server service account needs read access to it).
   3. Execute.
   ============================================================================= */
USE EngineeringActivity;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;     -- any error rolls the whole load back

DECLARE @path NVARCHAR(400) = N'C:\repos\engineering-activity-analytics\data\processed\';
DECLARE @sql  NVARCHAR(MAX), @t SYSNAME, @i INT = 1;

-- parent-to-child load order (foreign keys)
DECLARE @tables TABLE (seq INT, tbl SYSNAME);
INSERT INTO @tables VALUES
 (1,'dim_unit'),(2,'dim_platform'),(3,'dim_function'),(4,'dim_location'),(5,'dim_state'),(6,'dim_date'),
 (7,'dim_engineer'),(8,'dim_project'),(9,'fact_activity'),(10,'activity_state_history'),
 (11,'fact_timesheet'),(12,'fact_escalation');

BEGIN TRANSACTION;

    -- clear child-to-parent (TRUNCATE is not allowed on tables referenced by a foreign key)
    DELETE FROM dbo.fact_escalation;
    DELETE FROM dbo.fact_timesheet;
    DELETE FROM dbo.activity_state_history;
    DELETE FROM dbo.fact_activity;
    DELETE FROM dbo.dim_project;
    DELETE FROM dbo.dim_engineer;
    DELETE FROM dbo.dim_date;
    DELETE FROM dbo.dim_state;
    DELETE FROM dbo.dim_location;
    DELETE FROM dbo.dim_function;
    DELETE FROM dbo.dim_platform;
    DELETE FROM dbo.dim_unit;
    DELETE FROM dbo.stg_refresh_info;

    WHILE @i <= 12
    BEGIN
        SELECT @t = tbl FROM @tables WHERE seq = @i;
        SET @sql = N'BULK INSERT dbo.' + QUOTENAME(@t) + N' FROM ''' + @path + @t + N'.csv'''
                 + N' WITH (FORMAT = ''CSV'', FIRSTROW = 2, CODEPAGE = ''65001'', TABLOCK);';
        EXEC sys.sp_executesql @sql;
        PRINT CONCAT(@t, ' loaded');
        SET @i = @i + 1;
    END;

    SET @sql = N'BULK INSERT dbo.stg_refresh_info FROM ''' + @path + N'refresh_info.csv'''
             + N' WITH (FORMAT = ''CSV'', FIRSTROW = 2);';
    EXEC sys.sp_executesql @sql;

    INSERT INTO dbo.etl_refresh_log (as_of_date, dq_status, activities_loaded, rows_quarantined)
    SELECT as_of_date, dq_status, clean_activities, rows_quarantined
    FROM dbo.stg_refresh_info;

COMMIT TRANSACTION;

/* quick reconciliation against the DQ report: these counts should match it */
SELECT 'fact_activity' AS table_name, COUNT(*) AS row_count FROM dbo.fact_activity
UNION ALL SELECT 'activity_state_history', COUNT(*) FROM dbo.activity_state_history
UNION ALL SELECT 'fact_timesheet', COUNT(*) FROM dbo.fact_timesheet
UNION ALL SELECT 'fact_escalation', COUNT(*) FROM dbo.fact_escalation;
GO
