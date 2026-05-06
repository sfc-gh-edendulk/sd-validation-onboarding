import streamlit as st
import pandas as pd
import plotly.express as px
import os

try:
    from snowflake.snowpark.context import get_active_session
    _session = get_active_session()
    _SIS = True
except Exception:
    import snowflake.connector
    _SIS = False

st.set_page_config(page_title="SNCF Validation — SD Dashboard", page_icon="🚉", layout="wide")

st.markdown("""
<style>
    [data-testid="stAppViewContainer"] { background-color: #f5f6fa; }
    .sncf-header {
        background: linear-gradient(135deg, #1a1a2e 0%, #002d6e 60%, #c8102e 100%);
        padding: 1.8rem 2.5rem; border-radius: 12px; margin-bottom: 1.5rem; color: white;
    }
    .sncf-header h1 { color: white; margin: 0; font-size: 2rem; font-weight: 700; }
    .sncf-header p { color: #aac4f0; margin: 0.4rem 0 0 0; }
</style>
""", unsafe_allow_html=True)


@st.cache_resource
def get_conn():
    if _SIS:
        return _session
    conn_name = os.getenv("SNOWFLAKE_CONNECTION_NAME", "sncftrial")
    return snowflake.connector.connect(connection_name=conn_name)


@st.cache_data(ttl=300)
def query(sql: str) -> pd.DataFrame:
    conn = get_conn()
    if _SIS:
        return conn.sql(sql).to_pandas()
    return pd.read_sql(sql, conn)


st.markdown("""
<div class="sncf-header">
    <h1>🚉 SNCF New SI Validation</h1>
    <p>Tableau de bord opérationnel — Société Dédiée</p>
</div>
""", unsafe_allow_html=True)

try:
    df_count = query("SELECT COUNT(*) AS cnt FROM RAW.FACT_VALIDATIONS_PIPE")
    total_events = int(df_count["CNT"].iloc[0]) if not df_count.empty else 0
except Exception:
    total_events = 0

if total_events == 0:
    st.warning("Aucune donnée dans FACT_VALIDATIONS_PIPE. Lancez `generate_data.py` pour alimenter la pipeline.")
    st.stop()

col1, col2, col3, col4 = st.columns(4)

df_summary = query("""
    SELECT
        COUNT(*) AS total,
        COUNT(DISTINCT validation_date) AS nb_jours,
        COUNT(DISTINCT ligne_id) AS nb_lignes,
        SUM(CASE WHEN validation_result = 'REFUS' THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS taux_refus
    FROM RAW.FACT_VALIDATIONS_PIPE
""")

if not df_summary.empty:
    col1.metric("Total validations", f"{int(df_summary['TOTAL'].iloc[0]):,}")
    col2.metric("Jours de données", int(df_summary['NB_JOURS'].iloc[0]))
    col3.metric("Lignes actives", int(df_summary['NB_LIGNES'].iloc[0]))
    col4.metric("Taux de refus", f"{df_summary['TAUX_REFUS'].iloc[0]:.1f}%")

st.divider()

tab1, tab2, tab3 = st.tabs(["Volume journalier", "Répartition par ligne", "Types d'équipement"])

with tab1:
    df_daily = query("""
        SELECT validation_date, COUNT(*) AS validations,
               SUM(CASE WHEN validation_result='REFUS' THEN 1 ELSE 0 END) AS refus
        FROM RAW.FACT_VALIDATIONS_PIPE
        GROUP BY validation_date ORDER BY validation_date
    """)
    if not df_daily.empty:
        fig = px.bar(df_daily, x="VALIDATION_DATE", y="VALIDATIONS",
                     title="Validations par jour", labels={"VALIDATION_DATE": "Date", "VALIDATIONS": "Volume"})
        fig.add_scatter(x=df_daily["VALIDATION_DATE"], y=df_daily["REFUS"], name="Refus", mode="lines+markers")
        st.plotly_chart(fig, use_container_width=True)

with tab2:
    df_ligne = query("""
        SELECT ligne_id, COUNT(*) AS validations,
               ROUND(SUM(CASE WHEN validation_result='REFUS' THEN 1 ELSE 0 END)*100.0/COUNT(*),1) AS taux_refus
        FROM RAW.FACT_VALIDATIONS_PIPE GROUP BY ligne_id ORDER BY validations DESC
    """)
    if not df_ligne.empty:
        fig = px.bar(df_ligne, x="LIGNE_ID", y="VALIDATIONS", color="TAUX_REFUS",
                     title="Volume par ligne", color_continuous_scale="RdYlGn_r",
                     labels={"LIGNE_ID": "Ligne", "VALIDATIONS": "Volume", "TAUX_REFUS": "% Refus"})
        st.plotly_chart(fig, use_container_width=True)

with tab3:
    df_eq = query("""
        SELECT equipment_type, COUNT(*) AS validations
        FROM RAW.FACT_VALIDATIONS_PIPE GROUP BY equipment_type
    """)
    if not df_eq.empty:
        fig = px.pie(df_eq, values="VALIDATIONS", names="EQUIPMENT_TYPE",
                     title="Répartition par type d'équipement")
        st.plotly_chart(fig, use_container_width=True)

st.divider()
st.subheader("Derniers événements")
df_recent = query("""
    SELECT validation_id, equipment_id, station_id, ligne_id,
           validation_ts, validation_result, equipment_type
    FROM RAW.FACT_VALIDATIONS_PIPE
    ORDER BY validation_ts DESC LIMIT 20
""")
if not df_recent.empty:
    st.dataframe(df_recent, use_container_width=True, hide_index=True)

with st.sidebar:
    st.markdown("### Pipeline Status")
    pipe_status = query("SELECT SYSTEM$PIPE_STATUS('RAW.VALIDATIONS_SNOWPIPE') AS status")
    if not pipe_status.empty:
        st.code(pipe_status["STATUS"].iloc[0], language="json")

    st.markdown("---")
    st.markdown("### Export CSV")
    if st.button("Télécharger les données"):
        df_export = query("SELECT * FROM RAW.FACT_VALIDATIONS_PIPE")
        st.download_button("Download", df_export.to_csv(index=False), "validations.csv", "text/csv")
