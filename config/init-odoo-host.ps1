# Odoo Database Initialization Script for Host/IDE Execution (Windows PowerShell)
# This script initializes Odoo when running from the IDE (not in Docker)
# It connects to the database running in docker-compose-db-only.yml
#
# Prerequisites:
# - Docker container 'odoo19-db-only' must be running (from docker-compose-db-only.yml)
# - Odoo must be installed/available in the current environment
# - Database must be accessible at localhost:5433
# - PowerShell 5.1 or later

$ErrorActionPreference = "Stop"

# Get the script directory and project root
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$PROJECT_ROOT = Split-Path -Parent $SCRIPT_DIR

# Load environment variables from .env file if it exists
$envFile = Join-Path $PROJECT_ROOT ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]*?)\s*=\s*(.*?)\s*$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            # Remove quotes if present
            if ($value -match '^["''](.*)["'']$') {
                $value = $matches[1]
            }
            [Environment]::SetEnvironmentVariable($key, $value, "Process")
        }
    }
}

# Configuration with defaults
$DB_NAME = if ($env:DB_NAME) { $env:DB_NAME } else { "odoo" }
$DB_HOST = if ($env:DB_HOST) { $env:DB_HOST } else { "localhost" }
$DB_PORT = if ($env:DB_PORT) { $env:DB_PORT } else { "5433" }
$DB_USER = if ($env:DB_USER) { $env:DB_USER } else { "odoo" }
$DB_PASSWORD = if ($env:DB_PASSWORD) { $env:DB_PASSWORD } else { "odoo" }
$INIT_FLAG_FILE = Join-Path $PROJECT_ROOT ".odoo_initialized"
$ODOO_CONFIG_FILE = Join-Path $SCRIPT_DIR "odoo.conf"
$ODOO_BIN = Join-Path $PROJECT_ROOT "odoo-bin"

# Set default addons paths if not set
$ODOO_CUSTOM_ADDONS_PATH = if ($env:ODOO_CUSTOM_ADDONS_PATH) { 
    $env:ODOO_CUSTOM_ADDONS_PATH 
} else { 
    Join-Path $PROJECT_ROOT "custom-addons" 
}
$ODOO_ENTERPRISE_ADDONS_PATH = if ($env:ODOO_ENTERPRISE_ADDONS_PATH) { 
    $env:ODOO_ENTERPRISE_ADDONS_PATH 
} else { 
    Join-Path (Split-Path -Parent $PROJECT_ROOT) "enterprise-19.0" 
}

# Export variables for environment substitution
$env:ODOO_CUSTOM_ADDONS_PATH = $ODOO_CUSTOM_ADDONS_PATH
$env:ODOO_ENTERPRISE_ADDONS_PATH = $ODOO_ENTERPRISE_ADDONS_PATH

Write-Host "=== Odoo Database Initialization Script (Host/IDE) ===" -ForegroundColor Cyan
Write-Host "Database name: $DB_NAME"
Write-Host "Database host: $DB_HOST`:$DB_PORT"
Write-Host "Project root: $PROJECT_ROOT"

# Check if Odoo binary exists
if (-not (Test-Path $ODOO_BIN)) {
    Write-Host "✗ ERROR: Odoo binary not found at $ODOO_BIN" -ForegroundColor Red
    Write-Host "  Make sure you're running this from the Odoo project root."
    exit 1
}

# Check if Docker container is running
$dockerContainers = docker ps --format '{{.Names}}' 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ ERROR: Failed to check Docker containers. Is Docker running?" -ForegroundColor Red
    exit 1
}

$containerRunning = $dockerContainers -match "^odoo19-db-only$"
if (-not $containerRunning) {
    Write-Host "✗ ERROR: Docker container 'odoo19-db-only' is not running." -ForegroundColor Red
    Write-Host "  Please start it with: docker-compose -f docker-compose-db-only.yml up -d"
    exit 1
}

# Check if initialization flag file exists
if (Test-Path $INIT_FLAG_FILE) {
    Write-Host "✓ Odoo database is already initialized (flag file exists). Skipping initialization." -ForegroundColor Green
    exit 0
}

# Wait for database to be ready using Python (no psql dependency)
Write-Host "Waiting for database to be fully ready..."
$MAX_RETRIES = 30
$RETRY_COUNT = 0
$dbReady = $false

while ($RETRY_COUNT -lt $MAX_RETRIES) {
    $pythonCheck = @"
import sys
try:
    import psycopg2
    conn = psycopg2.connect(
        host='$DB_HOST',
        port=$DB_PORT,
        user='$DB_USER',
        password='$DB_PASSWORD',
        database='postgres',
        connect_timeout=2
    )
    conn.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
"@
    
    $pythonCheck | python3 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Database is ready." -ForegroundColor Green
        $dbReady = $true
        break
    }
    
    $RETRY_COUNT++
    if ($RETRY_COUNT -eq $MAX_RETRIES) {
        Write-Host "✗ ERROR: Database is not ready after $MAX_RETRIES attempts." -ForegroundColor Red
        Write-Host "  Please check that the database container is running and healthy."
        exit 1
    }
    Write-Host "  Waiting for database... (attempt $RETRY_COUNT/$MAX_RETRIES)"
    Start-Sleep -Seconds 2
}

# Wait a bit more to ensure database is fully ready
Start-Sleep -Seconds 2

Write-Host "Attempting Odoo database initialization..."

# Expand environment variables in config file
# Create a temporary config file with expanded variables
$EXPANDED_CONFIG = [System.IO.Path]::GetTempFileName()

if (Test-Path $ODOO_CONFIG_FILE) {
    $configContent = Get-Content $ODOO_CONFIG_FILE -Raw
    # Replace environment variables
    $configContent = $configContent -replace '\$\{ODOO_CUSTOM_ADDONS_PATH\}', $ODOO_CUSTOM_ADDONS_PATH
    $configContent = $configContent -replace '\$\{ODOO_ENTERPRISE_ADDONS_PATH\}', $ODOO_ENTERPRISE_ADDONS_PATH
    Set-Content -Path $EXPANDED_CONFIG -Value $configContent
} else {
    Write-Host "✗ ERROR: Config file not found at $ODOO_CONFIG_FILE" -ForegroundColor Red
    exit 1
}

# Run initialization with explicit database connection parameters
# Override db_host in config to use localhost instead of 'db'
$INIT_OUTPUT = [System.IO.Path]::GetTempFileName()

$initArgs = @(
    "-c", $EXPANDED_CONFIG,
    "-d", $DB_NAME,
    "--db_host=$DB_HOST",
    "--db_port=$DB_PORT",
    "--db_user=$DB_USER",
    "--db_password=$DB_PASSWORD",
    "-i", "base",
    "--stop-after-init",
    "--log-level=info"
)

try {
    # Run Odoo and capture output
    $allArgs = @($ODOO_BIN) + $initArgs
    $process = Start-Process -FilePath "python3" -ArgumentList $allArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput $INIT_OUTPUT -RedirectStandardError $INIT_OUTPUT -ErrorAction Stop
    
    $INIT_OUTPUT_CONTENT = Get-Content $INIT_OUTPUT -Raw -ErrorAction SilentlyContinue
    
    if ($process.ExitCode -eq 0) {
        Write-Host "✓ Odoo initialization command completed successfully." -ForegroundColor Green
        # Create flag file to mark initialization as complete
        New-Item -Path $INIT_FLAG_FILE -ItemType File -Force | Out-Null
        Write-Host "✓ Flag file created at $INIT_FLAG_FILE" -ForegroundColor Green
        Write-Host "  Initialization will be skipped on next run."
        Remove-Item $INIT_OUTPUT -ErrorAction SilentlyContinue
        Remove-Item $EXPANDED_CONFIG -ErrorAction SilentlyContinue
        exit 0
    } else {
        # Check if the error is because database is already initialized or base module already installed
        if ($INIT_OUTPUT_CONTENT -match "(?i)(already.*initialized|database.*already.*exists|Module.*base.*already.*installed|already.*installed)") {
            Write-Host "ℹ Database appears to be already initialized (detected from output)." -ForegroundColor Yellow
            Write-Host "Creating flag file to skip future initialization attempts."
            New-Item -Path $INIT_FLAG_FILE -ItemType File -Force | Out-Null
            Write-Host "✓ Flag file created at $INIT_FLAG_FILE" -ForegroundColor Green
            Remove-Item $INIT_OUTPUT -ErrorAction SilentlyContinue
            Remove-Item $EXPANDED_CONFIG -ErrorAction SilentlyContinue
            exit 0
        } else {
            Write-Host "✗ ERROR: Odoo initialization failed with exit code $($process.ExitCode)" -ForegroundColor Red
            Write-Host "Last 50 lines of output:"
            if ($INIT_OUTPUT_CONTENT) {
                $lines = $INIT_OUTPUT_CONTENT -split "`n"
                $lastLines = $lines[-50..-1] -join "`n"
                Write-Host $lastLines
            }
            Remove-Item $INIT_OUTPUT -ErrorAction SilentlyContinue
            Remove-Item $EXPANDED_CONFIG -ErrorAction SilentlyContinue
            exit 1
        }
    }
} catch {
    Write-Host "✗ ERROR: Failed to run Odoo initialization: $_" -ForegroundColor Red
    Remove-Item $INIT_OUTPUT -ErrorAction SilentlyContinue
    Remove-Item $EXPANDED_CONFIG -ErrorAction SilentlyContinue
    exit 1
}

