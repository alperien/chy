# chy

A tiny package manager for hand-built Linux systems. It is rootless,
relocatable, and source-based by default, with support for upstream
binary tarballs where compiling would be absurd.

The manager itself is one POSIX shell file, readable in one sitting. No
database. No daemon. Recipes come from
[void-packages](https://github.com/void-linux/void-packages), translated
mechanically; nobody hand-maintains them, so the set doesn't go stale.

chy installs, resolves dependencies, removes, and checks what it built.
It can build from source or unpack an upstream binary tarball. It built
and launched Firefox in a throwaway prefix. Early days, but it works.

```
chy/chy          the package manager, one POSIX sh file
translator/      chytrans: Void templates into chy recipes
recipes/         the generated recipe corpus
test             the test suite (run: sh ./test)
```

One warning up front: recipe pull requests will not be accepted.
Recipes are generated. When a recipe is wrong, the translator gets fixed.
