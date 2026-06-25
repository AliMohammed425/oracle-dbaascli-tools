#!/usr/bin/env bash
#############################################################
# Author  : Mohammed Ali
# Version : 4.0.1
# Purpose : dbaascli standby build + dataguard Configuration
#############################################################

clear
set -euo pipefail
IFS=$'\n\t'

SCRIPT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INI_FILE="${INI_FILE:-$SCRIPT_HOME/config/migration_db.ini}"
ORACLE_HOME="${ORACLE_HOME:-/u02/app/oracle/product/19.0.0.0/dbhome_1}"
FILTER_DB="${FILTER_DB:-}"

WAIT_FOR_COMPLETION="${WAIT_FOR_COMPLETION:-true}"
TDE_CONFIG_METHOD="${TDE_CONFIG_METHOD:-FILE}"
FRA_SIZE_MB="${FRA_SIZE_MB:-204800}"

TAR_SEARCH_DIR="${TAR_SEARCH_DIR:-/var/opt/oracle/log/reg_tmp_files}"
TARGET_DIR="${TARGET_DIR:-$SCRIPT_HOME/config}"

LOG_DIR="${LOG_DIR:-$SCRIPT_HOME/logs}"
mkdir -p "$LOG_DIR"

RUN_TS="$(date +%Y%m%d_%H%M%S)"
MASTER_LOG="$LOG_DIR/odaa_database_build_stby_${RUN_TS}.log"
SUMMARY_FILE="$LOG_DIR/database_stby_summary_${RUN_TS}.txt"

exec > >(tee -a "$MASTER_LOG") 2>&1

echo "                  BUILD STANDBY DATABASE + DATAGUARD CONFIGURATION  SUMMARY            " | tee "$SUMMARY_FILE"
echo "____________________________________________________________________________________________" | tee -a "$SUMMARY_FILE"
echo "Script      : odaa_db_build_stby.sh" | tee -a "$SUMMARY_FILE"
echo "Purpose     : dbaascli standby build and dataguard Configuration" | tee -a "$SUMMARY_FILE"
echo "Author      : Mohammed Ali" | tee -a "$SUMMARY_FILE"
echo "Version     : 4.0.1" | tee -a "$SUMMARY_FILE"
echo "Mode        : Execute" | tee -a "$SUMMARY_FILE"
echo "INI         : $INI_FILE" | tee -a "$SUMMARY_FILE"
echo "DB          : ${FILTER_DB:-ALL}" | tee -a "$SUMMARY_FILE"
echo "Oracle Home : $ORACLE_HOME" | tee -a "$SUMMARY_FILE"
echo "TAR Search  : $TAR_SEARCH_DIR" | tee -a "$SUMMARY_FILE"
echo "TAR Target  : $TARGET_DIR" | tee -a "$SUMMARY_FILE"
echo "Start       : $(date)" | tee -a "$SUMMARY_FILE"
echo "Master Log  : $MASTER_LOG" | tee -a "$SUMMARY_FILE"
echo "Summary Log : $SUMMARY_FILE" | tee -a "$SUMMARY_FILE"
echo "____________________________________________________________________________________________" | tee -a "$SUMMARY_FILE"

command -v /usr/bin/dbaascli >/dev/null || {
  echo "ERROR: dbaascli not found under /usr/bin/dbaascli" | tee -a "$SUMMARY_FILE"
  exit 1
}

[[ -f "$INI_FILE" ]] || {
  echo "ERROR: INI file not found: $INI_FILE" | tee -a "$SUMMARY_FILE"
  exit 1
}

sudo test -d "$TARGET_DIR" || {
  echo "ERROR: - Target directory not found: $TARGET_DIR" | tee -a "$SUMMARY_FILE"
  exit 1
}

chmod 600 "$INI_FILE" || true

db_exists() {
  local dbName="$1"

  sudo /usr/bin/dbaascli database list 2>/dev/null | \
    awk -F= '/DB Name/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | \
    grep -Eixq "$dbName"
}

move_latest_tar() {
  local dbName="$1"
  local latest_tar=""
  local target_file=""

  echo
  echo "📦 $dbName : TAR FILE PROCESSING STARTED" | tee -a "$SUMMARY_FILE"

  latest_tar=$(sudo su - root ls -1t "$TAR_SEARCH_DIR"/${dbName}*.tar 2>/dev/null | head -1 || true)

  if [[ -z "$latest_tar" ]]; then
    echo "⚠️  $dbName : TAR NOT FOUND → SKIPPED" | tee -a "$SUMMARY_FILE"
    return 0
  fi

  target_file="$TARGET_DIR/${dbName}.tar"

  echo "🔍 $dbName : Latest TAR found : $latest_tar" | tee -a "$SUMMARY_FILE"
  echo "📍 $dbName : Target file      : $target_file" | tee -a "$SUMMARY_FILE"

  if sudo mv -f "$latest_tar" "$target_file"; then
    sudo chown opc:opc "$target_file" 2>/dev/null || true
    sudo chmod 600 "$target_file" 2>/dev/null || true
    echo "✅ $dbName : TAR MOVE SUCCESSFUL → $target_file" | tee -a "$SUMMARY_FILE"
  else
    echo "❌ $dbName : TAR MOVE FAILED → $latest_tar" | tee -a "$SUMMARY_FILE"
    return 1
  fi
}

#dbName|pdbUniqueName|dbSID|dbCharset|dbNCharset|pdatafileDestination|pfraDestination|pNodeList|port|syspass|tdepass|primaryScanIPAddresses|primaryScanPort|pServiceName|standbyScanIPAddresses|standbyScanPort|sServiceName|standbyDBUniqueName|sdatafileDestination|sfraDestination|sNodeList|flagSkip|dbBlockSizeInKB|enableCDB|dbHome

tail -n +2 "$INI_FILE" | while IFS='|' read -r dbName pdbUniqueName dbSID dbCharset dbNCharset pdatafileDestination pfraDestination pNodeList port syspass tdepass primaryScanIPAddresses primaryScanPort pServiceName standbyScanIPAddresses standbyScanPort sServiceName standbyDBUniqueName sdatafileDestination sfraDestination sNodeList flagSkip dbBlockSizeInKB enableCDB dbHome


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


  if  db_exists "$dbName"; then
    echo "⚠️  $dbName : FOUND → SKIPPED" | tee -a "$SUMMARY_FILE"
    continue
  fi

  echo
  echo "✅ $dbName : EXISTS → Proceeding Dataguard Prepare For Standby" | tee -a "$SUMMARY_FILE"

  #move_latest_tar "$dbName" || true

  echo
  echo "DB Information                          : $dbName"
  echo "   oracleHome                           : $ORACLE_HOME"
  echo "   dbUniqueName                         : $pdbUniqueName"
  echo "   dbSID                                : $dbSID"
  echo "   datafileDestination                  : $sdatafileDestination"
  echo "   fraDestination                       : $sfraDestination"
  echo "   primaryNodeList                      : $pNodeList"
  echo "   standbyNodeList                      : $sNodeList"
  echo "   primaryScanIPAddresses               : $primaryScanIPAddresses"
  echo "   primaryScanPort                      : $primaryScanPort"
  echo "   standbyScanIPAddresses               : $standbyScanIPAddresses"
  echo "   standbyScanPort                      : $standbyScanPort"
  echo "   standbyDBUniqueName                  : $standbyDBUniqueName"

  echo "Creating Standby Build and Dataguard Configuration Prereqs Mode For DB: $dbName "

set +e

{
  printf '%s\n' "$syspass"   # PRIMARY_DB_SYS_PASSWORD
  printf '%s\n' "$tdepass"   # PRIMARY_DB_TDE_PASSWORD
  printf '%s\n' "$syspass"   # AWR_ADMIN_PASSWORD
  printf '%s\n' "$syspass"   # AWR_ADMIN_PASSWORD reconfirmation
} | sudo /usr/bin/dbaascli dataguard configureStandby \
  --dbname "${dbName}" \
  --oracleHome "${dbHome}" \
  --standbyDBUniqueName "$standbyDBUniqueName" \
  --noDBDomain \
  --primaryServiceName "${pdbUniqueName}.${pServiceName}" \
  --primaryScanPort "$primaryScanPort" \
  --protectionMode MAX_PERFORMANCE \
  --transportType ASYNC \
  --activeDG true \
  --standbyBlobFromPrimary "$SCRIPT_HOME/config/${dbName}.tar" \
  --standbyScanIPAddresses "$standbyScanIPAddresses" \
  --standbyScanPort "$standbyScanPort" \
  --primaryScanIPAddresses "$primaryScanIPAddresses" \
  --nodeList "$sNodeList" \
  --datafileDestination "$sdatafileDestination" \
  --fraDestination  "$sfraDestination" \
  --fraSizeInMB 204800 \
  --skipAWRConfiguration \
  --tdeKeyStoreType FILE \
  --executePrereqs > "$PRECHECK_LOG" 2>&1

RC=$?


  PRECHECK_RC=$?
  set -e

  if [[ "$PRECHECK_RC" -eq 0 ]] && grep -Eqi "success|successfully|passed|completed|prereq" "$PRECHECK_LOG"; then
    echo "✅ $dbName : PRECHECK PASS" | tee -a "$SUMMARY_FILE"
    echo "   PRECHECK LOG: $PRECHECK_LOG" | tee -a "$SUMMARY_FILE"

    echo "Creating Standby Build and Dataguard Configuration Execute Mode For DB : $dbName"

set +e

{
  printf '%s\n' "$syspass"   # PRIMARY_DB_SYS_PASSWORD
  printf '%s\n' "$tdepass"   # PRIMARY_DB_TDE_PASSWORD
  printf '%s\n' "$syspass"   # AWR_ADMIN_PASSWORD
  printf '%s\n' "$syspass"   # AWR_ADMIN_PASSWORD reconfirmation
} | sudo /usr/bin/dbaascli dataguard configureStandby \
  --dbname "${dbName}" \
  --oracleHome "${dbHome}" \
  --standbyDBUniqueName "$standbyDBUniqueName" \
  --noDBDomain \
  --primaryServiceName "${pdbUniqueName}.${pServiceName}" \
  --primaryScanPort "$primaryScanPort" \
  --protectionMode MAX_PERFORMANCE \
  --transportType ASYNC \
  --activeDG true \
  --standbyBlobFromPrimary "$SCRIPT_HOME/config/${dbName}.tar" \
  --standbyScanIPAddresses "$standbyScanIPAddresses" \
  --standbyScanPort "$standbyScanPort" \
  --primaryScanIPAddresses "$primaryScanIPAddresses" \
  --nodeList "$sNodeList" \
  --datafileDestination "$sdatafileDestination" \
  --fraDestination  "$sfraDestination" \
  --fraSizeInMB 204800 \
  --skipAWRConfiguration \
  --tdeKeyStoreType FILE  > "$CREATE_LOG" 2>&1

    CREATE_RC=$?
    set -e

    if [[ "$CREATE_RC" -eq 0 ]] && grep -Eqi "success|successfully|completed|created" "$CREATE_LOG"; then
      echo "🚀 $dbName : STANDBY BUILD DATAGUARD  DATABASE SUCCESS" | tee -a "$SUMMARY_FILE"
      #move_latest_tar "$dbName" || true
    else
      echo "❌ $dbName : BUID STANDBY AND  DATAGUARD  FAILED" | tee -a "$SUMMARY_FILE"
      echo "   Reason:" | tee -a "$SUMMARY_FILE"
      grep -Eai "error|failed|fail|exception|ORA-|PRCD-|PRCR-|CRS-|DCS-|DBT-|No input provided" "$CREATE_LOG" | tail -30 | tee -a "$SUMMARY_FILE" || true
    fi

    echo "   STANDBY BUILD DATABASE LOG: $CREATE_LOG" | tee -a "$SUMMARY_FILE"

  else
    echo "❌ $dbName : STANDBY BUILD FAILED →  SKIPPED" | tee -a "$SUMMARY_FILE"
    echo "   Reason:" | tee -a "$SUMMARY_FILE"
    grep -Eai "error|failed|fail|exception|ORA-|PRCD-|PRCR-|CRS-|DCS-|DBT-|No input provided" "$PRECHECK_LOG" | tail -30 | tee -a "$SUMMARY_FILE" || true
    echo "   PRECHECK LOG: $PRECHECK_LOG" | tee -a "$SUMMARY_FILE"
  fi

done

echo " "
echo "List all Database's with Database Role "
echo "____________________________________________________________________________________________"

sudo dbaascli system getDatabases | awk -F'"' '
BEGIN {
  printf "%-5s %-12s %-15s %-20s\n", "SEQ", "DB_NAME", "DB_UNIQUE_NAME", "DB_ROLE" "\n"
  #printf "%-5s %-12s %-15s %-20s\n", "----", "--------", "---------------", "--------------------"
}
/"dbName"/ {name=$4}
/"pdbUniqueName"/ {uniq=$4}
/"dbRole"/ {
  role=$4
  seq++
  printf "%-5s %-12s %-15s %-20s\n", seq, name, uniq, role
}'

echo

echo "______________________________________________________________________________________________________________________" | tee -a "$SUMMARY_FILE"
echo "Completed    		     : $(date)" | tee -a "$SUMMARY_FILE"
echo "Master Log   		     : $MASTER_LOG" | tee -a "$SUMMARY_FILE"
echo "Summary   		     : $SUMMARY_FILE" | tee -a "$SUMMARY_FILE"
echo "Example switchover           : sudo dbaascli dataguard switchover  --dbname BBCDB  --newPrimaryDBUniqueName SBBCDB"
echo "        status               : sudo dbaascli dataguard status --dbname BBCDB"
echo "        using                : dgmgrl sys@SBBCDB show configuration/failover/switchover "
echo 
echo "______________________________________________________________________________________________________________________" | tee -a "$SUMMARY_FILE"
