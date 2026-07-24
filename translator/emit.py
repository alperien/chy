"""The chytrans emitter.

Turns one evaluated template dump plus the snapshot's repodata slice into
one chy recipe directory, or refuses the package.  Numbered sections below;
each header notes which part of the format it handles.

Every sort in this file is byte order (C collation).  python3 stdlib only.
"""

import hashlib
import os
import re
import shutil

# repodata.py is a sibling: package-relative when translator/ is imported
# as a package, plain module when chytrans runs script-style.
try:
    from . import repodata # type: ignore
except ImportError: # pragma: no cover - script-style layout
    import repodata # type: ignore


# section 1: refusals and the Result type (the fixed interface)

class Refuse(Exception):
    """Per-package refusal; nothing gets written for the package."""


class Result:
    """What translate() hands back to chytrans.

    .ok            bool
    .name          package name
    .reason        refusal reason when not ok, else ''
    .depends       flattened, final runtime dependency names (sorted)
    .makedepends   flattened, final build dependency names (sorted)
    .files         {recipe-relative path: bytes}, everything write() emits
    """

    def __init__(self, name):
        self.ok = False
        self.name = name
        self.reason = ''
        self.depends = []
        self.makedepends = []
        self.files = {}


# section 2: dump reading

# keys the evaluator always writes. empty values are fine.
_DUMP_KEYS = (
    'pkgname', 'version', 'revision', 'build_style', 'build_helper',
    'distfiles', 'checksum', 'hostmakedepends', 'makedepends', 'depends',
    'conflicts', 'configure_args', 'make_build_args', 'make_install_args',
    'make_build_target', 'make_install_target', 'conf_files',
    'system_accounts', 'env_vars',
)


def _unescape(value):
    """Undo the vars-file escapes: \\t \\n \\\\ (left to right, one pass)."""
    out = []
    i = 0
    while i < len(value):
        c = value[i]
        if c == '\\' and i + 1 < len(value):
            n = value[i + 1]
            if n == 't':
                out.append('\t')
                i += 2
                continue
            if n == 'n':
                out.append('\n')
                i += 2
                continue
            if n == '\\':
                out.append('\\')
                i += 2
                continue
        out.append(c)
        i += 1
    return ''.join(out)


def _read_dump(dumpdir, name):
    """Read <dumpdir>/<name>/{vars,functions/} -> (vars dict, functions dict).

    functions maps function name -> verbatim body text.
    """
    d = os.path.join(dumpdir, name)
    varsfile = os.path.join(d, 'vars')
    if not os.path.isfile(varsfile):
        raise Refuse('no evaluated dump at %s' % varsfile)
    dump = {}
    with open(varsfile, encoding='utf-8') as f:
        for line in f.read().splitlines():
            if not line:
                continue
            if '\t' not in line:
                raise Refuse('malformed dump vars line: %r' % line)
            key, _, value = line.partition('\t')
            dump[key] = _unescape(value)
    for key in _DUMP_KEYS:
        if key not in dump:
            raise Refuse('dump vars missing required key %r' % key)
    functions = {}
    fdir = os.path.join(d, 'functions')
    if os.path.isdir(fdir):
        for fname in sorted(os.listdir(fdir)):
            with open(os.path.join(fdir, fname), encoding='utf-8') as f:
                functions[fname] = f.read()
    return dump, functions


# section 3: dependency translation
# Applies identically to run_depends, hostmakedepends+makedepends, and
# conflicts: parse, flatten, drop libc/self/dupes, strip versions, sort.

_LIBC = ('glibc', 'musl')


def _translate_deps(tokens, slice_, self_name, what):
    out = set()
    for tok in tokens:
        pname, kind = repodata.parse_dep(tok)
        if kind == 'virtual':
            raise Refuse('%s: virtual? dependency %r (not resolved)'
                         % (what, tok))
        # the libc is dropped BEFORE any slice lookup; no
        # slice carries it
        if pname in _LIBC:
            continue
        src = repodata.flatten(pname, slice_)
        if src is None:
            raise Refuse('%s: dependency %r not in the snapshot slice'
                         % (what, pname))
        if src in _LIBC or src == self_name:
            continue
        out.add(src)
    return sorted(out)


# section 4: shell tokenizer
# Splits one logical line into raw words (original quoting preserved) and
# reports every compound construct seen outside single quotes.  Not shlex:
# shlex can't flag compounds.

_KEYWORDS = ('if', 'case', 'for', 'while', 'until')
_ORPHAN_KW = ('then', 'do', 'done', 'fi', 'esac', 'else', 'elif')


def _tokenize(line):
    """-> (words, compounds).  words keep their original quote characters."""
    words = []
    cur = []
    comp = set()
    quote = None # None, "'" or '"'
    var_brace = 0 # depth of open ${...} expansions
    i = 0
    n = len(line)

    def flush():
        if cur:
            words.append(''.join(cur))
            del cur[:]

    while i < n:
        c = line[i]
        if quote == "'":
            cur.append(c)
            if c == "'":
                quote = None
            i += 1
            continue
        # command substitution executes inside double quotes too
        if c == '`':
            comp.add('command substitution')
            cur.append(c)
            i += 1
            continue
        if c == '$' and i + 1 < n and line[i + 1] == '(':
            comp.add('command substitution')
            cur.append(c)
            i += 1
            continue
        if quote == '"':
            cur.append(c)
            if c == '"':
                quote = None
            i += 1
            continue
        if c == "'":
            quote = "'"
            cur.append(c)
            i += 1
            continue
        if c == '"':
            quote = '"'
            cur.append(c)
            i += 1
            continue
        if c in ' \t':
            flush()
            i += 1
            continue
        if c == '#' and not cur:
            break # comment runs to end of line
        if c == '|':
            comp.add('pipe/or-list')
            i += 1
            continue
        if c == '&':
            comp.add('and-list/background')
            i += 1
            continue
        if c == ';':
            # a `;`-separated sequence of simple commands is NOT a
            # compound; the pieces get classified one command at a
            # time.  Emit a sentinel word.
            flush()
            words.append(';')
            i += 1
            continue
        if c in '()':
            comp.add('subshell')
            i += 1
            continue
        if c in '<>':
            comp.add('redirection')
            i += 1
            continue
        if c == '{':
            if cur and cur[-1] == '$':
                var_brace += 1 # ${...} is expansion, not brace grouping
            else:
                comp.add('brace expansion/grouping')
            cur.append(c)
            i += 1
            continue
        if c == '}':
            if var_brace > 0:
                var_brace -= 1
            else:
                comp.add('brace expansion/grouping')
            cur.append(c)
            i += 1
            continue
        cur.append(c)
        i += 1
    flush()
    if quote is not None:
        comp.add('unterminated quote')
    return words, comp


def _logical_lines(body):
    """Body -> logical lines: backslash continuations joined, blanks and
    whole-line comments removed."""
    out = []
    pend = ''
    for raw in body.splitlines():
        line = pend + raw
        if line.rstrip().endswith('\\'):
            pend = line.rstrip()[:-1] + ' '
            continue
        pend = ''
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        out.append(stripped)
    if pend.strip():
        out.append(pend.strip())
    return out


def _unquote(word):
    """Strip one pair of matching outer quotes.  For reading a word's
    semantic value, never for emission."""
    if len(word) >= 2 and word[0] == word[-1] and word[0] in '\'"':
        return word[1:-1]
    return word


# section 5: word rewriting, the variable and path maps
# $DESTDIR/usr/...  -> "$1$CHY_ROOT/usr/..."     (path map)
# $DESTDIR        -> "$1"                    (make variable map)
# $FILESDIR/<x>   -> basename(<x>), and <x> is recorded as a files/ asset
# ${makejobs}     -> dropped (serial), make commands only
# Any other variable reference is unresolvable -> class C.

class _HookC(Exception):
    """Internal: this function is class C, with a reason."""


_DESTDIR_SPELLINGS = ('${DESTDIR}', '$DESTDIR')
# double quotes only: a single-quoted $FILESDIR never expands in shell
_FILESDIR_RE = re.compile(r'^("?)\$\{?FILESDIR\}?/(.+)$')
_VARREF_RE = re.compile(r'\$(?:\{([A-Za-z_][A-Za-z0-9_]*)[^}]*\}'
                        r'|([A-Za-z_][A-Za-z0-9_]*)|([0-9@*#?!-]))')
_ALLOWED_VARS = {'CHY_ROOT', 'CHY_PREFIX', '1'}
_ASSET_NAME_RE = re.compile(r'^[A-Za-z0-9._+@-]+(/[A-Za-z0-9._+@-]+)*$')


def _sub_destdir(word):
    """Replace every $DESTDIR spelling in a raw word, quote-aware.

    Followed by '/': becomes $1$CHY_ROOT (path map).  Standalone: $1.
    Outside double quotes the replacement is emitted quoted; inside an
    existing double-quoted span it's spliced in bare.
    """
    out = []
    i = 0
    n = len(word)
    quote = None
    while i < n:
        c = word[i]
        if quote == "'":
            out.append(c)
            if c == "'":
                quote = None
            i += 1
            continue
        matched = None
        if c == '"' and quote is None:
            # a quoted span holding exactly the variable: consume quotes too
            for sp in _DESTDIR_SPELLINGS:
                cand = '"%s"' % sp
                if word.startswith(cand, i):
                    matched = (cand, True)
                    break
        if matched is None and c == '$':
            for sp in _DESTDIR_SPELLINGS:
                if word.startswith(sp, i):
                    matched = (sp, quote == '"')
                    break
        if matched is not None:
            text, quoted_ctx = matched
            nxt = word[i + len(text):i + len(text) + 1]
            core = '$1$CHY_ROOT' if nxt == '/' else '$1'
            out.append(core if quoted_ctx and text[0] != '"'
                       else '"%s"' % core)
            i += len(text)
            continue
        if c == '"':
            quote = '"' if quote is None else None
        elif c == "'" and quote is None:
            quote = "'"
        out.append(c)
        i += 1
    word_out = ''.join(out)
    # our notation quotes the WHOLE mapped path -- "$1$CHY_ROOT/usr/x"
    # not "$1$CHY_ROOT"/usr/x
    word_out = re.sub(r'"(\$1(?:\$CHY_ROOT)?)"(/[^\s"\']*)', r'"\1\2"', word_out)
    return word_out


def _is_makejobs(word):
    core = _unquote(word)
    return core in ('$makejobs', '${makejobs}')


def _squoted_spans(text):
    """[start, end) spans lying inside single quotes.  Shell rules: a
    single quote inside a double-quoted span opens nothing."""
    spans = []
    quote = None
    start = 0
    for i, c in enumerate(text):
        if quote == "'":
            if c == "'":
                spans.append((start, i))
                quote = None
        elif quote == '"':
            if c == '"':
                quote = None
        elif c == "'":
            quote = "'"
            start = i + 1
        elif c == '"':
            quote = '"'
    if quote == "'":
        spans.append((start, len(text)))
    return spans


def _check_no_bare_abs(word, where):
    """No literal /usr (or /etc, /var) survives unless it hangs off
    $CHY_ROOT / $CHY_PREFIX / the DESTDIR rewrite (the golden assertion,
    applied here at classification time).  Single-quoted spans are sed
    text, not paths (single quotes suppress shell path semantics)."""
    spans = _squoted_spans(word)
    for root in ('/usr', '/etc', '/var'):
        start = 0
        while True:
            k = word.find(root, start)
            if k < 0:
                break
            end = k + len(root)
            if any(a <= k < b for a, b in spans):
                start = end
                continue
            follower = word[end:end + 1]
            # ':' and '=' end a path too (FOO=/usr:/opt): still a root
            if follower and follower not in '/"\' :=':
                start = end # /users, /etcetera: not a path root
                continue
            before = word[:k]
            if before.endswith('"'):
                before = before[:-1]
            if not (before.endswith('$CHY_ROOT') or before.endswith('$CHY_PREFIX')
                    or before.endswith('{CHY_ROOT}') or before.endswith('{CHY_PREFIX}')):
                raise _HookC('absolute path %r in %s has no chy mapping'
                             % (word, where))
            start = end


def _rewrite_word(word, ctx, where):
    """Apply the hook maps to one raw word; returns the emitted text.

    ctx.assets collects files/ references.  Raises _HookC when the word
    can't be rewritten.
    """
    m = _FILESDIR_RE.match(word)
    if m:
        rel = m.group(2)
        if m.group(1) and rel.endswith(m.group(1)):
            rel = rel[:-1]
        if '$' in rel or not _ASSET_NAME_RE.match(rel):
            raise _HookC('unresolvable files/ asset reference %r in %s'
                         % (word, where))
        ctx.assets.add(rel)
        return rel.rsplit('/', 1)[-1] # arrives in the build dir
    if '$FILESDIR' in word or '${FILESDIR}' in word:
        raise _HookC('embedded $FILESDIR reference %r in %s' % (word, where))
    new = _sub_destdir(word)
    for vm in _VARREF_RE.finditer(new):
        var = vm.group(1) or vm.group(2) or vm.group(3)
        if var not in _ALLOWED_VARS:
            raise _HookC('unresolvable variable $%s in %s' % (var, where))
    _check_no_bare_abs(new, where)
    return new


# section 6: the hook classifier, classes A, B, C and the idiom set
# the idiom set is closed. adding to it means a golden-diff review.

_PASSTHROUGH = ('sed', 'rm', 'ln', 'mv', 'cp', 'mkdir', 'install')
_MODE_RE = re.compile(r'^[0-7]{3,4}$')
_MAN_SECTION_RE = re.compile(r'\.([1-9])[a-z0-9]*$')

# Phase positions, complete.  (stage, slot); do_* replaces the stage.
_PHASE_POS = {
    'post_patch': ('patch', 'post'),
    'pre_configure': ('configure', 'pre'),
    'post_configure': ('configure', 'post'),
    'pre_build': ('build', 'pre'),
    'post_build': ('build', 'post'),
    'pre_install': ('install', 'pre'),
    'post_install': ('install', 'post'),
    'do_configure': ('configure', 'do'),
    'do_build': ('build', 'do'),
    'do_install': ('install', 'do'),
}
_CHECK_PHASES = ('do_check', 'pre_check', 'post_check')


class _HookCtx:
    """Carries what hook translation produces besides lines."""

    def __init__(self, name=''):
        self.name = name         # package under translation (pinned drops)
        self.assets = set()      # files/ relpaths referenced by A-lines
        self.dropped = set()     # meta `dropped:` payloads


def _dst_path(directory, leaf):
    """DESTDIR-relative install dir + leaf -> the emitted staged path."""
    d = '/' + directory.strip('/')
    return '"$1$CHY_ROOT%s/%s"' % (d, leaf)


def _semantic(word, fname):
    """A word used for its value (mode, dir, name): unquote, no variables."""
    val = _unquote(word)
    if '$' in val or '`' in val:
        raise _HookC('unresolvable variable in %r (%s)' % (word, fname))
    return val


def _xlate_simple(words, fname, ctx):
    """One simple command -> emitted line(s) (possibly none), or _HookC."""
    cmd = _unquote(words[0])
    args = words[1:]
    where = fname

    # B-class simple commands: dropped, documented
    if cmd == 'vlicense':
        ctx.dropped.add('vlicense in %s' % fname)
        return []
    if cmd == 'vsv':
        ctx.dropped.add('vsv in %s' % fname)
        return []

    # the idiom set
    if cmd == 'vsed':
        out = [_rewrite_word(w, ctx, where) for w in args]
        if '-i' not in [_unquote(w) for w in out]:
            out.insert(0, '-i')
        return ['sed ' + ' '.join(out)]

    if cmd == 'vinstall':
        # vinstall <src> <mode> <dir> [name] (Void semantics)
        if len(args) not in (3, 4):
            raise _HookC('vinstall with %d arguments in %s'
                         % (len(args), fname))
        src = _rewrite_word(args[0], ctx, where)
        mode = _semantic(args[1], fname)
        if not _MODE_RE.match(mode):
            raise _HookC('vinstall mode %r in %s' % (mode, fname))
        directory = _semantic(args[2], fname)
        leaf = (_semantic(args[3], fname) if len(args) == 4
                else _unquote(src).rsplit('/', 1)[-1])
        return ['install -Dm%s %s %s' % (mode, src, _dst_path(directory, leaf))]

    if cmd == 'vbin':
        # vbin <src> [name] -> mode 755 into usr/bin
        if len(args) not in (1, 2):
            raise _HookC('vbin with %d arguments in %s' % (len(args), fname))
        src = _rewrite_word(args[0], ctx, where)
        leaf = (_semantic(args[1], fname) if len(args) == 2
                else _unquote(src).rsplit('/', 1)[-1])
        return ['install -Dm755 %s %s' % (src, _dst_path('usr/bin', leaf))]

    if cmd == 'vman':
        # vman <page> [name] -> usr/share/man/manN by suffix
        if len(args) not in (1, 2):
            raise _HookC('vman with %d arguments in %s' % (len(args), fname))
        src = _rewrite_word(args[0], ctx, where)
        leaf = (_semantic(args[1], fname) if len(args) == 2
                else _unquote(src).rsplit('/', 1)[-1])
        m = _MAN_SECTION_RE.search(leaf)
        if not m:
            raise _HookC('vman page %r has no section suffix (%s)'
                         % (leaf, fname))
        return ['install -Dm644 %s %s'
                % (src, _dst_path('usr/share/man/man' + m.group(1), leaf))]

    if cmd == 'vmkdir':
        # vmkdir <dir> -> mkdir -p; a mode argument is outside the idiom
        if len(args) != 1:
            raise _HookC('vmkdir with %d arguments in %s'
                         % (len(args), fname))
        directory = _semantic(args[0], fname)
        return ['mkdir -p "$1$CHY_ROOT/%s"' % directory.strip('/')]

    if cmd == 'make':
        # make, with the variable map: ${makejobs} dropped (serial),
        # PREFIX=/usr -> PREFIX="$CHY_PREFIX", $DESTDIR -> "$1".
        out = []
        for w in args:
            if _is_makejobs(w):
                continue
            if w == 'PREFIX=/usr':
                out.append('PREFIX="$CHY_PREFIX"')
                continue
            out.append(_rewrite_word(w, ctx, where))
        return ['make' + (' ' + ' '.join(out) if out else '')]

    if cmd in _PASSTHROUGH:
        out = [_rewrite_word(w, ctx, where) for w in args]
        return [cmd + (' ' + ' '.join(out) if out else '')]

    raise _HookC('command %r is outside the idiom set (%s)' % (cmd, fname))


def _guard_kind(line):
    """CROSS_BUILD-guarded -> 'cross-build'; XBPS_CHECK_PKGS-guarded
    (check-only conditional, class B) -> 'check-only'; else None.
    The guard variable must be tested: a word-bounded $VAR/${VAR}
    reference in the condition part of the line.  A lookalike name
    (MY_CROSS_BUILD_FLAG) is no guard; its if stays class C."""
    if line.startswith('['):
        cond = line.split(']', 1)[0]
    else:
        cond = re.split(r';\s*then\b', line, maxsplit=1)[0]
    if re.search(r'\$\{?CROSS_BUILD\b', cond):
        return 'cross-build'
    if re.search(r'\$\{?XBPS_CHECK_PKGS\b', cond):
        return 'check-only'
    return None


def _classify_function(fname, body, ctx):
    """Translate one hook function -> list of emitted lines (class A
    remainder), recording B-drops in ctx.  Raises _HookC for class C."""
    lines = _logical_lines(body)
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        words, comp = _tokenize(line)
        first = _unquote(words[0]) if words else ''

        # guarded blocks and guard lines (the enumerated B exception)
        if first == 'if':
            kind = _guard_kind(line)
            if kind is None:
                raise _HookC('compound construct (if) in %s' % fname)
            # consume the whole block, wrapper included
            if re.search(r'(;\s*|\s)fi\s*$', line):
                i += 1 # single-line if ... fi
                ctx.dropped.add('%s block in %s' % (kind, fname))
                continue
            depth = 1
            j = i + 1
            while j < len(lines):
                w0 = lines[j].split(None, 1)[0] if lines[j].split() else ''
                if w0 == 'if':
                    depth += 1
                elif w0 in ('fi', 'fi;'):
                    depth -= 1
                    if depth == 0:
                        break
                elif w0 in ('else', 'elif') and depth == 1:
                    raise _HookC('%s-guarded block in %s has an else branch '
                                 '(native code would be dropped)'
                                 % (kind, fname))
                j += 1
            if depth != 0:
                raise _HookC('unterminated if block in %s' % fname)
            ctx.dropped.add('%s block in %s' % (kind, fname))
            i = j + 1
            continue

        if first.startswith('[') and _guard_kind(line):
            # `[ -z "$CROSS_BUILD" ] || ...` single-line guard: class B
            ctx.dropped.add('%s block in %s' % (_guard_kind(line), fname))
            i += 1
            continue

        # `;`-sequences: split into simple commands, reprocess
        if ';' in words:
            segs, seg = [], []
            for w in words:
                if w == ';':
                    if seg:
                        segs.append(seg)
                    seg = []
                else:
                    seg.append(w)
            if seg:
                segs.append(seg)
            lines[i:i + 1] = [' '.join(s) for s in segs]
            continue

        # everything else must be a top-level simple command
        if first in _KEYWORDS:
            raise _HookC('compound construct (%s) in %s' % (first, fname))
        if first in _ORPHAN_KW:
            raise _HookC('orphan shell keyword %r in %s' % (first, fname))
        if comp:
            raise _HookC('compound construct (%s) in %s'
                         % (', '.join(sorted(comp)), fname))
        if not words:
            i += 1
            continue
        if re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', first):
            raise _HookC('variable assignment in %s' % fname)
        out.extend(_xlate_simple(words, fname, ctx))
        i += 1
    return out


_PINNED_HOOK_DROPS = {
    'glib': {
        'post_patch': 'test-suite-only edits and a dead 32-bit guard',
        'post_install': 'introspection wrapper tooling (runtime-dark limit)',
    },
}


def _classify_hooks(functions, ctx):
    """All dump functions -> {(stage, slot): [lines]}.  *_package functions
    are Void's split machinery; chy merges packages, so they carry no
    build semantics here and get ignored.  Refusals name the hook."""
    hooks = {}
    for fname in sorted(functions):
        if fname.endswith('_package'):
            continue
        if fname in _PINNED_HOOK_DROPS.get(ctx.name, {}):
            ctx.dropped.add('hook %s (pinned: %s)'
                            % (fname, _PINNED_HOOK_DROPS[ctx.name][fname]))
            continue
        if fname in _CHECK_PHASES:
            ctx.dropped.add('check phase %s' % fname)
            continue
        if fname not in _PHASE_POS:
            raise Refuse('hook %s: no phase position in the hook map' % fname)
        try:
            lines = _classify_function(fname, functions[fname], ctx)
        except _HookC as e:
            raise Refuse('hook %s is class C: %s' % (fname, e))
        # recorded even when emptied by B-drops: a present-but-empty do_*
        # still REPLACES its style stage rather than falling back to it
        hooks.setdefault(_PHASE_POS[fname], []).extend(lines)
    return hooks


# section 7: path-argument rewriting for configure_args
# Exactly one --prefix, emitter-supplied.  --sysconfdir -> $CHY_ROOT/etc.
# --libdir dropped.  Any =/... absolute path: /usr, /etc, /var roots are
# rewritten under $CHY_ROOT; anything else refuses.  /run is also rewritten,
# a recorded deviation: enumerates only the three, but dbus's evaluated
# -Dsystem_socket=/run/... must translate per, and refusing would break
# the corpus chain (see report).

_REWRITE_ROOTS = ('/usr', '/etc', '/var', '/run')


def _rewrite_configure_args(tokens):
    out = []
    for tok in tokens:
        if not tok:
            continue
        if '"' in tok or "'" in tok:
            raise Refuse('configure argument %r contains quoting; cannot '
                         'be tokenized faithfully' % tok)
        if tok.startswith('--prefix=') or tok.startswith('-DCMAKE_INSTALL_PREFIX='):
            continue # stripped; the emitter supplies exactly one prefix
        if tok.startswith('--sysconfdir='):
            arg = '--sysconfdir="$CHY_ROOT/etc"'
            if arg not in out:
                out.append(arg)
            continue
        if tok.startswith('--libdir='):
            continue # dropped: chy's flags point at $CHY_PREFIX/lib
        if '=/' in tok:
            key, _, value = tok.partition('=')
            if not value.startswith('/'):
                raise Refuse('configure argument %r embeds an absolute path '
                             'the emitter cannot place' % tok)
            root = '/' + value.split('/', 2)[1]
            if root not in _REWRITE_ROOTS:
                raise Refuse('configure argument %r: absolute path outside '
                             '/usr, /etc, /var' % tok)
            out.append('%s="$CHY_ROOT%s"' % (key, value))
            continue
        out.append(tok)
    return out


# section 8: style emitters and build-script assembly

_STYLES = ('gnu-configure', 'configure', 'meson', 'gnu-makefile', 'cmake',
           'NONE')


def _emit_command(head, args):
    """The pinned shape: evaluated args one-per-line whenever there are two
    or more, four-space continuations; otherwise a single line."""
    if len(args) >= 2:
        lines = [' '.join(head) + ' \\']
        for k, arg in enumerate(args):
            cont = ' \\' if k < len(args) - 1 else ''
            lines.append('    %s%s' % (arg, cont))
        return lines
    return [' '.join(head + list(args))]


def _style_stages(style, dump, cfg_args):
    """-> (configure_lines, build_lines, install_lines) for the style."""
    if style == 'NONE':
        return [], [], []

    if style in ('gnu-configure', 'configure'):
        emitter = ['--prefix="$CHY_PREFIX"']
        if style == 'gnu-configure':
            emitter.append('--sysconfdir="$CHY_ROOT/etc"')
        args = emitter + [a for a in cfg_args if a not in emitter]
        return (_emit_command(['./configure'], args),
                ['make'],
                ['make DESTDIR="$1" install'])

    if style == 'meson':
        emitter = ['--prefix="$CHY_PREFIX"', '--sysconfdir="$CHY_ROOT/etc"',
                   '--libdir=lib', '--buildtype=release']
        args = emitter + [a for a in cfg_args if a not in emitter]
        return (_emit_command(['meson', 'setup', 'build'], args),
                ['ninja -C build'],
                ['DESTDIR="$1" ninja -C build install'])

    if style == 'cmake':
        emitter = ['-DCMAKE_INSTALL_PREFIX="$CHY_PREFIX"',
                   '-DCMAKE_BUILD_TYPE=Release']
        args = emitter + [a for a in cfg_args if a not in emitter]
        return (_emit_command(['cmake', '-G', 'Ninja', '-B', 'build'], args),
                ['ninja -C build'],
                ['DESTDIR="$1" ninja -C build install'])

    if style == 'gnu-makefile':
        ctx = _HookCtx() # reuse the make word map for evaluated make args
        def make_words(vals):
            out = []
            for w in vals:
                if _is_makejobs(w):
                    continue
                if w == 'PREFIX=/usr':
                    continue # the emitter supplies PREFIX
                try:
                    new = _rewrite_word(w, ctx, 'make_args')
                except _HookC as e:
                    raise Refuse('gnu-makefile argument: %s' % e)
                if new != 'DESTDIR="$1"': # emitter supplies DESTDIR too
                    out.append(new)
            return out
        build_args = make_words(dump['make_build_args'].split()
                                + dump['make_build_target'].split())
        inst_args = make_words(dump['make_install_args'].split()
                               + (dump['make_install_target'].split()
                                  or ['install']))
        if ctx.assets:
            raise Refuse('gnu-makefile arguments reference $FILESDIR')
        return ([],
                _emit_command(['make'], build_args),
                _emit_command(['make', 'PREFIX="$CHY_PREFIX"',
                               'DESTDIR="$1"'], inst_args))

    raise Refuse('build_style %r is outside the allowlist' % style)


_ENV_ALLOWED = ('CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS')


def _env_lines(env_vars_value):
    """template env_vars, append-form exports only, top of the script.
    Items arrive as NAME=value, one per (escaped) line."""
    lines = []
    seen = {}
    for item in env_vars_value.splitlines():
        if not item.strip():
            continue
        if '=' not in item:
            raise Refuse('env_vars item %r is not NAME=value' % item)
        vname, _, value = item.partition('=')
        if vname not in _ENV_ALLOWED:
            raise Refuse('template environment variable %r: only '
                         'CFLAGS/CXXFLAGS/CPPFLAGS/LDFLAGS translate'
                         % vname)
        seen[vname] = seen.get(vname, '') + (' ' if vname in seen else '') + value
    for vname in sorted(seen):
        value = seen[vname]
        esc = (value.replace('\\', '\\\\').replace('"', '\\"')
                    .replace('`', '\\`').replace('$', '\\$'))
        lines.append('export %s="${%s:+$%s }%s"' % (vname, vname, vname, esc))
    return lines


def _assemble_build(style, dump, cfg_args, hooks):
    """Order: env exports; post_patch; pre/CONFIGURE/post; pre/BUILD/post;
    pre/INSTALL/post.  do_* replace the style stage; on style NONE
    the translated do_* are the stages."""
    conf, build, inst = _style_stages(style, dump, cfg_args)
    stage = {
        'configure': hooks.get(('configure', 'do'), conf),
        'build': hooks.get(('build', 'do'), build),
        'install': hooks.get(('install', 'do'), inst),
    }
    if style == 'NONE' and not stage['install']:
        raise Refuse('style NONE without a translated do_install: the build '
                     'script would install nothing')
    lines = ['#!/bin/sh -e']
    lines += _env_lines(dump['env_vars'])
    lines += hooks.get(('patch', 'post'), [])
    for st in ('configure', 'build', 'install'):
        lines += hooks.get((st, 'pre'), [])
        lines += stage[st]
        lines += hooks.get((st, 'post'), [])
    return '\n'.join(lines) + '\n'


# section 9: pins
# Hermeticity pins: live-root autodetection the spike identified.  Keyed by
# package name; each entry appends configure args and meta `pinned:` lines.

_PINS = {
    'freetype': {'args': ['--with-harfbuzz=no'], 'meta': ['harfbuzz=off']},
}


# section 10: sources, checksums, files/ assets, patches

_ARCHIVE_SUFFIXES = ('.tar.gz', '.tgz', '.tar.xz', '.tar.bz2')
_VOID_RAW = 'https://raw.githubusercontent.com/void-linux/void-packages'
_SHA256_RE = re.compile(r'^[0-9a-f]{64}$')


def _sources_and_checksums(name, version, dump, assets, srcdir, commit):
    """-> (source lines, checksum lines).  Distfiles first, each with the
    sources.voidlinux.org mirror appended; then files/ assets referenced by
    surviving class-A lines, byte-sorted, raw URL at the pinned commit."""
    distfiles = dump['distfiles'].split()
    checksums = dump['checksum'].split()
    if not distfiles:
        raise Refuse('template evaluates to no distfiles')
    if len(distfiles) != len(checksums):
        raise Refuse('distfiles/checksum count mismatch (%d vs %d)'
                     % (len(distfiles), len(checksums)))
    src_lines = []
    sum_lines = []
    for url, digest in zip(distfiles, checksums):
        if '>' in url:
            raise Refuse('distfile %r uses Void\'s rename syntax; chy '
                         'sources cannot rename' % url)
        # basename from the un-stripped URL: a trailing '/' or a bare
        # host names no file
        upath = url.partition('://')[2]
        if '/' not in upath or upath.endswith('/'):
            raise Refuse('distfile %r has no basename' % url)
        fname = url.rsplit('/', 1)[-1]
        mirror = ('https://sources.voidlinux.org/%s-%s/%s'
                  % (name, version, fname))
        src_lines.append('%s %s' % (url, mirror))
        sum_lines.append(digest)
    for rel in sorted(assets):
        if srcdir is None:
            raise Refuse('hook references files/%s but the snapshot has no '
                         'srcpkgs/%s tree' % (rel, name))
        path = os.path.join(srcdir, 'files', rel)
        if os.path.isdir(path):
            raise Refuse('files/%s is a directory; not translatable as a '
                         'source' % rel)
        if not os.path.isfile(path):
            raise Refuse('hook references files/%s, absent from the fetched '
                         'tree' % rel)
        low = rel.lower()
        if any(low.endswith(s) for s in _ARCHIVE_SUFFIXES):
            raise Refuse('files/%s has a recognized-archive suffix; the build '
                         'would extract it' % rel)
        with open(path, 'rb') as f:
            digest = hashlib.sha256(f.read()).hexdigest()
        # no void mirror: sources.voidlinux.org hosts distfiles only
        src_lines.append('%s/%s/srcpkgs/%s/files/%s'
                         % (_VOID_RAW, commit, name, rel))
        sum_lines.append(digest)
    return src_lines, sum_lines


def _collect_patches(srcdir, name):
    """patches/ verbatim from the fetched tree.  chy applies *.patch and
    *.diff only; any other file there would be silently inert,
    so refuse instead."""
    out = {}
    if srcdir is None:
        return out
    pdir = os.path.join(srcdir, 'patches')
    if not os.path.isdir(pdir):
        return out
    for fname in sorted(os.listdir(pdir)):
        path = os.path.join(pdir, fname)
        if os.path.isdir(path):
            raise Refuse('patches/%s is a directory' % fname)
        if not (fname.endswith('.patch') or fname.endswith('.diff')):
            raise Refuse('patches/%s: chy applies only *.patch and *.diff; '
                         'this file would be silently skipped' % fname)
        with open(path, 'rb') as f:
            out['patches/' + fname] = f.read()
    return out


# section 11: the meta ledger
# origin/template/void-commit/pkgver/style, then dropped:, pinned:,
# expect-needed:, each group sorted.  Never a translator version here.

def _build_meta(name, entry, style, dropped, pinned):
    commit = entry['source-revisions'].partition(':')[2]
    lines = [
        'origin: translated',
        'template: srcpkgs/%s/template' % name,
        'void-commit: %s' % commit,
        'pkgver: %s' % entry['pkgver'],
        'style: %s' % style,
    ]
    lines += ['dropped: %s' % d for d in sorted(dropped)]
    lines += ['pinned: %s' % p for p in sorted(pinned)]
    # expect-needed: repodata shlib-requires verbatim, byte-sorted (the
    # determinism rule); checks NEEDED drift against these.
    for soname in sorted(entry.get('shlib-requires') or []):
        lines.append('expect-needed: %s' % soname)
    return '\n'.join(lines) + '\n'


# section 12: self-validation against chy
# chytrans validates its own output before writing; a bug in our emission
# refuses the package just like a bad template, and writes nothing.

_NAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9+._-]*$') # uppercase is legal
_VERSION_RE = re.compile(r'^[A-Za-z0-9._+]+$')


def _self_validate(name, files, style):
    def refuse(msg):
        raise Refuse('self-validation: ' + msg)

    if not _NAME_RE.match(name) or name in ('install', 'order'):
        refuse('illegal package name %r' % name)
    version_line = files['version'].decode().strip()
    parts = version_line.split(' ')
    if len(parts) != 2 or not all(_VERSION_RE.match(p) for p in parts):
        refuse('illegal version line %r' % version_line)

    def significant(data):
        return [l for l in data.decode().splitlines()
                if l.strip() and not l.lstrip().startswith('#')]

    sources = significant(files['sources'])
    checksums = significant(files['checksums'])
    if not sources:
        refuse('no sources')
    if len(sources) != len(checksums):
        refuse('sources/checksums line-count mismatch')
    basenames = set()
    for line in sources:
        first = line.split()[0]
        base = first.rstrip('/').rsplit('/', 1)[-1]
        if base in basenames:
            refuse('source basename collision on %r' % base)
        basenames.add(base)
    for digest in checksums:
        if not _SHA256_RE.match(digest.strip()):
            refuse('checksum %r is not lowercase sha256 hex'
                   % digest)

    build = files['build'].decode()
    if not build.strip():
        refuse('empty build script')
    # golden assertion: no literal /usr-rooted path argument survives.
    # Single-quoted spans are exempt (shell path semantics suppressed).
    for bline in build.splitlines():
        spans = _squoted_spans(bline)
        for m in re.finditer(r'/usr(?=[/\s"\':=]|$)', bline):
            if any(a <= m.start() < b for a, b in spans):
                continue
            before = bline[:m.start()]
            if before.endswith('"'):
                before = before[:-1]
            if not (before.endswith('$CHY_ROOT') or before.endswith('$CHY_PREFIX')
                    or before.endswith('{CHY_ROOT}')
                    or before.endswith('{CHY_PREFIX}')):
                refuse('literal /usr-rooted path survives in the build script')
    # exactly one emitter-supplied prefix on configure-carrying styles
    if style in ('gnu-configure', 'configure', 'meson'):
        n = build.count('--prefix=')
        if n != 1 or build.count('--prefix="$CHY_PREFIX"') != 1:
            refuse('expected exactly one emitter-supplied --prefix, found %d'
                   % n)
    elif style == 'cmake':
        if build.count('-DCMAKE_INSTALL_PREFIX="$CHY_PREFIX"') != 1:
            refuse('expected exactly one emitter-supplied install prefix')
    for path in files:
        if path.startswith('patches/'):
            base = path.split('/', 1)[1]
            if '/' in base:
                refuse('nested path under patches/')


# section 13: translate() and write(), the public entry points

def translate(name, snap, dumpdir):
    """Translate one package.  Never raises for per-package problems;
    those come back as Result(ok=False, reason=...) for chytrans' report."""
    result = Result(name)
    try:
        _translate_into(result, name, snap, dumpdir)
        result.ok = True
    except Refuse as e:
        result.ok = False
        result.reason = str(e)
        result.files = {}
    return result


def _translate_into(result, name, snap, dumpdir):
    entry = snap.slice.get(name)
    if entry is None:
        raise Refuse('package not in the snapshot repodata slice')
    pkgver = entry.get('pkgver', '')
    m = re.match(r'^(.+)-([A-Za-z0-9._+]+)_([0-9]+)$', pkgver)
    if not m or m.group(1) != name:
        raise Refuse('repodata pkgver %r does not parse for %s'
                     % (pkgver, name))
    version, revision = m.group(2), m.group(3)
    if ':' not in entry.get('source-revisions', ''):
        raise Refuse('repodata entry has no source-revisions commit pin')

    dump, functions = _read_dump(dumpdir, name)
    if dump['pkgname'] != name:
        raise Refuse('dump pkgname %r does not match %r'
                     % (dump['pkgname'], name))
    if dump['version'] != version or (dump['revision'] or '1') != revision:
        raise Refuse('template %s-%s_%s disagrees with repodata %s: '
                     'incoherent snapshot'
                     % (name, dump['version'], dump['revision'], pkgver))

    style = dump['build_style'] or 'NONE'
    if style not in _STYLES:
        raise Refuse('build_style %r is outside the allowlist' % style)

    # helpers
    dropped = set()
    injected = []
    for helper in dump['build_helper'].split():
        if helper == 'gir':
            injected.append('gobject-introspection')
        elif helper == 'qemu':
            dropped.add('build_helper qemu')
        else:
            raise Refuse('build_helper %r is not translatable' % helper)

    # hooks
    ctx = _HookCtx(name)
    hooks = _classify_hooks(functions, ctx)
    dropped |= ctx.dropped

    # configure args and the build script.  style NONE has no
    # configure stage, so its configure_args are dead (a do_configure
    # referencing them would be class C).
    cfg_args = ([] if style == 'NONE' else
                _rewrite_configure_args(dump['configure_args'].split()))
    for pin_arg in _PINS.get(name, {}).get('args', []):
        if pin_arg not in cfg_args:
            cfg_args.append(pin_arg)
    pinned = list(_PINS.get(name, {}).get('meta', []))
    build_script = _assemble_build(style, dump, cfg_args, hooks)

    # style tool injection
    if style == 'meson':
        injected += ['meson', 'ninja', 'pkg-config']
    elif style == 'cmake':
        injected += ['cmake', 'ninja']
    elif style in ('gnu-configure', 'configure', 'gnu-makefile'):
        haystack = ' '.join(cfg_args) + '\n' + '\n'.join(
            l for lines in hooks.values() for l in lines)
        if 'pkg-config' in haystack:
            injected.append('pkg-config')

    # packaging metadata with no chy concept
    if dump['conf_files']:
        dropped.add('conf_files')
    if dump['system_accounts']:
        dropped.add('system_accounts')

    # dependencies
    depends = _translate_deps((entry.get('run_depends') or []),
                              snap.slice, name, 'run_depends')
    makedepends = _translate_deps(
        dump['hostmakedepends'].split() + dump['makedepends'].split()
        + injected, snap.slice, name, 'makedepends')
    conflicts = _translate_deps(dump['conflicts'].split(),
                                snap.slice, name, 'conflicts')

    # sources, checksums, patches
    srcdir = snap.srcpkg_dir(name)
    commit = entry['source-revisions'].partition(':')[2]
    src_lines, sum_lines = _sources_and_checksums(
        name, version, dump, ctx.assets, srcdir, commit)
    patches = _collect_patches(srcdir, name)

    # assemble the recipe
    files = {
        'version': ('%s %s\n' % (version, revision)).encode(),
        'sources': ('\n'.join(src_lines) + '\n').encode(),
        'checksums': ('\n'.join(sum_lines) + '\n').encode(),
        'build': build_script.encode(),
    }
    if depends:
        files['depends'] = ('\n'.join(depends) + '\n').encode()
    if makedepends:
        files['makedepends'] = ('\n'.join(makedepends) + '\n').encode()
    if conflicts:
        files['conflicts'] = ('\n'.join(conflicts) + '\n').encode()
    files['meta'] = _build_meta(name, entry, style, dropped, pinned).encode()
    files.update(patches)

    _self_validate(name, files, style)

    result.depends = depends
    result.makedepends = makedepends
    result.files = files


def write(result, outroot):
    """Write one translated recipe under <outroot>/recipes/<name>/.

    Refuses to touch a handwritten recipe (short-circuit is
    chytrans' job; this is defense in depth).  Replaces any previous
    translated output wholesale so re-runs are byte-identical."""
    if not result.ok:
        raise ValueError('write() called for refused package %s: %s'
                         % (result.name, result.reason))
    rdir = os.path.join(outroot, 'recipes', result.name)
    meta = os.path.join(rdir, 'meta')
    if os.path.isfile(meta):
        with open(meta, encoding='utf-8') as f:
            if any(l.strip() == 'origin: handwritten' for l in f):
                raise RuntimeError('refusing to overwrite handwritten '
                                   'recipe %s' % result.name)
    if os.path.isdir(rdir):
        shutil.rmtree(rdir)
    for rel in sorted(result.files):
        path = os.path.join(rdir, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as f:
            f.write(result.files[rel])
        os.chmod(path, 0o644) # umask-independent: modes are output too
    os.chmod(os.path.join(rdir, 'build'), 0o755)
