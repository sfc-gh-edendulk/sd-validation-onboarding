-- =============================================================================
-- pre_deploy.sql — Secure Data Share setup
-- SHARES are not supported by DEFINE — must run before snow dcm plan.
-- Run: snow sql -f pre_deploy.sql --connection <SD_ACCOUNT_CONNECTION>
--
-- ⚠️ No Jinja in companion scripts — replace variables with literal values:
--    Replace SD_DB with actual database name (e.g., SNCF_VALIDATION_SD3)
--    Replace SD_NAME with actual SD identifier (e.g., SD3)
--    Replace SD_CENTRAL_ACCOUNT with SFSENORTHAMERICA.HORIZON_LAB_AZURE_CONSUMER_EDD
-- =============================================================================

-- Replace placeholders below before running:
-- SD_DB              = SNCF_VALIDATION_SD3
-- SD_NAME            = SD3
-- SD_CENTRAL_ACCOUNT = SFSENORTHAMERICA.HORIZON_LAB_AZURE_CONSUMER_EDD

CREATE SHARE IF NOT EXISTS SNCF_SHARE_SD3;

GRANT USAGE ON DATABASE    SNCF_VALIDATION_SD3                        TO SHARE SNCF_SHARE_SD3;
GRANT USAGE ON SCHEMA      SNCF_VALIDATION_SD3.RAW                    TO SHARE SNCF_SHARE_SD3;
GRANT USAGE ON SCHEMA      SNCF_VALIDATION_SD3.ANALYTICS              TO SHARE SNCF_SHARE_SD3;
GRANT SELECT ON DYNAMIC TABLE SNCF_VALIDATION_SD3.ANALYTICS.KPI_DAILY TO SHARE SNCF_SHARE_SD3;
GRANT SELECT ON TABLE      SNCF_VALIDATION_SD3.RAW.DIM_STATIONS        TO SHARE SNCF_SHARE_SD3;
GRANT SELECT ON TABLE      SNCF_VALIDATION_SD3.RAW.DIM_EQUIPEMENTS     TO SHARE SNCF_SHARE_SD3;

ALTER SHARE SNCF_SHARE_SD3 ADD ACCOUNT = SFSENORTHAMERICA.HORIZON_LAB_AZURE_CONSUMER_EDD;
