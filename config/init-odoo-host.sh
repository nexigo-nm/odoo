#!/bin/bash
set -e

# Odoo Database Initialization Script for Host/IDE Execution
# This script initializes Odoo when running from the IDE (not in Docker)
# It connects to the database running in docker-compose-db-only.yml
#
# Prerequisites:
# - Docker container 'odoo19-db' must be running (from docker-compose-db-only.yml)
# - Odoo must be installed/available in the current environment
# - Database must be accessible at localhost:5433
#
# Windows Compatibility Note:
# This script runs on the host machine, so on Windows you'll need Git Bash, WSL, or similar.
# Ensure the file uses LF (Unix) line endings, not CRLF (Windows).

# Get the script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables from .env file if it exists
if [ -f "$PROJECT_ROOT/.env" ]; then
  set -a
  source "$PROJECT_ROOT/.env"
  set +a
fi

# Configuration
DB_NAME="${DB_NAME:-odoo}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5433}"
DB_USER="${DB_USER:-odoo}"
DB_PASSWORD="${DB_PASSWORD:-odoo}"
INIT_FLAG_FILE="$PROJECT_ROOT/.odoo_initialized"
ODOO_CONFIG_FILE="$SCRIPT_DIR/odoo.conf"
ODOO_BIN="$PROJECT_ROOT/odoo-bin"

# Set default addons paths if not set
ODOO_CUSTOM_ADDONS_PATH="${ODOO_CUSTOM_ADDONS_PATH:-$PROJECT_ROOT/custom-addons}"
ODOO_ENTERPRISE_ADDONS_PATH="${ODOO_ENTERPRISE_ADDONS_PATH:-$PROJECT_ROOT/../enterprise-19.0}"

# Export variables for envsubst
export ODOO_CUSTOM_ADDONS_PATH
export ODOO_ENTERPRISE_ADDONS_PATH

echo "=== Odoo Database Initialization Script (Host/IDE) ==="
echo "Database name: $DB_NAME"
echo "Database host: $DB_HOST:$DB_PORT"
echo "Project root: $PROJECT_ROOT"

# Check if Odoo binary exists
if [ ! -f "$ODOO_BIN" ]; then
  echo "✗ ERROR: Odoo binary not found at $ODOO_BIN"
  echo "  Make sure you're running this from the Odoo project root."
  exit 1
fi

# Check if Docker container is running
if ! docker ps --format '{{.Names}}' | grep -q "^odoo19-db-only$"; then
  echo "✗ ERROR: Docker container 'odoo19-db-only' is not running."
  echo "  Please start it with: docker-compose -f docker-compose-db-only.yml up -d"
  exit 1
fi

# Check if initialization flag file exists
if [ -f "$INIT_FLAG_FILE" ]; then
  echo "✓ Odoo database is already initialized (flag file exists). Skipping initialization."
  exit 0
fi

# Wait for database to be ready using Python (no psql dependency)
echo "Waiting for database to be fully ready..."
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if python3 -c "
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
" 2>/dev/null; then
    echo "✓ Database is ready."
    break
  fi
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "✗ ERROR: Database is not ready after $MAX_RETRIES attempts."
    echo "  Please check that the database container is running and healthy."
    exit 1
  fi
  echo "  Waiting for database... (attempt $RETRY_COUNT/$MAX_RETRIES)"
  sleep 2
done

# Wait a bit more to ensure database is fully ready
sleep 2

echo "Attempting Odoo database initialization..."

# Expand environment variables in config file
# Create a temporary config file with expanded variables
EXPANDED_CONFIG=$(mktemp)
if command -v envsubst >/dev/null 2>&1; then
  # Use envsubst if available (GNU gettext)
  envsubst < "$ODOO_CONFIG_FILE" > "$EXPANDED_CONFIG"
else
  # Fallback: use sed to replace variables manually
  sed "s|\${ODOO_CUSTOM_ADDONS_PATH}|$ODOO_CUSTOM_ADDONS_PATH|g; s|\${ODOO_ENTERPRISE_ADDONS_PATH}|$ODOO_ENTERPRISE_ADDONS_PATH|g" "$ODOO_CONFIG_FILE" > "$EXPANDED_CONFIG"
fi

# Run initialization with explicit database connection parameters
# Override db_host in config to use localhost instead of 'db'
INIT_OUTPUT=$(mktemp)
if python3 "$ODOO_BIN" \
  -c "$EXPANDED_CONFIG" \
  -d "$DB_NAME" \
  --db_host="$DB_HOST" \
  --db_port="$DB_PORT" \
  --db_user="$DB_USER" \
  --db_password="$DB_PASSWORD" \
  -i base \
  --stop-after-init \
  --log-level=info \
  2>&1 | tee "$INIT_OUTPUT"; then
  echo "✓ Odoo initialization command completed successfully."
  # Create flag file to mark initialization as complete
  touch "$INIT_FLAG_FILE"
  echo "✓ Flag file created at $INIT_FLAG_FILE"
  echo "  Initialization will be skipped on next run."
  rm -f "$INIT_OUTPUT" "$EXPANDED_CONFIG"
  exit 0
else
  INIT_EXIT_CODE=$?
  INIT_OUTPUT_CONTENT=$(cat "$INIT_OUTPUT" 2>/dev/null || echo "")
  
  # Check if the error is because database is already initialized or base module already installed
  if echo "$INIT_OUTPUT_CONTENT" | grep -qiE "already.*initialized|database.*already.*exists|Module.*base.*already.*installed|already.*installed"; then
    echo "ℹ Database appears to be already initialized (detected from output)."
    echo "Creating flag file to skip future initialization attempts."
    touch "$INIT_FLAG_FILE"
    echo "✓ Flag file created at $INIT_FLAG_FILE"
    rm -f "$INIT_OUTPUT" "$EXPANDED_CONFIG"
    exit 0
  else
    echo "✗ ERROR: Odoo initialization failed with exit code $INIT_EXIT_CODE"
    echo "Last 50 lines of output:"
    echo "$INIT_OUTPUT_CONTENT" | tail -50
    rm -f "$INIT_OUTPUT" "$EXPANDED_CONFIG"
    exit 1
  fi
fi

