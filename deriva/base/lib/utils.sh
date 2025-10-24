#!/bin/bash

# lib/utils.sh - Shared shell functions

log() {
  local tag="$1"; shift
  echo "$(date +'%Y-%m-%dT%H:%M:%S.%3N%:z') [$tag] $*"
}

require_envs() { for v in "$@"; do eval '[ -n "${'"$v"':-}" ]' || \
 { echo "Missing expected environment variable $v" >&2; return 1; }; done; }

# envsubst-like template substitution
# Usage:
#   substitute_env_vars template.in output.out                # use all env vars
#   substitute_env_vars template.in output.out "${FOO} ${BAR}"# only FOO,BAR
substitute_env_vars() {
  local template_file="$1"
  local output_file="$2"
  local var_list="${3:-}"

  local sed_expr=""

  if [[ -n "$var_list" ]]; then
    # Replace only the variables named in var_list (e.g. "${FOO} ${BAR}")
    local token name value escaped
    for token in $var_list; do
      # Accept ${NAME}, $NAME, or NAME; normalize to NAME
      case "$token" in
        \${*}) name="${token#\${}"; name="${name%\}}" ;;
        \$*)   name="${token#\$}" ;;
        *)     name="$token" ;;
      esac
      # Indirect expand (empty if unset, like envsubst)
      value="${!name-}"
      # Escape for sed replacement (we use '|' as delimiter)
      escaped="${value//\\/\\\\}"   # \ -> \\
      escaped="${escaped//&/\\&}"   # & -> \&
      escaped="${escaped//|/\\|}"   # | -> \|
      sed_expr+="s|\${$name}|$escaped|g;"
    done
  else
    # Fallback: use every exported var from `env`
    local name value escaped
    # Read NAME=VALUE lines; VALUE may contain '=' — the last field gets the rest
    while IFS='=' read -r name value; do
      [[ -z "$name" || "$name" == "_" ]] && continue
      escaped="${value//\\/\\\\}"
      escaped="${escaped//&/\\&}"
      escaped="${escaped//|/\\|}"
      sed_expr+="s|\${$name}|$escaped|g;"
    done < <(env)
  fi

  sed "$sed_expr" "$template_file" > "$output_file"
}

# inject a secret read from a file into an environment variable
inject_secret() {
  local file_glob="$1"
  local var_name="$2"

  for file in $file_glob; do
    if [[ -f "$file" ]]; then
      local value
      value=$(tr -d '\r\n' < "$file")
      export "$var_name=$value"
      return 0
    fi
  done

  log "Secret not found: $file_glob"
  return 1
}
