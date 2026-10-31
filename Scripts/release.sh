#!/bin/bash
# Tags a new release. Usage: Scripts/release.sh patch|minor|major|X.Y.Z
#
# Requires a clean working tree and passing tests. Creates an annotated tag vX.Y.Z on HEAD.
# Nothing is pushed; the script prints the push command.
set -euo pipefail
cd "$(dirname "$0")/.."

bump="${1:-}"
if [ -z "$bump" ]; then
    echo "Usage: Scripts/release.sh patch|minor|major|X.Y.Z" >&2
    exit 64
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree is not clean. Commit or stash your changes first." >&2
    exit 1
fi

latest="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)"
current="${latest#v}"
[ -z "$current" ] && current="0.0.0"
IFS=. read -r major minor patch <<< "$current"

case "$bump" in
    patch) next="$major.$minor.$((patch + 1))" ;;
    minor) next="$major.$((minor + 1)).0" ;;
    major) next="$((major + 1)).0.0" ;;
    [0-9]*.[0-9]*.[0-9]*) next="$bump" ;;
    *) echo "Unknown bump '$bump'. Use patch, minor, major or X.Y.Z." >&2; exit 64 ;;
esac

if git rev-parse -q --verify "refs/tags/v$next" >/dev/null; then
    echo "Tag v$next already exists." >&2
    exit 1
fi
if [ -n "$latest" ] && [ "$(printf '%s\n%s\n' "$current" "$next" | sort -V | tail -1)" != "$next" -o "$current" = "$next" ]; then
    echo "v$next is not newer than $latest." >&2
    exit 1
fi
if [ -n "$latest" ] && [ "$(git rev-parse "$latest^{commit}")" = "$(git rev-parse HEAD)" ]; then
    echo "HEAD is already tagged $latest. Commit something before releasing again." >&2
    exit 1
fi

echo "Running tests…"
swift test >/dev/null || { echo "Tests failed; not tagging." >&2; exit 1; }

git tag -a "v$next" -m "Murmur $next"
echo "Tagged v$next (previous: ${latest:-none})."
echo "Build it with:  Scripts/build-app.sh release"
echo "Publish with:   git push origin v$next"
