#!/usr/bin/env bash
# What a prod release of the umbrella's HEAD ships: for each image, the
# commit it would run, the commit prod runs now (values-prod.yaml) and
# whether it rolls. Prints a Markdown table.
#
#   infra/release-plan.sh                 run it before pressing Release
#   infra/release-plan.sh --resolve FILE  also find each image's digest on
#                                         GHCR and write "name commit digest"
#                                         lines to FILE (release.yml does)
#
# server, docs and agent are submodules: their commit is the pointer.
# website and console live in the clients submodule: their commit is the
# last clients commit that changed their folders, the one clients' CI built
# <repository>:sha-<commit> for. CLIENTS_DIR is clients' checkout. Each
# image's repository comes from values-prod.yaml.
set -euo pipefail
cd "$(dirname "$0")/.."

resolve=
if [[ ${1:-} == --resolve ]]; then resolve=${2:?--resolve needs a file}; : > "$resolve"; fi
clients=${CLIENTS_DIR:-clients}
values=infra/stack/values-prod.yaml

# name, then the submodule, then the clients paths for images built there.
components=(
  "server server"
  "website clients website brand/web"
  "docs docs"
  "console clients console"
  "agent agent"
)

commit_of() {
  local sub=$1; shift
  local pin
  pin=$(git rev-parse -q --verify "HEAD:$sub") || { echo "::error::the umbrella has no submodule $sub" >&2; exit 1; }
  if (( $# == 0 )); then echo "$pin"; return; fi
  git -C "$clients" cat-file -e "$pin^{commit}" 2>/dev/null ||
    { echo "::error::$clients does not have clients commit $pin (check out the submodule)" >&2; exit 1; }
  git -C "$clients" log -1 --format=%H "$pin" -- "$@"
}

# How many commits lie between two, when the checkout has both.
count() {
  local dir=$1 from=$2 to=$3; shift 3
  git -C "$dir" cat-file -e "$from^{commit}" 2>/dev/null && git -C "$dir" cat-file -e "$to^{commit}" 2>/dev/null || return 0
  local n; n=$(git -C "$dir" rev-list --count "$from..$to" -- "$@")
  if (( n == 1 )); then echo " (1 commit)"; else echo " ($n commits)"; fi
}

echo "| image | prod now | this release | |"
echo "|---|---|---|---|"
missing=0
for c in "${components[@]}"; do
  read -r name sub paths <<<"$c"
  # shellcheck disable=SC2086 # paths is a list of pathspecs
  new=$(commit_of "$sub" $paths)
  old=$(yq ".images.$name.commit // \"\"" "$values")
  if [[ $old == "$new" ]]; then
    note=unchanged
  else
    dir=$sub; [[ $sub == clients ]] && dir=$clients
    # shellcheck disable=SC2086
    note="rolls$(count "$dir" "$old" "$new" $paths)"
  fi
  shown=${old:0:8}
  echo "| $name | ${shown:--} | ${new:0:8} | $note |"
  if [[ -n $resolve ]]; then
    # An unchanged image keeps the digest prod runs, whatever GHCR's cleanup did since.
    pinned=$(yq ".images.$name.tag" "$values")
    if [[ $old == "$new" && $pinned == sha256:* ]]; then
      echo "$name $new $pinned" >> "$resolve"; continue
    fi
    image="$(yq ".images.$name.repository" "$values"):sha-$new"
    if digest=$(docker buildx imagetools inspect "$image" --format '{{json .Manifest}}' 2>/dev/null | jq -er .digest); then
      echo "$name $new $digest" >> "$resolve"
    else
      echo "::error::$image does not exist: CI has not built $new, or cleanup removed it (it keeps the 10 newest builds)" >&2
      missing=1
    fi
  fi
done
(( missing == 0 ))
