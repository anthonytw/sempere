# Gitea API helpers for the release and CI scripts (docs/design/local-first.md). Source this file.
#
#   forge_api METHOD ENDPOINT [-f key=value ...]   prints the response body; fails on any non-2xx status
#   forge_has_commit SHA                            succeeds if the forge has the commit
#   forge_post_status SHA CONTEXT STATE DESC        a commit status (state: pending|success|failure|error)
#   forge_statuses SHA                              "context<TAB>state" per context, the latest of each
#
# Requests go through `tea api`, using tea's default login for the forge. If SEMPERE_FORGE_TOKEN is set, or
# tea is missing, they go through curl with that token instead. SEMPERE_FORGE_REPO (default awertz/sempere)
# and SEMPERE_FORGE_URL (default https://git.lab.gulwertz.net) name the repository.

FORGE_REPO=${SEMPERE_FORGE_REPO:-awertz/sempere}
FORGE_URL=${SEMPERE_FORGE_URL:-https://git.lab.gulwertz.net}

forge_api() {
  local method=$1 endpoint=$2; shift 2
  if [[ -z ${SEMPERE_FORGE_TOKEN:-} ]] && command -v tea >/dev/null; then
    local body head code
    body=$(mktemp); head=$(mktemp)
    tea api -i -r "$FORGE_REPO" -X "$method" "$endpoint" "$@" >"$body" 2>"$head" || { cat "$head" >&2; rm -f "$body" "$head"; return 1; }
    code=$(sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' "$head")
    cat "$body"; rm -f "$body" "$head"
    [[ $code == 2?? ]] || { echo "forge: $method $endpoint: HTTP ${code:-?}" >&2; return 1; }
    return 0
  fi
  [[ -n ${SEMPERE_FORGE_TOKEN:-} ]] || { echo "forge: need tea (logged in to $FORGE_URL) or SEMPERE_FORGE_TOKEN" >&2; return 1; }
  local json='{}' k v
  while (($#)); do
    case $1 in
      -f) k=${2%%=*}; v=${2#*=}; json=$(jq -c --arg k "$k" --arg v "$v" '.[$k] = $v' <<<"$json"); shift 2 ;;
      *) echo "forge: unsupported argument $1" >&2; return 2 ;;
    esac
  done
  local data=()
  [[ $json != '{}' ]] && data=(-H 'Content-Type: application/json' -d "$json")
  curl -fsS -X "$method" -H "Authorization: token $SEMPERE_FORGE_TOKEN" "${data[@]}" "$FORGE_URL/api/v1/$endpoint"
}

forge_has_commit() {
  forge_api GET "repos/$FORGE_REPO/git/commits/$1" >/dev/null 2>&1
}

forge_post_status() {   # sha context state description
  forge_api POST "repos/$FORGE_REPO/statuses/$1" -f state="$3" -f context="$2" -f description="${4:0:140}" >/dev/null
}

forge_statuses() {   # sha -> "context<TAB>state", latest per context
  forge_api GET "repos/$FORGE_REPO/commits/$1/status?limit=100" \
    | jq -r '.statuses[]? | "\(.context)\t\(.status // .state)"'
}
