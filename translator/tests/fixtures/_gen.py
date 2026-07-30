#!/usr/bin/env python3
"""Regenerate every fixture under translator/tests/fixtures/.

    python3 translator/tests/fixtures/_gen.py

Deterministic: same bytes on every run. Each case_* function builds one
fixture directory (snapshot/ + names + checks [+ expect/ + pre/ +
overlay/]) whose expected outputs are written by hand. The runner (translator/tests/run)
does not import this file; the generated trees are committed and are the
tests.

The generator ends with a verification pass over what it wrote (plist
round-trips, checks-file lint, sorted expectations actually sorted,
sources/checksums pairing), so fixture bugs fail here.
"""

import hashlib
import os
import plistlib
import re
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
COMMIT = "1234567890abcdef1234567890abcdef12345678"
REPODATA_URL = "https://repo-default.voidlinux.org/current/x86_64-repodata"
SHLIBS_URL = ("https://raw.githubusercontent.com/void-linux/void-packages/"
              "master/common/shlibs")

DEFAULT_SHLIBS = (
    "# common/shlibs (synthetic) - <soname> <pkgname-version_revision>\n"
    "libz.so.1 zlib-1.3.1_1\n"
)

# pinned shape: gnu-configure with no template args.
GNU_MIN_BUILD = (
    '#!/bin/sh -e\n'
    './configure \\\n'
    '    --prefix="$CHY_PREFIX" \\\n'
    '    --sysconfdir="$CHY_ROOT/etc"\n'
    'make\n'
    'make DESTDIR="$1" install\n'
)


def raw_url(pkg, rel):
    return ("https://raw.githubusercontent.com/void-linux/void-packages/"
            "%s/srcpkgs/%s/%s" % (COMMIT, pkg, rel))


def fake_sha(token):
    """Stable, well-formed digest for distfiles that are never fetched
    (recipes are emitted, not built, by this suite)."""
    return hashlib.sha256(("chytrans-fixture:" + token).encode()).hexdigest()


def E(name, ver="1.0_1", src=None, run=None, provides=None, requires=None,
      vprovides=None):
    """One repodata slice entry, shaped like Void's index entries:
    pkgver, source-revisions ("<srcpkg>:<commit>"), optional run_depends /
    shlib-provides / shlib-requires / provides (virtual packages;
    omitted when empty, as xbps does)."""
    d = {
        "architecture": "x86_64",
        "pkgver": "%s-%s" % (name, ver),
        "source-revisions": "%s:%s" % (src or name, COMMIT),
    }
    if run:
        d["run_depends"] = list(run)
    if provides:
        d["shlib-provides"] = list(provides)
    if requires:
        d["shlib-requires"] = list(requires)
    if vprovides:
        d["provides"] = list(vprovides)
    return name, d


def tmpl(name, ver="1.0", style="gnu-configure", lines=(), funcs="",
         distfiles=None, checksum=None):
    """A tiny Void-shaped template. style=None omits build_style (NONE)."""
    if distfiles is None:
        distfiles = "https://example.org/dist/%s-${version}.tar.gz" % name
    if checksum is None:
        checksum = fake_sha("%s-%s.tar.gz" % (name, ver))
    out = [
        "# Template file for '%s'" % name,
        "pkgname=%s" % name,
        "version=%s" % ver,
        "revision=1",
    ]
    if style is not None:
        out.append("build_style=%s" % style)
    out.extend(lines)
    out += [
        'short_desc="Synthetic chytrans fixture"',
        'maintainer="chytrans tests <noreply@example.org>"',
        'license="MIT"',
        'homepage="https://example.org/%s"' % name,
        'distfiles="%s"' % distfiles,
        "checksum=%s" % checksum,
    ]
    text = "\n".join(out) + "\n"
    if funcs:
        text += "\n" + funcs
    return text


class Case:
    def __init__(self, name):
        self.name = name
        self.root = os.path.join(HERE, name)
        if os.path.isdir(self.root):
            shutil.rmtree(self.root)
        os.makedirs(self.root)
        self.manifest = []
        self._have_shlibs = False

    def write(self, rel, data):
        if isinstance(data, str):
            data = data.encode("utf-8")
        p = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)
        return data

    def snap(self, rel, data, url):
        data = self.write(os.path.join("snapshot", rel), data)
        self.manifest.append((url, hashlib.sha256(data).hexdigest()))

    def slice(self, *pairs):
        idx = {}
        for name, entry in pairs:
            if name in idx:
                raise SystemExit("%s: duplicate slice entry %s" % (self.name, name))
            idx[name] = entry
        self.snap("repodata.slice.plist",
                  plistlib.dumps(idx, fmt=plistlib.FMT_XML), REPODATA_URL)

    def template(self, pkg, text):
        self.snap("srcpkgs/%s/template" % pkg, text, raw_url(pkg, "template"))

    def files_asset(self, pkg, rel, text):
        self.snap("srcpkgs/%s/files/%s" % (pkg, rel), text,
                  raw_url(pkg, "files/" + rel))

    def shlibs(self, text):
        self._have_shlibs = True
        self.snap("common-shlibs", text, SHLIBS_URL)

    def names(self, *ns):
        self.write("names", "".join(n + "\n" for n in ns))

    def checks(self, text):
        self.write("checks", text)

    def expect(self, rel, text):
        self.write(os.path.join("expect", rel), text)

    def pre(self, rel, text):
        self.write(os.path.join("pre", rel), text)

    def overlay(self, pkg, rel, text):
        # an overlay recipe directory; its presence switches the
        # runner to the overlay-check surface.
        self.write(os.path.join("overlay", pkg, rel), text)

    def finish(self):
        if not self._have_shlibs:
            self.shlibs(DEFAULT_SHLIBS)
        rows = sorted("%s %s %s" % (url, COMMIT, sha) for url, sha in self.manifest)
        self.write("snapshot/MANIFEST", "".join(r + "\n" for r in rows))


def handwritten(c, name, ver_line):
    """A frozen origin:handwritten recipe, seeded into the output root
    (pre/) and asserted byte-identical after the run (expect/)."""
    files = {
        "meta": "origin: handwritten\nnote: frozen fixture recipe\n",
        "version": ver_line + "\n",
        "sources": "https://example.org/dist/%s.tar.gz\n" % name,
        "checksums": fake_sha(name + ".tar.gz") + "\n",
        "build": ("# handwritten fixture build - these bytes must survive "
                  "translator runs\nexit 1\n"),
    }
    for rel, text in files.items():
        c.pre("recipes/%s/%s" % (name, rel), text)
        c.expect("recipes/%s/%s" % (name, rel), text)


# dependency cases

def case_01():
    # parsing, flattening, libc drop, self drop, dup drop, constraint
    # stripping, sorting; plus conflicts and template-depends being
    # ignored in favor of repodata run_depends ('ignoredep' is not in
    # the slice, so consulting template depends would refuse).
    c = Case("01-parse-flatten")
    c.names("app")
    c.template("app", tmpl("app", lines=[
        'hostmakedepends="hosttool"',
        'makedepends="libbuild-devel"',
        'depends="ignoredep"',
        'conflicts="oldapp>=1_1"',
    ]))
    c.slice(
        E("app", run=[
            "alpha>=1.2_1", "beta<2", "gamma>=0",
            "lib-name-1.5.7_1", "at-spi2-core-2.56.5_1", "zeta",
            "glibc>=2.42_1",
            "app-libs-1.0_1",
            "libgtk-sub-3.24.52_1",
            "gtk-parent>=3.24.52_1",
        ]),
        E("app-libs", src="app"),
        E("alpha", ver="1.2_1"),
        E("beta"),
        E("gamma"),
        E("lib-name", ver="1.5.7_1"),
        E("at-spi2-core", ver="2.56.5_1"),
        E("zeta"),
        E("glibc", ver="2.42_1"),
        E("libgtk-sub", ver="3.24.52_1", src="gtk-parent"),
        E("gtk-parent", ver="3.24.52_1"),
        E("oldapp"),
        E("hosttool"),
        E("libbuild-devel", src="libbuild"),
        E("libbuild"),
    )
    c.expect("recipes/app/version", "1.0 1\n")
    c.expect("recipes/app/depends",
             "alpha\nat-spi2-core\nbeta\ngamma\ngtk-parent\nlib-name\nzeta\n")
    c.expect("recipes/app/makedepends", "hosttool\nlibbuild\n")
    c.expect("recipes/app/conflicts", "oldapp\n")
    c.checks(
        "exit :: 0\n"
        "file-line :: report :: translated: app\n"
        "file-line :: recipes/app/meta :: origin: translated\n"
    )
    c.finish()


def case_02():
    # a virtual? dependency nothing in the slice provides is a
    # refusal (36/38 cover the resolvable flavors).
    c = Case("02-refuse-virtual")
    c.names("vapp")
    c.template("vapp", tmpl("vapp"))
    c.slice(E("vapp", run=["virtual?awk>=0"]))
    c.checks(
        "exit :: 1\n"
        "stderr-refusal :: vapp :: virtual\n"
        "file-matches :: report :: ^refused: vapp:\n"
        "absent :: recipes/vapp\n"
    )
    c.finish()


def case_03():
    # a flatten lookup that misses the slice is a per-package
    # refusal naming the dependency.
    c = Case("03-refuse-flatten-miss")
    c.names("mapp")
    c.template("mapp", tmpl("mapp"))
    c.slice(E("mapp", run=["ghostlib>=1_1"]))
    c.checks(
        "exit :: 1\n"
        "stderr-refusal :: mapp :: ghostlib\n"
        "file-matches :: report :: ^refused: mapp:.*ghostlib\n"
        "absent :: recipes/mapp\n"
    )
    c.finish()


# rewrite cases

def case_04():
    # gnu-configure minimal shape, byte-exact; mirror fallback and
    # meta ledger lines.
    c = Case("04-shape-gnu-configure")
    c.names("shapea")
    c.template("shapea", tmpl("shapea"))
    c.slice(E("shapea"))
    c.expect("recipes/shapea/build", GNU_MIN_BUILD)
    c.expect("recipes/shapea/version", "1.0 1\n")
    c.expect("recipes/shapea/sources",
             "https://example.org/dist/shapea-1.0.tar.gz"
             " https://sources.voidlinux.org/shapea-1.0/shapea-1.0.tar.gz\n")
    c.expect("recipes/shapea/checksums", fake_sha("shapea-1.0.tar.gz") + "\n")
    c.checks(
        "exit :: 0\n"
        "file-line :: recipes/shapea/meta :: origin: translated\n"
        "file-line :: recipes/shapea/meta :: style: gnu-configure\n"
        "file-line :: recipes/shapea/meta :: pkgver: shapea-1.0_1\n"
        "file-line :: recipes/shapea/meta :: void-commit: %s\n" % COMMIT +
        "file-matches :: recipes/shapea/meta :: ^template: .*shapea\n"
        "file-line :: report :: translated: shapea\n"
    )
    c.finish()


def case_05():
    # plain configure is not gnu-configure: no --sysconfdir, only the
    # emitter's --prefix plus rewritten template args. Byte-exact.
    c = Case("05-shape-configure")
    c.names("zconf")
    c.template("zconf", tmpl("zconf", style="configure", lines=[
        'configure_args="--prefix=/usr --shared"',
    ]))
    c.slice(E("zconf"))
    c.expect("recipes/zconf/build",
             '#!/bin/sh -e\n'
             './configure \\\n'
             '    --prefix="$CHY_PREFIX" \\\n'
             '    --shared\n'
             'make\n'
             'make DESTDIR="$1" install\n')
    c.checks(
        "exit :: 0\n"
        "file-line :: recipes/zconf/meta :: style: configure\n"
        "file-not-has :: recipes/zconf/build :: --sysconfdir\n"
        "file-count :: recipes/zconf/build :: --prefix :: 1\n"
    )
    c.finish()


def case_06():
    # path-argument rewriting: --prefix consumed (exactly one,
    # emitter-supplied), --sysconfdir and /var paths rooted under
    # "$CHY_ROOT", --libdir dropped, and no bare /usr, /etc or /var path
    # argument survives.
    c = Case("06-rewrite-paths")
    c.names("rewr")
    c.template("rewr", tmpl("rewr", style="configure", lines=[
        'configure_args="--prefix=/usr --sysconfdir=/etc --libdir=/usr/lib'
        ' --with-cache-dir=/var/x --localstatedir=/var/lib/rewr"',
    ]))
    c.slice(E("rewr"))
    c.checks(
        "exit :: 0\n"
        'file-has :: recipes/rewr/build :: --sysconfdir="$CHY_ROOT/etc"\n'
        'file-has :: recipes/rewr/build :: --with-cache-dir="$CHY_ROOT/var/x"\n'
        'file-has :: recipes/rewr/build :: --localstatedir="$CHY_ROOT/var/lib/rewr"\n'
        'file-has :: recipes/rewr/build :: --prefix="$CHY_PREFIX"\n'
        "file-count :: recipes/rewr/build :: --prefix :: 1\n"
        "file-not-has :: recipes/rewr/build :: --libdir\n"
        "file-not-has :: recipes/rewr/build :: =/usr\n"
        "file-not-has :: recipes/rewr/build :: =/etc\n"
        "file-not-has :: recipes/rewr/build :: =/var\n"
    )
    c.finish()


def case_07():
    # an absolute path argument outside /usr, /etc, /var is a refusal.
    c = Case("07-refuse-opt-path")
    c.names("optp")
    c.template("optp", tmpl("optp", style="configure", lines=[
        'configure_args="--with-foo=/opt/x"',
    ]))
    c.slice(E("optp"))
    c.checks(
        "exit :: 1\n"
        "stderr-refusal :: optp :: /opt/x\n"
        "absent :: recipes/optp\n"
    )
    c.finish()


def case_08():
    # meson shape (--libdir=lib, buildtype, DESTDIR install line) and
    # style tool injection: meson ninja pkg-config land in makedepends.
    c = Case("08-shape-meson")
    c.names("mez")
    c.template("mez", tmpl("mez", style="meson", lines=[
        'configure_args="-Dfoo=enabled -Dbar=disabled"',
    ]))
    c.slice(E("mez"), E("meson"), E("ninja"), E("pkg-config"))
    c.expect("recipes/mez/makedepends", "meson\nninja\npkg-config\n")
    c.checks(
        "exit :: 0\n"
        "file-has :: recipes/mez/build :: meson setup build\n"
        'file-has :: recipes/mez/build :: --prefix="$CHY_PREFIX"\n'
        'file-has :: recipes/mez/build :: --sysconfdir="$CHY_ROOT/etc"\n'
        "file-has :: recipes/mez/build :: --libdir=lib\n"
        "file-has :: recipes/mez/build :: --buildtype=release\n"
        "file-has :: recipes/mez/build :: -Dfoo=enabled\n"
        "file-line :: recipes/mez/build :: ninja -C build\n"
        'file-line :: recipes/mez/build :: DESTDIR="$1" ninja -C build install\n'
        "file-after :: recipes/mez/build :: meson setup build :: ninja -C build\n"
        "file-line :: recipes/mez/meta :: style: meson\n"
    )
    c.finish()


def case_09():
    # template env vars: append form only, at the top of the script,
    # so chy's exported rpath LDFLAGS survive (pixman-shaped).
    c = Case("09-env-append")
    c.names("pixm")
    c.template("pixm", tmpl("pixm", lines=['LDFLAGS="-Wl,-z,relro"']))
    c.slice(E("pixm"))
    c.checks(
        "exit :: 0\n"
        "file-first-line :: recipes/pixm/build :: #!/bin/sh -e\n"
        'file-line-n :: recipes/pixm/build :: 2 :: '
        'export LDFLAGS="${LDFLAGS:+$LDFLAGS }-Wl,-z,relro"\n'
        "file-has :: recipes/pixm/build :: ./configure\n"
    )
    c.finish()


def case_10():
    # only CFLAGS/CXXFLAGS/CPPFLAGS/LDFLAGS are capturable; any
    # other template-level variable is an inert template-local and must
    # never leak into the emitted build script.
    c = Case("10-refuse-env-var")
    c.names("envx")
    c.template("envx", tmpl("envx", lines=["FOO=bar"]))
    c.slice(E("envx"))
    c.checks(
        "# amended: only the four env vars are capturable; a template-local\n"
        "# FOO=bar is inert and must never leak into the emitted build script\n"
        "exit :: 0\n"
        "exists :: recipes/envx/build\n"
        "file-not-has :: recipes/envx/build :: FOO\n"
    )
    c.finish()


# hook cases

def case_11():
    # build_helper gir -> gobject-introspection injected into
    # makedepends (alongside meson tool injection), sorted.
    c = Case("11-helper-gir")
    c.names("girp")
    c.template("girp", tmpl("girp", style="meson", lines=['build_helper="gir"']))
    c.slice(E("girp"), E("gobject-introspection"), E("meson"), E("ninja"),
            E("pkg-config"))
    c.expect("recipes/girp/makedepends",
             "gobject-introspection\nmeson\nninja\npkg-config\n")
    c.checks(
        "exit :: 0\n"
        "file-line :: report :: translated: girp\n"
    )
    c.finish()


def case_12():
    # build_helper qemu -> documented drop, recorded as a dropped: meta
    # line; translation still succeeds.
    c = Case("12-helper-qemu")
    c.names("qem")
    c.template("qem", tmpl("qem", lines=['build_helper="qemu"']))
    c.slice(E("qem"))
    c.checks(
        "exit :: 0\n"
        "exists :: recipes/qem/build\n"
        "file-matches :: recipes/qem/meta :: ^dropped: .*qemu\n"
    )
    c.finish()


def case_13():
    # any helper other than gir/qemu is a refusal naming it.
    c = Case("13-refuse-helper")
    c.names("helx")
    c.template("helx", tmpl("helx", lines=['build_helper="rust"']))
    c.slice(E("helx"))
    c.checks(
        "exit :: 1\n"
        "stderr-refusal :: helx :: rust\n"
        "absent :: recipes/helx\n"
    )
    c.finish()


def case_14():
    # class A: a post_install of simple idiom commands is rewritten at
    # its phase position (after install), in body order: vsed -> sed -i,
    # vinstall -> install -Dm..., rm kept, $DESTDIR/usr/... -> "$1$CHY_ROOT/usr/...".
    c = Case("14-hook-translated")
    c.names("hooka")
    c.template("hooka", tmpl("hooka", funcs=(
        "post_install() {\n"
        "\tvsed -e 's/old/new/' README.md\n"
        "\tvinstall app.conf 644 usr/share/hooka\n"
        "\trm -f $DESTDIR/usr/lib/libhooka.la\n"
        "}\n"
    )))
    c.slice(E("hooka"))
    c.checks(
        "exit :: 0\n"
        "file-line :: recipes/hooka/build :: sed -i -e 's/old/new/' README.md\n"
        "file-matches :: recipes/hooka/build :: ^install -Dm644 .*app\\.conf\n"
        'file-has :: recipes/hooka/build :: "$1$CHY_ROOT/usr/share/hooka\n'
        'file-line :: recipes/hooka/build :: rm -f "$1$CHY_ROOT/usr/lib/libhooka.la"\n'
        'file-after :: recipes/hooka/build :: make DESTDIR="$1" install'
        " :: sed -i -e 's/old/new/' README.md\n"
        "file-after :: recipes/hooka/build :: sed -i -e 's/old/new/' README.md"
        " :: install -Dm644\n"
        "file-after :: recipes/hooka/build :: install -Dm644"
        ' :: rm -f "$1$CHY_ROOT/usr/lib/libhooka.la"\n'
        "file-not-has :: recipes/hooka/build :: vsed\n"
        "file-not-has :: recipes/hooka/build :: vinstall\n"
        "file-not-has :: recipes/hooka/build :: $DESTDIR\n"
        "file-count :: recipes/hooka/sources :: :// :: 1\n"
    )
    c.finish()


def case_15():
    # class B: a vlicense-only post_install drops whole, leaves a
    # dropped: meta line and no trace in the build script, which stays
    # byte-identical to the minimal gnu-configure shape.
    c = Case("15-hook-dropped-vlicense")
    c.names("hookb")
    c.template("hookb", tmpl("hookb", funcs=(
        "post_install() {\n"
        "\tvlicense COPYING\n"
        "}\n"
    )))
    c.slice(E("hookb"))
    c.expect("recipes/hookb/build", GNU_MIN_BUILD)
    c.checks(
        "exit :: 0\n"
        "file-matches :: recipes/hookb/meta :: ^dropped: .*vlicense\n"
        "file-not-has :: recipes/hookb/build :: vlicense\n"
        "file-not-has :: recipes/hookb/build :: COPYING\n"
    )
    c.finish()


def case_16():
    # class C: a compound construct (a non-CROSS_BUILD if) refuses the
    # whole function, naming it.
    c = Case("16-refuse-hook-compound")
    c.names("hookc")
    c.template("hookc", tmpl("hookc", funcs=(
        "post_install() {\n"
        "\tif [ -e README.md ]; then\n"
        "\t\trm -f README.md\n"
        "\tfi\n"
        "}\n"
    )))
    c.slice(E("hookc"))
    c.checks(
        "exit :: 1\n"
        "stderr-refusal :: hookc :: post_install\n"
        "absent :: recipes/hookc\n"
    )
    c.finish()


def case_17():
    # the one enumerated compound exception. A CROSS_BUILD-guarded
    # block is class B (wrapper included); the remaining simple command
    # still translates (partly-B function).
    c = Case("17-hook-cross-guard")
    c.names("hookx")
    c.template("hookx", tmpl("hookx", funcs=(
        "post_install() {\n"
        "\tvsed -e 's/aa/bb/' data.txt\n"
        '\tif [ "$CROSS_BUILD" ]; then\n'
        "\t\techo cross-only\n"
        "\tfi\n"
        "}\n"
    )))
    c.slice(E("hookx"))
    c.checks(
        "exit :: 0\n"
        "file-line :: recipes/hookx/build :: sed -i -e 's/aa/bb/' data.txt\n"
        "file-not-has :: recipes/hookx/build :: CROSS_BUILD\n"
        "file-not-has :: recipes/hookx/build :: echo cross-only\n"
        "file-matches :: recipes/hookx/meta :: (?i)^dropped: .*cross\n"
        'file-after :: recipes/hookx/build :: make DESTDIR="$1" install'
        " :: sed -i -e 's/aa/bb/' data.txt\n"
    )
    c.finish()


def case_18():
    # a surviving class-A hook line referencing $FILESDIR/<asset>
    # pulls the files/ asset in as a final sources line (raw URL at the
    # pinned commit, no void mirror, real sha256) and uses its basename.
    c = Case("18-hook-filesdir-asset")
    asset = "# synthetic asset for hookf\nkey = value\n"
    asset_sha = hashlib.sha256(asset.encode()).hexdigest()
    c.names("hookf")
    c.template("hookf", tmpl("hookf", funcs=(
        "post_install() {\n"
        "\tvinstall $FILESDIR/asset.conf 644 usr/share/hookf\n"
        "}\n"
    )))
    c.files_asset("hookf", "asset.conf", asset)
    c.slice(E("hookf"))
    c.checks(
        "exit :: 0\n"
        "file-count :: recipes/hookf/sources :: :// :: 2\n"
        "file-matches-n :: recipes/hookf/sources :: 1 :: "
        r"^https://example\.org/dist/hookf-1\.0\.tar\.gz"
        r" https://sources\.voidlinux\.org/hookf-1\.0/hookf-1\.0\.tar\.gz$" "\n"
        "file-matches-n :: recipes/hookf/sources :: 2 :: "
        r"^https://raw\.githubusercontent\.com/.*" + COMMIT +
        r"/srcpkgs/hookf/files/asset\.conf$" "\n"
        "file-line-n :: recipes/hookf/checksums :: 1 :: "
        + fake_sha("hookf-1.0.tar.gz") + "\n"
        "file-line-n :: recipes/hookf/checksums :: 2 :: " + asset_sha + "\n"
        "file-matches :: recipes/hookf/build :: "
        r"^install -Dm644 asset\.conf\s" "\n"
        "file-not-has :: recipes/hookf/build :: FILESDIR\n"
    )
    c.finish()


def case_19():
    # on style NONE (zstd-shaped): do_build/do_install of make idioms
    # ARE the build script: ${makejobs} dropped, PREFIX=/usr ->
    # PREFIX="$CHY_PREFIX", $DESTDIR -> "$1". Whole file byte-exact.
    c = Case("19-style-none-make")
    c.names("zst")
    c.template("zst", tmpl("zst", style=None, funcs=(
        "do_build() {\n"
        "\tmake ${makejobs} PREFIX=/usr\n"
        "}\n"
        "\n"
        "do_install() {\n"
        "\tmake PREFIX=/usr DESTDIR=$DESTDIR install\n"
        "}\n"
    )))
    c.slice(E("zst"))
    c.expect("recipes/zst/build",
             '#!/bin/sh -e\n'
             'make PREFIX="$CHY_PREFIX"\n'
             'make PREFIX="$CHY_PREFIX" DESTDIR="$1" install\n')
    c.checks(
        "exit :: 0\n"
        "file-line :: recipes/zst/meta :: style: NONE\n"
        "file-not-has :: recipes/zst/build :: makejobs\n"
    )
    c.finish()


def case_20():
    # style NONE is legal only when its do_* overrides translate;
    # an untranslatable do_install refuses.
    c = Case("20-refuse-none-untranslatable")
    c.names("nonu")
    c.template("nonu", tmpl("nonu", style=None, funcs=(
        "do_install() {\n"
        "\t./installer.sh --go\n"
        "}\n"
    )))
    c.slice(E("nonu"))
    c.checks(
        "exit :: 1\n"
        "stderr-refusal :: nonu :: do_install\n"
        "absent :: recipes/nonu\n"
    )
    c.finish()


# output cases

def case_21():
    # handwritten exception: a pre-seeded recipes/hw1 with
    # origin: handwritten short-circuits (exit 0, 'exception: hw1' in the
    # report, directory byte-identical, pre/ == expect/), while a normal
    # requested package still translates around it.
    c = Case("21-exception-handwritten")
    c.names("hw1", "app")
    handwritten(c, "hw1", "9.9 9")
    c.template("hw1", tmpl("hw1", ver="9.9"))
    c.template("app", tmpl("app"))
    c.slice(E("hw1", ver="9.9_9"), E("app"))
    c.expect("recipes/app/version", "1.0 1\n")
    c.checks(
        "exit :: 0\n"
        "file-line :: report :: exception: hw1\n"
        "file-line :: report :: translated: app\n"
        "exists :: recipes/app/build\n"
    )
    c.finish()


def case_22():
    # meta expect-needed lines carry repodata shlib-requires, sorted;
    # every distfiles line gets the void mirror fallback appended.
    c = Case("22-expect-needed-mirror")
    c.names("enm")
    h1 = fake_sha("enm-1.0.tar.gz")
    h2 = fake_sha("enm-data.tar.gz")
    c.template("enm", tmpl(
        "enm",
        distfiles="https://example.org/dist/enm-${version}.tar.gz\n"
                  " https://example.org/extra/enm-data.tar.gz",
        checksum='"%s\n %s"' % (h1, h2),
    ))
    c.slice(
        E("enm", run=["zlib>=1.3.1_1", "barp>=0", "foop>=0"],
          requires=["libz.so.1", "libbar.so.9", "libfoo.so.2"]),
        E("zlib", ver="1.3.1_1", provides=["libz.so.1"]),
        E("barp", provides=["libbar.so.9"]),
        E("foop", provides=["libfoo.so.2"]),
    )
    c.expect("recipes/enm/version", "1.0 1\n")
    c.expect("recipes/enm/depends", "barp\nfoop\nzlib\n")
    c.expect("recipes/enm/sources",
             "https://example.org/dist/enm-1.0.tar.gz"
             " https://sources.voidlinux.org/enm-1.0/enm-1.0.tar.gz\n"
             "https://example.org/extra/enm-data.tar.gz"
             " https://sources.voidlinux.org/enm-1.0/enm-data.tar.gz\n")
    c.expect("recipes/enm/checksums", h1 + "\n" + h2 + "\n")
    c.checks(
        "exit :: 0\n"
        "file-line :: recipes/enm/meta :: expect-needed: libbar.so.9\n"
        "file-line :: recipes/enm/meta :: expect-needed: libfoo.so.2\n"
        "file-line :: recipes/enm/meta :: expect-needed: libz.so.1\n"
        "file-count :: recipes/enm/meta :: expect-needed: :: 3\n"
        "file-after :: recipes/enm/meta :: expect-needed: libbar.so.9"
        " :: expect-needed: libfoo.so.2\n"
        "file-after :: recipes/enm/meta :: expect-needed: libfoo.so.2"
        " :: expect-needed: libz.so.1\n"
    )
    c.finish()


# shlibs cases

def case_23():
    # every shlib-provides in the slice maps to its source package
    # (subpackage providers flattened), whole-line byte sort.
    c = Case("23-shlibs-unique")
    c.names("sapp")
    c.template("sapp", tmpl("sapp"))
    c.slice(
        E("sapp", run=["zlib>=1.3.1_1"]),
        E("zlib", ver="1.3.1_1", provides=["libz.so.1"]),
        E("alib", provides=["liba.so.1"]),
        E("libpng16", ver="1.6.50_1", src="libpng",
          provides=["libpng16.so.16"]),
        E("libpng", ver="1.6.50_1"),
    )
    c.expect("shlibs.map",
             "liba.so.1 alib\nlibpng16.so.16 libpng\nlibz.so.1 zlib\n")
    c.checks(
        "exit :: 0\n"
        "file-count :: report :: ambiguous-soname: :: 0\n"
    )
    c.finish()


def case_24():
    # multi-provider sonames: common/shlibs first entry wins
    # (version-stripped, flattened); a soname absent from common/shlibs
    # falls to the byte-smallest source and is reported ambiguous.
    c = Case("24-shlibs-multi")
    c.names("mapp2")
    c.template("mapp2", tmpl("mapp2"))
    c.slice(
        E("mapp2"),
        E("aprov", provides=["libdual.so.1"]),
        E("bprov-sub", src="bprov", provides=["libdual.so.1"]),
        E("bprov"),
        E("aa-src", provides=["libdual2.so.1"]),
        E("zz-src", provides=["libdual2.so.1"]),
    )
    c.shlibs(
        "# common/shlibs (synthetic) - first entry wins\n"
        "libdual.so.1 bprov-sub-1.0_1\n"
        "libdual.so.1 aprov-1.0_1\n"
        "libz.so.1 zlib-1.3.1_1\n"
    )
    c.expect("shlibs.map",
             "libdual.so.1 bprov\nlibdual2.so.1 aa-src\n")
    c.checks(
        "exit :: 0\n"
        "file-line :: report :: ambiguous-soname: libdual2.so.1\n"
        "file-count :: report :: ambiguous-soname: :: 1\n"
    )
    c.finish()


# provided cases

def case_25():
    # provided.suggested: union of emitted depends+makedepends plus
    # their transitive run_depends closures, minus translated set and
    # exceptions; '<source> <binaries flattened from, comma-separated>';
    # injected tools included; sorted.
    c = Case("25-provided-suggested")
    c.names("app", "zapp", "hwx")
    handwritten(c, "hwx", "2.0 1")
    c.template("app", tmpl("app", style="meson",
                           lines=['makedepends="libx-tools"']))
    c.template("zapp", tmpl("zapp"))
    c.slice(
        E("app", run=["libx-devel>=1.0_1", "zapp>=1.0_1", "hwx-bin-1.0_1"]),
        E("zapp"),
        E("hwx", ver="2.0_1"),
        E("hwx-bin", src="hwx"),
        E("libx-devel", src="xlib", run=["xcore>=0"]),
        E("libx-tools", src="xlib"),
        E("xlib", run=["xcore>=0"]),
        E("xcore"),
        E("meson"), E("ninja"), E("pkg-config"),
    )
    c.expect("recipes/app/depends", "hwx\nxlib\nzapp\n")
    c.expect("recipes/app/makedepends", "meson\nninja\npkg-config\nxlib\n")
    c.expect("provided.suggested",
             "meson meson\n"
             "ninja ninja\n"
             "pkg-config pkg-config\n"
             "xcore xcore\n"
             "xlib libx-devel,libx-tools\n")
    c.checks(
        "exit :: 0\n"
        "file-line :: report :: translated: app\n"
        "file-line :: report :: translated: zapp\n"
        "file-line :: report :: exception: hwx\n"
    )
    c.finish()


# exit-status cases

def case_26():
    # refusals are per-package and total: the good package is still
    # written, the refusing one is not, exit is 1, and the stderr line
    # follows the pinned grammar naming the offending style.
    c = Case("26-exit-mixed")
    c.names("good", "bad")
    c.template("good", tmpl("good"))
    c.template("bad", tmpl("bad", style="waf"))
    c.slice(E("good"), E("bad"))
    c.checks(
        "exit :: 1\n"
        "stderr-refusal :: bad :: waf\n"
        "stderr-matches :: ^chytrans: bad: refused: .+$\n"
        "exists :: recipes/good/build\n"
        "absent :: recipes/bad\n"
        "file-line :: report :: translated: good\n"
        "file-matches :: report :: ^refused: bad:\n"
    )
    c.finish()


# snapshot-loading cases

def case_27():
    # a snapshot whose repodata slice does not parse is refused
    # wholesale: one `chytrans: <path>: unreadable repodata slice: ...`
    # stderr line, exit 1, nothing written (never a traceback).
    c = Case("27-snapshot-unreadable")
    c.names("app")
    c.template("app", tmpl("app"))
    c.snap("repodata.slice.plist",
           b'<?xml version="1.0" encoding="UTF-8"?>\n'
           b'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
           b' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
           b'<plist version="1.0">\n<dict>\n\t<key>app</key>\n',
           REPODATA_URL)
    c.checks(
        "exit :: 1\n"
        "stderr-matches :: "
        r"^chytrans: .*repodata\.slice\.plist: unreadable repodata slice:"
        "\n"
        "absent :: report\n"
        "absent :: recipes\n"
    )
    c.finish()


def case_28():
    # a slice that parses but is not a plist dict (array root)
    # is the same wholesale refusal, not a mid-run crash after the
    # ledger files were skipped.
    c = Case("28-snapshot-not-dict")
    c.names("app")
    c.template("app", tmpl("app"))
    c.snap("repodata.slice.plist",
           plistlib.dumps([{"pkgver": "app-1.0_1"}], fmt=plistlib.FMT_XML),
           REPODATA_URL)
    c.checks(
        "exit :: 1\n"
        "stderr-matches :: "
        r"^chytrans: .*repodata\.slice\.plist: repodata slice is not a"
        " plist dict$\n"
        "absent :: report\n"
        "absent :: recipes\n"
    )
    c.finish()


# rewrite and hook tightening cases

def case_29():
    # golden assertion: a bare /usr followed by ':' or '=' (path list
    # or assignment, make FOO=/usr:/opt/x) is still a /usr-rooted path
    # and must refuse, never survive into the emitted build script.
    c = Case("29-refuse-usr-pathlist")
    c.names("plst")
    c.template("plst", tmpl("plst", funcs=(
        "post_build() {\n"
        "\tmake FOO=/usr:/opt/x\n"
        "}\n"
    )))
    c.slice(E("plst"))
    c.checks(
        "exit :: 1\n"
        "stderr-refusal :: plst :: /usr:/opt/x\n"
        "absent :: recipes/plst\n"
    )
    c.finish()


def case_30():
    # the enumerated B exception is a block guarded by the
    # CROSS_BUILD variable itself; an if testing a lookalike name such
    # as MY_CROSS_BUILD_FLAG is an ordinary compound construct and must
    # refuse (class C), never be silently dropped.
    c = Case("30-refuse-guard-lookalike")
    c.names("gdlk")
    c.template("gdlk", tmpl("gdlk", funcs=(
        "post_install() {\n"
        '\tif [ -n "$MY_CROSS_BUILD_FLAG" ]; then\n'
        "\t\trm -f README.md\n"
        "\tfi\n"
        "}\n"
    )))
    c.slice(E("gdlk"))
    c.checks(
        "exit :: 1\n"
        "stderr-refusal :: gdlk :: post_install\n"
        "absent :: recipes/gdlk\n"
    )
    c.finish()


def case_31():
    # single quotes suppress shell path semantics; a vsed script
    # editing '/usr/lib' inside single quotes is sed text, not a path
    # argument, and must translate verbatim with no $CHY_ROOT rewriting.
    c = Case("31-vsed-quoted-path")
    c.names("vq")
    c.template("vq", tmpl("vq", funcs=(
        "post_patch() {\n"
        "\tvsed -e 's|/usr/lib|/lib|g' foo.pc\n"
        "}\n"
    )))
    c.slice(E("vq"))
    c.checks(
        "exit :: 0\n"
        "file-line :: recipes/vq/build :: sed -i -e 's|/usr/lib|/lib|g' foo.pc\n"
        "file-not-has :: recipes/vq/build :: CHY_ROOT/usr\n"
        "file-line :: report :: translated: vq\n"
    )
    c.finish()


# distfiles cases

def case_32():
    # a distfile URL with no path segment after the host (trailing
    # '/' or bare host) names no file; refusal, not an invented
    # basename/mirror pair.
    c = Case("32-refuse-distfile-nobase")
    c.names("nob")
    c.template("nob", tmpl("nob", distfiles="https://example.org/dist/",
                           checksum=fake_sha("nob-dir")))
    c.slice(E("nob"))
    c.checks(
        "exit :: 1\n"
        "stderr-refusal :: nob :: basename\n"
        "absent :: recipes/nob\n"
    )
    c.finish()


# evaluation-isolation cases

def case_33():
    # sourcing an untrusted template must execute nothing real.  A
    # body that calls external commands (directly, in a subshell, in a
    # command substitution) is an unexpected-command hard failure and a
    # per-package refusal; none of the commands may actually run.
    c = Case("33-refuse-eval-canary")
    c.names("cnry")
    c.template("cnry", tmpl("cnry", lines=[
        "rm -f /tmp/chytrans-canary-rm",
        "touch /tmp/chytrans-canary-touch",
        "( touch /tmp/chytrans-canary-subshell )",
        'CANARY="$(touch /tmp/chytrans-canary-csub)"',
    ]))
    c.slice(E("cnry"))
    c.checks(
        "exit :: 1\n"
        "stderr-refusal :: cnry :: unexpected command\n"
        "absent :: recipes/cnry\n"
    )
    c.finish()


# overlay-staleness cases

# 40-hex, sharing no prefix with COMMIT in either direction.
OLD_BASE = "deadbeefcafefeedfacedeadbeefcafefeedface"


def case_32_overlay_stale():
    # an overlay whose overlay-base lags the slice's current
    # source-revisions commit is STALE: the exact report line, a stderr
    # alarm in the pinned grammar, exit 1.
    c = Case("32-overlay-stale")
    c.names("app")
    c.template("app", tmpl("app"))
    c.slice(E("app"))
    c.overlay("app", "meta",
              "origin: overlay\noverlay-base: %s\n" % OLD_BASE)
    c.checks(
        "exit :: 1\n"
        "stdout-line :: overlay: app: STALE: base %s, upstream now %s\n"
        % (OLD_BASE, COMMIT) +
        "stderr-matches :: ^chytrans: app: stale-overlay: base %s\n"
        % OLD_BASE
    )
    c.finish()


def case_33_overlay_current():
    # commit comparison is prefix-tolerant (live source-revisions
    # commits are abbreviated), so a 12-hex overlay-base matches its
    # 40-hex upstream; an overlay shadowing nothing in the snapshot is
    # the informational 'local' line.  No alarm, exit 0.
    c = Case("33-overlay-current")
    c.names("app")
    c.template("app", tmpl("app"))
    c.slice(E("app"))
    c.overlay("app", "meta",
              "origin: overlay\noverlay-base: %s\n" % COMMIT[:12])
    c.overlay("locpkg", "meta", "origin: overlay\n")
    c.checks(
        "exit :: 0\n"
        "stdout-line :: overlay: app: current (base %s)\n" % COMMIT[:12] +
        "stdout-line :: overlay: locpkg: local (no upstream in snapshot)\n"
    )
    c.finish()


# kill-switch cases

# 40-hex, distinct from COMMIT (the slice's source-revisions commit).
PIN = "fedcba9876543210fedcba9876543210fedcba98"


def case_34_pin_meta():
    # a snapshot carrying snapshot/pin translates with void-commit:
    # = the pin, not the package's source-revisions commit, and the run
    # ledger records the pin.
    c = Case("34-pin-meta")
    c.names("app")
    c.template("app", tmpl("app"))
    c.slice(E("app"))
    c.write("snapshot/pin", PIN + "\n")
    c.checks(
        "exit :: 0\n"
        "file-line :: recipes/app/meta :: void-commit: %s\n" % PIN +
        "file-not-has :: recipes/app/meta :: %s\n" % COMMIT +
        "file-line :: report :: pin: %s\n" % PIN +
        "file-line :: report :: translated: app\n"
    )
    c.finish()


# soak-gate cases

def case_35_soak_defer():
    # snapshot/soak pins the verdict; translate stays offline.  A
    # deferred package with a seeded prior recipe keeps it byte-identical
    # (like a handwritten exception it is not regenerated); a deferred
    # package with no prior recipe emits nothing; both earn a 'deferred:'
    # report line and leave exit status untouched; a soaked package
    # translates as always.
    c = Case("35-soak-defer")
    c.names("aged", "fresh", "young")
    c.template("aged", tmpl("aged"))
    c.template("fresh", tmpl("fresh", ver="2.0"))
    c.template("young", tmpl("young", ver="3.0"))
    c.slice(E("aged"), E("fresh", ver="2.0_1"), E("young", ver="3.0_1"))
    # Epochs are server-supplied (mirror Last-Modified, commits-API
    # committer date).  Ages resolve against the newest epoch recorded in
    # the file (1704326400): fresh's newest clock is 2 days older, young
    # (all doubt, both clocks 0) reports age=0.
    c.write("snapshot/soak",
            "aged aged-1.0_1 1704326400 1703980800 soaked\n"
            "fresh fresh-2.0_1 1704067200 1704153600 deferred\n"
            "young young-3.0_1 0 0 deferred\n")
    prior = {
        "meta": ("origin: translated\n"
                 "template: srcpkgs/fresh/template\n"
                 "void-commit: %s\n"
                 "pkgver: fresh-1.9_1\n"
                 "style: gnu-configure\n" % COMMIT),
        "version": "1.9 1\n",
        "sources": ("https://example.org/dist/fresh-1.9.tar.gz"
                    " https://sources.voidlinux.org/fresh-1.9/"
                    "fresh-1.9.tar.gz\n"),
        "checksums": fake_sha("fresh-1.9.tar.gz") + "\n",
        "build": ("#!/bin/sh -e\n"
                  "# prior repo recipe (1.9); a regenerating run would"
                  " replace these bytes\n"
                  './configure \\\n'
                  '    --prefix="$CHY_PREFIX" \\\n'
                  '    --sysconfdir="$CHY_ROOT/etc"\n'
                  'make\n'
                  'make DESTDIR="$1" install\n'),
    }
    for rel, text in prior.items():
        c.pre("recipes/fresh/%s" % rel, text)
        c.expect("recipes/fresh/%s" % rel, text)
    c.expect("recipes/aged/version", "1.0 1\n")
    c.checks(
        "exit :: 0\n"
        "file-line :: report :: translated: aged\n"
        "file-line :: report :: deferred: fresh fresh-2.0_1 age=2\n"
        "file-line :: report :: deferred: young young-3.0_1 age=0\n"
        "file-count :: report :: deferred: :: 2\n"
        "exists :: recipes/aged/build\n"
        "absent :: recipes/young\n"
    )
    c.finish()


# virtual-package resolution cases

def case_36_virtual_resolved():
    # names with no slice entry of their own resolve through the
    # slice's 'provides' entries: an implicit virtual (libFAKE, the
    # libEGL/libglvnd shape) and an explicit virtual? token both land
    # on their single provider's source package, in depends and in the
    # provided.suggested hints.
    c = Case("36-virtual-resolved")
    c.names("gapp")
    c.template("gapp", tmpl("gapp"))
    c.slice(
        E("gapp", run=["libFAKE>=1.0_1", "virtual?fakefw>=0"]),
        E("glprov", vprovides=["libFAKE-1.0_1"]),
        E("fwprov", vprovides=["fakefw-1_1"]),
    )
    c.expect("recipes/gapp/depends", "fwprov\nglprov\n")
    c.expect("provided.suggested", "fwprov fwprov\nglprov glprov\n")
    c.checks(
        "exit :: 0\n"
        "file-line :: report :: translated: gapp\n"
        "file-line :: recipes/gapp/meta :: origin: translated\n"
    )
    c.finish()


def case_37_refuse_virtual_ambiguous():
    # two source packages providing the same virtual name, with no
    # reviewed default to settle it, is its own refusal naming the
    # providers.
    c = Case("37-refuse-virtual-ambiguous")
    c.names("aapp")
    c.template("aapp", tmpl("aapp"))
    c.slice(
        E("aapp", run=["libAMB>=1_1"]),
        E("prov1", vprovides=["libAMB-1_1"]),
        E("prov2", vprovides=["libAMB-1_1"]),
    )
    c.checks(
        "exit :: 1\n"
        "stderr-refusal :: aapp :: ambiguous\n"
        "file-matches :: report :: ^refused: aapp:.*libAMB\n"
        "absent :: recipes/aapp\n"
    )
    c.finish()


def case_38_virtual_default_awk():
    # an ambiguity the reviewed default table settles: awk has several
    # providers and resolves to gawk, Void's own default.
    c = Case("38-virtual-default-awk")
    c.names("wapp")
    c.template("wapp", tmpl("wapp"))
    c.slice(
        E("wapp", run=["awk>=1_1"]),
        E("gawk", vprovides=["awk-1_1"]),
        E("mawk", vprovides=["awk-1_1"]),
    )
    c.expect("recipes/wapp/depends", "gawk\n")
    c.checks(
        "exit :: 0\n"
        "file-line :: report :: translated: wapp\n"
        "file-line :: recipes/wapp/depends :: gawk\n"
    )
    c.finish()


# verification

DIRECTIVE_ARITY = {
    "exit": (1, 1), "stderr-refusal": (1, 2), "stderr-matches": (1, 1),
    "stdout-line": (1, 1), "stdout-matches": (1, 1),
    "exists": (1, 1), "absent": (1, 1),
    "file-line": (2, 2), "file-has": (2, 2), "file-not-has": (2, 2),
    "file-matches": (2, 2), "file-first-line": (2, 2),
    "file-line-n": (3, 3), "file-matches-n": (3, 3),
    "file-after": (3, 3), "file-count": (3, 3),
}

PKGVER_RX = re.compile(r"^[a-z0-9][a-z0-9+._-]*-[A-Za-z0-9._+]+_[0-9]+$")
SRCREV_RX = re.compile(r"^[a-z0-9][a-z0-9+._-]*:[0-9a-f]{40}$")
HEX64_RX = re.compile(r"^[0-9a-f]{64}$")


def _sig(text):
    return [ln for ln in text.splitlines()
            if ln.strip() != "" and not ln.startswith("#")]


def _read(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8")


def verify(root):
    probs = []
    case = os.path.basename(root)

    def bad(msg):
        probs.append("%s: %s" % (case, msg))

    for req in ("snapshot/repodata.slice.plist", "snapshot/common-shlibs",
                "snapshot/MANIFEST", "names", "checks"):
        if not os.path.isfile(os.path.join(root, req)):
            bad("missing %s" % req)
    plist_path = os.path.join(root, "snapshot/repodata.slice.plist")
    idx = {}
    if os.path.isfile(plist_path):
        with open(plist_path, "rb") as f:
            try:
                idx = plistlib.load(f)
            except Exception:
                idx = None # unreadable on purpose (bad-snapshot cases)
        if not isinstance(idx, dict):
            idx = None      # wrong-rooted on purpose; the case pins it
        for k, v in sorted((idx or {}).items()):
            if not PKGVER_RX.match(v.get("pkgver", "")):
                bad("slice %s: bad pkgver %r" % (k, v.get("pkgver")))
            if not v.get("pkgver", "").startswith(k + "-"):
                bad("slice %s: pkgver does not carry the name" % k)
            if not SRCREV_RX.match(v.get("source-revisions", "")):
                bad("slice %s: bad source-revisions" % k)

    names = _sig(_read(os.path.join(root, "names")))
    if not names:
        bad("empty names file")
    for n in names:
        if idx is not None and n not in idx:
            bad("requested %s not in slice" % n)
        tpl = os.path.join(root, "snapshot/srcpkgs", n, "template")
        premeta = os.path.join(root, "pre/recipes", n, "meta")
        if not os.path.isfile(tpl):
            if not (os.path.isfile(premeta)
                    and "origin: handwritten" in _read(premeta)):
                bad("requested %s has neither template nor handwritten pre" % n)

    for lineno, ln in enumerate(_read(os.path.join(root, "checks")).splitlines(), 1):
        if ln.strip() == "" or ln.startswith("#"):
            continue
        parts = ln.split(" :: ")
        op, args = parts[0], parts[1:]
        if op not in DIRECTIVE_ARITY:
            bad("checks:%d unknown directive %r" % (lineno, op))
            continue
        lo, hi = DIRECTIVE_ARITY[op]
        if not lo <= len(args) <= hi:
            bad("checks:%d %s arity %d" % (lineno, op, len(args)))
        for a in args:
            if a != a.strip():
                bad("checks:%d arg with edge whitespace: %r" % (lineno, a))

    expect_root = os.path.join(root, "expect")
    if os.path.isdir(expect_root):
        for dirpath, _dn, fns in os.walk(expect_root):
            for fn in fns:
                p = os.path.join(dirpath, fn)
                rel = os.path.relpath(p, expect_root)
                text = _read(p)
                if text and not text.endswith("\n"):
                    bad("expect %s lacks trailing newline" % rel)
                base = os.path.basename(rel)
                if base in ("depends", "makedepends", "conflicts") \
                        or rel in ("shlibs.map", "provided.suggested"):
                    lines = text.splitlines()
                    if lines != sorted(lines):
                        bad("expect %s not byte-sorted" % rel)
        for rdir in sorted(os.listdir(expect_root)):
            pass
        # sources/checksums pairing wherever both are expected
        rec_root = os.path.join(expect_root, "recipes")
        if os.path.isdir(rec_root):
            for name in sorted(os.listdir(rec_root)):
                s = os.path.join(rec_root, name, "sources")
                k = os.path.join(rec_root, name, "checksums")
                if os.path.isfile(s) and os.path.isfile(k):
                    ns, nk = len(_sig(_read(s))), len(_sig(_read(k)))
                    if ns != nk:
                        bad("expect recipes/%s: %d sources vs %d checksums"
                            % (name, ns, nk))
                if os.path.isfile(k):
                    for ln in _sig(_read(k)):
                        if not HEX64_RX.match(ln):
                            bad("expect recipes/%s: bad checksum line %r"
                                % (name, ln))
    return probs


def main():
    fns = [fn for nm, fn in sorted(globals().items())
           if nm.startswith("case_") and callable(fn)]
    for fn in fns:
        fn()
    dirs = sorted(d for d in os.listdir(HERE)
                  if os.path.isfile(os.path.join(HERE, d, "names")))
    if len(dirs) != len(fns):
        raise SystemExit("case count mismatch: %d dirs from %d functions"
                         % (len(dirs), len(fns)))
    probs = []
    for d in dirs:
        probs.extend(verify(os.path.join(HERE, d)))
    if probs:
        for p in probs:
            print("BAD %s" % p)
        raise SystemExit(1)
    print("generated %d fixtures OK" % len(dirs))


if __name__ == "__main__":
    main()
