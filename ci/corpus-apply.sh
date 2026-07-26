#!/bin/sh
# ci/corpus-apply.sh - act on a corpus-sync verdict (step 5).
#
# The only side-effectful half of the seam: pushes the corpus commit
# that ci/corpus-sync.sh staged, and runs the issue lifecycle through
# $gh. It executes decisions, it never makes them.
#
#   corpus-apply.sh --decisions DIR --corpus DIR --issue-repo OWNER/REPO \
#                   [--gh CMD]
#
# commit.msg present: commit the staged index as github-actions[bot],
# push HEAD:main, then close any open `corpus-sync: refused: <name>`
# whose package the new report shows translated (auto-close; it rides
# a push because a fixed package re-emits its recipe, which moves the
# corpus; the byte-identical corner waits for the next real commit).
# issues/*.md present: open-or-update by exact title, the dedup key. An
# unchanged reason-hash marker stays silent; a changed one posts one
# comment and refreshes the body so the marker tracks the live reason.
# Neither: nothing to do, zero gh calls.
#
# --gh names a single command (a stub in the dry-run tests, default gh).
set -eu

say() { printf 'corpus-apply: %s\n' "$1"; }
die() { printf 'corpus-apply: error: %s\n' "$1" >&2; exit 1; }

decisions='' corpus='' issue_repo='' gh=gh
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case $1 in
        --decisions) decisions=$2 ;;
        --corpus)     corpus=$2 ;;
        --issue-repo) issue_repo=$2 ;;
        --gh)         gh=$2 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift 2
done
if [ -z "$decisions" ] || [ -z "$corpus" ] || [ -z "$issue_repo" ]; then
    die 'usage: --decisions DIR --corpus DIR --issue-repo OWNER/REPO [--gh CMD]'
fi
[ -d "$decisions" ] || die "no decisions directory: $decisions"
git -C "$corpus" rev-parse --git-dir >/dev/null 2>&1 \
    || die "not a git checkout: $corpus"

bot_name='github-actions[bot]'
bot_mail='41898282+github-actions[bot]@users.noreply.github.com'

# --- the push ---

pushed=0
if [ -f "$decisions/commit.msg" ]; then
    git -C "$corpus" -c user.name="$bot_name" -c user.email="$bot_mail" \
        commit --quiet -F "$decisions/commit.msg"
    git -C "$corpus" push origin HEAD:main
    pushed=1
    say "pushed: $(git -C "$corpus" log -1 --format=%s)"
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

# one listing serves dedup and auto-close: number, reason-hash (or -), title
"$gh" issue list --repo "$issue_repo" --state open --limit 200 \
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
            title="corpus-sync: refused: $name" ;;
        infra.md) title='corpus-sync: infrastructure failure' ;;
        lock.md) title='corpus-sync: corpus lock loosened' ;;
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

# auto-close after a push: an open refusal whose package the freshly
# committed report shows translated is fixed
if [ "$pushed" -eq 1 ]; then
    [ -f "$corpus/report" ] || die "no report in $corpus after a push"
    while IFS=$tab read -r num _ title; do
        case $title in 'corpus-sync: refused: '*) ;; *) continue ;; esac
        name=${title#corpus-sync: refused: }
        grep -Fqx "translated: $name" "$corpus/report" || continue
        "$gh" issue close "$num" --repo "$issue_repo" \
            --comment "corpus-sync: $name translated cleanly again; closing."
        say "closed: $title"
    done <"$work/issues.tsv"
fi
exit 0
