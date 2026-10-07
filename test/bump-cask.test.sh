#!/usr/bin/env bash
#
# Tests for scripts/bump-cask.sh against a stubbed `gh`.
#
# This script is the whole reason the tap can be unattended, and its failure
# mode is quiet: a wrong checksum is a 404 or a checksum mismatch on a user's
# machine, long after the run went green. So every branch gets a case here,
# including the ones that are supposed to refuse.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
pass=0
fail=0

ok() {
  printf '  ok   %s\n' "$1"
  pass=$((pass + 1))
}

no() {
  printf '  FAIL %s\n       %s\n' "$1" "$2"
  fail=$((fail + 1))
}

expect_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ $haystack == *"$needle"* ]]; then
    ok "$label"
  else
    no "$label" "expected to find '${needle}' in: ${haystack}"
  fi
}

expect_missing() {
  local label="$1" haystack="$2" needle="$3"
  if [[ $haystack != *"$needle"* ]]; then
    ok "$label"
  else
    no "$label" "expected NOT to find '${needle}' in: ${haystack}"
  fi
}

ARM_SHA="1111111111111111111111111111111111111111111111111111111111111111"
INTEL_SHA="2222222222222222222222222222222222222222222222222222222222222222"
UNIVERSAL_BODY="cairn-universal-dmg-bytes"

sha256_of_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# Builds a sandbox holding a Casks/ dir and a `gh` on PATH that answers the two
# subcommands the script uses. STUB_TAG picks the release it reports;
# STUB_SUMS=0 makes the release carry no SHA256SUMS.txt, which drives the
# download-and-hash fallback.
setup() {
  sandbox=$(mktemp -d)
  mkdir -p "$sandbox/Casks" "$sandbox/bin"

  cat >"$sandbox/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

jq_expr=""
dir=""
pattern=""
args=("$@")
for i in "${!args[@]}"; do
  case "${args[$i]}" in
    --jq) jq_expr="${args[$((i + 1))]}" ;;
    --dir) dir="${args[$((i + 1))]}" ;;
    --pattern) pattern="${args[$((i + 1))]}" ;;
  esac
done

case "$1 $2" in
  "release list")
    json="[]"
    if [ -n "${STUB_TAG:-}" ]; then
      json="[{\"tagName\":\"${STUB_TAG}\"}]"
    fi
    if [ -n "$jq_expr" ]; then
      printf '%s' "$json" | jq -r "$jq_expr"
    else
      printf '%s' "$json"
    fi
    ;;
  "release download")
    if [ "$pattern" = "SHA256SUMS.txt" ]; then
      if [ "${STUB_SUMS:-1}" != "1" ]; then
        exit 1
      fi
      printf '%s  %s\n' "$STUB_ARM_SHA" "Entracte_${STUB_TAG#v}_aarch64.dmg" >"$dir/SHA256SUMS.txt"
      printf '%s  %s\n' "$STUB_INTEL_SHA" "Entracte_${STUB_TAG#v}_x64.dmg" >>"$dir/SHA256SUMS.txt"
    else
      if [ -z "${STUB_ASSET_BODY:-}" ]; then
        exit 1
      fi
      printf '%s' "$STUB_ASSET_BODY" >"$dir/$pattern"
    fi
    ;;
  *)
    echo "stub gh: unhandled '$*'" >&2
    exit 64
    ;;
esac
STUB
  chmod +x "$sandbox/bin/gh"

  export STUB_ARM_SHA="$ARM_SHA" STUB_INTEL_SHA="$INTEL_SHA"
  unset STUB_ASSET_BODY || true
  export STUB_SUMS=1
}

teardown() {
  rm -rf "$sandbox"
  unset STUB_TAG STUB_SUMS STUB_ASSET_BODY || true
}

dual_arch_cask() {
  cat >"$sandbox/Casks/entracte.rb" <<RUBY
cask "entracte" do
  arch arm: "aarch64", intel: "x64"

  version "$1"
  sha256 arm:   "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         intel: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  url "https://github.com/drmowinckels/entracte/releases/download/v#{version}/Entracte_#{version}_#{arch}.dmg"
  name "Entracte"
  app "Entracte.app"
end
RUBY
}

universal_cask() {
  cat >"$sandbox/Casks/cairn.rb" <<RUBY
cask "cairn" do
  version "$1"
  sha256 "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

  url "https://github.com/drmowinckels/cairn/releases/download/v#{version}/Cairn_#{version}_universal.dmg"
  name "Cairn"
  app "Cairn.app"
end
RUBY
}

run_bump() {
  (
    cd "$sandbox"
    PATH="$sandbox/bin:$PATH" bash "$root/scripts/bump-cask.sh" "$@"
  )
}

echo "scripts/bump-cask.sh"

# --- a dual-arch cask reads both checksums out of SHA256SUMS.txt ------------
setup
dual_arch_cask "0.0.12"
export STUB_TAG="v0.0.13"
if out=$(run_bump entracte 2>&1); then
  cask=$(cat "$sandbox/Casks/entracte.rb")
  expect_contains "bumps the version line" "$cask" 'version "0.0.13"'
  expect_contains "rewrites the arm checksum" "$cask" "arm:   \"${ARM_SHA}\""
  expect_contains "rewrites the intel checksum" "$cask" "intel: \"${INTEL_SHA}\""
  expect_missing "leaves no trace of the old version" "$cask" "0.0.12"
  expect_contains "reports the transition" "$out" "0.0.12 -> 0.0.13"
else
  no "bumps a dual-arch cask" "$out"
fi
teardown

# --- the no-op path --------------------------------------------------------
setup
dual_arch_cask "0.0.13"
export STUB_TAG="v0.0.13"
if out=$(run_bump entracte 2>&1); then
  expect_contains "no-ops when already current" "$out" "already at 0.0.13"
  expect_contains "leaves the file untouched when current" \
    "$(cat "$sandbox/Casks/entracte.rb")" "aaaaaaaa"
else
  no "no-ops when already current" "$out"
fi
teardown

# --- a yanked release must not become a downgrade -------------------------
setup
dual_arch_cask "0.0.13"
export STUB_TAG="v0.0.9"
if out=$(run_bump entracte 2>&1); then
  no "refuses a downgrade" "exited 0: ${out}"
else
  expect_contains "refuses a downgrade" "$out" "refusing to move entracte backwards"
  expect_contains "leaves the cask alone on a refused downgrade" \
    "$(cat "$sandbox/Casks/entracte.rb")" 'version "0.0.13"'
fi
teardown

# --- no stable release yet is not an error --------------------------------
setup
universal_cask "0.0.0"
unset STUB_TAG
if out=$(run_bump cairn 2>&1); then
  expect_contains "treats a beta-only repo as a no-op" "$out" "no stable release yet"
else
  no "treats a beta-only repo as a no-op" "exited non-zero: ${out}"
fi
teardown

# --- a release with no SHA256SUMS.txt falls back to hashing the asset -----
setup
universal_cask "0.0.0"
export STUB_TAG="v0.1.0" STUB_SUMS=0 STUB_ASSET_BODY="$UNIVERSAL_BODY"
expected=$(printf '%s' "$UNIVERSAL_BODY" | sha256_of_stdin)
if out=$(run_bump cairn 2>&1); then
  cask=$(cat "$sandbox/Casks/cairn.rb")
  expect_contains "hashes the asset when no checksum file is published" \
    "$cask" "sha256 \"${expected}\""
  expect_contains "bumps a single-build cask" "$cask" 'version "0.1.0"'
else
  no "hashes the asset when no checksum file is published" "$out"
fi
teardown

# --- an unconfigured cask is refused rather than silently skipped ---------
setup
dual_arch_cask "0.0.13"
printf 'cask "mystery" do\n  version "1"\n  sha256 "x"\nend\n' >"$sandbox/Casks/mystery.rb"
if out=$(run_bump mystery 2>&1); then
  no "refuses an unconfigured cask" "exited 0: ${out}"
else
  expect_contains "refuses an unconfigured cask" "$out" "no upstream configuration"
fi
teardown

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
