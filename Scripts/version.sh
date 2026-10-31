#!/bin/bash
# Derives Murmur's version from git. Prints shell assignments; use with: eval "$(Scripts/version.sh)"
#
#   MURMUR_VERSION       marketing version from the latest tag vX.Y.Z      e.g. 1.0.0
#   MURMUR_BUILD         number of commits on HEAD (monotonic build number) e.g. 42
#   MURMUR_FULL_VERSION  version + distance from tag + commit + dirty flag  e.g. 1.0.0+3.g1a2b3c4.dirty
#   MURMUR_COMMIT        abbreviated commit hash                            e.g. 1a2b3c4
set -euo pipefail
cd "$(dirname "$0")/.."

version="0.0.0"; build="0"; full="0.0.0+unknown"; commit="unknown"

if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    build="$(git rev-list --count HEAD)"
    commit="$(git rev-parse --short HEAD)"
    dirty=""
    [ -n "$(git status --porcelain --untracked-files=no)" ] && dirty=".dirty"

    if describe="$(git describe --tags --long --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null)"; then
        # v1.2.3-<distance>-g<hash>
        tag="${describe%-*-g*}"
        rest="${describe#"$tag"-}"
        distance="${rest%%-*}"
        version="${tag#v}"
        if [ "$distance" = "0" ]; then
            full="${version}${dirty:++dirty}"
        else
            full="${version}+${distance}.g${commit}${dirty}"
        fi
    else
        full="0.0.0+${build}.g${commit}${dirty}"
    fi
fi

printf 'MURMUR_VERSION=%q\nMURMUR_BUILD=%q\nMURMUR_FULL_VERSION=%q\nMURMUR_COMMIT=%q\n' \
    "$version" "$build" "$full" "$commit"
