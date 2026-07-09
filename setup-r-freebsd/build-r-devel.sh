#!/bin/sh
# Builds R-devel on FreeBSD and packages it as a relocatable tarball, so CI can
# unpack it rather than compile R on every run.
#
# Run as root in a disposable FreeBSD VM: it installs packages and writes $PREFIX.
set -eu

PREFIX="${PREFIX:-/opt/R-devel}"
GCC_PORT="${GCC_PORT:-gcc14}"   # pins the libgfortran ABI; consumers must match
LEAN="${LEAN:-1}"               # 1 = no X11, smaller artifact
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
WORK="${WORK:-/tmp/r-devel-build}"
OUT="${OUT:-$(pwd)/artifacts}"  # vmactions copies this back to the host
SRC_URL="https://stat.ethz.ch/R/daily/R-devel.tar.gz"

FBSD_MAJOR="$(freebsd-version | cut -d. -f1)"
ARCH="$(uname -m)"

RUNTIME_DEPS="${GCC_PORT} pcre2 readline icu curl"   # names verified on 14.3 (2026-07)
BUILD_DEPS="gmake pkgconf perl5 ${RUNTIME_DEPS}"
# Needed only by `R CMD check --as-cran` for packages with manuals or vignettes.
# Recorded rather than bundled, to keep the artifact small.
OPTIONAL_CHECK_DEPS="qpdf hs-pandoc aspell en-aspell texlive-base"

mkdir -p "$WORK" "$OUT"

echo ">> installing build deps"
# shellcheck disable=SC2086  # word splitting is intended: one argument per package
env ASSUME_ALWAYS_YES=yes pkg install -y ${BUILD_DEPS}

echo ">> fetching R-devel daily snapshot"
cd "$WORK"
fetch -o R-devel.tar.gz "$SRC_URL"
tar -xf R-devel.tar.gz
cd R-devel
SVNREV="$(awk '/Revision:/ {print $2}' SVN-REVISION 2>/dev/null || echo unknown)"

# FreeBSD base has no Fortran compiler, so gfortran comes from the gcc port. R must
# find libgfortran at run time as well as link time, hence the rpath.
GVER="${GCC_PORT#gcc}"
FC_BIN="gfortran${GVER}"                # verified: /usr/local/bin/gfortran14
GCCLIB="/usr/local/lib/${GCC_PORT}"     # verified: holds libgfortran.so.5

export CC=cc CXX=c++                    # clang, from base
export FC="$FC_BIN" F77="$FC_BIN"
export CPPFLAGS="-I/usr/local/include"
export LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib -L${GCCLIB} -Wl,-rpath,${GCCLIB}"

XOPT="--with-x=no"
[ "$LEAN" = "0" ] && XOPT="--with-x=yes"

echo ">> configuring (prefix=$PREFIX gcc=$GCC_PORT lean=$LEAN rev=$SVNREV)"
./configure \
  --prefix="$PREFIX" \
  --enable-R-shlib \
  --with-blas --with-lapack \
  --with-recommended-packages=yes \
  $XOPT

echo ">> building"
gmake -j"$JOBS"
gmake install

# GPL: the licence plus BUILDINFO's exact source revision are the corresponding-source
# offer. See SOURCE-OFFER.md.
cp COPYING "$PREFIX/COPYING"
# shellcheck disable=SC2086  # unquoted so printf repeats its format, one package per line
printf '%s\n' ${RUNTIME_DEPS}        > "$PREFIX/DEPS.txt"
# shellcheck disable=SC2086
printf '%s\n' ${OPTIONAL_CHECK_DEPS} > "$PREFIX/DEPS.optional.txt"
printf 'freebsd-major=%s\narch=%s\ngcc=%s\nsvn-rev=%s\nsource=%s\n' \
  "$FBSD_MAJOR" "$ARCH" "$GCC_PORT" "$SVNREV" "$SRC_URL" > "$PREFIX/BUILDINFO.txt"

NAME="R-devel-freebsd${FBSD_MAJOR}-${ARCH}-${GCC_PORT}-r${SVNREV}.tar.zst"
# Stable URL that setup-r-freebsd's devel path downloads. Must match the
# r-devel-url default in action.yaml.
ALIAS="R-devel-freebsd${FBSD_MAJOR}-${ARCH}-${GCC_PORT}.tar.zst"

echo ">> packaging $NAME"
tar --zstd -cf "$OUT/$NAME" -C "$(dirname "$PREFIX")" "$(basename "$PREFIX")"
cp "$OUT/$NAME" "$OUT/$ALIAS"
cp "$PREFIX/DEPS.txt" "$OUT/deps.txt"

echo ">> done -> $OUT/$NAME (alias: $ALIAS)"
