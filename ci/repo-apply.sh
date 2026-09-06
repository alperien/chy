#!/bin/sh
# ci/repo-apply.sh - act on the final verdict, after the build gate.
#
# Pushes the repo commit ci/repo-sync.sh staged and the gate let stand,
# and runs the issue lifecycle through $gh. Decisions were already
# made, this only executes them.
#
#   repo-apply.sh --decisions DIR --repo DIR --issue-repo OWNER/REPO \
#                   [--gh CMD]
#
# commit.msg present: commit the staged index as github-actions[bot],
# push HEAD:main, then close any open `repo-sync: refused: <name>` or
# `repo-sync: build failed: <name>` whose package the pushed commit
# actually carries: the name is in the commit's recipes/ diff and
# today's decisions hold no issue file for it (auto-close rides a push
# because a fixed package re-emits its recipe, which moves the repo).
# A sweep closes open build failures for names gone from default.set
# (refused: issues stay: a vanished name genuinely lost its recipe).
# issues/*.md present: open-or-update by exact title, the dedup key. An
# unchanged reason-hash marker stays silent, a changed one posts one
# comment and refreshes the body so the marker tracks the live reason.
# Neither: nothing to do, zero gh calls.
#
# --gh names a single command (a stub in the dry-run tests, default gh).
set -eu

say() { printf 'repo-apply: %s\n' "$1"; }
die() { printf 'repo-apply: error: %s\n' "$1" >&2; exit 1; }

decisions='' repo='' issue_repo='' gh=gh
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case $1 in
        --decisions) decisions=$2 ;;
        --repo)     repo=$2 ;;
        --issue-repo) issue_repo=$2 ;;
        --gh)         gh=$2 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift 2
done
if [ -z "$decisions" ] || [ -z "$repo" ] || [ -z "$issue_repo" ]; then
    die 'usage: --decisions DIR --repo DIR --issue-repo OWNER/REPO [--gh CMD]'
fi
[ -d "$decisions" ] || die "no decisions directory: $decisions"
# git -C "$repo" resolves relative file arguments (commit -F) inside
# the checkout, so pin both directories to absolute paths up front
decisions=$(cd "$decisions" && pwd) || die "cannot resolve $decisions"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || die "not a git checkout: $repo"
repo=$(cd "$repo" && pwd) || die "cannot resolve $repo"

bot_name='github-actions[bot]'
bot_mail='41898282+github-actions[bot]@users.noreply.github.com'

# --- the push ---

pushed=0
if [ -f "$decisions/commit.msg" ]; then
    git -C "$repo" -c user.name="$bot_name" -c user.email="$bot_mail" \
        commit --quiet -F "$decisions/commit.msg"
    git -C "$repo" push origin HEAD:main
    pushed=1
    say "pushed: $(git -C "$repo" log -1 --format=%s)"
fi

# --- the issue lifecycle ---

have_issues=0
for f in "$decisions/issues"/*.md; do
    [ -f "$f" ] && { have_issues=1; break; }
done

if [ "$pushed" -eq 0 ] && [ "$have_issues" -eq 0 ]; then
    say 'nothing to apply'
    exit 0
fi
command -v python3 >/dev/null 2>&1 || die 'missing tool: python3'

work=$(mktemp -d) || die 'mktemp -d failed'
trap 'rm -rf "$work"' EXIT INT TERM
tab=$(printf '\t')

# one listing serves dedup, auto-close, and the sweep: number,
# reason-hash (or -), title. The cap has to clear every open issue or
# the sweep can't see (and close) what it lists; gh rejects limits
# below 1, so this is a large finite number, not unlimited.
"$gh" issue list --repo "$issue_repo" --state open --limit 10000 \
    --json number,title,body >"$work/issues.json"
python3 -c '
import json, re, sys
for it in json.load(sys.stdin):
    m = re.search(r"^reason-hash: ([0-9a-f]{64})[ \t]*$",
                  it.get("body") or "", re.M)
    print("%s\t%s\t%s" % (it["number"], m.group(1) if m else "-", it["title"]))
' <"$work/issues.json" >"$work/issues.tsv"

issue_row() { # TITLE - print "number hash" of the open issue, or fail
    while IFS=$tab read -r ir_num ir_hash ir_title; do
        [ "$ir_title" = "$1" ] || continue
        printf '%s %s\n' "$ir_num" "$ir_hash"
        return 0
    done <"$work/issues.tsv"
    return 1
}

for f in "$decisions/issues"/*.md; do
    [ -f "$f" ] || continue
    base=${f##*/}
    case $base in
        refused-*.md)
            name=${base#refused-}; name=${name%.md}
            title="repo-sync: refused: $name" ;;
        build-*.md)
            name=${base#build-}; name=${name%.md}
            title="repo-sync: build failed: $name" ;;
        doctor.md) title='repo-sync: doctor found problems' ;;
        infra.md) title='repo-sync: infrastructure failure' ;;
        lock.md) title='repo-sync: repo lock loosened' ;;
        *) die "unrecognized decision issue: $base" ;;
    esac
    want=$(sed -n 's/^reason-hash: //p' "$f" | head -n 1)
    [ -n "$want" ] || want=missing
    row=$(issue_row "$title") || row=
    if [ -z "$row" ]; then
        "$gh" issue create --repo "$issue_repo" --title "$title" --body-file "$f"
        say "opened: $title"
    elif [ "${row#* }" = "$want" ]; then
        say "already open, reason unchanged: $title"
    else
        num=${row%% *}
        "$gh" issue comment "$num" --repo "$issue_repo" --body-file "$f"
        "$gh" issue edit "$num" --repo "$issue_repo" --body-file "$f"
        say "reason changed, commented: $title"
    fi
done

# --- closing what this run resolves ---
#
# A name ships when the pushed commit's recipes/ diff carries it (added
# or changed, still present in the tree; --diff-filter=ACM drops
# prunes). An open refusal or build failure for a shipped name is
# stale: the fix rode the push. A name with an issue file in TODAY's
# decisions is live state, not a fix, even if the diff carries it, so
# it stays open. Every close is best-effort: the push already
# happened, a failed close only warns.
if [ "$pushed" -eq 1 ]; then
    git -C "$repo" diff-tree -r --no-commit-id --no-renames \
        --name-only --diff-filter=ACM HEAD -- recipes/ \
        >"$work/shipped.raw" 2>/dev/null || : >"$work/shipped.raw"
    sed -n 's|^recipes/\([^/][^/]*\)/.*|\1|p' "$work/shipped.raw" \
        | LC_ALL=C sort -u >"$work/shipped"
    while IFS=$tab read -r num _ title; do
        case $title in
            'repo-sync: refused: '*) name=${title#repo-sync: refused: } ;;
            'repo-sync: build failed: '*)
                name=${title#repo-sync: build failed: } ;;
            *) continue ;;
        esac
        [ ! -f "$decisions/issues/build-$name.md" ] || continue
        [ ! -f "$decisions/issues/refused-$name.md" ] || continue
        grep -Fqx "$name" "$work/shipped" || continue
        if "$gh" issue close "$num" --repo "$issue_repo" \
            --comment "repo-sync: $name shipped in this push; closing."; then
            say "closed: $title"
        else
            say "warn: close failed: $title"
        fi
    done <"$work/issues.tsv"
fi

# The stale sweep: a build failure for a name no longer in the set can
# never resolve (the sync stopped translating it) and only drowns the
# tracker. default.set rides the chy checkout next to ci/; no file, no
# sweep. Names the ship loop above already handled, or that today's
# decisions still hold, are left alone.
set_file=$(dirname "$0")/../default.set
if [ -f "$set_file" ]; then
    set_names=' '
    set -f
    while IFS= read -r line; do
        case $line in ''|'#'*) continue ;; esac
        # shellcheck disable=SC2086 # splitting the line into names is the point
        for sn in $line; do set_names="$set_names$sn "; done
    done <"$set_file"
    set +f
    while IFS=$tab read -r num _ title; do
        case $title in
            'repo-sync: build failed: '*)
                name=${title#repo-sync: build failed: } ;;
            *) continue ;;
        esac
        [ ! -f "$decisions/issues/build-$name.md" ] || continue
        case $set_names in *" $name "*) continue ;; esac
        if [ "$pushed" -eq 1 ] && grep -Fqx "$name" "$work/shipped"; then
            continue # the ship loop above already closed it
        fi
        if "$gh" issue close "$num" --repo "$issue_repo" \
            --comment "repo-sync: $name is no longer in default.set; closing."; then
            say "swept: $title"
        else
            say "warn: sweep close failed: $title"
        fi
    done <"$work/issues.tsv"
fi
exit 0
