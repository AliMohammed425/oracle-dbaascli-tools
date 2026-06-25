#!/usr/bin/env bash
######################################################
# Author  : Mohammed Ali
# Version : 4.0.1
# Purpose : dbaascli dataguard prepareForStandby + move latest DB tar
######################################################
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
#TARGET_DIR="${TARGET_DIR:-/home/opc/odaa-dbaascli-tools/config}"
TARGET_DIR="${TARGET_DIR:-$SCRIPT_HOME/config}"

LOG_DIR="${LOG_DIR:-$SCRIPT_HOME/logs}"
mkdir -p "$LOG_DIR"

RUN_TS="$(date +%Y%m%d_%H%M%S)"
MASTER_LOG="$LOG_DIR/odaa_db_prepare_stby_${RUN_TS}.log"
SUMMARY_FILE="$LOG_DIR/db_prepare_stby_summary_${RUN_TS}.txt"

exec > >(tee -a "$MASTER_LOG") 2>&1

echo "                  DATAGUARD PREPARE FOR STANDBY SUMMARY            " | tee "$SUMMARY_FILE"
echo "____________________________________________________________________________________________" | tee -a "$SUMMARY_FILE"
echo "Script      : odaa_db_prepare_stby.sh" | tee -a "$SUMMARY_FILE"
echo "Purpose     : dbaascli dataguard prepareForStandby" | tee -a "$SUMMARY_FILE"
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
  echo "ERROR: Target directory not found: $TARGET_DIR" | tee -a "$SUMMARY_FILE"
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


#dbName|dbUniqueName|dbSID|dbCharset|dbNCharset|pdatafileDestination|pfraDestination|pNodeList|port|syspass|tdepass|primaryScanIPAddresses|primaryScanPort|pServiceName|standbyScanIPAddresses|standbyScanPort|sServiceName|standbyDBUniqueName|sdatafileDestination|sfraDestination|sNodeList|flagSkip|dbBlockSizeInKB|enableCDB|dbHome

#MCK|MCKPRI|MCK|AL32UTF8|AL16UTF16|+DATAC1|+RECOC1|ukwhost-mvsgl1,ukwhost-mvsgl2|1521|Welcome1!ChangeMe|Welcome1!ChangeMe|10.201.0.252,10.201.0.57,10.201.0.87|1521|10.200.0.216,10.200.0.160,10.200.0.125|1521|ocidelgatedsub.ocivnetukwest.oraclevcn.com|MCKSTBY|+DATAC2|+RECOC2|host51-4uhm22,host51-4uhm21|ocidelgatedsub.ocivnetukwest.oraclevcn.com|N|8|true|/u02/app/oracle/product/19.0.0.0/dbhome_1

tail -n +2 "$INI_FILE" | while IFS='|' read -r dbName dbUniqueName dbSID dbCharset dbNCharset pdatafileDestination pfraDestination pNodeList port syspass tdepass primaryScanIPAddresses primaryScanPort pServiceName standbyScanIPAddresses standbyScanPort sServiceName standbyDBUniqueName sdatafileDestination sfraDestination sNodeList flagSkip dbBlockSizeInKB enableCDB dbHome

#echo "dbName                         : $dbName"
#echo "dbUniqueName                   : $dbUniqueName"
#echo "dbSID                          : $dbSID"
#echo "dbCharset                      : $dbCharset"
#echo "dbNCharset                     : $dbNCharset"
#echo "pdatafileDestination           : $pdatafileDestination"
#echo "pfraDestination                : $pfraDestination"
#echo "pNodeList                      : $pNodeList"
#echo "port                           : $port"
#echo "syspass                        : $syspass"
#echo "tdepass                        : $tdepass"
#echo "primaryScanIPAddresses         : $primaryScanIPAddresses"
#echo "primaryScanPort                : $primaryScanPort"
#echo "pServiceName                   : $pServiceName"
#echo "standbyScanIPAddresses         : $standbyScanIPAddresses"
#echo "standbyScanPort                : $standbyScanPort"
#echo "sServiceName                   : $sServiceName"
#echo "standbyDBUniqueName            : $standbyDBUniqueName"
#echo "sdatafileDestination           : $sdatafileDestination"
#echo "sfraDestination                : $sfraDestination"
#echo "sNodeList                      : $sNodeList"
#echo "flagSkip                       : $flagSkip"
#echo "dbBlockSizeInKB                : $dbBlockSizeInKB"
#echo "enableCDB                      : $enableCDB"
#echo "dbHome                         : $dbHome"

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


  if ! db_exists "$dbName"; then
    echo "⚠️  $dbName : NOT FOUND → SKIPPED" | tee -a "$SUMMARY_FILE"
    continue
  fi

  echo
  echo "✅ $dbName : EXISTS → Proceeding Dataguard Prepare For Standby" | tee -a "$SUMMARY_FILE"

  #move_latest_tar "$dbName" || true

  echo
  echo "DB Information                          : $dbName"
  echo "   oracleHome                           : $ORACLE_HOME"
  echo "   dbUniqueName                         : $dbUniqueName"
  echo "   dbSID                                : $dbSID"
  echo "   datafileDestination                  : $pdatafileDestination"
  echo "   fraDestination                       : $pfraDestination"
  echo "   PrimaryNodeList                      : $pNodeList"
  echo "   StandbyNodeList                      : $sNodeList"
  echo "   primaryScanIPAddresses               : $primaryScanIPAddresses"
  echo "   primaryScanPort                      : $primaryScanPort"
  echo "   standbyScanIPAddresses               : $standbyScanIPAddresses"
  echo "   standbyScanPort                      : $standbyScanPort"
  echo "   standbyDBUniqueName                  : $standbyDBUniqueName"

  echo "Running Dataguard Prepare For Standby Executing Prereqs Mode"

  set +e
  {
    printf '%s\n' "$syspass"
    printf '%s\n' "$syspass"
    [[ -n "${tdepass:-}" ]] && printf '%s\n%s\n' "$tdepass" "$tdepass"
  } | sudo /usr/bin/dbaascli dataguard prepareForStandby \
      --dbname "$dbName" \
      --standbyDBUniqueName "$standbyDBUniqueName" \
      --noDBDomain \
      --standbyScanIPAddresses "$standbyScanIPAddresses" \
      --standbyScanPort "$standbyScanPort" \
      --primaryScanIPAddresses "$primaryScanIPAddresses" \
      --primaryScanPort "$primaryScanPort" \
      --executePrereqs > "$PRECHECK_LOG" 2>&1

  PRECHECK_RC=$?
  set -e

  if [[ "$PRECHECK_RC" -eq 0 ]] && grep -Eqi "success|successfully|passed|completed|prereq" "$PRECHECK_LOG"; then
    echo "✅ $dbName : PRECHECK PASS" | tee -a "$SUMMARY_FILE"
    echo "   PRECHECK LOG: $PRECHECK_LOG" | tee -a "$SUMMARY_FILE"

    echo "Running Dataguard Prepare For Standby Executing for DB: $dbName"

    set +e
    {
      printf '%s\n' "$syspass"
      printf '%s\n' "$syspass"
      [[ -n "${tdepass:-}" ]] && printf '%s\n%s\n' "$tdepass" "$tdepass"
    } | sudo /usr/bin/dbaascli dataguard prepareForStandby \
        --dbname "$dbName" \
        --standbyDBUniqueName "$standbyDBUniqueName" \
        --noDBDomain \
        --standbyScanIPAddresses "$standbyScanIPAddresses" \
        --standbyScanPort "$standbyScanPort" \
        --primaryScanIPAddresses "$primaryScanIPAddresses" \
        --primaryScanPort "$primaryScanPort" \
        --waitForCompletion "$WAIT_FOR_COMPLETION" > "$CREATE_LOG" 2>&1

    CREATE_RC=$?
    set -e

    if [[ "$CREATE_RC" -eq 0 ]] && grep -Eqi "success|successfully|completed|created" "$CREATE_LOG"; then
      echo "🚀 $dbName : PREPARE DATAGUARD ON PRIMARY DATABASE SUCCESS" | tee -a "$SUMMARY_FILE"
      #move_latest_tar "$dbName" || true
    else
      echo "❌ $dbName : PREPARE DATAGUARD ON PRIMARY DATABASE FAILED" | tee -a "$SUMMARY_FILE"
      echo "   Reason:" | tee -a "$SUMMARY_FILE"
      grep -Eai "error|failed|fail|exception|ORA-|PRCD-|PRCR-|CRS-|DCS-|DBT-|No input provided" "$CREATE_LOG" | tail -30 | tee -a "$SUMMARY_FILE" || true
    fi

    echo "   PREPARE DATAGUARD LOG: $CREATE_LOG" | tee -a "$SUMMARY_FILE"

  else
    echo "❌ $dbName : PRECHECK FAILED → PREPARE SKIPPED" | tee -a "$SUMMARY_FILE"
    echo "   Reason:" | tee -a "$SUMMARY_FILE"
    grep -Eai "error|failed|fail|exception|ORA-|PRCD-|PRCR-|CRS-|DCS-|DBT-|No input provided" "$PRECHECK_LOG" | tail -30 | tee -a "$SUMMARY_FILE" || true
    echo "   PRECHECK LOG: $PRECHECK_LOG" | tee -a "$SUMMARY_FILE"
  fi

done

echo "______________________________________________________________________________________________________________________" | tee -a "$SUMMARY_FILE"
echo "Completed    		     : $(date)" | tee -a "$SUMMARY_FILE"
echo "Master Log   		     : $MASTER_LOG" | tee -a "$SUMMARY_FILE"
echo "Summary   		     : $SUMMARY_FILE" | tee -a "$SUMMARY_FILE"
echo "Execute Post Tasks as root   : sudo su - root '/home/opc/odaa-dbaascli-tools/bin/odaa_move_latest_db_tar.sh' " | tee -a "$SUMMARY_FILE"
echo "                               scp -r /home/opc/odaa-dbaascli-tools <TARGET SERVER>:/home/opc "
echo "______________________________________________________________________________________________________________________" | tee -a "$SUMMARY_FILE"
echo "📦 TAR FILE PROCESSING STARTED" $SCRIPT_HOME/bin/odaa_move_latest_db_tar.sh | tee -a "$SUMMARY_FILE"


MOVE_SCRIPT="$SCRIPT_HOME/bin/odaa_move_latest_db_tar.sh"
if [[ -x "$MOVE_SCRIPT" ]]; then
  echo "▶ Running odaa_move_latest_db_tar.sh..."
sudo su - root  "$MOVE_SCRIPT"
echo ${TARGET_DIR}/*.tar
sudo chmod 755 ${TARGET_DIR}/*.tar
else
  echo "⚠️  File not found or not executable: $MOVE_SCRIPT"
  echo "⏭️  Skipping TAR move step..."
fi

#echo " "
#echo "✅ List all Database's with Database Role "
#echo "____________________________________________________________________________________________"

#sudo dbaascli system getDatabases | awk -F'"' '
#BEGIN {
#  printf "%-5s %-12s %-15s %-20s\n", "SEQ", "DB_NAME", "DB_UNIQUE_NAME", "DB_ROLE" "\n"
#  #printf "%-5s %-12s %-15s %-20s\n", "----", "--------", "---------------", "--------------------"
#}
#/"dbName"/ {name=$4}
#/"dbUniqueName"/ {uniq=$4}
#/"dbRole"/ {
#  role=$4
#  seq++
#  printf "%-5s %-12s %-15s %-20s\n", seq, name, uniq, role
#}'

echo

echo "Post Manual Task scp -r ${SCRIPT_HOME} <TARGET SERVER>:/home/opc "
echo "Execute as root <TARGET SERVER> "
echo "                sudo chmod 755 /home/opc"
echo "                sudo chmod 755 ${SCRIPT_HOME}"
echo "                sudo chmod 755 ${SCRIPT_HOME}/config"
echo "                sudo chmod 755 ${SCRIPT_HOME}/config/*.tar"
echo "______________________________________________________________________________________________________________________" | tee -a "$SUMMARY_FILE"
