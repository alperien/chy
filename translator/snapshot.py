"""Build (network) and load (offline) the snapshot.

create() is the only networked code in the translator: it fetches Void's
x86_64-repodata, common/shlibs at the current master commit, and each
requested package's srcpkgs/<name>/ tree at its pinned source-revisions
commit (shallow, sparse, blob-filtered git fetch; docs/).
load() is offline and is all the translate pipeline ever touches.

Python 3.9+, stdlib only; external tools: curl, zstd, tar, git, bash.
"""

import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

import repodata

REPODATA_URL = "https://repo-default.voidlinux.org/current/x86_64-repodata"
VOID_GIT = "https://github.com/void-linux/void-packages.git"
RAW_URL = "https://raw.githubusercontent.com/void-linux/void-packages"
COMMITS_API = "https://api.github.com/repos/void-linux/void-packages/commits/"

# tool-injection mirror.  Void injects these outside templates, so
# no evaluation can surface them; the slice has to contain them (and their
# run-closures) or translation refuses on a flatten miss.  This table
# errs generous: emit adds pkg-config to gnu-configure / configure /
# gnu-makefile builds only when configure_args or hooks reference it,
# but a slice SUPERSET is always safe while an undershoot refuses;
# chytrans keeps provided.suggested exact by intersecting with emit's
# Result lists.
STYLE_TOOLS = {
    "meson": ("meson", "ninja", "pkg-config"),
    "cmake": ("cmake", "ninja"),
    "gnu-configure": ("pkg-config",),
    "configure": ("pkg-config",),
    "gnu-makefile": ("pkg-config",),
}
HELPER_TOOLS = {"gir": ("gobject-introspection",)}


class SnapshotError(Exception):
    """Snapshot creation or loading failed; message is user-facing."""


class Snapshot:
    """An on-disk snapshot, loaded. .slice maps binary package name to
    its repodata entry; .shlibs is the common/shlibs text; .manifest is
    the MANIFEST's lines."""

    def __init__(self, dir, slice, shlibs, manifest):
        self.dir = dir
        self.slice = slice
        self.shlibs = shlibs
        self.manifest = manifest

    def srcpkg_dir(self, name):
        """Absolute path of the snapshotted srcpkgs/<name>/ tree, or
        None when the snapshot holds no tree for that name."""
        path = os.path.join(self.dir, "srcpkgs", name)
        return path if os.path.isdir(path) else None


def load(dir):
    """Load a snapshot directory (offline)."""
    dir = os.path.abspath(dir)
    slice_path = os.path.join(dir, "repodata.slice.plist")
    shlibs_path = os.path.join(dir, "common-shlibs")
    if not os.path.isfile(slice_path) or not os.path.isfile(shlibs_path):
        raise SnapshotError("%s: not a snapshot (missing repodata.slice.plist"
                            " or common-shlibs)" % dir)
    with open(slice_path, "rb") as f:
        slice = plistlib.load(f)
    with open(shlibs_path, "r", encoding="utf-8", errors="replace") as f:
        shlibs = f.read()
    manifest = []
    manifest_path = os.path.join(dir, "MANIFEST")
    if os.path.isfile(manifest_path):
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = [line.rstrip("\n") for line in f if line.strip()]
    return Snapshot(dir, slice, shlibs, manifest)


# dumps

_UNESCAPE = {"t": "\t", "n": "\n", "\\": "\\"}


def _unescape(value):
    out, i = [], 0
    while i < len(value):
        ch = value[i]
        if ch == "\\" and i + 1 < len(value) and value[i + 1] in _UNESCAPE:
            out.append(_UNESCAPE[value[i + 1]])
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def _dump_dir(dump_root, name):
    # The fixed dump format is dump/<name>/vars; tolerate an
    # evaluate.sh that writes straight into the given out-dir (flat
    # layout) so a mismatched component pair can't wedge the glue.
    for candidate in (os.path.join(dump_root, name), dump_root):
        if os.path.isfile(os.path.join(candidate, "vars")):
            return candidate
    return None


def read_dump_vars(dump_root, name):
    """Parse dump/<name>/vars ("key<TAB>value", \\t \\n \\\\ escapes)
    into a dict, or None when no dump exists for the name."""
    dir = _dump_dir(dump_root, name)
    if dir is None:
        return None
    vars = {}
    with open(os.path.join(dir, "vars"), "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            key, _sep, value = line.partition("\t")
            vars[key] = _unescape(value)
    return vars


def dump_dep_names(dump_root, name):
    """Binary package names referenced by the dump's evaluated
    hostmakedepends + makedepends (parsed, virtual and libc dropped)."""
    vars = read_dump_vars(dump_root, name)
    if vars is None:
        return set()
    names = set()
    for key in ("hostmakedepends", "makedepends"):
        for token in vars.get(key, "").split():
            dep, kind = repodata.parse_dep(token)
            if kind == "virtual" or dep in repodata.LIBC:
                continue
            names.add(repodata.canonical(dep))
    return names


def injected_tools(dump_root, name):
    """The tool names injected for this dump's build_style and
    build_helper (generous; see STYLE_TOOLS comment)."""
    vars = read_dump_vars(dump_root, name)
    if vars is None:
        return set()
    tools = set(STYLE_TOOLS.get(vars.get("build_style", "").strip(), ()))
    for helper in vars.get("build_helper", "").split():
        tools.update(HELPER_TOOLS.get(helper, ()))
    return tools


# create

def _run(cmd, **kwargs):
    return subprocess.run(cmd, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, **kwargs)


def _curl(url):
    proc = _run(["curl", "-sSfL", "--max-time", "300", url])
    if proc.returncode != 0:
        raise SnapshotError("fetch failed: %s: %s"
                            % (url, proc.stderr.decode().strip()))
    return proc.stdout


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load_index(repodata_bytes, tmp):
    blob = os.path.join(tmp, "x86_64-repodata")
    with open(blob, "wb") as f:
        f.write(repodata_bytes)
    extract = os.path.join(tmp, "repodata.d")
    os.mkdir(extract)
    zstd = subprocess.Popen(["zstd", "-dc", blob], stdout=subprocess.PIPE)
    tar = subprocess.Popen(["tar", "-xf", "-", "-C", extract],
                           stdin=zstd.stdout)
    zstd.stdout.close()
    tar.wait()
    zstd.wait()
    if zstd.returncode != 0 or tar.returncode != 0:
        raise SnapshotError("repodata: zstd/tar extraction failed")
    with open(os.path.join(extract, "index.plist"), "rb") as f:
        return plistlib.load(f)


def _full_commit(abbrev):
    """Expand an abbreviated source-revisions commit to the full 40-hex
    id (GitHub only serves fetch-by-SHA for full ids)."""
    if len(abbrev) == 40:
        return abbrev
    data = json.loads(_curl(COMMITS_API + abbrev).decode())
    full = data.get("sha", "")
    if len(full) != 40 or not full.startswith(abbrev):
        raise SnapshotError("commit %s: could not resolve full sha" % abbrev)
    return full


def _fetch_srcpkg_trees(names, index, outdir, tmp):
    """Shallow, sparse, blob-filtered fetch of srcpkgs/<name>/ at each
    package's pinned commit; copies the verbatim trees under
    outdir/srcpkgs/.  Returns {name: full commit}."""
    gitdir = os.path.join(tmp, "git")
    os.mkdir(gitdir)
    for cmd in (["git", "init", "-q", "."],
                ["git", "remote", "add", "void", VOID_GIT]):
        proc = _run(cmd, cwd=gitdir)
        if proc.returncode != 0:
            raise SnapshotError("git setup failed: %s"
                                % proc.stderr.decode().strip())
    commits = {}
    for name in names:
        abbrev = repodata.source_commit(name, index)
        if abbrev is None:
            raise SnapshotError("%s: repodata entry has no source-revisions"
                                " commit" % name)
        commits[name] = _full_commit(abbrev)
    for sha in sorted(set(commits.values())):
        proc = _run(["git", "fetch", "-q", "--depth", "1",
                     "--filter=blob:none", "void", sha], cwd=gitdir)
        if proc.returncode != 0:
            raise SnapshotError("git fetch %s failed: %s"
                                % (sha, proc.stderr.decode().strip()))
    for name in names:
        # checkout of specific paths pulls just those blobs on demand
        # from the promisor remote.
        proc = _run(["git", "checkout", "-q", commits[name], "--",
                     "srcpkgs/%s" % name], cwd=gitdir)
        fetched = os.path.join(gitdir, "srcpkgs", name)
        if proc.returncode != 0 or not os.path.isdir(fetched):
            raise SnapshotError(
                "%s: srcpkg fetch failed at %s: %s"
                % (name, commits[name], proc.stderr.decode().strip()))
        dest = os.path.join(outdir, "srcpkgs", name)
        if os.path.isdir(dest):
            shutil.rmtree(dest)
        shutil.copytree(fetched, dest, symlinks=True)
    return commits


def _harvest_makedepends(names, outdir, tmp):
    """Run evaluate.sh (offline-safe bash) over each fetched srcpkg tree
    to learn the evaluated hostmakedepends/makedepends plus the
    injected tools, so the slice covers everything translation can
    produce.  Snapshot creation can't know them any other way: they
    live in templates, not repodata.  When evaluate.sh is absent
    (older dumps were laid out flat) we degrade to the run_depends
    closure alone and warn; a snapshot built that way will refuse
    packages whose makedepends miss the slice."""
    eval_sh = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "evaluate.sh")
    if not os.path.isfile(eval_sh):
        sys.stderr.write(
            "chytrans: WARNING: translator/evaluate.sh is missing; building"
            " a DEGRADED snapshot\n"
            "chytrans: WARNING: slice = requested + run_depends closure only"
            " (no evaluated makedepends, no injected tools);\n"
            "chytrans: WARNING: translation from this snapshot will refuse"
            " any package needing more\n")
        return set()
    harvested = set()
    for name in names:
        dump_root = os.path.join(tmp, "snapdump", name)
        os.makedirs(dump_root, exist_ok=True)
        try:
            proc = _run(["bash", eval_sh,
                         os.path.join(outdir, "srcpkgs", name),
                         dump_root], timeout=300)
        except subprocess.TimeoutExpired:
            sys.stderr.write("chytrans: WARNING: %s: evaluation timed out"
                             " while building the snapshot\n" % name)
            continue
        if proc.returncode != 0:
            sys.stderr.write(
                "chytrans: WARNING: %s: evaluation failed while building the"
                " snapshot; its makedepends are not in the slice and its"
                " translation will refuse\n" % name)
            continue
        harvested |= dump_dep_names(dump_root, name)
        harvested |= injected_tools(dump_root, name)
    return harvested


def create(names, outdir):
    """Build the snapshot for `names` under `outdir` (network)."""
    names = sorted(set(names))
    outdir = os.path.abspath(outdir)
    tmp = tempfile.mkdtemp(prefix="chytrans-snap.")
    try:
        _create(names, outdir, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _create(names, outdir, tmp):
    index = _load_index(_curl(REPODATA_URL), tmp)

    problems = []
    for name in names:
        src = repodata.flatten(name, index)
        if src is None:
            problems.append("%s: not in repodata" % name)
        elif src != name:
            problems.append("%s: is a subpackage of %s; request the source"
                            " package" % (name, src))
    if problems:
        raise SnapshotError("; ".join(problems))

    os.makedirs(os.path.join(outdir, "srcpkgs"), exist_ok=True)

    # common/shlibs, pinned to the master commit resolved right now so
    # the MANIFEST line names a commit and the bytes stay refetchable.
    proc = _run(["git", "ls-remote", VOID_GIT, "refs/heads/master"])
    if proc.returncode != 0:
        raise SnapshotError("git ls-remote failed: %s"
                            % proc.stderr.decode().strip())
    master_sha = proc.stdout.decode().split()[0]
    shlibs_url = "%s/%s/common/shlibs" % (RAW_URL, master_sha)
    shlibs_bytes = _curl(shlibs_url)

    commits = _fetch_srcpkg_trees(names, index, outdir, tmp)

    # The slice: requested set + transitive run_depends closure,
    # + evaluated make-dependencies and injected tools + THEIR closures.
    slice_names = set(names) | repodata.binary_run_closure(names, index)
    extra = _harvest_makedepends(names, outdir, tmp)
    missing_extra = sorted(n for n in extra if n not in index)
    for n in missing_extra:
        sys.stderr.write("chytrans: WARNING: evaluated dependency %s is not"
                         " in repodata; left out of the slice\n" % n)
    extra = {n for n in extra if n in index}
    slice_names |= extra | repodata.binary_run_closure(extra, index)
    slice = {n: index[n] for n in sorted(slice_names)}

    slice_path = os.path.join(outdir, "repodata.slice.plist")
    with open(slice_path, "wb") as f:
        plistlib.dump(slice, f, sort_keys=True)
    with open(os.path.join(outdir, "common-shlibs"), "wb") as f:
        f.write(shlibs_bytes)

    # MANIFEST: one line per fetched object, "url commit sha256".  The
    # digests are of the files as they sit in the snapshot, so an
    # offline audit can re-hash the tree; the repodata line records the
    # upstream URL but digests the derived slice (the retained
    # artifact), with '-' for the commit it doesn't have.
    manifest = ["%s - %s" % (REPODATA_URL, _file_sha256(slice_path)),
                "%s %s %s" % (shlibs_url, master_sha, _sha256(shlibs_bytes))]
    for name in names:
        tree = os.path.join(outdir, "srcpkgs", name)
        for root, dirs, files in os.walk(tree):
            dirs.sort()
            for fn in sorted(files):
                path = os.path.join(root, fn)
                if os.path.islink(path) or not os.path.isfile(path):
                    continue # regular files only; nothing else to hash
                rel = os.path.relpath(path, outdir)
                manifest.append("%s/%s/%s %s %s"
                                % (RAW_URL, commits[name], rel,
                                   commits[name], _file_sha256(path)))
    with open(os.path.join(outdir, "MANIFEST"), "w", encoding="utf-8") as f:
        for line in sorted(manifest):
            f.write(line + "\n")
