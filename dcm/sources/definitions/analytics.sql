-- =============================================================================
-- analytics.sql — Dynamic Table KPI_DAILY (J-1 refresh)
-- Variables: SD_DB
-- =============================================================================

DEFINE DYNAMIC TABLE {{ SD_DB }}.ANALYTICS.KPI_DAILY
  TARGET_LAG = '1 day'
  WAREHOUSE = SNCF_VALIDATION_WH
  COMMENT = 'KPIs J-1 agrégés par date/ligne/gare — {{ SD_NAME }}'
AS
  SELECT
    v.validation_date                                                               AS kpi_date,
    v.sd_id,
    v.ligne_id,
    v.station_id,
    s.station_name,
    s.city,
    COUNT(*)                                                                        AS total_validations,
    SUM(CASE WHEN v.validation_result = 'REFUS'            THEN 1 ELSE 0 END)      AS nb_refus,
    SUM(CASE WHEN v.validation_result = 'FRAUDE_SUSPECTEE' THEN 1 ELSE 0 END)      AS nb_fraude,
    SUM(CASE WHEN v.validation_result = 'ERREUR_TECHNIQUE' THEN 1 ELSE 0 END)      AS nb_erreur,
    ROUND(SUM(CASE WHEN v.validation_result = 'REFUS' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS taux_refus,
    ROUND(SUM(CASE WHEN v.validation_result = 'FRAUDE_SUSPECTEE' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS taux_fraude,
    COUNT(DISTINCT v.equipment_id)                                                  AS nb_equipements_actifs,
    SUM(CASE WHEN v.is_peak_hour THEN 1 ELSE 0 END)                                AS validations_heure_pointe,
    ROUND(SUM(CASE WHEN v.is_peak_hour THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1)   AS pct_heure_pointe
  FROM {{ SD_DB }}.RAW.FACT_VALIDATIONS v
  LEFT JOIN {{ SD_DB }}.RAW.DIM_STATIONS s ON s.station_id = v.station_id
  GROUP BY 1, 2, 3, 4, 5, 6;
