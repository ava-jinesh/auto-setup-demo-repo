#!/usr/bin/env bash

# Set GitHub Actions secrets and variables using your personal gh session.
# No GitHub App, no private key — just gh auth login and admin rights on the repos.

# Usage: ./set-var-sec.sh /OR/ ./set-var-sec.sh [--repo owner/name] [--secret NAME[@env]] [--var NAME[@env]] [--dry-run]


set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_FILE="$SCRIPT_DIR/repos.conf"
SECRETS_FILE="$SCRIPT_DIR/secrets.conf"
VARS_FILE="$SCRIPT_DIR/vars.conf"

DRY_RUN=false
declare -a CLI_REPOS=() CLI_SECRETS=() CLI_VARS=()

die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

usage() {
  awk 'NR<3 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)         CLI_REPOS+=("${2:?--repo needs a value}"); shift 2 ;;
    --secret)       CLI_SECRETS+=("${2:?--secret needs a value}"); shift 2 ;;
    --var)          CLI_VARS+=("${2:?--var needs a value}"); shift 2 ;;
    --repos-file)   REPOS_FILE="${2:?}"; shift 2 ;;
    --secrets-file) SECRETS_FILE="${2:?}"; shift 2 ;;
    --vars-file)    VARS_FILE="${2:?}"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      usage 0 ;;
    *)              printf 'unknown argument: %s\n' "$1" >&2; usage 1 ;;
  esac
done

# --- preflight ---------------------------------------------------------------

command -v gh      >/dev/null || die "gh is not installed or not on PATH"
command -v openssl >/dev/null || die "openssl is not installed or not on PATH"

GH_TOKEN=$(gh auth token 2>/dev/null) || die "not logged in to gh — run: gh auth login"
[[ -n $GH_TOKEN ]] || die "gh auth token returned empty — run: gh auth login"

# --- config ------------------------------------------------------------------

read_conf() {
  [[ -f $1 ]] || die "config file not found: $1"
  sed -e 's/\r$//' -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" \
    | awk 'NF && !seen[$0]++'
}

read_conf_optional() {
  [[ -f $1 ]] || return 0
  sed -e 's/\r$//' -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" \
    | awk 'NF && !seen[$0]++'
}

declare -a REPOS=() SECRET_SPECS=() VAR_SPECS=()

if [[ ${#CLI_REPOS[@]} -gt 0 ]]; then
  REPOS=("${CLI_REPOS[@]}")
else
  while IFS= read -r line; do REPOS+=("$line"); done < <(read_conf "$REPOS_FILE")
fi

# CLI mode: --secret or --var on the command line ignores both config files.
if [[ ${#CLI_SECRETS[@]} -gt 0 || ${#CLI_VARS[@]} -gt 0 ]]; then
  SECRET_SPECS=("${CLI_SECRETS[@]}")
  VAR_SPECS=("${CLI_VARS[@]}")
else
  while IFS= read -r line; do SECRET_SPECS+=("$line"); done < <(read_conf "$SECRETS_FILE")
  while IFS= read -r line; do VAR_SPECS+=("$line");   done < <(read_conf_optional "$VARS_FILE")
fi

[[ ${#REPOS[@]} -gt 0 ]] || die "no repositories configured (see $REPOS_FILE)"
[[ ${#SECRET_SPECS[@]} -gt 0 || ${#VAR_SPECS[@]} -gt 0 ]] \
  || die "nothing to do — add entries to secrets.conf or vars.conf, or pass --secret / --var"

for repo in "${REPOS[@]}"; do
  [[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    || die "invalid repository '$repo' (expected owner/name)"
done

# Parse NAME or NAME@env specs; validate names.
parse_specs() {
  local kind=$1; shift
  local -n _names=$1 _envs=$2; shift 2
  local spec name env
  for spec in "$@"; do
    name="${spec%%@*}"; env=""
    [[ $spec == *@* ]] && env="${spec#*@}"
    [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
      || die "invalid $kind name '$name' (letters, digits and underscore only; cannot start with a digit)"
    [[ $name == GITHUB_* ]] \
      && die "$kind name '$name' is reserved: GitHub rejects the GITHUB_ prefix"
    [[ -n $env ]] && { [[ $env =~ ^[A-Za-z0-9._\ -]+$ ]] \
      || die "invalid environment name '$env' in '$spec'"; }
    _names+=("$name"); _envs+=("$env")
  done
}

declare -a S_NAMES=() S_ENVS=() V_NAMES=() V_ENVS=()
[[ ${#SECRET_SPECS[@]} -gt 0 ]] && parse_specs "secret"   S_NAMES S_ENVS "${SECRET_SPECS[@]}"
[[ ${#VAR_SPECS[@]}    -gt 0 ]] && parse_specs "variable"  V_NAMES V_ENVS "${VAR_SPECS[@]}"

# --- collect values ----------------------------------------------------------

info "Repositories (${#REPOS[@]}):"
printf '  %s\n' "${REPOS[@]}"

if [[ ${#S_NAMES[@]} -gt 0 ]]; then
  info ""; info "Secrets (${#S_NAMES[@]}):"
  for i in "${!S_NAMES[@]}"; do
    printf '  %s%s\n' "${S_NAMES[$i]}" "${S_ENVS[$i]:+  [env: ${S_ENVS[$i]}]}"
  done
fi

if [[ ${#V_NAMES[@]} -gt 0 ]]; then
  info ""; info "Variables (${#V_NAMES[@]}):"
  for i in "${!V_NAMES[@]}"; do
    printf '  %s%s\n' "${V_NAMES[$i]}" "${V_ENVS[$i]:+  [env: ${V_ENVS[$i]}]}"
  done
fi

info ""

declare -a S_VALUES=() V_VALUES=()
declare -A ASKED=()

if [[ ${#S_NAMES[@]} -gt 0 ]]; then
  info "Secrets — input is hidden. Press Enter to skip."
  info ""
  for i in "${!S_NAMES[@]}"; do
    name="${S_NAMES[$i]}"
    if [[ -n ${ASKED[$name]+x} ]]; then S_VALUES+=("${ASKED[$name]}"); continue; fi
    printf '  %s: ' "$name"
    IFS= read -r -s value || true; printf '\n'
    if [[ -n $value ]]; then
      printf '    sha256:%s  (%d chars)\n' \
        "$(printf '%s' "$value" | openssl dgst -sha256 -binary | openssl base64 -A | cut -c1-12)" \
        "${#value}"
    else
      printf '    (skipped)\n'
    fi
    ASKED[$name]="$value"; S_VALUES+=("$value")
  done
  info ""
fi

unset ASKED; declare -A ASKED=()

if [[ ${#V_NAMES[@]} -gt 0 ]]; then
  info "Variables — plaintext. Press Enter to skip."
  info ""
  for i in "${!V_NAMES[@]}"; do
    name="${V_NAMES[$i]}"
    if [[ -n ${ASKED[$name]+x} ]]; then V_VALUES+=("${ASKED[$name]}"); continue; fi
    printf '  %s: ' "$name"
    IFS= read -r value || true; printf '\n'
    [[ -z $value ]] && printf '    (skipped)\n'
    ASKED[$name]="$value"; V_VALUES+=("$value")
  done
  info ""
fi

# --- apply -------------------------------------------------------------------

$DRY_RUN && info "DRY RUN — will validate secrets but not write anything."
info ""

applied=0; skipped=0; failed=0

for repo in "${REPOS[@]}"; do
  info "$repo"

  for i in "${!S_NAMES[@]}"; do
    name="${S_NAMES[$i]}"; env="${S_ENVS[$i]}"; value="${S_VALUES[$i]}"
    label="$name${env:+ @ $env}"

    if [[ -z $value ]]; then
      printf '  -  %-42s skipped\n' "$label"; skipped=$((skipped+1)); continue
    fi

    declare -a flags=(--repo "$repo")
    [[ -n $env ]]  && flags+=(--env "$env")
    $DRY_RUN       && flags+=(--no-store)

    if err=$(printf '%s' "$value" \
        | GH_TOKEN="$GH_TOKEN" gh secret set "$name" "${flags[@]}" 2>&1 >/dev/null); then
      $DRY_RUN \
        && printf '  ~  %-42s secret: verified, not written\n' "$label" \
        || printf '  OK %-42s secret: set\n' "$label"
      applied=$((applied+1))
    else
      printf '  !! %-42s secret: FAILED\n' "$label"
      printf '%s\n' "$err" | sed 's/^/       /'
      failed=$((failed+1))
    fi
  done

  for i in "${!V_NAMES[@]}"; do
    name="${V_NAMES[$i]}"; env="${V_ENVS[$i]}"; value="${V_VALUES[$i]}"
    label="$name${env:+ @ $env}"

    if [[ -z $value ]]; then
      printf '  -  %-42s skipped\n' "$label"; skipped=$((skipped+1)); continue
    fi

    if $DRY_RUN; then
      printf '  ~  %-42s variable: would set\n' "$label"
      applied=$((applied+1)); continue
    fi

    declare -a flags=(--repo "$repo")
    [[ -n $env ]] && flags+=(--env "$env")

    if err=$(printf '%s' "$value" \
        | GH_TOKEN="$GH_TOKEN" gh variable set "$name" "${flags[@]}" 2>&1); then
      printf '  OK %-42s variable: set\n' "$label"
      applied=$((applied+1))
    else
      printf '  !! %-42s variable: FAILED\n' "$label"
      printf '%s\n' "$err" | sed 's/^/       /'
      failed=$((failed+1))
    fi
  done
done

info ""
info "----------------------------------------"
printf 'applied: %d   skipped: %d   failed: %d\n' "$applied" "$skipped" "$failed"
[[ $failed -eq 0 ]] || exit 1
