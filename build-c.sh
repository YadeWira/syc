# Sourced by build.sh and plugin/build.sh: build_c OUTDIR [fpc options]
# compiles src/sylzc.c to OUTDIR/sylzc.o for the target the fpc options
# name (unless -dSYLZ_PUREPASCAL), asking $FPC for its target OS and CPU:
# gcc, gcc -m32 (Linux x86), the mingw and aarch64 cross compilers, or cc
# (clang, macOS). CC overrides the compiler; CFLAGS_EXTRA adds flags (e.g.
# -DSYLZC_NO_SSE2: a 32-bit x86 decoder without SSE2, for CPUs before the
# Pentium 4). (Variables prefixed: this runs in the caller's shell.)
CFLAGS_SYLZ="-O2 -ffreestanding -fno-builtin -fno-stack-protector \
-fno-asynchronous-unwind-tables -Wall"
build_c() {
  _bc_out=$1
  shift
  _bc_os=$(${FPC:-fpc} "$@" -iTO 2>/dev/null)
  _bc_cpu=$(${FPC:-fpc} "$@" -iTP 2>/dev/null)
  case "$_bc_os-$_bc_cpu" in
    linux-i386) _bc_cc="gcc -m32" ;;
    darwin-*) _bc_cc=cc ;;
    *) _bc_cc=gcc ;;
  esac
  _bc_extra=
  for _bc_opt in "$@"; do
    case $_bc_opt in
      -dSYLZ_PUREPASCAL) return 0 ;;
      -Twin64) _bc_cc=x86_64-w64-mingw32-gcc ;;
      -Twin32) _bc_cc=i686-w64-mingw32-gcc ;;
      -XPaarch64-linux-gnu-) _bc_cc=aarch64-linux-gnu-gcc ;;
      -Cg) _bc_extra=-fPIC ;;
    esac
  done
  _bc_cc=${CC:-$_bc_cc}
  # gcc turns some loops into memcpy/memset calls unless told not to
  # (freestanding code); clang has no such flag
  if ! $_bc_cc --version 2>/dev/null | grep -qi clang; then
    _bc_extra="$_bc_extra -fno-tree-loop-distribute-patterns"
  fi
  # shellcheck disable=SC2086
  $_bc_cc $CFLAGS_SYLZ $_bc_extra $CFLAGS_EXTRA -c src/sylzc.c -o "$_bc_out/sylzc.o"
}
