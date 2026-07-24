# chy

A tiny, source-based package manager for hand-built Linux systems. One
POSIX shell script, with no database, no daemon, and no root.

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

```
git clone https://github.com/alperien/chy
cd chy
export CHY_ROOT="$HOME/.chy"
export PATH="$CHY_ROOT/usr/bin:$PATH"
sh chy/chy install freetype
```

`chy` is the single file `chy/chy`. Copy it onto your `PATH` as `chy`, or
run it in place with `sh chy/chy`.

`$CHY_ROOT` is the whole world it touches. Leave it unset and it defaults
to `$HOME/.chy`. chy never writes outside that directory and never needs
privilege, so two roots at two paths are completely independent.

## Layout

```
chy/chy          the package manager, one POSIX sh file
translator/      chytrans: Void templates into chy recipes
recipes/         the generated recipe corpus
test             the test suite (run: sh ./test)
```

## Recipes are generated

Recipes come from the translator, so a pull request that adds or edits one
will be closed. When a recipe is wrong the fix goes into the translator,
and the affected recipes are regenerated. Nobody maintains thousands of
build files by hand.

## License

MIT. See [LICENSE](LICENSE).

[void]: https://github.com/void-linux/void-packages
