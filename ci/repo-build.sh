#!/bin/sh
# ci/repo-build.sh - the build gate over a staged sync: after
# repo-sync.sh decides, before repo-apply.sh pushes.
#
# repo-sync.sh stages the day's diff and prepares commit.msg; this
# gate proves the staged recipes actually build before repo-apply.sh
# is allowed to push. Scope is exactly the recipes the staged diff
# touches: each is installed through chy itself into a throwaway
# root, so its dependency closure builds as needed and host packages
# come from db/provided (seeded from the repo's own
# provided.suggested). A failure writes issues/build-<name>.md, drops
# commit.msg, and records the build-failed verdict: the all-or-nothing
# rule covers builds, so a day the gate rejects commits nothing.
#
#   repo-build.sh --repo DIR --decisions DIR [--chy FILE] [--root DIR]
#
# --root is a prepared build root (the tests seed its cache/); by
# default a temporary one is created and removed. Exit 0 means the
# decision stands or was rewritten to build-failed; any other exit is
# the gate itself breaking, which the workflow treats as infra.
set -eu

say() { printf 'repo-build: %s\n' "$1"; }
die() { printf 'repo-build: error: %s\n' "$1" >&2; exit 1; }

hash_of() { # STRING - the reason-hash dedup marker value
    printf '%s\n' "$1" | sha256sum | cut -d ' ' -f 1
}

repo='' decisions='' chy=chy/chy root=''
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case $1 in
        --repo)      repo=$2 ;;
        --decisions) decisions=$2 ;;
        --chy)       chy=$2 ;;
        --root)      root=$2 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift 2
done
if [ -z "$repo" ] || [ -z "$decisions" ]; then
    die 'usage: --repo DIR --decisions DIR [--chy FILE] [--root DIR]'
fi
[ -f "$chy" ] || die "no chy at $chy"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || die "not a git checkout: $repo"

if [ ! -f "$decisions/commit.msg" ]; then
    say 'no commit staged, nothing to build'
    exit 0
fi

# scratch is always owned and temporary: it holds the staged-name
# list and the per-package build logs even when --root is supplied,
# so logs never land on a shared predictable path
scratch=$(mktemp -d) || die 'mktemp -d failed'
trap 'rm -rf "$scratch"' EXIT INT TERM

# the recipes this sync touches: first path component under recipes/
# in the staged diff. The git read is staged to a file and checked,
# so a failing git cannot masquerade as an empty diff and wave the
# day through unbuilt. A name gone from the worktree is a prune and
# has nothing to build.
git -C "$repo" diff --cached --name-only -- recipes/ >"$scratch/staged" \
    || die 'git diff --cached failed'
names=$(sed -n 's|^recipes/\([^/][^/]*\)/.*|\1|p' "$scratch/staged" \
    | LC_ALL=C sort -u)
if [ -z "$names" ]; then
    say 'no recipe changes staged, nothing to build'
    exit 0
fi

[ -n "$root" ] || root="$scratch/root"
mkdir -p "$root/db"
root=$(cd "$root" && pwd) || die "cannot resolve $root"
repo_abs=$(cd "$repo" && pwd)

# reconcile a reused root to the staged repo before building.  The
# resolver satisfies dependencies by presence alone and never reads a
# version, so anything installed that the staged repo no longer
# vouches for (recipe gone, or version drifted from the staged recipe)
# must go, along with every diff name (explicit targets rebuild).  chy
# refuses to remove a depended-on package, so removal runs in passes;
# a pass that removes nothing with work left means the root cannot be
# reconciled cheaply, and it is discarded instead.  Fresh roots skip
# all of this.
reconcile_root() {
    rr_list="$scratch/reconcile"
    : >"$rr_list"
    for rr_d in "$root/db/installed/"*/; do
        [ -d "$rr_d" ] || continue
        rr_n=${rr_d%/}; rr_n=${rr_n##*/}
        if [ ! -d "$repo/recipes/$rr_n" ]; then
            printf '%s\n' "$rr_n" >>"$rr_list"
            continue
        fi
        rr_iv=$(cat "$rr_d/version" 2>/dev/null) || rr_iv=''
        rr_rv=$(head -n 1 "$repo/recipes/$rr_n/version" 2>/dev/null) || rr_rv=''
        case $rr_iv in *' '*) ;; *) rr_iv="$rr_iv 1" ;; esac
        case $rr_rv in *' '*) ;; *) rr_rv="$rr_rv 1" ;; esac
        [ "$rr_iv" = "$rr_rv" ] || printf '%s\n' "$rr_n" >>"$rr_list"
    done
    printf '%s\n' "$names" >>"$rr_list"
    while :; do
        rr_progress=0 rr_stuck=0
        while IFS= read -r rr_n; do
            [ -n "$rr_n" ] || continue
            [ -d "$root/db/installed/$rr_n" ] || continue
            if CHY_ROOT="$root" sh "$chy" remove "$rr_n" \
                >/dev/null 2>&1 </dev/null; then
                rr_progress=1
            else
                rr_stuck=1
            fi
        done <"$rr_list"
        [ "$rr_stuck" -eq 1 ] || break
        if [ "$rr_progress" -eq 0 ]; then
            # keep cache/ (checksum-verified downloads); wipe the state
            say 'reused root cannot be reconciled; starting fresh'
            rm -rf "${root:?}/db" "${root:?}/store" "${root:?}/usr" \
                "${root:?}/build" "${root:?}/recipes" "${root:?}/shlibs.map"
            mkdir -p "$root/db"
            break
        fi
    done
}
if [ -d "$root/db/installed" ]; then
    reconcile_root
fi

[ -e "$root/recipes" ] || ln -s "$repo_abs/recipes" "$root/recipes"
# side files refresh every run: a reused root must see today's repo
if [ -f "$repo/shlibs.map" ]; then
    cp "$repo/shlibs.map" "$root/shlibs.map"
fi
if [ -f "$repo/provided.suggested" ]; then
    awk 'NF {print $1}' "$repo/provided.suggested" >"$root/db/provided"
fi

built=0 failed=''
while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ ! -d "$repo/recipes/$name" ]; then
        say "pruned, not built: $name"
        continue
    fi
    log="$scratch/build-$name.log"
    : >"$log" || die "cannot write $log"
    # stdin is closed off: the loop reads names from its own heredoc,
    # and a build script that reads stdin must not eat the queue
    rc=0
    CHY_ROOT="$root" sh "$chy" install "$name" >"$log" 2>&1 </dev/null \
        || rc=$?
    if [ "$rc" -eq 0 ]; then
        built=$((built + 1))
        say "built: $name"
        continue
    fi
    # chy exits 2 when it could not even run (usage, root validation);
    # that is the gate broken, not the package
    [ "$rc" -ne 2 ] || die "chy could not run for $name: $(tail -n 1 "$log")"
    failed="$failed$name "
    say "build FAILED: $name"
    # the tail goes to the step log too: on a dry run the issue file
    # below is never filed, and a rejection nobody can read is noise
    tail -n 15 "$log" | sed 's/^/repo-build:   /'
    last=$(tail -n 1 "$log") || last=''
    mkdir -p "$decisions/issues"
    {
        printf 'The build gate rejected the staged sync: %s failed to build.\n\n' "$name"
        printf 'package: %s\n' "$name"
        printf 'void commit: %s\n' "$(sed -n 's/^void-commit: //p' \
            "$repo/recipes/$name/meta" 2>/dev/null | head -n 1 | grep . \
            || printf 'unknown')"
        printf '\nlast 30 lines:\n\n```\n'
        tail -n 30 "$log"
        printf '```\n\n'
        printf 'Nothing was committed (all-or-nothing). Translated output is\n'
        printf 'regenerated wholesale, so fix the translator or its inputs,\n'
        printf 'never the recipe; this issue closes on the next push that\n'
        printf 'carries %s.\n\n' "$name"
        printf 'run: RUN_URL\n\n'
        printf 'reason-hash: %s\n' "$(hash_of "build $name: $last")"
    } >"$decisions/issues/build-$name.md"
done <<EOF
$names
EOF

if [ -n "$failed" ]; then
    rm -f "$decisions/commit.msg"
    printf 'build-failed\n' >"$decisions/nochange"
    say "rejected: $failed- no commit (all-or-nothing)"
    exit 0
fi
say "$built recipe(s) built clean, decision stands"
exit 0
