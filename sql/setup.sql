-- =============================================================================
-- setup.sql -- Snowflake objects for SNCF Validation ingestion pipeline
--
-- USAGE:
--   1. Replace SD3 with your SD identifier everywhere in this file
--   2. Replace SNCF_VALIDATION_SD3 with your database name
--   3. Run: snow sql -f sql/setup.sql -c <YOUR_CONNECTION>
--
-- After running, execute the two queries at the bottom and send the output
-- to the pipeline admin (or use it in deploy.sh).
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- 1. Database + Schema
CREATE DATABASE IF NOT EXISTS SNCF_VALIDATION_SD3;
CREATE SCHEMA IF NOT EXISTS SNCF_VALIDATION_SD3.RAW;
CREATE SCHEMA IF NOT EXISTS SNCF_VALIDATION_SD3.ANALYTICS;

-- 2. Warehouse
CREATE WAREHOUSE IF NOT EXISTS SNCF_VALIDATION_WH
  WITH WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

-- 3. Storage Integration (cross-cloud S3 access)
CREATE STORAGE INTEGRATION IF NOT EXISTS SNCF_S3_INGESTION
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::484577546576:role/sncf-validation-sd3-snowflake-reader'
  STORAGE_ALLOWED_LOCATIONS = ('s3://edendulksnow/transform/SD3/');

-- 4. External Stage
USE DATABASE SNCF_VALIDATION_SD3;
USE SCHEMA RAW;

CREATE STAGE IF NOT EXISTS VALIDATIONS_S3_STAGE
  STORAGE_INTEGRATION = SNCF_S3_INGESTION
  URL = 's3://edendulksnow/transform/SD3/'
  FILE_FORMAT = (TYPE = PARQUET);

-- 5. Target Tables
CREATE TABLE IF NOT EXISTS FACT_VALIDATIONS_PIPE (
  validation_id     STRING,
  equipment_id      STRING,
  station_id        STRING,
  ligne_id          STRING,
  validation_ts     TIMESTAMP_NTZ,
  validation_date   DATE,
  media_type        STRING,
  validation_result STRING,
  channel           STRING,
  is_peak_hour      BOOLEAN,
  sd_id             STRING,
  equipment_type    STRING,
  _loaded_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS DIM_LIGNES (
  ligne_id   STRING NOT NULL,
  ligne_name STRING,
  sd_id      STRING DEFAULT 'SD3',
  PRIMARY KEY (ligne_id)
);

CREATE TABLE IF NOT EXISTS DIM_STATIONS (
  station_id          STRING NOT NULL,
  station_name        STRING,
  ligne_id            STRING,
  city                STRING,
  nb_equipements      NUMBER,
  flux_journalier_moyen NUMBER,
  PRIMARY KEY (station_id)
);

CREATE TABLE IF NOT EXISTS DIM_EQUIPEMENTS (
  equipment_id    STRING NOT NULL,
  equipment_model STRING,
  equipment_type  STRING,
  station_id      STRING,
  equipment_status STRING,
  installation_year NUMBER,
  sd_id           STRING DEFAULT 'SD3',
  PRIMARY KEY (equipment_id)
);

-- 6. Dynamic Table KPI_DAILY (J-1 aggregation)
USE SCHEMA ANALYTICS;

CREATE OR REPLACE DYNAMIC TABLE KPI_DAILY
  TARGET_LAG = '1 day'
  WAREHOUSE = SNCF_VALIDATION_WH
AS
  SELECT
    v.validation_date AS kpi_date,
    v.sd_id,
    v.ligne_id,
    v.station_id,
    s.station_name,
    s.city,
    COUNT(*) AS total_validations,
    SUM(CASE WHEN v.validation_result = 'REFUS' THEN 1 ELSE 0 END) AS nb_refus,
    SUM(CASE WHEN v.validation_result = 'FRAUDE' THEN 1 ELSE 0 END) AS nb_fraude,
    SUM(CASE WHEN v.validation_result NOT IN ('VALIDATION','REFUS','FRAUDE') THEN 1 ELSE 0 END) AS nb_erreur,
    ROUND(SUM(CASE WHEN v.validation_result = 'REFUS' THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(*),0), 2) AS taux_refus,
    ROUND(SUM(CASE WHEN v.validation_result = 'FRAUDE' THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(*),0), 2) AS taux_fraude,
    COUNT(DISTINCT v.equipment_id) AS nb_equipements_actifs
  FROM SNCF_VALIDATION_SD3.RAW.FACT_VALIDATIONS_PIPE v
  LEFT JOIN SNCF_VALIDATION_SD3.RAW.DIM_STATIONS s ON s.station_id = v.station_id
  GROUP BY 1, 2, 3, 4, 5, 6;

-- 7. Snowpipe (auto-ingest via SNS) -- will fail until AWS IAM role exists
--    Run deploy.sh to create the IAM role first, then re-run this section.
USE SCHEMA RAW;

CREATE PIPE IF NOT EXISTS VALIDATIONS_SNOWPIPE
  AUTO_INGEST = TRUE
  AWS_SNS_TOPIC = 'arn:aws:sns:us-west-2:484577546576:sncf-validation-ingest'
  AS
  COPY INTO SNCF_VALIDATION_SD3.RAW.FACT_VALIDATIONS_PIPE (
    validation_id, equipment_id, station_id, ligne_id,
    validation_ts, validation_date, media_type,
    validation_result, channel, is_peak_hour, sd_id, equipment_type
  )
  FROM (
    SELECT
      $1:validation_id::STRING,
      $1:equipment_id::STRING,
      $1:station_id::STRING,
      $1:ligne_id::STRING,
      $1:validation_ts::TIMESTAMP_NTZ,
      $1:validation_date::DATE,
      $1:media_type::STRING,
      $1:validation_result::STRING,
      $1:channel::STRING,
      $1:is_peak_hour::BOOLEAN,
      $1:sd_id::STRING,
      $1:equipment_type::STRING
    FROM @SNCF_VALIDATION_SD3.RAW.VALIDATIONS_S3_STAGE
  )
  FILE_FORMAT = (TYPE = PARQUET);

-- 8. Secure Data Share to CENTRALE (same-org only)
--    For cross-org sharing, use scripts/share_to_centrale.py instead.
CREATE SHARE IF NOT EXISTS SNCF_SHARE_SD3;
GRANT USAGE ON DATABASE SNCF_VALIDATION_SD3 TO SHARE SNCF_SHARE_SD3;
GRANT USAGE ON SCHEMA SNCF_VALIDATION_SD3.RAW TO SHARE SNCF_SHARE_SD3;
GRANT USAGE ON SCHEMA SNCF_VALIDATION_SD3.ANALYTICS TO SHARE SNCF_SHARE_SD3;
GRANT SELECT ON DYNAMIC TABLE SNCF_VALIDATION_SD3.ANALYTICS.KPI_DAILY TO SHARE SNCF_SHARE_SD3;
GRANT SELECT ON TABLE SNCF_VALIDATION_SD3.RAW.DIM_STATIONS TO SHARE SNCF_SHARE_SD3;
GRANT SELECT ON TABLE SNCF_VALIDATION_SD3.RAW.DIM_EQUIPEMENTS TO SHARE SNCF_SHARE_SD3;
-- Uncomment and set account if same org:
-- ALTER SHARE SNCF_SHARE_SD3 ADD ACCOUNT = SFSENORTHAMERICA.HORIZON_LAB_AZURE_CONSUMER_EDD;

-- =============================================================================
-- 9. OUTPUT THESE VALUES -- needed for AWS IAM setup
-- =============================================================================
DESC INTEGRATION SNCF_S3_INGESTION;
SELECT SYSTEM$GET_AWS_SNS_IAM_POLICY('arn:aws:sns:us-west-2:484577546576:sncf-validation-ingest');
