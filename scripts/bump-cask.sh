#!/usr/bin/env bash
#
# Bump one cask in this tap to the latest stable upstream release.
#
# Pull-based by design: this tap polls the app repositories instead of each
# app repo pushing a bump into it. Two reasons.
#
#   1. A push needs a cross-repo credential. GITHUB_TOKEN is scoped to the
#      single repository running the workflow, no matter who owns the rest,
#      so a push-based bump means a PAT or deploy key duplicated into every
#      app repo. Polling needs no secret at all — release metadata for a
#      public repo is public.
#   2. A missed push stays missed. Entracte's in-repo bump failed silently on
#      eleven consecutive releases and left the cask stranded, because nothing
#      retried (drmowinckels/entracte#349). A poller compares desired state to
#      actual state on every tick, so the next run picks up whatever the last
#      one dropped.
#
# Usage: scripts/bump-cask.sh <cask-token>
#
# Exits 0 and prints a reason when there is nothing to do, so a scheduled
# caller can run it unconditionally. GH_TOKEN is optional and only lifts the
# unauthenticated API rate limit.

set -euo pipefail

die() {
  echo "::error::$*" >&2
  exit 1
}

# `sed -i` takes an argument on BSD/macOS and not on GNU, and `sha256sum` is
# GNU-only. Both are wrapped so the script runs identically under CI and under
# a maintainer's local `test/bump-cask.test.sh` on a Mac.
rewrite() {
  local expr="$1" file="$2" tmp
  tmp=$(mktemp)
  sed -E "$expr" "$file" >"$tmp"
  mv "$tmp" "$file"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

token="${1:-}"
[ -n "$token" ] || die "usage: $0 <cask-token>"

cask="Casks/${token}.rb"
[ -f "$cask" ] || die "no such cask: ${cask}"

# Each `assets` entry is "<key>|<asset-name-template>". The key is the literal
# text standing in front of the checksum in the cask file — "arm:", "intel:",
# or empty for a cask with a single universal build. VERSION is substituted.
case "$token" in
entracte)
  repo="drmowinckels/entracte"
  assets=("arm:|Entracte_VERSION_aarch64.dmg" "intel:|Entracte_VERSION_x64.dmg")
  ;;
cairn)
  repo="drmowinckels/cairn"
  assets=("|Cairn_VERSION_universal.dmg")
  ;;
*)
  die "no upstream configuration for '${token}' — add a case in $0"
  ;;
esac

tag=$(gh release list --repo "$repo" \
  --exclude-drafts --exclude-pre-releases \
  --limit 1 --json tagName --jq '.[0].tagName // empty')

if [ -z "$tag" ]; then
  echo "${token}: ${repo} has no stable release yet — nothing to do"
  exit 0
fi

version="${tag#v}"

# `$version` is interpolated into sed expressions and asset names below. It
# comes from the GitHub API rather than from a user, so this is not an
# injection guard — git simply permits characters in a ref name (`|` among
# them) that would corrupt a sed expression into a confusing failure several
# steps later. Reject the shape up front instead.
if ! printf '%s' "$version" | grep -Eq '^[0-9A-Za-z._-]+$'; then
  die "refusing tag '${tag}': version '${version}' has characters outside [0-9A-Za-z._-]"
fi

current=$(sed -n -E 's/^  version "([^"]+)"$/\1/p' "$cask" | head -1)
[ -n "$current" ] || die "could not read the current version out of ${cask}"

if [ "$current" = "$version" ]; then
  echo "${token}: already at ${version}"
  exit 0
fi

# A poller can move backwards in a way a release-triggered push cannot: if the
# newest stable release is deleted or un-published, `releases/latest` silently
# resolves to its predecessor and the next tick would hand every `brew upgrade`
# user a downgrade. Refuse instead, loudly.
newest=$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -1)
if [ "$newest" != "$version" ]; then
  die "refusing to move ${token} backwards: cask is at ${current}, latest stable release of ${repo} is ${version}"
fi

work=$(mktemp -d)
# shellcheck disable=SC2064  # expand $work now; it is gone by trap time otherwise
trap "rm -rf '$work'" EXIT

sums_file="${work}/SHA256SUMS.txt"
gh release download "$tag" --repo "$repo" \
  --pattern SHA256SUMS.txt --dir "$work" >/dev/null 2>&1 || true

sha_for() {
  local asset="$1" sum=""

  if [ -f "$sums_file" ]; then
    sum=$(awk -v f="$asset" '$2 == f { print $1 }' "$sums_file")
  fi

  if [ -z "$sum" ]; then
    gh release download "$tag" --repo "$repo" \
      --pattern "$asset" --dir "$work" >/dev/null 2>&1 ||
      die "release ${tag} of ${repo} publishes no asset named '${asset}'"
    sum=$(sha256_of "${work}/${asset}")
  fi

  printf '%s' "$sum"
}

sums=()
for entry in "${assets[@]}"; do
  key="${entry%%|*}"
  asset="${entry#*|}"
  asset="${asset//VERSION/$version}"

  sum=$(sha_for "$asset")
  printf '%s' "$sum" | grep -Eq '^[0-9a-f]{64}$' ||
    die "'${sum}' is not a sha256 (asset ${asset})"

  if [ -n "$key" ]; then
    rewrite "s|^([[:space:]]*(sha256[[:space:]]+)?${key}[[:space:]]+\")[0-9a-f]{64}(\")|\1${sum}\3|" "$cask"
  else
    rewrite "s|^([[:space:]]*sha256[[:space:]]+\")[0-9a-f]{64}(\")|\1${sum}\2|" "$cask"
  fi

  grep -qF "$sum" "$cask" || die "checksum for ${asset} did not land in ${cask}"
  sums+=("${key:-sha256} ${sum}")
done

rewrite "s|^(  version \")[^\"]+(\")|\1${version}\2|" "$cask"

# Re-read the stanza rather than grepping for the version string. A substring
# search answers the wrong question: bumping a long-stranded cask from 0.0.1 to
# 0.0.14 leaves "0.0.1" findable inside "0.0.14", so a `grep -F "$current"`
# guard fails the run precisely in the recover-from-neglect case this whole
# design exists to handle.
after=$(sed -n -E 's/^  version "([^"]+)"$/\1/p' "$cask" | head -1)
[ "$after" = "$version" ] || die "version line reads '${after}' after the bump, expected '${version}'"

echo "${token}: ${current} -> ${version}"
for s in "${sums[@]}"; do
  echo "  ${s}"
done

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "bumped=true"
    echo "token=${token}"
    echo "version=${version}"
    echo "previous=${current}"
  } >>"$GITHUB_OUTPUT"
fi
