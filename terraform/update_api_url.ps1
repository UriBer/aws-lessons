<#
.SYNOPSIS
    Sync frontend placeholders with Terraform outputs,
    upload to S3 and (optionally) invalidate CloudFront.

.EXAMPLE
    PS> .\update_api_url.ps1 -Verbose -Debug
#>

[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------
# 1. Discover directories  (same logic as the Bash script)
# ----------------------------
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot  = Split-Path $ScriptDir -Parent
$TerraformDir = Join-Path $ProjectRoot 'terraform'
$FrontendDir  = Join-Path $ProjectRoot 'frontend'

Write-Debug "ScriptDir    : $ScriptDir"
Write-Debug "ProjectRoot  : $ProjectRoot"
Write-Debug "TerraformDir : $TerraformDir"
Write-Debug "FrontendDir  : $FrontendDir"

# ----------------------------
# 2. Read Terraform outputs
# ----------------------------
function TFOut([string]$Name) {
    & terraform -chdir=$TerraformDir output -raw $Name 2>$null
}

$API_URL      = TFOut 'api_url'
$USER_POOL_ID = TFOut 'cognito_user_pool_id'
$CLIENT_ID    = TFOut 'cognito_client_id'
$CLOUDFRONT_URL = TFOut 'cloudfront_url'
$BUCKET_NAME  = TFOut 'bucket_name'

if (-not ($API_URL -and $USER_POOL_ID -and $CLIENT_ID -and $CLOUDFRONT_URL -and $BUCKET_NAME)) {
    throw 'Missing one or more Terraform outputs (api_url, cognito_user_pool_id, cognito_client_id, cloudfront_url, bucket_name).'
}

Write-Verbose "API_URL      = $API_URL"
Write-Verbose "USER_POOL_ID = $USER_POOL_ID"
Write-Verbose "CLIENT_ID    = $CLIENT_ID"
Write-Verbose "BUCKET_NAME  = $BUCKET_NAME"

# Extract CloudFront domain (remove protocol and any trailing slash)
$CLOUDFRONT_DOMAIN = ($CLOUDFRONT_URL -replace '^https?://', '') -replace '/.*$',''
if (-not $CLOUDFRONT_DOMAIN) {
    throw "Could not extract CloudFront domain from URL: $CLOUDFRONT_URL"
}
Write-Debug "CloudFront domain = $CLOUDFRONT_DOMAIN"

# ----------------------------
# 3. Replace placeholders in app.js, login.html and index.html
# ----------------------------
function Replace-InFile ($Path, [hashtable]$Map) {
    Write-Verbose "Updating $(Split-Path $Path -Leaf)"
    $Content = Get-Content $Path -Raw
    foreach ($Key in $Map.Keys) {
        $Content = $Content -replace $Key, $Map[$Key]
    }
    Set-Content $Path $Content -NoNewline
}

$appJs   = Join-Path $FrontendDir 'app.js'
$login   = Join-Path $FrontendDir 'login.html'
$index   = Join-Path $FrontendDir 'index.html'

Replace-InFile $appJs @{
    'REPLACE_WITH_API_URL'      = $API_URL
    'REPLACE_WITH_USER_POOL_ID' = $USER_POOL_ID
    'REPLACE_WITH_CLIENT_ID'    = $CLIENT_ID
}
Replace-InFile $login @{
    'REPLACE_WITH_USER_POOL_ID' = $USER_POOL_ID
    'REPLACE_WITH_CLIENT_ID'    = $CLIENT_ID
}
Replace-InFile $index @{
    'REPLACE_WITH_API_URL'      = $API_URL
    'REPLACE_WITH_USER_POOL_ID' = $USER_POOL_ID
    'REPLACE_WITH_CLIENT_ID'    = $CLIENT_ID
}
Write-Host 'Frontend files updated.'

# ----------------------------
# 4. Upload to S3
# ----------------------------
Write-Host "Uploading files to bucket: $BUCKET_NAME"
aws s3 cp $index "s3://$BUCKET_NAME/index.html" --content-type text/html
aws s3 cp $appJs "s3://$BUCKET_NAME/app.js"     --content-type application/javascript
aws s3 cp $login "s3://$BUCKET_NAME/login.html" --content-type text/html
Write-Host 'Files uploaded.'

# ----------------------------
# 5. CloudFront invalidation (only if resource exists in state)
# ----------------------------
$cfState = & terraform -chdir=$TerraformDir state list aws_cloudfront_distribution.frontend 2>$null
if ($cfState) {
    $DistId = aws cloudfront list-distributions `
        --query "DistributionList.Items[?DomainName=='$CLOUDFRONT_DOMAIN'].Id" `
        --output text 2>$null
    if ($DistId) {
        Write-Host "Creating CloudFront invalidation for distribution: $DistId"
        aws cloudfront create-invalidation --distribution-id $DistId --paths '/*' | Write-Debug
        Write-Host 'CloudFront cache invalidated.'
    } else {
        Write-Warning 'CloudFront distribution ID could not be determined, skipping invalidation.'
    }
} else {
    Write-Verbose 'aws_cloudfront_distribution.frontend not found in Terraform state - skipping invalidation.'
}

Write-Host ''
Write-Host 'Static site is now synced with latest Terraform outputs.' -ForegroundColor Green
