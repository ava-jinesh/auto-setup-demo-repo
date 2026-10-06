#!/usr/bin/env bash
#
# Rotate GitHub Actions secrets and variables across one or more repositories.
# Authenticates as a GitHub App (default) or your personal gh session (--personal-auth).
#
# Usage: ./rotate-secrets.sh [--repo owner/name] [--secret NAME[@env]] [--var NAME[@env]] [--personal-auth] [--dry-run]
# See README.md for setup and required GitHub App permissions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_FILE="$SCRIPT_DIR/repos.conf"
SECRETS_FILE="$SCRIPT_DIR/secrets.conf"
VARS_FILE="$SCRIPT_DIR/vars.conf"
API="https://api.github.com"

DRY_RUN=false
PERSONAL_AUTH=false
declare -a CLI_REPOS=() CLI_SECRETS=() CLI_VARS=() MINTED_TOKENS=()

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }
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
    --personal-auth) PERSONAL_AUTH=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      usage 0 ;;
    *)              printf 'unknown argument: %s\n' "$1" >&2; usage 1 ;;
  esac
done

# --- preflight ---------------------------------------------------------------

for cmd in gh openssl curl; do
  command -v "$cmd" >/dev/null || die "$cmd is not installed or not on PATH"
done
JQ="$(command -v jq 2>/dev/null || true)"

if $PERSONAL_AUTH; then
  PERSONAL_TOKEN=$(gh auth token 2>/dev/null) \
    || die "not logged in to gh — run: gh auth login"
  [[ -n $PERSONAL_TOKEN ]] || die "gh auth token returned empty — run: gh auth login"
else
  [[ -n ${GH_APP_ID:-} ]] || die "set GH_APP_ID to the App ID shown on your GitHub App settings page"
  [[ -n ${GH_APP_PRIVATE_KEY:-} ]] || die "set GH_APP_PRIVATE_KEY to the path of the .pem private key you generated for the App"
  [[ -r $GH_APP_PRIVATE_KEY ]] || die "cannot read private key: $GH_APP_PRIVATE_KEY"
  openssl pkey -in "$GH_APP_PRIVATE_KEY" -noout 2>/dev/null \
    || die "$GH_APP_PRIVATE_KEY is not a valid PEM private key (re-download it from the App settings page)"
fi

# Installation tokens live an hour; revoke them on exit (no-op in personal-auth mode).
cleanup() {
  local t
  for t in ${MINTED_TOKENS[@]+"${MINTED_TOKENS[@]}"}; do
    curl -sS -X DELETE -H "Authorization: Bearer $t" \
      -H "Accept: application/vnd.github+json" "$API/installation/token" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

# --- config ------------------------------------------------------------------

# Strips comments, blank lines and Windows CR, then de-duplicates.
read_conf() {
  [[ -f $1 ]] || die "config file not found: $1"
  sed -e 's/\r$//' -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | awk 'NF && !seen[$0]++'
}

# Optional conf file: same as read_conf but silently skips if file is absent.
read_conf_optional() {
  [[ -f $1 ]] || return 0
  sed -e 's/\r$//' -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | awk 'NF && !seen[$0]++'
}

declare -a REPOS=() SECRET_SPECS=() VAR_SPECS=()

if [[ ${#CLI_REPOS[@]} -gt 0 ]]; then
  REPOS=("${CLI_REPOS[@]}")
else
  while IFS= read -r line; do REPOS+=("$line"); done < <(read_conf "$REPOS_FILE")
fi

# If any --secret or --var is given on the CLI, run in CLI mode: use only what
# was explicitly listed and ignore both config files entirely.
CLI_MODE=false
[[ ${#CLI_SECRETS[@]} -gt 0 || ${#CLI_VARS[@]} -gt 0 ]] && CLI_MODE=true

if $CLI_MODE; then
  SECRET_SPECS=("${CLI_SECRETS[@]}")
  VAR_SPECS=("${CLI_VARS[@]}")
else
  while IFS= read -r line; do SECRET_SPECS+=("$line"); done < <(read_conf "$SECRETS_FILE")
  while IFS= read -r line; do VAR_SPECS+=("$line"); done < <(read_conf_optional "$VARS_FILE")
fi

[[ ${#REPOS[@]} -gt 0 ]] || die "no repositories configured (see $REPOS_FILE)"
[[ ${#SECRET_SPECS[@]} -gt 0 || ${#VAR_SPECS[@]} -gt 0 ]] \
  || die "nothing to do — add entries to secrets.conf or vars.conf, or pass --secret / --var"

for repo in "${REPOS[@]}"; do
  [[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    || die "invalid repository '$repo' (expected owner/name)"
done

# Parse and validate a spec list (NAME or NAME@env).
# Populates parallel NAMES and ENVS arrays; sets NEED_ENV=true for env-scoped entries.
parse_specs() {
  local kind=$1; shift
  local -n _names=$1 _envs=$2; shift 2
  local spec name env
  for spec in "$@"; do
    name="${spec%%@*}"; env=""
    [[ $spec == *@* ]] && env="${spec#*@}"
    [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
      || die "invalid $kind name '$name' (letters, digits and underscore only; cannot start with a digit)"
    [[ $name == GITHUB_* ]] && die "$kind name '$name' is reserved: GitHub rejects the GITHUB_ prefix"
    if [[ -n $env ]]; then
      [[ $env =~ ^[A-Za-z0-9._\ -]+$ ]] || die "invalid environment name '$env' in '$spec'"
      NEED_ENV=true
    fi
    _names+=("$name"); _envs+=("$env")
  done
}

NEED_ENV=false
NEED_VARS=false
declare -a S_NAMES=() S_ENVS=() V_NAMES=() V_ENVS=()
[[ ${#SECRET_SPECS[@]} -gt 0 ]] && parse_specs "secret" S_NAMES S_ENVS "${SECRET_SPECS[@]}"
if [[ ${#VAR_SPECS[@]} -gt 0 ]]; then
  parse_specs "variable" V_NAMES V_ENVS "${VAR_SPECS[@]}"
  NEED_VARS=true
fi

# --- github app auth ---------------------------------------------------------

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

mint_jwt() {
  local now header payload signing_input sig
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$GH_APP_ID" | b64url)
  signing_input="$header.$payload"
  sig=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$GH_APP_PRIVATE_KEY" -binary | b64url)
  printf '%s.%s' "$signing_input" "$sig"
}

# Pulls a top-level key out of a JSON object on stdin.
extract() {
  local key=$1 body
  body=$(cat)
  if [[ -n $JQ ]]; then
    printf '%s' "$body" | "$JQ" -r --arg k "$key" '.[$k] // empty'
  else
    printf '%s' "$body" \
      | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|[0-9]\+\)" \
      | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/^"//; s/"$//'
  fi
}

app_api() {
  local method=$1 path=$2 body=${3:-} out code
  local -a args=(-sS -X "$method"
    -H "Authorization: Bearer $(mint_jwt)"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
    -w $'\n%{http_code}')
  [[ -n $body ]] && args+=(-H "Content-Type: application/json" -d "$body")
  out=$(curl "${args[@]}" "$API$path")
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  [[ $code == 2* ]] || { printf '%s\n' "$body" >&2; return 1; }
  printf '%s' "$body"
}

# One installation token per owner, scoped to just the repos and permissions we need.
mint_installation_token() {
  local owner=$1; shift
  local install_id perms repo_list token
  install_id=$(app_api GET "/repos/$owner/$1/installation" | extract id) \
    || die "the GitHub App is not installed on $owner/$1 (or the App ID / private key is wrong)"
  [[ -n $install_id ]] || die "could not resolve an installation id for $owner"

  perms='"metadata":"read"'
  [[ ${#S_NAMES[@]} -gt 0 ]] && perms="$perms,\"secrets\":\"write\""
  $NEED_VARS                  && perms="$perms,\"variables\":\"write\""
  $NEED_ENV                   && perms="$perms,\"environments\":\"write\""
  repo_list=""
  for r in "$@"; do repo_list+="${repo_list:+,}\"$r\""; done

  token=$(app_api POST "/app/installations/$install_id/access_tokens" \
    "{\"repositories\":[$repo_list],\"permissions\":{$perms}}" | extract token) \
    || die "could not mint an installation token for $owner — check the App's permissions (see README.md)"
  [[ -n $token ]] || die "GitHub returned an empty installation token for $owner"
  MINTED_TOKENS+=("$token")
  printf '%s' "$token"
}

# --- collect values ----------------------------------------------------------

info "Repositories (${#REPOS[@]}):"
printf '  %s\n' "${REPOS[@]}"

if [[ ${#S_NAMES[@]} -gt 0 ]]; then
  info ""
  info "Secrets (${#S_NAMES[@]}):"
  for i in "${!S_NAMES[@]}"; do
    printf '  %s%s\n' "${S_NAMES[$i]}" "${S_ENVS[$i]:+  [env: ${S_ENVS[$i]}]}"
  done
fi

if [[ ${#V_NAMES[@]} -gt 0 ]]; then
  info ""
  info "Variables (${#V_NAMES[@]}):"
  for i in "${!V_NAMES[@]}"; do
    printf '  %s%s\n' "${V_NAMES[$i]}" "${V_ENVS[$i]:+  [env: ${V_ENVS[$i]}]}"
  done
fi

info ""

declare -a S_VALUES=() V_VALUES=()
declare -A ASKED=()

if [[ ${#S_NAMES[@]} -gt 0 ]]; then
  info "Secrets — input is hidden; a checksum is shown to confirm the value."
  info "Press Enter on an empty value to skip."
  info ""
  for i in "${!S_NAMES[@]}"; do
    name="${S_NAMES[$i]}"
    if [[ -n ${ASKED[$name]+x} ]]; then
      S_VALUES+=("${ASKED[$name]}"); continue
    fi
    printf '  %s: ' "$name"
    IFS= read -r -s value || true
    printf '\n'
    if [[ -n $value ]]; then
      printf '    sha256:%s  (%d chars)\n' \
        "$(printf '%s' "$value" | openssl dgst -sha256 -binary | openssl base64 -A | cut -c1-12)" \
        "${#value}"
    else
      printf '    (skipped)\n'
    fi
    ASKED[$name]="$value"
    S_VALUES+=("$value")
  done
  info ""
fi

unset ASKED; declare -A ASKED=()

if [[ ${#V_NAMES[@]} -gt 0 ]]; then
  info "Variables — plaintext (visible as you type). Press Enter on an empty value to skip."
  info ""
  for i in "${!V_NAMES[@]}"; do
    name="${V_NAMES[$i]}"
    if [[ -n ${ASKED[$name]+x} ]]; then
      V_VALUES+=("${ASKED[$name]}"); continue
    fi
    printf '  %s: ' "$name"
    IFS= read -r value || true
    printf '\n'
    [[ -z $value ]] && printf '    (skipped)\n'
    ASKED[$name]="$value"
    V_VALUES+=("$value")
  done
  info ""
fi

# --- apply -------------------------------------------------------------------

$DRY_RUN && info "DRY RUN — authenticating and validating, but not writing anything."
info ""

declare -A TOKENS=()
applied=0; skipped=0; failed=0

for repo in "${REPOS[@]}"; do
  owner="${repo%%/*}"

  if [[ -z ${TOKENS[$owner]+x} ]]; then
    if $PERSONAL_AUTH; then
      info "Using personal gh session for '$owner'..."
      TOKENS[$owner]="$PERSONAL_TOKEN"
    else
      declare -a owner_repos=()
      for r in "${REPOS[@]}"; do
        [[ ${r%%/*} == "$owner" ]] && owner_repos+=("${r#*/}")
      done
      info "Authenticating as GitHub App for '$owner' (${#owner_repos[@]} repo(s))..."
      TOKENS[$owner]=$(mint_installation_token "$owner" "${owner_repos[@]}")
    fi
  fi

  info "$repo"

  # Secrets
  for i in "${!S_NAMES[@]}"; do
    name="${S_NAMES[$i]}"; env="${S_ENVS[$i]}"; value="${S_VALUES[$i]}"
    label="$name${env:+ @ $env}"

    if [[ -z $value ]]; then
      printf '  -  %-42s skipped (no value entered)\n' "$label"
      skipped=$((skipped + 1)); continue
    fi

    declare -a flags=(--repo "$repo")
    [[ -n $env ]] && flags+=(--env "$env")
    $DRY_RUN && flags+=(--no-store)

    if err=$(printf '%s' "$value" \
        | GH_TOKEN="${TOKENS[$owner]}" gh secret set "$name" "${flags[@]}" 2>&1 >/dev/null); then
      $DRY_RUN \
        && printf '  ~  %-42s secret: verified, not written\n' "$label" \
        || printf '  OK %-42s secret: set\n' "$label"
      applied=$((applied + 1))
    else
      printf '  !! %-42s secret: FAILED\n' "$label"
      printf '%s\n' "$err" | sed 's/^/       /'
      failed=$((failed + 1))
    fi
  done

  # Variables
  for i in "${!V_NAMES[@]}"; do
    name="${V_NAMES[$i]}"; env="${V_ENVS[$i]}"; value="${V_VALUES[$i]}"
    label="$name${env:+ @ $env}"

    if [[ -z $value ]]; then
      printf '  -  %-42s skipped (no value entered)\n' "$label"
      skipped=$((skipped + 1)); continue
    fi

    if $DRY_RUN; then
      printf '  ~  %-42s variable: would set\n' "$label"
      applied=$((applied + 1)); continue
    fi

    declare -a flags=(--repo "$repo")
    [[ -n $env ]] && flags+=(--env "$env")

    if err=$(printf '%s' "$value" \
        | GH_TOKEN="${TOKENS[$owner]}" gh variable set "$name" "${flags[@]}" 2>&1); then
      printf '  OK %-42s variable: set\n' "$label"
      applied=$((applied + 1))
    else
      printf '  !! %-42s variable: FAILED\n' "$label"
      printf '%s\n' "$err" | sed 's/^/       /'
      failed=$((failed + 1))
    fi
  done
done

info ""
info "----------------------------------------"
printf 'applied: %d   skipped: %d   failed: %d\n' "$applied" "$skipped" "$failed"
[[ $failed -eq 0 ]] || exit 1
