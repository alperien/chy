"""Dependency parsing and closure logic over Void repodata.

Pure functions over the snapshot's repodata slice: a dict mapping binary
package name -> its repodata index entry (the plist dicts Void publishes).
Everything here is offline and deterministic: token grammar, flattening
and drops, shlibs.map, the dependency closure.

Python 3.9+, stdlib only.
"""

import re

# the libc never appears in chy dependency output or closures.
LIBC = ("glibc", "musl")

# Operator-less exact pin: rightmost -<version>_<revision> suffix.  The
# version class has no hyphen, so greedy backtracking
# finds the rightmost hyphen that yields a legal split:
#   at-spi2-core-2.56.5_1 -> (at-spi2-core, 2.56.5, 1)
#   gtk+3-3.24.52_1       -> (gtk+3, 3.24.52, 1)
_PIN_RE = re.compile(r"^(.+)-([A-Za-z0-9._+]+)_([0-9]+)$")


def parse_dep(token):
    """Parse one dependency token -> (name, kind).

    kind is one of 'ge', 'lt', 'pin', 'plain', 'virtual' (operator
    forms first, then the exact pin, then a bare name).  A dual-bound
    token like 'python3>=3.14.0_1<3.15.0_1' is 'ge'; the name still
    splits off right, and constraints get stripped anyway.
    """
    if token.startswith("virtual?"):
        name, _kind = parse_dep(token[len("virtual?"):])
        return (name, "virtual")
    if ">=" in token:
        return (token.split(">=", 1)[0], "ge")
    if "<" in token:
        return (token.split("<", 1)[0], "lt")
    m = _PIN_RE.match(token)
    if m:
        return (m.group(1), "pin")
    return (token, "plain")


# Void-internal source-only names that never ship a binary: a small,
# reviewed name-map.  One entry today: Void's glib<->gobject-introspection
# bootstrap package, which in chy's merged world is just the published
# gobject-introspection.  Growing this table is a golden-diff review,
# like the idiom set.
_NAME_MAP = {
    "gobject-introspection-bootstrap": "gobject-introspection",
}


def canonical(name):
    """The name-map, applied: Void-internal source-only names become
    their published equivalents; everything else passes through."""
    return _NAME_MAP.get(name, name)


def flatten(name, slice):
    """Binary package name -> source package name via the entry's
    repodata 'source-revisions' ("srcpkg:commit").  None = the name
    isn't in the slice; that miss is a per-package refusal, and raising
    it is the caller's job."""
    name = canonical(name)
    entry = slice.get(name)
    if entry is None:
        return None
    src = entry.get("source-revisions", "").split(":", 1)[0]
    return src or None


def source_commit(name, slice):
    """The pinned void-packages commit for a name's source package,
    from 'source-revisions' ("srcpkg:commit"); None on a miss."""
    entry = slice.get(name)
    if entry is None:
        return None
    parts = entry.get("source-revisions", "").split(":", 1)
    return parts[1] if len(parts) == 2 and parts[1] else None


def binary_run_closure(names, slice):
    """Transitive repodata run_depends of `names`, as BINARY package
    names.  The inputs themselves are not included (unless reached via
    some other member's dependency chain).  The libc is dropped before
    expansion; 'virtual?' tokens cannot be resolved and are skipped
.  Names absent
    from the slice are kept in the result but not expanded: at snapshot
    time the slice is the full index so nothing misses, and at translate
    time the caller detects the miss via flatten() and refuses."""
    seen = set()
    stack = sorted(names)
    while stack:
        current = stack.pop()
        entry = slice.get(current)
        if entry is None:
            continue
        for token in entry.get("run_depends", []):
            dep, kind = parse_dep(token)
            if kind == "virtual" or dep in LIBC or dep in seen:
                continue
            seen.add(dep)
            stack.append(dep)
    return seen


def run_closure(names, slice):
    """Transitive run_depends of `names`, flattened to source package
    names, libc dropped.  run_closure({'zlib'}) == set(): zlib's only
    run dependency is the libc."""
    flattened = set()
    for binary in binary_run_closure(names, slice):
        src = flatten(binary, slice)
        if src is not None:
            flattened.add(src)
        # A slice miss stays silent here; binary_run_closure's
        # docstring says who refuses.
    return flattened


def _shlibs_first_entry(shlibs_text):
    """common/shlibs -> {soname: first package field}.  Lines are
    '<soname> <pkgname>-<version>_<revision>' with '#' comments; the
    FIRST entry for a soname wins."""
    first = {}
    for line in shlibs_text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 2:
            continue
        if fields[0] not in first:
            first[fields[0]] = fields[1]
    return first


def shlibs_map_with_ambiguities(slice, shlibs_text):
    """in full: (map lines, ambiguous sonames).

    Scope is every shlib-provides entry in the slice.  Each map line is
    '<soname> <source package>', whole-line byte-order sorted.  A soname
    with several source-package providers resolves to the provider named
    by common/shlibs (first entry, version-stripped via the pin
    parse, flattened) when that names one of the actual providers;
    otherwise the byte-smallest source name wins and the soname lands on
    the ambiguity list (reported as 'ambiguous-soname:' by chytrans)."""
    providers = {} # soname -> set of source package names
    for binary in slice:
        entry = slice[binary]
        sonames = entry.get("shlib-provides") or []
        if not sonames:
            continue
        src = flatten(binary, slice)
        if src is None:
            continue
        for soname in sonames:
            providers.setdefault(soname, set()).add(src)

    first = _shlibs_first_entry(shlibs_text)
    lines = []
    ambiguous = []
    for soname in providers:
        sources = providers[soname]
        if len(sources) == 1:
            chosen = next(iter(sources))
        else:
            chosen = None
            hint = first.get(soname)
            if hint:
                hint_name, _kind = parse_dep(hint)
                candidate = flatten(hint_name, slice)
                if candidate in sources:
                    chosen = candidate
            if chosen is None:
                chosen = min(sources)
                ambiguous.append(soname)
        lines.append("%s %s" % (soname, chosen))
    return sorted(lines), sorted(ambiguous)


def shlibs_map(slice, shlibs_text):
    """lines, sorted (the map only; chytrans uses
    shlibs_map_with_ambiguities to also get the report lines)."""
    lines, _ambiguous = shlibs_map_with_ambiguities(slice, shlibs_text)
    return lines
