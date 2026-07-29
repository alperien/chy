# chy

A tiny, source-based package manager for hand-built Linux systems. One
POSIX shell script. No daemon, no root, and no state that is not a plain
file under one directory.

`chy` builds each package into its own directory and links it into a
symlink farm under `$CHY_ROOT`. Recipes are not written by hand: a
separate tool translates them from [Void Linux][void]'s package tree, so
the set follows upstream instead of going stale.

```
chy install freetype      # resolve dependencies, build, link
chy remove -r freetype    # remove it, and any orphans it leaves
chy list                  # what is installed
chy doctor                # check the farm and the linked libraries
```

## Getting started

`chy` reads recipes from `$CHY_ROOT`, so the corpus has to live there.
The clone ships it at the repo root, so link it in:

```
git clone https://github.com/alperien/chy
cd chy
export CHY_ROOT="$HOME/.chy"
export PATH="$CHY_ROOT/usr/bin:$PATH"
mkdir -p "$CHY_ROOT"
ln -s "$PWD/recipes"    "$CHY_ROOT/recipes"
ln -s "$PWD/shlibs.map" "$CHY_ROOT/shlibs.map"
sh chy/chy install zlib
```

Building a package needs a C toolchain and network access to fetch its
sources. The `recipes/` in this clone is a small sample; the full corpus
is what the translator generates (see below).

`chy` is the single file `chy/chy`. Copy it onto your `PATH` as `chy`, or
run it in place with `sh chy/chy`.

`$CHY_ROOT` is the whole world it touches. Leave it unset and it defaults
to `$HOME/.chy`. chy never writes outside that directory and never needs
privilege, so two roots at two paths are completely independent.

Two more files under `$CHY_ROOT` are optional. `shlibs.map` maps a soname
to the package that provides it, so `doctor` can name it. `db/provided`
lists package names the host already supplies, seeded from
`provided.suggested` at the repo root; a name listed there is treated as
installed and never built.

## Layout

```
chy/chy          the package manager, one POSIX sh file
translator/      chytrans: Void templates into chy recipes
recipes/         the generated recipe corpus (a sample in this clone)
shlibs.map       soname to package, for doctor
tests/           the test suite
test             the test runner (run: sh ./test)
```

## Recipes are generated

Recipes come from the translator, so a pull request that adds or edits one
will be closed. When a recipe is wrong the fix goes into the translator,
and the affected recipes are regenerated. Nobody maintains thousands of
build files by hand.

## License

MIT. See [LICENSE](LICENSE).

[void]: https://github.com/void-linux/void-packages
