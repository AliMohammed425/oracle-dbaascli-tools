#!/usr/bin/env bash
source "$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/lib/odaa_common.sh"
DB_FILTER="ALL"; TEST_MODE="false"
usage(){ echo "Usage: $(basename "$0") [-a|-d db1,db2] [-i ini_file] [-t]"; exit 1; }
while getopts ":ad:i:th" opt; do case "$opt" in a) DB_FILTER="ALL";; d) DB_FILTER="$OPTARG";; i) INI_FILE="$OPTARG";; t) TEST_MODE="true";; h|*) usage;; esac; done
start_logging "odaa_db_prepare_stby"; print_banner "Prepare primary for standby build" "PRECHECK TEST=$TEST_MODE" "$DB_FILTER"
require_dbaascli; require_readable "$INI_FILE"; PASS=0; FAIL=0; SKIP=0
while IFS='|' read -r dbName dbUniqueName dbSID dbCharset dbNCharset pdatafileDestination pfraDestination pNodeList port syspass tdepass primaryScanIPAddresses primaryScanPort pServiceName standbyScanIPAddresses standbyScanPort sServiceName standbyDBUniqueName sdatafileDestination sfraDestination sNodeList flagSkip dbBlockSizeInKB enableCDB dbHome rest; do
 dbName="$(echo "${dbName:-}"|xargs)"; [[ -n "$dbName" ]] || continue; is_selected_db "$dbName" "$DB_FILTER" || continue
 [[ "$(normalize_flag "$flagSkip")" == "Y" ]] && { summ "SKIP $dbName flagSkip=Y"; ((SKIP++)); continue; }
 CMD=(sudo "$DBAASCLI" dataguard prepareStandby --dbname "$dbName" --standbyDBUniqueName "$standbyDBUniqueName" --standbyScanIPAddresses "$standbyScanIPAddresses" --standbyScanPort "${standbyScanPort:-1521}" --standbyServiceName "$sServiceName" --standbyNodeList "$sNodeList" --waitForCompletion "$WAIT_FOR_COMPLETION")
 if [[ "$TEST_MODE" == "true" ]]; then printf 'TEST CMD: %q ' "${CMD[@]}"; echo; ((PASS++)); continue; fi
 summ "PREPARE START $dbName"; if printf '%s\n%s\n' "$syspass" "${tdepass:-$syspass}" | "${CMD[@]}"; then summ "PASS $dbName prepare"; ((PASS++)); else summ "FAIL $dbName prepare"; ((FAIL++)); fi
done < <(ini_rows)
summ "Completed: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; [[ $FAIL -eq 0 ]]
