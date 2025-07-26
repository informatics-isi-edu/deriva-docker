#!/bin/bash

# lib/utils.sh - Shared shell functions

log() {
  local tag="$1"; shift
  echo "$(date +'%Y-%m-%dT%H:%M:%S.%3N%:z') [$tag] $*"
}

# envsubst-like template substitution using all exported environment variables
substitute_env_vars() {
  local template_file="$1"
  local output_file="$2"

  local sed_expr=""
  while IFS='=' read -r name value; do
    [[ -z "$name" || "$name" == "_" ]] && continue
    local escaped_value
    escaped_value=$(printf '%s\n' "$value" | sed 's/[&/\]/\\&/g')
    sed_expr+="s|\${$name}|$escaped_value|g;"
  done < <(env)

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
