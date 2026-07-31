#!/bin/sh
# ci/repo-sync.sh - decide what the scheduled sync of the default recipe repo does.
#
# The pure half of the seam: reads a snapshot, a checkout of the
# default recipe repo, the package set, and the translator, stages the
# checkout on a clean run and writes its verdict under --decisions.
# Never commits, never pushes, never talks to GitHub, ci/repo-apply.sh
# acts on the verdict. Offline, deterministic, runs anywhere.
#
#   repo-sync.sh --snapshot DIR --repo DIR --set FILE \
#                  --decisions DIR --translator DIR
#
# Verdict files (exactly one of commit.msg / nochange, plus issues/):
#   commit.msg              run with changes, staged in the repo checkout
#                           index; subject provenance from the snapshot
#                           MANIFEST, counts body from the report, and a
#                           literal RUN_URL the workflow substitutes with
#                           the Actions run URL before apply
#   nochange                no commit: unchanged or infra (the build
#                           gate may later rewrite it to build-failed
#                           and drop commit.msg)
#   issues/refused-NAME.md  one issue body per refusal
#   issues/infra.md         translate died without writing a report
#
# Holdback: a refused package keeps its last translated recipe (it was
# seeded and never regenerated) or stays absent when it has none, an
# issue gets filed either way, and the rest of the day still commits.
# One template can't hold the whole set's freshness hostage, and the
# recipe a user gets is always one the translator once vouched for.
# Never --allow-empty, `git diff --cached --quiet` is the commit
# decision. Exit 0 whenever a verdict was written, nonzero only when
# this script itself can't do its job.
set -eu

say() { printf 'repo-sync: %s\n' "$1"; }
die() { printf 'repo-sync: error: %s\n' "$1" >&2; exit 1; }

snap='' repo='' set_file='' decisions='' translator=''
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case $1 in
        --snapshot)   snap=$2 ;;
        --repo)     repo=$2 ;;
        --set)        set_file=$2 ;;
        --decisions) decisions=$2 ;;
        --translator) translator=$2 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift 2
done
if [ -z "$snap" ] || [ -z "$repo" ] || [ -z "$set_file" ] \
    || [ -z "$decisions" ] || [ -z "$translator" ]; then
    die 'usage: --snapshot DIR --repo DIR --set FILE --decisions DIR --translator DIR'
fi
[ -f "$set_file" ] || die "no such set file: $set_file"
[ -f "$translator/chytrans" ] || die "no translator at $translator/chytrans"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || die "not a git checkout: $repo"
command -v python3 >/dev/null 2>&1 || die 'missing tool: python3'

work=$(mktemp -d) || die 'mktemp -d failed'
trap 'rm -rf "$work"' EXIT INT TERM
out="$work/out"

# fresh verdict: a stale commit.msg must never survive into apply
rm -rf "$decisions/issues"
rm -f "$decisions/commit.msg" "$decisions/nochange"
mkdir -p "$decisions"

# the set: one name per significant line, whitespace separates names.
# Globbing is off around the unquoted split so a stray * in the set
# file can't expand against the working directory.
set --
set -f
while IFS= read -r line; do
    case $line in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2086 # splitting the line into names is the point
    set -- "$@" $line
done <"$set_file"
set +f
[ $# -gt 0 ] || die "no package names in $set_file"

# seed the out-root with each existing repo recipe whose package is
# still in the set, plus every handwritten exception (modes included).
# The translator regenerates translated recipes wholesale and keeps the
# handwritten and soak-deferred ones it's seeded, so a deferred
# package's recipe survives instead of vanishing. A package dropped
# from the set is NOT seeded, so this sync prunes it instead of copying
# it back.
set_names=' '
for sn in "$@"; do set_names="$set_names$sn "; done
mkdir -p "$out/recipes"
for meta in "$repo"/recipes/*/meta; do
    [ -f "$meta" ] || continue
    dir=${meta%/meta}
    name=${dir##*/}
    case $set_names in
        *" $name "*) ;;
        *) grep -q '^origin: handwritten[[:space:]]*$' "$meta" \
               || continue ;;
    esac
    cp -Rp "$dir" "$out/recipes/$name"
done

rc=0
python3 "$translator/chytrans" translate \
    --snapshot "$snap" --out "$out" "$@" >"$work/translate.log" 2>&1 || rc=$?
report="$out/report"

# provenance from the snapshot MANIFEST: the void master is the commit
# common/shlibs was fetched at, the slice digest is the repodata line
# (the one whose commit field is "-"), both ride in messages, never files
manifest="$snap/MANIFEST"
master12='' slice12=''
if [ -f "$manifest" ]; then
    master12=$(awk '$1 ~ /\/common\/shlibs$/ { print substr($2, 1, 12); exit }' \
        "$manifest")
    slice12=$(awk '$2 == "-" { print substr($3, 1, 12); exit }' "$manifest")
fi

tpl_commit() { # NAME - the commit srcpkgs/NAME/template was pinned at
    [ -f "$manifest" ] || { printf 'unknown\n'; return 0; }
    awk -v want="/srcpkgs/$1/template" \
        'substr($1, length($1) - length(want) + 1) == want { print $2; exit }' \
        "$manifest" | grep . || printf 'unknown\n'
}

hash_of() { # STRING - the reason-hash dedup marker value
    printf '%s\n' "$1" | sha256sum | cut -d ' ' -f 1
}

# --- classification: rc 0 clean, rc!=0 with refused: lines in the
#     report is per-package holdback, anything else (no report at all)
#     is infra. A refused package was seeded and never regenerated, so
#     its last translated recipe rides the out-root unchanged (a
#     refused name with no prior recipe stays absent), each refusal
#     files an issue and the rest of the day proceeds ---

refused_n=0
if [ -f "$report" ] && grep -q '^refused: ' "$report"; then
    mkdir -p "$decisions/issues"
    while IFS= read -r rline; do
        rest=${rline#refused: }
        name=${rest%%:*}
        if [ -d "$out/recipes/$name" ]; then
            state='held at its last translated recipe'
        else
            state='absent (no prior recipe to hold)'
        fi
        {
            printf '%s\n\n' "$rline"
            printf 'package: %s\n' "$name"
            printf 'state: %s\n' "$state"
            printf 'template commit: %s\n' "$(tpl_commit "$name")"
            printf 'void master: %s\n' "${master12:-unknown}"
            printf 'repodata slice: %s\n' "${slice12:-unknown}"
            printf 'run: RUN_URL\n\n'
            printf 'Fix the translator, never the recipe: translated output is\n'
            printf 'regenerated wholesale and hand-edits rot.\n\n'
            printf 'reason-hash: %s\n' "$(hash_of "$rline")"
        } >"$decisions/issues/refused-$name.md"
        refused_n=$((refused_n + 1))
    done <<EOF
$(grep '^refused: ' "$report")
EOF
    say "refused $refused_n package(s): held, the day proceeds"
fi

if [ "$rc" -ne 0 ] && [ "$refused_n" -eq 0 ]; then
    mkdir -p "$decisions/issues"
    last=$(tail -n 1 "$work/translate.log" 2>/dev/null || true)
    {
        printf 'chytrans translate exited %s without a usable report.\n\n' "$rc"
        printf 'last output:\n\n'
        printf '```\n'
        tail -n 20 "$work/translate.log" 2>/dev/null || true
        printf '```\n\n'
        printf 'void master: %s\n' "${master12:-unknown}"
        printf 'run: RUN_URL\n\n'
        printf 'reason-hash: %s\n' "$(hash_of "$last")"
    } >"$decisions/issues/infra.md"
    printf 'infra\n' >"$decisions/nochange"
    say "infrastructure failure (translate exit $rc), no commit"
    exit 0
fi

# --- clean: sync the out-root into the checkout (recipes wholesale plus
#     the four repo-level files; README.md is not ours), stage it, and
#     let the staged diff decide ---

rm -rf "$repo/recipes"
cp -Rp "$out/recipes" "$repo/recipes"
for f in shlibs.map provided.suggested report TRANSLATOR_VERSION; do
    [ -f "$out/$f" ] || die "translate wrote no $f"
    cp -p "$out/$f" "$repo/$f"
done
git -C "$repo" add -A

dr=0
git -C "$repo" diff --cached --quiet || dr=$?
case $dr in
    0)
        printf 'unchanged\n' >"$decisions/nochange"
        say 'unchanged'
        ;;
    1)
        if [ -z "$master12" ] || [ -z "$slice12" ]; then
            die "MANIFEST at $manifest lacks the common/shlibs or repodata line"
        fi
        t=$(grep -c '^translated: ' "$report") || :
        e=$(grep -c '^exception: ' "$report") || :
        r=$(grep -c '^refused: ' "$report") || :
        {
            printf 'sync to void @ %s, repodata slice %s\n\n' \
                "$master12" "$slice12"
            printf 'translated %s, exceptions %s, refused %s\n\n' "$t" "$e" "$r"
            printf 'run: RUN_URL\n'
        } >"$decisions/commit.msg"
        say "commit prepared (translated $t, exceptions $e, refused $r)"
        ;;
    *) die 'git diff --cached failed' ;;
esac
exit 0
