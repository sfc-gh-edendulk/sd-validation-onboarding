# SNCF New SI Validation — Account Onboarding

Connect a new Snowflake account (any cloud, any org) to the SNCF validation data pipeline.

## What this does

Your account will receive real-time validation events (tap-in/tap-out from Flowbird and Conduent equipment) via Snowpipe auto-ingest from a shared AWS S3 bucket.

```
Concentrateur (simulated) → S3 → Lambda → Parquet → SNS → Your Snowpipe → Your table
```

## Prerequisites

- A Snowflake account with ACCOUNTADMIN access
- `snow` CLI configured with a connection to your account
- `conda` with the `crocevia` environment (or Python 3.11+ with `boto3`)
- AWS CLI access (profile `edd_aws_test`) — provided by the demo admin

## Quick Start

### 1. Run the Snowflake setup

Edit `sql/setup.sql` — set your SD name and database name at the top, then:

```bash
snow sql -f sql/setup.sql -c <YOUR_CONNECTION>
```

This creates: database, schema, storage integration, external stage, table, and Snowpipe.

### 2. Note the output from the last two queries

From `DESC INTEGRATION`:
- `STORAGE_AWS_IAM_USER_ARN` (e.g., `arn:aws:iam::640083578061:user/externalstages/abc123`)
- `STORAGE_AWS_EXTERNAL_ID` (e.g., `XX12345_SFCRole=2_someBase64String=`)

From `SYSTEM$GET_AWS_SNS_IAM_POLICY`:
- The `Principal.AWS` ARN (may differ from the one above)

### 3. Send these values to the pipeline admin

The admin will:
1. Create an IAM role in AWS with your storage integration's trust policy
2. Add your Snowpipe IAM user to the SNS topic policy

Or, if you have AWS access yourself:

```bash
export AWS_PROFILE=edd_aws_test
SD=SD3  # your SD identifier

# Create IAM role
aws iam create-role \
  --role-name sncf-validation-${SD,,}-snowflake-reader \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"AWS": "<STORAGE_AWS_IAM_USER_ARN>"},
      "Action": "sts:AssumeRole",
      "Condition": {"StringEquals": {"sts:ExternalId": "<STORAGE_AWS_EXTERNAL_ID>"}}
    }]
  }' \
  --tags Key=app_name,Value=sncf-new-si-validation Key=app_owner,Value=edendulk Key=app_env,Value=sesandbox Key=app_bu,Value=se

# Attach S3 read policy
aws iam put-role-policy \
  --role-name sncf-validation-${SD,,}-snowflake-reader \
  --policy-name s3-read \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:GetObjectVersion\"],\"Resource\":\"arn:aws:s3:::edendulksnow/transform/${SD}/*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\",\"s3:GetBucketLocation\"],\"Resource\":\"arn:aws:s3:::edendulksnow\",\"Condition\":{\"StringLike\":{\"s3:prefix\":[\"transform/${SD}/*\"]}}}
    ]
  }"

# Update SNS topic policy (add Snowpipe IAM user to AllowSnowflakeSubscribe)
# Get current policy:
aws sns get-topic-attributes \
  --topic-arn arn:aws:sns:us-west-2:484577546576:sncf-validation-ingest | jq -r '.Attributes.Policy'
# Add your Snowpipe IAM user ARN to the Principal array, then set it back.
```

### 4. Verify the connection

```bash
snow sql -c <YOUR_CONNECTION> -q "LIST @<DB>.RAW.VALIDATIONS_S3_STAGE;"
```

If you see files listed, the integration is working.

### 5. Generate test data

```bash
conda activate crocevia
AWS_PROFILE=edd_aws_test python scripts/generate_data.py --sd <YOUR_SD> --count 500
```

Wait 30 seconds, then:

```bash
snow sql -c <YOUR_CONNECTION> -q "SELECT COUNT(*) FROM <DB>.RAW.FACT_VALIDATIONS_PIPE;"
```

## Pipeline Details

| Component | Location |
|-----------|----------|
| S3 Bucket | `s3://edendulksnow` (us-west-2) |
| SNS Topic | `arn:aws:sns:us-west-2:484577546576:sncf-validation-ingest` |
| Lambda | `sncf-validation-protobuf-decoder` (us-west-2) |
| AWS Account | `484577546576` |

## Data Schema

| Column | Type | Description |
|--------|------|-------------|
| validation_id | STRING | Unique event ID |
| equipment_id | STRING | Equipment identifier (e.g., SD1-EQ-0042) |
| station_id | STRING | Station code (e.g., GDN, AUS) |
| ligne_id | STRING | Line (A-U) |
| validation_ts | TIMESTAMP_NTZ | Event timestamp |
| validation_date | DATE | Event date |
| media_type | STRING | NAVIGO, TICKET_T_PLUS, etc. |
| validation_result | STRING | VALIDATION, REFUS, FRAUDE |
| channel | STRING | ENTRY or EXIT |
| is_peak_hour | BOOLEAN | Peak hour flag |
| sd_id | STRING | SD identifier |
| equipment_type | STRING | Flowbird_MT, Conduent_CAB_MT, Conduent_M1R |

## Using Cortex Code CLI

You can ask Cortex Code to do all of this for you:

```
cortex "I need to onboard my Snowflake account to the SNCF validation pipeline.
My connection is <CONNECTION>, my SD is SD3. Follow the README steps."
```
