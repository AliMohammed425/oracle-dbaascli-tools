#!/usr/bin/env bash
source "$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/lib/odaa_common.sh"
DB_FILTER=""; TEST_MODE="false"
usage(){ echo "Usage: $(basename "$0") --all|-d db1,db2 [-i ini_file] [-t]"; exit 1; }
while [[ $# -gt 0 ]]; do case "$1" in --all|-a) DB_FILTER="ALL"; shift;; -d|--database) DB_FILTER="$2"; shift 2;; -i) INI_FILE="$2"; shift 2;; -t|--test) TEST_MODE="true"; shift;; -h|--help) usage;; *) usage;; esac; done
[[ -n "$DB_FILTER" ]] || usage
start_logging "odaa_db_status_health"; print_banner "Database and Data Guard health check" "STATUS TEST=$TEST_MODE" "$DB_FILTER"
require_dbaascli; require_readable "$INI_FILE"; PASS=0; FAIL=0; SKIP=0
while IFS='|' read -r dbName dbUniqueName dbSID rest; do dbName="$(echo "${dbName:-}"|xargs)"; [[ -n "$dbName" ]] || continue; is_selected_db "$dbName" "$DB_FILTER" || continue; summ "STATUS START $dbName"; if [[ "$TEST_MODE" == "true" ]]; then echo "TEST CMD: sudo $DBAASCLI database getDetails --dbname $dbName"; echo "TEST CMD: sudo $DBAASCLI dataguard status --dbname $dbName"; ((PASS++)); elif sudo "$DBAASCLI" database getDetails --dbname "$dbName" && sudo "$DBAASCLI" dataguard status --dbname "$dbName"; then summ "PASS status $dbName"; ((PASS++)); else summ "FAIL status $dbName"; ((FAIL++)); fi; done < <(ini_rows)
summ "Completed: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; [[ $FAIL -eq 0 ]]
