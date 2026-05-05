-- =============================================================================
-- setup.sql — Snowflake objects for SNCF Validation ingestion pipeline
--
-- Run this in your Snowflake account with ACCOUNTADMIN role.
-- Replace <SD_NAME> and <DB_NAME> with your values (e.g., SD3, SNCF_VALIDATION_SD3)
-- =============================================================================

SET SD_NAME = 'SD3';                -- Change this
SET DB_NAME = 'SNCF_VALIDATION_SD3'; -- Change this
SET PREFIX = 'transform/' || $SD_NAME || '/';
SET ROLE_NAME = 'sncf-validation-' || LOWER($SD_NAME) || '-snowflake-reader';

-- 1. Database + Schema
CREATE DATABASE IF NOT EXISTS IDENTIFIER($DB_NAME);
CREATE SCHEMA IF NOT EXISTS IDENTIFIER($DB_NAME || '.RAW');

-- 2. Storage Integration
-- After creation, run: DESC INTEGRATION SNCF_S3_INGESTION;
-- Record STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID
CREATE STORAGE INTEGRATION IF NOT EXISTS SNCF_S3_INGESTION
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::484577546576:role/' || $ROLE_NAME
  STORAGE_ALLOWED_LOCATIONS = ('s3://edendulksnow/' || $PREFIX);

-- 3. External Stage
USE DATABASE IDENTIFIER($DB_NAME);
USE SCHEMA RAW;

CREATE STAGE IF NOT EXISTS VALIDATIONS_S3_STAGE
  STORAGE_INTEGRATION = SNCF_S3_INGESTION
  URL = 's3://edendulksnow/' || $PREFIX
  FILE_FORMAT = (TYPE = PARQUET);

-- 4. Target Table
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

-- 5. Snowpipe (auto-ingest via SNS)
CREATE PIPE IF NOT EXISTS VALIDATIONS_SNOWPIPE
  AUTO_INGEST = TRUE
  AWS_SNS_TOPIC = 'arn:aws:sns:us-west-2:484577546576:sncf-validation-ingest'
  AS
  COPY INTO FACT_VALIDATIONS_PIPE (
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
    FROM @VALIDATIONS_S3_STAGE
  )
  FILE_FORMAT = (TYPE = PARQUET);

-- 6. Get identifiers needed for AWS setup
DESC INTEGRATION SNCF_S3_INGESTION;
SELECT SYSTEM$GET_AWS_SNS_IAM_POLICY('arn:aws:sns:us-west-2:484577546576:sncf-validation-ingest');
