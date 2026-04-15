# syc — bitácora del proyecto

Compresor/archivador en Rust, optimizado para hardware modesto
(AMD A8-6600K, 4 cores, 7 GiB RAM, Debian 13).

## Estado actual: v0.2.0 — dict training + long mode + solid sort

### Misiones encaradas (en orden cronológico)

1. **Empatar a `zstd + tar`** — logrado: ganamos ratio (~17% mejor) y velocidad
   de compresión; descompresión ~6% debajo (cerrable con buffers más grandes).
2. **Ganar a FreeArc/ARC.exe en ratio + descompresión** — objetivo actual.
   - Descompresión: ✅ **12× más rápido** que ARC en todos los niveles
   - Ratio: 🚧 ganamos -m1, -m2, -m3, -m4. Perdiendo por ~6-12% vs -m5, -mx.

### Decisiones de diseño

- **Formato propio `SYC2`** (antes `SYC1`): `[magic 4B][u32 dict_len][dict bytes][zstd stream]`.
  El stream es un solid: concatenación de `[header][body]...` comprimida de
  corrido. Sin índice final → unpack streaming puro, sin seek.
- **Compresión**: zstd (crate `zstd` 0.13 con features `zstdmt` + `zdict_builder`).
  - Long-range matching (`window_log=27`, 128 MiB) **por defecto** — encuentra
    matches entre archivos (análogo al REP de FreeArc).
  - Flag `-nolong` para desactivar (si se prioriza RAM baja en decomp).
- **Solid sort** (idea 7-zip/RAR): antes de streamear, ordenamos entradas por
  `(KindRank, extensión, tamaño, path)`. Archivos similares quedan contiguos
  → mejor compartición del diccionario móvil de zstd. `sort_by_cached_key`
  para evitar N·log(N) syscalls.
- **Dict training opcional** (`-dict`): entrena un zstd-dict con muestras del
  input (hasta 16 MiB totales, ≤256 KiB por archivo) y lo embebe en la preamble.
  Mejora 15-30% en datasets de muchos archivos pequeños similares.
  Descompresión: **igual de rápida** (dict se carga 1 vez al abrir).
  No siempre ayuda (archivos grandes/variados pierden vs el costo de ~110 KiB
  del dict) → opt-in.
- **Buffers**: CHUNK = 256 KiB, IO_BUF = 1 MiB (`BufReader`/`BufWriter`).
- **Seguridad**: `sanitize_rel` rechaza paths absolutos y `..` al desempacar.
- **Symlinks/permisos Unix** preservados.

### CLI (inspirada en zpaqfranz)

Parser propio (`src/cli.rs`), **sin dependencia de clap**.

```
Core : a, x, l, t
Info : h, v
```

- `syc a <archive> <src...> [-level N] [-threads N] [-dict] [-store] ...`
- `syc x <archive> -to <dir> [-force] [-summary] [-verbose]`
- `syc l <archive> [-find TEXT] [-summary]`
- `syc t <archive> [-verbose]`

Switches: `-level N`, `-threads N`, `-to DIR`, `-find TEXT`,
`-verbose`, `-summary`, `-force`, `-store`, `-nochecksum`,
`-nosort` (desactiva solid sort), `-dict` (activa dict training),
`-nolong` (desactiva long-range matching).

### Benchmarks

#### vs ARC.exe (FreeArc 0.67.1 vía wine), dataset `/usr/share/doc/python3.13` (68.2 MiB, 1502 archivos)

| Método | Ratio | Decomp speed |
|--------|-------|--------------|
| ARC -m1 | 0.228 | 24.0 MiB/s |
| ARC -m2 | 0.173 | — |
| ARC -m3 | 0.166 | 21.1 MiB/s |
| ARC -m4 | 0.162 | — |
| ARC -m5 | 0.146 | 8.4 MiB/s |
| ARC -m6..m9 | 0.139 | ~7.4 MiB/s (plateau) |
| **ARC -mx (tope)** | **0.139** | 7.3 MiB/s |
| syc -l3  (long) | 0.202 | 220 MiB/s |
| syc -l9  (long) | 0.183 | 227 MiB/s |
| syc -l15 (long) | 0.172 | 227 MiB/s |
| syc -l19 (long) | 0.155 | 207 MiB/s (48s comp, inviable) |

→ **Descompresión: 12-38× más rápido que ARC.**
→ **Ratio: ganamos hasta ARC -m4; perdemos ~6% vs -m5, ~12% vs -mx.**

#### vs `tar + zstd` (para referencia), dataset `/usr/share/doc` (412 MiB, 54k archivos)

| Modo | syc (long+sort) | tar+zstd | Δ |
|------|-----------------|----------|---|
| l3/j4 | 0.204, 150 MiB/s | 0.243, 186 MiB/s | syc ratio +17% |
| l9/j4 | 0.184, 57 MiB/s | 0.224, 80 MiB/s | syc ratio +18% |
| l19/j4 | 0.155 | 0.211 | syc ratio +27% |

### Escala de niveles 0..10 (v0.3.0)

Se remapeó la escala de syc de `1..22` (crudo de zstd) a `0..10` — más
cercana a la de ARC (`m1..m9`). Default: `-l5`.

| syc | zstd | Ratio  | Tiempo | Gana vs ARC |
|-----|------|--------|--------|-------------|
| l0  | -5   | 0.2774 | 0.34s  | — (draft/rápido) |
| l1  |  1   | 0.2142 | 0.35s  | m1 |
| l2  |  3   | 0.2020 | 0.43s  | m1 |
| l3  |  5   | 0.1940 | 0.65s  | m1 |
| l4  |  7   | 0.1860 | 0.86s  | m1 |
| l5  |  9   | 0.1826 | 1.16s  | m1 (default, sweet spot) |
| l6  | 11   | 0.1788 | 2.60s  | m1 |
| l7  | 13   | 0.1748 | 3.84s  | m1 |
| l8  | 15   | 0.1720 | 7.44s  | m1, **m2** |
| l9  | 17   | 0.1644 | 14.08s | m1, m2, **m3** |
| l10 | 19   | 0.1546 | 48.68s | m1, m2, m3, **m4** |

**m5 (0.146) queda fuera de alcance con backend zstd** — brecha estructural:
ARC usa LZMA/PPMD, syc usa zstd puro. Cerrar el gap requeriría cambiar
backend, lo que rompería el formato SYC2 y mataría la ventaja de decomp (24-33× más rápido que ARC).

### Ideas que no funcionaron (documentado para no repetir)

- **BufReader en cadena sobre el Decoder de zstd**: doble buffer → más memcpy,
  descompresión **más lenta** (196→175 MiB/s). Revertido.
- **Dict training siempre activo**: en datasets de archivos grandes y variados
  (python docs, avg 46 KiB/archivo), el dict (~110 KiB) es overhead neto.
  Pasa a **opt-in** (`-dict`).
- **Sort sin cachear la key**: `sort_by` llama `symlink_metadata` 2× por
  comparación → 860k syscalls en un dataset de 54k entradas. Fix:
  `sort_by_cached_key`.

### Dependencias
- `zstd` 0.13 + features `zstdmt` + `zdict_builder`
- `walkdir` 2.5
- `anyhow` 1.0
- `byteorder` 1.5
- `crc32fast` 1.5 (reservado, aún no cableado)

### Pendientes para cerrar el último gap vs ARC -m5/-mx

- [ ] **Chunk-level dedup (FastCDC)**: idea de restic/borg/zpaqfranz. Quita
      redundancia inter-archivo antes del compresor. Dominante cuando hay
      versiones de los mismos datos.
- [ ] **BCJ/exe filter** para binarios ELF/PE (idea LZMA2/7z). Transforma
      jumps relativos → absolutos para mejor compresión.
- [ ] **Delta filter** para WAV/multimedia (idea FreeArc mm).
- [ ] **Per-extension routing**: zstd para texto, compresor distinto para
      multimedia. Hoy usamos zstd para todo.
- [ ] **Dict adaptativo**: entrenar, hacer trial-compress sobre sample,
      guardar sólo si mejora neta. Evita el regression observado en python3.13.
- [ ] Checksum CRC32 por archivo.
- [ ] Tests de integración en `tests/`.
- [ ] **Port Dict (FreeArc)**: substitución de palabras inglesas comunes.
      Probablemente 3–5% de mejora en texto (lo que separa `0.1479` de `0.139`).
      1439 líneas C++ en `/tmp/freearc-ref/Compression/Dict/dict.cpp`.
- [ ] **Port LZP (FreeArc)**: predictor largo alcance. ~323 líneas C++ en
      `/tmp/freearc-ref/Compression/LZP/C_LZP.cpp`. Complementario a Dict.

### Estado al 2026-04-15 (bench limpio, `bench_arc.sh`, re-confirmado post BCJ)

**Ratio sobre `python3.13` docs (71 MiB, 1502 archivos):**

| Nivel | syc ratio | ARC ratio | Veredicto ratio |
|-------|-----------|-----------|-----------------|
| l1/m1 | 0.214     | 0.228     | ✅ syc −6%      |
| l3/m3 | 0.155     | 0.166     | ✅ syc −7%      |
| l5/m5 | 0.148     | 0.146     | ❌ syc +1.3%    |
| l9/m9 | 0.148     | 0.139     | ❌ syc +6.5%    |

- Ganamos ratio hasta `m4`. A partir de `m5` ARC activa su preset de texto
  (`dict + lzp + ppmd`) y nos saca ventaja.
- `l5..l10` saturan en `0.1479` — LZMA puro al máximo no basta.

**Velocidad compresión (MiB/s sobre mismos datos):**

| Nivel | syc   | ARC  | ventaja syc |
|-------|-------|------|-------------|
| l1/m1 | 207   | 19   | 10.9× más rápido |
| l3/m3 | 1.5   | 18   | ARC 12×  (ARC usa su preset rápido; syc l3 = zstd l19 que es lento) |
| l5/m5 | 1.5   | 6.7  | ARC 4.5× (xz preset 9 single-thread en 71 MiB, el gate MT no se activa por ser chico) |

**Velocidad descompresión (nuestra gran ventaja):**

| Nivel | syc MiB/s | ARC MiB/s | ventaja syc |
|-------|-----------|-----------|-------------|
| l1/m1 | 213       | 22        | **9.7×**    |
| l3/m3 | 207       | 20        | **10.4×**   |
| l5/m5 | 124       | 8         | **14.9×**   |
| l9/m9 | 129       | 7         | **17.9×**   |

- Descompresión syc es dominante en todos los niveles (~10–18× ARC).
- La rapidez sale de: zstd para niveles bajos; xz decoder liblzma (C) single-threaded pero con window_log corto y sin stages de Dict/LZP que sí tendría que invertir ARC.

**Big bench `test-files.tar` (2.29 GB):**
- `l5` sin preproc, t=1: ratio 0.6652, 1363s
- `l5` con SREP, t=1:    ratio 0.6603
- `l5` con SREP + MT (t=4, auto): ratio **0.6604**, **461s** (2.96× más rápido, mismo ratio)
- SREP ahorra ~11 MB (0.5%). Heurística actualizada: `>1 GiB → SREP`, si no → nada. REP quedó deshabilitado por default: en subset 200 MiB aparece 0.1% peor y 35% más lento (el dict LZMA de 128 MiB ya hace ese trabajo).

**Level table test-files.tar (2.29 GB, tar de binarios, con MT auto):**

| Nivel | Ratio | Tiempo |
|-------|-------|--------|
| l1    | 0.7980 | 11s  |
| l3    | 0.6823 | 435s |
| l5    | 0.6604 | 456s |
| l9    | 0.6599 | 666s |

- l5 casi empata con l9 (0.6604 vs 0.6599), 45% más rápido → l5 es el sweet-spot en datos binarios grandes.
- l1 (zstd) baseline brutalmente rápido pero ratio de ~0.80.

**LZMA multi-thread (nuevo 2026-04-15):**
Activado automáticamente con `-threads >1` cuando `total_raw ≥ 2 × block_size`
(`block_size = 3 × dict` por default, override vía `SYC_LZMA_BLOCK_MIB`).
- python docs 71 MiB: gate lo mantiene single-thread → ratio 0.1479 intacto
- subset 200 MiB: gate lo mantiene single-thread (no daña ratio)
- subset 600 MiB: t=1 → 0.6598 en 372s; t=4 → 0.6601 en 149s (**2.5× más rápido**, 0.05% ratio)
- Rationale: MT parte el stream en bloques independientes; cada bloque reinicia el estado LZMA → hit pequeño al ratio. Gate en `2 × block_size` garantiza que datasets que caben en un solo bloque no pierden nada.

**PPMd7 (via `ppmd-rust 1.4`):**
- Backend integrado pero **opt-in** vía `SYC_BACKEND=ppmd`. Razón: PPMd solo
  no supera a LZMA tuneado en este dataset (0.1487 @ order=16/mem=512M vs
  LZMA 0.1479). La ventaja real viene de Dict+LZP+PPMd combinados (receta
  FreeArc `m5t`/`m9t`), aún sin portar. Plumbing listo para cuando lleguen.

**Formato actualizado:**
- Preamble ahora incluye `(u8 order, u32 mem_mb)` al final cuando `backend = 2` (Ppmd).
- `Backend::Ppmd = 2` añadido al enum. Compatible con archivos SYC4 anteriores
  mientras el backend no sea Ppmd.

**BCJ filter (2026-04-15):**
- Selección: `-bcj TYPE` CLI flag → `SYC_BCJ=...` env → **auto-detect**.
  Tipos: `x86|arm|armt|ia64|sparc|off`.
- Sin cambio de formato: xz block header guarda el filter chain → decoder
  re-descubre la cadena automáticamente al desempacar.
- Auto-detect (solo LZMA backend): samplea hasta 64 archivos regulares,
  cuenta los que empiezan con ELF x86/x86_64 (magic + e_machine 0x03/0x3E)
  o PE (`MZ`); si ≥30 % → `Bcj::X86`. Con ≥4 samples mínimo (evita disparar
  en inputs tiny).
- Medición directorio ELF (120 binarios de `/usr/bin`, 24 MiB, l5):
  - auto / `-bcj x86`: `ratio 0.2591`, 14.4s
  - `-bcj off`:        `ratio 0.2689`, 15.5s → **−3.6 % tamaño, −7 % tiempo**
- Medición texto (python docs 71 MiB, l5):
  - auto no dispara (samples no son ELF): `ratio 0.14787`, 46.4s — intacto.
- Roundtrip verificado (integration test `roundtrip_lzma_bcj_x86`).

## LZP preprocessor (tarea #2, 2026-04-15)

- Context-hash predictor (CTX=8, HASH_BITS=20, MIN_MATCH=32) — emite
  (literal_run, match_len) sin offset; decoder recupera la fuente desde el
  mismo hash table reconstruido.
- Flag `-lzp`. Bit `PREPROC_LZP = 0x80` en el preamble (sin bytes extra).
- Incompatible con REP/SREP, `-delta`, `-route`, `-append`. Gate requiere
  backend LZMA o PPMd (`preproc_eligible`).
- Roundtrip cubierto: `roundtrip_lzp_lzma`, `roundtrip_lzp_ppmd`.

### Medición (log corpus 7.8 MiB, texto repetitivo)

| config       | tamaño     | Δ vs base | walltime |
|--------------|------------|-----------|----------|
| lzma -m 6    | 321.386 B  | —         | 9.4 s    |
| lzma + lzp   | 343.142 B  | **+6.8 %**| 2.9 s (×3.3 más rápido) |
| ppmd         | 555.614 B  | —         | 0.24 s   |
| ppmd + lzp   | 427.116 B  | **−23 %** | 0.40 s   |

- **PPMd + LZP** es la combo clásica: captura matches largos que el modelo
  de contexto chico de PPMd no ve. Ideal para `-mx` cuando esté listo.
- **LZMA + LZP** es trade-off velocidad/ratio, no ganancia neta; útil si el
  walltime pesa más que los últimos bytes.
- Corpora pequeños (<2 MiB) no tienen suficiente repetición a larga
  distancia para pagar el overhead de varints — LZP queda neutral o con
  pérdida leve. Por eso queda opt-in (sin auto-selección).

### Cómo compilar / ejecutar

```bash
. "$HOME/.cargo/env"
cargo build --release
./target/release/syc a data.syc ./mydir -level 19 -threads 4 -summary
./target/release/syc x data.syc -to ./restored
./target/release/syc t data.syc
```

### Benchmark harness

- `bench.sh <dir>` — syc vs tar+zstd (compresión + descompresión)
- `bench_arc.sh <dir>` — syc vs ARC.exe (FreeArc vía wine), -m1..-m9 + -mx

## FastCDC chunk-level dedup (tarea #3, 2026-04-15)

FastCDC Gear-hash chunker (MIN=2 KiB, AVG=8 KiB, MAX=64 KiB) + registry global de chunks por archivo (`xxh3_64`). Boundaries content-defined → files con overlap desplazado comparten chunks.

- Flag `-fastcdc`. Nueva `EntryKind::ChunkedFile = 4`: body = secuencia de `(varint header, payload?)` registros; `header&1==0` → inline, `header&1==1` → backref a chunk previo.
- Sin bit en preamble: formato legible por decoders antiguos sólo si no hay ChunkedFile en el archivo.
- Registry global por frame (shared across entries). DecodeRegistry mantiene `Vec<Vec<u8>>` en memoria — MVP, sin eviction.
- Incompatibilidades: `-append`, `-delta` (error duro al combinar).

### Medición (3 ficheros con overlaps desplazados, 8 MiB total)

| backend      | plain       | +fastcdc    | delta      | walltime |
|--------------|-------------|-------------|------------|----------|
| zstd -l 1    | 4.20 MB     | 4.20 MB     | ≈0%        | similar  |
| ppmd -l 5    | 6.41 MB     | 4.27 MB     | **−33%**   | 2.0× faster |

- **zstd/lzma solid** ya deduplican vía su ventana grande (128 MiB lzma, 128 MiB zstd long); CDC no añade valor.
- **ppmd** no tiene match-finder: CDC aporta el ahorro entero. Combo ganadora para texto/logs grandes con PPMd.
- Para archivos > dict window (multi-GB), CDC también ayuda a LZMA.

## v0.1.12 — progress: CountingWriter sobre BufWriter + flushing pad (2026-04-16)

**Bug visible en v0.1.11**: durante `flushing...` el counter `comp` quedaba en `22 B` (preámbulo) durante minutos, y al final aparecían pixeles `B/s \` colgando a la derecha de la línea.

**Causa #1**: `CountingWriter` estaba *bajo* `BufWriter` (1 MiB), así que solo veía bytes cuando el buffer hacía flush — y con LZMA-MT, los workers acumulan todo el output internamente y solo emiten en bloques al `finish()`, llegando a BufWriter en ráfagas.

**Fix #1**: subir `CountingWriter` *encima* del `BufWriter` (entre encoder y buffer). Ahora cuenta cuando el encoder emite, sin esperar a que se llene el buffer. Cambio mecánico en los call sites de zstd que usaban `bw.into_inner()` — añadido `CountingWriter::into_inner()` y un paso extra de unwrap.

**Causa #2**: el `format!()` del flushing era ~75 chars vs ~82 del render normal, dejando residuo a la derecha.

**Fix #2**: construir la línea con `format!` y luego `eprint!("\r{:<82}", line)` para garantizar ancho fijo.

**Lo que sigue siendo limitación, no bug**: con `xz2` LZMA-MT (`-m 5 -threads N`), los workers buffean TODO el input antes de emitir. Resultado: la barra muestra input subiendo rápido pero `comp` queda casi 0 hasta que `enc.finish()` libera los workers. Test 700 MB texto+random: input 0→97 % en ~2 s, luego flushing 2:47 con `comp` saltando 1.28 MB → 17 → 106 → 177 → 240 → 327 → 425 → 476 MB en el último segundo. Esto es xz2 MT, no nuestra capa. Con zstd MT o LZMA single-thread la barra avanza sincronizada.

## v0.1.11 — progress: i_scritti + projection (2026-04-16)

Cierro la pieza que quedaba de la rama "rica" del `print_progress` de zpaqfranz: la columna de bytes ya escritos al archivo y la proyección del tamaño final.

- **`CountingWriter<W>` en `src/main.rs`**: wrap entre `BufWriter` y la salida (File / ChunkedWriter / OpenOptions append). Cada `write` exitoso suma a un `Arc<AtomicU64>`. Vive *bajo* el BufWriter para contar bytes que efectivamente bajaron al sink (no los que el buffer aún tiene), análogo a `g_scritti+= n` en zpaqfranz tras flush MT (`zpaqfranz.cpp:71474`).
- **`Progress::set_compressed_counter(Arc<AtomicU64>)`** (`src/progress.rs`): el ticker lee el counter en cada render. Cuando hay counter + `total > 0`, formato cambia de `(in)=>(total)` a `(in)->(comp)=>(proj)` con `proj = comp * total / done` (i128 intermedio para evitar overflow temprano cuando comp ≫ done). El ticker de `flushing()` también muestra `(in)->(comp)` para que el comprimido siga subiendo durante `encoder.finish()`.
- **Cableado**: ambos paths de pack — `cmd_add` (con/sin route, route-append comparte el mismo Arc) y `cmd_append`. Extract/test no usan el counter (input-driven, ya tienen total stub a 0).

Verificado con script-PTY sobre 250 MB (200 MB urandom + 50 MB ceros, lzma -m 5 -threads 4): la proyección converge a 190.16 MB durante el run y el resultado real es 190.75 MB.

## v0.1.10 — progress format zpaqfranz + spinner + flushing live ticker (2026-04-16)

`src/progress.rs` reescrito:

- Formato igual a `zpaqfranz.cpp:63480`: `       PCT.PP% HH:MM:SS  (done)=>(total) rate/s spin`. Sin label "pack"/"extract", percent con 2 decimales, paréntesis y `=>` flecha como zpaqfranz. Cuando `total == 0` (extract/test) percent colapsa a `--` y se omite el `=>`.
- Spinner `|/-\` rota cada tick. Razón: aunque la ratio de rendering subió a 8 Hz (125 ms vs 250 ms), jobs sub-segundo todavía se sentían "estaticos" — el spinner garantiza percepción de movimiento incluso cuando los bytes apenas cambian entre frames.
- `flushing()` ahora spawn-ea un thread que re-renderiza cada 125 ms con elapsed actualizado + spinner. Bug: el LZMA-MT `enc.finish()` con archivos grandes bloqueaba el main thread por minutos sin updates a la barra (input ya consumido, no más `advance()`); el ticker independiente mantiene la línea viva. Stop signalizado vía `Arc<AtomicBool>`, joineado en `finish()` y `Drop`.
- Throttle subido a 8 Hz (era 4 Hz). zpaqfranz usa 1 Hz pero ahí se nota más estatica en jobs cortos.

## v0.1.9 — chunk rotation = zpaqfranz semantics + Drop announce (2026-04-16)

**ChunkedWriter::write** ahora replica la mecánica de `myfwrite` en zpaqfranz (`zpaqfranz.cpp:44083`): escribe el buffer entero a la parte actual y rota DESPUÉS si `written_in_part > chunk_size`. Las partes terminan ligeramente más grandes que `-chunk SIZE` (por hasta un upstream-write, típicamente decenas/cientos de KiB), pero cada rotación cae en una frontera de write limpia en vez de partir un buffer al medio. Decisión del usuario: "no importa la exactitud", queremos clon de zpaqfranz.

**Drop impl en ChunkedWriter**: la última parte parcial nunca cruza el umbral, por lo que `rotate()` no la anuncia. Un `Drop` que ahora cierra la parte actual e imprime su `wrote …` real (best-effort, sin propagar errores). El Box<dyn Write> en `cmd_add` muere después de `encoder.finish()`, por lo que `written_in_part` es el tamaño real en disco.

**Padding del `wrote …`**: subido a 80 chars con `\r{:<80}\n` para barrer cualquier residuo de la barra de progreso a la derecha. Antes se veían pixeles tipo "1.47 GB/s" pegados al final del `wrote a.syc.001 …`.

Comparativa práctica con `zpaqfranz a 'z_????.zpaq' payload.bin -chunk 12MB`: ambos producen 4 partes (3 llenas + 1 parcial) sobre 50 MB de input. Tamaños syc 13.2 MiB (overshoot ~1.2 MiB del buffer de zstd-MT), zpaqfranz 12.06 MiB (overshoot 64 KiB del bloque interno de zpaq).

## v0.1.8 — `-chunk XMB/GB` size suffixes + part rotation log (tareas #35-36, 2026-04-16)

**#35 Size suffix parser** (`src/cli.rs`):
- Opts.`chunk_mib` → `chunk_bytes`. Nuevo `parse_size(&str) → Result<u64>` aceptado por `-chunk`, `-minsize`, `-maxsize`.
- Sufijos soportados: `B`, `K/KB/KiB`, `M/MB/MiB`, `G/GB/GiB`, `T/TB/TiB`. Valores decimales OK (`1.5GB`).
- **Decisión**: KB/MB/GB son 1024-base (igual que zpaqfranz y nuestro `human_si`), no decimal-1000. Así `-chunk 10MB` → 10·1024·1024 → echo "10.00 MB" coincide con lo que escribió el usuario. Antes (interpretación decimal): "10MB" → 10MB exactos pero la barra decía "9.54 MB".
- Errores hablados: `size '10X': expected digits or N{K,M,G,T}[{B,iB}]`.

**#36 Polish: print resolved chunk + part rotation log** (`src/main.rs`):
- Pre-pack: `chunk   10.00 MB  (output split into a.syc.001, .002, ...)` — el usuario ve qué interpretó syc antes de comprometerse.
- Por cada parte completada, `ChunkedWriter::rotate` imprime `wrote   a.syc.001 (10.00 MB)` (sobreescribiendo la línea de progreso, con padding para ocultar restos).
- Smoke test: 50 MB de urandom + `-chunk 10MB -m 0` → 5 partes de 10·1024·1024 + remainder, sin bytes perdidos.

## v0.1.7 — per-chunk progress en pack_entry (tarea #34, 2026-04-16)

**#34 Per-chunk progress** (`src/archive.rs`, `src/fastcdc.rs`, `src/main.rs`):
- `pack_entry` y `pack_entry_chunked` reciben `on_bytes: &mut dyn FnMut(u64)` y lo invocan **dentro del read loop** de cada chunk (no una sola vez por entry al final).
- Bug report: en single-file de 1.75 GB, la barra saltaba directo de `Scanned` a `flushing...` porque `pack_entry` consumía el archivo entero antes de devolver y `progress.advance(meta.len())` corría una sola vez.
- También aplicado al body del FastCDC chunker (`pack_chunked_body`) para coherencia.

## v0.1.6 — auto-MT zstd + banner trim (tareas #31-32, 2026-04-16)

**#31 Auto-MT zstd cuando el input pesa** (`src/main.rs`):
- Cuando `opts.threads == 0` (no se pasó `-threads`) **y** `total_raw >= 256 MiB`, syc autodetecta cores con `std::thread::available_parallelism()`, los capa a 8 y los inyecta a `enc.multithread()` de zstd y al `MtStreamBuilder` de LZMA.
- Reportado por usuario: en un i9-11900K (16 threads), `syc a -m 1 data.tar` corría a 1 hilo (`1T` en el footer) — FreeArc usaba 4 cores en el mismo input. Ratio nuestro era mejor pero wall-time perdía por falta de paralelismo.
- Cap a 8: zstd-MT escala sublinear pasados 8 workers en hardware típico.
- Threshold a 256 MiB: por debajo de eso el spawn + setup se come la ganancia.

**#32 Banner simplificado** (`src/cli.rs`):
- Antes: `syc v0.1.4-zstd,lzma,ppmd,xattr,HW xxh3/blake3,(2026-04-16)` — un trabalengua de feature flags que el usuario nunca leyó.
- Después: `syc v0.1.6 - 2026-04-16 - by Yade Bravo (YadeWira)` — versión, fecha, autor. Las features quedan implícitas (siempre están todas compiladas) o se descubren con `syc h`.

## Polish iteration v0.1.5 (tareas #27-29, 2026-04-17)

Tres pulidas en pos del clon zpaqfranz — uno nació de un bug report real del usuario en Windows:

**#27 Atomic .tmp write + rename on pack** (`src/main.rs`):
- `open_output` ahora escribe a `<archive>.tmp` cuando el destino es un archivo regular (stdout y `-chunk` quedan como estaban).
- Tras `prog.finish()` y después del route-append, `std::fs::rename(tmp, archive)` promueve el archivo a su nombre final.
- Si el usuario cancela (Ctrl-C) o el compresor falla, el `.tmp` queda tirado y el nombre final jamás se crea. Antes: el `.syc` quedaba truncado y aparentemente válido.
- Route-append (`opts.route`) ahora abre `tmp_path` (no el path final).
- Reportado por el usuario tras cancelar un pack de 1.75 GiB en Windows: "lo cancele y termina asi, y deja un archivo incompleto".

**#28 Flushing... indicator** (`src/progress.rs` + `pack_all`):
- `Progress::flushing()` sobreescribe la línea de progreso con `"{label} flushing... HH:MM:SS {done}"` en stderr.
- Llamado al final de `pack_all()`, justo antes del `encoder.finish()` de cada arm (LZMA-MT puede tardar decenas de segundos vaciando el stream).
- El `prog.finish()` subsiguiente reemplaza la línea por las stats normales + newline, así que visualmente sólo aparece durante el flush real.

**#29 Yellow `warn_line` helper + footer** (`src/color.rs`):
- `warn_line(msg)` → `"00042: msg"` amarillo, contador global independiente del de errores.
- `warn_count()` público para el footer.
- En éxito con warnings: footer amarillo `(N warnings)`; en error con warnings: `(N errors, M warnings, with errors)`.
- Sitios convertidos: `cmd_add_append` (xattrs/hash/comment locked por preamble), `snapshot::take_snapshot` (btrfs/zfs/unsupported fallbacks).

## zpaqfranz clone UX (tareas #24-26, 2026-04-16)

Tres toques para que `syc` se sienta como un clon de zpaqfranz — apariencia + semántica de salida:

**#25 Numeric error prefixes** (`src/color.rs`):
- `err_line(msg)` → `"00042! msg"` en rojo, contador global monotónico (`AtomicU32`).
- Resumen final: `(N errors, with errors)` en vez de `(with errors)`.
- Sustituye los eprintln rojos de `miss/diff/syc: <err>/exec hook failed`.

**#26 Scan phase summary** (`src/main.rs`):
- Después de `collect_entries + apply_selectors + solid_sort`, imprime `Scanned N file/s HH:MM:SS B (X.XX KB)` antes de `Creating archive at offset 0 + 0`.
- No bloqueante — es una línea resumen post-walk, no un progress bar en vivo. `walkdir` síncrono sobre corpora modestos (target hardware: A8-6600K) suele correr en <1s; real-time throttling sería overkill.

**#24 List layout con mtime** (`src/archive.rs`, `src/main.rs`):
- **Wire format bump: `SYC4` → `SYC5`**. El byte de flags ya estaba lleno (0x01..0x80 todos tomados), así que no cabía un FEATURE_MTIME — magic bump fue la vía limpia.
- `EntryHeader` gana `mtime: i64` (UNIX seconds). Writers emiten siempre v5; readers aceptan ambos.
- `read_preamble` devuelve `(ArchiveVersion, Backend, ...)`; `EntryHeader::read_from(r, version)` lee mtime sólo si v5 (v4 → 0).
- Extract restaura mtime via `utimensat` (best-effort; dirs quedan pisados por writes subsecuentes, symlinks con AT_SYMLINK_NOFOLLOW).
- `cmd_list` cambia de `Size | Flag | Name` a:
  ```
  Date       Time                  Size  Ratio  Name
  2026-04-15 19:22:40               0  <dir>  sub
  2026-04-15 19:22:40              47         a.txt
  ```
  No tenemos per-entry compressed size, así que la columna Ratio lleva tag tipado (`<dir>`/`<lnk>`/`<hln>`/`<cdc>`) en lugar de un porcentaje falso. Dir cyan, link/hardlink amarillo, cdc verde.

Test nuevo: `roundtrip_mtime` (stamp vía `utimensat`, pack, extract, verify exact seconds).

## FS snapshot (tarea #14, 2026-04-15)

`src/snapshot.rs` — snapshot atómico opcional antes de archivar (`-snapshot`).

- Detección por `statfs` magic: btrfs (0x9123683E) y zfs (0x2FC12FC1).
- btrfs: `btrfs subvolume snapshot -r <src> <parent>/.syc-snap-<pid>-<ns>`; cleanup via `btrfs subvolume delete` en Drop.
- zfs: `df --output=source` → dataset; `zfs snapshot ds@tag`; navegación via `<mountpoint>/.zfs/snapshot/tag/<rel>`; cleanup via `zfs destroy`.
- Otras FS (ext4/xfs/tmpfs/fuse): aviso y fallback a live tree.
- Cualquier fallo (no-root, src no subvolume, binarios ausentes) → fallback con aviso; nunca error duro.
- `SnapshotGuard` RAII: effective_src usado durante archivar, cleanup al salir de cmd_add.

## Dict preprocessor (tarea #1, pending design)

FreeArc Dict sustituye palabras frecuentes inglesas/multi-idioma por códigos cortos (1..3 bytes) antes de LZMA/PPMd. Combinado con LZP da el empujón que lleva ARC -mx a ganarle a LZMA puro en texto. ~1500 líneas C++ en `Compression/Dict/C_Dict.cpp` (ref no disponible localmente; consultar repo FreeArc upstream).

**Diseño propuesto (no implementado, pendiente para 0.1.4):**

1. **Tabla de tokens**: diccionario estático de N tokens (palabras comunes + whitespace patterns), ordenado por frecuencia descendente. Publicado como bytes embebidos en el binario (p. ej. `include_bytes!("dict_en.bin")`).
2. **Encoder**: scan secuencial byte a byte con un trie. Cuando matchea un token, emite `0xFx yy` (2B) o `0xFF xx yy` (3B) según índice. Ventaja real: tokens de 6..12 chars → 2..3 bytes.
3. **Decoder**: stateless, reemplaza códigos por tokens.
4. **Wire format**: bit `PREPROC_DICT = 0x40` en preamble (libre, REP=0x04, SREP=0x08, LZP=0x80 ya tomados; 0x40 disponible).
5. **Gating**: auto-on si total_raw > 4 MiB y >30 % del sample muestra tokens del diccionario. Incompat con binarios (detectar por BCJ auto-detect).
6. **Sinergia**: debería apilar como `Dict → LZP → LZMA/PPMd` (primero sustituye tokens, después LZP encuentra repeticiones entre sustituciones, después el backend).

**Por qué quedó para doc**: el trabajo crítico es la **selección y curación de la tabla** (FreeArc tiene versiones separadas EN/RU/EN+symbols), no el encoder. Un port a ciegas sin medir contra corpora específicos tendería a empatar o perder vs LZP solo. Mejor abordar cuando haya corpus de referencia y tiempo de medición iterativa.
