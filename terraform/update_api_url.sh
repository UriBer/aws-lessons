#!/bin/bash

# Determine the directory where the script is located (i.e., the terraform directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Assume the project root is one level up from the script directory
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Define paths relative to the project root
TERRAFORM_PATH="${PROJECT_ROOT}/terraform"
FRONTEND_PATH="${PROJECT_ROOT}/frontend"

# Get values from Terraform output
API_URL=$(terraform -chdir="${TERRAFORM_PATH}" output -raw api_url)
USER_POOL_ID=$(terraform -chdir="${TERRAFORM_PATH}" output -raw cognito_user_pool_id)
CLIENT_ID=$(terraform -chdir="${TERRAFORM_PATH}" output -raw cognito_client_id)
CLOUDFRONT_URL=$(terraform -chdir="${TERRAFORM_PATH}" output -raw cloudfront_url)
BUCKET_NAME=$(terraform -chdir="${TERRAFORM_PATH}" output -raw bucket_name)

if [ -z "$API_URL" ] || [ -z "$USER_POOL_ID" ] || [ -z "$CLIENT_ID" ] || [ -z "$CLOUDFRONT_URL" ] || [ -z "$BUCKET_NAME" ]; then
    echo "Missing one or more Terraform outputs (api_url, cognito_user_pool_id, cognito_client_id, cloudfront_url, bucket_name)"
    exit 1
fi

echo "API_URL: $API_URL"
echo "USER_POOL_ID: $USER_POOL_ID"
echo "CLIENT_ID: $CLIENT_ID"

# Extract domain name from the CloudFront URL (e.g., d1qqkzsgrf6nbh.cloudfront.net)
CLOUDFRONT_DOMAIN=$(echo "${CLOUDFRONT_URL}" | sed -e 's|^[^/]*//||' -e 's|/.*$||')

if [ -z "$CLOUDFRONT_DOMAIN" ]; then
    echo "Could not extract CloudFront domain from URL: $CLOUDFRONT_URL"
    exit 1
fi

# Update app.js, login.html, and index.html
# Use a cross-platform approach for in-place edits
replace_placeholder() {
  local file=$1 pattern=$2 value=$3
  sed -i.bak -e "s|${pattern}|${value}|g" "$file"
  rm -f "${file}.bak"
}

replace_placeholder "${FRONTEND_PATH}/app.js" "REPLACE_WITH_API_URL" "${API_URL}"
replace_placeholder "${FRONTEND_PATH}/app.js" "REPLACE_WITH_USER_POOL_ID" "${USER_POOL_ID}"
replace_placeholder "${FRONTEND_PATH}/app.js" "REPLACE_WITH_CLIENT_ID" "${CLIENT_ID}"

replace_placeholder "${FRONTEND_PATH}/login.html" "REPLACE_WITH_USER_POOL_ID" "${USER_POOL_ID}"
replace_placeholder "${FRONTEND_PATH}/login.html" "REPLACE_WITH_CLIENT_ID" "${CLIENT_ID}"

replace_placeholder "${FRONTEND_PATH}/index.html" "REPLACE_WITH_API_URL" "${API_URL}"
replace_placeholder "${FRONTEND_PATH}/index.html" "REPLACE_WITH_USER_POOL_ID" "${USER_POOL_ID}"
replace_placeholder "${FRONTEND_PATH}/index.html" "REPLACE_WITH_CLIENT_ID" "${CLIENT_ID}"

echo "Updated app.js, login.html, and index.html"

echo "Uploading files to bucket: ${BUCKET_NAME}"
# Use absolute paths for aws s3 cp
aws s3 cp "${FRONTEND_PATH}/index.html" "s3://${BUCKET_NAME}/index.html" --content-type text/html
aws s3 cp "${FRONTEND_PATH}/app.js" "s3://${BUCKET_NAME}/app.js" --content-type application/javascript
aws s3 cp "${FRONTEND_PATH}/login.html" "s3://${BUCKET_NAME}/login.html" --content-type text/html

echo "Files uploaded successfully."

# Check if CloudFront distribution exists in Terraform state before attempting invalidation
CLOUDFRONT_RESOURCE_EXISTS=$(terraform -chdir="${TERRAFORM_PATH}" state list aws_cloudfront_distribution.frontend 2>/dev/null)

if [ -n "$CLOUDFRONT_RESOURCE_EXISTS" ]; then
    # Get the actual Distribution ID
    DISTRIBUTION_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='${CLOUDFRONT_DOMAIN}'].Id" --output text 2>/dev/null)

    if [ -n "$DISTRIBUTION_ID" ]; then
        echo "Creating CloudFront invalidation for distribution: $DISTRIBUTION_ID"
        aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths "/*" >/dev/null || echo "CloudFront invalidation failed, but continuing."
    else
        echo "CloudFront distribution ID could not be determined, skipping invalidation."
    fi
else
    echo "CloudFront distribution 'aws_cloudfront_distribution.frontend' not found in Terraform state, skipping invalidation."
fi
