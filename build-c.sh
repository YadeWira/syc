# Sourced by build.sh and plugin/build.sh: build_c OUTDIR [fpc options]
# compiles src/sylzc.c to OUTDIR/sylzc.o for the target the fpc options
# name (unless -dSYLZ_PUREPASCAL). CC overrides the compiler. (Variables
# prefixed: this runs in the caller's shell.)
CFLAGS_SYLZ="-O2 -ffreestanding -fno-builtin -fno-tree-loop-distribute-patterns \
-fno-stack-protector -fno-asynchronous-unwind-tables -Wall"
build_c() {
  _bc_out=$1
  shift
  _bc_cc=gcc
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
  # shellcheck disable=SC2086
  ${CC:-$_bc_cc} $CFLAGS_SYLZ $_bc_extra -c src/sylzc.c -o "$_bc_out/sylzc.o"
}
