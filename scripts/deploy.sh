#!/bin/bash
# =============================================================================
# deploy.sh -- End-to-end deployment of SNCF validation pipeline to a new account
#
# Prerequisites:
#   - snow CLI configured with a connection to the target account
#   - AWS CLI with the edd_aws_test profile (or whoever owns edendulksnow)
#   - conda env with boto3 (crocevia)
#
# Usage:
#   ./scripts/deploy.sh --sd SD3 --connection sncftrial --aws-profile edd_aws_test
# =============================================================================
set -euo pipefail

SD=""
CONNECTION=""
AWS_PROFILE_NAME="edd_aws_test"
DB=""
COUNT=500

while [[ $# -gt 0 ]]; do
  case $1 in
    --sd) SD="$2"; shift 2 ;;
    --connection|-c) CONNECTION="$2"; shift 2 ;;
    --aws-profile) AWS_PROFILE_NAME="$2"; shift 2 ;;
    --db) DB="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$SD" || -z "$CONNECTION" ]]; then
  echo "Usage: ./scripts/deploy.sh --sd <SD_NAME> --connection <SNOW_CONNECTION>"
  echo "  --sd          SD identifier (e.g., SD3)"
  echo "  --connection  Snow CLI connection name"
  echo "  --aws-profile AWS CLI profile (default: edd_aws_test)"
  echo "  --db          Database name (default: SNCF_VALIDATION_<SD>)"
  echo "  --count       Test events to generate (default: 500)"
  exit 1
fi

DB="${DB:-SNCF_VALIDATION_${SD}}"
SD_LOWER=$(echo "$SD" | tr '[:upper:]' '[:lower:]')
ROLE_NAME="sncf-validation-${SD_LOWER}-snowflake-reader"
SNS_TOPIC="arn:aws:sns:us-west-2:484577546576:sncf-validation-ingest"
BUCKET="edendulksnow"

echo "=============================================="
echo " SNCF Validation Pipeline — Deploy ${SD}"
echo "=============================================="
echo " Connection: ${CONNECTION}"
echo " Database:   ${DB}"
echo " IAM Role:   ${ROLE_NAME}"
echo "=============================================="
echo ""

# ── Step 1: Create Snowflake objects ──────────────────────────────────────────
echo ">>> Step 1: Creating Snowflake objects..."

snow sql -c "$CONNECTION" -q "USE ROLE ACCOUNTADMIN; CREATE DATABASE IF NOT EXISTS ${DB};"
snow sql -c "$CONNECTION" -q "CREATE SCHEMA IF NOT EXISTS ${DB}.RAW;"
snow sql -c "$CONNECTION" -q "CREATE SCHEMA IF NOT EXISTS ${DB}.ANALYTICS;"
snow sql -c "$CONNECTION" -q "CREATE WAREHOUSE IF NOT EXISTS SNCF_VALIDATION_WH WITH WAREHOUSE_SIZE='XSMALL' AUTO_SUSPEND=60 AUTO_RESUME=TRUE;"

echo "    Created DB, schemas, warehouse."

# ── Step 2: Storage Integration ───────────────────────────────────────────────
echo ">>> Step 2: Creating storage integration..."

snow sql -c "$CONNECTION" -q "
CREATE STORAGE INTEGRATION IF NOT EXISTS SNCF_S3_INGESTION
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::484577546576:role/${ROLE_NAME}'
  STORAGE_ALLOWED_LOCATIONS = ('s3://${BUCKET}/transform/${SD}/');
"

# ── Step 3: Get Snowflake IAM identifiers ─────────────────────────────────────
echo ">>> Step 3: Getting Snowflake IAM identifiers..."

INTEGRATION_DESC=$(snow sql -c "$CONNECTION" -q "DESC INTEGRATION SNCF_S3_INGESTION;" 2>&1)
SF_IAM_USER=$(echo "$INTEGRATION_DESC" | grep -A1 "STORAGE_AWS_IAM_USE" | grep -oE "arn:aws:iam::[0-9]+:user/[^ |]+" | head -1)
SF_EXTERNAL_ID=$(echo "$INTEGRATION_DESC" | grep -A1 "STORAGE_AWS_EXTERNA" | grep -oP "(?<=\| )[A-Z0-9].*(?= \|)" | tail -1 | xargs)

SNS_POLICY=$(snow sql -c "$CONNECTION" -q "SELECT SYSTEM\$GET_AWS_SNS_IAM_POLICY('${SNS_TOPIC}');" 2>&1)
SNOWPIPE_IAM=$(echo "$SNS_POLICY" | grep -oE "arn:aws:iam::[0-9]+:user/[^\"]+" | head -1)

echo "    Storage IAM User: ${SF_IAM_USER}"
echo "    External ID:      ${SF_EXTERNAL_ID}"
echo "    Snowpipe IAM:     ${SNOWPIPE_IAM}"

if [[ -z "$SF_IAM_USER" || -z "$SF_EXTERNAL_ID" ]]; then
  echo "ERROR: Could not extract IAM identifiers from DESC INTEGRATION output."
  echo "Full output:"
  echo "$INTEGRATION_DESC"
  exit 1
fi

# ── Step 4: Create AWS IAM Role ───────────────────────────────────────────────
echo ">>> Step 4: Creating AWS IAM role..."

export AWS_PROFILE="$AWS_PROFILE_NAME"

aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {\"AWS\": \"${SF_IAM_USER}\"},
      \"Action\": \"sts:AssumeRole\",
      \"Condition\": {\"StringEquals\": {\"sts:ExternalId\": \"${SF_EXTERNAL_ID}\"}}
    }]
  }" \
  --tags Key=app_name,Value=sncf-new-si-validation Key=app_owner,Value=edendulk Key=app_env,Value=sesandbox Key=app_bu,Value=se \
  2>/dev/null || echo "    (Role may already exist, continuing...)"

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "s3-read-${SD_LOWER}" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:GetObjectVersion\"],\"Resource\":\"arn:aws:s3:::${BUCKET}/transform/${SD}/*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\",\"s3:GetBucketLocation\"],\"Resource\":\"arn:aws:s3:::${BUCKET}\",\"Condition\":{\"StringLike\":{\"s3:prefix\":[\"transform/${SD}/*\"]}}}
    ]
  }"

echo "    IAM role created + S3 policy attached."

# ── Step 5: Update SNS topic policy ──────────────────────────────────────────
echo ">>> Step 5: Updating SNS topic policy..."

CURRENT_POLICY=$(aws sns get-topic-attributes --topic-arn "$SNS_TOPIC" --output json 2>&1 | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data['Attributes']['Policy'])
")

UPDATED_POLICY=$(echo "$CURRENT_POLICY" | python3 -c "
import json, sys
policy = json.loads(sys.stdin.read())
new_arn = '${SNOWPIPE_IAM}'
for stmt in policy['Statement']:
    if stmt.get('Sid') == 'AllowSnowflakeSubscribe':
        principals = stmt['Principal']['AWS']
        if isinstance(principals, str):
            principals = [principals]
        if new_arn not in principals:
            principals.append(new_arn)
        stmt['Principal']['AWS'] = principals
        break
else:
    policy['Statement'].append({
        'Sid': 'AllowSnowflakeSubscribe',
        'Effect': 'Allow',
        'Principal': {'AWS': [new_arn]},
        'Action': ['sns:Subscribe'],
        'Resource': '${SNS_TOPIC}'
    })
print(json.dumps(policy))
")

aws sns set-topic-attributes \
  --topic-arn "$SNS_TOPIC" \
  --attribute-name Policy \
  --attribute-value "$UPDATED_POLICY"

echo "    SNS policy updated."

# ── Step 6: Create Stage, Table, Pipe ─────────────────────────────────────────
echo ">>> Step 6: Creating stage, table, and Snowpipe..."

snow sql -c "$CONNECTION" -q "
USE DATABASE ${DB}; USE SCHEMA RAW;
CREATE STAGE IF NOT EXISTS VALIDATIONS_S3_STAGE
  STORAGE_INTEGRATION = SNCF_S3_INGESTION
  URL = 's3://${BUCKET}/transform/${SD}/'
  FILE_FORMAT = (TYPE = PARQUET);
"

snow sql -c "$CONNECTION" -q "
USE DATABASE ${DB}; USE SCHEMA RAW;
CREATE TABLE IF NOT EXISTS FACT_VALIDATIONS_PIPE (
  validation_id STRING, equipment_id STRING, station_id STRING,
  ligne_id STRING, validation_ts TIMESTAMP_NTZ, validation_date DATE,
  media_type STRING, validation_result STRING, channel STRING,
  is_peak_hour BOOLEAN, sd_id STRING, equipment_type STRING,
  _loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
"

snow sql -c "$CONNECTION" -q "
USE DATABASE ${DB}; USE SCHEMA RAW;
CREATE PIPE IF NOT EXISTS VALIDATIONS_SNOWPIPE
  AUTO_INGEST = TRUE
  AWS_SNS_TOPIC = '${SNS_TOPIC}'
  AS
  COPY INTO ${DB}.RAW.FACT_VALIDATIONS_PIPE (
    validation_id, equipment_id, station_id, ligne_id,
    validation_ts, validation_date, media_type,
    validation_result, channel, is_peak_hour, sd_id, equipment_type
  )
  FROM (SELECT
    \$1:validation_id::STRING, \$1:equipment_id::STRING,
    \$1:station_id::STRING, \$1:ligne_id::STRING,
    \$1:validation_ts::TIMESTAMP_NTZ, \$1:validation_date::DATE,
    \$1:media_type::STRING, \$1:validation_result::STRING,
    \$1:channel::STRING, \$1:is_peak_hour::BOOLEAN,
    \$1:sd_id::STRING, \$1:equipment_type::STRING
  FROM @${DB}.RAW.VALIDATIONS_S3_STAGE)
  FILE_FORMAT = (TYPE = PARQUET);
"

echo "    Stage, table, and pipe created."

# ── Step 7: Generate test data ────────────────────────────────────────────────
echo ">>> Step 7: Generating ${COUNT} test events..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "${SCRIPT_DIR}/generate_data.py" --sd "$SD" --count "$COUNT"

echo "    Waiting 30s for Lambda + Snowpipe..."
sleep 30

# ── Step 8: Verify ────────────────────────────────────────────────────────────
echo ">>> Step 8: Verifying..."

RESULT=$(snow sql -c "$CONNECTION" -q "SELECT COUNT(*) AS cnt FROM ${DB}.RAW.FACT_VALIDATIONS_PIPE;" 2>&1)
echo "$RESULT"

echo ""
echo "=============================================="
echo " DEPLOYMENT COMPLETE"
echo "=============================================="
echo " Database:  ${DB}"
echo " Table:     ${DB}.RAW.FACT_VALIDATIONS_PIPE"
echo " Snowpipe:  ${DB}.RAW.VALIDATIONS_SNOWPIPE"
echo " Stage:     ${DB}.RAW.VALIDATIONS_S3_STAGE"
echo ""
echo " To run Streamlit:"
echo "   SNOWFLAKE_CONNECTION_NAME=${CONNECTION} streamlit run app/streamlit_app.py"
echo ""
echo " To share data to CENTRALE (cross-org):"
echo "   python scripts/share_to_centrale.py --sd-connection ${CONNECTION} --sd ${SD}"
echo "=============================================="
