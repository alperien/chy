#!/bin/sh
# ci/repo-build.sh - the build gate over a staged sync: after
# repo-sync.sh decides, before repo-apply.sh pushes.
#
# repo-sync.sh stages the day's diff and prepares commit.msg, this gate
# checks the staged recipes actually build before repo-apply.sh may
# push. Scope is exactly the recipes the staged diff touches: each one
# installs through chy itself into a throwaway or cached root, so its
# dependency closure builds as needed and host packages come from
# db/provided (seeded from the repo's own provided.suggested).
#
# Holdback: a failed build no longer rejects the day. The failed name's
# recipe is restored from HEAD (a new name with no HEAD version is held
# absent instead), an issues/build-<name>.md gets filed, and the
# surviving combination re-gates on a fresh root: later rounds rebuild
# the current diff PLUS every held name, so what ships is what was
# validated. A held name that fails again pulls its in-diff deps into
# the hold, and three rejected rounds reject the day wholesale (that's
# systemic, not a package). Held names ride the commit message as one
# "gate held:" line.
#
#   repo-build.sh --repo DIR --decisions DIR [--chy FILE] [--root DIR]
#
# --root is a persistent or prepared build root (the workflow caches
# it, the tests seed its cache/), by default a temporary one is made
# and removed. Exit 0 means the decision stands, was amended with
# holds, or was rewritten to build-failed. Any other exit is the gate
# itself breaking, which the workflow treats as infra.
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

# scratch is always owned and temporary: it holds name lists and the
# per-package build logs even when --root is supplied, so logs never
# land on a shared predictable path
scratch=$(mktemp -d) || die 'mktemp -d failed'
trap 'rm -rf "$scratch"' EXIT INT TERM

[ -n "$root" ] || root="$scratch/root"
mkdir -p "$root/db"
root=$(cd "$root" && pwd) || die "cannot resolve $root"
repo_abs=$(cd "$repo" && pwd)

# --- root plumbing ---

# wipe the root's state, keeping cache/ (checksum-verified downloads)
wipe_root() {
    rm -rf "${root:?}/db" "${root:?}/store" "${root:?}/usr" \
        "${root:?}/build" "${root:?}/recipes" "${root:?}/shlibs.map"
    mkdir -p "$root/db"
}

# side files refresh every round: a reused root must see today's
# repo. Rounds after the first union HEAD's suggestions in, so a
# held-at-HEAD recipe can still resolve host names only yesterday's
# file carried.
seed_side_files() { # seed_side_files <round>
    [ -e "$root/recipes" ] || ln -s "$repo_abs/recipes" "$root/recipes"
    if [ -f "$repo/shlibs.map" ]; then
        cp "$repo/shlibs.map" "$root/shlibs.map"
    fi
    {
        [ ! -f "$repo/provided.suggested" ] \
            || awk 'NF {print $1}' "$repo/provided.suggested"
        [ "$1" -eq 1 ] \
            || git -C "$repo" show HEAD:provided.suggested 2>/dev/null \
                | awk 'NF {print $1}'
    } | LC_ALL=C sort -u >"$root/db/provided"
}

# reconcile a reused root to the staged repo before building. The
# resolver satisfies deps by presence alone and never reads a version,
# so anything installed that the staged repo no longer vouches for
# (recipe gone, or version drifted from the staged recipe) has to go,
# along with every working-list name (explicit targets rebuild). chy
# refuses to remove a depended-on package, so removal runs in passes.
# A pass that removes nothing with work left means the root can't be
# reconciled cheaply, so it gets discarded instead.
reconcile_root() { # reconcile_root <working-list-file>
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
    cat "$1" >>"$rr_list"
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
            say 'reused root cannot be reconciled; starting fresh'
            wipe_root
            break
        fi
    done
}

# --- working list plumbing ---

# the recipes the staged diff touches: first path component under
# recipes/. The git read goes to a file and gets checked, so a failing
# git can't pass for an empty diff. A name gone from the worktree is a
# prune, nothing to build.
staged_names() {
    git -C "$repo" diff --cached --name-only -- recipes/ \
        >"$scratch/staged" || die 'git diff --cached failed'
    sed -n 's|^recipes/\([^/][^/]*\)/.*|\1|p' "$scratch/staged" \
        | LC_ALL=C sort -u
}

# best-effort dependency order over the list: names whose in-list
# depends are already placed go first (warm roots then rebuild deps
# before dependents). Any order is safe, this is placement, not
# correctness. Bounded passes, leftovers (cycles) append in byte order.
order_names() { # stdin: names; stdout: ordered names
    on_in="$scratch/order-in"
    LC_ALL=C sort -u >"$on_in"
    on_left="$scratch/order-left"
    cp "$on_in" "$on_left"
    : >"$scratch/order-done"
    on_pass=0
    while [ -s "$on_left" ] && [ "$on_pass" -lt 25 ]; do
        on_pass=$((on_pass + 1))
        on_next="$scratch/order-next"
        : >"$on_next"
        cp "$on_left" "$scratch/order-set"
        while IFS= read -r on_n; do
            on_ready=1
            if [ -f "$repo/recipes/$on_n/depends" ]; then
                while IFS= read -r on_d; do
                    on_d=${on_d%% *}
                    [ -n "$on_d" ] || continue
                    if grep -Fqx "$on_d" "$scratch/order-set" \
                        && [ "$on_d" != "$on_n" ]; then
                        on_ready=0
                        break
                    fi
                done <"$repo/recipes/$on_n/depends"
            fi
            if [ "$on_ready" -eq 1 ]; then
                printf '%s\n' "$on_n" >>"$scratch/order-done"
            else
                printf '%s\n' "$on_n" >>"$on_next"
            fi
        done <"$on_left"
        if cmp -s "$on_left" "$on_next"; then
            break # cycle or cross-dependency stall: flush in byte order
        fi
        mv "$on_next" "$on_left"
    done
    cat "$scratch/order-done" "$on_left" 2>/dev/null | awk 'NF && !seen[$0]++'
}

# hold a failed name: restore its HEAD recipe (index and worktree,
# cleanly: staged-only files under the path must not survive), or
# remove it entirely when HEAD never had it
hold_name() { # hold_name <name> -> prints "held" or "absent"
    if git -C "$repo" cat-file -e "HEAD:recipes/$1" 2>/dev/null; then
        git -C "$repo" rm -r -q --cached "recipes/$1" 2>/dev/null || true
        rm -rf "${repo:?}/recipes/${1:?}"
        git -C "$repo" checkout -q HEAD -- "recipes/$1"
        git -C "$repo" add -A "recipes/$1"
        printf 'held\n'
    else
        git -C "$repo" rm -r -q "recipes/$1" 2>/dev/null \
            || rm -rf "${repo:?}/recipes/${1:?}"
        printf 'absent\n'
    fi
}

file_issue() { # file_issue <name> <log>
    fi_last=$(tail -n 1 "$2") || fi_last=''
    mkdir -p "$decisions/issues"
    {
        printf 'The build gate held %s: it failed to build.\n\n' "$1"
        printf 'package: %s\n' "$1"
        printf 'void commit: %s\n' "$(sed -n 's/^void-commit: //p' \
            "$repo/recipes/$1/meta" 2>/dev/null | head -n 1 | grep . \
            || printf 'unknown')"
        printf 'blamed by the log: %s\n' "$(grep 'chy: .*: error:' "$2" \
            | tail -n 1 | sed 's/^chy: \([^:]*\):.*/\1/' | grep . \
            || printf '%s' "$1")"
        printf '\nlast 30 lines:\n\n```\n'
        tail -n 30 "$2"
        printf '```\n\n'
        printf 'The package is held at its last published recipe (or absent\n'
        printf 'when it never had one); the rest of the day shipped.\n'
        printf 'Translated output is regenerated wholesale, so fix the\n'
        printf 'translator or its inputs, never the recipe; this issue\n'
        printf 'closes on the next push that carries %s.\n\n' "$1"
        printf 'run: RUN_URL\n\n'
        printf 'reason-hash: %s\n' "$(hash_of "build $1: $fi_last")"
    } >"$decisions/issues/build-$1.md"
}

# --- the round loop ---

held=''        # names held at their HEAD recipes
held_absent='' # new names held absent for the day
round=1
while :; do
    names=$(staged_names)
    # working list: diff names plus every held name (the shipped
    # combination is what gets validated), held-absent names ship
    # absent, nothing there to validate
    worklist="$scratch/worklist"
    {
        printf '%s\n' "$names"
        for h in $held; do printf '%s\n' "$h"; done
    } | awk 'NF' | LC_ALL=C sort -u >"$worklist"
    if [ ! -s "$worklist" ]; then
        say 'no recipe changes staged, nothing to build'
        exit 0
    fi

    if [ "$round" -gt 1 ]; then
        # fresh root at the same path: the previous round's builds
        # include combinations that won't ship
        wipe_root
    elif [ -d "$root/db/installed" ]; then
        reconcile_root "$worklist"
    fi
    seed_side_files "$round"

    say "round $round"
    order_names <"$worklist" >"$scratch/ordered"
    failures=''
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ ! -d "$repo/recipes/$name" ]; then
            say "pruned, not built: $name"
            continue
        fi
        log="$scratch/build-$name.log"
        : >"$log" || die "cannot write $log"
        rc=0
        CHY_ROOT="$root" sh "$chy" install "$name" >"$log" 2>&1 </dev/null \
            || rc=$?
        if [ "$rc" -eq 0 ]; then
            say "built: $name"
            continue
        fi
        # chy exits 2 when it couldn't even run, that's the gate
        # broken, not the package
        [ "$rc" -ne 2 ] || die "chy could not run for $name: $(tail -n 1 "$log")"
        failures="$failures$name "
        say "build FAILED: $name"
        # the tail goes to the step log too: a hold nobody can read
        # is noise
        tail -n 15 "$log" | sed 's/^/repo-build:   /'
        file_issue "$name" "$log"
    done <"$scratch/ordered"

    if [ -z "$failures" ]; then
        break
    fi
    round=$((round + 1))
    if [ "$round" -gt 3 ]; then
        rm -f "$decisions/commit.msg"
        printf 'build-failed\n' >"$decisions/nochange"
        say "three rejected rounds - no commit (systemic)"
        exit 0
    fi
    for f in $failures; do
        if printf '%s' " $held " | grep -q " $f "; then
            # a held name failed against the surviving combination:
            # pull its in-diff deps into the hold. With none, nothing
            # can be unwound and the day is systemic
            f_deps=''
            if [ -f "$repo/recipes/$f/depends" ]; then
                while IFS= read -r d; do
                    d=${d%% *}
                    [ -n "$d" ] || continue
                    printf '%s\n' "$names" | grep -Fqx "$d" || continue
                    f_deps="$f_deps$d "
                done <"$repo/recipes/$f/depends"
            fi
            if [ -z "$f_deps" ]; then
                rm -f "$decisions/commit.msg"
                printf 'build-failed\n' >"$decisions/nochange"
                say "held $f fails with nothing left to unwind - no commit"
                exit 0
            fi
            for d in $f_deps; do
                case $(hold_name "$d") in
                    held)   held="$held$d " ;;
                    absent) held_absent="$held_absent$d " ;;
                esac
                say "held (unwound under $f): $d"
            done
            continue
        fi
        case $(hold_name "$f") in
            held)   held="$held$f "; say "held at HEAD: $f" ;;
            absent) held_absent="$held_absent$f "; say "held absent: $f" ;;
        esac
    done
    git -C "$repo" add -A
done

if [ -n "$held$held_absent" ]; then
    printf 'gate held: %s\n' "$(printf '%s' "$held$held_absent" \
        | tr ' ' '\n' | awk 'NF' | LC_ALL=C sort | tr '\n' ' ' \
        | sed 's/ $//')" >>"$decisions/commit.msg"
    say "day stands with holds:$held$held_absent"
else
    say "all built clean, decision stands"
fi
exit 0
