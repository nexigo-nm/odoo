#!/bin/bash
set -e

# Check if Odoo database is already initialized
# This script ensures initialization only runs once
#
# Windows Compatibility Note:
# This script runs inside a Linux Docker container, so it works on Windows hosts.
# However, ensure the file uses LF (Unix) line endings, not CRLF (Windows).
# Git should handle this automatically if .gitattributes is configured.
# If you edit this file on Windows, ensure your editor saves with LF line endings.

DB_NAME="${DB_NAME:-odoo}"
INIT_FLAG_FILE="/var/lib/odoo/.odoo_initialized"

echo "=== Odoo Database Initialization Script ==="
echo "Database name: $DB_NAME"

# Check if initialization flag file exists (persisted in volume)
if [ -f "$INIT_FLAG_FILE" ]; then
  echo "✓ Odoo database is already initialized (flag file exists). Skipping initialization."
  echo "Waiting for healthcheck to detect completion..."
  sleep 15
  exit 0
fi

# Wait a moment for database to be fully ready (healthcheck should handle this, but extra safety)
echo "Waiting for database to be fully ready..."
sleep 3

echo "Attempting Odoo database initialization..."

# Run initialization - capture both stdout and stderr
# Use --log-level=info to see what's happening
if odoo -d "$DB_NAME" -i base --stop-after-init --log-level=info 2>&1 | tee /tmp/odoo-init.log; then
  echo "✓ Odoo initialization command completed successfully."
  # Create flag file to mark initialization as complete
  touch "$INIT_FLAG_FILE"
  echo "✓ Flag file created. Initialization will be skipped on next run."
  echo "Waiting for healthcheck to detect completion..."
  sleep 15
  exit 0
else
  INIT_EXIT_CODE=$?
  INIT_OUTPUT=$(cat /tmp/odoo-init.log 2>/dev/null || echo "")
  
  # Check if the error is because database is already initialized or base module already installed
  if echo "$INIT_OUTPUT" | grep -qiE "already.*initialized|database.*already.*exists|Module.*base.*already.*installed|already.*installed"; then
    echo "ℹ Database appears to be already initialized (detected from output)."
    echo "Creating flag file to skip future initialization attempts."
    touch "$INIT_FLAG_FILE"
    echo "Waiting for healthcheck to detect completion..."
    sleep 10
    exit 0
  else
    echo "✗ ERROR: Odoo initialization failed with exit code $INIT_EXIT_CODE"
    echo "Last 50 lines of output:"
    echo "$INIT_OUTPUT" | tail -50
    exit 1
  fi
fi

