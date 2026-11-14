#!/usr/bin/env bash
# Rebuilds `staging` on the fork: upstream's main with every branch named in
# .github/staging-branches merged in, then the commit that only staging has
# (its builds, this script, the list) on top; pushed to origin, which builds
# it (Release workflow → the "staging" pre-release).
#
#   scripts/staging.sh            # rebuild and push
#   scripts/staging.sh --no-push  # rebuild only, to look at it first
#
# To add or drop a branch: edit .github/staging-branches on staging, amend
# the top commit ("Staging: …"), then run this. A branch merged upstream is
# dropped from the list (a squash-merge is not recognised as merged).
# Conflicts stop it; resolutions are remembered (git rerere), so after
# resolving and committing the merge, running it again goes through. The
# script is not in the tree then: run it from the staging commit,
#   git show "$(git log -g --format=%H --grep='^Staging:' -n1 staging)":scripts/staging.sh | bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Run from a copy: this file goes away while staging is rebuilt (it lives
# in the staging-only commit), and bash reads scripts as it runs them.
if [ -z "${STAGING_SH_COPY:-}" ]; then
    copy=$(mktemp)
    cp "$0" "$copy"
    STAGING_SH_COPY="$copy" exec bash "$copy" "$@"
fi
trap 'rm -f "$STAGING_SH_COPY"' EXIT

push=1
[ "${1:-}" = "--no-push" ] && push=0

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "uncommitted changes: commit or stash them first" >&2
    exit 1
fi

git fetch -q upstream
git fetch -q origin

# The staging-only commit: the newest "Staging:" commit staging has had
# (its reflog: after a conflict staging is a merge without it), else the
# fork's.
own=$(git log -g --format=%H --grep='^Staging:' -n1 staging 2>/dev/null || true)
[ -n "$own" ] || own=$(git log --format=%H --grep='^Staging:' -n1 origin/staging)
[ -n "$own" ] || { echo "no 'Staging:' commit" >&2; exit 1; }
branches=$(git show "$own:.github/staging-branches" | sed 's/#.*//' | xargs)

git checkout -q -B staging upstream/main
for b in $branches; do
    echo "merging $b"
    if ! git -c rerere.enabled=true -c rerere.autoUpdate=true \
        merge -q --no-ff --no-edit "origin/$b"; then
        if git diff --name-only --diff-filter=U | grep -q .; then
            echo "conflict merging $b: resolve it, 'git commit', then run this again" >&2
            exit 1
        fi
        # rerere resolved it.
        git commit -q --no-edit
    fi
done
git -c rerere.enabled=true cherry-pick "$own" >/dev/null
git log --oneline -1
if [ "$push" = 1 ]; then
    git push -q -f origin staging
    echo "pushed: https://github.com/$(git remote get-url origin | sed -E 's#.*github.com[:/]##; s#\.git$##')/actions"
fi
