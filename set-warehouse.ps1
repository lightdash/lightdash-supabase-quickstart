#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# Sets the warehouse connection credentials on an existing Lightdash project
# via the API -- no UI required.
#
# Prerequisites:
#   - lightdash login has been run (or LIGHTDASH_API_KEY is set)
#   - lightdash deploy --create has been run (project exists)
#   - .env exists with DB_HOST, DB_PORT, DB_USER, DB_PASS, DB_NAME, DB_SSL_MODE

function Write-Info    { param([string]$Msg) Write-Host "[>] $Msg" -ForegroundColor Cyan }
function Write-Success { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-Warn    { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-Die     { param([string]$Msg) Write-Host "[x] $Msg" -ForegroundColor Red; exit 1 }

$LIGHTDASH_URL = "https://app.lightdash.cloud"

Write-Host ""
Write-Host "Set Lightdash Warehouse Connection" -ForegroundColor White
Write-Host "========================================="
Write-Host ""

# -- load .env -----------------------------------------------------------------
if (Test-Path ".env") {
    $envVars = @{}
    Get-Content ".env" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') {
            $envVars[$Matches[1]] = $Matches[2]
        }
    }
    $DB_HOST  = $envVars['DB_HOST']
    $DB_PORT  = $envVars['DB_PORT']
    $DB_USER  = $envVars['DB_USER']
    $DB_PASS  = $envVars['DB_PASS']
    $DB_NAME  = $envVars['DB_NAME']
    $SSL_MODE = $envVars['DB_SSL_MODE']
    Write-Success ".env loaded"
} else {
    Write-Die ".env not found. Run setup.ps1 first."
}

foreach ($var in @('DB_HOST','DB_PORT','DB_USER','DB_PASS','DB_NAME')) {
    if ([string]::IsNullOrWhiteSpace((Get-Variable -Name ($var -replace '^DB_','DB_') -ValueOnly -ErrorAction SilentlyContinue))) {
        Write-Die "$var not set in .env"
    }
}
if ([string]::IsNullOrWhiteSpace($SSL_MODE)) { $SSL_MODE = "no-verify" }

Write-Host ""

# -- project uuid --------------------------------------------------------------
Write-Info "Reading active Lightdash project..."

$PROJECT_UUID = $env:LIGHTDASH_PROJECT

if ([string]::IsNullOrWhiteSpace($PROJECT_UUID) -and (Get-Command lightdash -ErrorAction SilentlyContinue)) {
    try {
        $projectOutput = & lightdash config get-project 2>$null
        if ($projectOutput -match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') {
            $PROJECT_UUID = $Matches[0]
        }
    } catch { }
}

if ([string]::IsNullOrWhiteSpace($PROJECT_UUID)) {
    Write-Warn "Could not detect project UUID automatically."
    Write-Host "  Find it in your Lightdash URL: $LIGHTDASH_URL/projects/YOUR-UUID/..."
    Write-Host ""
    $PROJECT_UUID = Read-Host "  Paste project UUID"
    if ([string]::IsNullOrWhiteSpace($PROJECT_UUID)) { Write-Die "Project UUID required." }
}

Write-Success "Project UUID: $PROJECT_UUID"
Write-Host ""

# -- auth token ----------------------------------------------------------------
Write-Info "Looking for Lightdash auth token..."

$LIGHTDASH_TOKEN = $env:LIGHTDASH_API_KEY

# Try config.yaml (written by lightdash login)
if ([string]::IsNullOrWhiteSpace($LIGHTDASH_TOKEN)) {
    $cliCfg = Join-Path $HOME ".config\lightdash\config.yaml"
    if (Test-Path $cliCfg) {
        $yamlContent = Get-Content $cliCfg -Raw
        if ($yamlContent -match '(?m)^\s*apiKey:\s*"?([^"\s]+)"?') {
            $LIGHTDASH_TOKEN = $Matches[1]
            Write-Success "Token found in $cliCfg"
        }
    }
}

# Fallback: JSON config locations (older CLI versions)
if ([string]::IsNullOrWhiteSpace($LIGHTDASH_TOKEN)) {
    $configPaths = @(
        (Join-Path $HOME ".config\lightdash-cli\config.json"),
        (Join-Path $env:APPDATA "lightdash-cli\config.json")
    )
    foreach ($cfg in $configPaths) {
        if (Test-Path $cfg) {
            $jsonContent = Get-Content $cfg -Raw
            if ($jsonContent -match '"(?:token|apiKey)"\s*:\s*"([^"]+)"') {
                $LIGHTDASH_TOKEN = $Matches[1]
                Write-Success "Token found in $cfg"
                break
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($LIGHTDASH_TOKEN)) {
    Write-Warn "No token found automatically."
    Write-Host "  Create one at: $LIGHTDASH_URL/settings/personal-access-tokens"
    Write-Host ""
    $tokenSecure = Read-Host "  Paste token" -AsSecureString
    $LIGHTDASH_TOKEN = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenSecure)
    )
    if ([string]::IsNullOrWhiteSpace($LIGHTDASH_TOKEN)) { Write-Die "Token required." }
}

Write-Host ""

# -- api call ------------------------------------------------------------------
Write-Info "Setting warehouse credentials on project $PROJECT_UUID..."
Write-Host "  Host:    ${DB_HOST}:${DB_PORT}"
Write-Host "  DB:      $DB_NAME"
Write-Host "  User:    $DB_USER"
Write-Host "  SSL:     $SSL_MODE"
Write-Host ""

$body = @{
    warehouseConnection = @{
        type     = "postgres"
        host     = $DB_HOST
        user     = $DB_USER
        password = $DB_PASS
        port     = [int]$DB_PORT
        dbname   = $DB_NAME
        schema   = "public"
        sslmode  = $SSL_MODE
    }
} | ConvertTo-Json -Depth 3

$headers = @{
    "Authorization" = "ApiKey $LIGHTDASH_TOKEN"
    "Content-Type"  = "application/json"
}

try {
    $response = Invoke-RestMethod `
        -Uri "$LIGHTDASH_URL/api/v1/projects/$PROJECT_UUID/warehouse-credentials" `
        -Method Put `
        -Headers $headers `
        -Body $body

    if ($response.status -eq "ok") {
        Write-Success "Done! Warehouse credentials set - no UI step needed."
        Write-Host ""
        Write-Host "  Run a query in Lightdash to verify the connection:"
        Write-Host "  $LIGHTDASH_URL/projects/$PROJECT_UUID/tables"
    } else {
        throw "Unexpected response status: $($response.status)"
    }
} catch {
    $errMsg = $_.Exception.Message
    $statusCode = ""
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }

    Write-Host ""
    if ($statusCode) {
        Write-Warn "API returned HTTP $statusCode."
    } else {
        Write-Warn "API request failed: $errMsg"
    }
    Write-Host ""
    Write-Host "  Common causes:"
    Write-Host "    401 - token is wrong or expired (regenerate at /settings/personal-access-tokens)"
    Write-Host "    403 - token doesn't have project admin permissions"
    Write-Host "    404 - project UUID is wrong"
    Write-Host ""
    Write-Host "  Set credentials manually instead:"
    Write-Host "  $LIGHTDASH_URL > gear > Project Settings > warehouse connection form"
    Write-Host "    Host:     $DB_HOST"
    Write-Host "    Port:     $DB_PORT"
    Write-Host "    Database: $DB_NAME"
    Write-Host "    User:     $DB_USER"
    Write-Host "    Password: (from .env)"
    Write-Host "    Advanced > SSL mode: $SSL_MODE"
    Write-Host ""
    Write-Host "  Note: use the Session/Transaction Pooler host from Supabase > Connect"
    Write-Host "  NOT the Direct connection host (db.xxxx.supabase.co)"
    exit 1
}
