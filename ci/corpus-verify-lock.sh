#!/bin/sh
# ci/corpus-verify-lock.sh - assert the default recipe repo's branch lock.
#
# Bot-only is enforced, not suggested: the repo's default branch must
# carry active rules restricting updates, restricting deletions, and
# blocking force pushes, with exactly the deploy key as bypass actor.
# Every scheduled run verifies this through `$gh api` before touching
# the repo; a loosened lock is reported, never proceeded past.
#
#   corpus-verify-lock.sh --repo OWNER/REPO [--gh CMD] [--decisions DIR]
#
# Exit 0: locked. Exit 2: loosened; problems go to stderr, and with
# --decisions an issues/lock.md decision is written for corpus-apply.sh
# (the workflow then skips sync and applies only the issue). Any other
# nonzero exit means the check itself could not run.
set -eu

say() { printf 'corpus-verify-lock: %s\n' "$1"; }
die() { printf 'corpus-verify-lock: error: %s\n' "$1" >&2; exit 1; }

repo='' gh=gh decisions=''
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case $1 in
        --repo)      repo=$2 ;;
        --gh)        gh=$2 ;;
        --decisions) decisions=$2 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift 2
done
[ -n "$repo" ] || die 'usage: --repo OWNER/REPO [--gh CMD] [--decisions DIR]'
command -v python3 >/dev/null 2>&1 || die 'missing tool: python3'

work=$(mktemp -d) || die 'mktemp -d failed'
trap 'rm -rf "$work"' EXIT INT TERM
problems="$work/problems"
: >"$problems"

branch=$("$gh" api "repos/$repo" | python3 -c \
    'import json, sys; print(json.load(sys.stdin)["default_branch"])') \
    || die "could not read $repo default branch"

# the effective active rules on the branch, then the bypass actors of
# every ruleset contributing one of the three required rules
"$gh" api "repos/$repo/rules/branches/$branch" >"$work/rules.json" \
    || die "could not read branch rules for $repo@$branch"

python3 -c '
import json, sys
rules = json.load(sys.stdin)
have = set(r.get("type") for r in rules)
for t in ("update", "deletion", "non_fast_forward"):
    if t not in have:
        print("missing rule: %s" % t)
' <"$work/rules.json" >>"$problems"

ids=$(python3 -c '
import json, sys
rules = json.load(sys.stdin)
ids = set()
for r in rules:
    if r.get("type") in ("update", "deletion", "non_fast_forward"):
        ids.add(r.get("ruleset_id"))
print(" ".join(str(i) for i in sorted(ids)))
' <"$work/rules.json")

for rid in $ids; do
    "$gh" api "repos/$repo/rulesets/$rid" >"$work/ruleset.json" \
        || die "could not read ruleset $rid of $repo"
    python3 -c '
import json, sys
rs = json.load(sys.stdin)
rid = sys.argv[1]
if rs.get("enforcement") != "active":
    print("ruleset %s: enforcement is %r, want active" % (rid, rs.get("enforcement")))
actors = [a.get("actor_type") for a in rs.get("bypass_actors") or []]
if actors != ["DeployKey"]:
    print("ruleset %s: bypass actors %r, want exactly [DeployKey]" % (rid, actors))
' "$rid" <"$work/ruleset.json" >>"$problems"
done

if [ ! -s "$problems" ]; then
    say "$repo@$branch: locked (update, deletion, non_fast_forward; bypass = DeployKey)"
    exit 0
fi

sed "s/^/corpus-verify-lock: $branch: /" "$problems" >&2
if [ -n "$decisions" ]; then
    mkdir -p "$decisions/issues"
    {
        printf 'The default recipe repo branch lock is loosened.\n\n'
        printf 'repo: %s\nbranch: %s\n\nproblems:\n\n' "$repo" "$branch"
        sed 's/^/- /' "$problems"
        printf '\nThe scheduled bot must be the only writer. Restore the branch\n'
        printf 'ruleset: Restrict updates, Restrict deletions, Block force\n'
        printf 'pushes, bypass = the deploy key only, enforcement Active.\n\n'
        printf 'run: RUN_URL\n\n'
        printf 'reason-hash: %s\n' "$(sha256sum "$problems" | cut -d ' ' -f 1)"
    } >"$decisions/issues/lock.md"
    say "wrote $decisions/issues/lock.md"
fi
exit 2
