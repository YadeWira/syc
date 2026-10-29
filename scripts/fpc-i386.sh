#!/bin/bash
# Installs a 32-bit (i386) Linux Free Pascal from Debian's packages into
# "$1" (default /tmp/fpc-i386) and writes "$1/fpc", a wrapper that adds the
# unit search paths. Used to build syc for Linux x86 (CI and by hand);
# needs curl and dpkg-deb. The compiler is itself an i386 program: the
# host needs 32-bit glibc (gcc-multilib brings it).
set -e
PREFIX=${1:-/tmp/fpc-i386}
ROOT="$PREFIX/root"
DEBS="$PREFIX/debs"
VER=3.2.2+dfsg-46
mkdir -p "$ROOT" "$DEBS"
for p in fp-compiler-3.2.2 fp-units-rtl-3.2.2 fp-units-base-3.2.2; do
  deb="$DEBS/$p.deb"
  if [ ! -s "$deb" ]; then
    curl -sS --fail --max-time 120 -o "$deb" \
      "https://deb.debian.org/debian/pool/main/f/fpc/${p}_${VER}_i386.deb"
  fi
  dpkg-deb -x "$deb" "$ROOT"
done
FPCROOT="$ROOT/usr/lib/i386-linux-gnu/fpc/3.2.2"
cat > "$PREFIX/fpc" <<WRAPPER
#!/bin/bash
ROOT="$FPCROOT"
ARGS=(-n -Fl/usr/lib32 "-Fl\$(dirname "\$(gcc -m32 -print-file-name=crtbegin.o)")")
for d in "\$ROOT"/units/i386-linux/*; do [ -d "\$d" ] && ARGS+=("-Fu\$d"); done
exec "\$ROOT/ppc386" "\${ARGS[@]}" "\$@"
WRAPPER
chmod +x "$PREFIX/fpc"
echo "$PREFIX/fpc"
