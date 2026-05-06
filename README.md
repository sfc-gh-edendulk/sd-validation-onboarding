# SNCF New SI Validation — SD Onboarding Kit

Connect a new Snowflake account (any cloud, any org) to the SNCF validation data pipeline.

## What you get

After deployment, your account receives real-time validation events from the shared AWS pipeline:

```
Concentrateur (Flowbird/Conduent) → S3 → Lambda → Parquet → SNS → Your Snowpipe → Your table
```

Plus:
- Streamlit dashboard showing your SD's validation KPIs
- Dynamic Table KPI_DAILY with J-1 aggregation
- Data sharing back to ORG CENTRALE
- DCM (Database Change Management) templates for infrastructure-as-code

## Prerequisites

- Snowflake account with **ACCOUNTADMIN** access
- `snow` CLI installed and configured with a connection to your account
- AWS CLI access (profile `edd_aws_test`) — provided by the pipeline admin
- Python 3.11+ with `boto3` (use `conda activate crocevia` or `pip install boto3`)

## Quick Deploy (one command)

```bash
./scripts/deploy.sh --sd SD3 --connection sncftrial --aws-profile edd_aws_test
```

This creates everything: database, schemas, storage integration, IAM role, SNS subscription, stage, table, Snowpipe, generates test data, and verifies.

## Ask Cortex Code to do it

```
cortex "Deploy the SNCF validation pipeline to my account.
Connection: sncftrial, SD: SD3, AWS profile: edd_aws_test.
Run: ./scripts/deploy.sh --sd SD3 --connection sncftrial --aws-profile edd_aws_test
Then run the Streamlit app and share data to CENTRALE."
```

## Manual Steps (if deploy.sh fails)

All commands use `snow sql -c <YOUR_CONNECTION>`:

### 1. Edit and run sql/setup.sql

Replace all occurrences of `SD3` and `SNCF_VALIDATION_SD3` with your values, then:

```bash
snow sql -f sql/setup.sql -c sncftrial
```

### 2. Create AWS IAM role

The setup.sql output gives you two values needed for AWS:
- `STORAGE_AWS_IAM_USER_ARN` (from `DESC INTEGRATION`)
- Snowpipe IAM user (from `SYSTEM$GET_AWS_SNS_IAM_POLICY`)

```bash
export AWS_PROFILE=edd_aws_test

aws iam create-role \
  --role-name sncf-validation-sd3-snowflake-reader \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"AWS": "<STORAGE_AWS_IAM_USER_ARN>"},
      "Action": "sts:AssumeRole",
      "Condition": {"StringEquals": {"sts:ExternalId": "<EXTERNAL_ID>"}}
    }]
  }' \
  --tags Key=app_name,Value=sncf-new-si-validation Key=app_owner,Value=edendulk Key=app_env,Value=sesandbox Key=app_bu,Value=se

aws iam put-role-policy \
  --role-name sncf-validation-sd3-snowflake-reader \
  --policy-name s3-read \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {"Effect":"Allow","Action":["s3:GetObject","s3:GetObjectVersion"],"Resource":"arn:aws:s3:::edendulksnow/transform/SD3/*"},
      {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":"arn:aws:s3:::edendulksnow","Condition":{"StringLike":{"s3:prefix":["transform/SD3/*"]}}}
    ]
  }'
```

### 3. Update SNS topic policy

Add the Snowpipe IAM user to the AllowSnowflakeSubscribe statement on:
`arn:aws:sns:us-west-2:484577546576:sncf-validation-ingest`

### 4. Re-run the Snowpipe creation (if it failed in step 1)

The pipe creation may fail if the IAM role didn't exist yet. After step 2-3, re-run just the pipe section from setup.sql.

### 5. Verify

```bash
snow sql -c sncftrial -q "LIST @SNCF_VALIDATION_SD3.RAW.VALIDATIONS_S3_STAGE;"
```

## Generate Data

```bash
AWS_PROFILE=edd_aws_test python scripts/generate_data.py --sd SD3 --count 1000
```

Wait 30 seconds for Lambda + Snowpipe, then:

```bash
snow sql -c sncftrial -q "SELECT COUNT(*) FROM SNCF_VALIDATION_SD3.RAW.FACT_VALIDATIONS_PIPE;"
```

## Run Streamlit Dashboard

```bash
SNOWFLAKE_CONNECTION_NAME=sncftrial streamlit run app/streamlit_app.py
```

## Share Data to CENTRALE (cross-org)

Since your account may be in a different org than CENTRALE, use the Python loader:

```bash
python scripts/share_to_centrale.py --sd-connection sncftrial --sd SD3
```

This reads your `KPI_DAILY` Dynamic Table and inserts into `SNCF_CENTRAL.ANALYTICS.FACT_CONSOLIDATED`.

For **same-org** accounts: uncomment the `ALTER SHARE` line in `sql/setup.sql` instead.

## DCM (Infrastructure-as-Code)

For reproducible deployments, use the DCM templates:

```bash
# Edit dcm/manifest.yml with your account + SD values, then:
snow dcm plan --target sd_new
snow dcm deploy --target sd_new
```

## Pipeline Details

| Component | Value |
|-----------|-------|
| S3 Bucket | `s3://edendulksnow` (us-west-2) |
| SNS Topic | `arn:aws:sns:us-west-2:484577546576:sncf-validation-ingest` |
| Lambda | `sncf-validation-protobuf-decoder` |
| AWS Account | `484577546576` |

## Data Schema (FACT_VALIDATIONS_PIPE)

| Column | Type | Description |
|--------|------|-------------|
| validation_id | STRING | Unique event ID |
| equipment_id | STRING | Equipment (e.g., SD3-EQ-0042) |
| station_id | STRING | Station code |
| ligne_id | STRING | Transit line |
| validation_ts | TIMESTAMP_NTZ | Event timestamp |
| validation_date | DATE | Event date |
| media_type | STRING | NAVIGO, TICKET_T_PLUS, etc. |
| validation_result | STRING | VALIDATION, REFUS, FRAUDE |
| channel | STRING | ENTRY or EXIT |
| is_peak_hour | BOOLEAN | Peak hour flag |
| sd_id | STRING | SD identifier |
| equipment_type | STRING | Flowbird_MT, Conduent_CAB_MT, Conduent_M1R |
