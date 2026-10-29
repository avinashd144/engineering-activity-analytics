/* =============================================================================
   01_schema.sql  —  Engineering Activity Analytics (portfolio project)
   Target: SQL Server 2019+ (tested pattern for SQL Server 2022 / SSMS)

   Creates the database and a normalised schema that mirrors a typical
   project-tracking source system:
     dimensions : unit, platform, function, location, state, engineer, project, date
     facts      : activity (one row = one engineering activity), state history,
                  weekly timesheets, escalations
     control    : refresh log and data-quality results written by the pipeline

   Re-runnable: drops and recreates every table.
   ============================================================================= */

IF DB_ID('EngineeringActivity') IS NULL
    CREATE DATABASE EngineeringActivity;
GO
USE EngineeringActivity;
GO

/* ---- drop in child-to-parent order -------------------------------------- */
DROP VIEW IF EXISTS dbo.vw_dq_latest, dbo.vw_dim_engineer, dbo.vw_escalations_monthly, dbo.vw_closed_by_month,
                    dbo.vw_engineer_load, dbo.vw_fact_escalation, dbo.vw_fact_timesheet,
                    dbo.vw_fact_activity_monthly, dbo.vw_fact_activity;
DROP TABLE IF EXISTS dbo.dq_check_results, dbo.etl_refresh_log, dbo.stg_refresh_info,
                     dbo.fact_escalation, dbo.fact_timesheet, dbo.activity_state_history,
                     dbo.fact_activity, dbo.dim_project, dbo.dim_engineer, dbo.dim_date,
                     dbo.dim_state, dbo.dim_location, dbo.dim_function, dbo.dim_platform, dbo.dim_unit;
GO

/* ---- dimensions ---------------------------------------------------------- */
CREATE TABLE dbo.dim_unit (
    unit_id         VARCHAR(5)     NOT NULL CONSTRAINT pk_dim_unit PRIMARY KEY,
    unit_name       NVARCHAR(60)   NOT NULL
);

CREATE TABLE dbo.dim_platform (
    platform_id     VARCHAR(10)    NOT NULL CONSTRAINT pk_dim_platform PRIMARY KEY,
    platform_name   NVARCHAR(60)   NOT NULL,
    unit_id         VARCHAR(5)     NOT NULL CONSTRAINT fk_platform_unit REFERENCES dbo.dim_unit (unit_id)
);

CREATE TABLE dbo.dim_function (
    function_id     VARCHAR(5)     NOT NULL CONSTRAINT pk_dim_function PRIMARY KEY,
    function_name   NVARCHAR(60)   NOT NULL,
    function_code   VARCHAR(5)     NOT NULL
);

CREATE TABLE dbo.dim_location (
    location_id     VARCHAR(5)     NOT NULL CONSTRAINT pk_dim_location PRIMARY KEY,
    location_name   NVARCHAR(60)   NOT NULL,
    country         NVARCHAR(40)   NOT NULL
);

CREATE TABLE dbo.dim_state (
    state           VARCHAR(20)    NOT NULL CONSTRAINT pk_dim_state PRIMARY KEY,
    state_order     TINYINT        NOT NULL,
    state_group     VARCHAR(20)    NOT NULL,   -- Pipeline / In Progress / Wrap-up / Closed
    is_open         BIT            NOT NULL
);

CREATE TABLE dbo.dim_date (
    date_key        INT            NOT NULL CONSTRAINT pk_dim_date PRIMARY KEY,   -- yyyymmdd
    [date]          DATE           NOT NULL CONSTRAINT uq_dim_date UNIQUE,
    [year]          SMALLINT       NOT NULL,
    month_num       TINYINT        NOT NULL,
    month_name      VARCHAR(10)    NOT NULL,
    month_short     CHAR(3)        NOT NULL,
    year_month      CHAR(7)        NOT NULL,   -- 2026-09
    month_start     DATE           NOT NULL,
    is_month_end    BIT            NOT NULL,
    fiscal_year     CHAR(6)        NOT NULL,   -- April-March, e.g. FY2027
    fiscal_month    TINYINT        NOT NULL,   -- 1 = April
    week_start      DATE           NOT NULL    -- Monday
);

CREATE TABLE dbo.dim_engineer (
    engineer_id          VARCHAR(5)    NOT NULL CONSTRAINT pk_dim_engineer PRIMARY KEY,
    engineer_name        NVARCHAR(80)  NOT NULL,
    home_function_id     VARCHAR(5)    NOT NULL CONSTRAINT fk_engineer_function REFERENCES dbo.dim_function (function_id),
    location_id          VARCHAR(5)    NOT NULL CONSTRAINT fk_engineer_location REFERENCES dbo.dim_location (location_id),
    [role]               VARCHAR(30)   NOT NULL,
    capacity_activities  TINYINT       NOT NULL,   -- in-flight activities one engineer can carry
    is_active            BIT           NOT NULL
);

CREATE TABLE dbo.dim_project (
    project_id          VARCHAR(6)     NOT NULL CONSTRAINT pk_dim_project PRIMARY KEY,
    project_title       NVARCHAR(120)  NOT NULL,
    unit_id             VARCHAR(5)     NOT NULL CONSTRAINT fk_project_unit REFERENCES dbo.dim_unit (unit_id),
    platform_id         VARCHAR(10)    NOT NULL CONSTRAINT fk_project_platform REFERENCES dbo.dim_platform (platform_id),
    project_start_date  DATE           NOT NULL
);

/* ---- facts --------------------------------------------------------------- */
-- Grain: one row per engineering activity (current state)
CREATE TABLE dbo.fact_activity (
    activity_id           VARCHAR(8)     NOT NULL CONSTRAINT pk_fact_activity PRIMARY KEY,
    project_id            VARCHAR(6)     NOT NULL CONSTRAINT fk_activity_project  REFERENCES dbo.dim_project (project_id),
    activity_title        NVARCHAR(120)  NOT NULL,
    function_id           VARCHAR(5)     NOT NULL CONSTRAINT fk_activity_function REFERENCES dbo.dim_function (function_id),
    activity_engineer_id  VARCHAR(5)     NOT NULL CONSTRAINT fk_activity_engineer REFERENCES dbo.dim_engineer (engineer_id),
    guide_approver_id     VARCHAR(5)     NULL     CONSTRAINT fk_activity_guide    REFERENCES dbo.dim_engineer (engineer_id),
    location_id           VARCHAR(5)     NOT NULL CONSTRAINT fk_activity_location REFERENCES dbo.dim_location (location_id),
    state                 VARCHAR(20)    NOT NULL CONSTRAINT fk_activity_state    REFERENCES dbo.dim_state (state),
    created_date          DATE           NOT NULL,
    start_date            DATE           NULL,     -- entered Active
    deadline_date         DATE           NULL,
    report_date           DATE           NULL,     -- entered Report
    closed_date           DATE           NULL,
    percent_complete      TINYINT        NULL CONSTRAINT ck_activity_pct CHECK (percent_complete BETWEEN 0 AND 100),
    planned_hours         SMALLINT       NULL,
    CONSTRAINT ck_activity_dates CHECK (closed_date IS NULL OR start_date IS NULL OR closed_date >= start_date)
);
CREATE INDEX ix_activity_engineer ON dbo.fact_activity (activity_engineer_id, state);
CREATE INDEX ix_activity_project  ON dbo.fact_activity (project_id);

-- Grain: one row per activity per state it has been in. valid_to is exclusive; NULL = current state
CREATE TABLE dbo.activity_state_history (
    activity_id   VARCHAR(8)   NOT NULL CONSTRAINT fk_history_activity REFERENCES dbo.fact_activity (activity_id),
    state         VARCHAR(20)  NOT NULL CONSTRAINT fk_history_state    REFERENCES dbo.dim_state (state),
    valid_from    DATE         NOT NULL,
    valid_to      DATE         NULL,
    CONSTRAINT pk_activity_state_history PRIMARY KEY (activity_id, valid_from)
);
CREATE INDEX ix_history_dates ON dbo.activity_state_history (valid_from, valid_to) INCLUDE (state);

-- Grain: one row per engineer per activity per week
CREATE TABLE dbo.fact_timesheet (
    timesheet_id  VARCHAR(8)    NOT NULL CONSTRAINT pk_fact_timesheet PRIMARY KEY,
    week_start    DATE          NOT NULL,
    engineer_id   VARCHAR(5)    NOT NULL CONSTRAINT fk_timesheet_engineer REFERENCES dbo.dim_engineer (engineer_id),
    activity_id   VARCHAR(8)    NOT NULL CONSTRAINT fk_timesheet_activity REFERENCES dbo.fact_activity (activity_id),
    hours         DECIMAL(4,1)  NOT NULL CONSTRAINT ck_timesheet_hours CHECK (hours > 0 AND hours <= 60)
);

-- Grain: one row per escalation raised on an activity
CREATE TABLE dbo.fact_escalation (
    escalation_id    VARCHAR(9)    NOT NULL CONSTRAINT pk_fact_escalation PRIMARY KEY,
    activity_id      VARCHAR(8)    NOT NULL CONSTRAINT fk_escalation_activity REFERENCES dbo.fact_activity (activity_id),
    escalation_date  DATE          NOT NULL,
    reason           VARCHAR(40)   NOT NULL,
    raised_by        VARCHAR(40)   NOT NULL
);

/* ---- control tables ------------------------------------------------------ */
CREATE TABLE dbo.etl_refresh_log (
    refresh_id         INT IDENTITY(1,1) CONSTRAINT pk_etl_refresh_log PRIMARY KEY,
    as_of_date         DATE          NOT NULL,
    dq_status          VARCHAR(10)   NOT NULL,
    activities_loaded  INT           NOT NULL,
    rows_quarantined   INT           NOT NULL,
    loaded_at          DATETIME2(0)  NOT NULL CONSTRAINT df_refresh_loaded_at DEFAULT SYSDATETIME()
);

CREATE TABLE dbo.dq_check_results (
    refresh_id     INT           NOT NULL CONSTRAINT fk_dq_refresh REFERENCES dbo.etl_refresh_log (refresh_id),
    as_of_date     DATE          NOT NULL,
    table_name     VARCHAR(40)   NOT NULL,
    check_name     VARCHAR(80)   NOT NULL,
    severity       VARCHAR(10)   NOT NULL,
    rows_affected  INT           NOT NULL,
    action         VARCHAR(120)  NOT NULL,
    status         VARCHAR(10)   NOT NULL
);

-- staging for the manual BULK INSERT path (02_load.sql)
CREATE TABLE dbo.stg_refresh_info (
    as_of_date        DATE         NOT NULL,
    dq_status         VARCHAR(10)  NOT NULL,
    clean_activities  INT          NOT NULL,
    rows_quarantined  INT          NOT NULL
);
GO
