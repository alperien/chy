#!/bin/sh
# ci/corpus-sync.sh - decide what the scheduled sync of the default recipe repo does.
#
# The pure half of the seam: reads a snapshot, a checkout of the default recipe repo, the
# package set, and the translator; stages the checkout on a clean run and
# writes its verdict under --decisions. Never commits, never pushes, never
# talks to GitHub; ci/corpus-apply.sh acts on the verdict. Offline,
# deterministic, safe to run anywhere.
#
#   corpus-sync.sh --snapshot DIR --corpus DIR --set FILE \
#                  --decisions DIR --translator DIR
#
# Verdict files (exactly one of commit.msg / nochange, plus issues/):
#   commit.msg              clean run with changes, staged in the repo checkout
#                           index; subject provenance from the snapshot
#                           MANIFEST, counts body from the report, and a
#                           literal RUN_URL the workflow substitutes with
#                           the Actions run URL before apply
#   nochange                no commit: contains unchanged, refused, or infra
# issues/refused-NAME.md one issue body per refusal
#   issues/infra.md         translate died without writing a report
#
# All-or-nothing: any refusal means no commit (a partial commit would mix
# snapshots across the repo). Never --allow-empty; `git diff --cached
# --quiet` is the commit decision. Exit 0 whenever a verdict was written;
# nonzero only when this script itself cannot do its job.
set -eu

say() { printf 'corpus-sync: %s\n' "$1"; }
die() { printf 'corpus-sync: error: %s\n' "$1" >&2; exit 1; }

snap='' corpus='' set_file='' decisions='' translator=''
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case $1 in
        --snapshot)   snap=$2 ;;
        --corpus)     corpus=$2 ;;
        --set)        set_file=$2 ;;
        --decisions) decisions=$2 ;;
        --translator) translator=$2 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift 2
done
if [ -z "$snap" ] || [ -z "$corpus" ] || [ -z "$set_file" ] \
    || [ -z "$decisions" ] || [ -z "$translator" ]; then
    die 'usage: --snapshot DIR --corpus DIR --set FILE --decisions DIR --translator DIR'
fi
[ -f "$set_file" ] || die "no such set file: $set_file"
[ -f "$translator/chytrans" ] || die "no translator at $translator/chytrans"
git -C "$corpus" rev-parse --git-dir >/dev/null 2>&1 \
    || die "not a git checkout: $corpus"
command -v python3 >/dev/null 2>&1 || die 'missing tool: python3'

work=$(mktemp -d) || die 'mktemp -d failed'
trap 'rm -rf "$work"' EXIT INT TERM
out="$work/out"

# fresh verdict: a stale commit.msg must never survive into apply
rm -rf "$decisions/issues"
rm -f "$decisions/commit.msg" "$decisions/nochange"
mkdir -p "$decisions"

# the set: one name per significant line; whitespace separates names
set --
while IFS= read -r line; do
    case $line in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2086 # splitting the line into names is the point
    set -- "$@" $line
done <"$set_file"
[ $# -gt 0 ] || die "no package names in $set_file"

# seed the out-root with each existing repo recipe whose package is still
# in the set, plus every handwritten exception (modes included). The
# translator regenerates translated recipes wholesale and preserves the
# handwritten and soak-deferred ones it is seeded, so a deferred package's
# recipe survives instead of vanishing. A package dropped from the set is NOT
# seeded, so it is pruned from the repo on this sync rather than copied back.
set_names=' '
for sn in "$@"; do set_names="$set_names$sn "; done
mkdir -p "$out/recipes"
for meta in "$corpus"/recipes/*/meta; do
    [ -f "$meta" ] || continue
    dir=${meta%/meta}
    name=${dir##*/}
    case $set_names in
        *" $name "*) ;;
        *) grep -q '^origin:[[:space:]]*handwritten[[:space:]]*$' "$meta" \
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
# (the one whose commit field is "-"); both ride in messages, never files
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

# --- classification: rc 0 clean; rc!=0 with refused: lines in the
#     report is a refusal; anything else (no report at all) is infra ---

if [ "$rc" -ne 0 ] && [ -f "$report" ] && grep -q '^refused: ' "$report"; then
    mkdir -p "$decisions/issues"
    n=0
    while IFS= read -r rline; do
        rest=${rline#refused: }
        name=${rest%%:*}
        {
            printf '%s\n\n' "$rline"
            printf 'package: %s\n' "$name"
            printf 'template commit: %s\n' "$(tpl_commit "$name")"
            printf 'void master: %s\n' "${master12:-unknown}"
            printf 'repodata slice: %s\n' "${slice12:-unknown}"
            printf 'run: RUN_URL\n\n'
            printf 'Fix the translator, never the recipe: translated output is\n'
            printf 'regenerated wholesale and hand-edits rot.\n\n'
            printf 'reason-hash: %s\n' "$(hash_of "$rline")"
        } >"$decisions/issues/refused-$name.md"
        n=$((n + 1))
    done <<EOF
$(grep '^refused: ' "$report")
EOF
    printf 'refused\n' >"$decisions/nochange"
    say "refused $n package(s), no commit (all-or-nothing)"
    exit 0
fi

if [ "$rc" -ne 0 ]; then
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

rm -rf "$corpus/recipes"
cp -Rp "$out/recipes" "$corpus/recipes"
for f in shlibs.map provided.suggested report TRANSLATOR_VERSION; do
    [ -f "$out/$f" ] || die "translate wrote no $f"
    cp -p "$out/$f" "$corpus/$f"
done
git -C "$corpus" add -A

dr=0
git -C "$corpus" diff --cached --quiet || dr=$?
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
