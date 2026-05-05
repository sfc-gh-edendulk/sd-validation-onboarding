#!/usr/bin/env python3
"""
generate_data.py — Simulates Flowbird/Conduent concentrateur Protobuf output.

Generates realistic validation event batches and uploads them as .pb files
to s3://edendulksnow/landing/{sd}/.

Usage:
    python scripts/generate_data.py --sd SD1 --count 5000
    python scripts/generate_data.py --sd SD2 --count 5000
    python scripts/generate_data.py --sd ALL --count 10000
"""

import argparse
import random
import time
import uuid
import sys
import os
from datetime import datetime, timezone, timedelta

import boto3

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "proto"))
from validation_codec import encode_batch

BUCKET = "edendulksnow"
LANDING_PREFIX = "landing"

SD1_LIGNES = ["H", "J", "K", "L", "N", "P"]
SD2_LIGNES = ["B", "C", "D", "R", "U"]

SD1_STATIONS = {
    "H": ["GDN", "CPL", "CRL", "STD", "ENL"],
    "J": ["GLZ", "MNT", "PSY", "MAS"],
    "K": ["GDN"],
    "L": ["GLZ", "CRY", "VRC", "PRF", "NAT"],
    "N": ["MTG", "RAM"],
    "P": ["GDN"],
}

SD2_STATIONS = {
    "B": ["BFR", "CDG1", "CDG2", "MAS2", "ANT"],
    "C": ["AUS", "VPT", "JUV"],
    "D": ["GLY", "ORL", "CRB", "VLN", "MLS"],
    "R": ["GLY"],
    "U": ["LVR", "DEF"],
}

EQUIPMENT_TYPES = {
    "SD1": ["Flowbird_MT", "Conduent_CAB_MT", "Conduent_M1R"],
    "SD2": ["Flowbird_MT", "Conduent_CAB_MT", "Conduent_M1R"],
}

MEDIA_TYPES = ["NAVIGO", "NAVIGO_EASY", "TICKET_T_PLUS", "IMAGINE_R", "MOBILIS", "TICKET_OD"]
RESULTS = ["VALIDATION", "VALIDATION", "VALIDATION", "VALIDATION", "VALIDATION",
           "VALIDATION", "VALIDATION", "VALIDATION", "REFUS", "FRAUDE"]
CHANNELS = ["ENTRY", "EXIT"]

PEAK_HOURS = {7, 8, 9, 17, 18, 19}


def generate_events(sd: str, count: int, base_time: datetime) -> list[dict]:
    if sd == "SD1":
        lignes = SD1_LIGNES
        stations = SD1_STATIONS
    else:
        lignes = SD2_LIGNES
        stations = SD2_STATIONS

    eq_types = EQUIPMENT_TYPES[sd]
    events = []

    for _ in range(count):
        ligne = random.choice(lignes)
        station = random.choice(stations[ligne])
        hour = random.choices(
            range(5, 24),
            weights=[1 if h not in PEAK_HOURS else 4 for h in range(5, 24)],
            k=1,
        )[0]
        minute = random.randint(0, 59)
        second = random.randint(0, 59)

        jitter_days = random.randint(0, 0)
        ts = base_time.replace(hour=hour, minute=minute, second=second) - timedelta(days=jitter_days)
        ts_ms = int(ts.timestamp() * 1000)

        eq_type = random.choice(eq_types)
        eq_num = random.randint(1, 150)
        eq_id = f"{sd}-EQ-{eq_num:04d}"

        events.append({
            "validation_id": str(uuid.uuid4())[:12],
            "equipment_id": eq_id,
            "station_id": station,
            "ligne_id": ligne,
            "timestamp_ms": ts_ms,
            "media_type": random.choice(MEDIA_TYPES),
            "result": random.choice(RESULTS),
            "channel": random.choice(CHANNELS),
            "equipment_type": eq_type,
        })

    return events


def upload_batch(s3_client, sd: str, batch_data: bytes, batch_id: str):
    now = datetime.now(timezone.utc)
    key = f"{LANDING_PREFIX}/{sd}/{now.strftime('%Y%m%d_%H%M%S')}_{batch_id}.pb"
    s3_client.put_object(Bucket=BUCKET, Key=key, Body=batch_data)
    print(f"  Uploaded s3://{BUCKET}/{key} ({len(batch_data)} bytes)")
    return key


def main():
    parser = argparse.ArgumentParser(description="SNCF Validation Data Generator")
    parser.add_argument("--sd", choices=["SD1", "SD2", "ALL"], default="ALL",
                        help="Which SD to generate data for (default: ALL)")
    parser.add_argument("--count", type=int, default=1000,
                        help="Number of events per SD (default: 1000)")
    parser.add_argument("--batch-size", type=int, default=500,
                        help="Events per .pb file (default: 500)")
    parser.add_argument("--date", type=str, default=None,
                        help="Base date YYYY-MM-DD (default: yesterday)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Generate but don't upload")
    args = parser.parse_args()

    if args.date:
        base_time = datetime.strptime(args.date, "%Y-%m-%d").replace(
            hour=12, tzinfo=timezone.utc
        )
    else:
        base_time = datetime.now(timezone.utc) - timedelta(days=1)

    sds = ["SD1", "SD2"] if args.sd == "ALL" else [args.sd]
    s3 = boto3.client("s3", region_name="us-west-2")

    for sd in sds:
        print(f"\n=== Generating {args.count} events for {sd} (date: {base_time.date()}) ===")
        events = generate_events(sd, args.count, base_time)

        for i in range(0, len(events), args.batch_size):
            batch_events = events[i:i + args.batch_size]
            batch_id = f"{sd}-{uuid.uuid4().hex[:8]}"
            batch_data = encode_batch(
                sd_id=sd,
                batch_id=batch_id,
                generated_at_ms=int(time.time() * 1000),
                events=batch_events,
            )
            if args.dry_run:
                print(f"  [dry-run] Batch {batch_id}: {len(batch_events)} events, {len(batch_data)} bytes")
            else:
                upload_batch(s3, sd, batch_data, batch_id)

    print("\nDone!")


if __name__ == "__main__":
    main()
