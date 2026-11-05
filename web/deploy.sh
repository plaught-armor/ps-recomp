#!/bin/sh
# Rebuilds the converter page and commits it to the local gh-pages branch,
# which GitHub Pages serves. The branch holds only the web/build.sh out dir
# plus .nojekyll. Run it from a clean checkout: it refuses a tree with
# changes or untracked files, so commit.txt names a real commit. It never
# pushes; push gh-pages yourself.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [ -n "$(git status --porcelain)" ]; then
	echo "deploy.sh: the tree has changes or untracked files; commit them first" >&2
	exit 1
fi
head=$(git rev-parse HEAD)
tmp=$(mktemp -d)
site="$tmp/site"
cleanup() {
	git -C "$root" worktree remove --force "$site" 2>/dev/null || true
	rm -rf "${tmp:?}"
}
trap cleanup EXIT INT TERM
"$root/web/build.sh" "$tmp/out"
if git show-ref --verify --quiet refs/heads/gh-pages; then
	git worktree add -q "$site" gh-pages
else
	git worktree add -q --orphan -b gh-pages "$site"
fi
git -C "$site" rm -rq --ignore-unmatch -- .
cp "$tmp/out"/* "$site/"
touch "$site/.nojekyll"
git -C "$site" add -A
if git -C "$site" rev-parse -q --verify HEAD >/dev/null && git -C "$site" diff --cached --quiet; then
	echo "deploy.sh: gh-pages already matches $head"
else
	git -C "$site" commit -q -m "Converter page from ps-recomp $head"
fi
echo "deploy.sh: gh-pages is at $(git rev-parse gh-pages); push it to publish"
