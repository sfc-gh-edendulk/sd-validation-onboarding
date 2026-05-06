-- =============================================================================
-- infrastructure.sql — Database, Schemas, Warehouse
-- Variables: SD_DB, SD_NAME, WH_SIZE
-- =============================================================================

DEFINE DATABASE {{ SD_DB }}
  COMMENT = '{{ SD_NAME }} — New SI Validation';

DEFINE SCHEMA {{ SD_DB }}.RAW
  COMMENT = 'Données brutes de validation';

DEFINE SCHEMA {{ SD_DB }}.ANALYTICS
  COMMENT = 'KPIs et agrégats J-1';

DEFINE WAREHOUSE SNCF_VALIDATION_WH
  WITH WAREHOUSE_SIZE = '{{ WH_SIZE }}'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  COMMENT = 'SNCF New SI Validation warehouse';
