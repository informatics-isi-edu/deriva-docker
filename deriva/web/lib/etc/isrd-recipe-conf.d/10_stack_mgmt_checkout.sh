isrd_checkout_code() {
  # Ref may be branch-ish (e.g., origin/master) or tag-ish (e.g., v1.2.3) depending on resolve_checkout_ref().
  declare -A DEFAULT_REF=(
    [webauthn]="origin/session_resource_arg"
    [credenza]="origin/m2m_support"
    [ermrest]="origin/master"
    [hatrac]="origin/S3-signature-version-fix"
    [ermresolve]="origin/master"
    [deriva-web]="origin/package-namespace-refactor"
    [deriva-py]="origin/master"
    [ermrestjs]="origin/master"
    [chaise]="origin/master"
  )

  local mod default want repo ref
  local -a mods

  # Stable order (no separate MODULES list)
  mapfile -t mods < <(printf '%s\n' "${!DEFAULT_REF[@]}" | LC_ALL=C sort)

  for mod in "${mods[@]}"; do
    default="${DEFAULT_REF[$mod]}"

    # effective_ref_for implements:
    #   1) per-module override (e.g., WEBAUTHN_TAG)
    #   2) global RELEASE_TAG fallback
    #   3) otherwise the provided default
    want="$(effective_ref_for "$mod" "$default")"

    repo="/home/${DEVUSER}/${mod}"

    # resolve_checkout_ref decides whether "want" is a tag or branch-ish ref
    # and returns something acceptable to git_checkout.
    ref="$(resolve_checkout_ref "$repo" "$want")"

    # Use explicit repo path (avoids relying on short-form name resolution)
    git_checkout "$repo" "$ref"
  done

  # Optional static site repo, not part of DEFAULT_REF map
  if [[ -n "${STATIC_SITE_NAME:-}" ]]; then
    default="origin/main"
    want="$(effective_ref_for "$STATIC_SITE_NAME" "$default")"
    repo="/home/${DEVUSER}/${STATIC_SITE_NAME}"
    ref="$(resolve_checkout_ref "$repo" "$want")"
    git_checkout "$repo" "$ref"
  fi
}

# Turn "module-name" into "MODULE_NAME_TAG"
module_tag_var_name() {
  local mod="$1"
  # Uppercase + replace '-' with '_' then append _TAG
  printf '%s_TAG' "$(printf '%s' "$mod" | tr '[:lower:]-' '[:upper:]_')"
}

# Decide which ref the module wants:
#  1) <MODULE>_TAG env var wins
#  2) RELEASE_TAG (global) next
#  3) per-module default fallback
effective_ref_for() {
  local mod="$1"
  local default_ref="$2"
  local var
  var="$(module_tag_var_name "$mod")"

  # Use ${!var-} so this remains safe under "set -u"
  if [[ -n "${!var-}" ]]; then
    printf '%s' "${!var}"
  elif [[ -n "${RELEASE_TAG:-}" ]]; then
    printf '%s' "${RELEASE_TAG}"
  else
    printf '%s' "${default_ref}"
  fi
}

# Make ref explicit for git_checkout, without modifying git_checkout:
# - refs/*, origin/*, and HEAD-ish/special rev syntaxes: pass through
# - SHA: pass through (validated via regex)
# - branch-ish with slash (e.g., feature/foo): prefer origin/<name> if it exists
# - bare name: prefer tag, then origin branch, else passthrough
resolve_checkout_ref() {
  local repo="$1"
  local ref="$2"

  [[ -z "$ref" ]] && { printf '%s' ""; return 0; }

  # Ensure our local view of tags/remotes is fresh before probing show-ref.
  # (git_checkout does its own fetch too, but we need this for correct resolution.)
  git -C "$repo" fetch --tags --quiet 2>/dev/null || true

  # Pass through explicit forms (or things we shouldn't second-guess)
  case "$ref" in
    refs/*|origin/*|HEAD*|*@\{*\}|*~*|*^*)
      printf '%s' "$ref"
      return 0
      ;;
  esac

  # If it's a SHA (short or full), pass through.
  if [[ "$ref" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    printf '%s' "$ref"
    return 0
  fi

  # If it contains a slash (e.g., feature/foo), it's *probably* a branch-ish name.
  # Prefer origin/<name> if it exists, otherwise pass through.
  if [[ "$ref" == */* ]]; then
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
      printf 'origin/%s' "$ref"
    else
      printf '%s' "$ref"
    fi
    return 0
  fi

  # Bare name: prefer tag, then origin branch, else passthrough.
  if git -C "$repo" show-ref --verify --quiet "refs/tags/$ref"; then
    printf '%s' "$ref"
  elif git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
    printf 'origin/%s' "$ref"
  else
    printf '%s' "$ref"
  fi
}
