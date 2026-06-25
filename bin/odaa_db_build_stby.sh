#!/usr/bin/env bash
source "$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/lib/odaa_common.sh"
DB_FILTER="ALL"; TEST_MODE="false"; MOVE_TAR="true"; TAR_SEARCH_DIR="${TAR_SEARCH_DIR:-/var/opt/oracle/log/reg_tmp_files}"; TARGET_DIR="${TARGET_DIR:-$SCRIPT_HOME/config}"
usage(){ cat <<USAGE
Usage: $(basename "$0") [-a|-d db1,db2] [-i ini_file] [-t] [--no-move-tar]
Build standby and configure Data Guard using dbaascli. Existing standby DBs are skipped; nothing is deleted.
USAGE
exit 1; }
while [[ $# -gt 0 ]]; do case "$1" in -a|--all) DB_FILTER="ALL"; shift;; -d|--database) DB_FILTER="$2"; shift 2;; -i) INI_FILE="$2"; shift 2;; -t|--test) TEST_MODE="true"; shift;; --no-move-tar) MOVE_TAR="false"; shift;; -h|--help) usage;; *) usage;; esac; done
start_logging "odaa_db_build_stby"; print_banner "Build standby and configure Data Guard" "EXECUTE TEST=$TEST_MODE" "$DB_FILTER"
require_dbaascli; require_readable "$INI_FILE"; PASS=0; FAIL=0; SKIP=0
move_latest_tar(){ local db="$1"; local latest target; latest=$(sudo ls -1t "$TAR_SEARCH_DIR"/${db}*.tar 2>/dev/null | head -1 || true); [[ -z "$latest" ]] && { warn "$db TAR not found"; return 0; }; target="$TARGET_DIR/${db}.tar"; sudo mv -f "$latest" "$target" && sudo chmod 600 "$target" 2>/dev/null || true; ok "$db TAR moved to $target"; }
while IFS='|' read -r dbName dbUniqueName dbSID dbCharset dbNCharset pdatafileDestination pfraDestination pNodeList port syspass tdepass primaryScanIPAddresses primaryScanPort pServiceName standbyScanIPAddresses standbyScanPort sServiceName standbyDBUniqueName sdatafileDestination sfraDestination sNodeList flagSkip dbBlockSizeInKB enableCDB dbHome rest; do
 dbName="$(echo "${dbName:-}"|xargs)"; [[ -n "$dbName" ]] || continue; is_selected_db "$dbName" "$DB_FILTER" || continue
 [[ "$(normalize_flag "$flagSkip")" == "Y" ]] && { summ "SKIP $dbName flagSkip=Y"; ((SKIP++)); continue; }
 if [[ "$TEST_MODE" != "true" ]] && db_exists "$standbyDBUniqueName"; then summ "SKIP $dbName: standby $standbyDBUniqueName already exists"; ((SKIP++)); continue; fi
 [[ "$MOVE_TAR" == "true" && "$TEST_MODE" != "true" ]] && move_latest_tar "$dbName" || true
 CMD=(sudo "$DBAASCLI" dataguard buildStandby --dbname "$dbName" --standbyDBUniqueName "$standbyDBUniqueName" --standbyScanIPAddresses "$standbyScanIPAddresses" --standbyScanPort "${standbyScanPort:-1521}" --standbyServiceName "$sServiceName" --standbyNodeList "$sNodeList" --waitForCompletion "$WAIT_FOR_COMPLETION")
 if [[ "$TEST_MODE" == "true" ]]; then printf 'TEST CMD: %q ' "${CMD[@]}"; echo; ((PASS++)); continue; fi
 summ "BUILD STANDBY START $dbName"; if printf '%s\n%s\n' "$syspass" "${tdepass:-$syspass}" | "${CMD[@]}"; then summ "PASS $dbName standby build"; ((PASS++)); else summ "FAIL $dbName standby build"; ((FAIL++)); fi
done < <(ini_rows)
summ "Completed: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; [[ $FAIL -eq 0 ]]
