#!/bin/sh
# Keep this fork current with its upstreams and release when anything moved:
#   - william-aqn/asuswrt-merlin-amneziawg  latest release  -> addon tree (+ fork/patches/addon)
#   - amnezia-vpn/amneziawg-go              latest v* tag   -> daemon   (+ fork/patches/go)
#   - amnezia-vpn/amneziawg-tools           latest v* tag   -> awg CLI
# Nothing is released when a patch no longer applies or the daemon no longer builds: the
# job fails and opens an issue instead. Needs: git, go, gh (GH_TOKEN), run from repo root
# on a full clone of main. DRY_RUN=1 computes and applies locally without committing/pushing.
set -eu

ADDON_UP=william-aqn/asuswrt-merlin-amneziawg
GO_UP=https://github.com/amnezia-vpn/amneziawg-go.git
TOOLS_UP=https://github.com/amnezia-vpn/amneziawg-tools.git
FORK_REPO=VolkovIlia/asuswrt-merlin-amneziawg
PINS=fork/pins.env

fail(){
    echo "SYNC FAILED: $1" >&2
    if [ "${DRY_RUN:-0}" != 1 ]; then
        gh issue create -R "$FORK_REPO" --title "sync-upstream: $1" \
            --body "Automatic upstream sync stopped: $1. Nothing was released. Update the patches in fork/patches and re-run the Sync upstream workflow." >/dev/null || true
    fi
    exit 1
}
pin(){ sed -n "s/^$1=//p" "$PINS"; }
setpin(){ sed -i "s|^$1=.*|$1=$2|" "$PINS"; }
latest_tag(){ git ls-remote --tags --refs "$1" | awk -F/ '{print $3}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1; }

cur_addon=$(pin UPSTREAM_ADDON_TAG); cur_go=$(pin AWG_GO_TAG); cur_tools=$(pin AWG_TOOLS_TAG)
new_addon=$(gh api "repos/$ADDON_UP/releases/latest" --jq .tag_name)
new_go=$(latest_tag "$GO_UP"); new_tools=$(latest_tag "$TOOLS_UP")
[ -n "$new_addon" ] && [ -n "$new_go" ] && [ -n "$new_tools" ] || fail "cannot resolve upstream versions"
echo "addon $cur_addon -> $new_addon | go $cur_go -> $new_go | tools $cur_tools -> $new_tools"

notes=""
# sort -V guard: never move a pin backwards (upstream tag deleted / re-pointed).
newer(){ [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }

if newer "$cur_go" "$new_go"; then
    tmp=$(mktemp -d)
    git clone -q --depth 1 --branch "$new_go" "$GO_UP" "$tmp/go"
    git -C "$tmp/go" apply "$PWD"/fork/patches/go/*.patch \
        || fail "router patches do not apply to amneziawg-go $new_go"
    ( cd "$tmp/go" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o /dev/null . ) \
        || fail "amneziawg-go $new_go with router patches does not build"
    rm -rf "$tmp"
    setpin AWG_GO_TAG "$new_go"; setpin AWG_GO_REF "$new_go"
    notes="$notes- Демон обновлён до \`amneziawg-go $new_go\` (роутерные патчи из \`fork/patches/go\` применены).\n"
fi

if newer "$cur_tools" "$new_tools"; then
    setpin AWG_TOOLS_TAG "$new_tools"
    notes="$notes- CLI обновлён до \`amneziawg-tools $new_tools\`.\n"
fi

addon_moved=0
if newer "$cur_addon" "$new_addon"; then
    addon_moved=1
    git fetch -q "https://github.com/$ADDON_UP.git" "refs/tags/$new_addon:refs/tags/upstream-$new_addon" \
        "refs/tags/$cur_addon:refs/tags/upstream-$cur_addon"
    up="upstream-$new_addon"
    # Replace the addon tree with upstream's, keeping this fork's own .github/ and fork/.
    for f in $(git ls-files | grep -vE '^(\.github|fork)/'); do
        git cat-file -e "$up:$f" 2>/dev/null || git rm -q "$f"
    done
    for f in $(git ls-tree -r --name-only "$up" | grep -vE '^(\.github|fork)/'); do
        mkdir -p "$(dirname "$f")"; git show "$up:$f" > "$f"; git add "$f"
    done
    git apply -3 fork/patches/addon/*.patch || fail "fork addon patches do not apply to $ADDON_UP $new_addon"
    if ! git diff --quiet "upstream-$cur_addon" "$up" -- .github/workflows/release.yml 2>/dev/null; then
        notes="$notes- Внимание: у апстрима изменился release.yml ($cur_addon..$new_addon) — рецепт сборки форка не обновляется автоматически.\n"
    fi
    setpin UPSTREAM_ADDON_TAG "$new_addon"
    notes="$notes- Аддон синхронизирован с \`$ADDON_UP $new_addon\`.\n"
fi

[ -n "$notes" ] || { echo "Nothing new upstream."; exit 0; }

# Fork refs (updater, installer, links) always point at this fork — re-applied after every
# upstream import because new upstream code may add fresh literals.
grep -rl "$ADDON_UP" addon install-online.sh build-ipk.sh 2>/dev/null \
    | xargs -r sed -i "s#$ADDON_UP#$FORK_REPO#g"

# Version: upstream X.Y.Z -> X.Y.(Z*100+rev). Always distinct from upstream's own numbers,
# monotonic across upstream releases, valid semver for jsDelivr's resolver.
rev=$(pin FORK_REV)
if [ "$addon_moved" = 1 ]; then rev=1; else rev=$((rev + 1)); fi
setpin FORK_REV "$rev"
base="${new_addon#v}"
version="${base%.*}.$(( ${base##*.} * 100 + rev ))"
sed -i "s/^AWG_VERSION=\"[0-9.]*\"/AWG_VERSION=\"$version\"/" addon/amneziawg.sh
grep -q "^AWG_VERSION=\"$version\"" addon/amneziawg.sh || fail "could not stamp AWG_VERSION $version"

entry=$(printf '### %s -- %s\n\n%b\n' "$version" "$(date -u +%Y-%m-%d)" "$notes")
{ echo "# История изменений"; echo; echo "$entry"; tail -n +2 CHANGELOG.md; } > CHANGELOG.md.new
mv CHANGELOG.md.new CHANGELOG.md

sh -n addon/amneziawg.sh || fail "addon/amneziawg.sh has a syntax error after sync"
echo "Releasing v$version"
[ "${DRY_RUN:-0}" = 1 ] && { git status --short; exit 0; }

git add -A
git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -qm "sync: v$version (addon $new_addon, amneziawg-go $(pin AWG_GO_TAG), tools $(pin AWG_TOOLS_TAG))"
git tag "v$version"
git push -q origin HEAD:main "v$version"
# A tag pushed with GITHUB_TOKEN does not trigger workflows; a dispatch does.
gh workflow run release.yml -R "$FORK_REPO" --ref "v$version"
