#!/usr/bin/env bash
# Shared configuration and helpers for the modulizer Boost pipeline.
#
# Sourced, not executed. Every path is an environment variable with a default,
# so a checkout works without configuration and a CI job can point each stage
# somewhere else without editing anything.

set -euo pipefail

# ---- layout --------------------------------------------------------------
# One work root holds everything the pipeline produces. Each directory under it
# can be overridden on its own, so an existing tree of upstream clones can be
# reused without copying it into place.
MZ_ROOT=${MZ_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/modulizer}
MZ_SRC=${MZ_SRC:-$MZ_ROOT/src}          # upstream Boost clones, one per library
MZ_DEPS=${MZ_DEPS:-$MZ_ROOT/deps}       # shared include tree the forks build against
MZ_FORKS=${MZ_FORKS:-$MZ_ROOT/forks}    # assembled forks
MZ_PUB=${MZ_PUB:-$MZ_ROOT/pub}          # publish scratch

# The Boost release the upstream clones are pinned to. A conversion is only
# reproducible against a fixed tree.
MZ_BOOST_TAG=${MZ_BOOST_TAG:-boost-1.92.0}
MZ_BOOST_ORG=${MZ_BOOST_ORG:-https://github.com/boostorg}

# Where converted forks are published. Only boost-publish reads these.
MZ_GITHUB_USER=${MZ_GITHUB_USER:-}
MZ_REPO_SUFFIX=${MZ_REPO_SUFFIX:--modules}
MZ_PUBLISH_BRANCH=${MZ_PUBLISH_BRANCH:-develop}

MZ_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MZ_HOME=$(dirname "$MZ_LIB_DIR")
MZ_BIN=$MZ_HOME/bin
MZ_CONFIG=${MZ_CONFIG:-$MZ_HOME/config}

# ---- tools ---------------------------------------------------------------
# Overridable, discovered otherwise. Modules need a recent everything, so the
# versions are checked rather than assumed.
MZ_MODULIZER=${MZ_MODULIZER:-}
MZ_CMAKE=${MZ_CMAKE:-cmake}
MZ_CXX=${MZ_CXX:-}
MZ_JOBS=${MZ_JOBS:-}

# ---- output --------------------------------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _c_red=$'\033[31m'; _c_yellow=$'\033[33m'; _c_dim=$'\033[2m'; _c_off=$'\033[0m'
else
  _c_red=''; _c_yellow=''; _c_dim=''; _c_off=''
fi

log()  { printf '%s\n' "$*" >&2; }
info() { printf '%s%s%s\n' "$_c_dim" "$*" "$_c_off" >&2; }
warn() { printf '%swarning:%s %s\n' "$_c_yellow" "$_c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

# ---- preconditions -------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

need_cmd() {
  have "$1" || die "$1 is required but not on PATH${2:+ ($2)}"
}

# Compare dotted versions: version_at_least 3.28.1 3.28 -> true
version_at_least() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

mz_jobs() {
  if [ -n "$MZ_JOBS" ]; then printf '%s' "$MZ_JOBS"; return; fi
  if have nproc; then nproc; else printf '1'; fi
}

# The C++ compiler. Modules need Clang 17+ (`-std=c++20` with `import`), and the
# pipeline is only exercised with Clang.
mz_cxx() {
  if [ -n "$MZ_CXX" ]; then printf '%s' "$MZ_CXX"; return; fi
  local c
  for c in clang++ clang++-22 clang++-21 clang++-20 clang++-19 clang++-18 clang++-17; do
    have "$c" && { printf '%s' "$c"; return; }
  done
  die "no clang++ found; set MZ_CXX"
}

# CMake 3.28 is the first release with C++20 module support that does not need
# an experimental UUID opt-in.
mz_cmake() {
  local cm=$MZ_CMAKE v
  have "$cm" || die "cmake not found; set MZ_CMAKE"
  v=$("$cm" --version | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  version_at_least "$v" 3.28 || die "cmake $v is too old; 3.28+ is required for C++20 modules (set MZ_CMAKE)"
  printf '%s' "$cm"
}

# The modulizer binary. Looked for next to the checkout and in the usual build
# directories before giving up, so a normal working tree needs no configuration.
mz_modulizer() {
  if [ -n "$MZ_MODULIZER" ]; then
    [ -x "$MZ_MODULIZER" ] || die "MZ_MODULIZER is not executable: $MZ_MODULIZER"
    printf '%s' "$MZ_MODULIZER"; return
  fi
  local c
  for c in "$MZ_HOME/../modulizer/build/modulizer_client" \
           "$MZ_HOME/../build/modulizer_client" \
           "$MZ_ROOT/build/modulizer_client"; do
    [ -x "$c" ] && { printf '%s' "$c"; return; }
  done
  have modulizer_client && { command -v modulizer_client; return; }
  die "modulizer_client not found; set MZ_MODULIZER to the built binary"
}

# ---- names ---------------------------------------------------------------
# Boost library names carry underscores (`type_index`), which become dots in
# module names and upper case in macros.
mz_upper()  { printf '%s' "$1" | tr 'a-z-' 'A-Z_'; }
mz_module() { printf 'boost.%s' "$1"; }
# The macro prefix a converted library uses. The trailing X keeps it clear of
# Boost's own BOOST_<LIB>_ macros, which the headers already define.
mz_prefix() { printf 'BOOST_%sX' "$(mz_upper "$1")"; }

mz_repo_dir()  { printf '%s/%s' "$MZ_SRC" "$1"; }
mz_fork_dir()  { printf '%s/%s' "$MZ_FORKS" "$1"; }

mz_require_repo() {
  [ -d "$(mz_repo_dir "$1")/include" ] ||
    die "no upstream checkout for '$1'; run: boost-fetch $1"
}

# The libraries that have been converted, in dependency order. Each is a sibling
# of the others: a fork imports a converted dependency as a module when that
# dependency's own macro says so.
mz_libraries() {
  local f=${MZ_LIBRARIES_FILE:-$MZ_CONFIG/libraries.txt}
  [ -f "$f" ] || die "library list not found: $f"
  grep -vE '^\s*(#|$)' "$f"
}

# ---- usage ---------------------------------------------------------------
# Every command prints its own header comment for --help, so the documentation
# and the script cannot drift apart.
mz_usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

mz_handle_help() {
  case "${1:-}" in -h|--help|help) mz_usage 0 ;; esac
}
