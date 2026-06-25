#!/usr/bin/env bash
source "$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/lib/odaa_common.sh"
DB_FILTER="ALL"; TEST_MODE="false"; TAR_SEARCH_DIR="${TAR_SEARCH_DIR:-/var/opt/oracle/log/reg_tmp_files}"; TARGET_DIR="${TARGET_DIR:-$SCRIPT_HOME/config}"
usage(){ echo "Usage: $(basename "$0") [-a|-d db1,db2] [-i ini_file] [-t]"; exit 1; }
while getopts ":ad:i:th" opt; do case "$opt" in a) DB_FILTER="ALL";; d) DB_FILTER="$OPTARG";; i) INI_FILE="$OPTARG";; t) TEST_MODE="true";; h|*) usage;; esac; done
start_logging "odaa_move_latest_db_tar"; print_banner "Move latest DBaaS registration TAR file" "MOVE TEST=$TEST_MODE" "$DB_FILTER"
require_readable "$INI_FILE"; [[ -d "$TARGET_DIR" ]] || die "Target directory not found: $TARGET_DIR"
PASS=0; FAIL=0; SKIP=0
while IFS='|' read -r dbName rest; do dbName="$(echo "${dbName:-}"|xargs)"; [[ -n "$dbName" ]] || continue; is_selected_db "$dbName" "$DB_FILTER" || continue; latest=$(sudo ls -1t "$TAR_SEARCH_DIR"/${dbName}*.tar 2>/dev/null | head -1 || true); [[ -z "$latest" ]] && { summ "SKIP $dbName TAR not found"; ((SKIP++)); continue; }; target="$TARGET_DIR/${dbName}.tar"; if [[ "$TEST_MODE" == "true" ]]; then echo "TEST CMD: sudo mv -f $latest $target"; ((PASS++)); elif sudo mv -f "$latest" "$target"; then sudo chmod 600 "$target" 2>/dev/null || true; summ "PASS $dbName moved to $target"; ((PASS++)); else summ "FAIL $dbName move"; ((FAIL++)); fi; done < <(ini_rows)
summ "Completed: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; [[ $FAIL -eq 0 ]]
