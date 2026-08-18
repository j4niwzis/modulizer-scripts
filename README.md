# modulizer-scripts

The pipeline that converts Boost libraries to C++20 modules with
[modulizer](https://github.com/j4niwzis/modulizer) and packages each result as a
fork that builds either way.

Every conversion starts from the library as Boost publishes it — the scripts
clone `boostorg/<lib>` at a release tag. Nothing here reads an already-converted
fork.

## What a converted fork is

The upstream repository with its headers replaced by generated ones and the
module interface units added under `modules/`. It builds two ways from one
tree:

```sh
cmake -B build                              # classic, header-only
cmake -B build -DBOOST_SYSTEM_MODULES=ON    # module units and imports
```

The library's own tests and examples build and run under both. They are the
upstream sources, rewritten to carry their includes for the classic build and
imports where the module macro is defined.

Tests that do not compile against *upstream* are left out of the generated
build: they want a Boost library the tree has no way to provide, or they are
compile-fail tests. Only what worked before the conversion is held to working
after it.

A fork depending on another converted library imports it as a module when that
library's own macro says so — `BOOST_MP11X_IMPORT_MODULES`, not one switch for
all of Boost. Each library's modularity is chosen on its own.

## Requirements

| | |
|---|---|
| Clang | 17+ (the pipeline is exercised on 22) |
| CMake | 3.28+ — the first release with C++20 modules out of the box |
| Ninja | any; the module build needs a generator with dyndep support |
| modulizer | built, `modulizer_client` on `PATH` or in `MZ_MODULIZER` |
| git, rsync, python3, curl | curl only for publishing |

## Use

```sh
export PATH=$PWD/bin:$PATH

boost-fetch --all --deps      # clone boostorg/<lib> and everything they include
boost-deps system             # stage the shared include tree, minus system
boost-fork system             # convert, assemble, build and test both ways
```

or over the whole list:

```sh
boost-sweep --all             # each library against original Boost headers
boost-sweep --all --siblings  # each library against the converted forks
```

and to publish:

```sh
export MZ_GITHUB_USER=yourname
boost-publish --dry-run system   # build the commit, push nothing
boost-publish system             # push <user>/system-modules
```

A published fork is the upstream history with a single `Modulize` commit on
top, so the diff against Boost is the conversion itself.

## Commands

| | |
|---|---|
| `boost-fetch` | clone the upstream libraries, pinned to a release tag |
| `boost-deps` | stage the shared include tree a fork builds against |
| `boost-fork` | convert one library and verify it both ways |
| `boost-sweep` | run the above over many libraries and report a table |
| `boost-publish` | push a converted fork to GitHub |

Each takes `--help`.

## Patches

`patches/<lib>/*.patch` are applied to a fork after it is copied from upstream
and before it is converted.

They exist for one thing: a conversion changes how many lines stand above a
consumer's code, so every source location the file reports moves, and a test
that names a line outright fails by exactly that shift. Such a test is patched
to ask `__LINE__` for the line it is about.

A patch must apply cleanly or the run stops — a patch that has drifted from its
upstream is worse than none. Each is also checked against *unpatched* upstream:
the patched test has to pass there too, so a patch adapts a test rather than
bending one into passing.

## Configuration

Every path is an environment variable with a default, so a checkout works
unconfigured and CI can point each stage elsewhere without edits.

| variable | default | |
|---|---|---|
| `MZ_ROOT` | `$XDG_CACHE_HOME/modulizer` | everything below lives here |
| `MZ_SRC` | `$MZ_ROOT/src` | upstream clones, one per library |
| `MZ_DEPS` | `$MZ_ROOT/deps` | shared include tree |
| `MZ_FORKS` | `$MZ_ROOT/forks` | assembled forks |
| `MZ_PUB` | `$MZ_ROOT/pub` | publish scratch |
| `MZ_BOOST_TAG` | `boost-1.92.0` | the release the clones are pinned to |
| `MZ_BOOST_ORG` | `https://github.com/boostorg` | where upstream is fetched from |
| `MZ_MODULIZER` | discovered | the `modulizer_client` binary |
| `MZ_CMAKE` | `cmake` | must be 3.28+ |
| `MZ_CXX` | discovered | `clang++` |
| `MZ_JOBS` | `nproc` | build parallelism |
| `MZ_GITHUB_USER` | — | account to publish under |
| `MZ_GITHUB_TOKEN` | git's credential store | token for publishing |

`config/libraries.txt` is the list of converted libraries, in dependency order.

## Why the dependency tree is staged file by file

A converted library still includes the Boost libraries it depends on, and those
have to resolve to something. `boost-deps` symlinks every other library's
headers into one directory one file at a time rather than linking directories:
several Boost repositories contribute to the same directory — `boost/detail/`
among them — and linking that directory would hide whatever the others put
there.

The library being converted is excluded by *repository*, not by where a header
sits. A library owns its top-level forwarding headers too — `boost/shared_ptr.hpp`
belongs to `smart_ptr` — and staging one of those would let the original win
over the generated header that replaces it. The exception is `header.hpp` and
`footer.hpp`, the ABI prefix/suffix fragments: neither is a translation unit, so
the conversion leaves both as textual includes and they still have to resolve.

## License

AGPL-3.0, as [modulizer](https://github.com/j4niwzis/modulizer) is — the
pipeline and the tool it drives are one thing, and it would be confusing for
them to be licensed differently.

This covers the scripts only. The libraries they convert stay under the Boost
Software License 1.0: a published fork is upstream's own repository with one
commit on top, so Boost's per-file copyright notices ride along untouched.
