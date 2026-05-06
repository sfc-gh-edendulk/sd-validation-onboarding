-- =============================================================================
-- tables.sql — Reference & fact tables
-- Variables: SD_DB, SD_NAME
-- =============================================================================

DEFINE TABLE {{ SD_DB }}.RAW.DIM_STATIONS (
  station_id          STRING  NOT NULL,
  station_name        STRING,
  ligne_id            STRING,
  city                STRING,
  nb_equipements      NUMBER,
  flux_journalier_moyen NUMBER,
  PRIMARY KEY (station_id)
)
COMMENT = 'Référentiel des gares {{ SD_NAME }}';

DEFINE TABLE {{ SD_DB }}.RAW.DIM_EQUIPEMENTS (
  equipment_id        STRING  NOT NULL,
  equipment_model     STRING,
  equipment_type      STRING,
  station_id          STRING,
  equipment_status    STRING,
  last_maintenance_dt TIMESTAMP_NTZ,
  installation_year   NUMBER,
  sd_id               STRING  DEFAULT '{{ SD_NAME }}',
  PRIMARY KEY (equipment_id)
)
COMMENT = 'Équipements Flowbird / Conduent {{ SD_NAME }}';

DEFINE TABLE {{ SD_DB }}.RAW.DIM_LIGNES (
  ligne_id    STRING NOT NULL,
  ligne_name  STRING,
  sd_id       STRING DEFAULT '{{ SD_NAME }}',
  PRIMARY KEY (ligne_id)
)
COMMENT = 'Lignes Transilien opérées par {{ SD_NAME }}';

DEFINE TABLE {{ SD_DB }}.RAW.FACT_VALIDATIONS (
  validation_id   STRING NOT NULL,
  equipment_id    STRING,
  station_id      STRING,
  ligne_id        STRING,
  validation_ts   TIMESTAMP_NTZ,
  validation_date DATE,
  media_type      STRING,
  validation_result STRING,
  channel         STRING,
  is_peak_hour    BOOLEAN,
  sd_id           STRING DEFAULT '{{ SD_NAME }}'
)
CLUSTER BY (validation_date, ligne_id)
COMMENT = 'Événements de validation {{ SD_NAME }}';
