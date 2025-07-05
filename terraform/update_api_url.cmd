@echo off
REM ---------------------------------------------------------------------------
REM  update_api_url.cmd - Sync placeholders, upload to S3, invalidate CloudFront
REM  Requires Terraform & AWS-CLI in PATH
REM  Works whether you launch it from project root, terraform folder or VS Code
REM ---------------------------------------------------------------------------

setlocal EnableDelayedExpansion
set ERRLEV=0

REM -- 1. Discover directories (same logic as bash) ----------------------------
set "SCRIPT_DIR=%~dp0"
for %%i in ("%SCRIPT_DIR%..") do set "PROJECT_ROOT=%%~fi"

set "TERRAFORM_PATH=%PROJECT_ROOT%\terraform"
set "FRONTEND_PATH=%PROJECT_ROOT%\frontend"

REM -- 2. Helper : function to read Terraform outputs -------------------------
for %%# in (api_url cognito_user_pool_id cognito_client_id cloudfront_url bucket_name) do call :GET_TF %%#

if not defined api_url            (echo [ERROR] api_url missing        & set ERRLEV=1)
if not defined cognito_user_pool_id (echo [ERROR] user pool id missing  & set ERRLEV=1)
if not defined cognito_client_id   (echo [ERROR] client id missing      & set ERRLEV=1)
if not defined cloudfront_url      (echo [ERROR] cloudfront url missing & set ERRLEV=1)
if not defined bucket_name         (echo [ERROR] bucket name missing    & set ERRLEV=1)
if %ERRLEV% NEQ 0 exit /b 1

echo API_URL      = %api_url%
echo USER_POOL_ID = %cognito_user_pool_id%
echo CLIENT_ID    = %cognito_client_id%
echo BUCKET_NAME  = %bucket_name%

REM -- 3. Extract CloudFront domain ------------------------------------------
set "TMP=%cloudfront_url:https://=%"
for /f "tokens=1 delims=/" %%d in ("%TMP%") do set "CLOUDFRONT_DOMAIN=%%d"
if not defined CLOUDFRONT_DOMAIN (
    echo [ERROR] Could not parse CloudFront domain from %cloudfront_url%
    exit /b 1
)

REM -- 4. Replace placeholders in frontend files ------------------------------
echo Updating placeholders...
call :PS_REPLACE "%FRONTEND_PATH%\app.js"    REPLACE_WITH_API_URL      "%api_url%"
call :PS_REPLACE "%FRONTEND_PATH%\app.js"    REPLACE_WITH_USER_POOL_ID "%cognito_user_pool_id%"
call :PS_REPLACE "%FRONTEND_PATH%\app.js"    REPLACE_WITH_CLIENT_ID    "%cognito_client_id%"

call :PS_REPLACE "%FRONTEND_PATH%\login.html" REPLACE_WITH_USER_POOL_ID "%cognito_user_pool_id%"
call :PS_REPLACE "%FRONTEND_PATH%\login.html" REPLACE_WITH_CLIENT_ID    "%cognito_client_id%"

call :PS_REPLACE "%FRONTEND_PATH%\index.html" REPLACE_WITH_API_URL      "%api_url%"
call :PS_REPLACE "%FRONTEND_PATH%\index.html" REPLACE_WITH_USER_POOL_ID "%cognito_user_pool_id%"
call :PS_REPLACE "%FRONTEND_PATH%\index.html" REPLACE_WITH_CLIENT_ID    "%cognito_client_id%"

echo Frontend files updated

REM -- 5. Upload to S3 --------------------------------------------------------
echo Uploading files to bucket %bucket_name%...
aws s3 cp "%FRONTEND_PATH%\index.html" "s3://%bucket_name%/index.html" --content-type text/html
aws s3 cp "%FRONTEND_PATH%\app.js"     "s3://%bucket_name%/app.js"     --content-type application/javascript
aws s3 cp "%FRONTEND_PATH%\login.html" "s3://%bucket_name%/login.html" --content-type text/html
echo Files uploaded

REM -- 6. CloudFront invalidation --------------------------------------------
for /f "usebackq tokens=*" %%k in (`terraform -chdir="%TERRAFORM_PATH%" state list aws_cloudfront_distribution.frontend 2^>nul`) do set "CF_STATE=%%k"

if defined CF_STATE (
    for /f "usebackq tokens=* delims=" %%j in (`aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='%CLOUDFRONT_DOMAIN%'].Id" --output text 2^>nul`) do set "DIST_ID=%%j"
    if defined DIST_ID (
        echo Creating CloudFront invalidation for %DIST_ID%...
        aws cloudfront create-invalidation --distribution-id %DIST_ID% --paths "/*" >nul
        echo CloudFront cache invalidated
    ) else (
        echo [WARN] Distribution ID could not be determined - skipping invalidation
    )
) else (
    echo CloudFront distribution not found in Terraform state - skipping invalidation
)

echo Done.
exit /b 0

REM -- Sub-routines -----------------------------------------------------------
:GET_TF
for /f "usebackq delims=" %%o in (`terraform -chdir="%TERRAFORM_PATH%" output -raw %1 2^>nul`) do set "%1=%%o"
goto :eof

:PS_REPLACE
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "(Get-Content -Path '%~1') -replace '%~2', '%~3' | Set-Content -Path '%~1'"
goto :eof

