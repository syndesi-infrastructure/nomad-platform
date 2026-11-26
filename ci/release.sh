#!/usr/bin/env bash
# Release helper, used by .github/workflows/release.yml and runnable locally (it only edits VERSION and CHANGELOG.md, nothing is committed):
#   release.sh next <patch|minor|major>   print the next version
#   release.sh prepare <patch|minor|major> bump VERSION, turn "## Unreleased" of CHANGELOG.md into "## <version> (<date>)", print the version
#   release.sh check                      fail when a line marked x-release-version names another version than VERSION
#   release.sh notes <version>            print the changelog section of <version> (the GitHub release notes)
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "release: $*" >&2; exit 1; }

next_version() { # <type>
  local current major minor patch
  current=$(tr -d '[:space:]' < VERSION)
  [[ $current =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "VERSION is not x.y.z: $current"
  major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}; patch=${BASH_REMATCH[3]}
  case $1 in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
    *) die "release type must be patch, minor or major (got: ${1:-nothing})" ;;
  esac
}

# Every line that carries the marker x-release-version (in a markdown file as an html comment, in yaml as a comment) names the released
# version as vX.Y.Z; `prepare` rewrites it with sed, `check` (task ci:lint:version) fails when one was left behind. Not scanned: this
# script, the root Taskfile.yml, CHANGELOG.md and CLAUDE.md, which only talk about the marker.
marked_files() { git grep -lI 'x-release-version' -- . ':!ci/release.sh' ':!CHANGELOG.md' ':!CLAUDE.md' ':!Taskfile.yml' || true; }

# the lines of one changelog section, without its heading; the section ends at the next "## "
section() { # <heading prefix, literal>
  awk -v prefix="$1" '
    /^## / { if (on) exit; if (index($0, prefix) == 1) { on = 1; next } }
    on { print }
  ' CHANGELOG.md
}

case ${1:-} in
  next)
    next_version "${2:-}"
    ;;
  prepare)
    version=$(next_version "${2:-}")
    # VERSION must be what the last release tag says (a hand-made tag or edit would make every later release wrong); no tags: skipped
    last=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)
    [ -z "$last" ] || [ "${last#v}" = "$(tr -d '[:space:]' < VERSION)" ] || die "VERSION is $(tr -d '[:space:]' < VERSION) but the latest tag is $last: fix VERSION first"
    grep -qx '## Unreleased' CHANGELOG.md || die "CHANGELOG.md has no '## Unreleased' section"
    [ "$(grep -c '^## Unreleased$' CHANGELOG.md)" -eq 1 ] || die "CHANGELOG.md has more than one '## Unreleased' section"
    [ -n "$(section '## Unreleased' | tr -d '[:space:]')" ] || die "the '## Unreleased' section of CHANGELOG.md is empty: nothing to release"
    if grep -q "^## $version " CHANGELOG.md; then die "CHANGELOG.md already has a section for $version"; fi
    if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then die "tag v$version exists already"; fi
    # a new, empty Unreleased section stays on top
    tmp=$(mktemp)
    sed "s/^## Unreleased\$/## Unreleased\n\n## $version ($(date -u +%F))/" CHANGELOG.md > "$tmp"
    cat "$tmp" > CHANGELOG.md; rm -f "$tmp"
    echo "$version" > VERSION
    for f in $(marked_files); do sed -i -E "/x-release-version/ s/v[0-9]+\.[0-9]+\.[0-9]+/v$version/g" "$f"; done
    echo "$version"
    ;;
  check)
    current=$(tr -d '[:space:]' < VERSION); bad=0
    for f in $(marked_files); do
      while IFS= read -r line; do
        [[ $line =~ v[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "$f: marked line without a version: $line" >&2; bad=1; continue; }
        [ "$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' <<< "$line" | sort -u)" = "v$current" ] || { echo "$f: not v$current: $line" >&2; bad=1; }
      done < <(grep 'x-release-version' "$f")
    done
    [ "$bad" -eq 0 ] && echo "release: all marked versions are v$current"
    exit "$bad"
    ;;
  notes)
    version=${2:-}
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: release.sh notes <x.y.z>"
    notes=$(section "## $version ")
    [ -n "$(echo "$notes" | tr -d '[:space:]')" ] || die "no changelog section for $version"
    printf '%s\n' "$notes" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | sed '/./,$!d'
    ;;
  *)
    die "usage: release.sh next|prepare <patch|minor|major> | check | notes <version>"
    ;;
esac
