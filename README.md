# chy

chy is a byte-sized, portable, source-based package manager written in
POSIX shell. 1.6k lines of pretty shell with no dependencies.

chy is for machines you do not control: shared hosts and locked-down
servers where you get a shell, a compiler, and no root. Everything
installs under your home directory and uninstalls by deleting it. The
tool is one file, short enough to read before trusting it.

Packages are recipe based and easily readable and tweakable

Everything is at $CHY_ROOT, ~/.chy by default. Packages get built into
store/ and get linked into a usr/ symlink farm. chy lives in userland and won't write outside its
root, so deleting the folder is equal to a full uninstall. Running chy with no arguments prints
the list of all options.

    git clone https://github.com/alperien/chy && cd chy
    git clone https://github.com/alperien/chy-recipes
    export CHY_ROOT=$HOME/.chy PATH="$HOME/.chy/usr/bin:$PATH"
    mkdir -p "$CHY_ROOT" && ln -s "$PWD/chy-recipes/recipes" "$CHY_ROOT/recipes"
    cp chy-recipes/shlibs.map "$CHY_ROOT/shlibs.map"
    sh chy/chy install freetype

A recipe is a folder containing text files: version, sources, checksums,
depends, makedepends, a build script, patches/, and an optional
patchlevel for patches that do not apply at -p1. A recipe repo is a
directory of recipes, chy builds from whichever one $CHY_ROOT/recipes
points at: the symlink above picks the default repo, but making your
own is encouraged. For quick tweaks there's also
$CHY_ROOT/overlay/<name>, which chy reads before the repo.

The default repo, [chy-recipes](https://github.com/alperien/chy-recipes), is converted from Void
Linux's xbps by the chytrans tool. Void's maintainers do the packaging; a nightly sync
snapshots their templates after a seven day quarantine, translates the set, builds every
changed recipe in a container, and publishes only what built. A package that stops
translating is held at its last good recipe instead of blocking the rest. All fixes go in
the translator in this repo; recipe PRs against chy-recipes get closed.

MIT.
