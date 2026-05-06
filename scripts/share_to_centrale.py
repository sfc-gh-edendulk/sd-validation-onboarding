#!/usr/bin/env python3
"""
share_to_centrale.py -- Load KPI data from this SD into ORG CENTRALE.

For cross-org sharing (different Snowflake organizations), direct data sharing
is not supported. This script reads aggregated KPI data from the SD account and
inserts it into the CENTRALE account via executemany.

Usage:
    python scripts/share_to_centrale.py --sd-connection sncftrial --sd SD3
    python scripts/share_to_centrale.py --sd-connection sncftrial --sd SD3 --centrale-connection CURSOR-AZURE_NETHERLANDS
"""

import argparse
import os
import sys

import snowflake.connector
import pandas as pd


def get_conn(connection_name: str):
    return snowflake.connector.connect(
        connection_name=os.getenv("SNOWFLAKE_CONNECTION_NAME") or connection_name
    )


def query_df(conn, sql: str) -> pd.DataFrame:
    cur = conn.cursor()
    cur.execute(sql)
    cols = [d[0].lower() for d in cur.description]
    return pd.DataFrame(cur.fetchall(), columns=cols)


def bulk_insert(conn, df: pd.DataFrame, table: str):
    cur = conn.cursor()
    cols = ", ".join(df.columns)
    placeholders = ", ".join(["%s"] * len(df.columns))
    rows = [tuple(r) for r in df.itertuples(index=False)]

    batch_size = 500
    for i in range(0, len(rows), batch_size):
        batch = rows[i:i + batch_size]
        cur.executemany(
            f"INSERT INTO {table} ({cols}) VALUES ({placeholders})", batch
        )
        sys.stdout.write(f"\r  {min(i + batch_size, len(rows))}/{len(rows)} rows")
        sys.stdout.flush()
    print()
    return len(rows)


def main():
    parser = argparse.ArgumentParser(description="Share SD data to CENTRALE")
    parser.add_argument("--sd-connection", required=True,
                        help="Snow CLI connection name for this SD account")
    parser.add_argument("--sd", required=True,
                        help="SD identifier (e.g., SD3)")
    parser.add_argument("--centrale-connection", default="CURSOR-AZURE_NETHERLANDS",
                        help="Snow CLI connection for CENTRALE (default: CURSOR-AZURE_NETHERLANDS)")
    parser.add_argument("--sd-db", default=None,
                        help="SD database name (default: SNCF_VALIDATION_<SD>)")
    args = parser.parse_args()

    sd_db = args.sd_db or f"SNCF_VALIDATION_{args.sd}"

    print(f"Connecting to SD account ({args.sd_connection})...")
    conn_sd = snowflake.connector.connect(connection_name=args.sd_connection)

    print(f"Connecting to CENTRALE ({args.centrale_connection})...")
    conn_c = snowflake.connector.connect(connection_name=args.centrale_connection)

    print(f"\n1. Fetching KPI data from {sd_db}.ANALYTICS.KPI_DAILY...")
    kpi_sql = f"""
        SELECT kpi_date, sd_id, ligne_id, station_id, station_name, city,
               total_validations, nb_refus, nb_fraude, nb_erreur,
               taux_refus, taux_fraude, nb_equipements_actifs
        FROM {sd_db}.ANALYTICS.KPI_DAILY
    """
    df_kpi = query_df(conn_sd, kpi_sql)
    df_kpi["sd_name"] = f"SD {args.sd}"
    print(f"   {len(df_kpi)} rows fetched")

    if df_kpi.empty:
        print("   No KPI data found. Ensure the Dynamic Table has refreshed.")
        print("   Try: snow sql -c {} -q \"ALTER DYNAMIC TABLE {}.ANALYTICS.KPI_DAILY REFRESH;\"".format(
            args.sd_connection, sd_db))
        conn_sd.close()
        conn_c.close()
        return

    print("\n2. Loading into SNCF_CENTRAL.ANALYTICS.FACT_CONSOLIDATED...")
    cur_c = conn_c.cursor()
    cur_c.execute("USE DATABASE SNCF_CENTRAL")
    cur_c.execute("USE SCHEMA ANALYTICS")

    cur_c.execute(f"DELETE FROM FACT_CONSOLIDATED WHERE sd_id = '{args.sd}'")
    print(f"   Cleared existing {args.sd} rows from FACT_CONSOLIDATED")

    n = bulk_insert(conn_c, df_kpi, "FACT_CONSOLIDATED")
    print(f"   Loaded {n} rows into SNCF_CENTRAL.ANALYTICS.FACT_CONSOLIDATED")

    print("\n3. Verifying...")
    cur_c.execute(f"SELECT COUNT(*) FROM FACT_CONSOLIDATED WHERE sd_id = '{args.sd}'")
    count = cur_c.fetchone()[0]
    print(f"   CENTRALE now has {count} rows for {args.sd}")

    conn_sd.close()
    conn_c.close()
    print("\nDone! Data shared to CENTRALE successfully.")


if __name__ == "__main__":
    main()
