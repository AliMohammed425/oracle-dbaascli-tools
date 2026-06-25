#!/usr/bin/env bash
# Common functions for ODAA DBaaSCLI Tools
# Author  : Mohammed Ali
# Company : Aqil Information Technology LLC
# Version : 5.0.0

set -euo pipefail
IFS=$'\n\t'

ODAA_VERSION="5.0.0"
ODAA_AUTHOR="Mohammed Ali"
ODAA_COMPANY="Aqil Information Technology LLC"
ODAA_COPYRIGHT="Copyright (c) 2026 Aqil Information Technology LLC. All Rights Reserved."

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SCRIPT_HOME="${SCRIPT_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
INI_FILE="${INI_FILE:-$SCRIPT_HOME/config/migration_db.ini}"
LOG_DIR="${LOG_DIR:-$SCRIPT_HOME/logs}"
WAIT_FOR_COMPLETION="${WAIT_FOR_COMPLETION:-true}"
TDE_CONFIG_METHOD="${TDE_CONFIG_METHOD:-FILE}"
FRA_SIZE_MB="${FRA_SIZE_MB:-204800}"
DEFAULT_ORACLE_HOME="${ORACLE_HOME:-/u02/app/oracle/product/19.0.0.0/dbhome_1}"
DBAASCLI="${DBAASCLI:-/usr/bin/dbaascli}"
mkdir -p "$LOG_DIR"

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

info(){ echo "${C_BLUE}INFO${C_RESET}: $*"; }
ok(){ echo "${C_GREEN}OK${C_RESET}: $*"; }
warn(){ echo "${C_YELLOW}WARN${C_RESET}: $*"; }
fail(){ echo "${C_RED}ERROR${C_RESET}: $*"; }
die(){ fail "$*"; exit 1; }

start_logging(){
  local prefix="$1"
  RUN_TS="$(date +%Y%m%d_%H%M%S)"
  MASTER_LOG="$LOG_DIR/${prefix}_${RUN_TS}.log"
  SUMMARY_FILE="$LOG_DIR/${prefix}_summary_${RUN_TS}.txt"
  exec > >(tee -a "$MASTER_LOG") 2>&1
}

print_banner(){
  local purpose="$1" mode="${2:-Execute}" target="${3:-ALL}"
  {
    echo
    printf '%0.s_' {1..120}; echo
    echo "Script      : $SCRIPT_NAME"
    echo "Purpose     : $purpose"
    echo "Author      : $ODAA_AUTHOR"
    echo "Company     : $ODAA_COMPANY"
    echo "Version     : $ODAA_VERSION"
    echo "Mode        : $mode"
    echo "INI         : $INI_FILE"
    echo "Target DB   : $target"
    echo "Start       : $(date)"
    echo "Master Log  : ${MASTER_LOG:-N/A}"
    echo "Summary Log : ${SUMMARY_FILE:-N/A}"
    printf '%0.s_' {1..120}; echo
  } | tee "${SUMMARY_FILE:-/dev/null}"
}

require_file(){ [[ -f "$1" ]] || die "Required file not found: $1"; }
require_readable(){ [[ -r "$1" ]] || die "File is not readable: $1"; }
require_dbaascli(){ [[ -x "$DBAASCLI" ]] || command -v dbaascli >/dev/null 2>&1 || die "dbaascli not found. Expected $DBAASCLI or in PATH"; }

relaunch_as_oracle(){
  if [[ "$(id -un)" != "oracle" ]]; then
    info "Re-launching as oracle user..."
    exec sudo -iu oracle env SCRIPT_HOME="$SCRIPT_HOME" INI_FILE="$INI_FILE" LOG_DIR="$LOG_DIR" ORACLE_HOME="$DEFAULT_ORACLE_HOME" DBAASCLI="$DBAASCLI" "$SCRIPT_PATH" "$@"
  fi
}

normalize_flag(){ echo "${1:-N}" | tr '[:lower:]' '[:upper:]' | xargs; }

is_selected_db(){
  local db="$1" filter="${2:-ALL}"
  [[ "$filter" == "ALL" || -z "$filter" ]] && return 0
  IFS=',' read -ra arr <<< "$filter"
  for x in "${arr[@]}"; do [[ "$(echo "$x"|xargs)" == "$db" ]] && return 0; done
  return 1
}

ini_rows(){
  require_file "$INI_FILE"
  tail -n +2 "$INI_FILE" | sed '/^[[:space:]]*$/d;/^[[:space:]]*#/d'
}

summ(){ echo "$*" | tee -a "$SUMMARY_FILE"; }

db_exists(){
  local db="$1"
  sudo "$DBAASCLI" database list 2>/dev/null | awk -F= '/DB Name/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | grep -Eixq "$db"
}

dbaascli_version(){ sudo "$DBAASCLI" version 2>/dev/null || sudo "$DBAASCLI" --version 2>/dev/null || true; }

run_cmd(){
  local test_mode="$1"; shift
  if [[ "$test_mode" == "true" ]]; then
    echo "TEST MODE: $*"
  else
    "$@"
  fi
}
