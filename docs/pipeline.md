# The pipeline, end to end

chy-recipes is generated. This is the machine that generates it, in
the order it runs every night, and what each stage refuses to do.

## Snapshot

`chytrans snapshot` pins the day's inputs: the rolling x86_64
repodata, each set member's template tree at the commit the index
names for it, and common/shlibs at current master. Commit lookups
batch over GraphQL (a hundred refs a query) and fall back to per-ref
REST; a ref the API calls ambiguous resolves through the package's
own history, and one that will not resolve skips that package's tree
with a warning. Everything fetched lands in a MANIFEST with sha256s,
so the snapshot can be re-audited offline.

The soak gate: a package is adopted only when both the mirror's
binary timestamp and the template's committer date read at least
seven days old. Anything younger, and any lookup in doubt, defers:
the recipe already published stays, a new one waits. A malicious or
broken upstream commit gets a week of public exposure before this
repo will mirror it.

## Translate

`chytrans translate` regenerates every set member from the snapshot,
wholesale. It refuses what it cannot translate faithfully: build
styles outside the allowlist, hooks outside the idiom set, patch
headers it cannot derive a strip level from, patch_args beyond a bare
strip flag. A refused package that has a published recipe is held at
it (the seed loop carries the bytes; nothing regenerates them); one
that never had a recipe stays absent. Either way an issue is filed
and the rest of the day proceeds. Handwritten recipes (`origin:
handwritten`, exact grammar) are never regenerated and never
refused.

Patches ship byte-identical to Void's. Their strip levels ride the
optional `patchlevel` recipe file, derived from the headers (a/ or b/
markers mean -p1, bare paths mean the old -p0 era) or pinned by the
template's patch_args.

## The gate

`ci/repo-build.sh` builds every recipe the staged diff touches, in a
root that persists between runs. Before building, the root is
reconciled by invariant: anything installed whose recipe is gone or
whose version drifted from the staged recipe leaves, along with every
diff name. A failed build holds its package (recipe restored from
HEAD, or removed when new), files an issue, and the survivors
re-validate on a fresh root as the exact combination that will ship;
a held package that still fails pulls its in-diff dependencies into
the hold. Three rejected rounds reject the day: that is systemic.

After a clean loop, `chy doctor` runs over the whole root. Every
library of every installed package must resolve, or the day rejects.
As the cached root accretes the published set, this converges on the
entire repo being checked every night.

The gate proves compile, link, staging, and resolution. It does not
prove a package behaves correctly at runtime; only the firefox
acceptance goes that far.

## Apply

`ci/repo-apply.sh` commits the staged index as the bot and pushes
through a write deploy key; the target's branch ruleset admits only
that key, and every run verifies the lock first. Issues open and
update keyed on exact title with a reason-hash marker, so an
unchanged reason stays silent. A push auto-closes the issues of
packages the new report shows translated, except names held today:
a live hold is not a fix.

Every sync commit carries the Actions run URL. That is the
provenance chain: commit, to run, to logs, to the pinned MANIFEST.

## The host contract

chy satisfies provided names by name alone; db/provided carries no
versions. "Host-provided icu" means whatever icu the host has. The
gate validates against a current Void container, so a host much older
than that may need newer system libraries than it carries. The
container installs `tests/acceptance-hostpkgs` plus whatever the
staged repo's own provided.suggested names, tolerantly; a genuinely
missing host tool surfaces as a named build failure, which is the
feedback loop for growing the list.

## When something goes wrong

A bad published sync: pause the schedule first, then revert on
chy-recipes, then land the root cause here. A bare revert without the
pause self-undoes at the next sync, because recipes regenerate
wholesale.

Key rotation: add the new deploy key on chy-recipes, update the
RECIPES_DEPLOY_KEY secret here, then delete the old key, in that
order. The ruleset's bypass is keyed on the DeployKey type, not a
specific key, so rotation never trips the lock verifier. Deploy keys
created through a personal access token are deleted with that token;
keys meant to outlive their creator belong in the web UI.

A run that dies before any verdict files "repo-sync: run failed
before a verdict", including timeout cancellations, which usually
mean an oversized set chunk. A weekly probe deliberately breaks chy
and confirms the suite notices; its miss files its own issue.
