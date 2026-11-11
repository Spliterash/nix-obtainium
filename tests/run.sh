#!/usr/bin/env bash
# End-to-end check against real GitHub (needs network). Usage: tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT=$PWD
N=$(nix build --no-link --print-out-paths .#nix)/bin/nix
T=$(mktemp -d)
trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
cd "$T"
fail() { echo "FAIL: $*" >&2; exit 1; }

mkflake() {
  cat >flake.nix <<EOF
{
  inputs.gh = { url = "file+https://nix-obtainium.invalid/$1"; flake = false; };
  inputs.obtainium.url = "path:$ROOT";
  outputs = { self, gh, obtainium }: { path = "\${gh}"; release = obtainium.lib.release self "gh"; };
}
EOF
}
locked() { jq -r '.nodes.gh.locked | "\(.type) \(.url)"' flake.lock; }

echo "1. lock with plugin -> plain file input"
mkflake 'github/cli/cli?asset=gh_*_linux_amd64.deb'
"$N" flake lock
[[ $(locked) =~ ^file\ https://github.com/cli/cli/releases/download/v[0-9.]+/gh_([0-9.]+)_linux_amd64.deb#([0-9.]+)$ ]] \
  && [[ ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]}" ]] || fail "locked: $(locked)"

echo "2. outPath is the asset itself, lib.release reads version and file name"
[[ $(head -c 7 "$("$N" eval --raw .#path)") == '!<arch>' ]] || fail "outPath is not a .deb"
v=$("$N" eval --raw .#release.version)
[[ $("$N" eval --raw .#release.fileName) == "gh_${v}_linux_amd64.deb" ]] || fail "release: $("$N" eval --json .#release)"

echo "3. Nix without plugin fetches the lock into an empty store"
nix eval --store "$T/store" --raw .#path >/dev/null

echo "4. tag filter re-resolves to an older release"
mkflake 'github/cli/cli?asset=gh_*_linux_amd64.deb&tag=v2.100.*'
"$N" flake lock
[[ $(locked) == */v2.100.* ]] || fail "tag filter: $(locked)"

echo "5. without plugin update fails and keeps the lock"
cp flake.lock lock.bak
! nix --option plugin-files '' flake update 2>err || fail "update without plugin succeeded"
grep -q 'nix-obtainium.invalid' err || fail "unexpected error: $(cat err)"
cmp -s flake.lock lock.bak || fail "lock changed"

echo "6. unknown connector -> clear error"
mkflake 'nope/x?asset=y'
! "$N" flake lock 2>err || fail "unknown connector succeeded"
grep -q "connector 'nope' is not installed" err || fail "unexpected error: $(cat err)"

echo OK
