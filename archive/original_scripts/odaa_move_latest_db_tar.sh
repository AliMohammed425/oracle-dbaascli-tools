#!/usr/bin/env bash
######################################################
# Author  : Mohammed Ali
# Version : 1.0.0
# Purpose : Move latest ${dbName}*.tar → ${dbName}.tar
######################################################

set -euo pipefail
IFS=$'\n\t'

SCRIPT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INI_FILE="${INI_FILE:-$SCRIPT_HOME/config/migration_db.ini}"
TAR_SEARCH_DIR="${TAR_SEARCH_DIR:-/var/opt/oracle/log/reg_tmp_files}"
TARGET_DIR="${TARGET_DIR:-$SCRIPT_HOME/config}"
#TARGET_DIR="${TARGET_DIR:-/home/opc/odaa-dbaascli-tools/config}"
FILTER_DB="${FILTER_DB:-}"

LOG_DIR="${LOG_DIR:-$SCRIPT_HOME/logs}"
mkdir -p "$LOG_DIR"

RUN_TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/odaa_move_tar_${RUN_TS}.log"
SUMMARY_FILE="$LOG_DIR/odaa_move_tar_summary_${RUN_TS}.txt"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "📦 MOVE LATEST TAR FILE SCRIPT" | tee "$SUMMARY_FILE"
echo "____________________________________________________________________________________________" | tee -a "$SUMMARY_FILE"
echo "INI FILE     : $INI_FILE" | tee -a "$SUMMARY_FILE"
echo "SEARCH DIR   : $TAR_SEARCH_DIR" | tee -a "$SUMMARY_FILE"
echo "TARGET DIR   : $TARGET_DIR" | tee -a "$SUMMARY_FILE"
echo "Start Time   : $(date)" | tee -a "$SUMMARY_FILE"
echo "____________________________________________________________________________________________" | tee -a "$SUMMARY_FILE"

[[ -f "$INI_FILE" ]] || {
  echo "❌ ERROR: INI file not found: $INI_FILE" | tee -a "$SUMMARY_FILE"
  exit 1
}

sudo test -d "$TARGET_DIR" || {
  echo "❌ ERROR: Target directory not found: $TARGET_DIR" | tee -a "$SUMMARY_FILE"
  exit 1
}

# Function
move_latest_tar() {
  local dbName="$1"
  local latest_tar=""
  local target_file=""

  echo
  echo "🔍 Processing DB: $dbName"

  latest_tar=$(sudo ls -1t "$TAR_SEARCH_DIR"/${dbName}_*.tar 2>/dev/null | head -1 || true)

  if [[ -z "$latest_tar" ]]; then
    echo "⚠️  $dbName : TAR NOT FOUND → SKIPPED" | tee -a "$SUMMARY_FILE"
    return
  fi

  target_file="$TARGET_DIR/${dbName}.tar"

  echo "   Found  : $latest_tar"
  echo "   Target : $target_file"

  if sudo mv -f "$latest_tar" "$target_file"; then
    sudo chown opc:opc "$target_file" 2>/dev/null || true
    sudo chmod 600 "$target_file" 2>/dev/null || true
    echo "✅ $dbName : SUCCESS → $(basename "$target_file")" | tee -a "$SUMMARY_FILE"
  else
    echo "❌ $dbName : MOVE FAILED" | tee -a "$SUMMARY_FILE"
  fi
}

# Main loop

#dbName|dbUniqueName|dbSID|dbCharset|dbNCharset|pdatafileDestination|pfraDestination|pNodeList|port|syspass|tdepass|primaryScanIPAddresses|primaryScanPort|pServiceName|standbyScanIPAddresses|standbyScanPort|sServiceName|standbyDBUniqueName|sdatafileDestination|sfraDestination|sNodeList|flagSkip|dbBlockSizeInKB|enableCDB|dbHome

tail -n +2 "$INI_FILE" | while IFS='|' read -r dbName dbUniqueName dbSID dbCharset dbNCharset pdatafileDestination pfraDestination pNodeList port syspass tdepass primaryScanIPAddresses primaryScanPort pServiceName standbyScanIPAddresses standbyScanPort sServiceName standbyDBUniqueName sdatafileDestination sfraDestination sNodeList flagSkip dbBlockSizeInKB enableCDB dbHome

do
  [[ -z "${dbName// }" ]] && continue

  if [[ -n "$FILTER_DB" && "$dbName" != "$FILTER_DB" ]]; then
    continue
  fi

  PRECHECK_LOG="$LOG_DIR/${dbName}_precheck_${RUN_TS}.log"
  CREATE_LOG="$LOG_DIR/${dbName}_create_${RUN_TS}.log"

# Normalize flagSkip

  flagSkip="$(echo "${flagSkip:-N}" | tr '[:lower:]' '[:upper:]' | xargs)"

  # Skip if flagSkip = Y
  if [[ "$flagSkip" == "Y" ]]; then
    echo "⚠️  $dbName : SKIPPED (flagSkip=Y)" | tee -a "$SUMMARY_FILE"
    continue
  fi

move_latest_tar "$dbName"

done

#tail -n +2 "$INI_FILE" | while IFS='|' read -r dbName _

#do
#  [[ -z "${dbName// }" ]] && continue
#  move_latest_tar "$dbName"
#done

echo
echo "____________________________________________________________________________________________" | tee -a "$SUMMARY_FILE"
echo "✅ COMPLETED : $(date)" | tee -a "$SUMMARY_FILE"
echo "Log File     : $LOG_FILE" | tee -a "$SUMMARY_FILE"
echo "Summary File : $SUMMARY_FILE" | tee -a "$SUMMARY_FILE"
echo "____________________________________________________________________________________________"


