/*
packJPG v4.0 (04/21/2026)
~~~~~~~~~~~~~~~~~~~~~~~~~~

packJPG is a compression program specially designed for further
compression of JPEG images without causing any further loss. Typically
it reduces the file size of a JPEG file by 20%.


LGPL v3 license and special permissions
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

All programs in this package are free software; you can redistribute 
them and/or modify them under the terms of the GNU Lesser General Public 
License as published by the Free Software Foundation; either version 3 
of the License, or (at your option) any later version. 

The package is distributed in the hope that it will be useful, but 
WITHOUT ANY WARRANTY; without even the implied warranty of 
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser 
General Public License for more details at 
http://www.gnu.org/copyleft/lgpl.html. 

If the LGPL v3 license is not compatible with your software project you 
might contact us and ask for a special permission to use the packJPG 
library under different conditions. In any case, usage of the packJPG 
algorithm under the LGPL v3 or above is highly advised and special 
permissions will only be given where necessary on a case by case basis. 
This offer is aimed mainly at closed source freeware developers seeking 
to add PJG support to their software projects. 

Copyright 2006...2014 by HTW Aalen University and Matthias Stirner.


Usage of packJPG
~~~~~~~~~~~~~~~~

JPEG files are compressed and PJG files are decompressed using this
command:

 "packJPG [file(s)]"

packJPG recognizes file types on its own and decides whether to compress
(JPG) or decompress (PJG). For unrecognized file types no action is
taken. Files are recognized by content, not by extension.

packJPG supports wildcards like "*.*" and drag and drop of multiple 
files. Filenames for output files are created automatically. In default
mode, files are never overwritten. If a filename is already in use,
packJPG creates a new filename by adding underscores.

If "-" is used as a filename input from stdin is assumed and output is
written to stdout. This can be useful for example if jpegtran is to be
used as a preprocessor.

Usage examples:

 "packJPG *.pjg"
 "packJPG lena.jpg"
 "packJPG kodim??.jpg"
 "packJPG - < sail.pjg > sail.jpg"


Command line switches
~~~~~~~~~~~~~~~~~~~~~

 -ver  verify files after processing
 -v?   level of verbosity; 0,1 or 2 is allowed (default 0)
 -np   no pause after processing files
 -o    overwrite existing files
 -p    proceed on warnings
 -d    discard meta-info

By default, compression is cancelled on warnings. If warnings are 
skipped by using "-p", most files with warnings can also be compressed, 
but JPEG files reconstructed from PJG files might not be bitwise 
identical with the original JPEG files. There won't be any loss to 
image data or quality however.

Unnecessary meta information can be discarded using "-d". This reduces 
compressed files' sizes. Be warned though, reconstructed files won't be 
bitwise identical with the original files and meta information will be 
lost forever. As with "-p" there won't be any loss to image data or 
quality. 

There is no known case in which a file compressed by packJPG (without 
the "-p" option, see above) couldn't be reconstructed to exactly the 
state it was before. If you want an additional layer of safety you can 
also use the verify option "-ver". In this mode, files are compressed, 
then decompressed and the decompressed file compared to the original 
file. If this test doesn't pass there will be an error message and the 
compressed file won't be written to the drive. 

Please note that the "-ver" option should never be used in conjunction 
with the "-d" and/or "-p" options. As stated above, the "-p" and "-d" 
options will most likely lead to reconstructed JPG files not being 
bitwise identical to the original JPG files. In turn, the verification 
process may fail on various files although nothing actually went wrong. 

Usage examples:

 "packJPG -v1 -o baboon.pjg"
 "packJPG -ver lena.jpg"
 "packJPG -d tiffany.jpg"
 "packJPG -p *.jpg"


Known Limitations 
~~~~~~~~~~~~~~~~~ 

packJPG is a compression program specially for JPEG files, so it doesn't 
compress other file types.

packJPG has low error tolerance. JPEG files might not work with packJPG 
even if they work perfectly with other image processing software. The 
command line switch "-p" can be used to increase error tolerance and 
compatibility.

If you try to drag and drop to many files at once, there might be a 
windowed error message about missing privileges. In that case you can 
try it again with less files or consider using the command prompt. 
packJPG has been tested to work perfectly with thousands of files from 
the command line. This issue also happens with drag and drop in other 
applications, so it might not be a limitation of packJPG but a 
limitation of Windows.

Compressed PJG files are not compatible between different packJPG 
versions. You will get an error message if you try to decompress PJG 
files with a different version than the one used for compression. You 
may download older versions of packJPG from:
http://www.elektronik.htw-aalen.de/packJPG/binaries/old/


Open source release / developer info
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The packJPG source codes is found inside the "source" subdirectory. 
Additional documents aimed to developers, containing detailed 
instructions on compiling the source code and using special 
functionality, are included in the "packJPG" subdirectory. 
 

History
~~~~~~~

v1.9a (04/20/2007) (non public)
 - first released version
 - only for testing purposes

v2.0  (05/28/2007) (public)
 - first public version of packJPG
 - minor improvements to overall compression
 - minor bugfixes

v2.2  (08/05/2007) (public)
 - around 40% faster compression & decompression
 - major improvements to overall compression (around 2% on average)
 - reading from stdin, writing to stdout
 - smaller executable
 - minor bugfixes
 - various minor improvements
 
v2.3  (09/18/2007) (public)
 - compatibility with JPEG progressive mode
 - compatibility with JPEG extended sequential mode
 - compatibility with the CMYK color space
 - compatibility with older CPUs
 - around 15% faster compression & decompression 
 - new switch: [-d] (discard meta-info)
 - various bugfixes

v2.3a (11/21/2007) (public)
 - crash issue with certain images fixed
 - compatibility with packJPG v2.3 maintained

v2.3b (12/20/2007) (public)
 - some minor errors in the packJPG library fixed
 - compatibility with packJPG v2.3 maintained
 
v2.4 (03/24/2010) (public)
 - major improvements (1%...2%) to overall compression
 - around 10% faster compression & decompression
 - major improvements to JPG compatibility
 - size of executable reduced to ~33%
 - new switch: [-ver] (verify file after processing)
 - new switch: [-np] (no pause after processing)
 - new progress bar output mode
 - arithmetic coding routines rewritten from scratch
 - various smaller improvements to numerous to list here
 - new SFX (self extracting) archive format
 
v2.5 (11/11/2011) (public)
 - improvements (~0.5%) to overall compression
 - several minor bugfixes
 - major code cleanup
 - removed packJPX from the package
 - added packARC to the package
 - packJPG is now open source!
 
v2.5a (11/21/11) (public)
 - source code compatibility improvements (Gerhard Seelmann)
 - avoid some compiler warnings (Gerhard Seelmann)
 - source code clean up (Gerhard Seelmann)
 
v2.5b (01/27/12) (public)
 - further removal of redundant code
 - some fixes for the packJPG static library
 - compiler fix for Mac OS (thanks to Sergio Lopez)
 - improved compression ratio calculation
 - eliminated the need for temp files
 
v2.5c (04/13/12) (public)
 - various source code optimizations
 
v2.5d (07/03/12) (public)
 - fixed a rare bug with progressive JPEG
 
v2.5e (07/03/12) (public)
 - some minor source code optimizations
 - changed packJPG licensing to LGPL
 - moved packARC to a separate package
 
v2.5f (02/24/13) (public)
 - fixed a minor bug in the JPG parser (thanks to Stephan Busch)
 
v2.5g (09/14/13) (public)
 - fixed a rare crash bug with manipulated JPEG files
 
v2.5h (12/07/13) (public)
 - added a warning for inefficient huffman coding (thanks to Moinak Ghosh)
 
v2.5i (12/26/13) (public)
 - fixed possible crash with malformed JPEG (thanks to Moinak Ghosh)
 
v2.5j (01/15/14) (public)
 - various source code optimizations (using cppcheck)

v2.5k (01/22/16) (public)
 - Updated contact info
 - fixed a minor bug

v2.6 (03/19/25) (public)
 - Ported to C++17 (replaced std::experimental::filesystem)
 - Removed GCC-only -fsched-spec-load flag from Makefile (clang compatibility)
 - Fixed segfault: current_order going negative in model_s (issue #41/#35)
 - Fixed alloc-dealloc mismatch: BitWriter::get_c_bytes() now uses malloc (issue #31)
 - Fixed memory leaks: early returns in read_jpeg() now clean up hdrw/huffw/segment (issue #34)
 - Fixed undefined behaviour: DEVLI macro with s=0 caused negative shift (UB)
 - Fixed global-buffer-overflow: errormessage buffer 128→512, sprintf→snprintf (issue #30)
 - Fixed heap-buffer-overflow: shift_context() now clamps c to max_context-1 (issue #33)
 - Fixed global-buffer-overflow: qtable_id validated against 4 before indexing qtables[] (issue #32)
 - Removed unused dead code: plocoi, median_int, median_float, ccode field in ArithmeticEncoder
 - Performance: BitWriter and MemoryWriter now pre-reserve buffer using input size hint
 - Performance: scoreboard reset uses memset instead of std::fill
 - Performance: exclude_symbols() bulk-sets scoreboard with memset
 - New flag: -od<path> writes output files to specified directory (issue #37)
 - Maintainer: Yade Bravo (https://github.com/YadeWira/packJPG)

v2.7 (03/20/2026) (public)
 - Windows: wildcard expansion in initialize_options (*.jpg, *.pjg now work from cmd.exe)
 - Build: fixed icon embedding for Windows x64/x86 (windres -O coff)
 - Multi-threaded batch processing via -th<N> flag (0=auto, detects cores)
 - Thread-safe output buffering in process_ui (per-file atomic console writes)

v3.0 (03/30/2026) (public)
 - new flag: [-sfth] parallel single-file compression using 3 threads (Y/Cb/Cr)
   ~25-30% faster on 3+ thread machines; ratio preserved (~0.01% delta)
   generates new .pjg format (0x01 marker); requires v3.0+ to decompress
   both encode and decode are parallelized
 - warning shown when -sfth is used with fewer than 3 detected threads
 - optimal batch+single-file usage: -th<N/3> -sfth on an N-thread machine
 - fixed: [a] mode no longer creates empty .pjg files for skipped JPEGs
 - fixed: [x] mode no longer creates empty .jpg files for skipped PJGs
 - fixed: skipped files in a/x mode are now silent (no warning printed)
 - fixed: unrecognized flags (e.g. -th=) now print a clear error message
   instead of being silently treated as filenames
 - fixed: jpgfilesize/pjgfilesize changed from int to int64_t — prevents
   0.00% ratio reporting on large files (>2GB) and on 32-bit builds
 - fixed: -th0 on x86 now caps at 2 threads to prevent OOM on large images;
   x64/Linux still uses all available cores
 - fixed: progress counter now shows only processable files (e.g. "2 of 2"
   instead of "5 of 5" when 3 of the 5 files are skipped)
 - fixed: verbose mode (-v1/-v2) no longer prints header lines for skipped
   files — only processed files appear in the output
 - fixed: skipped files (wrong type) no longer print warnings in MT mode
 - fixed: directories from wildcard expansion (e.g. * expanding PANA/) are
   now silently ignored; use -r explicitly to recurse into subdirectories
 - fixed: decompressing -sfth files with -ver incorrectly reported "file sizes
   do not match" even when the output was bit-for-bit correct; verify now
   re-encodes using the same format (sfth or standard) as the original PJG
 - fixed: 'mix' mode warning incorrectly referenced '-c' (non-existent flag);
   message now correctly reads 'a' (compress only)
 - fixed: 'list' subcommand displayed 'v0.1' for -sfth files instead of the
   correct version; sfth files now show 'v3.0 (parallel)'
 - maintainer: Yade Bravo (https://github.com/YadeWira/packJPG)

v2.9 (03/23/2026) (public)
 - new flag: [-c] compress only — skip PJG files silently
 - new flag: [-x] decompress only — skip JPG files silently
 - new flag: [-module] machine-friendly output: OK/ERROR + elapsed seconds
 - fixed: crash with accented/special characters in path (Windows drag & drop)
 - fixed: file count wrong with wildcard expansion on Windows
 - fixed: comp. ratio 0.00%% with mixed file types
 - fixed: -module now added to help screen
 - fixed: -list no longer creates empty output files
 - fixed: MT progress bar stray characters
 - help screen now shows program description
 - unknown file types now skipped silently (no error shown for .exe, .png, etc.)
 - maintainer: Yade Bravo (https://github.com/YadeWira/packJPG)

v2.8b (03/23/2026) (public)
 - fixed: crash with accented/special characters in path (Windows drag & drop)
   uses safe_path() helper: CP_ACP -> wchar_t -> filesystem::path on Windows
 - fixed: all filesystem operations wrapped in try/catch to prevent file destruction
 - fixed: comp. ratio now shows correctly regardless of mixed file types
 - new flag: [-c] compress only — skip PJG files silently
 - new flag: [-x] decompress only — skip JPG files silently
 - maintainer: Yade Bravo (https://github.com/YadeWira/packJPG)

v2.8a (03/22/2026) (public)
 - fixed: Windows wildcard expansion buffer overflow (file count wrong with *.jpg)
 - fixed: Windows wildcard now uses Wide API (FindFirstFileW) for accented filenames
 - fixed: recursive mode (-r) now only collects .jpg/.jpeg/.pjg files
 - fixed: wildcard expansion now skips directories
 - minimum supported Windows version: 7 (dropped XP)
 - maintainer: Yade Bravo (https://github.com/YadeWira/packJPG)

v2.8 (03/21/2026) (public)
 - Improved sign context in AC high encoder/decoder: adds top-left diagonal neighbor
   (mod_sgn 9→27 states), yielding ~0.04% better compression ratio
 - New flag: [-r] recurse into subdirectories
 - New flag: [-list] display PJG file info without decompressing
 - New flag: [-dry] dry run: simulate compression without writing output files
 - MT mode: Ctrl+C (SIGINT) stops workers cleanly and removes partial output files
 - [-od<path>] now creates output directory automatically if missing
 - Progress bar in multi-threaded mode: errors print cleanly above bar
 - Summary now reports speed in MB/s instead of kbyte/s
 - Thread info shows detected core count: "Using N of M detected thread(s)"
 - Fixed: -list no longer creates empty .jpg output files
 - Fixed: final MT progress bar no longer shows stray characters
 - maintainer: Yade Bravo (https://github.com/YadeWira/packJPG)


Acknowledgements
~~~~~~~~~~~~~~~~

packJPG is the result of countless hours of research and development. It
is part of my final year project for Hochschule Aalen.

Prof. Dr. Gerhard Seelmann from Hochschule Aalen supported my
development of packJPG with his extensive knowledge in the field of data
compression. Without his advice, packJPG would not be possible.

The official developer blog for packJPG is hosted by encode.ru.

packJPG logo and icon are designed by Michael Kaufmann.


Contact
~~~~~~~

The official developer blog for packJPG:
 http://packjpg.encode.ru/
 
For questions and bug reports:
 https://github.com/YadeWira/packJPG/issues


____________________________________
packJPG by Matthias Stirner, 01/2016
*/

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <cmath>
#include <ctime>
#include <memory>
#include <stdexcept>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <future>
#include <filesystem>
#include <csignal>

#if defined(_WIN32) || defined(WIN32)
	#include <windows.h>
#else
	#include <unistd.h>
#endif

// ─── Color support ────────────────────────────────────────────────────────────
// ANSI escape codes — empty strings when colors are disabled.
// Call init_colors() once at startup (no-op in library builds).
#if !defined(BUILD_LIB)
static bool use_color    = false;
static bool force_no_color = false;  // set by --no-color flag

#define COL_RESET   (use_color ? "\033[0m"   : "")
#define COL_CYAN    (use_color ? "\033[36m"  : "")
#define COL_GRAY    (use_color ? "\033[90m"  : "")
#define COL_BRED    (use_color ? "\033[1;31m": "")
#define COL_BGREEN  (use_color ? "\033[1;32m": "")
#define COL_BYELLOW (use_color ? "\033[1;33m": "")
#define COL_BCYAN   (use_color ? "\033[1;36m": "")

// Bullet separator in program header.
// On Windows, use the CP-1252 byte \x95 for cmd.exe portability across
// codepages. On Linux/macOS, use proper UTF-8 (E2 80 A2).
#if defined(_WIN32) || defined(WIN32)
    #define BULLET "\x95"
#else
    #define BULLET "\xe2\x80\xa2"
#endif

static void init_colors( void )
{
#if defined(_WIN32) || defined(WIN32)
	// Switch console to UTF-8 so multi-byte characters (•, ✓, ░, █ …) render
	// correctly regardless of --no-color. No-op when output isn't a console.
	SetConsoleOutputCP( CP_UTF8 );
	SetConsoleCP( CP_UTF8 );
	if ( force_no_color ) return;
	HANDLE h = GetStdHandle( STD_OUTPUT_HANDLE );
	if ( h == INVALID_HANDLE_VALUE ) return;
	DWORD mode = 0;
	if ( !GetConsoleMode( h, &mode ) ) return;
	// ENABLE_VIRTUAL_TERMINAL_PROCESSING (0x0004) — Windows 10+. source/ targets
	// Win10+ only; sourcelegacy/ handles Win7/XP via xp_compat.h with a
	// different ANSI strategy.
	if ( SetConsoleMode( h, mode | 0x0004 ) )
		use_color = true;
#else
	if ( force_no_color ) return;
	// Enable colors if stdout is a real terminal and NO_COLOR env is not set.
	if ( isatty( fileno( stdout ) ) && getenv( "NO_COLOR" ) == NULL )
		use_color = true;
#endif
}
#endif
// ─────────────────────────────────────────────────────────────────────────────

// Helper: convert a char* path (CP_ACP on Windows, UTF-8 on Linux) to
// std::filesystem::path safely — avoids filesystem_error on accented chars.
// CLI-only (not used from the library entry points).
#if !defined( BUILD_LIB )
static std::filesystem::path safe_path( const char* s )
{
	if ( s == NULL ) return std::filesystem::path();
	#if defined(_WIN32) || defined(WIN32)
	// argv on Windows is CP_ACP — convert to wchar_t first
	wchar_t wbuf[32768];
	if ( MultiByteToWideChar( CP_ACP, 0, s, -1, wbuf, 32768 ) > 0 )
		return std::filesystem::path( wbuf );
	// fallback: let filesystem try (may throw on bad chars)
	#endif
	return std::filesystem::path( s );
}
#endif // BUILD_LIB

#include "bitops.h"
#include "aricoder.h"
#include "pjpgtbl.h"
#include "dct8x8.h"

#if defined BUILD_DLL // define BUILD_LIB from the compiler options if you want to compile a DLL!
	#define BUILD_LIB
#endif

#if defined BUILD_LIB // define BUILD_LIB as compiler option if you want to compile a library!
	#include "packjpglib.h"
#endif

#define INTERN static
#define THREAD_LOCAL static thread_local

#define INIT_MODEL_S(a,b,c) new model_s( a, b, c, 255 )
#define INIT_MODEL_B(a,b)   new model_b( a, b, 255 )

// #define USE_PLOCOI // uncomment to use loco-i predictor instead of 1DDCT predictor
// #define DEV_BUILD // uncomment to include developer functions
// #define DEV_INFOS // uncomment to include developer information

#define QUANT(cm,bp)	( cmpnfo[cm].qtable[ bp ] )
#define MAX_V(cm,bp)	( ( QUANT(cm,bp) > 0 ) ? ( ( freqmax[bp] + QUANT(cm,bp) - 1 ) /  QUANT(cm,bp) ) : 0 )
// #define QUN_V(v,cm,bp)	( ( QUANT(cm,bp) > 0 ) ? ( ( v > 0 ) ? ( v + (QUANT(cm,bp)/2) ) /  QUANT(cm,bp) : ( v - (QUANT(cm,bp)/2) ) /  QUANT(cm,bp) ) : 0 )

#define ENVLI(s,v)		( ( v > 0 ) ? v : ( v - 1 ) + ( 1 << s ) )
// Fix UB: when s==0 the original expression evaluates 1<<(s-1) = 1<<(-1) which
// is undefined behaviour. When s==0 there are no extra bits to read, so n==0
// and the coefficient must be 0 — return 0 directly in that case.
#define DEVLI(s,n)		( (s) == 0 ? 0 : ( ( (n) >= ( 1 << ((s) - 1) ) ) ? (n) : (n) + 1 - ( 1 << (s) ) ) )
#define E_ENVLI(s,v)	( v - ( 1 << s ) )
#define E_DEVLI(s,n)	( n + ( 1 << s ) )

#define ABS(v1)			( (v1 < 0) ? -v1 : v1 )
#define ABSDIFF(v1,v2)	( (v1 > v2) ? (v1 - v2) : (v2 - v1) )
#define IPOS(w,v,h)		( ( v * w ) + h )
#define NPOS(n1,n2,p)	( ( ( p / n1 ) * n2 ) + ( p % n1 ) )
#define ROUND_F(v1)		( (v1 < 0) ? (int) (v1 - 0.5) : (int) (v1 + 0.5) )
#define DIV_INT(v1,v2)	( (v1 < 0) ? (v1 - (v2>>1)) / v2 : (v1 + (v2>>1)) / v2 )
#define B_SHORT(v1,v2)	( ( ((int) v1) << 8 ) + ((int) v2) )
#define BITLEN1024P(v)	( pbitlen_0_1024[ v ] )
#define BITLEN2048N(v)	( (pbitlen_n2048_2047+2048)[ v ] )
#define CLAMPED(l,h,v)	( ( v < l ) ? l : ( v > h ) ? h : v )

#define MEM_ERRMSG	"out of memory error"
#define FRD_ERRMSG	"could not read file / file not found: %s"
#define FWR_ERRMSG	"could not write file / file write-protected: %s"
// Fix #30: increased from 128 to 512 — errormessage overflowed with long
// filenames or exception messages (e.what() could write 315+ bytes per ASAN).
#define MSG_SIZE	512
#define BARLEN		36

// special realloc with guaranteed free() of previous memory
static inline void* frealloc( void* ptr, size_t size ) {
	void* n_ptr = realloc( ptr, (size) ? size : 1 );
	if ( n_ptr == NULL ) free( ptr );
	return n_ptr;
}



/* -----------------------------------------------
	struct declarations
	----------------------------------------------- */

struct componentInfo {
	unsigned short* qtable; // quantization table
	int huffdc; // no of huffman table (DC)
	int huffac; // no of huffman table (AC)
	int sfv; // sample factor vertical
	int sfh; // sample factor horizontal	
	int mbs; // blocks in mcu
	int bcv; // block count vertical (interleaved)
	int bch; // block count horizontal (interleaved)
	int bc;  // block count (all) (interleaved)
	int ncv; // block count vertical (non interleaved)
	int nch; // block count horizontal (non interleaved)
	int nc;  // block count (all) (non interleaved)
	int sid; // statistical identity
	int jid; // jpeg internal id
};

struct huffCodes {
	unsigned short cval[ 256 ];
	unsigned short clen[ 256 ];
	unsigned short max_eobrun;
};

struct huffTree {
	unsigned short l[ 256 ];
	unsigned short r[ 256 ];
};


/* -----------------------------------------------
	function declarations: main interface
	----------------------------------------------- */
#if !defined( BUILD_LIB )
INTERN void initialize_options( int argc, char** argv );
INTERN void process_ui( void );
INTERN inline const char* get_status( bool (*function)() );
INTERN void show_help( void );
#endif
INTERN void process_file( void );
INTERN void execute( bool (*function)() );


/* -----------------------------------------------
	function declarations: main functions
	----------------------------------------------- */
#if !defined( BUILD_LIB )
INTERN bool check_file( void );
INTERN bool swap_streams( void );
INTERN bool compare_output( void );
#endif
INTERN bool reset_buffers( void );
INTERN bool read_jpeg( void );
INTERN bool merge_jpeg( void );
INTERN bool decode_jpeg( void );
INTERN bool recode_jpeg( void );
INTERN bool adapt_icos( void );
INTERN bool predict_dc( void );
INTERN bool unpredict_dc( void );
INTERN bool check_value_range( void );
INTERN bool calc_zdst_lists( void );
INTERN bool pack_pjg( void );
INTERN bool unpack_pjg( void );


/* -----------------------------------------------
	function declarations: jpeg-specific
	----------------------------------------------- */

INTERN bool jpg_setup_imginfo( void );
INTERN bool jpg_parse_jfif( unsigned char type, unsigned int len, unsigned char* segment );
INTERN bool jpg_rebuild_header( void );

INTERN int jpg_decode_block_seq( BitReader* huffr, huffTree* dctree, huffTree* actree, short* block );
INTERN int jpg_encode_block_seq( BitWriter* huffw, huffCodes* dctbl, huffCodes* actbl, short* block );

INTERN int jpg_decode_dc_prg_fs( BitReader* huffr, huffTree* dctree, short* block );
INTERN int jpg_encode_dc_prg_fs( BitWriter* huffw, huffCodes* dctbl, short* block );
INTERN int jpg_decode_ac_prg_fs( BitReader* huffr, huffTree* actree, short* block,
						int* eobrun, int from, int to );
INTERN int jpg_encode_ac_prg_fs( BitWriter* huffw, huffCodes* actbl, short* block,
						int* eobrun, int from, int to );

INTERN int jpg_decode_dc_prg_sa( BitReader* huffr, short* block );
INTERN int jpg_encode_dc_prg_sa( BitWriter* huffw, short* block );
INTERN int jpg_decode_ac_prg_sa( BitReader* huffr, huffTree* actree, short* block,
						int* eobrun, int from, int to );
INTERN int jpg_encode_ac_prg_sa( BitWriter* huffw, std::vector<std::uint8_t>& storw, huffCodes* actbl,
						short* block, int* eobrun, int from, int to );

INTERN int jpg_decode_eobrun_sa( BitReader* huffr, short* block, int* /*eobrun*/, int from, int to );
INTERN int jpg_encode_eobrun( BitWriter* huffw, huffCodes* actbl, int* eobrun );
INTERN int jpg_encode_crbits( BitWriter* huffw, std::vector<std::uint8_t>& storw );

INTERN int jpg_next_huffcode( BitReader *huffw, huffTree *ctree );
INTERN int jpg_next_mcupos( int* mcu, int* cmp, int* csc, int* sub, int* dpos, int* rstw );
INTERN int jpg_next_mcuposn( int* cmp, int* dpos, int* rstw );
INTERN int jpg_skip_eobrun( int* cmp, int* dpos, int* rstw, int* eobrun );

INTERN void jpg_build_huffcodes( unsigned char *clen, unsigned char *cval,
				huffCodes *hc, huffTree *ht );

/* -----------------------------------------------
	function declarations: pjg-specific
	----------------------------------------------- */
	
INTERN bool pjg_encode_zstscan( ArithmeticEncoder* enc, int cmp );
INTERN bool pjg_encode_zdst_high( ArithmeticEncoder* enc, int cmp );
INTERN bool pjg_encode_zdst_low( ArithmeticEncoder* enc, int cmp );
INTERN bool pjg_encode_dc( ArithmeticEncoder* enc, int cmp );
INTERN bool pjg_encode_ac_high( ArithmeticEncoder* enc, int cmp );
INTERN bool pjg_encode_ac_low( ArithmeticEncoder* enc, int cmp );
INTERN bool pjg_encode_generic( ArithmeticEncoder* enc, unsigned char* data, int len );
INTERN bool pjg_encode_bit( ArithmeticEncoder* enc, unsigned char bit );

INTERN bool pjg_decode_zstscan( ArithmeticDecoder* dec, int cmp );
INTERN bool pjg_decode_zdst_high( ArithmeticDecoder* dec, int cmp );
INTERN bool pjg_decode_zdst_low( ArithmeticDecoder* dec, int cmp );
INTERN bool pjg_decode_dc( ArithmeticDecoder* dec, int cmp );
INTERN bool pjg_decode_ac_high( ArithmeticDecoder* dec, int cmp );
INTERN bool pjg_decode_ac_low( ArithmeticDecoder* dec, int cmp );
INTERN bool pjg_decode_generic( ArithmeticDecoder* dec, unsigned char** data, int* len );
INTERN bool pjg_decode_bit( ArithmeticDecoder* dec, unsigned char* bit );

INTERN void pjg_get_zerosort_scan( unsigned char* sv, int cmp );
INTERN bool pjg_optimize_header( void );
INTERN bool pjg_unoptimize_header( void );

INTERN void pjg_aavrg_prepare( unsigned short** abs_coeffs, int* weights, unsigned short* abs_store, int cmp );
INTERN int pjg_aavrg_context( unsigned short** abs_coeffs, int* weights, int pos, int p_y, int p_x, int r_x );
INTERN int pjg_lakh_context( signed short** coeffs_x, signed short** coeffs_a, int* pred_cf, int pos );
INTERN void get_context_nnb( int pos, int w, int *a, int *b );


/* -----------------------------------------------
	function declarations: DCT
	----------------------------------------------- */

#if !defined(BUILD_LIB) && defined(DEV_BUILD)
INTERN int idct_2d_fst_8x8( int cmp, int dpos, int ix, int iy );
#endif
INTERN int idct_2d_fst_1x8( int cmp, int dpos, int /*ix*/, int iy );
INTERN int idct_2d_fst_8x1( int cmp, int dpos, int ix, int /*iy*/ );


/* -----------------------------------------------
	function declarations: prediction
	----------------------------------------------- */

#if defined( USE_PLOCOI )
INTERN int dc_coll_predictor( int cmp, int dpos );
#else
INTERN int dc_1ddct_predictor( int cmp, int dpos );
#endif


/* -----------------------------------------------
	function declarations: miscelaneous helpers
	----------------------------------------------- */
#if !defined( BUILD_LIB )
INTERN inline void progress_bar( int current, int last );
INTERN inline char* create_filename( const char* base, const char* extension );
INTERN inline char* unique_filename( const char* base, const char* extension );
INTERN inline void set_extension( char* filename, const char* extension );
INTERN inline void add_underscore( char* filename );
#endif
INTERN inline bool file_exists( const char* filename );


/* -----------------------------------------------
	function declarations: developers functions
	----------------------------------------------- */

// these are developers functions, they are not needed
// in any way to compress jpg or decompress pjg
#if !defined(BUILD_LIB) && defined(DEV_BUILD)
INTERN int collmode = 0; // write mode for collections: 0 -> std, 1 -> dhf, 2 -> squ, 3 -> unc
INTERN bool dump_hdr( void );
INTERN bool dump_huf( void );
INTERN bool dump_coll( void );
INTERN bool dump_zdst( void );
INTERN bool dump_file( const char* base, const char* ext, void* data, int bpv, int size );
INTERN bool dump_errfile( void );
INTERN bool dump_info( void );
INTERN bool dump_dist( void );
INTERN bool dump_pgm( void );
#endif

#if !defined(BUILD_LIB)
INTERN bool list_pjg( void );
INTERN bool list_jpg( void );
#endif


/* -----------------------------------------------
	global variables: library only variables
	----------------------------------------------- */
#if defined(BUILD_LIB)
// THREAD_LOCAL so concurrent pjglib_convert_* calls from different threads
// each maintain their own init/convert stream-type pairing.
THREAD_LOCAL int lib_in_type  = -1;
THREAD_LOCAL int lib_out_type = -1;
#endif


/* -----------------------------------------------
	global variables: data storage
	----------------------------------------------- */

THREAD_LOCAL unsigned short qtables[4][64];				// quantization tables
THREAD_LOCAL huffCodes      hcodes[2][4];				// huffman codes
THREAD_LOCAL huffTree       htrees[2][4];				// huffman decoding trees
THREAD_LOCAL unsigned char  htset[2][4];					// 1 if huffman table is set

THREAD_LOCAL unsigned char* grbgdata		   =   NULL;	// garbage data
THREAD_LOCAL unsigned char* hdrdata          =   NULL;   // header data
THREAD_LOCAL unsigned char* huffdata         =   NULL;   // huffman coded data
THREAD_LOCAL int            hufs             =    0  ;   // size of huffman data
THREAD_LOCAL int            hdrs             =    0  ;   // size of header
THREAD_LOCAL int            grbs             =    0  ;   // size of garbage

THREAD_LOCAL unsigned int*  rstp             =   NULL;   // restart markers positions in huffdata
THREAD_LOCAL unsigned int*  scnp             =   NULL;   // scan start positions in huffdata
THREAD_LOCAL int            rstc             =    0  ;   // count of restart markers
THREAD_LOCAL int            scnc             =    0  ;   // count of scans
THREAD_LOCAL int            rsti             =    0  ;   // restart interval
THREAD_LOCAL char           padbit           =    -1 ;   // padbit (for huffman coding)
THREAD_LOCAL unsigned char* rst_err          =   NULL;   // number of wrong-set RST markers per scan

THREAD_LOCAL unsigned char* zdstdata[4]      = { NULL }; // zero distribution (# of non-zeroes) lists (for higher 7x7 block)
THREAD_LOCAL unsigned char* eobxhigh[4]      = { NULL }; // eob in x direction (for higher 7x7 block)
THREAD_LOCAL unsigned char* eobyhigh[4]      = { NULL }; // eob in y direction (for higher 7x7 block)
THREAD_LOCAL unsigned char* zdstxlow[4]		= { NULL }; // # of non zeroes for first row
THREAD_LOCAL unsigned char* zdstylow[4]		= { NULL }; // # of non zeroes for first collumn
THREAD_LOCAL signed short*  colldata[4][64]  = {{NULL}}; // collection sorted DCT coefficients

THREAD_LOCAL unsigned char* freqscan[4]      = { NULL }; // optimized order for frequency scans (only pointers to scans)
THREAD_LOCAL unsigned char  zsrtscan[4][64];				// zero optimized frequency scan

THREAD_LOCAL int adpt_idct_8x8[ 4 ][ 8 * 8 * 8 * 8 ];	// precalculated/adapted values for idct (8x8)
THREAD_LOCAL int adpt_idct_1x8[ 4 ][ 1 * 1 * 8 * 8 ];	// precalculated/adapted values for idct (1x8)
THREAD_LOCAL int adpt_idct_8x1[ 4 ][ 8 * 8 * 1 * 1 ];	// precalculated/adapted values for idct (8x1)


/* -----------------------------------------------
	global variables: info about image
	----------------------------------------------- */

// seperate info for each color component
THREAD_LOCAL componentInfo cmpnfo[ 4 ];

THREAD_LOCAL int cmpc        = 0; // component count
THREAD_LOCAL int imgwidth    = 0; // width of image
THREAD_LOCAL int imgheight   = 0; // height of image

THREAD_LOCAL int sfhm        = 0; // max horizontal sample factor
THREAD_LOCAL int sfvm        = 0; // max verical sample factor
THREAD_LOCAL int mcuv        = 0; // mcus per line
THREAD_LOCAL int mcuh        = 0; // mcus per collumn
THREAD_LOCAL int mcuc        = 0; // count of mcus


/* -----------------------------------------------
	global variables: info about current scan
	----------------------------------------------- */

THREAD_LOCAL int cs_cmpc      =   0  ; // component count in current scan
THREAD_LOCAL int cs_cmp[ 4 ]  = { 0 }; // component numbers  in current scan
THREAD_LOCAL int cs_from      =   0  ; // begin - band of current scan ( inclusive )
THREAD_LOCAL int cs_to        =   0  ; // end - band of current scan ( inclusive )
THREAD_LOCAL int cs_sah       =   0  ; // successive approximation bit pos high
THREAD_LOCAL int cs_sal       =   0  ; // successive approximation bit pos low
	

/* -----------------------------------------------
	global variables: info about files
	----------------------------------------------- */
	
THREAD_LOCAL char*  jpgfilename = NULL;	// name of JPEG file
THREAD_LOCAL char*  pjgfilename = NULL;	// name of PJG file
THREAD_LOCAL int64_t jpgfilesize;			// size of JPEG file
THREAD_LOCAL int64_t pjgfilesize;			// size of PJG file
THREAD_LOCAL int    jpegtype = 0;			// type of JPEG coding: 0->unknown, 1->sequential, 2->progressive
THREAD_LOCAL int    filetype;				// type of current file
THREAD_LOCAL std::unique_ptr<Reader> str_in;	// input stream
THREAD_LOCAL std::unique_ptr<Writer> str_out;	// output stream

#if !defined(BUILD_LIB)
THREAD_LOCAL std::unique_ptr<Reader> str_str;	// storage stream

INTERN char** filelist = NULL;		// list of files to process 
INTERN int    file_cnt = 0;			// count of files in list
INTERN int    file_proc_cnt = 0;		// count of processable files (JPG/PJG)
INTERN int    file_proc_no  = 0;		// current processable file number (live)
THREAD_LOCAL int    file_no  = 0;			// number of current file

INTERN char** err_list = NULL;		// list of error messages 
INTERN int*   err_tp   = NULL;		// list of error types
#endif

#if defined(DEV_INFOS)
INTERN int    dev_size_hdr      = 0;
INTERN int    dev_size_cmp[ 4 ] = { 0 };
INTERN int    dev_size_zsr[ 4 ] = { 0 };
INTERN int    dev_size_dc[ 4 ]  = { 0 };
INTERN int    dev_size_ach[ 4 ] = { 0 };
INTERN int    dev_size_acl[ 4 ] = { 0 };
INTERN int    dev_size_zdh[ 4 ] = { 0 };
INTERN int    dev_size_zdl[ 4 ] = { 0 };
#endif


/* -----------------------------------------------
	global variables: messages
	----------------------------------------------- */

THREAD_LOCAL char errormessage [ MSG_SIZE ];
THREAD_LOCAL bool (*errorfunction)();
THREAD_LOCAL int  errorlevel;
// meaning of errorlevel:
// -1 -> wrong input
// 0 -> no error
// 1 -> warning
// 2 -> fatal error


/* -----------------------------------------------
	global variables: settings
	----------------------------------------------- */

// sfth_mode / decoded_from_sfth must exist in BUILD_LIB too: they are
// referenced from pack_pjg/unpack_pjg which run in both CLI and lib paths.
// Both THREAD_LOCAL: process_file() perturbs sfth_mode around pack_pjg during
// verification, so a non-TL value would race across MT CLI workers and across
// concurrent pjglib_convert_* calls from host threads.
THREAD_LOCAL bool sfth_mode  = false;	// -sfth: use 3 cores for single-file pre-pack
THREAD_LOCAL bool decoded_from_sfth = false; // set by unpack_pjg when 0x01 marker found
// On-disk format version seen by the decoder (set by unpack_pjg after reading
// the version byte). THREAD_LOCAL because MT batch workers each decode their
// own file.
THREAD_LOCAL unsigned char format_version_read = 0;
// Cross-component prediction switch, set explicitly by each pack/unpack entry
// point before pjg_encode_*/pjg_decode_* is called. Always false inside sfth
// parallel workers (to preserve component parallelism). Sequential path sets
// it true unconditionally now (no -legacy flag, only one accepted format).
THREAD_LOCAL bool pjg_use_crosscomp_now = false;
// v4.0b feature flag: diagonal/anti-diagonal DC neighbor context. Encoder
// always writes this on (preceded by sub-marker 0x02 in the file header).
// Decoder sets it true only when it sees the 0x02 sub-marker — files generated
// by v4.0/v4.0a (no marker) decode with this off, preserving backward compat.
// THREAD_LOCAL like pjg_use_crosscomp_now: sfth workers each set their own.
THREAD_LOCAL bool pjg_use_diag_dc_now = false;

#if !defined( BUILD_LIB )
INTERN int  verbosity  =  0;	// level of verbosity (0=table, -1=progress bar via -vp)
INTERN bool overwrite  = false;	// overwrite files yes / no
INTERN bool wait_exit  = true;	// pause after finished yes / no
INTERN bool dry_run    = false;	// simulate without writing output yes/no
INTERN bool compress_only   = false;	// -c: only compress JPG files
INTERN bool decompress_only = false;	// -x: only decompress PJG files
INTERN bool mix_mode        = false;	// -mix: auto-detect with warning
INTERN bool subcmd_given    = false;	// a subcommand was explicitly provided
INTERN bool module_mode = false;	// machine-friendly output: OK/ERROR + time only
INTERN char* outdir    = NULL;	// output directory (NULL = same as input)
INTERN int  verify_lv  = 0;		// verification level ( none (0), simple (1), detailed output (2) )
INTERN int  err_tol    = 1;		// error threshold ( proceed on warnings yes (2) / no (1) )
INTERN bool disc_meta  = false;	// discard meta-info yes / no

INTERN bool developer  = false;	// allow developers functions yes/no
INTERN bool recursive  = false;	// recurse into subdirectories yes/no
THREAD_LOCAL bool auto_set   = true;	// automatic find best settings yes/no
THREAD_LOCAL int  action = A_COMPRESS;// what to do with JPEG/PJG files

INTERN FILE*  msgout   = stdout;// stream for output of messages
INTERN int    num_threads = 1;  // number of worker threads (1 = single-threaded)
INTERN std::atomic<int> g_files_done{0}; // files completed so far (for MT progress bar)
INTERN std::atomic<bool> g_interrupted{false}; // set by SIGINT handler
THREAD_LOCAL std::string tl_ui_buf;     // per-thread output buffer for MT mode
THREAD_LOCAL bool   pipe_on  = false;	// use stdin/stdout instead of filelist
#else
INTERN int  err_tol    = 1;		// error threshold ( proceed on warnings yes (2) / no (1) )
INTERN bool disc_meta  = false;	// discard meta-info yes / no
THREAD_LOCAL bool auto_set   = true;	// automatic find best settings yes/no
// THREAD_LOCAL: pjglib_convert_stream2mem writes action on every call; concurrent
// host threads calling the lib would race on this otherwise.
THREAD_LOCAL int  action = A_COMPRESS;// what to do with JPEG/PJG files
#endif

THREAD_LOCAL unsigned char nois_trs[ 4 ] = {6,6,6,6}; // bit pattern noise threshold
THREAD_LOCAL unsigned char segm_cnt[ 4 ] = {10,10,10,10}; // number of segments

// ─── -sfth intra-file pre-pack parallelism ───────────────────────────────────
// Snapshots all THREAD_LOCAL image pointers from the calling thread and returns
// a lambda that installs them into whichever thread calls it.
static std::function<void()> make_tls_init()
{
	struct Snap {
		unsigned char* zdstdata[4], *eobxhigh[4], *eobyhigh[4];
		unsigned char* zdstxlow[4], *zdstylow[4];
		signed short*  colldata[4][64];
		unsigned char* freqscan[4];
		unsigned char  zsrtscan[4][64];
		componentInfo  cmpnfo_arr[4];
		int  cmpc_v, imgwidth_v, imgheight_v, sfhm_v, sfvm_v, mcuc_v, mcuh_v, mcuv_v;
		bool auto_set_v;
		unsigned char nois_trs_v[4], segm_cnt_v[4];
		// large idct tables on heap to avoid stack overflow (64 KB)
		std::shared_ptr<std::vector<int>> idct_8x8, idct_1x8, idct_8x1;
	};
	auto s = std::make_shared<Snap>();
	for ( int i = 0; i < 4; i++ ) {
		s->zdstdata[i] = zdstdata[i]; s->eobxhigh[i] = eobxhigh[i];
		s->eobyhigh[i] = eobyhigh[i]; s->zdstxlow[i] = zdstxlow[i];
		s->zdstylow[i] = zdstylow[i];
		for ( int j = 0; j < 64; j++ ) s->colldata[i][j] = colldata[i][j];
		s->freqscan[i] = freqscan[i];
		memcpy( s->zsrtscan[i], zsrtscan[i], 64 );
		s->nois_trs_v[i] = nois_trs[i]; s->segm_cnt_v[i] = segm_cnt[i];
	}
	memcpy( s->cmpnfo_arr, cmpnfo, sizeof(cmpnfo) );
	s->cmpc_v = cmpc; s->imgwidth_v = imgwidth; s->imgheight_v = imgheight;
	s->sfhm_v = sfhm; s->sfvm_v = sfvm;
	s->mcuc_v = mcuc; s->mcuh_v = mcuh; s->mcuv_v = mcuv;
	s->auto_set_v = auto_set;
	s->idct_8x8 = std::make_shared<std::vector<int>>(
		&adpt_idct_8x8[0][0], &adpt_idct_8x8[0][0] + 4*64*64);
	s->idct_1x8 = std::make_shared<std::vector<int>>(
		&adpt_idct_1x8[0][0], &adpt_idct_1x8[0][0] + 4*64);
	s->idct_8x1 = std::make_shared<std::vector<int>>(
		&adpt_idct_8x1[0][0], &adpt_idct_8x1[0][0] + 4*64);
	return [s]() {
		for ( int i = 0; i < 4; i++ ) {
			zdstdata[i] = s->zdstdata[i]; eobxhigh[i] = s->eobxhigh[i];
			eobyhigh[i] = s->eobyhigh[i]; zdstxlow[i] = s->zdstxlow[i];
			zdstylow[i] = s->zdstylow[i];
			for ( int j = 0; j < 64; j++ ) colldata[i][j] = s->colldata[i][j];
			freqscan[i] = s->freqscan[i];
			memcpy( zsrtscan[i], s->zsrtscan[i], 64 );
			nois_trs[i] = s->nois_trs_v[i]; segm_cnt[i] = s->segm_cnt_v[i];
		}
		memcpy( cmpnfo, s->cmpnfo_arr, sizeof(cmpnfo) );
		cmpc = s->cmpc_v; imgwidth = s->imgwidth_v; imgheight = s->imgheight_v;
		sfhm = s->sfhm_v; sfvm = s->sfvm_v;
		mcuc = s->mcuc_v; mcuh = s->mcuh_v; mcuv = s->mcuv_v;
		auto_set = s->auto_set_v;
		memcpy( &adpt_idct_8x8[0][0], s->idct_8x8->data(), s->idct_8x8->size()*sizeof(int) );
		memcpy( &adpt_idct_1x8[0][0], s->idct_1x8->data(), s->idct_1x8->size()*sizeof(int) );
		memcpy( &adpt_idct_8x1[0][0], s->idct_8x1->data(), s->idct_8x1->size()*sizeof(int) );
	};
}

// Run fn(cmp) for each component in parallel when sfth_mode is active.
// Each worker calls init_tls() first to restore THREAD_LOCAL image state.
// Falls back to sequential when sfth_mode is off or cmpc==1.
static bool par_pre_pack( int n, std::function<bool(int)> fn )
{
	if ( !sfth_mode || n <= 1 ) {
		for ( int c = 0; c < n; c++ ) if ( !fn(c) ) return false;
		return true;
	}
	auto init = make_tls_init();
	std::vector<std::future<bool>> futs;
	futs.reserve(n);
	for ( int c = 0; c < n; c++ )
		futs.push_back( std::async( std::launch::async, [&,c]() -> bool {
			init();
			return fn(c);
		}));
	bool ok = true;
	for ( auto& f : futs ) if ( !f.get() ) ok = false;
	return ok;
}
// ─────────────────────────────────────────────────────────────────────────────
#if !defined( BUILD_LIB )
THREAD_LOCAL unsigned char orig_set[ 8 ] = { 0 }; // store array for settings
#endif


/* -----------------------------------------------
	global variables: info about program
	----------------------------------------------- */

INTERN const unsigned char appversion = 40;
INTERN const char*  subversion   = "b";
INTERN const char*  apptitle     = "packJPG";
INTERN const char*  appname      = "packjpg";
[[maybe_unused]] INTERN const char*  versiondate  = "04/27/2026";
// On-disk PJG format version. v4.0b is a clean break — only one accepted
// format. Legacy v3.1d (31), v4.0 (40 without diag DC), and unreleased v4.1
// (41) are no longer decoded. Users with archives generated by earlier
// builds need to keep those binaries available, or re-encode with v4.0b+.
// See README "Format policy" section for rationale.
INTERN const unsigned char format_version_current = 40;
INTERN const char*  author       = "Yade Bravo";
#if !defined(BUILD_LIB)
INTERN const char*  website      = "https://github.com/YadeWira/packJPG";
[[maybe_unused]] INTERN const char*	copyright    = "2006-2026 Yade Bravo & Matthias Stirner";
INTERN const char*  pjg_ext      = "pjg";
INTERN const char*  jpg_ext      = "jpg";
#endif
INTERN const char   pjg_magic[] = { 'J', 'S' };


/* -----------------------------------------------
	main-function
	----------------------------------------------- */

#if !defined(BUILD_LIB)
int main( int argc, char** argv )
{	
	snprintf( errormessage, MSG_SIZE, "no errormessage specified" );
	
	using WallClock = std::chrono::steady_clock;
	WallClock::time_point begin, end;
	
	int error_cnt = 0;
	int warn_cnt  = 0;
	
	double acc_jpgsize = 0;
	double acc_pjgsize = 0;
	int acc_jpg_cnt = 0;
	int acc_pjg_cnt = 0;
	int acc_list_cnt = 0;
	
	double mbps;
	double cr;
	double total;
	
	errorlevel = 0;
	
	
	// read options from command line
	initialize_options( argc, argv );
	init_colors();

	// write program info to screen (suppressed in module mode)
	if ( !module_mode ) {
		fprintf( msgout, "\n%s%s v%i.%i%s%s  " BULLET "  by %s\n%s\n",
				COL_BCYAN, apptitle, appversion / 10, appversion % 10, subversion, COL_RESET, author, COL_RESET );
	}
	
	// check if user input is wrong, show help screen if it is
	if ( ( file_cnt == 0 ) ||
		( ( !developer ) && ( (action != A_COMPRESS && action != A_LIST && action != A_STATS) || (!auto_set) || (verify_lv > 1) ) ) ||
		( ( !developer ) && ( !subcmd_given ) && ( !pipe_on ) ) ) {
		show_help();
		return -1;
	}
	
	// display warning if not using automatic settings
	if ( !auto_set ) {
		fprintf( msgout,  " custom compression settings: \n" );
		fprintf( msgout,  " -------------------------------------------------\n" );
		fprintf( msgout,  " no of segments    ->  %3i[0] %3i[1] %3i[2] %3i[3]\n",
				segm_cnt[0], segm_cnt[1], segm_cnt[2], segm_cnt[3] );
		fprintf( msgout,  " noise threshold   ->  %3i[0] %3i[1] %3i[2] %3i[3]\n",
				nois_trs[0], nois_trs[1], nois_trs[2], nois_trs[3] );
		fprintf( msgout,  " -------------------------------------------------\n\n" );
	}
	
	// (re)set program has to be done first
	reset_buffers();
	
	// process file(s) - this is the main function routine
	begin = WallClock::now();
	if ( num_threads <= 1 ) {
		// --- single-threaded (original behavior) ---
		int st_proc_done = 0; // tracks processable files for progress display
		for ( file_no = 0; file_no < file_cnt; file_no++ ) {
			// process current file
			process_ui();
			// store error message and type if any
			if ( errorlevel > 0 ) {
				err_list[ file_no ] = (char*) calloc( MSG_SIZE, sizeof( char ) );
				err_tp[ file_no ] = errorlevel;
				if ( err_list[ file_no ] != NULL )
					snprintf( err_list[ file_no ], MSG_SIZE, "%s", errormessage );
			}
			// count errors / warnings / file sizes
			// unknown filetype (F_UNK) is silently skipped — not counted as error
			if ( filetype == F_UNK ) {
				if ( errorlevel > 0 ) error_cnt++; // inaccessible/unreadable file — count error
				// else: silently skip wrong file type
			} else {
				file_proc_no = ++st_proc_done;
				if ( errorlevel >= err_tol ) {
					error_cnt++;
				} else {
					if ( errorlevel == 1 ) warn_cnt++;
					if ( action == A_LIST ) {
						acc_list_cnt++;
					} else if ( action != A_STATS ) {
						if ( filetype == F_JPG ) {
							acc_jpgsize += jpgfilesize;
							acc_pjgsize += pjgfilesize;
							acc_jpg_cnt++;
						} else if ( filetype == F_PJG ) {
							acc_jpgsize += jpgfilesize;
							acc_pjgsize += pjgfilesize;
							acc_pjg_cnt++;
						}
					}
				}
			}
		}
	} else {
		// --- multi-threaded ---
		// Force verification in MT mode to catch any silent corruption.
		// Each file is compressed then immediately decompressed and compared bit-for-bit.
		if ( verify_lv < 1 ) verify_lv = 1;
		if ( !module_mode ) {
			int detected = (int) std::thread::hardware_concurrency();
			if ( detected < 1 ) detected = 1;
			fprintf( msgout, "Using %i of %i detected thread(s) (verify enabled)\n",
				num_threads, detected );
		}
		g_files_done.store( 0 );
		g_interrupted.store( false );

		// install SIGINT handler so Ctrl+C stops workers cleanly
		std::signal( SIGINT, []( int ) { g_interrupted.store( true ); } );

		std::atomic<int> g_next_file( 0 );
		std::mutex stats_mtx;
		int spinner_idx = 0;

		// Capture settings from main thread before spawning workers.
		// nois_trs, segm_cnt, auto_set, sfth_mode are thread_local
		// so each worker starts with defaults — copy the parsed values in.
		unsigned char main_nois_trs[4], main_segm_cnt[4];
		bool main_auto_set    = auto_set;
		bool main_sfth_mode   = sfth_mode;
		for ( int i = 0; i < 4; i++ ) {
			main_nois_trs[i] = nois_trs[i];
			main_segm_cnt[i] = segm_cnt[i];
		}

		auto worker = [&]() {
			// propagate main-thread settings into this thread's locals
			auto_set    = main_auto_set;
			sfth_mode   = main_sfth_mode;
			for ( int i = 0; i < 4; i++ ) {
				nois_trs[i] = main_nois_trs[i];
				segm_cnt[i] = main_segm_cnt[i];
			}
			int fn;
			while ( !g_interrupted.load() && ( fn = g_next_file.fetch_add( 1 ) ) < file_cnt ) {
				file_no = fn;
				process_ui();
				// accumulate stats under lock (each fn is unique so err_list/err_tp are safe)
				// acquire lock once: flush output + update stats + redraw bar
				{
					std::lock_guard<std::mutex> lk( stats_mtx );

					// --- stats ---
					// unknown filetype is silently skipped; but errors on unknown files still count
					if ( filetype == F_UNK && errorlevel > 0 ) error_cnt++;
					if ( filetype != F_UNK ) {
						if ( errorlevel > 0 ) {
							err_list[ fn ] = (char*) calloc( MSG_SIZE, sizeof( char ) );
							err_tp[ fn ] = errorlevel;
							if ( err_list[ fn ] != NULL )
								snprintf( err_list[ fn ], MSG_SIZE, "%s", errormessage );
						}
						if ( errorlevel >= err_tol ) error_cnt++;
						else {
							if ( errorlevel == 1 ) warn_cnt++;
							if ( action == A_LIST ) {
								acc_list_cnt++;
							} else if ( action != A_STATS ) {
								if ( filetype == F_JPG ) {
									acc_jpgsize += jpgfilesize;
									acc_pjgsize += pjgfilesize;
									acc_jpg_cnt++;
								} else if ( filetype == F_PJG ) {
									acc_jpgsize += jpgfilesize;
									acc_pjgsize += pjgfilesize;
									acc_pjg_cnt++;
								}
							}
						}
					}
					// only count non-skipped files for the progress display
					int done = ( filetype != F_UNK ) ? ++g_files_done : g_files_done.load();

					// --- console (all under the same lock) ---
					// In verbose mode (v1/v2) show per-file output interleaved with bar.
					// At verbosity 0 or -1 suppress it — errors are collected in err_list[]
					// and shown cleanly after the bar completes.
					if ( !tl_ui_buf.empty() && verbosity >= 1 ) {
						fprintf( msgout, "\r%*s\r", BARLEN + 34, "" );
						fwrite( tl_ui_buf.data(), 1, tl_ui_buf.size(), msgout );
					}
					tl_ui_buf.clear();
					// draw/update progress bar
					if ( !module_mode ) {
					int barpos = ( done * BARLEN ) / ( file_proc_cnt > 0 ? file_proc_cnt : 1 );
					#if defined(_WIN32)
					static const char* spinners[] = { "-", "\\", "|", "/" };
					const char* spin = spinners[ spinner_idx % 4 ];
					#else
					static const char* spinners[] = { "\xe2\xa0\x8b","\xe2\xa0\x99","\xe2\xa0\xb9","\xe2\xa0\xb8","\xe2\xa0\xbc","\xe2\xa0\xb4","\xe2\xa0\xa6","\xe2\xa0\xa7","\xe2\xa0\x87","\xe2\xa0\x8f" };
					const char* spin = spinners[ spinner_idx % 10 ];
					#endif
					spinner_idx++;
					fprintf( msgout, "\r  %s  %3i / %-3i  %s[", spin, done, file_proc_cnt, COL_CYAN );
					for ( int b = 0; b < barpos; b++ )
					#if defined(_WIN32)
						fprintf( msgout, "#" );
					#else
						fprintf( msgout, "\xe2\x96\x88" );
					#endif
					fprintf( msgout, "%s", COL_RESET );
					for ( int b = barpos; b < BARLEN; b++ )
					#if defined(_WIN32)
						fprintf( msgout, " " );
					#else
						fprintf( msgout, "\xe2\x96\x91" );
					#endif
					fprintf( msgout, "]" );
					fflush( msgout );
					}
				}
			}
		};

		std::vector<std::thread> threads;
		threads.reserve( num_threads );
		for ( int i = 0; i < num_threads; i++ )
			threads.emplace_back( worker );
		for ( auto& t : threads )
			t.join();

		// restore default SIGINT behavior
		std::signal( SIGINT, SIG_DFL );

		if ( g_interrupted.load() ) {
			if ( !module_mode )
				fprintf( msgout, "\n\n%s[interrupted]%s cleaning up...\n", COL_BYELLOW, COL_RESET );
			// remove any incomplete output files from files not yet processed
			for ( int fi = g_files_done.load(); fi < file_cnt; fi++ ) {
				if ( filelist[fi] == NULL ) continue;
				std::error_code ec;
				// try to remove .pjg and .jpg outputs that may have been partially written
				std::filesystem::path p = safe_path( filelist[fi] );
				std::filesystem::path out_pjg = p; out_pjg.replace_extension(".pjg");
				std::filesystem::path out_jpg = p; out_jpg.replace_extension(".jpg");
				std::filesystem::remove( out_pjg, ec );
				std::filesystem::remove( out_jpg, ec );
			}
			end = WallClock::now();
			if ( !module_mode )
				fprintf( msgout, "-> %i of %i file(s) processed before interrupt\n",
					g_files_done.load(), file_proc_cnt );
			goto cleanup;
		}

		// overwrite last progress bar line with final completed state
		if ( !module_mode ) {
		#if defined(_WIN32)
		fprintf( msgout, "\r  +  %3i / %-3i  %s[", file_proc_cnt, file_proc_cnt, COL_CYAN );
		#else
		fprintf( msgout, "\r  \xe2\x9c\x93  %3i / %-3i  %s[", file_proc_cnt, file_proc_cnt, COL_CYAN );
		#endif
		for ( int b = 0; b < BARLEN; b++ )
		#if defined(_WIN32)
			fprintf( msgout, "#" );
		#else
			fprintf( msgout, "\xe2\x96\x88" );
		#endif
		fprintf( msgout, "%s]   \n", COL_RESET );
		}
	}
	end = WallClock::now();

	cleanup:
	// In MT mode, per-file output is suppressed during the bar — print a clean
	// list of errors/warnings after the bar, before the summary counts.
	// Also shown at verbosity 2 in single-thread mode.
	if ( !module_mode && ( num_threads > 1 || verbosity == 2 ) && error_cnt > 0 ) {
		fprintf( msgout, "\n\n%sfiles with errors:%s\n", COL_BRED, COL_RESET );
		fprintf( msgout, "------------------\n" );
		for ( file_no = 0; file_no < file_cnt; file_no++ ) {
			if ( err_tp[ file_no ] >= err_tol )
				fprintf( msgout, "%s%s%s (%s)\n", COL_BRED, filelist[ file_no ], COL_RESET, err_list[ file_no ] );
		}
	}
	if ( !module_mode && ( num_threads > 1 || verbosity == 2 ) && warn_cnt > 0 ) {
		fprintf( msgout, "\n\n%sfiles with warnings:%s\n", COL_BYELLOW, COL_RESET );
		fprintf( msgout, "------------------\n" );
		for ( file_no = 0; file_no < file_cnt; file_no++ ) {
			if ( err_tp[ file_no ] == 1 )
				fprintf( msgout, "%s%s%s (%s)\n", COL_BYELLOW, filelist[ file_no ], COL_RESET, err_list[ file_no ] );
		}
	}
	
	// show statistics
	if ( !module_mode && mix_mode && acc_jpg_cnt > 0 && acc_pjg_cnt > 0 && ( verbosity >= 0 ) ) {
		fprintf( msgout, "\n%s[WARNING]%s Mixed mode: compressed %i JPG and decompressed %i PJG files.\n", COL_BYELLOW, COL_RESET, acc_jpg_cnt, acc_pjg_cnt );
		fprintf( msgout, "  Running -mix on already-processed files can undo previous work.\n" );
		fprintf( msgout, "  Use 'a' (compress only) or 'x' (decompress only) for safer operation.\n" );
	}
	if ( module_mode ) {
		// machine-friendly output for external tools (e.g. FreeArc)
		total = std::chrono::duration<double>( end - begin ).count();
		if ( error_cnt == 0 )
			fprintf( msgout, "OK %.2f\n", total );
		else
			fprintf( msgout, "ERROR %i %.2f\n", error_cnt, total );
	} else {
	fprintf( msgout,  "\n%i file(s)  %i ok  %i error(s)  %i warning(s)\n",
		file_proc_cnt, file_proc_cnt - error_cnt, error_cnt, warn_cnt );
	if ( acc_jpg_cnt > 0 || acc_pjg_cnt > 0 || acc_list_cnt > 0 ) {
		fprintf( msgout, " " );
		bool prev = false;
		if ( acc_jpg_cnt > 0 )  { fprintf( msgout, "compressed: %i JPG",    acc_jpg_cnt  ); prev = true; }
		if ( acc_pjg_cnt > 0 )  { if ( prev ) fprintf( msgout, "  " ); fprintf( msgout, "decompressed: %i PJG", acc_pjg_cnt  ); prev = true; }
		if ( acc_list_cnt > 0 ) { if ( prev ) fprintf( msgout, "  " ); fprintf( msgout, "listed: %i PJG",       acc_list_cnt ); }
		fprintf( msgout, "\n" );
	}
	if ( ( file_cnt > error_cnt ) && ( verbosity != 0 ) &&
	 ( acc_jpgsize > 0 || acc_pjgsize > 0 ) ) {
		// acc_jpgsize in bytes → convert to MB for MB/s
		double acc_jpg_mb = acc_jpgsize / ( 1024.0 * 1024.0 );
		acc_jpgsize /= 1024.0; acc_pjgsize /= 1024.0;
		total = std::chrono::duration<double>( end - begin ).count(); 
		mbps  = ( total > 0 ) ? ( acc_jpg_mb / total ) : acc_jpg_mb;
		cr    = ( acc_jpgsize > 0 ) ? ( 100.0 * acc_pjgsize / acc_jpgsize ) : 0;
		
		#if defined(_WIN32)
		fprintf( msgout,  "%s --------------------------------- %s\n", COL_GRAY, COL_RESET );
		#else
		fprintf( msgout,  "%s \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80 %s\n", COL_GRAY, COL_RESET );
		#endif
		if ( total >= 0 ) {
			fprintf( msgout,  " time    %8.2f sec\n", total );
			fprintf( msgout,  " speed   %8.2f MB/s\n", mbps );
		}
		else {
			fprintf( msgout,  " time    %8s sec\n", "N/A" );
			fprintf( msgout,  " speed   %8s MB/s\n", "N/A" );
		}
		fprintf( msgout,  " ratio   %8.2f %%\n", cr );
		#if defined(_WIN32)
		fprintf( msgout,  "%s --------------------------------- %s\n", COL_GRAY, COL_RESET );
		#else
		fprintf( msgout,  "%s \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80 %s\n", COL_GRAY, COL_RESET );
		#endif
		#if defined(DEV_INFOS)
		if ( acc_jpgsize > 0 ) { 
			fprintf( msgout,  " header %%          : %8.2f %%\n", 100.0 * dev_size_hdr / acc_jpgsize );
			if ( dev_size_cmp[0] > 0 ) fprintf( msgout,  " component [0] %%   : %8.2f %%\n", 100.0 * dev_size_cmp[0] / acc_jpgsize );
			if ( dev_size_cmp[1] > 0 ) fprintf( msgout,  " component [1] %%   : %8.2f %%\n", 100.0 * dev_size_cmp[1] / acc_jpgsize );
			if ( dev_size_cmp[2] > 0 ) fprintf( msgout,  " component [2] %%   : %8.2f %%\n", 100.0 * dev_size_cmp[2] / acc_jpgsize );
			if ( dev_size_cmp[3] > 0 ) fprintf( msgout,  " component [3] %%   : %8.2f %%\n", 100.0 * dev_size_cmp[3] / acc_jpgsize );
			fprintf( msgout,  " --------------------------------- \n" );
			for ( int i = 0; i < 4; i++ ) {
				if ( dev_size_cmp[i] == 0 ) break;
				fprintf( msgout,  " ac coeffs h [%i] %% : %8.2f %%\n", i, 100.0 * dev_size_ach[i] / acc_jpgsize );
				fprintf( msgout,  " ac coeffs l [%i] %% : %8.2f %%\n", i, 100.0 * dev_size_acl[i] / acc_jpgsize );
				fprintf( msgout,  " dc coeffs   [%i] %% : %8.2f %%\n", i, 100.0 * dev_size_dc[i] / acc_jpgsize );
				fprintf( msgout,  " zero dist h [%i] %% : %8.2f %%\n", i, 100.0 * dev_size_zdh[i] / acc_jpgsize );
				fprintf( msgout,  " zero dist l [%i] %% : %8.2f %%\n", i, 100.0 * dev_size_zdl[i] / acc_jpgsize );
				fprintf( msgout,  " zero sort   [%i] %% : %8.2f %%\n", i, 100.0 * dev_size_zsr[i] / acc_jpgsize );
				fprintf( msgout,  " --------------------------------- \n" );
			}
		}
		#endif
	}
	} // end if (!module_mode)
	
	// pause before exit
	if ( wait_exit && ( msgout != stderr ) ) {
		fprintf( msgout, "\n\n< press ENTER >\n" );
		fgetc( stdin );
	}
	
	
	return ( error_cnt > 0 ) ? 1 : 0;
}
#endif

/* ----------------------- Begin of library only functions -------------------------- */

/* -----------------------------------------------
	DLL export converter function
	----------------------------------------------- */
	
#if defined(BUILD_LIB)
EXPORT bool pjglib_convert_stream2stream( char* msg )
{
	// process in main function
	return pjglib_convert_stream2mem( NULL, NULL, msg ); 
}
#endif


/* -----------------------------------------------
	DLL export converter function
	----------------------------------------------- */

#if defined(BUILD_LIB)
EXPORT bool pjglib_convert_file2file( char* in, char* out, char* msg )
{
	// init streams
	pjglib_init_streams( (void*) in, 0, 0, (void*) out, 0 );
	
	// process in main function
	return pjglib_convert_stream2mem( NULL, NULL, msg ); 
}
#endif


/* -----------------------------------------------
	DLL export converter function
	----------------------------------------------- */
	
#if defined(BUILD_LIB)
EXPORT bool pjglib_convert_stream2mem( unsigned char** out_file, unsigned int* out_size, char* msg )
{
	clock_t begin, end;
	int total;
	float cr;	
	
	
	// use automatic settings
	auto_set = true;
	
	// (re)set buffers
	reset_buffers();
	action = A_COMPRESS;
	
	// main compression / decompression routines
	begin = clock();
	
	// process one file
	process_file();
	
	// fetch pointer and size of output (only for memory output)
	if ( ( errorlevel < err_tol ) && ( lib_out_type == 1 ) &&
		 ( out_file != NULL ) && ( out_size != NULL ) ) {
		*out_size = str_out->num_bytes_written();
		*out_file = str_out->get_c_data();
	}
	
	// close iostreams
    str_in.reset(nullptr);
    str_out.reset(nullptr);
	
	end = clock();
	
	// copy errormessage / remove files if error (and output is file)
	if ( errorlevel >= err_tol ) {
		if ( lib_out_type == 0 ) {
			if ( filetype == F_JPG ) {
				if ( file_exists( pjgfilename ) ) remove( pjgfilename );
			} else if ( filetype == F_PJG ) {
				if ( file_exists( jpgfilename ) ) remove( jpgfilename );
			}
		}
		if ( msg != NULL ) snprintf( msg, MSG_SIZE, "%s", errormessage );
		return false;
	}
	
	// get compression info
	total = (int) ( (double) (( end - begin ) * 1000) / CLOCKS_PER_SEC );
	cr    = ( jpgfilesize > 0 ) ? ( 100.0 * pjgfilesize / jpgfilesize ) : 0;
	
	// write success message else
	if ( msg != NULL ) {
		switch( filetype )
		{
			case F_JPG:
				snprintf( msg, MSG_SIZE, "Compressed to %s (%.2f%%) in %ims",
					pjgfilename, cr, ( total >= 0 ) ? total : -1 );
				break;
			case F_PJG:
				snprintf( msg, MSG_SIZE, "Decompressed to %s (%.2f%%) in %ims",
					jpgfilename, cr, ( total >= 0 ) ? total : -1 );
				break;
			case F_UNK:
				snprintf( msg, MSG_SIZE, "Unknown filetype" );
				break;
		}
	}
	
	
	return true;
}
#endif


/* -----------------------------------------------
	DLL export init input (file/mem)
	----------------------------------------------- */
	
#if defined(BUILD_LIB)
EXPORT void pjglib_init_streams( void* in_src, int in_type, int in_size, void* out_dest, int out_type )
{
	/* a short reminder about input/output stream types:
	
	if input is file
	----------------
	in_scr -> name of input file
	in_type -> 0
	in_size -> ignore
	
	if input is memory
	------------------
	in_scr -> array containg data
	in_type -> 1
	in_size -> size of data array
	
	if input is *FILE (f.e. stdin)
	------------------------------
	in_src -> stream pointer
	in_type -> 2
	in_size -> ignore
	
	vice versa for output streams! */
	
	unsigned char buffer[ 2 ];
	
	// (re)set errorlevel
	errorfunction = NULL;
	errorlevel = 0;
	jpgfilesize = 0;
	pjgfilesize = 0;
	

    switch (in_type) {
        case 0:
            try {
                str_in = std::make_unique<FileReader>((char*)in_src);
            } catch (const std::runtime_error&) {
                snprintf( errormessage, MSG_SIZE, "error opening input file %s", (char*)in_src);
		        errorlevel = 2;
		        return;
            }
            break;
        case 1:
            str_in = std::make_unique<MemoryReader>((unsigned char*)in_src, in_size);
            break;
        case 2:
			try {
				str_in = std::make_unique<StreamReader>();
			} catch (const std::runtime_error& e) {
				snprintf( errormessage, MSG_SIZE, e.what());
				errorlevel = 2;
				return;
			}
            break;
        default:
            snprintf( errormessage, MSG_SIZE, "Invalid input type: %i", in_type);
		    errorlevel = 2;
		    return;
    }

    switch (out_type) {
        case 0:
            try {
                str_out = std::make_unique<FileWriter>((char*)out_dest);
            } catch (const std::runtime_error&) {
                snprintf( errormessage, MSG_SIZE, "error opening output file %s", (char*)out_dest);
		        errorlevel = 2;
		        return;
            }
            break;
        case 1:
            str_out = std::make_unique<MemoryWriter>();
            break;
        case 2:
			try {
				str_out = std::make_unique<StreamWriter>();
			} catch (const std::runtime_error& e) {
				snprintf( errormessage, MSG_SIZE, e.what());
				errorlevel = 2;
				return;
			}
            break;
        default:
            snprintf( errormessage, MSG_SIZE, "Invalid output type: %i", out_type);
		    errorlevel = 2;
		    return;
    }
	
	// free memory from filenames if needed
	if (jpgfilename != nullptr) {
		free(jpgfilename);
		jpgfilename = nullptr;
	}
	if (pjgfilename != nullptr) {
		free(pjgfilename);
		pjgfilename = nullptr;
	}
	
	// check input stream
	str_in->read( buffer, 2 );
	if ( ( buffer[0] == 0xFF ) && ( buffer[1] == 0xD8 ) ) {
		// file is JPEG
		filetype = F_JPG;
		// copy filenames
		jpgfilename = (char*) calloc( (  in_type == 0 ) ? strlen( (char*) in_src   ) + 1 : 32, sizeof( char ) );
		pjgfilename = (char*) calloc( ( out_type == 0 ) ? strlen( (char*) out_dest ) + 1 : 32, sizeof( char ) );
		strcpy( jpgfilename, (  in_type == 0 ) ? (char*) in_src   : "JPG in memory" );
		strcpy( pjgfilename, ( out_type == 0 ) ? (char*) out_dest : "PJG in memory" );
	}
	else if ( (buffer[0] == pjg_magic[0]) && (buffer[1] == pjg_magic[1]) ) {
		// file is PJG
		filetype = F_PJG;
		// copy filenames
		pjgfilename = (char*) calloc( (  in_type == 0 ) ? strlen( (char*) in_src   ) + 1 : 32, sizeof( char ) );
		jpgfilename = (char*) calloc( ( out_type == 0 ) ? strlen( (char*) out_dest ) + 1 : 32, sizeof( char ) );
		strcpy( pjgfilename, (  in_type == 0 ) ? (char*) in_src   : "PJG in memory" );
		strcpy( jpgfilename, ( out_type == 0 ) ? (char*) out_dest : "JPG in memory" );
	}
	else {
		// file is neither
		filetype = F_UNK;
		snprintf( errormessage, MSG_SIZE, "filetype of input stream is unknown" );
		errorlevel = 2;
		return;
	}
	
	// store types of in-/output
	lib_in_type  = in_type;
	lib_out_type = out_type;
}
#endif


/* -----------------------------------------------
	DLL export version information
	----------------------------------------------- */
	
#if defined(BUILD_LIB)
EXPORT const char* pjglib_version_info( void )
{
	static char v_info[ 256 ];
	
	// copy version info to string
	snprintf( v_info, sizeof( v_info ), "--> %s library v%i.%i%s (%s) by %s <--",
			apptitle, appversion / 10, appversion % 10, subversion, versiondate, author );
			
	return (const char*) v_info;
}
#endif


/* -----------------------------------------------
	DLL export version information
	----------------------------------------------- */
	
#if defined(BUILD_LIB)
EXPORT const char* pjglib_short_name( void )
{
	static char v_name[ 256 ];
	
	// copy version info to string
	snprintf( v_name, sizeof( v_name ), "%s v%i.%i%s",
			apptitle, appversion / 10, appversion % 10, subversion );
			
	return (const char*) v_name;
}
#endif

/* ----------------------- End of libary only functions -------------------------- */

/* ----------------------- Begin of main interface functions -------------------------- */


/* -----------------------------------------------
	reads in commandline arguments
	----------------------------------------------- */
	
#if !defined(BUILD_LIB)

/* -----------------------------------------------
	recursively collect files from a directory
	----------------------------------------------- */
static bool is_jpg_or_pjg( const std::filesystem::path& p )
{
	auto ext = p.extension().string();
	for ( auto& ch : ext ) ch = (char)tolower( (unsigned char)ch );
	return ext == ".jpg" || ext == ".jpeg" || ext == ".pjg";
}

static void collect_files_recursive( const std::filesystem::path& dir,
                                     std::vector<std::string>& out )
{
	std::error_code ec;
	for ( auto& entry : std::filesystem::recursive_directory_iterator( dir,
	        std::filesystem::directory_options::skip_permission_denied, ec ) ) {
		if ( entry.is_regular_file( ec ) && is_jpg_or_pjg( entry.path() ) )
			out.push_back( entry.path().string() );
	}
}

INTERN void initialize_options( int argc, char** argv )
{	
	int tmp_val;
	char** tmp_flp;
	int i;
	
	
	// get memory for filelist & preset with NULL
	// Allocate generously: wildcard expansion on Windows can yield many more
	// files than argc. 65536 entries covers any realistic batch.
	const int FILELIST_MAX = 65536;
	filelist = (char**) calloc( FILELIST_MAX, sizeof( char* ) );
	for ( i = 0; i < FILELIST_MAX; i++ )
		filelist[ i ] = NULL;
	
	// preset temporary filelist pointer
	tmp_flp = filelist;
	
	
	// read in arguments
	// Check for pipe mode early (before subcommand check)
	for ( int pi = 1; pi < argc; pi++ ) {
		if ( strcmp(argv[pi], "-") == 0 ) { subcmd_given = true; break; }
	}

	// First argument can be a subcommand: c, x, mix, list
	if ( argc > 1 ) {
		const char* subcmd = argv[1];
		if ( strcmp(subcmd, "a") == 0 ) {
			compress_only = true;
			subcmd_given = true;
			argv++; argc--;
		} else if ( strcmp(subcmd, "x") == 0 ) {
			decompress_only = true;
			subcmd_given = true;
			argv++; argc--;
		} else if ( strcmp(subcmd, "mix") == 0 ) {
			mix_mode = true;
			subcmd_given = true;
			argv++; argc--;
		} else if ( strcmp(subcmd, "list") == 0 ) {
			action = A_LIST;
			subcmd_given = true;
			argv++; argc--;
		} else if ( strcmp(subcmd, "stats") == 0 ) {
			action = A_STATS;
			compress_only = true;  // only process JPG files
			subcmd_given = true;
			argv++; argc--;
		}
	}

	while ( --argc > 0 ) {
		argv++;
		// switches begin with '-'
		if ( strcmp((*argv), "-p" ) == 0 ) {
			err_tol = 2;
		}
		else if ( strcmp((*argv), "-d" ) == 0 ) {
			disc_meta = true;
		}		
		else if ( strcmp((*argv), "-ver" ) == 0 ) {
			verify_lv = ( verify_lv < 1 ) ? 1 : verify_lv;
		}
		else if ( sscanf( (*argv), "-v%i", &tmp_val ) == 1 ){
			verbosity = tmp_val;
			verbosity = ( verbosity < 0 ) ? 0 : verbosity;
			verbosity = ( verbosity > 2 ) ? 2 : verbosity;			
		}
		else if ( strcmp((*argv), "-vp" ) == 0 ) {
			verbosity = -1;
		}
		else if ( strcmp((*argv), "-np" ) == 0 ) {
			wait_exit = false;
		}
		else if ( strcmp((*argv), "--no-color" ) == 0 ) {
			force_no_color = true;
		}
		else if ( strcmp((*argv), "-r" ) == 0 ) {
			recursive = true;
		}
		else if ( strcmp((*argv), "-dry" ) == 0 ) {
			dry_run = true;
		}
		else if ( strcmp((*argv), "-module" ) == 0 ) {
			module_mode = true;
			wait_exit = false;
			verbosity = 0; // suppress all output except final OK/ERROR line
		}
		else if ( sscanf( (*argv), "-th%i", &tmp_val ) == 1 ) {
			if ( tmp_val == 0 ) {
				// auto: use all detected cores (x64/Linux), cap at 4 for x86
				// x86 has 2-4GB address space limit; too many threads causes OOM
				int cores = (int) std::thread::hardware_concurrency();
				if ( cores < 1 ) cores = 1;
				#if defined(_WIN64) || defined(__x86_64__) || defined(__amd64__) || defined(__LP64__)
				num_threads = cores;
				#else
				num_threads = ( cores > 2 ) ? 2 : cores;
				#endif
			} else {
				num_threads = ( tmp_val < 1 ) ? 1 : tmp_val;
			}
		}
		else if ( strcmp((*argv), "-o" ) == 0 ) {
			overwrite = true;
		}
		else if ( strcmp((*argv), "-sfth" ) == 0 ) {
			sfth_mode = true;
			// Warn if fewer than 3 cores are available
			int cores = (int) std::thread::hardware_concurrency();
			if ( cores > 0 && cores < 3 ) {
				fprintf( msgout, "\nWarning: -sfth works best with 3+ cores (detected: %i)\n\n", cores );
			}
		}
		else if ( strncmp((*argv), "-od", 3 ) == 0 && strlen(*argv) > 3 ) {
			// Feature #37: -od<path> sets output directory
			outdir = (*argv) + 3;
			// Create directory if it doesn't exist
			std::error_code ec;
			std::filesystem::create_directories( safe_path( outdir ), ec );
			// ec is silently ignored — if it fails, the error will surface later when writing files
		}
		#if defined(DEV_BUILD)
		else if ( strcmp((*argv), "-dev") == 0 ) {
			developer = true;
		}
		else if ( strcmp((*argv), "-test") == 0 ) {
			verify_lv = 2;
		}
		else if ( sscanf( (*argv), "-t%i,%i", &i, &tmp_val ) == 2 ) {			
			i = ( i < 0 ) ? 0 : i;
			i = ( i > 3 ) ? 3 : i;
			tmp_val = ( tmp_val < 0  ) ?  0 : tmp_val;
			tmp_val = ( tmp_val > 10 ) ? 10 : tmp_val;
			nois_trs[ i ] = tmp_val;
			auto_set = false;
		}
		else if ( sscanf( (*argv), "-s%i,%i", &i, &tmp_val ) == 2 ) {
			i = ( i < 0 ) ? 0 : i;
			i = ( i > 3 ) ? 3 : i;
			tmp_val = ( tmp_val <  1 ) ?  1 : tmp_val;
			tmp_val = ( tmp_val > 49 ) ? 49 : tmp_val;
			segm_cnt[ i ] = tmp_val;
			auto_set = false;
		}
		else if ( sscanf( (*argv), "-t%i", &tmp_val ) == 1 ) {
			tmp_val = ( tmp_val < 0  ) ?  0 : tmp_val;
			tmp_val = ( tmp_val > 10 ) ? 10 : tmp_val;
			nois_trs[0] = tmp_val;
			nois_trs[1] = tmp_val;
			nois_trs[2] = tmp_val;
			nois_trs[3] = tmp_val;
			auto_set = false;
		}
		else if ( sscanf( (*argv), "-s%i", &tmp_val ) == 1 ) {
			tmp_val = ( tmp_val <  1 ) ?  1 : tmp_val;
			tmp_val = ( tmp_val > 64 ) ? 64 : tmp_val;
			segm_cnt[0] = tmp_val;
			segm_cnt[1] = tmp_val;
			segm_cnt[2] = tmp_val;
			segm_cnt[3] = tmp_val;
			auto_set = false;
		}
		else if ( sscanf( (*argv), "-coll%i", &tmp_val ) == 1 ) {
			tmp_val = ( tmp_val < 0 ) ? 0 : tmp_val;
			tmp_val = ( tmp_val > 5 ) ? 5 : tmp_val;
			collmode = tmp_val;
			action = A_COLL_DUMP;
		}
		else if ( sscanf( (*argv), "-fcol%i", &tmp_val ) == 1 ) {
			tmp_val = ( tmp_val < 0 ) ? 0 : tmp_val;
			tmp_val = ( tmp_val > 5 ) ? 5 : tmp_val;
			collmode = tmp_val;
			action = A_FCOLL_DUMP;
		}
		else if ( strcmp((*argv), "-split") == 0 ) {
			action = A_SPLIT_DUMP;
		}
		else if ( strcmp((*argv), "-zdst") == 0 ) {
			action = A_ZDST_DUMP;
		}	
		else if ( strcmp((*argv), "-info") == 0 ) {
			action = A_TXT_INFO;
		}
		else if ( strcmp((*argv), "-dist") == 0 ) {
			action = A_DIST_INFO;
		}
		else if ( strcmp((*argv), "-pgm") == 0 ) {
			action = A_PGM_DUMP;
		}
	   	else if ( ( strcmp((*argv), "-comp") == 0) ) {
			action = A_COMPRESS;
		}
		#endif
		else if ( strcmp((*argv), "-") == 0 ) {
			// switch standard message out stream
			msgout = stderr;
			// use "-" as placeholder for stdin
			*(tmp_flp++) = (char*) "-";
		}
		else if ( (*argv)[0] == '-' ) {
			// Starts with '-' but matched no known flag — likely a typo.
			// Reject early to avoid treating it as a filename.
			fprintf( stderr, "\nError: unknown option '%s'\n", *argv );
			fprintf( stderr, "Run without arguments to see usage.\n\n" );
			return;
		}
		else {
			// if argument is not switch, it's a filename, wildcard, or directory
			#if defined(_WIN32) || defined(WIN32)
			// On Windows the shell does not expand wildcards, so we do it here.
			// Use Wide API (FindFirstFileW) to handle accented/Unicode filenames.
			if ( strchr( *argv, '*' ) != NULL || strchr( *argv, '?' ) != NULL ) {
				// Convert pattern to wide string; use 32768 to handle long paths (Win10+)
				wchar_t wpattern[32768];
				MultiByteToWideChar( CP_ACP, 0, *argv, -1, wpattern, 32768 );
				WIN32_FIND_DATAW fd;
				HANDLE hFind = FindFirstFileW( wpattern, &fd );
				if ( hFind != INVALID_HANDLE_VALUE ) {
					// Extract directory prefix from the pattern (e.g. "imgs\*.jpg" → "imgs\")
					// Win10+ long paths can exceed MAX_PATH, so size to match wpattern.
					char dir_prefix[32768] = "";
					const char* last_sep = strrchr( *argv, '\\' );
					const char* last_sep2 = strrchr( *argv, '/' );
					if ( last_sep2 > last_sep ) last_sep = last_sep2;
					if ( last_sep != NULL ) {
						size_t prefix_len = (size_t)(last_sep - *argv) + 1;
						if ( prefix_len >= sizeof(dir_prefix) )
							prefix_len = sizeof(dir_prefix) - 1;
						memcpy( dir_prefix, *argv, prefix_len );
						dir_prefix[ prefix_len ] = '\0';
					}
					do {
						// Skip . and ..
						if ( wcscmp( fd.cFileName, L"." ) == 0 || wcscmp( fd.cFileName, L".." ) == 0 )
							continue;
						// When -r is active, include subdirectories so they can be recursed later.
						// Without -r, skip directories as before.
						if ( ( fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY ) && !recursive )
							continue;
						// Convert wide filename back to CP_ACP; skip if chars can't be represented
						// (avoids silently corrupted filenames with best-fit substitution).
						char fname_utf8[MAX_PATH * 2];
						BOOL used_default = FALSE;
						int r = WideCharToMultiByte( CP_ACP, WC_NO_BEST_FIT_CHARS,
							fd.cFileName, -1, fname_utf8, (int)sizeof(fname_utf8), NULL, &used_default );
						if ( r == 0 || used_default ) continue;
						size_t len = strlen( dir_prefix ) + strlen( fname_utf8 ) + 1;
						char* fn = (char*) malloc( len );
						if ( fn ) {
							strcpy( fn, dir_prefix );
							strcat( fn, fname_utf8 );
							*(tmp_flp++) = fn;
						}
					} while ( FindNextFileW( hFind, &fd ) );
					FindClose( hFind );
				}
				// If no match found, skip silently (same behavior as Linux shell)
			} else {
				*(tmp_flp++) = *argv;
			}
			#else
			// Linux: add directories only when -r is active (for recursion);
			// without -r, silently skip directories from wildcard expansion
			{ std::error_code _ec;
			  bool is_dir = std::filesystem::is_directory( safe_path(*argv), _ec );
			  if ( !is_dir || recursive )
				*(tmp_flp++) = *argv;
			}
			#endif
		}		
	}

	// if -r is set, expand any directories in the filelist
	if ( recursive ) {
		std::vector<std::string> extra_files;
		for ( int fi = 0; filelist[ fi ] != NULL; fi++ ) {
			std::error_code ec;
			std::filesystem::path p;
			try { p = safe_path( filelist[ fi ] ); } catch (...) { continue; }
			if ( std::filesystem::is_directory( p, ec ) ) {
				filelist[ fi ] = NULL; // remove directory entry
				try { collect_files_recursive( p, extra_files ); } catch (...) {}
			}
		}
		if ( !extra_files.empty() ) {
			// count existing entries
			int existing = 0;
			for ( ; filelist[ existing ] != NULL; existing++ );
			// realloc filelist to fit extra files
			filelist = (char**) realloc( filelist,
				( existing + extra_files.size() + 1 ) * sizeof( char* ) );
			// compact (remove NULLs from directory entries)
			int wi = 0;
			for ( int fi = 0; fi < existing + (int)extra_files.size(); fi++ ) {
				if ( fi < existing && filelist[ fi ] != NULL )
					filelist[ wi++ ] = filelist[ fi ];
			}
			// append extra files
			for ( auto& s : extra_files ) {
				char* fn = (char*) malloc( s.size() + 1 );
				strcpy( fn, s.c_str() );
				filelist[ wi++ ] = fn;
			}
			filelist[ wi ] = NULL;
		}
	}
	
	// count number of files (or filenames) in filelist
	for ( file_cnt = 0; filelist[ file_cnt ] != NULL; file_cnt++ );

	// pre-scan to count processable files (JPG/PJG) for accurate progress display
	// skipped for single-file invocations — no overhead worth optimizing away
	if ( file_cnt == 1 ) {
		file_proc_cnt = 1;
		file_proc_no  = 0; // will become 1 after first non-UNK file processed
	} else {
	file_proc_cnt = 0;
	for ( int fi = 0; fi < file_cnt; fi++ ) {
		if ( filelist[fi] == NULL ) continue;
		// peek at first 2 bytes to detect type
		FILE* fp = fopen( filelist[fi], "rb" );
		if ( fp ) {
			unsigned char hd[2] = {0,0};
			if ( fread( hd, 1, 2, fp ) == 2 ) {
				bool is_jpg = ( hd[0] == 0xFF && hd[1] == 0xD8 );
				bool is_pjg = ( hd[0] == pjg_magic[0] && hd[1] == pjg_magic[1] );
				if ( ( is_jpg && !decompress_only ) ||
				     ( is_pjg && !compress_only ) )
					file_proc_cnt++;
			}
			fclose( fp );
		} else {
			file_proc_cnt++; // can't open — will be an error, count for correct progress display
		}
	}
	if ( file_proc_cnt == 0 ) file_proc_cnt = file_cnt; // fallback
	} // end else (file_cnt > 1)

	// alloc arrays for error messages and types storage
	err_list = (char**) calloc( file_cnt, sizeof( char* ) );
	err_tp   = (int*) calloc( file_cnt, sizeof( int ) );
	
	// backup settings - needed to restore original setting later
	if ( !auto_set ) {
		orig_set[ 0 ] = nois_trs[ 0 ];
		orig_set[ 1 ] = nois_trs[ 1 ];
		orig_set[ 2 ] = nois_trs[ 2 ];
		orig_set[ 3 ] = nois_trs[ 3 ];
		orig_set[ 4 ] = segm_cnt[ 0 ];
		orig_set[ 5 ] = segm_cnt[ 1 ];
		orig_set[ 6 ] = segm_cnt[ 2 ];
		orig_set[ 7 ] = segm_cnt[ 3 ];
	}
	else {
		for ( i = 0; i < 8; i++ )
			orig_set[ i ] = 0;
	}	
}
#endif


/* -----------------------------------------------
	UI for processing one file
	----------------------------------------------- */
	
#if !defined(BUILD_LIB)
INTERN void process_ui( void )
{
	clock_t begin, end;
	const char* actionmsg  = NULL;
	const char* errtypemsg = NULL;

	// Reset per-file state up front so module_mode's short-circuit also benefits.
	// Without this, a failed file leaves errorlevel=2, which makes the next file's
	// check inside the module branch skip process_file() and still count as error.
	errorfunction = NULL;
	errorlevel    = 0;
	jpgfilesize   = 0;
	pjgfilesize   = 0;

	// In module mode, suppress all per-file output — only final OK/ERROR is shown
	if ( module_mode ) {
		// still need to process the file, just skip all UI
		check_file();
		if ( errorlevel < 2 ) process_file();
		return;
	}

	// In multi-threaded mode we buffer all output into a thread_local string
	// so the worker lambda can flush it atomically together with the progress bar.
	tl_ui_buf.clear();
	bool   use_buf = ( num_threads > 1 );
	// Local printf macro: writes to buffer or directly to msgout
	#define UIPRINTF( ... ) \
		do { if ( use_buf ) { \
			char _tmp[1024]; \
			snprintf( _tmp, sizeof(_tmp), __VA_ARGS__ ); \
			tl_ui_buf += _tmp; \
		} else fprintf( msgout, __VA_ARGS__ ); } while(0)
	// progress bar (-1) doesn't work reliably across threads — treat as local_verbosity 0
	// A_LIST/A_STATS also forces verbosity 0: output is printed inside list_pjg/list_jpg
	int local_verbosity = ( ( use_buf && verbosity < 0 ) || action == A_LIST || action == A_STATS ) ? 0 : verbosity;
	int total, bpms;
	float cr;

	// errorfunction/errorlevel/jpgfilesize/pjgfilesize already reset at top of function

	#if !defined(DEV_BUILD)
	if ( action != A_LIST && action != A_STATS ) action = A_COMPRESS;
	#endif
	
	// compare file name, set pipe if needed
	if ( ( strcmp( filelist[ file_no ], "-" ) == 0 ) && ( action == A_COMPRESS ) ) {
		pipe_on = true;
		filelist[ file_no ] = (char*) "STDIN";
	}
	else {		
		pipe_on = false;
	}
	
	if ( local_verbosity >= 0 ) { // standard UI
		if ( action == A_LIST || action == A_STATS ) {
			// -list / stats: print filename as header, details follow from list_pjg/list_jpg
			fprintf( msgout, "\n%s\n", filelist[ file_no ] );
		} else if ( !use_buf ) {
			// single-thread verbose: check file first, then print header only if processable
			execute( check_file );
			if ( filetype == F_UNK ) return; // skip silently, no output
			if ( local_verbosity > 1 )
				fprintf( msgout, "\n----------------------------------------" );
			// get action message now that filetype is known
			switch ( action ) {
				case A_COMPRESS: actionmsg = ( filetype == F_JPG ) ? "Compressing" : "Decompressing"; break;
				case A_LIST:     actionmsg = "Listing"; break;
				case A_STATS:    actionmsg = "Analyzing"; break;
				default:         actionmsg = "Processing"; break;
			}
			{
				const char* _sl = strrchr( filelist[ file_no ], '/' );
				#if defined(_WIN32)
				const char* _bs = strrchr( filelist[ file_no ], '\\' );
				if ( _bs && ( !_sl || _bs > _sl ) ) _sl = _bs;
				#endif
				const char* _fn = _sl ? _sl + 1 : filelist[ file_no ];
				if ( local_verbosity > 1 )
					fprintf( msgout, "\n----------------------------------------\n" );
				#if defined(_WIN32)
				fprintf( msgout, "\n  ...  %-46.46s", _fn );
				#else
				fprintf( msgout, "\n  \xe2\xa0\xb8  %-46.46s", _fn );
				#endif
			}
			// actionmsg already set, skip the second fprintf below
			goto after_check;
		}

		// check input file and determine filetype
		execute( check_file );
		
		// get specific action message
		if ( filetype == F_UNK ) actionmsg = "unknown filetype";
		else switch ( action ) {
			case A_COMPRESS:	actionmsg = ( filetype == F_JPG ) ? "Compressing" : "Decompressing";	break;			
			case A_SPLIT_DUMP:	actionmsg = "Splitting"; break;			
			case A_COLL_DUMP:	actionmsg = "Extracting Colls"; break;
			case A_FCOLL_DUMP:	actionmsg = "Extracting FColls"; break;
			case A_ZDST_DUMP:	actionmsg = "Extracting ZDST lists"; break;			
			case A_TXT_INFO:	actionmsg = "Extracting info"; break;		
			case A_DIST_INFO:	actionmsg = "Extracting distributions";	break;		
			case A_PGM_DUMP:	actionmsg = "Converting"; break;
			case A_LIST:		actionmsg = "Listing"; break;
			case A_STATS:		actionmsg = "Analyzing"; break;
		}

		if ( !use_buf && local_verbosity < 2 && action != A_LIST && action != A_STATS )
			fprintf( msgout, "%s%s%s -> ", COL_CYAN, actionmsg, COL_RESET );
		after_check:;
	}
	else { // progress bar UI
		// update progress message
		#if defined(_WIN32)
		UIPRINTF( "  ...  %2i / %-2i  ", file_proc_no + 1, file_proc_cnt );
		#else
		UIPRINTF( "  \xe2\xa0\xb8  %2i / %-2i  ", file_proc_no + 1, file_proc_cnt );
		#endif
		progress_bar( file_no, file_cnt );
		UIPRINTF( "\r" );
		execute( check_file );
	}
	fflush( msgout );
	
	
	// main function routine
	begin = clock();
	
	// streams are initiated, start processing file
	try {
		process_file();
	} catch ( const std::exception& e ) {
		strncpy( errormessage, e.what(), MSG_SIZE - 1 );
		errormessage[MSG_SIZE - 1] = '\0';
		errorlevel = 2;
	}

	// close iostreams
    str_in.reset(nullptr);
    str_out.reset(nullptr);
    str_str.reset(nullptr);
	// delete if broken or if output not needed
	if ( ( !pipe_on ) && ( action != A_LIST ) &&
	     ( ( errorlevel >= err_tol ) || ( action != A_COMPRESS ) ) ) {
		if ( filetype == F_JPG ) {
			if ( file_exists( pjgfilename ) ) remove( pjgfilename );
		} else if ( filetype == F_PJG ) {
			if ( file_exists( jpgfilename ) ) remove( jpgfilename );
		}
	}
	
	end = clock();	
	
	// speed and compression ratio calculation
	total = (int) ( (double) (( end - begin ) * 1000) / CLOCKS_PER_SEC );
	bpms  = ( total > 0 ) ? ( jpgfilesize / total ) : jpgfilesize;
	cr    = ( jpgfilesize > 0 ) ? ( 100.0 * pjgfilesize / jpgfilesize ) : 0;

	
	if ( local_verbosity >= 0 ) { // standard UI
		if ( local_verbosity > 1 && !use_buf )
			fprintf( msgout, "\n----------------------------------------" );
		
		// display success/failure message (single-thread only for non-errors in MT)
		if ( !use_buf ) {
			switch ( local_verbosity ) {
				case 0:
					{
						const char* _sl = strrchr( filelist[ file_no ], '/' );
						#if defined(_WIN32)
						const char* _bs = strrchr( filelist[ file_no ], '\\' );
						if ( _bs && ( !_sl || _bs > _sl ) ) _sl = _bs;
						#endif
						const char* _fn = _sl ? _sl + 1 : filelist[ file_no ];
						if ( errorlevel < err_tol ) {
							if ( action == A_COMPRESS ) {
								long long orig_kb = ( jpgfilesize + 512 ) / 1024;
								long long comp_kb = ( pjgfilesize + 512 ) / 1024;
								double time_s = ( total >= 0 ) ? total / 1000.0 : 0.0;
								#if defined(_WIN32)
								fprintf( msgout, "\r  +  %-46.46s %6lld KB -> %6lld KB  %5.1f%%  %5.2fs\n",
									_fn, orig_kb, comp_kb, cr, time_s );
								#else
								fprintf( msgout, "\r  %s\xe2\x9c\x93%s  %-46.46s %6lld KB \xe2\x86\x92 %6lld KB  %5.1f%%  %5.2fs\n",
									COL_BGREEN, COL_RESET, _fn, orig_kb, comp_kb, cr, time_s );
								#endif
							} else if ( action != A_LIST && action != A_STATS ) {
								#if defined(_WIN32)
								fprintf( msgout, "\r  +  %-46.46s DONE\n", _fn );
								#else
								fprintf( msgout, "\r  %s\xe2\x9c\x93%s  %-46.46s DONE\n", COL_BGREEN, COL_RESET, _fn );
								#endif
							}
						} else {
							#if defined(_WIN32)
							fprintf( msgout, "\r  x  %-46.46s ERROR\n", _fn );
							#else
							fprintf( msgout, "\r  %s\xe2\x9c\x97%s  %-46.46s %sERROR%s\n",
								COL_BRED, COL_RESET, _fn, COL_BRED, COL_RESET );
							#endif
						}
					}
					break;

				case 1:
					if ( errorlevel < err_tol ) fprintf( msgout, "%sDONE%s\n", COL_BGREEN, COL_RESET );
					else                        fprintf( msgout, "%sERROR%s\n", COL_BRED,   COL_RESET );
					break;

				case 2:
					if ( errorlevel < err_tol ) fprintf( msgout, "\n-> %s %sOK%s\n",    actionmsg, COL_BGREEN, COL_RESET );
					else                        fprintf( msgout, "\n-> %s %sERROR%s\n", actionmsg, COL_BRED,   COL_RESET );
					break;
			}
		}
		
		// set type of error message
		switch ( errorlevel ) {
			case 0:	errtypemsg = "none"; break;
			case 1: errtypemsg = ( err_tol > 1 ) ?  "warning (ignored)" : "warning (skipped file)"; break;
			case 2: errtypemsg = "fatal error"; break;
		}
		
		// error/warning message — shown for real errors/warnings, not for silently skipped files
		if ( errorlevel > 0 && filetype != F_UNK ) {
			UIPRINTF( "\nProcessing file %i of %i \"%s\" -> %s -> %s:\n",
				file_no + 1, file_cnt, filelist[ file_no ], actionmsg, errtypemsg );
			UIPRINTF( " %s\n", errormessage );
		}
		if ( !use_buf && (local_verbosity > 0) && (errorlevel < err_tol) && (action == A_COMPRESS) ) {
			double file_mb = jpgfilesize / (1024.0 * 1024.0);
			double file_mbps = ( total > 0 ) ? ( file_mb / ( total / 1000.0 ) ) : file_mb;
			if ( total >= 0 ) {
				fprintf( msgout, " time taken  : %7i msec\n", total );
				fprintf( msgout, " speed       : %7.2f MB/s\n", file_mbps );
				fprintf( msgout, " byte per ms : %7i byte\n", bpms );
			}
			else {
				fprintf( msgout, " time taken  : %7s msec\n", "N/A" );
				fprintf( msgout, " speed       : %7s MB/s\n", "N/A" );
				fprintf( msgout, " byte per ms : %7s byte\n", "N/A" );
			}
			fprintf( msgout, " comp. ratio : %7.2f %%\n", cr );		
		}	
		if ( !use_buf && ( local_verbosity > 1 ) && ( action == A_COMPRESS ) )
			fprintf( msgout, "\n" );
	}
	else { // progress bar UI
		// if this is the last file, update progress bar one last time
		if ( file_no + 1 == file_cnt ) {
			// update progress message — add 1 for the current file if it was processed
			int shown = ( filetype != F_UNK ) ? file_proc_no + 1 : ( file_proc_no > 0 ? file_proc_no : file_proc_cnt );
			#if defined(_WIN32)
			UIPRINTF( "  +  %2i / %-2i  ", shown, file_proc_cnt );
			#else
			UIPRINTF( "  \xe2\x9c\x93  %2i / %-2i  ", shown, file_proc_cnt );
			#endif
			progress_bar( 1, 1 );
			UIPRINTF( "\n" );
		}
	}

	// In MT mode, output is flushed by the worker lambda after updating stats.
	// In single-thread mode, output was written directly to msgout via UIPRINTF.

	#undef UIPRINTF
}
#endif


/* -----------------------------------------------
	gets statusmessage for function
	----------------------------------------------- */
	
#if !defined(BUILD_LIB)
INTERN inline const char* get_status( bool (*function)() )
{	
	if ( function == NULL ) {
		return "unknown action";
	} else if ( function == *check_file ) {
		return "Determining filetype";
	} else if ( function == *read_jpeg ) {
		return "Reading header & image data";
	} else if ( function == *merge_jpeg ) {
		return "Merging header & image data";
	} else if ( function == *decode_jpeg ) {
		return "Decompressing JPEG image data";
	} else if ( function == *recode_jpeg ) {
		return "Recompressing JPEG image data";
	} else if ( function == *adapt_icos ) {
		return "Adapting DCT precalc. tables";
	} else if ( function == *predict_dc ) {
		return "Applying prediction to DC";
	} else if ( function == *unpredict_dc ) {
		return "Removing prediction from DC";
	} else if ( function == *check_value_range ) {
		return "Checking values range";
	} else if ( function == *calc_zdst_lists ) {
		return "Calculating zero dist lists";
	} else if ( function == *pack_pjg ) {
		return "Compressing data to PJG";
	} else if ( function == *unpack_pjg ) {
		return "Uncompressing data from PJG";
	} else if ( function == *swap_streams ) {
		return "Swapping input/output streams";
	} else if ( function == *compare_output ) {
		return "Verifying output stream";
	} else if ( function == *reset_buffers ) {
		return "Resetting program";
	}
	#if defined(DEV_BUILD)
	else if ( function == *dump_hdr ) {
		return "Writing header data to file";
	} else if ( function == *dump_huf ) {
		return "Writing huffman data to file";
	} else if ( function == *dump_coll ) {
		return "Writing collections to files";
	} else if ( function == *dump_zdst ) {
		return "Writing zdist lists to files";
	} else if ( function == *dump_errfile ) {
		return "Writing error info to file";
	} else if ( function == *dump_info ) {
		return "Writing info to files";
	} else if ( function == *dump_dist ) {
		return "Writing distributions to files";
	} else if ( function == *dump_pgm ) {
		return "Writing converted image to pgm";
	}
	#endif
	else {
		return "Function description missing!";
	}
}
#endif


/* -----------------------------------------------
	shows help in case of wrong input
	----------------------------------------------- */
	
#if !defined(BUILD_LIB)
INTERN void show_help( void )
{	
	fprintf( msgout, "\n" );
	fprintf( msgout, "packJPG -- lossless JPEG compression. Typical reduction: ~20%%.\n" );
	fprintf( msgout, "Compresses JPEG files to PJG format and decompresses them back,\n" );
	fprintf( msgout, "with bit-for-bit identical reconstruction.\n" );
	fprintf( msgout, "\n" );
	fprintf( msgout, "Website: %s\n", website );
	fprintf( msgout, "\n" );
	fprintf( msgout, "Usage: %s <subcommand> [switches] [filename(s)]\n", appname );
	fprintf( msgout, "\n" );
	fprintf( msgout, "Subcommands:\n" );
	fprintf( msgout, " a         compress only: process JPG files, skip PJG\n" );
	fprintf( msgout, " x         decompress only: process PJG files, skip JPG\n" );
	fprintf( msgout, " mix       mixed mode: auto-detect (warns if both directions used)\n" );
	fprintf( msgout, " list      list PJG file info without decompressing\n" );
	fprintf( msgout, " stats     show JPEG file info (size, dimensions, color) without compressing\n" );
	fprintf( msgout, "\n" );
	fprintf( msgout, "Switches:" );
	fprintf( msgout, "\n" );
	fprintf( msgout, "\n" );
	fprintf( msgout, " [-ver]   verify files after processing\n" );
	fprintf( msgout, " [-v?]    set level of verbosity (max: 2) (def: 0)\n" );
	fprintf( msgout, " [-vp]    progress bar mode (overrides -v?)\n" );
	fprintf( msgout, " [-np]    no pause after processing files\n" );
	fprintf( msgout, " [--no-color] disable ANSI color output\n" );
	fprintf( msgout, " [-o]     overwrite existing files\n" );
	fprintf( msgout, " [-sfth]  use 3 cores for single-file compression (pre-pack stages)\n" );
	fprintf( msgout, " [-th?]   set number of threads (0=auto, def: 1)\n" );
	fprintf( msgout, " [-r]     recurse into subdirectories\n" );
	fprintf( msgout, " [-dry]   dry run: simulate without writing output files\n" );
	fprintf( msgout, " [-module] machine-friendly output: OK/ERROR + time only\n" );
	fprintf( msgout, " [-od<p>] write output files to directory <p>\n" );
	fprintf( msgout, " [-p]     proceed on warnings\n" );
	fprintf( msgout, " [-d]     discard meta-info\n" );
	#if defined(DEV_BUILD)
	if ( developer ) {
	fprintf( msgout, "\n" );
	fprintf( msgout, " [-s?]    set global number of segments (1<=s<=49)\n" );
	fprintf( msgout, " [-t?]    set global noise threshold (0<=t<=10)\n" );
	fprintf( msgout, "\n" );	
	fprintf( msgout, " [-s?,?]  set number of segments for component\n" );
	fprintf( msgout, " [-t?,?]  set noise threshold for component\n" );
	fprintf( msgout, "\n" );
	fprintf( msgout, " [-test]  test algorithms, alert if error\n" );
	fprintf( msgout, " [-split] split jpeg (to header & image data)\n" );
	fprintf( msgout, " [-coll?] write collections (0=std,1=dhf,2=squ,3=unc)\n" );
	fprintf( msgout, " [-fcol?] write predicted collections (see above)\n" );
	fprintf( msgout, " [-zdst]  write zero distribution lists\n" );	
	fprintf( msgout, " [-info]  write debug info to .nfo file\n" );	
	fprintf( msgout, " [-dist]  write distribution data to file\n" );
	fprintf( msgout, " [-pgm]   convert and write to pgm files\n" );
	}
	#endif
	fprintf( msgout, "\n" );
}
#endif


/* -----------------------------------------------
	processes one file
	----------------------------------------------- */

INTERN void process_file( void )
{	
	if ( filetype == F_JPG ) {
		switch ( action ) {
			case A_COMPRESS:
				execute( read_jpeg );
				execute( decode_jpeg );
				execute( check_value_range );
				execute( adapt_icos );
				execute( predict_dc );
				execute( calc_zdst_lists );
				execute( pack_pjg );
				#if !defined(BUILD_LIB)	
				if ( verify_lv > 0 ) { // verifcation
					// save jpgfilesize/pjgfilesize before verify — unpack overwrites them
					int64_t saved_jpgsize = jpgfilesize;
					int64_t saved_pjgsize = pjgfilesize;
					execute( reset_buffers );
					execute( swap_streams );
					execute( unpack_pjg );
					execute( adapt_icos );
					execute( unpredict_dc );
					execute( recode_jpeg );
					execute( merge_jpeg );
					execute( compare_output );
					// restore original sizes for correct ratio reporting
					jpgfilesize = saved_jpgsize;
					pjgfilesize = saved_pjgsize;
				}
				#endif
				break;

			#if !defined(BUILD_LIB)
			case A_STATS:
				execute( read_jpeg );
				execute( decode_jpeg );
				execute( list_jpg );
				break;
			#endif

			#if !defined(BUILD_LIB) && defined(DEV_BUILD)
			case A_SPLIT_DUMP:
				execute( read_jpeg );
				execute( dump_hdr );
				execute( dump_huf );
				break;
				
			case A_COLL_DUMP:
				execute( read_jpeg );
				execute( decode_jpeg );
				execute( dump_coll );
				break;
				
			case A_FCOLL_DUMP:
				execute( read_jpeg );
				execute( decode_jpeg );
				execute( check_value_range );
				execute( adapt_icos );
				execute( predict_dc );
				execute( dump_coll );
				break;
				
			case A_ZDST_DUMP:
				execute( read_jpeg );
				execute( decode_jpeg );
				execute( check_value_range );
				execute( adapt_icos );
				execute( predict_dc );
				execute( calc_zdst_lists );
				execute( dump_zdst );
				break;
				
			case A_TXT_INFO:
				execute( read_jpeg );
				execute( dump_info );
				break;
				
			case A_DIST_INFO:
				execute( read_jpeg );
				execute( decode_jpeg );
				execute( check_value_range );
				execute( adapt_icos );
				execute( predict_dc );
				execute( dump_dist );
				break;
			
			case A_PGM_DUMP:
				execute( read_jpeg );
				execute( decode_jpeg );
				execute( adapt_icos );
				execute( dump_pgm );
				break;
			case A_LIST:
				// -list only works on .pjg files
				snprintf( errormessage, MSG_SIZE, "-list is only supported for PJG files" );
				errorlevel = 2;
				break;
			// A_STATS handled outside the DEV_BUILD block (runs list_jpg)
			#else
			default:
				break;
			#endif
		}
	}
	else if ( filetype == F_PJG )	{
		switch ( action )
		{
			case A_COMPRESS:
				execute( unpack_pjg );
				execute( adapt_icos );
				execute( unpredict_dc );
				execute( recode_jpeg );
				execute( merge_jpeg );
				#if !defined(BUILD_LIB)
				if ( verify_lv > 0 ) { // verify
					execute( reset_buffers );
					execute( swap_streams );
					execute( read_jpeg );
					execute( decode_jpeg );
					execute( check_value_range );
					execute( adapt_icos );
					execute( predict_dc );
					execute( calc_zdst_lists );
					// re-encode with the same format as the original PJG
					bool saved_sfth = sfth_mode;
					sfth_mode = decoded_from_sfth;
					execute( pack_pjg );
					sfth_mode = saved_sfth;
					execute( compare_output );
				}
				#endif
				break;
				
			#if !defined(BUILD_LIB)
				#if defined(DEV_BUILD)
			case A_SPLIT_DUMP:
				execute( unpack_pjg );
				execute( adapt_icos );
				execute( unpredict_dc );
				execute( recode_jpeg );
				execute( dump_hdr );
				execute( dump_huf );
				break;

			case A_COLL_DUMP:
				execute( unpack_pjg );
				execute( adapt_icos );
				execute( unpredict_dc );
				execute( dump_coll );
				break;

			case A_FCOLL_DUMP:
				execute( unpack_pjg );
				execute( dump_coll );
				break;

			case A_ZDST_DUMP:
				execute( unpack_pjg );
				execute( dump_zdst );
				break;

			case A_TXT_INFO:
				execute( unpack_pjg );
				execute( dump_info );
				break;

			case A_DIST_INFO:
				execute( unpack_pjg );
				execute( dump_dist );
				break;

			case A_PGM_DUMP:
				execute( unpack_pjg );
				execute( adapt_icos );
				execute( unpredict_dc );
				execute( dump_pgm );
				break;
				#endif // DEV_BUILD

			case A_LIST:
				execute( list_pjg );
				break;
			#else
			default:
				break;
			#endif // BUILD_LIB
		}
	}	
	#if !defined(BUILD_LIB) && defined(DEV_BUILD)
	// write error file if verify lv > 1
	if ( ( verify_lv > 1 ) && ( errorlevel >= err_tol ) )
		dump_errfile();
	#endif
	// reset buffers
	reset_buffers();
}


/* -----------------------------------------------
	main-function execution routine
	----------------------------------------------- */

INTERN void execute( bool (*function)() )
{
	if ( errorlevel < err_tol ) {
		#if !defined BUILD_LIB
		clock_t begin, end;
		bool success;
		int total;
		
		// write statusmessage
		if ( verbosity == 2 ) {
			fprintf( msgout,  "\n%s ", get_status( function ) );
			for ( int i = strlen( get_status( function ) ); i <= 30; i++ )
				fprintf( msgout,  " " );			
		}
		
		// set starttime
		begin = clock();
		// call function
		success = ( *function )();
		// set endtime
		end = clock();
		
		if ( ( errorlevel > 0 ) && ( errorfunction == NULL ) )
			errorfunction = function;
		
		// write time or failure notice
		if ( success ) {
			total = (int) ( (double) (( end - begin ) * 1000) / CLOCKS_PER_SEC );
			if ( verbosity == 2 ) fprintf( msgout,  "%6ims", ( total >= 0 ) ? total : -1 );
		}
		else {
			errorfunction = function;
			if ( verbosity == 2 ) fprintf( msgout,  "%8s", "ERROR" );
		}
		#else
		// call function
		( *function )();
		
		// store errorfunction if needed
		if ( ( errorlevel > 0 ) && ( errorfunction == NULL ) )
			errorfunction = function;
		#endif
	}
}

/* ----------------------- End of main interface functions -------------------------- */

/* ----------------------- Begin of main functions -------------------------- */


/* -----------------------------------------------
	check file and determine filetype
	----------------------------------------------- */

#if !defined(BUILD_LIB)
INTERN bool check_file( void )
{
	unsigned char fileid[ 2 ] = { 0, 0 };
	const char* filename = filelist[ file_no ];
	filetype = F_UNK; // reset before open attempt so inaccessible files don't inherit previous filetype

	try {
		if (pipe_on) {
			str_in = std::make_unique<StreamReader>();
		} else {
			str_in = std::make_unique<FileReader>(std::string(filename));
		}
	} catch (const std::runtime_error& e) {
		strncpy(errormessage, e.what(), MSG_SIZE - 1); errormessage[MSG_SIZE - 1] = '\0';
		errorlevel = 2;
		return false;
	}
	
	// free memory from filenames if needed
	if (jpgfilename != nullptr) {
		free(jpgfilename);
		jpgfilename = nullptr;
	}
	if (pjgfilename != nullptr) {
		free(pjgfilename);
		pjgfilename = nullptr;
	}
	
	// immediately return error if 2 bytes can't be read
	if ( str_in->read( fileid, 2 ) != 2 ) { 
		filetype = F_UNK;
		snprintf( errormessage, MSG_SIZE, "file doesn't contain enough data" );
		errorlevel = 2;
		return false;
	}
	
	// check file id, determine filetype
	if ( ( fileid[0] == 0xFF ) && ( fileid[1] == 0xD8 ) ) {
		// file is JPEG
		filetype = F_JPG;
		// create filenames
		if ( !pipe_on ) {
			jpgfilename = (char*) calloc( strlen( filename ) + 1, sizeof( char ) );
			strcpy( jpgfilename, filename );
			pjgfilename = ( overwrite ) ?
				create_filename( filename, (char*) pjg_ext ) :
				unique_filename( filename, (char*) pjg_ext );
		}
		else {
			jpgfilename = create_filename( "STDIN", NULL );
			pjgfilename = create_filename( "STDOUT", NULL );
		}

		try {
			if (pipe_on) {
				str_out = std::make_unique<StreamWriter>();
			} else if ( dry_run ) {
				str_out = std::make_unique<MemoryWriter>(); // write to memory, discard
			} else if ( decompress_only ) {
				// Skip silently — symmetric with 'a' skipping .pjg files
				filetype = F_UNK;
				errorlevel = 0;
				return false;
			} else {
				str_out = std::make_unique<FileWriter>(std::string(pjgfilename));
			}
		} catch (const std::runtime_error& e) {
			strncpy(errormessage, e.what(), MSG_SIZE - 1); errormessage[MSG_SIZE - 1] = '\0';
            errorlevel = 2;
            return false;
		}
		// JPEG specific settings - restore original settings
		if ( orig_set[ 0 ] == 0 )
			auto_set = true;
		else {	
			nois_trs[ 0 ] = orig_set[ 0 ];
			nois_trs[ 1 ] = orig_set[ 1 ];
			nois_trs[ 2 ] = orig_set[ 2 ];
			nois_trs[ 3 ] = orig_set[ 3 ];
			segm_cnt[ 0 ] = orig_set[ 4 ];
			segm_cnt[ 1 ] = orig_set[ 5 ];
			segm_cnt[ 2 ] = orig_set[ 6 ];
			segm_cnt[ 3 ] = orig_set[ 7 ];
			auto_set = false;
		}
	}
	else if ( ( fileid[0] == pjg_magic[0] ) && ( fileid[1] == pjg_magic[1] ) ) {
		// file is PJG
		filetype = F_PJG;
		// create filenames
		if ( !pipe_on ) {
			pjgfilename = (char*) calloc( strlen( filename ) + 1, sizeof( char ) );
			strcpy( pjgfilename, filename );
			jpgfilename = ( overwrite ) ?
				create_filename( filename, (char*) jpg_ext ) :
				unique_filename( filename, (char*) jpg_ext );
		}
		else {
			jpgfilename = create_filename( "STDOUT", NULL );
			pjgfilename = create_filename( "STDIN", NULL );
		}
		// open output stream, check for errors
        if (pipe_on) {
            str_out = std::make_unique<StreamWriter>();
        } else if ( action == A_LIST ) {
            // no output file for -list
        } else if ( dry_run ) {
            str_out = std::make_unique<MemoryWriter>(); // write to memory, discard
        } else if ( compress_only ) {
            // Skip silently — symmetric with 'x' skipping .jpg files
            filetype = F_UNK;
            errorlevel = 0;
            return false;
        } else {
            str_out = std::make_unique<FileWriter>(std::string(jpgfilename));
        }
		// PJG specific settings - auto unless specified otherwise
		auto_set = true;
	}
	else {
		// file is neither — skip silently (no error shown for .exe, .png, etc.)
		filetype = F_UNK;
		errorlevel = 1; // warning level: skipped silently, not counted as error
		return false;
	}
	
	
	return true;
}
#endif


/* -----------------------------------------------
	swap streams / init verification
	----------------------------------------------- */
	
#if !defined(BUILD_LIB)
INTERN bool swap_streams( void )	
{
	unsigned char dmp[ 2 ];
	
	// store input stream
	str_str = std::move(str_in);
	str_str->rewind();
	
	// replace input stream by output stream / switch mode for reading / read first bytes
    str_in = std::make_unique<MemoryReader>(str_out->get_data());
	str_in->read( dmp, 2 );
	
	// open new stream for output / check for errors
    str_out = std::make_unique<MemoryWriter>();
	
	return true;
}
#endif


/* -----------------------------------------------
	comparison between input & output
	----------------------------------------------- */

#if !defined(BUILD_LIB)
INTERN bool compare_output( void )
{
    if (str_out->error()) {
        snprintf( errormessage, MSG_SIZE, "error in comparison stream");
        errorlevel = 2;
        return false;
    } else if (str_in->error()) {
        snprintf( errormessage, MSG_SIZE, "error in output stream");
        errorlevel = 2;
        return false;
    } else if (str_str->error()) {
        snprintf( errormessage, MSG_SIZE, "error in input stream");
        errorlevel = 2;
        return false;
    }
    
	const auto verif_data = str_out->get_data();
    const auto orig_data = str_str->get_data();
    
	if (verif_data.size() != orig_data.size()) {
		snprintf( errormessage, MSG_SIZE, "file sizes do not match" );
		errorlevel = 2;
		return false;
	}
	const auto result = std::mismatch(std::begin(orig_data),
	                                  std::end(orig_data),
	                                  std::begin(verif_data),
	                                  std::end(verif_data));
	if (result.first != std::end(orig_data) || result.second != std::end(verif_data)) {
		const auto first_diff = std::distance(std::begin(orig_data), result.first);
        snprintf( errormessage, MSG_SIZE, "difference found at 0x%llx", (long long) first_diff );
		errorlevel = 2;
		return false;
	}
	return true;
}
#endif


/* -----------------------------------------------
	set each variable to its initial value
	----------------------------------------------- */

INTERN bool reset_buffers( void )
{
	int cmp, bpos;
	int i;
	
	
	// -- free buffers --
	
	// free buffers & set pointers NULL
	if ( hdrdata  != NULL ) free ( hdrdata );
	if ( huffdata != NULL ) free ( huffdata );
	if ( grbgdata != NULL ) free ( grbgdata );
	if ( rst_err  != NULL ) free ( rst_err );
	if ( rstp     != NULL ) free ( rstp );
	if ( scnp     != NULL ) free ( scnp );
	hdrdata   = NULL;
	huffdata  = NULL;
	grbgdata  = NULL;
	rst_err   = NULL;
	rstp      = NULL;
	scnp      = NULL;
	
	// free image arrays
	for ( cmp = 0; cmp < 4; cmp++ )	{
		if ( zdstdata[ cmp ] != NULL ) free( zdstdata[cmp] );
		if ( eobxhigh[ cmp ] != NULL ) free( eobxhigh[cmp] );
		if ( eobyhigh[ cmp ] != NULL ) free( eobyhigh[cmp] );
		if ( zdstxlow[ cmp ] != NULL ) free( zdstxlow[cmp] );
		if ( zdstylow[ cmp ] != NULL ) free( zdstylow[cmp] );
		zdstdata[ cmp ] = NULL;
		eobxhigh[ cmp ] = NULL;
		eobyhigh[ cmp ] = NULL;
		zdstxlow[ cmp ] = NULL;
		zdstylow[ cmp ] = NULL;
		freqscan[ cmp ] = (unsigned char*) stdscan;
		
		for ( bpos = 0; bpos < 64; bpos++ ) {
			if ( colldata[ cmp ][ bpos ] != NULL ) free( colldata[cmp][bpos] );
			colldata[ cmp ][ bpos ] = NULL;
		}		
	}
	
	
	// -- set variables --
	
	// preset componentinfo
	for ( cmp = 0; cmp < 4; cmp++ ) {
		cmpnfo[ cmp ].sfv = -1;
		cmpnfo[ cmp ].sfh = -1;
		cmpnfo[ cmp ].mbs = -1;
		cmpnfo[ cmp ].bcv = -1;
		cmpnfo[ cmp ].bch = -1;
		cmpnfo[ cmp ].bc  = -1;
		cmpnfo[ cmp ].ncv = -1;
		cmpnfo[ cmp ].nch = -1;
		cmpnfo[ cmp ].nc  = -1;
		cmpnfo[ cmp ].sid = -1;
		cmpnfo[ cmp ].jid = -1;
		cmpnfo[ cmp ].qtable = NULL;
		cmpnfo[ cmp ].huffdc = -1;
		cmpnfo[ cmp ].huffac = -1;
	}
	
	// preset imgwidth / imgheight / component count 
	imgwidth  = 0;
	imgheight = 0;
	cmpc      = 0;
	
	// preset mcu info variables / restart interval
	sfhm      = 0;
	sfvm      = 0;
	mcuc      = 0;
	mcuh      = 0;
	mcuv      = 0;
	rsti      = 0;
	
	// reset quantization / huffman tables
	for ( i = 0; i < 4; i++ ) {
		htset[ 0 ][ i ] = 0;
		htset[ 1 ][ i ] = 0;
		for ( bpos = 0; bpos < 64; bpos++ )
			qtables[ i ][ bpos ] = 0;
	}
	
	// preset jpegtype
	jpegtype  = 0;
	
	// reset padbit
	padbit = -1;
	
	
	return true;
}


/* -----------------------------------------------
	Read in header & image data
	----------------------------------------------- */
	
INTERN bool read_jpeg( void )
{
	unsigned char* segment = NULL; // storage for current segment
	unsigned int   ssize = 1024; // current size of segment array
	unsigned char  type = 0x00; // type of current marker segment
	unsigned int   len  = 0; // length of current marker segment
	unsigned int   crst = 0; // current rst marker counter
	unsigned int   cpos = 0; // rst marker counter
	unsigned char  tmp;	
	
	MemoryWriter* huffw;	
	MemoryWriter* hdrw;
	MemoryWriter* grbgw;	
	
	
	// preset count of scans
	scnc = 0;
	
	// start headerwriter
	hdrw = new MemoryWriter();
	hdrs = 0; // size of header data, start with 0
	
	// start huffman writer
	// Opt: pre-reserve ~90% of input size to avoid reallocs — huffdata is usually the bulk.
	huffw = new MemoryWriter();
	huffw->reserve( str_in->get_size() );
	hufs  = 0; // size of image data, start with 0
	
	// alloc memory for segment data first
	segment = ( unsigned char* ) calloc( ssize, sizeof( char ) );
	if ( segment == NULL ) {
		snprintf( errormessage, MSG_SIZE, MEM_ERRMSG );
		errorlevel = 2;
		// Fix #34: hdrw and huffw were already allocated above — free them before returning.
		delete ( hdrw );
		delete ( huffw );
		return false;
	}
	
	// JPEG reader loop
	while ( true ) {
		if ( type == 0xDA ) { // if last marker was sos
			// switch to huffman data reading mode
			cpos = 0;
			crst = 0;
			while ( true ) {
				// read byte from imagedata
				if ( str_in->read_byte(&tmp) == 0 )
					break;
					
				// non-0xFF loop
				if ( tmp != 0xFF ) {
					crst = 0;
					while ( tmp != 0xFF ) {
						huffw->write_byte( tmp );
						if ( str_in->read_byte(&tmp) == 0 )
							break;
					}
				}
				
				// treatment of 0xFF
				if ( tmp == 0xFF ) {
					if ( str_in->read_byte(&tmp) == 0 )
						break; // read next byte & check
					if ( tmp == 0x00 ) {
						crst = 0;
						// no zeroes needed -> ignore 0x00. write 0xFF
						huffw->write_byte( 0xFF );
					}
					else if ( tmp == 0xD0 + ( cpos % 8 ) ) { // restart marker
						// increment rst counters
						cpos++;
						crst++;
					}
					else { // in all other cases leave it to the header parser routines
						// store number of wrongly set rst markers
						if ( crst > 0 ) {
							if ( rst_err == NULL ) {
								rst_err = (unsigned char*) calloc( scnc + 1, sizeof( char ) );
								if ( rst_err == NULL ) {
									snprintf( errormessage, MSG_SIZE, MEM_ERRMSG );
									errorlevel = 2;
									// Fix #34: cleanup before early return.
									delete ( hdrw );
									delete ( huffw );
									free ( segment );
									return false;
								}
							}
						}
						if ( rst_err != NULL ) {
							// realloc and set only if needed
							rst_err = ( unsigned char* ) frealloc( rst_err, ( scnc + 1 ) * sizeof( char ) );
							if ( rst_err == NULL ) {
								snprintf( errormessage, MSG_SIZE, MEM_ERRMSG );
								errorlevel = 2;
								// Fix #34: cleanup before early return.
								delete ( hdrw );
								delete ( huffw );
								free ( segment );
								return false;
							}
							if ( crst > 255 ) {
								snprintf( errormessage, MSG_SIZE, "Severe false use of RST markers (%i)", (int) crst );
								errorlevel = 1;
								crst = 255;
							}
							rst_err[ scnc ] = crst;							
						}
						// end of current scan
						scnc++;
						// on with the header parser routines
						segment[ 0 ] = 0xFF;
						segment[ 1 ] = tmp;
						break;
					}
				}
				else {
					// otherwise this means end-of-file, so break out
					break;
				}
			}
		}
		else {
			// read in next marker
			if ( str_in->read( segment, 2 ) != 2 ) break;
			if ( segment[ 0 ] != 0xFF ) {
				// ugly fix for incorrect marker segment sizes
				snprintf( errormessage, MSG_SIZE, "size mismatch in marker segment FF %2X", type );
				errorlevel = 2;
				if ( type == 0xFE ) { //  if last marker was COM try again
					if ( str_in->read( segment, 2 ) != 2 ) break;
					if ( segment[ 0 ] == 0xFF ) errorlevel = 1;
				}
				if ( errorlevel == 2 ) {
					delete ( hdrw );
					delete ( huffw );
					free ( segment );
					return false;
				}
			}
		}
		
		// read segment type
		type = segment[ 1 ];
		
		// if EOI is encountered make a quick exit
		if ( type == 0xD9 ) {
			// get pointer for header data & size
			hdrdata  = hdrw->get_c_data();
			hdrs     = hdrw->num_bytes_written();
			// get pointer for huffman data & size
			huffdata = huffw->get_c_data();
			hufs     = huffw->num_bytes_written();
			// everything is done here now
			break;			
		}
		
		// read in next segments' length and check it
		if ( str_in->read( segment + 2, 2 ) != 2 ) break;
		len = 2 + B_SHORT( segment[ 2 ], segment[ 3 ] );
		if ( len < 4 ) break;
		
		// realloc segment data if needed
		if ( ssize < len ) {
			segment = ( unsigned char* ) frealloc( segment, len );
			if ( segment == NULL ) {
				snprintf( errormessage, MSG_SIZE, MEM_ERRMSG );
				errorlevel = 2;
				delete ( hdrw );
				delete ( huffw );
				return false;
			}
			ssize = len;
		}
		
		// read rest of segment, store back in header writer
		if ( str_in->read( ( segment + 4 ), ( len - 4 ) ) !=
			( unsigned short ) ( len - 4 ) ) break;
		hdrw->write( segment, len );
	}
	// JPEG reader loop end
	
	// free writers
	delete ( hdrw );
	delete ( huffw );
	
	// check if everything went OK
	if ( ( hdrs == 0 ) || ( hufs == 0 ) ) {
		snprintf( errormessage, MSG_SIZE, "unexpected end of data encountered" );
		errorlevel = 2;
		// Fix #34: segment is not freed until later — free it now before returning.
		free( segment );
		return false;
	}
	
	// store garbage after EOI if needed
	grbs = str_in->read_byte(&tmp);
	if ( grbs > 0 ) {
		grbgw = new MemoryWriter();
		grbgw->write_byte( tmp );
		while( true ) {
			len = str_in->read( segment, ssize );
			if ( len == 0 ) break;
			grbgw->write( segment, len );
		}
		grbgdata = grbgw->get_c_data();
		grbs     = grbgw->num_bytes_written();
		delete grbgw;
	}
	
	// free segment
	free( segment );
	
	// get filesize
	jpgfilesize = str_in->get_size();	
	
	// parse header for image info
	if ( !jpg_setup_imginfo() ) {
		return false;
	}
	
	
	return true;
}


/* -----------------------------------------------
	Merges header & image data to jpeg
	----------------------------------------------- */
	
INTERN bool merge_jpeg( void )
{
	unsigned char SOI[ 2 ] = { 0xFF, 0xD8 }; // SOI segment
	unsigned char EOI[ 2 ] = { 0xFF, 0xD9 }; // EOI segment
	unsigned char mrk = 0xFF; // marker start
	unsigned char stv = 0x00; // 0xFF stuff value
	unsigned char rst = 0xD0; // restart marker
	
	unsigned char  type = 0x00; // type of current marker segment
	unsigned int   len  = 0; // length of current marker segment
	unsigned int   hpos = 0; // current position in header
	unsigned int   ipos = 0; // current position in imagedata
	unsigned int   rpos = 0; // current restart marker position
	unsigned int   cpos = 0; // in scan corrected rst marker position
	unsigned int   scan = 1; // number of current scan
	unsigned int   tmp; // temporary storage variable
	
	
	// write SOI
	str_out->write( SOI, 2 );
	
	// JPEG writing loop
	while ( true )
	{		
		// store current header position
		tmp = hpos;
		
		// seek till start-of-scan
		for ( type = 0x00; type != 0xDA; ) {
			if ( (int)hpos + 4 > hdrs ) break;
			type = hdrdata[ hpos + 1 ];
			len = 2 + B_SHORT( hdrdata[ hpos + 2 ], hdrdata[ hpos + 3 ] );
			hpos += len;
		}

		// write header data to file
		str_out->write( hdrdata + tmp, ( hpos - tmp ) );
		
		// get out if last marker segment type was not SOS
		if ( type != 0xDA ) break;
		
		
		// (re)set corrected rst pos
		cpos = 0;
		
		// write & expand huffman coded image data
		for ( ipos = scnp[ scan - 1 ]; ipos < scnp[ scan ]; ipos++ ) {
			// write current byte
			str_out->write_byte(huffdata[ipos]);
			// check current byte, stuff if needed
			if ( huffdata[ ipos ] == 0xFF )
				str_out->write_byte(stv);
			// insert restart markers if needed
			if ( rstp != NULL ) {
				if ( ipos == rstp[ rpos ] ) {
					rst = 0xD0 + ( cpos % 8 );
					str_out->write_byte(mrk);
					str_out->write_byte(rst);
					rpos++; cpos++;
				}
			}
		}
		// insert false rst markers at end if needed
		if ( rst_err != NULL ) {
			while ( rst_err[ scan - 1 ] > 0 ) {
				rst = 0xD0 + ( cpos % 8 );
				str_out->write_byte(mrk);
				str_out->write_byte(rst);
				cpos++;	rst_err[ scan - 1 ]--;
			}
		}

		// proceed with next scan
		scan++;
	}
	
	// write EOI
	str_out->write( EOI, 2 );
	
	// write garbage if needed
	if ( grbs > 0 )
		str_out->write( grbgdata, grbs );
	
	// errormessage if write error
	if ( str_out->error() ) {
		snprintf( errormessage, MSG_SIZE, "write error, possibly drive is full" );
		errorlevel = 2;		
		return false;
	}
	
	// get filesize: merge_jpeg writes the reconstructed JPG, so set jpgfilesize.
	// pjgfilesize is already set by read_pjg() (input PJG size) and must not be overwritten.
	jpgfilesize = str_out->num_bytes_written();
	
	
	return true;
}


/* -----------------------------------------------
	JPEG decoding routine
	----------------------------------------------- */

INTERN bool decode_jpeg( void )
{
	BitReader* huffr; // bitwise reader for image data
	
	unsigned char  type = 0x00; // type of current marker segment
	unsigned int   len  = 0; // length of current marker segment
	unsigned int   hpos = 0; // current position in header
	
	int lastdc[ 4 ]; // last dc for each component
	short block[ 64 ]; // store block for coeffs
	int peobrun; // previous eobrun
	int eobrun; // run of eobs
	int rstw; // restart wait counter
	
	int cmp, bpos, dpos;
	int mcu, sub, csc;
	int eob, sta;
	
	
	// open huffman coded image data for input in BitReader
	huffr = new BitReader( huffdata, hufs );
	
	// preset count of scans
	scnc = 0;
	
	// JPEG decompression loop
	while ( true )
	{
		// seek till start-of-scan, parse only DHT, DRI and SOS
		for ( type = 0x00; type != 0xDA; ) {
			if ( (int)hpos + 4 > hdrs ) break;
			type = hdrdata[ hpos + 1 ];
			len = 2 + B_SHORT( hdrdata[ hpos + 2 ], hdrdata[ hpos + 3 ] );
			if ( ( type == 0xC4 ) || ( type == 0xDA ) || ( type == 0xDD ) ) {
				if ( !jpg_parse_jfif( type, len, &( hdrdata[ hpos ] ) ) ) {
					delete huffr;
					return false;
				}
			}
			hpos += len;
		}
		
		// get out if last marker segment type was not SOS
		if ( type != 0xDA ) break;
		
		// check if huffman tables are available
		for ( csc = 0; csc < cs_cmpc; csc++ ) {
			cmp = cs_cmp[ csc ];
			if ( ( ( jpegtype == 1 || ( ( cs_cmpc > 1 || cs_to == 0 ) && cs_sah == 0 ) ) && htset[ 0 ][ cmpnfo[cmp].huffdc ] == 0 ) || 
			   ( jpegtype == 1 && htset[ 1 ][ cmpnfo[cmp].huffdc ] == 0 ) ||
			   ( cs_cmpc == 1 && cs_to > 0 && cs_sah == 0 && htset[ 1 ][ cmpnfo[cmp].huffac ] == 0 ) ) {
				snprintf( errormessage, MSG_SIZE, "huffman table missing in scan%i", scnc );
				delete huffr;
				errorlevel = 2;
				return false;
			}
		}
		
		
		// intial variables set for decoding
		cmp  = cs_cmp[ 0 ];
		csc  = 0;
		mcu  = 0;
		sub  = 0;
		dpos = 0;
		
		// JPEG imagedata decoding routines
		while ( true )
		{			
			// (re)set last DCs for diff coding
			lastdc[ 0 ] = 0;
			lastdc[ 1 ] = 0;
			lastdc[ 2 ] = 0;
			lastdc[ 3 ] = 0;
			
			// (re)set status
			eob = 0;
			sta = 0;
			
			// (re)set eobrun
			eobrun  = 0;
			peobrun = 0;
			
			// (re)set rst wait counter
			rstw = rsti;
			
			// decoding for interleaved data
			if ( cs_cmpc > 1 )
			{				
				if ( jpegtype == 1 ) {
					// ---> sequential interleaved decoding <---
					while ( sta == 0 ) {
						// decode block
						eob = jpg_decode_block_seq( huffr,
							&(htrees[ 0 ][ cmpnfo[cmp].huffdc ]),
							&(htrees[ 1 ][ cmpnfo[cmp].huffdc ]),
							block );
						
						// check for non optimal coding
						if ( ( eob > 1 ) && ( block[ eob - 1 ] == 0 ) ) {
							snprintf( errormessage, MSG_SIZE, "reconstruction of inefficient coding not supported" );
							errorlevel = 1;
						}
						
						// fix dc
						block[ 0 ] += lastdc[ cmp ];
						lastdc[ cmp ] = block[ 0 ];
						
						// copy to colldata
						for ( bpos = 0; bpos < eob; bpos++ )
							colldata[ cmp ][ bpos ][ dpos ] = block[ bpos ];
						
						// check for errors, proceed if no error encountered
						if ( eob < 0 ) sta = -1;
						else sta = jpg_next_mcupos( &mcu, &cmp, &csc, &sub, &dpos, &rstw );
					}
				}
				else if ( cs_sah == 0 ) {
					// ---> progressive interleaved DC decoding <---
					// ---> succesive approximation first stage <---
					while ( sta == 0 ) {
						sta = jpg_decode_dc_prg_fs( huffr,
							&(htrees[ 0 ][ cmpnfo[cmp].huffdc ]),
							block );
						
						// fix dc for diff coding
						colldata[cmp][0][dpos] = block[0] + lastdc[ cmp ];
						lastdc[ cmp ] = colldata[cmp][0][dpos];
						
						// bitshift for succesive approximation (cast avoids UB
						// when the coefficient value is negative — C++17 §8.8)
						colldata[cmp][0][dpos] = (short)( (unsigned int)colldata[cmp][0][dpos] << cs_sal );

						// next mcupos if no error happened
						if ( sta != -1 )
							sta = jpg_next_mcupos( &mcu, &cmp, &csc, &sub, &dpos, &rstw );
					}
				}
				else {
					// ---> progressive interleaved DC decoding <---
					// ---> succesive approximation later stage <---					
					while ( sta == 0 ) {
						// decode next bit
						sta = jpg_decode_dc_prg_sa( huffr,
							block );

						// shift in next bit (cast avoids UB for negative block[0])
						colldata[cmp][0][dpos] += (short)( (unsigned int)block[0] << cs_sal );

						// next mcupos if no error happened
						if ( sta != -1 )
							sta = jpg_next_mcupos( &mcu, &cmp, &csc, &sub, &dpos, &rstw );
					}
				}
			}
			else // decoding for non interleaved data
			{
				if ( jpegtype == 1 ) {
					// ---> sequential non interleaved decoding <---
					while ( sta == 0 ) {
						// decode block
						eob = jpg_decode_block_seq( huffr,
							&(htrees[ 0 ][ cmpnfo[cmp].huffdc ]),
							&(htrees[ 1 ][ cmpnfo[cmp].huffdc ]),
							block );
						
						// check for non optimal coding
						if ( ( eob > 1 ) && ( block[ eob - 1 ] == 0 ) ) {
							snprintf( errormessage, MSG_SIZE, "reconstruction of inefficient coding not supported" );
							errorlevel = 1;
						}
						
						// fix dc
						block[ 0 ] += lastdc[ cmp ];
						lastdc[ cmp ] = block[ 0 ];
						
						// copy to colldata
						for ( bpos = 0; bpos < eob; bpos++ )
							colldata[ cmp ][ bpos ][ dpos ] = block[ bpos ];
						
						// check for errors, proceed if no error encountered
						if ( eob < 0 ) sta = -1;
						else sta = jpg_next_mcuposn( &cmp, &dpos, &rstw );
					}
				}
				else if ( cs_to == 0 ) {					
					if ( cs_sah == 0 ) {
						// ---> progressive non interleaved DC decoding <---
						// ---> succesive approximation first stage <---
						while ( sta == 0 ) {
							sta = jpg_decode_dc_prg_fs( huffr,
								&(htrees[ 0 ][ cmpnfo[cmp].huffdc ]),
								block );
								
							// fix dc for diff coding
							colldata[cmp][0][dpos] = block[0] + lastdc[ cmp ];
							lastdc[ cmp ] = colldata[cmp][0][dpos];

							// bitshift for succesive approximation (UB-safe cast)
							colldata[cmp][0][dpos] = (short)( (unsigned int)colldata[cmp][0][dpos] << cs_sal );

							// check for errors, increment dpos otherwise
							if ( sta != -1 )
								sta = jpg_next_mcuposn( &cmp, &dpos, &rstw );
						}
					}
					else {
						// ---> progressive non interleaved DC decoding <---
						// ---> succesive approximation later stage <---
						while( sta == 0 ) {
							// decode next bit
							sta = jpg_decode_dc_prg_sa( huffr,
								block );

							// shift in next bit (UB-safe cast)
							colldata[cmp][0][dpos] += (short)( (unsigned int)block[0] << cs_sal );

							// check for errors, increment dpos otherwise
							if ( sta != -1 )
								sta = jpg_next_mcuposn( &cmp, &dpos, &rstw );
						}
					}
				}
				else {
					if ( cs_sah == 0 ) {
						// ---> progressive non interleaved AC decoding <---
						// ---> succesive approximation first stage <---
						while ( sta == 0 ) {
							if ( eobrun == 0 ) {
								// decode block
								eob = jpg_decode_ac_prg_fs( huffr,
									&(htrees[ 1 ][ cmpnfo[cmp].huffac ]),
									block, &eobrun, cs_from, cs_to );
								
								if ( eobrun > 0 ) {
									// check for non optimal coding
									if ( ( eob == cs_from )  && ( peobrun > 0 ) &&
										( peobrun <	hcodes[ 1 ][ cmpnfo[cmp].huffac ].max_eobrun - 1 ) ) {
										snprintf( errormessage, MSG_SIZE,
											"reconstruction of inefficient coding not supported" );
										errorlevel = 1;
									}
									peobrun = eobrun;
									eobrun--;
								} else peobrun = 0;
							
								// copy to colldata (UB-safe cast for negative coeffs)
								for ( bpos = cs_from; bpos < eob; bpos++ )
									colldata[ cmp ][ bpos ][ dpos ] = (short)( (unsigned int)block[ bpos ] << cs_sal );
							} else eobrun--;
							
							// check for errors
							if ( eob < 0 ) sta = -1;
							else sta = jpg_skip_eobrun( &cmp, &dpos, &rstw, &eobrun );
							
							// proceed only if no error encountered
							if ( sta == 0 )
								sta = jpg_next_mcuposn( &cmp, &dpos, &rstw );
						}
					}
					else {
						// ---> progressive non interleaved AC decoding <---
						// ---> succesive approximation later stage <---
						while ( sta == 0 ) {
							// copy from colldata
							for ( bpos = cs_from; bpos <= cs_to; bpos++ )
								block[ bpos ] = colldata[ cmp ][ bpos ][ dpos ];
							
							if ( eobrun == 0 ) {
								// decode block (long routine)
								eob = jpg_decode_ac_prg_sa( huffr,
									&(htrees[ 1 ][ cmpnfo[cmp].huffac ]),
									block, &eobrun, cs_from, cs_to );
								
								if ( eobrun > 0 ) {
									// check for non optimal coding
									if ( ( eob == cs_from ) && ( peobrun > 0 ) &&
										( peobrun < hcodes[ 1 ][ cmpnfo[cmp].huffac ].max_eobrun - 1 ) ) {
										snprintf( errormessage, MSG_SIZE,
											"reconstruction of inefficient coding not supported" );
										errorlevel = 1;
									}
									
									// store eobrun
									peobrun = eobrun;
									eobrun--;
								} else peobrun = 0;
							}
							else {
								// decode block (short routine)
								eob = jpg_decode_eobrun_sa( huffr,
									block, &eobrun, cs_from, cs_to );
								eobrun--;
							}
								
							// copy back to colldata (UB-safe cast for negative coeffs)
							for ( bpos = cs_from; bpos <= cs_to; bpos++ )
								colldata[ cmp ][ bpos ][ dpos ] += (short)( (unsigned int)block[ bpos ] << cs_sal );
							
							// proceed only if no error encountered
							if ( eob < 0 ) sta = -1;
							else sta = jpg_next_mcuposn( &cmp, &dpos, &rstw );
						}
					}
				}
			}			
			
			// unpad huffman reader / check padbit
			if ( padbit != -1 ) {
				if ( padbit != huffr->unpad( padbit ) ) {
					snprintf( errormessage, MSG_SIZE, "inconsistent use of padbits" );
					padbit = 1;
					errorlevel = 1;
				}
			}
			else {
				padbit = huffr->unpad( padbit );
			}
			
			// evaluate status
			if ( sta == -1 ) { // status -1 means error
				// Entropy decode errors (errorlevel=2) indicate a malformed Huffman
				// stream — this is NOT recoverable via -p (which only relaxes
				// warnings). Typical causes: corrupted bitstream, out-of-bounds AC
				// run-length, extraneous bytes before RST markers. Such files
				// are usually rejected by `djpeg -strict` too. lossless
				// recompression cannot preserve these non-conformant encodings.
				snprintf( errormessage, MSG_SIZE,
					"decode error in scan%i / mcu%i — malformed JPEG bitstream (verify with: djpeg -strict)",
					scnc, ( cs_cmpc > 1 ) ? mcu : dpos );
				delete huffr;
				errorlevel = 2;
				return false;
			}
			else if ( sta == 2 ) { // status 2/3 means done
				scnc++; // increment scan counter
				break; // leave decoding loop, everything is done here
			}
			// else if ( sta == 1 ); // status 1 means restart - so stay in the loop
		}
	}
	
	// check for missing data
	if ( huffr->peof() > 0 ) {
		snprintf( errormessage, MSG_SIZE, "coded image data truncated / too short" );
		errorlevel = 1;
	}
	
	// check for surplus data
	if ( !huffr->eof()) {
		snprintf( errormessage, MSG_SIZE, "surplus data found after coded image data" );
		errorlevel = 1;
	}
	
	// clean up
	delete( huffr );
	
	
	return true;
}


/* -----------------------------------------------
	JPEG encoding routine
	----------------------------------------------- */

INTERN bool recode_jpeg( void )
{
	BitWriter*  huffw; // bitwise writer for image data
	
	unsigned char  type = 0x00; // type of current marker segment
	unsigned int   len  = 0; // length of current marker segment
	unsigned int   hpos = 0; // current position in header
		
	int lastdc[ 4 ]; // last dc for each component0
	short block[ 64 ]; // store block for coeffs
	int eobrun; // run of eobs
	int rstw; // restart wait counter
	
	int cmp, bpos, dpos;
	int mcu, sub, csc;
	int eob, sta;
	int tmp;
	
	
	// open huffman coded image data in BitWriter
	// Opt: pre-reserve hufs bytes to avoid reallocs — output will be close to input size.
	huffw = new BitWriter(padbit, hufs);
	
	// init storage writer
	std::vector<std::uint8_t> storw; // Storage for correction bits.
	
	// preset count of scans and restarts
	scnc = 0;
	rstc = 0;
	
	// JPEG decompression loop
	while ( true )
	{
		// seek till start-of-scan, parse only DHT, DRI and SOS
		for ( type = 0x00; type != 0xDA; ) {
			if ( (int)hpos + 4 > hdrs ) break;
			type = hdrdata[ hpos + 1 ];
			len = 2 + B_SHORT( hdrdata[ hpos + 2 ], hdrdata[ hpos + 3 ] );
			if ( ( type == 0xC4 ) || ( type == 0xDA ) || ( type == 0xDD ) ) {
				if ( !jpg_parse_jfif( type, len, &( hdrdata[ hpos ] ) ) ) {
					return false;
				}
				hpos += len;
			}
			else {
				hpos += len;
				continue;
			}			
		}
		
		// get out if last marker segment type was not SOS
		if ( type != 0xDA ) break;
		
		
		// (re)alloc scan positons array
		if ( scnp == NULL ) scnp = ( unsigned int* ) calloc( scnc + 2, sizeof( int ) );
		else scnp = ( unsigned int* ) frealloc( scnp, ( scnc + 2 ) * sizeof( int ) );
		if ( scnp == NULL ) {
			snprintf( errormessage, MSG_SIZE, MEM_ERRMSG );
			errorlevel = 2;
			return false;
		}
		
		// (re)alloc restart marker positons array if needed
		if ( rsti > 0 ) {
			tmp = rstc + ( ( cs_cmpc > 1 ) ?
				( mcuc / rsti ) : ( cmpnfo[ cs_cmp[ 0 ] ].bc / rsti ) );
			if ( rstp == NULL ) rstp = ( unsigned int* ) calloc( tmp + 1, sizeof( int ) );
			else rstp = ( unsigned int* ) frealloc( rstp, ( tmp + 1 ) * sizeof( int ) );
			if ( rstp == NULL ) {
				snprintf( errormessage, MSG_SIZE, MEM_ERRMSG );
				errorlevel = 2;
				return false;
			}
		}		
		
		// intial variables set for encoding
		cmp  = cs_cmp[ 0 ];
		csc  = 0;
		mcu  = 0;
		sub  = 0;
		dpos = 0;
		
		// store scan position
		scnp[ scnc ] = huffw->num_bytes_written();
		
		// JPEG imagedata encoding routines
		while ( true )
		{
			// (re)set last DCs for diff coding
			lastdc[ 0 ] = 0;
			lastdc[ 1 ] = 0;
			lastdc[ 2 ] = 0;
			lastdc[ 3 ] = 0;
			
			// (re)set status
			sta = 0;
			
			// (re)set eobrun
			eobrun = 0;
			
			// (re)set rst wait counter
			rstw = rsti;
			
			// encoding for interleaved data
			if ( cs_cmpc > 1 )
			{				
				if ( jpegtype == 1 ) {
					// ---> sequential interleaved encoding <---
					while ( sta == 0 ) {
						// copy from colldata
						for ( bpos = 0; bpos < 64; bpos++ )
							block[ bpos ] = colldata[ cmp ][ bpos ][ dpos ];
						
						// diff coding for dc
						block[ 0 ] -= lastdc[ cmp ];
						lastdc[ cmp ] = colldata[ cmp ][ 0 ][ dpos ];
						
						// encode block
						eob = jpg_encode_block_seq( huffw,
							&(hcodes[ 0 ][ cmpnfo[cmp].huffdc ]),
							&(hcodes[ 1 ][ cmpnfo[cmp].huffac ]),
							block );
						
						// check for errors, proceed if no error encountered
						if ( eob < 0 ) sta = -1;
						else sta = jpg_next_mcupos( &mcu, &cmp, &csc, &sub, &dpos, &rstw );
					}
				}
				else if ( cs_sah == 0 ) {
					// ---> progressive interleaved DC encoding <---
					// ---> succesive approximation first stage <---
					while ( sta == 0 ) {
						// diff coding & bitshifting for dc 
						tmp = colldata[ cmp ][ 0 ][ dpos ] >> cs_sal;
						block[ 0 ] = tmp - lastdc[ cmp ];
						lastdc[ cmp ] = tmp;
						
						// encode dc
						sta = jpg_encode_dc_prg_fs( huffw,
							&(hcodes[ 0 ][ cmpnfo[cmp].huffdc ]),
							block );
						
						// next mcupos if no error happened
						if ( sta != -1 )
							sta = jpg_next_mcupos( &mcu, &cmp, &csc, &sub, &dpos, &rstw );
					}
				}
				else {
					// ---> progressive interleaved DC encoding <---
					// ---> succesive approximation later stage <---
					while ( sta == 0 ) {
						// fetch bit from current bitplane
						block[ 0 ] = BITN( colldata[ cmp ][ 0 ][ dpos ], cs_sal );
						
						// encode dc correction bit
						sta = jpg_encode_dc_prg_sa( huffw, block );
						
						// next mcupos if no error happened
						if ( sta != -1 )
							sta = jpg_next_mcupos( &mcu, &cmp, &csc, &sub, &dpos, &rstw );
					}
				}
			}
			else // encoding for non interleaved data
			{
				if ( jpegtype == 1 ) {
					// ---> sequential non interleaved encoding <---
					while ( sta == 0 ) {
						// copy from colldata
						for ( bpos = 0; bpos < 64; bpos++ )
							block[ bpos ] = colldata[ cmp ][ bpos ][ dpos ];
						
						// diff coding for dc
						block[ 0 ] -= lastdc[ cmp ];
						lastdc[ cmp ] = colldata[ cmp ][ 0 ][ dpos ];
						
						// encode block
						eob = jpg_encode_block_seq( huffw,
							&(hcodes[ 0 ][ cmpnfo[cmp].huffdc ]),
							&(hcodes[ 1 ][ cmpnfo[cmp].huffac ]),
							block );
						
						// check for errors, proceed if no error encountered
						if ( eob < 0 ) sta = -1;
						else sta = jpg_next_mcuposn( &cmp, &dpos, &rstw );	
					}
				}
				else if ( cs_to == 0 ) {
					if ( cs_sah == 0 ) {
						// ---> progressive non interleaved DC encoding <---
						// ---> succesive approximation first stage <---
						while ( sta == 0 ) {
							// diff coding & bitshifting for dc 
							tmp = colldata[ cmp ][ 0 ][ dpos ] >> cs_sal;
							block[ 0 ] = tmp - lastdc[ cmp ];
							lastdc[ cmp ] = tmp;
							
							// encode dc
							sta = jpg_encode_dc_prg_fs( huffw,
								&(hcodes[ 0 ][ cmpnfo[cmp].huffdc ]),
								block );							
							
							// check for errors, increment dpos otherwise
							if ( sta != -1 )
								sta = jpg_next_mcuposn( &cmp, &dpos, &rstw );
						}
					}
					else {
						// ---> progressive non interleaved DC encoding <---
						// ---> succesive approximation later stage <---
						while ( sta == 0 ) {
							// fetch bit from current bitplane
							block[ 0 ] = BITN( colldata[ cmp ][ 0 ][ dpos ], cs_sal );
							
							// encode dc correction bit
							sta = jpg_encode_dc_prg_sa( huffw, block );
							
							// next mcupos if no error happened
							if ( sta != -1 )
								sta = jpg_next_mcuposn( &cmp, &dpos, &rstw );
						}
					}
				}
				else {
					if ( cs_sah == 0 ) {
						// ---> progressive non interleaved AC encoding <---
						// ---> succesive approximation first stage <---
						while ( sta == 0 ) {
							// copy from colldata
							for ( bpos = cs_from; bpos <= cs_to; bpos++ )
								block[ bpos ] =
									FDIV2( colldata[ cmp ][ bpos ][ dpos ], cs_sal );
							
							// encode block
							eob = jpg_encode_ac_prg_fs( huffw,
								&(hcodes[ 1 ][ cmpnfo[cmp].huffac ]),
								block, &eobrun, cs_from, cs_to );
							
							// check for errors, proceed if no error encountered
							if ( eob < 0 ) sta = -1;
							else sta = jpg_next_mcuposn( &cmp, &dpos, &rstw );
						}						
						
						// encode remaining eobrun
						jpg_encode_eobrun( huffw,
							&(hcodes[ 1 ][ cmpnfo[cmp].huffac ]),
							&eobrun );
					}
					else {
						// ---> progressive non interleaved AC encoding <---
						// ---> succesive approximation later stage <---
						while ( sta == 0 ) {
							// copy from colldata
							for ( bpos = cs_from; bpos <= cs_to; bpos++ )
								block[ bpos ] =
									FDIV2( colldata[ cmp ][ bpos ][ dpos ], cs_sal );
							
							// encode block
							eob = jpg_encode_ac_prg_sa( huffw, storw,
								&(hcodes[ 1 ][ cmpnfo[cmp].huffac ]),
								block, &eobrun, cs_from, cs_to );
							
							// check for errors, proceed if no error encountered
							if ( eob < 0 ) sta = -1;
							else sta = jpg_next_mcuposn( &cmp, &dpos, &rstw );
						}						
						
						// encode remaining eobrun
						jpg_encode_eobrun( huffw,
							&(hcodes[ 1 ][ cmpnfo[cmp].huffac ]),
							&eobrun );
							
						// encode remaining correction bits
						jpg_encode_crbits( huffw, storw );
					}
				}
			}
			
			// pad huffman writer
			huffw->pad();
			
			// evaluate status
			if ( sta == -1 ) { // status -1 means error
				snprintf( errormessage, MSG_SIZE, "encode error in scan%i / mcu%i",
					scnc, ( cs_cmpc > 1 ) ? mcu : dpos );
				delete huffw;
				errorlevel = 2;
				return false;
			}
			else if ( sta == 2 ) { // status 2 means done
				scnc++; // increment scan counter
				break; // leave decoding loop, everything is done here
			}
			else if ( sta == 1 ) { // status 1 means restart
				if ( rsti > 0 ) // store rstp & stay in the loop
					rstp[ rstc++ ] = huffw->num_bytes_written() - 1;
			}
		}
	}
	
	// get data into huffdata
	huffdata = huffw->get_c_bytes();
	hufs = huffw->num_bytes_written();	
	delete huffw;
	
	// store last scan & restart positions
	scnp[ scnc ] = hufs;
	if ( rstp != NULL )
		rstp[ rstc ] = hufs;
	
	
	return true;
}


/* -----------------------------------------------
	adapt ICOS tables for quantizer tables
	----------------------------------------------- */
	
INTERN bool adapt_icos( void )
{
	// NOTE: adpt_idct_* are TLS-stored arrays (not heap pointers), so worker
	// thread writes would be lost. Keep sequential so results stay in main TLS.
	unsigned short quant[ 64 ];
	for ( int cmp = 0; cmp < cmpc; cmp++ ) {
		for ( int ipos = 0; ipos < 64; ipos++ ) {
			quant[ ipos ] = QUANT( cmp, zigzag[ ipos ] );
			if ( quant[ ipos ] >= 2048 ) quant[ ipos ] = 0;
		}
		for ( int ipos = 0; ipos < 64 * 64; ipos++ )
			adpt_idct_8x8[ cmp ][ ipos ] = icos_idct_8x8[ ipos ] * quant[ ipos % 64 ];
		for ( int ipos = 0; ipos < 8 * 8; ipos++ )
			adpt_idct_1x8[ cmp ][ ipos ] = icos_idct_1x8[ ipos ] * quant[ ( ipos % 8 ) * 8 ];
		for ( int ipos = 0; ipos < 8 * 8; ipos++ )
			adpt_idct_8x1[ cmp ][ ipos ] = icos_idct_1x8[ ipos ] * quant[ ipos % 8 ];
	}
	return true;
}


/* -----------------------------------------------
	filter DC coefficients
	----------------------------------------------- */

INTERN bool predict_dc( void )
{
	// -sfth: each cmp writes only to colldata[cmp][0] — no cross deps.
	// make_tls_init copies adpt_idct tables needed by dc_1ddct_predictor.
	int n = cmpc;
	return par_pre_pack( n, []( int cmp ) -> bool {
		int absmaxp = MAX_V( cmp, 0 );
		int absmaxn = -absmaxp;
		int corr_f  = ( 2 * absmaxp ) + 1;
		for ( int dpos = cmpnfo[cmp].bc - 1; dpos > 0; dpos-- ) {
			signed short* coef = &(colldata[cmp][0][dpos]);
			#if defined( USE_PLOCOI )
			(*coef) -= dc_coll_predictor( cmp, dpos );
			#else
			(*coef) -= dc_1ddct_predictor( cmp, dpos );
			#endif
			if      ( (*coef) > absmaxp ) (*coef) -= corr_f;
			else if ( (*coef) < absmaxn ) (*coef) += corr_f;
		}
		return true;
	} );
}


/* -----------------------------------------------
	unpredict DC coefficients
	----------------------------------------------- */

INTERN bool unpredict_dc( void )
{	
	signed short* coef;
	int absmaxp;
	int absmaxn;
	int corr_f;
	int cmp, dpos;
	
	
	// remove prediction, store DC instead of prediction error
	for ( cmp = 0; cmp < cmpc; cmp++ ) {
		absmaxp = MAX_V( cmp, 0 );
		absmaxn = -absmaxp;
		corr_f = ( ( 2 * absmaxp ) + 1 );
		
		for ( dpos = 1; dpos < cmpnfo[cmp].bc; dpos++ ) {
			coef = &(colldata[cmp][0][dpos]);
			#if defined( USE_PLOCOI )
			(*coef) += dc_coll_predictor( cmp, dpos ); // loco-i predictor
			#else
			(*coef) += dc_1ddct_predictor( cmp, dpos ); // 1d dct predictor
			#endif
			
			// fix range
			if ( (*coef) > absmaxp ) (*coef) -= corr_f;
			else if ( (*coef) < absmaxn ) (*coef) += corr_f;
		}
	}
	
	
	return true;
}


/* -----------------------------------------------
	checks range of values, error if out of bounds
	----------------------------------------------- */

INTERN bool check_value_range( void )
{
	// Out of range should never happen with unmodified JPEGs.
	// Use minmax_element so the compiler can auto-vectorize the inner scan.
	for ( int cmp = 0; cmp < cmpc; cmp++ )
	for ( int bpos = 0; bpos < 64; bpos++ ) {
		const int bc = cmpnfo[cmp].bc;
		if ( bc == 0 ) continue;
		const int absmax = MAX_V( cmp, bpos );
		const signed short* data = colldata[cmp][bpos];
		const auto [lo, hi] = std::minmax_element( data, data + bc );
		if ( *hi > absmax || *lo < -absmax ) {
			const int bad = ( *hi > absmax ) ? *hi : *lo;
			snprintf( errormessage, MSG_SIZE, "value out of range error: cmp%i, frq%i, val %i, max %i",
					cmp, bpos, bad, absmax );
			errorlevel = 2;
			return false;
		}
	}

	return true;
}


/* -----------------------------------------------
	calculate zero distribution lists
	----------------------------------------------- */
	
INTERN bool calc_zdst_lists( void )
{
	// -sfth: each cmp writes only its own zdst arrays — no cross deps.
	int n = cmpc;
	return par_pre_pack( n, []( int cmp ) -> bool {
		memset( zdstdata[cmp], 0, cmpnfo[cmp].bc * sizeof( char ) );
		for ( int bpos = 1; bpos < 64; bpos++ ) {
			int b_x = unzigzag[ bpos ] % 8;
			int b_y = unzigzag[ bpos ] / 8;
			if ( b_x == 0 ) {
				for ( int dpos = 0; dpos < cmpnfo[cmp].bc; dpos++ )
					if ( colldata[cmp][bpos][dpos] != 0 ) zdstylow[cmp][dpos]++;
			} else if ( b_y == 0 ) {
				for ( int dpos = 0; dpos < cmpnfo[cmp].bc; dpos++ )
					if ( colldata[cmp][bpos][dpos] != 0 ) zdstxlow[cmp][dpos]++;
			} else {
				for ( int dpos = 0; dpos < cmpnfo[cmp].bc; dpos++ )
					if ( colldata[cmp][bpos][dpos] != 0 ) zdstdata[cmp][dpos]++;
			}
		}
		return true;
	} );
}


/* -----------------------------------------------
	packs all parts to compressed pjg
	----------------------------------------------- */
	
INTERN bool pack_pjg( void )
{
	unsigned char hcode;
	int cmp;
	#if defined(DEV_INFOS)
	int dev_size = 0;
	#endif

	// Reset feature flags on main thread; sequential path and sfth workers
	// re-enable below. Sfth workers set their own TLS after tls().
	pjg_use_crosscomp_now = false;
	pjg_use_diag_dc_now   = false;

	// PJG-Header
	str_out->write( reinterpret_cast<const unsigned char*>(pjg_magic), 2 );
	
	// store settings if not auto
	if ( !auto_set ) {
		hcode = 0x00;
		str_out->write_byte(hcode);
		str_out->write( nois_trs, 4 );
		str_out->write( segm_cnt, 4 );
	}
	
	// -sfth: parallel component encoding path (new format, faster, incompatible with stable)
	if ( sfth_mode && cmpc > 1 ) {
		// Write markers BEFORE version so decoder loop processes them first.
		// 0x01 = sfth parallel format, 0x02 = v4.0b features (diagonal DC ctx).
		str_out->write_byte( 0x01 );
		str_out->write_byte( 0x02 );
		hcode = format_version_current;
		str_out->write_byte( hcode );

		// Encode shared header into a bounded MemoryWriter, prefix its size.
		// The decoder reads exactly this many bytes keeping stream aligned.
		{
			MemoryWriter hdr_mw;
			{
				ArithmeticEncoder enc( hdr_mw );
				if ( disc_meta ) if ( !jpg_rebuild_header() ) return false;
				if ( !pjg_optimize_header() ) return false;
				if ( padbit == -1 ) padbit = 1;
				if ( !pjg_encode_generic( &enc, hdrdata, hdrs ) ) return false;
				if ( !pjg_encode_bit( &enc, padbit ) ) return false;
				if ( !pjg_encode_bit( &enc, (rst_err == NULL) ? 0 : 1 ) ) return false;
				if ( rst_err != NULL )
					if ( !pjg_encode_generic( &enc, rst_err, scnc ) ) return false;
			} // enc finalizes here
			uint32_t hsz = (uint32_t) hdr_mw.num_bytes_written();
			uint8_t hle[4] = { (uint8_t)hsz, (uint8_t)(hsz>>8), (uint8_t)(hsz>>16), (uint8_t)(hsz>>24) };
			str_out->write( hle, 4 );
			str_out->write( hdr_mw.get_data() );
		}

		// Encode each component into its own MemoryWriter in parallel.
		// make_tls_init() snapshots TLS so each worker sees the current file's data.
		// Cross-comp is safe in parallel on encode: colldata[0] is pre-populated
		// read-only by jpg_decode() before pack_pjg() runs, so all workers read Y.
		std::vector<std::vector<uint8_t>> cmp_bufs( cmpc );
		std::vector<std::string> cmp_errs( cmpc );
		std::atomic<bool> any_err{ false };
		auto tls = make_tls_init();
		std::vector<std::future<void>> futs;
		futs.reserve( cmpc );
		for ( int c = 0; c < cmpc; c++ ) {
			futs.push_back( std::async( std::launch::async, [&, c]() {
				tls();
				pjg_use_crosscomp_now = true; // v4.0b always-on
				pjg_use_diag_dc_now   = true; // v4.0b always-on
				MemoryWriter mw;
				{
					ArithmeticEncoder enc( mw );
					bool ok =
						pjg_encode_zstscan  ( &enc, c ) &&
						pjg_encode_zdst_high( &enc, c ) &&
						pjg_encode_ac_high  ( &enc, c ) &&
						pjg_encode_zdst_low ( &enc, c ) &&
						pjg_encode_ac_low   ( &enc, c ) &&
						pjg_encode_dc       ( &enc, c );
					if ( !ok ) { cmp_errs[c] = errormessage; any_err.store(true); return; }
				} // enc finalizes here
				cmp_bufs[c] = mw.get_data();
			} ) );
		}
		for ( auto& f : futs ) f.get();
		if ( any_err.load() ) {
			for ( int c = 0; c < cmpc; c++ )
				if ( !cmp_errs[c].empty() ) {
					strncpy( errormessage, cmp_errs[c].c_str(), MSG_SIZE-1 );
					errormessage[MSG_SIZE-1] = '\0'; break;
				}
			errorlevel = 2; return false;
		}
		// Write component count + per-component sizes + streams
		str_out->write_byte( (uint8_t) cmpc );
		for ( int c = 0; c < cmpc; c++ ) {
			uint32_t sz = (uint32_t) cmp_bufs[c].size();
			uint8_t le[4] = { (uint8_t)sz, (uint8_t)(sz>>8), (uint8_t)(sz>>16), (uint8_t)(sz>>24) };
			str_out->write( le, 4 );
		}
		for ( int c = 0; c < cmpc; c++ ) str_out->write( cmp_bufs[c] );
		// Garbage (sequential, after component streams)
		{
			ArithmeticEncoder enc( *str_out );
			bool ok = pjg_encode_bit( &enc, (grbs > 0) ? 1 : 0 ) &&
			          ( grbs == 0 || pjg_encode_generic( &enc, grbgdata, grbs ) );
			if ( !ok ) return false;
		}
		if ( str_out->error() ) {
			snprintf( errormessage, MSG_SIZE, "write error, possibly drive is full" );
			errorlevel = 2; return false;
		}
		pjgfilesize = str_out->num_bytes_written();
		return true;
	}

	// ── Sequential path (default) ──────────────────────────────────────────────
	// Write 0x02 sub-marker BEFORE version byte to signal v4.0b features
	// (diagonal DC ctx). v4.0/v4.0a binaries reading this hit "unknown header
	// code" → clean error. v4.0b binaries reading v4.0a files (no 0x02) keep
	// pjg_use_diag_dc_now = false → backward-compatible decoding.
	str_out->write_byte( 0x02 );
	// store version number
	hcode = format_version_current;
	str_out->write_byte(hcode);

	// v4.0b sequential: cross-component DC + diag DC ctx always on.
	// (sfth path keeps components parallel and cannot read Y during Cb/Cr
	// decode — sets crosscomp false in workers, but diag is component-internal
	// and stays on.)
	pjg_use_crosscomp_now = true;
	pjg_use_diag_dc_now   = true;

	// init arithmetic compression
	auto encoder = new ArithmeticEncoder(*str_out);
	
	// discard meta information from header if option set
	if ( disc_meta )
		if ( !jpg_rebuild_header() ) return false;	
	// optimize header for compression
	if ( !pjg_optimize_header() ) return false;	
	// set padbit to 1 if previously unset
	if ( padbit == -1 )	padbit = 1;
	
	// encode JPG header
	#if !defined(DEV_INFOS)	
	if ( !pjg_encode_generic( encoder, hdrdata, hdrs ) ) return false;
	#else
	dev_size = str_out->getpos();
	if ( !pjg_encode_generic( encoder, hdrdata, hdrs ) ) return false;
	dev_size_hdr += str_out->getpos() - dev_size;
	#endif
	// store padbit (padbit can't be retrieved from the header)
	if ( !pjg_encode_bit( encoder, padbit ) ) return false;	
	// also encode one bit to signal false/correct use of RST markers
	if ( !pjg_encode_bit( encoder, ( rst_err == NULL ) ? 0 : 1 ) ) return false;
	// encode # of false set RST markers per scan
	if ( rst_err != NULL )
		if ( !pjg_encode_generic( encoder, rst_err, scnc ) ) return false;
	
	// encode actual components data
	for ( cmp = 0; cmp < cmpc; cmp++ ) {		
		#if !defined(DEV_INFOS)
		// encode frequency scan ('zero-sort-scan')
		if ( !pjg_encode_zstscan( encoder, cmp ) ) return false;
		// encode zero-distribution-lists for higher (7x7) ACs
		if ( !pjg_encode_zdst_high( encoder, cmp ) ) return false;
		// encode coefficients for higher (7x7) ACs
		if ( !pjg_encode_ac_high( encoder, cmp ) ) return false;
		// encode zero-distribution-lists for lower ACs
		if ( !pjg_encode_zdst_low( encoder, cmp ) ) return false;
		// encode coefficients for first row / collumn ACs
		if ( !pjg_encode_ac_low( encoder, cmp ) ) return false;
		// encode coefficients for DC
		if ( !pjg_encode_dc( encoder, cmp ) ) return false;		
		#else
		dev_size = str_out->getpos();
		// encode frequency scan ('zero-sort-scan')
		if ( !pjg_encode_zstscan( encoder, cmp ) ) return false;		
		dev_size_zsr[ cmp ] += str_out->getpos() - dev_size;
		dev_size = str_out->getpos();
		// encode zero-distribution-lists for higher (7x7) ACs
		if ( !pjg_encode_zdst_high( encoder, cmp ) ) return false;
		dev_size_zdh[ cmp ] += str_out->getpos() - dev_size;
		dev_size = str_out->getpos();
		// encode coefficients for higher (7x7) ACs
		if ( !pjg_encode_ac_high( encoder, cmp ) ) return false;
		dev_size_ach[ cmp ] += str_out->getpos() - dev_size;
		dev_size = str_out->getpos();
		// encode zero-distribution-lists for lower ACs
		if ( !pjg_encode_zdst_low( encoder, cmp ) ) return false;
		dev_size_zdl[ cmp ] += str_out->getpos() - dev_size;
		dev_size = str_out->getpos();
		// encode coefficients for first row / collumn ACs
		if ( !pjg_encode_ac_low( encoder, cmp ) ) return false;
		dev_size_acl[ cmp ] += str_out->getpos() - dev_size;
		dev_size = str_out->getpos();
		// encode coefficients for DC
		if ( !pjg_encode_dc( encoder, cmp ) ) return false;
		dev_size_dc[ cmp ] += str_out->getpos() - dev_size;
		dev_size_cmp[ cmp ] = 
			dev_size_zsr[ cmp ] + dev_size_zdh[ cmp ] +	dev_size_zdl[ cmp ] +
			dev_size_ach[ cmp ] + dev_size_acl[ cmp ] +	dev_size_dc[ cmp ];
		#endif
	}
	
	// encode checkbit for garbage (0 if no garbage, 1 if garbage has to be coded)
	if ( !pjg_encode_bit( encoder, ( grbs > 0 ) ? 1 : 0 ) ) return false;
	// encode garbage data only if needed
	if ( grbs > 0 )
		if ( !pjg_encode_generic( encoder, grbgdata, grbs ) ) return false;
	
	// finalize arithmetic compression
	delete( encoder );
	
	
	// errormessage if write error
	if ( str_out->error() ) {
		snprintf( errormessage, MSG_SIZE, "write error, possibly drive is full" );
		errorlevel = 2;		
		return false;
	}
	
	// get filesize
	pjgfilesize = str_out->num_bytes_written();
	
	
	return true;
}


/* -----------------------------------------------
	unpacks compressed pjg to colldata
	----------------------------------------------- */
	
INTERN bool unpack_pjg( void )
{
	unsigned char hcode;
	unsigned char cb;
	int cmp;
	bool parallel_fmt = false; // set when 0x01 sfth marker seen
	decoded_from_sfth = false; // reset before reading header
	format_version_read = 0;   // reset; set by header loop below
	pjg_use_crosscomp_now = false; // reset; sequential path enables below
	pjg_use_diag_dc_now   = false; // reset; set true if 0x02 sub-marker seen
	bool v40b_features    = false; // local flag tracking 0x02 sub-marker presence
	
	
	// check header codes ( maybe position in other function ? )
	while( true ) {
		if ( !str_in->read_byte(&hcode) ) {
			snprintf( errormessage, MSG_SIZE, "unexpected end of file in PJG header" );
			errorlevel = 2;
			return false;
		}
		if ( hcode == 0x00 ) {
			// retrieve compression settings from file
			str_in->read( nois_trs, 4 );
			str_in->read( segm_cnt, 4 );
			auto_set = false;
		}
		else if ( hcode == 0x01 ) {
			// -sfth parallel format: component streams stored independently
			parallel_fmt = true;
			decoded_from_sfth = true;
		}
		else if ( hcode == 0x02 ) {
			// v4.0b sub-marker: file uses diagonal DC ctx (and any future v4.0b
			// features). Files without this marker (v4.0a or older) decode with
			// pjg_use_diag_dc_now stuck at false → backward-compatible.
			v40b_features = true;
		}
		else if ( hcode >= 0x14 ) {
			// v4.0b accepts version byte 0x28 (40) — both files generated by
			// v4.0/v4.0a (without 0x02 sub-marker) and v4.0b (with 0x02 marker).
			// The marker controls feature gating, not format acceptance.
			if ( hcode != format_version_current ) {
				snprintf( errormessage, MSG_SIZE,
					"incompatible file (version byte 0x%02x); this build accepts 0x%02x.",
					hcode, format_version_current );
				errorlevel = 2;
				return false;
			}
			format_version_read = hcode;
			break;
		}
		else {
			snprintf( errormessage, MSG_SIZE, "unknown header code, use newer version of %s", appname );
			errorlevel = 2;
			return false;
		}
	}
	
	
	if ( parallel_fmt ) {
		// -sfth format: bounded header blob + parallel component streams
		uint8_t hle[4] = {}; str_in->read( hle, 4 );
		uint32_t hsz = (uint32_t)hle[0] | ((uint32_t)hle[1]<<8) |
		               ((uint32_t)hle[2]<<16) | ((uint32_t)hle[3]<<24);
		std::vector<uint8_t> hblob( hsz ); str_in->read( hblob.data(), hsz );
		{
			MemoryReader hmr( hblob ); ArithmeticDecoder hdec( hmr );
			if ( !pjg_decode_generic( &hdec, &hdrdata, &hdrs ) ) return false;
			if ( !pjg_decode_bit( &hdec, &cb ) ) return false;
		padbit = cb;
			if ( !pjg_decode_bit( &hdec, &cb ) ) return false;
			if ( cb == 1 ) if ( !pjg_decode_generic( &hdec, &rst_err, NULL ) ) return false;
			if ( !pjg_unoptimize_header() ) return false;
			if ( disc_meta ) if ( !jpg_rebuild_header() ) return false;
			if ( !jpg_setup_imginfo() ) return false;
		} // hdec destroyed — stream aligned after hblob
		uint8_t ncmps = 0; str_in->read_byte( &ncmps );
		if ( (int)ncmps != cmpc ) {
			snprintf( errormessage, MSG_SIZE, "sfth cmp count mismatch (%i vs %i)", (int)ncmps, cmpc );
			errorlevel = 2; return false;
		}
		std::vector<uint32_t> csizes( cmpc );
		for ( cmp = 0; cmp < cmpc; cmp++ ) {
			uint8_t le[4] = {}; str_in->read( le, 4 );
			csizes[cmp] = (uint32_t)le[0]|((uint32_t)le[1]<<8)|((uint32_t)le[2]<<16)|((uint32_t)le[3]<<24);
		}
		std::vector<std::vector<uint8_t>> cbufs( cmpc );
		for ( cmp = 0; cmp < cmpc; cmp++ ) {
			cbufs[cmp].resize( csizes[cmp] ); str_in->read( cbufs[cmp].data(), csizes[cmp] );
		}
		// v4.0 sfth pipeline: cross-comp reads colldata[0][bpos] during Cb/Cr
		// decode. AC bands partition is disjoint (ac_high=7×7 inner, ac_low=
		// row0+col0, dc=[0,0]), so Cb/Cr need Y's ac_high / ac_low / dc each
		// to complete ONLY before their own matching step — earlier steps
		// (zstscan, zdst_high, zdst_low) have no Y dependency and run in
		// parallel with Y.
		// v4.0b: cc always on (only one accepted format).
		std::vector<std::string> cmp_errs( cmpc );
		std::atomic<bool> any_err{ false };
		auto tls = make_tls_init();

		if ( cmpc >= 2 ) {
			std::promise<void> p_y_ach, p_y_acl, p_y_dc;
			std::shared_future<void> f_y_ach = p_y_ach.get_future().share();
			std::shared_future<void> f_y_acl = p_y_acl.get_future().share();
			std::shared_future<void> f_y_dc  = p_y_dc .get_future().share();

			std::vector<std::future<void>> futs; futs.reserve( cmpc - 1 );
			for ( cmp = 1; cmp < cmpc; cmp++ ) {
				futs.push_back( std::async( std::launch::async,
				                            [&, cmp, v40b_features]() {
					tls();
					pjg_use_crosscomp_now = true;
					pjg_use_diag_dc_now   = v40b_features;
					MemoryReader mr( cbufs[cmp] ); ArithmeticDecoder dec( mr );
					auto fail = [&] { cmp_errs[cmp] = errormessage; any_err.store(true); };
					if ( !pjg_decode_zstscan  ( &dec, cmp ) ) { fail(); return; }
					if ( !pjg_decode_zdst_high( &dec, cmp ) ) { fail(); return; }
					f_y_ach.wait(); if ( any_err.load() ) return;
					if ( !pjg_decode_ac_high  ( &dec, cmp ) ) { fail(); return; }
					if ( !pjg_decode_zdst_low ( &dec, cmp ) ) { fail(); return; }
					f_y_acl.wait(); if ( any_err.load() ) return;
					if ( !pjg_decode_ac_low   ( &dec, cmp ) ) { fail(); return; }
					f_y_dc .wait(); if ( any_err.load() ) return;
					if ( !pjg_decode_dc       ( &dec, cmp ) ) { fail(); return; }
				} ) );
			}

			// Y on main thread — signal after ac_high / ac_low / dc regardless
			// of outcome so workers can observe any_err and unblock.
			pjg_use_crosscomp_now = true;
			pjg_use_diag_dc_now   = v40b_features;
			MemoryReader ymr( cbufs[0] ); ArithmeticDecoder ydec( ymr );
			bool y_ok = pjg_decode_zstscan( &ydec, 0 )
			         && pjg_decode_zdst_high( &ydec, 0 )
			         && pjg_decode_ac_high ( &ydec, 0 );
			if ( !y_ok ) { cmp_errs[0] = errormessage; any_err.store(true); }
			p_y_ach.set_value();
			if ( y_ok ) {
				y_ok = pjg_decode_zdst_low( &ydec, 0 )
				    && pjg_decode_ac_low  ( &ydec, 0 );
				if ( !y_ok ) { cmp_errs[0] = errormessage; any_err.store(true); }
			}
			p_y_acl.set_value();
			if ( y_ok ) {
				y_ok = pjg_decode_dc( &ydec, 0 );
				if ( !y_ok ) { cmp_errs[0] = errormessage; any_err.store(true); }
			}
			p_y_dc.set_value();

			for ( auto& f : futs ) f.get();
		} else {
			// Grayscale sfth (cmpc < 2): no cross-comp meaningful, run components
			// fully parallel. v4.0b: cc_enable disabled implicitly via flag set
			// to false in workers (no Y to read from).
			std::vector<std::future<void>> futs; futs.reserve( cmpc );
			for ( cmp = 0; cmp < cmpc; cmp++ ) {
				futs.push_back( std::async( std::launch::async,
				                            [&, cmp, v40b_features]() {
					tls();
					pjg_use_crosscomp_now = false;
					pjg_use_diag_dc_now   = v40b_features;
					MemoryReader mr( cbufs[cmp] ); ArithmeticDecoder dec( mr );
					bool ok =
						pjg_decode_zstscan  ( &dec, cmp ) && pjg_decode_zdst_high( &dec, cmp ) &&
						pjg_decode_ac_high  ( &dec, cmp ) && pjg_decode_zdst_low ( &dec, cmp ) &&
						pjg_decode_ac_low   ( &dec, cmp ) && pjg_decode_dc       ( &dec, cmp );
					if ( !ok ) { cmp_errs[cmp] = errormessage; any_err.store(true); }
				} ) );
			}
			for ( auto& f : futs ) f.get();
		}
		if ( any_err.load() ) {
			for ( int c = 0; c < cmpc; c++ )
				if ( !cmp_errs[c].empty() ) {
					strncpy( errormessage, cmp_errs[c].c_str(), MSG_SIZE-1 );
					errormessage[MSG_SIZE-1] = '\0'; break;
				}
			errorlevel = 2; return false;
		}
		// Garbage
		ArithmeticDecoder gdec( *str_in );
		if ( !pjg_decode_bit( &gdec, &cb ) ) return false;
		if ( cb == 0 ) grbs = 0;
		else if ( !pjg_decode_generic( &gdec, &grbgdata, &grbs ) ) return false;
	} else {
		// ── Sequential path (default) ──────────────────────────────────────────
		// v4.0b: cross-component DC always on. Diagonal DC ctx gated by 0x02
		// sub-marker presence (true for v4.0b files, false for v4.0/v4.0a).
		pjg_use_crosscomp_now = true;
		pjg_use_diag_dc_now   = v40b_features;
		auto decoder = new ArithmeticDecoder(*str_in);
		if ( !pjg_decode_generic( decoder, &hdrdata, &hdrs ) ) { delete decoder; return false; }
		if ( !pjg_decode_bit(decoder, &cb) ) { delete decoder; return false; }
		padbit = cb;
		if ( !pjg_decode_bit( decoder, &cb ) ) { delete decoder; return false; }
		if ( cb == 1 ) if ( !pjg_decode_generic( decoder, &rst_err, NULL ) ) { delete decoder; return false; }
		if ( !pjg_unoptimize_header() ) { delete decoder; return false; }
		if ( disc_meta ) if ( !jpg_rebuild_header() ) { delete decoder; return false; }
		if ( !jpg_setup_imginfo() ) { delete decoder; return false; }
		for ( cmp = 0; cmp < cmpc; cmp++ ) {
			if ( !pjg_decode_zstscan  ( decoder, cmp ) ) { delete decoder; return false; }
			if ( !pjg_decode_zdst_high( decoder, cmp ) ) { delete decoder; return false; }
			if ( !pjg_decode_ac_high  ( decoder, cmp ) ) { delete decoder; return false; }
			if ( !pjg_decode_zdst_low ( decoder, cmp ) ) { delete decoder; return false; }
			if ( !pjg_decode_ac_low   ( decoder, cmp ) ) { delete decoder; return false; }
			if ( !pjg_decode_dc       ( decoder, cmp ) ) { delete decoder; return false; }
		}
		if ( !pjg_decode_bit( decoder, &cb ) ) { delete decoder; return false; }
		if ( cb == 0 ) grbs = 0;
		else if ( !pjg_decode_generic( decoder, &grbgdata, &grbs ) ) { delete decoder; return false; }
		delete decoder;
	}
	
	
	// get filesize
	pjgfilesize = str_in->get_size();
	
	
	return true;
}

/* ----------------------- End of main functions -------------------------- */

/* ----------------------- Begin of JPEG specific functions -------------------------- */


/* -----------------------------------------------
	Parses header for imageinfo
	----------------------------------------------- */
INTERN bool jpg_setup_imginfo( void )
{
	unsigned char  type = 0x00; // type of current marker segment
	unsigned int   len  = 0; // length of current marker segment
	unsigned int   hpos = 0; // position in header
	
	int cmp, bpos;
	int i;
	
	// header parser loop
	while ( (int)hpos + 4 <= hdrs ) {
		type = hdrdata[ hpos + 1 ];
		len = 2 + B_SHORT( hdrdata[ hpos + 2 ], hdrdata[ hpos + 3 ] );
		// do not parse DHT & DRI
		if ( ( type != 0xDA ) && ( type != 0xC4 ) && ( type != 0xDD ) ) {
			if ( !jpg_parse_jfif( type, len, &( hdrdata[ hpos ] ) ) )
				return false;
		}
		hpos += len;
	}
	
	// check if information is complete
	if ( cmpc == 0 ) {
		snprintf( errormessage, MSG_SIZE, "header contains incomplete information" );
		errorlevel = 2;
		return false;
	}
	for ( cmp = 0; cmp < cmpc; cmp++ ) {
		if ( ( cmpnfo[cmp].sfv == 0 ) ||
			 ( cmpnfo[cmp].sfh == 0 ) ||
			 ( cmpnfo[cmp].qtable == NULL ) ||
			 ( cmpnfo[cmp].qtable[0] == 0 ) ||
			 ( jpegtype == 0 ) ) {
			snprintf( errormessage, MSG_SIZE, "header information is incomplete" );
			errorlevel = 2;
			return false;
		}
	}
	
	// do all remaining component info calculations
	for ( cmp = 0; cmp < cmpc; cmp++ ) {
		if ( cmpnfo[ cmp ].sfh > sfhm ) sfhm = cmpnfo[ cmp ].sfh;
		if ( cmpnfo[ cmp ].sfv > sfvm ) sfvm = cmpnfo[ cmp ].sfv;
	}
	mcuv = ( int ) ceil( (float) imgheight / (float) ( 8 * sfhm ) );
	mcuh = ( int ) ceil( (float) imgwidth  / (float) ( 8 * sfvm ) );
	mcuc  = mcuv * mcuh;
	for ( cmp = 0; cmp < cmpc; cmp++ ) {
		cmpnfo[ cmp ].mbs = cmpnfo[ cmp ].sfv * cmpnfo[ cmp ].sfh;		
		cmpnfo[ cmp ].bcv = mcuv * cmpnfo[ cmp ].sfh;
		cmpnfo[ cmp ].bch = mcuh * cmpnfo[ cmp ].sfv;
		cmpnfo[ cmp ].bc  = cmpnfo[ cmp ].bcv * cmpnfo[ cmp ].bch;
		cmpnfo[ cmp ].ncv = ( int ) ceil( (float) imgheight * 
							( (float) cmpnfo[ cmp ].sfh / ( 8.0 * sfhm ) ) );
		cmpnfo[ cmp ].nch = ( int ) ceil( (float) imgwidth * 
							( (float) cmpnfo[ cmp ].sfv / ( 8.0 * sfvm ) ) );
		cmpnfo[ cmp ].nc  = cmpnfo[ cmp ].ncv * cmpnfo[ cmp ].nch;
	}
	
	// decide components' statistical ids
	if ( cmpc <= 3 ) {
		for ( cmp = 0; cmp < cmpc; cmp++ ) cmpnfo[ cmp ].sid = cmp;
	}
	else {
		for ( cmp = 0; cmp < cmpc; cmp++ ) cmpnfo[ cmp ].sid = 0;
	}
	
	// alloc memory for further operations
	for ( cmp = 0; cmp < cmpc; cmp++ )
	{
		// alloc memory for colls
		for ( bpos = 0; bpos < 64; bpos++ ) {
			colldata[cmp][bpos] = (short int*) calloc ( cmpnfo[cmp].bc, sizeof( short ) );
			if (colldata[cmp][bpos] == NULL) {
				snprintf( errormessage, MSG_SIZE, MEM_ERRMSG );
				errorlevel = 2;
				return false;
			}
		}
		
		// alloc memory for zdstlist / eob x / eob y
		zdstdata[cmp] = (unsigned char*) calloc( cmpnfo[cmp].bc, sizeof( char ) );
		eobxhigh[cmp] = (unsigned char*) calloc( cmpnfo[cmp].bc, sizeof( char ) );
		eobyhigh[cmp] = (unsigned char*) calloc( cmpnfo[cmp].bc, sizeof( char ) );
		zdstxlow[cmp] = (unsigned char*) calloc( cmpnfo[cmp].bc, sizeof( char ) );
		zdstylow[cmp] = (unsigned char*) calloc( cmpnfo[cmp].bc, sizeof( char ) );
		if ( ( zdstdata[cmp] == NULL ) ||
			( eobxhigh[cmp] == NULL ) || ( eobyhigh[cmp] == NULL ) ||
			( zdstxlow[cmp] == NULL ) || ( zdstylow[cmp] == NULL ) ) {
			snprintf( errormessage, MSG_SIZE, MEM_ERRMSG );
			errorlevel = 2;
			return false;
		}
	}
	
	// also decide automatic settings here
	if ( auto_set ) {
		for ( cmp = 0; cmp < cmpc; cmp++ ) {
			for ( i = 0;
				conf_sets[ i ][ cmpnfo[cmp].sid ] > (unsigned int) cmpnfo[ cmp ].bc;
				i++ );
			segm_cnt[ cmp ] = conf_segm[ i ][ cmpnfo[cmp].sid ];
			nois_trs[ cmp ] = conf_ntrs[ i ][ cmpnfo[cmp].sid ];
		}
	}
	
	
	return true;
}


/* -----------------------------------------------
	Parse routines for JFIF segments
	----------------------------------------------- */
INTERN bool jpg_parse_jfif( unsigned char type, unsigned int len, unsigned char* segment )
{
	unsigned int hpos = 4; // current position in segment, start after segment header
	int lval, rval; // temporary variables
	int skip;
	int cmp;
	int i;
	
	
	switch ( type )
	{
		case 0xC4: // DHT segment
			// build huffman trees & codes
			while ( hpos < len ) {
				lval = LBITS( segment[ hpos ], 4 );
				rval = RBITS( segment[ hpos ], 4 );
				if ( ((lval < 0) || (lval >= 2)) || ((rval < 0) || (rval >= 4)) )
					break;

				hpos++;
				// need at least 16 bytes for the count table
				if ( hpos + 16 > len ) break;
				skip = 16;
				for ( i = 0; i < 16; i++ )
					skip += ( int ) segment[ hpos + i ];
				// need count-table + all code bytes to be within segment
				if ( hpos + (unsigned)skip > len ) break;
				// build huffman codes & trees
				jpg_build_huffcodes( &(segment[ hpos + 0 ]), &(segment[ hpos + 16 ]),
					&(hcodes[ lval ][ rval ]), &(htrees[ lval ][ rval ]) );
				htset[ lval ][ rval ] = 1;
				hpos += skip;
			}
			
			if ( hpos != len ) {
				// if we get here, something went wrong
				snprintf( errormessage, MSG_SIZE, "size mismatch in dht marker" );
				errorlevel = 2;
				return false;
			}
			return true;
		
		case 0xDB: // DQT segment
			// copy quantization tables to internal memory
			while ( hpos < len ) {
				lval = LBITS( segment[ hpos ], 4 );
				rval = RBITS( segment[ hpos ], 4 );
				if ( (lval < 0) || (lval >= 2) ) break;
				if ( (rval < 0) || (rval >= 4) ) break;
				hpos++;
				if ( lval == 0 ) { // 8 bit precision
					if ( hpos + 64 > len ) break;
					for ( i = 0; i < 64; i++ ) {
						qtables[ rval ][ i ] = ( unsigned short ) segment[ hpos + i ];
						if ( qtables[ rval ][ i ] == 0 ) break;
					}
					hpos += 64;
				}
				else { // 16 bit precision
					if ( hpos + 128 > len ) break;
					for ( i = 0; i < 64; i++ ) {
						qtables[ rval ][ i ] =
							B_SHORT( segment[ hpos + (2*i) ], segment[ hpos + (2*i) + 1 ] );
						if ( qtables[ rval ][ i ] == 0 ) break;
					}
					hpos += 128;
				}
			}
			
			if ( hpos != len ) {
				// if we get here, something went wrong
				snprintf( errormessage, MSG_SIZE, "size mismatch in dqt marker" );
				errorlevel = 2;
				return false;
			}
			return true;
			
		case 0xDD: // DRI segment
			// define restart interval
			if ( hpos + 2 > len ) return true; // malformed but non-fatal
			rsti = B_SHORT( segment[ hpos ], segment[ hpos + 1 ] );
			return true;
			
		case 0xDA: // SOS segment
			// need component count byte + 2 bytes per component + 3 spectral bytes
			if ( hpos + 1 > len ) {
				snprintf( errormessage, MSG_SIZE, "truncated sos segment" );
				errorlevel = 2;
				return false;
			}
			// prepare next scan
			cs_cmpc = segment[ hpos ];
			if ( cs_cmpc > cmpc ) {
				snprintf( errormessage, MSG_SIZE, "%i components in scan, only %i are allowed",
							cs_cmpc, cmpc );
				errorlevel = 2;
				return false;
			}
			hpos++;
			if ( hpos + (unsigned)(cs_cmpc * 2) + 3 > len ) {
				snprintf( errormessage, MSG_SIZE, "truncated sos segment" );
				errorlevel = 2;
				return false;
			}
			for ( i = 0; i < cs_cmpc; i++ ) {
				for ( cmp = 0; ( segment[ hpos ] != cmpnfo[ cmp ].jid ) && ( cmp < cmpc ); cmp++ );
				if ( cmp == cmpc ) {
					snprintf( errormessage, MSG_SIZE, "component id mismatch in start-of-scan" );
					errorlevel = 2;
					return false;
				}
				cs_cmp[ i ] = cmp;
				cmpnfo[ cmp ].huffdc = LBITS( segment[ hpos + 1 ], 4 );
				cmpnfo[ cmp ].huffac = RBITS( segment[ hpos + 1 ], 4 );
				if ( ( cmpnfo[ cmp ].huffdc < 0 ) || ( cmpnfo[ cmp ].huffdc >= 4 ) ||
					 ( cmpnfo[ cmp ].huffac < 0 ) || ( cmpnfo[ cmp ].huffac >= 4 ) ) {
					snprintf( errormessage, MSG_SIZE, "huffman table number mismatch" );
					errorlevel = 2;
					return false;
				}
				hpos += 2;
			}
			if ( hpos + 3 > len ) {
				snprintf( errormessage, MSG_SIZE, "truncated sos segment" );
				errorlevel = 2;
				return false;
			}
			cs_from = segment[ hpos + 0 ];
			cs_to   = segment[ hpos + 1 ];
			cs_sah  = LBITS( segment[ hpos + 2 ], 4 );
			cs_sal  = RBITS( segment[ hpos + 2 ], 4 );
			// check for errors
			if ( ( cs_from > cs_to ) || ( cs_from > 63 ) || ( cs_to > 63 ) ) {
				snprintf( errormessage, MSG_SIZE, "spectral selection parameter out of range" );
				errorlevel = 2;
				return false;
			}
			if ( ( cs_sah >= 12 ) || ( cs_sal >= 12 ) ) {
				snprintf( errormessage, MSG_SIZE, "successive approximation parameter out of range" );
				errorlevel = 2;
				return false;
			}
			return true;
		
		case 0xC0: // SOF0 segment
			// coding process: baseline DCT
			
		case 0xC1: // SOF1 segment
			// coding process: extended sequential DCT
		
		case 0xC2: // SOF2 segment
			// coding process: progressive DCT
			
			// set JPEG coding type
			if ( type == 0xC2 )
				jpegtype = 2;
			else
				jpegtype = 1;
				
			// need precision(1) + height(2) + width(2) + cmpc(1) = 6 bytes
			if ( hpos + 6 > len ) {
				snprintf( errormessage, MSG_SIZE, "truncated sof segment" );
				errorlevel = 2;
				return false;
			}
			// check data precision, only 8 bit is allowed
			lval = segment[ hpos ];
			if ( lval != 8 ) {
				snprintf( errormessage, MSG_SIZE, "%i bit data precision is not supported", lval );
				errorlevel = 2;
				return false;
			}

			// image size, height & component count
			imgheight = B_SHORT( segment[ hpos + 1 ], segment[ hpos + 2 ] );
			imgwidth  = B_SHORT( segment[ hpos + 3 ], segment[ hpos + 4 ] );
			cmpc      = segment[ hpos + 5 ];
			if ( ( imgwidth == 0 ) || ( imgheight == 0 ) ) {
				snprintf( errormessage, MSG_SIZE, "resolution is %ix%i, possible malformed JPEG", imgwidth, imgheight );
				errorlevel = 2;
				return false;
			}
			if ( cmpc > 4 ) {
				snprintf( errormessage, MSG_SIZE, "image has %i components, max 4 are supported", cmpc );
				errorlevel = 2;
				return false;
			}
			
			hpos += 6;
			// need 3 bytes per component
			if ( hpos + (unsigned)(cmpc * 3) > len ) {
				snprintf( errormessage, MSG_SIZE, "truncated sof component data" );
				errorlevel = 2;
				return false;
			}
			// components contained in image
			for ( cmp = 0; cmp < cmpc; cmp++ ) {
				cmpnfo[ cmp ].jid = segment[ hpos ];
				cmpnfo[ cmp ].sfv = LBITS( segment[ hpos + 1 ], 4 );
				cmpnfo[ cmp ].sfh = RBITS( segment[ hpos + 1 ], 4 );
				// Fix #32: validate qtable_id before indexing qtables[4][64].
				// A malformed JPEG can set qtable_id to any byte value (0-255),
				// but qtables only has 4 entries — anything >= 4 is overflow.
				{ int qtable_id = segment[ hpos + 2 ];
				  if ( qtable_id >= 4 ) {
				    snprintf( errormessage, MSG_SIZE, "invalid quantization table id %i in component %i", qtable_id, cmp );
				    errorlevel = 2;
				    return false;
				  }
				  cmpnfo[ cmp ].qtable = qtables[ qtable_id ]; }
				hpos += 3;
			}
			
			return true;
		
		case 0xC3: // SOF3 segment
			// coding process: lossless sequential
			snprintf( errormessage, MSG_SIZE, "sof3 marker found, image is coded lossless" );
			errorlevel = 2;
			return false;
		
		case 0xC5: // SOF5 segment
			// coding process: differential sequential DCT
			snprintf( errormessage, MSG_SIZE, "sof5 marker found, image is coded diff. sequential" );
			errorlevel = 2;
			return false;
		
		case 0xC6: // SOF6 segment
			// coding process: differential progressive DCT
			snprintf( errormessage, MSG_SIZE, "sof6 marker found, image is coded diff. progressive" );
			errorlevel = 2;
			return false;
		
		case 0xC7: // SOF7 segment
			// coding process: differential lossless
			snprintf( errormessage, MSG_SIZE, "sof7 marker found, image is coded diff. lossless" );
			errorlevel = 2;
			return false;
			
		case 0xC9: // SOF9 segment
			// coding process: arithmetic extended sequential DCT
			snprintf( errormessage, MSG_SIZE, "sof9 marker found, image is coded arithm. sequential" );
			errorlevel = 2;
			return false;
			
		case 0xCA: // SOF10 segment
			// coding process: arithmetic extended sequential DCT
			snprintf( errormessage, MSG_SIZE, "sof10 marker found, image is coded arithm. progressive" );
			errorlevel = 2;
			return false;
			
		case 0xCB: // SOF11 segment
			// coding process: arithmetic extended sequential DCT
			snprintf( errormessage, MSG_SIZE, "sof11 marker found, image is coded arithm. lossless" );
			errorlevel = 2;
			return false;
			
		case 0xCD: // SOF13 segment
			// coding process: arithmetic differntial sequential DCT
			snprintf( errormessage, MSG_SIZE, "sof13 marker found, image is coded arithm. diff. sequential" );
			errorlevel = 2;
			return false;
			
		case 0xCE: // SOF14 segment
			// coding process: arithmetic differential progressive DCT
			snprintf( errormessage, MSG_SIZE, "sof14 marker found, image is coded arithm. diff. progressive" );
			errorlevel = 2;
			return false;
		
		case 0xCF: // SOF15 segment
			// coding process: arithmetic differntial lossless
			snprintf( errormessage, MSG_SIZE, "sof15 marker found, image is coded arithm. diff. lossless" );
			errorlevel = 2;
			return false;
			
		case 0xE0: // APP0 segment	
		case 0xE1: // APP1 segment
		case 0xE2: // APP2 segment
		case 0xE3: // APP3 segment
		case 0xE4: // APP4 segment
		case 0xE5: // APP5 segment
		case 0xE6: // APP6 segment
		case 0xE7: // APP7 segment
		case 0xE8: // APP8 segment
		case 0xE9: // APP9 segment
		case 0xEA: // APP10 segment
		case 0xEB: // APP11 segment
		case 0xEC: // APP12 segment
		case 0xED: // APP13 segment
		case 0xEE: // APP14 segment
		case 0xEF: // APP15 segment
		case 0xFE: // COM segment
			// do nothing - return true
			return true;
			
		case 0xD0: // RST0 segment
		case 0xD1: // RST1 segment
		case 0xD2: // RST2 segment
		case 0xD3: // RST3 segment
		case 0xD4: // RST4 segment
		case 0xD5: // RST5 segment
		case 0xD6: // RST6 segment
		case 0xD7: // RST7 segment
			// return errormessage - RST is out of place here
			snprintf( errormessage, MSG_SIZE, "rst marker found out of place" );
			errorlevel = 2;
			return false;
		
		case 0xD8: // SOI segment
			// return errormessage - start-of-image is out of place here
			snprintf( errormessage, MSG_SIZE, "soi marker found out of place" );
			errorlevel = 2;
			return false;
		
		case 0xD9: // EOI segment
			// return errormessage - end-of-image is out of place here
			snprintf( errormessage, MSG_SIZE, "eoi marker found out of place" );
			errorlevel = 2;
			return false;
			
		default: // unknown marker segment
			// return warning
			snprintf( errormessage, MSG_SIZE, "unknown marker found: FF %2X", type );
			errorlevel = 1;
			return true;
	}
}


/* -----------------------------------------------
	JFIF header rebuilding routine
	----------------------------------------------- */
INTERN bool jpg_rebuild_header( void )
{	
	MemoryWriter* hdrw; // new header writer
	
	unsigned char  type = 0x00; // type of current marker segment
	unsigned int   len  = 0; // length of current marker segment
	unsigned int   hpos = 0; // position in header	
	
	
	// start headerwriter
	hdrw = new MemoryWriter();
	
	// header parser loop
	while ( (int)hpos + 4 <= hdrs ) {
		type = hdrdata[ hpos + 1 ];
		len = 2 + B_SHORT( hdrdata[ hpos + 2 ], hdrdata[ hpos + 3 ] );
		// discard any unneeded meta info
		if ( ( type == 0xDA ) || ( type == 0xC4 ) || ( type == 0xDB ) ||
			 ( type == 0xC0 ) || ( type == 0xC1 ) || ( type == 0xC2 ) ||
			 ( type == 0xDD ) ) {
			hdrw->write( &(hdrdata[ hpos ]), len );
		}
		hpos += len;
	}
	
	// replace current header with the new one
	free( hdrdata );
	hdrdata = hdrw->get_c_data();
	hdrs    = hdrw->num_bytes_written();
	delete( hdrw );
	
	
	return true;
}


/* -----------------------------------------------
	sequential block decoding routine
	----------------------------------------------- */
INTERN int jpg_decode_block_seq( BitReader* huffr, huffTree* dctree, huffTree* actree, short* block )
{
	unsigned short n;
	unsigned char  s;
	unsigned char  z;
	int eob = 64;
	int bpos;
	int hc;
	
	
	// decode dc
	hc = jpg_next_huffcode( huffr, dctree );
	if ( hc < 0 ) return -1; // return error
	else s = ( unsigned char ) hc;
	n = huffr->read( s );	
	block[ 0 ] = DEVLI( s, n );
	
	// decode ac
	for ( bpos = 1; bpos < 64; )
	{
		// decode next
		hc = jpg_next_huffcode( huffr, actree );
		// analyse code
		if ( hc > 0 ) {
			z = LBITS( hc, 4 );
			s = RBITS( hc, 4 );
			n = huffr->read( s );
			if ( ( z + bpos ) >= 64 )
				return -1; // run is to long
			while ( z > 0 ) { // write zeroes
				block[ bpos++ ] = 0;
				z--;
			}
			block[ bpos++ ] = ( short ) DEVLI( s, n ); // decode cvli
		}
		else if ( hc == 0 ) { // EOB
			eob = bpos;			
			// while( bpos < 64 ) // fill remaining block with zeroes
			//	block[ bpos++ ] = 0;
			break;
		}
		else {
			return -1; // return error
		}
	}
	
	
	// return position of eob
	return eob;
}


/* -----------------------------------------------
	sequential block encoding routine
	----------------------------------------------- */
INTERN int jpg_encode_block_seq( BitWriter* huffw, huffCodes* dctbl, huffCodes* actbl, short* block )
{
	unsigned short n;
	unsigned char  s;
	unsigned char  z;
	int bpos;
	int hc;
	
	
	// encode DC
	s = BITLEN2048N( block[ 0 ] );
	n = ENVLI( s, block[ 0 ] );
	huffw->write_u16( dctbl->cval[ s ], dctbl->clen[ s ] );
	huffw->write_u16( n, s );
	
	// encode AC
	z = 0;
	for ( bpos = 1; bpos < 64; bpos++ )
	{
		// if nonzero is encountered
		if ( block[ bpos ] != 0 ) {
			// write remaining zeroes
			while ( z >= 16 ) {
				huffw->write_u16( actbl->cval[ 0xF0 ], actbl->clen[ 0xF0 ] );
				z -= 16;
			}			
			// vli encode
			s = BITLEN2048N( block[ bpos ] );
			n = ENVLI( s, block[ bpos ] );
			hc = ( ( z << 4 ) + s );
			// write to huffman writer
			huffw->write_u16( actbl->cval[ hc ], actbl->clen[ hc ] );
			huffw->write_u16( n, s );
			// reset zeroes
			z = 0;
		}
		else { // increment zero counter
			z++;
		}
	}
	// write eob if needed
	if ( z > 0 )
		huffw->write_u16( actbl->cval[ 0x00 ], actbl->clen[ 0x00 ] );
		
	
	return 64 - z;
}


/* -----------------------------------------------
	progressive DC decoding routine
	----------------------------------------------- */
INTERN int jpg_decode_dc_prg_fs( BitReader* huffr, huffTree* dctree, short* block )
{
	unsigned short n;
	unsigned char  s;
	int hc;
	
	
	// decode dc
	hc = jpg_next_huffcode( huffr, dctree );
	if ( hc < 0 ) return -1; // return error
	else s = ( unsigned char ) hc;
	n = huffr->read( s );	
	block[ 0 ] = DEVLI( s, n );
	
	
	// return 0 if everything is ok
	return 0;
}


/* -----------------------------------------------
	progressive DC encoding routine
	----------------------------------------------- */
INTERN int jpg_encode_dc_prg_fs( BitWriter* huffw, huffCodes* dctbl, short* block )
{
	unsigned short n;
	unsigned char  s;
	
	
	// encode DC	
	s = BITLEN2048N( block[ 0 ] );
	n = ENVLI( s, block[ 0 ] );
	huffw->write_u16( dctbl->cval[ s ], dctbl->clen[ s ] );
	huffw->write_u16( n, s );
	
	
	// return 0 if everything is ok
	return 0;
}


/* -----------------------------------------------
	progressive AC decoding routine
	----------------------------------------------- */
INTERN int jpg_decode_ac_prg_fs( BitReader* huffr, huffTree* actree, short* block, int* eobrun, int from, int to )
{
	unsigned short n;
	unsigned char  s;
	unsigned char  z;
	int eob = to + 1;
	int bpos;
	int hc;
	int l;
	int r;
	
	
	// decode ac
	for ( bpos = from; bpos <= to; )
	{
		// decode next
		hc = jpg_next_huffcode( huffr, actree );
		if ( hc < 0 ) return -1;
		l = LBITS( hc, 4 );
		r = RBITS( hc, 4 );
		// analyse code
		if ( ( l == 15 ) || ( r > 0 ) ) { // decode run/level combination
			z = l;
			s = r;
			n = huffr->read( s );
			if ( ( z + bpos ) > to )
				return -1; // run is to long			
			while ( z > 0 ) { // write zeroes
				block[ bpos++ ] = 0;
				z--;
			}			
			block[ bpos++ ] = ( short ) DEVLI( s, n ); // decode cvli
		}
		else { // decode eobrun
			eob = bpos;
			s = l;
			n = huffr->read( s );
			(*eobrun) = E_DEVLI( s, n );			
			// while( bpos <= to ) // fill remaining block with zeroes
			//	block[ bpos++ ] = 0;
			break;
		}
	}
	
	
	// return position of eob
	return eob;
}


/* -----------------------------------------------
	progressive AC encoding routine
	----------------------------------------------- */
INTERN int jpg_encode_ac_prg_fs( BitWriter* huffw, huffCodes* actbl, short* block, int* eobrun, int from, int to )
{
	unsigned short n;
	unsigned char  s;
	unsigned char  z;
	int bpos;
	int hc;
	
	// encode AC
	z = 0;
	for ( bpos = from; bpos <= to; bpos++ )
	{
		// if nonzero is encountered
		if ( block[ bpos ] != 0 ) {
			// encode eobrun
			jpg_encode_eobrun( huffw, actbl, eobrun );
			// write remaining zeroes
			while ( z >= 16 ) {
				huffw->write_u16( actbl->cval[ 0xF0 ], actbl->clen[ 0xF0 ] );
				z -= 16;
			}			
			// vli encode
			s = BITLEN2048N( block[ bpos ] );
			n = ENVLI( s, block[ bpos ] );
			hc = ( ( z << 4 ) + s );
			// write to huffman writer
			huffw->write_u16( actbl->cval[ hc ], actbl->clen[ hc ] );
			huffw->write_u16( n, s );
			// reset zeroes
			z = 0;
		}
		else { // increment zero counter
			z++;
		}
	}
	
	// check eob, increment eobrun if needed
	if ( z > 0 ) {
		(*eobrun)++;
		// check eobrun, encode if needed
		if ( (*eobrun) == actbl->max_eobrun )
			jpg_encode_eobrun( huffw, actbl, eobrun );
		return 1 + to - z;		
	}
	else {
		return 1 + to;
	}
}


/* -----------------------------------------------
	progressive DC SA decoding routine
	----------------------------------------------- */
INTERN int jpg_decode_dc_prg_sa( BitReader* huffr, short* block )
{
	// decode next bit of dc coefficient
	block[ 0 ] = huffr->read( 1 );
	
	// return 0 if everything is ok
	return 0;
}


/* -----------------------------------------------
	progressive DC SA encoding routine
	----------------------------------------------- */
INTERN int jpg_encode_dc_prg_sa( BitWriter* huffw, short* block )
{
	// enocode next bit of dc coefficient
	huffw->write_u16( block[ 0 ], 1 );
	
	// return 0 if everything is ok
	return 0;
}


/* -----------------------------------------------
	progressive AC SA decoding routine
	----------------------------------------------- */
INTERN int jpg_decode_ac_prg_sa( BitReader* huffr, huffTree* actree, short* block, int* eobrun, int from, int to )
{
	unsigned short n;
	unsigned char  s;
	signed char    z;
	signed char    v;
	int bpos = from;
	int eob = to;
	int hc;
	int l;
	int r;
	
	
	// decode AC succesive approximation bits
	if ( (*eobrun) == 0 ) while ( bpos <= to )
	{
		// decode next
		hc = jpg_next_huffcode( huffr, actree );
		if ( hc < 0 ) return -1;
		l = LBITS( hc, 4 );
		r = RBITS( hc, 4 );
		// analyse code
		if ( ( l == 15 ) || ( r > 0 ) ) { // decode run/level combination
			z = l;
			s = r;
			if ( s == 0 ) v = 0;
			else if ( s == 1 ) {
				n = huffr->read( 1 );
				v = ( n == 0 ) ? -1 : 1; // fast decode vli
			}
			else return -1; // decoding error
			// write zeroes / write correction bits
			while ( true ) {
				if ( block[ bpos ] == 0 ) { // skip zeroes / write value
					if ( z > 0 ) z--;
					else {
						block[ bpos++ ] = v;
						break;
					}
				}
				else { // read correction bit
					n = huffr->read( 1 );
					block[ bpos ] = ( block[ bpos ] > 0 ) ? n : -n;
				}
				if ( bpos++ >= to ) return -1; // error check					
			}
		}
		else { // decode eobrun
			eob = bpos;
			s = l;
			n = huffr->read( s );
			(*eobrun) = E_DEVLI( s, n );
			break;
		}
	}
	
	// read after eob correction bits
	if ( (*eobrun) > 0 ) {
		for ( ; bpos <= to; bpos++ ) {
			if ( block[ bpos ] != 0 ) {
				n = huffr->read( 1 );
				block[ bpos ] = ( block[ bpos ] > 0 ) ? n : -n;
			}
		}
	}
	
	// return eob
	return eob;
}


/* -----------------------------------------------
	progressive AC SA encoding routine
	----------------------------------------------- */
INTERN int jpg_encode_ac_prg_sa( BitWriter* huffw, std::vector<std::uint8_t>& storw, huffCodes* actbl, short* block, int* eobrun, int from, int to )
{
	unsigned short n;
	unsigned char  s;
	unsigned char  z;
	int eob = from;
	int bpos;
	int hc;
	
	// check if block contains any newly nonzero coefficients and find out position of eob
	for ( bpos = to; bpos >= from; bpos-- )	{
		if ( ( block[ bpos ] == 1 ) || ( block[ bpos ] == -1 ) ) {
			eob = bpos + 1;
			break;
		}
	}
	
	// encode eobrun if needed
	if ( ( eob > from ) && ( (*eobrun) > 0 ) ) {
		jpg_encode_eobrun( huffw, actbl, eobrun );
		jpg_encode_crbits( huffw, storw );
	}
	
	// encode AC
	z = 0;
	for ( bpos = from; bpos < eob; bpos++ )
	{
		// if zero is encountered
		if ( block[ bpos ] == 0 ) {
			z++; // increment zero counter
			if ( z == 16 ) { // write zeroes if needed
				huffw->write_u16( actbl->cval[ 0xF0 ], actbl->clen[ 0xF0 ] );
				jpg_encode_crbits( huffw, storw );
				z = 0;
			}
		}
		// if nonzero is encountered
		else if ( ( block[ bpos ] == 1 ) || ( block[ bpos ] == -1 ) ) {
			// vli encode			
			s = BITLEN2048N( block[ bpos ] );
			n = ENVLI( s, block[ bpos ] );
			hc = ( ( z << 4 ) + s );
			// write to huffman writer
			huffw->write_u16( actbl->cval[ hc ], actbl->clen[ hc ] );
			huffw->write_u16( n, s );
			// write correction bits
			jpg_encode_crbits( huffw, storw );
			// reset zeroes
			z = 0;
		}
		else { // store correction bits
			n = block[ bpos ] & 0x1;
			storw.emplace_back(n);
		}
	}
	
	// fast processing after eob
	for ( ;bpos <= to; bpos++ )
	{
		if ( block[ bpos ] != 0 ) { // store correction bits
			n = block[ bpos ] & 0x1;
			storw.emplace_back(n);
		}
	}
	
	// check eob, increment eobrun if needed
	if ( eob <= to ) {
		(*eobrun)++;	
		// check eobrun, encode if needed
		if ( (*eobrun) == actbl->max_eobrun ) {
			jpg_encode_eobrun( huffw, actbl, eobrun );
			jpg_encode_crbits( huffw, storw );		
		}
	}	
	
	// return eob
	return eob;
}


/* -----------------------------------------------
	run of EOB SA decoding routine
	----------------------------------------------- */
INTERN int jpg_decode_eobrun_sa( BitReader* huffr, short* block, int* /*eobrun*/, int from, int to )
{
	unsigned short n;
	int bpos;
	
	
	// fast eobrun decoding routine for succesive approximation
	for ( bpos = from; bpos <= to; bpos++ ) {
		if ( block[ bpos ] != 0 ) {
			n = huffr->read( 1 );
			block[ bpos ] = ( block[ bpos ] > 0 ) ? n : -n;
		}
	}
	
	
	return 0;
}


/* -----------------------------------------------
	run of EOB encoding routine
	----------------------------------------------- */
INTERN int jpg_encode_eobrun( BitWriter* huffw, huffCodes* actbl, int* eobrun )
{
	unsigned short n;
	unsigned char  s;
	int hc;
	
	
	if ( (*eobrun) > 0 ) {
		while ( (*eobrun) > actbl->max_eobrun ) {
			huffw->write_u16( actbl->cval[ 0xE0 ], actbl->clen[ 0xE0 ] );
			huffw->write_u16( E_ENVLI( 14, 32767 ), 14 );
			(*eobrun) -= actbl->max_eobrun;
		}
		BITLEN( s, (*eobrun) );
		s--;
		n = E_ENVLI( s, (*eobrun) );
		hc = ( s << 4 );
		huffw->write_u16( actbl->cval[ hc ], actbl->clen[ hc ] );
		huffw->write_u16( n, s );
		(*eobrun) = 0;
	}

	
	return 0;
}


/* -----------------------------------------------
	correction bits encoding routine
	----------------------------------------------- */
INTERN int jpg_encode_crbits( BitWriter* huffw, std::vector<std::uint8_t>& storw )
{	
	for (const std::uint8_t bit : storw) {
		huffw->write_bit(bit);
    }
	storw.clear();
	return 0;
}


/* -----------------------------------------------
	returns next code (from huffman-tree & -data)
	----------------------------------------------- */
INTERN int jpg_next_huffcode( BitReader *huffw, huffTree *ctree )
{	
	int node = 0;
	
	
	while ( node < 256 ) {
		node = ( huffw->read( 1 ) == 1 ) ?
				ctree->r[ node ] : ctree->l[ node ];
		if ( node == 0 ) break;
	}
	
	return ( node - 256 );
}


/* -----------------------------------------------
	calculates next position for MCU
	----------------------------------------------- */
INTERN int jpg_next_mcupos( int* mcu, int* cmp, int* csc, int* sub, int* dpos, int* rstw )
{
	int sta = 0; // status
	
	
	// increment all counts where needed
	if ( ( ++(*sub) ) >= cmpnfo[(*cmp)].mbs ) {
		(*sub) = 0;
		
		if ( ( ++(*csc) ) >= cs_cmpc ) {
			(*csc) = 0;
			(*cmp) = cs_cmp[ 0 ];
			(*mcu)++;
			if ( (*mcu) >= mcuc ) sta = 2;
			else if ( rsti > 0 )
				if ( --(*rstw) == 0 ) sta = 1;
		}
		else {
			(*cmp) = cs_cmp[(*csc)];
		}
	}
	
	// get correct position in image ( x & y )
	if ( cmpnfo[(*cmp)].sfh > 1 ) { // to fix mcu order
		(*dpos)  = ( (*mcu) / mcuh ) * cmpnfo[(*cmp)].sfh + ( (*sub) / cmpnfo[(*cmp)].sfv );
		(*dpos) *= cmpnfo[(*cmp)].bch;
		(*dpos) += ( (*mcu) % mcuh ) * cmpnfo[(*cmp)].sfv + ( (*sub) % cmpnfo[(*cmp)].sfv );
	}
	else if ( cmpnfo[(*cmp)].sfv > 1 ) {
		// simple calculation to speed up things if simple fixing is enough
		(*dpos) = ( (*mcu) * cmpnfo[(*cmp)].mbs ) + (*sub);
	}
	else {
		// no calculations needed without subsampling
		(*dpos) = (*mcu);
	}
	
	
	return sta;
}


/* -----------------------------------------------
	calculates next position (non interleaved)
	----------------------------------------------- */
INTERN int jpg_next_mcuposn( int* cmp, int* dpos, int* rstw )
{
	// increment position
	(*dpos)++;
	
	// fix for non interleaved mcu - horizontal
	if ( cmpnfo[(*cmp)].bch != cmpnfo[(*cmp)].nch ) {
		if ( (*dpos) % cmpnfo[(*cmp)].bch == cmpnfo[(*cmp)].nch )
			(*dpos) += ( cmpnfo[(*cmp)].bch - cmpnfo[(*cmp)].nch );
	}
	
	// fix for non interleaved mcu - vertical
	if ( cmpnfo[(*cmp)].bcv != cmpnfo[(*cmp)].ncv ) {
		if ( (*dpos) / cmpnfo[(*cmp)].bch == cmpnfo[(*cmp)].ncv )
			(*dpos) = cmpnfo[(*cmp)].bc;
	}
	
	// check position
	if ( (*dpos) >= cmpnfo[(*cmp)].bc ) return 2;
	else if ( rsti > 0 )
		if ( --(*rstw) == 0 ) return 1;
	

	return 0;
}


/* -----------------------------------------------
	skips the eobrun, calculates next position
	----------------------------------------------- */
INTERN int jpg_skip_eobrun( int* cmp, int* dpos, int* rstw, int* eobrun )
{
	if ( (*eobrun) > 0 ) // error check for eobrun
	{		
		// compare rst wait counter if needed
		if ( rsti > 0 ) {
			if ( (*eobrun) > (*rstw) )
				return -1;
			else
				(*rstw) -= (*eobrun);
		}
		
		// fix for non interleaved mcu - horizontal
		if ( cmpnfo[(*cmp)].bch != cmpnfo[(*cmp)].nch ) {
			(*dpos) += ( ( ( (*dpos) % cmpnfo[(*cmp)].bch ) + (*eobrun) ) /
						cmpnfo[(*cmp)].nch ) * ( cmpnfo[(*cmp)].bch - cmpnfo[(*cmp)].nch );
		}
		
		// fix for non interleaved mcu - vertical
		if ( cmpnfo[(*cmp)].bcv != cmpnfo[(*cmp)].ncv ) {
			if ( (*dpos) / cmpnfo[(*cmp)].bch >= cmpnfo[(*cmp)].ncv )
				(*dpos) += ( cmpnfo[(*cmp)].bcv - cmpnfo[(*cmp)].ncv ) *
						cmpnfo[(*cmp)].bch;
		}		
		
		// skip blocks 
		(*dpos) += (*eobrun);
		
		// reset eobrun
		(*eobrun) = 0;
		
		// check position
		if ( (*dpos) == cmpnfo[(*cmp)].bc ) return 2;
		else if ( (*dpos) > cmpnfo[(*cmp)].bc ) return -1;
		else if ( rsti > 0 ) 
			if ( (*rstw) == 0 ) return 1;
	}
	
	return 0;
}


/* -----------------------------------------------
	creates huffman-codes & -trees from dht-data
	----------------------------------------------- */
INTERN void jpg_build_huffcodes( unsigned char *clen, unsigned char *cval,	huffCodes *hc, huffTree *ht )
{
	int nextfree;	
	int code;
	int node;
	int i, j, k;
	
	
	// fill with zeroes
	memset( hc->clen, 0, 256 * sizeof( short ) );
	memset( hc->cval, 0, 256 * sizeof( short ) );
	memset( ht->l, 0, 256 * sizeof( short ) );
	memset( ht->r, 0, 256 * sizeof( short ) );
	
	// 1st part -> build huffman codes
	
	// creating huffman-codes	
	k = 0;
	code = 0;	
	
	// symbol-value of code is its position in the table
	for( i = 0; i < 16; i++ ) {
		for( j = 0; j < (int) clen[ i ]; j++ ) {
			hc->clen[ (int) cval[k] ] = 1 + i;
			hc->cval[ (int) cval[k] ] = code;
			
			k++;			
			code++;
		}		
		code = code << 1;
	}
	
	// find out eobrun max value
	hc->max_eobrun = 0;
	for ( i = 14; i >= 0; i-- ) {
		if ( hc->clen[ i << 4 ] > 0 ) {
			hc->max_eobrun = ( 2 << i ) - 1;
			break;
		}
	}
	
	// 2nd -> part use codes to build the coding tree
	
	// initial value for next free place
	nextfree = 1;

	// work through every code creating links between the nodes (represented through ints)
	for ( i = 0; i < 256; i++ )	{
		// (re)set current node
		node = 0;   		   		
		// go through each code & store path
		for ( j = hc->clen[ i ] - 1; j > 0; j-- ) {
			if ( BITN( hc->cval[ i ], j ) == 1 ) {
				if ( ht->r[ node ] == 0 )
					 ht->r[ node ] = nextfree++;
				node = ht->r[ node ];
			}
			else{
				if ( ht->l[ node ] == 0 )
					ht->l[ node ] = nextfree++;
				node = ht->l[ node ];
			}   					
		}
		// last link is number of targetvalue + 256
		if ( hc->clen[ i ] > 0 ) {
			if ( BITN( hc->cval[ i ], 0 ) == 1 )
				ht->r[ node ] = i + 256;
			else
				ht->l[ node ] = i + 256;
		}	   	
	}
}

/* ----------------------- End of JPEG specific functions -------------------------- */

/* ----------------------- End of PJG specific functions -------------------------- */


/* -----------------------------------------------
	encodes frequency scanorder to pjg
	----------------------------------------------- */
INTERN bool pjg_encode_zstscan( ArithmeticEncoder* enc, int cmp )
{
	model_s* model;
	
	unsigned char freqlist[ 64 ];
	int tpos; // true position
	int cpos; // coded position
	int c, i;
	
	
	// calculate zero sort scan
	pjg_get_zerosort_scan( zsrtscan[cmp], cmp );
	
	// preset freqlist
	for ( i = 0; i < 64; i++ )
		freqlist[ i ] = stdscan[ i ];
		
	// init model
	model = INIT_MODEL_S( 64, 64, 1 );
	
	// encode scanorder
	for ( i = 1; i < 64; i++ )
	{			
		// reduce range of model
		model->exclude_symbols(64 - i);
		
		// compare remaining list to remainnig scan
		tpos = 0;
		for ( c = i; c < 64; c++ ) {
			// search next val != 0 in list
			for ( tpos++; freqlist[ tpos ] == 0; tpos++ );
			// get out if not a match
			if ( freqlist[ tpos ] != zsrtscan[ cmp ][ c ] ) break;				
		}
		if ( c == 64 ) {
			// remaining list is in sorted scanorder
			// encode zero and make a quick exit
			encode_ari( enc, model, 0 );
			break;
		}
		
		// list is not in sorted order -> next pos hat to be encoded
		cpos = 1;
		// encode position
		for ( tpos = 0; freqlist[ tpos ] != zsrtscan[ cmp ][ i ]; tpos++ )
			if ( freqlist[ tpos ] != 0 ) cpos++;
		// remove from list
		freqlist[ tpos ] = 0;
		
		// encode coded position in list
		encode_ari( enc, model, cpos );
		model->shift_context( cpos );		
	}
	
	// delete model
	delete( model );
	
	// set zero sort scan as freqscan
	freqscan[ cmp ] = zsrtscan[ cmp ];
	
	
	return true;
}


/* -----------------------------------------------
	encodes # of non zeroes to pjg (high)
	----------------------------------------------- */	
INTERN bool pjg_encode_zdst_high( ArithmeticEncoder* enc, int cmp )
{
	model_s* model;
	
	unsigned char* zdstls;
	int dpos;
	int a, b;
	int bc;
	int w;
	
	
	// init model, constants
	model = INIT_MODEL_S( 49 + 1, 25 + 1, 1 );
	zdstls = zdstdata[ cmp ];
	w = cmpnfo[cmp].bch;
	bc = cmpnfo[cmp].bc;
	
	// arithmetic encode zero-distribution-list
	for ( dpos = 0; dpos < bc; dpos++ ) {
		// context modelling - use average of above and left as context
		get_context_nnb( dpos, w, &a, &b );
		a = ( a >= 0 ) ? zdstls[ a ] : 0;
		b = ( b >= 0 ) ? zdstls[ b ] : 0;
		// shift context
		model->shift_context( ( a + b + 2 ) / 4 );
		// encode symbol
		encode_ari( enc, model, zdstls[ dpos ] );
	}
	
	// clean up
	delete( model );
	
	
	return true;
}


/* -----------------------------------------------
	encodes # of non zeroes to pjg (low)
	----------------------------------------------- */	
INTERN bool pjg_encode_zdst_low( ArithmeticEncoder* enc, int cmp )
{
	model_s* model;
	
	unsigned char* zdstls_x;
	unsigned char* zdstls_y;
	unsigned char* ctx_zdst;
	unsigned char* ctx_eobx;
	unsigned char* ctx_eoby;
	
	int dpos;
	int bc;
	
	
	// init model, constants
	model = INIT_MODEL_S( 8, 8, 2 );
	zdstls_x = zdstxlow[ cmp ];
	zdstls_y = zdstylow[ cmp ];
	ctx_eobx = eobxhigh[ cmp ];
	ctx_eoby = eobyhigh[ cmp ];
	ctx_zdst = zdstdata[ cmp ];
	bc = cmpnfo[cmp].bc;
	
	// arithmetic encode zero-distribution-list (first row)
	for ( dpos = 0; dpos < bc; dpos++ ) {
		model->shift_context( ( ctx_zdst[dpos] + 3 ) / 7 ); // shift context
		model->shift_context( ctx_eobx[dpos] ); // shift context
		encode_ari( enc, model, zdstls_x[ dpos ] ); // encode symbol
	}
	// arithmetic encode zero-distribution-list (first collumn)
	for ( dpos = 0; dpos < bc; dpos++ ) {
		model->shift_context( ( ctx_zdst[dpos] + 3 ) / 7 ); // shift context
		model->shift_context( ctx_eoby[dpos] ); // shift context
		encode_ari( enc, model, zdstls_y[ dpos ] ); // encode symbol
	}
	
	// clean up
	delete( model );
	
	
	return true;
}


/* -----------------------------------------------
	encodes DC coefficients to pjg
	----------------------------------------------- */
INTERN bool pjg_encode_dc( ArithmeticEncoder* enc, int cmp )
{
	unsigned char* segm_tab;

	model_s* mod_len;
	model_b* mod_sgn;
	model_b* mod_res;

	unsigned char* zdstls; // pointer to zero distribution list
	signed short* coeffs; // pointer to current coefficent data

	unsigned short* absv_store; // absolute coefficients values storage
	unsigned short* c_absc[ 6 ]; // quick access array for contexts
	int c_weight[ 6 ]; // weighting for contexts

	unsigned char* sgn_store; // sign storage for context
	unsigned char* sgn_nbh; // left signs neighbor
	unsigned char* sgn_nbv; // upper signs neighbor

	int ctx_avr; // 'average' context
	int ctx_len; // context for bit length
	int ctx_sgn; // context for sign

	int max_val; // max value
	int max_len; // max bitlength

	int dpos;
	int clen, absv, sgn;
	int snum;
	int bt, bp;

	int p_x, p_y;
	int r_x; //, r_y;
	int w, bc;


	// v4.0 cross-component DC: Cb/Cr DC uses Y DC bit-length as extra context.
	bool use_cc = pjg_use_crosscomp_now && cmp != 0 && cmpc >= 2
	            && cmpnfo[cmp].bc == cmpnfo[0].bc;
	signed short* y_coeffs = use_cc ? colldata[ 0 ][ 0 ] : NULL;

	// decide segmentation setting
	segm_tab = segm_tables[ segm_cnt[ cmp ] - 1 ];

	// get max absolute value/bit length
	max_val = MAX_V( cmp, 0 );
	max_len = BITLEN1024P( max_val );

	// init models for bitlenghts and -patterns
	{
		int mod_len_maxc = ( segm_cnt[cmp] > max_len ) ? segm_cnt[cmp] : max_len + 1;
		if ( use_cc ) mod_len_maxc = ( ( max_len + 1 ) << 3 ); // compound (ctx_len<<3|y_class)
		// v4.0b: 4 diag-variance buckets multiply the context space (only when
		// flag set — i.e., file has the 0x02 sub-marker indicating v4.0b features)
		if ( pjg_use_diag_dc_now ) mod_len_maxc <<= 2;
		mod_len = INIT_MODEL_S( max_len + 1, mod_len_maxc, 2 );
	}
	mod_res = INIT_MODEL_B( ( segm_cnt[cmp] < 16 ) ? 1 << 4 : segm_cnt[cmp], 2 );
	mod_sgn = INIT_MODEL_B( 9, 1 );

	// set width/height of each band
	bc = cmpnfo[cmp].bc;
	w = cmpnfo[cmp].bch;

	// allocate memory for absolute values and sign storage
	absv_store = (unsigned short*) calloc ( bc, sizeof( short ) );
	sgn_store = (unsigned char*) calloc ( bc, sizeof( char ) );
	if ( ( absv_store == NULL ) || ( sgn_store == NULL ) ) {
		if ( absv_store != NULL ) free( absv_store );
		if ( sgn_store != NULL ) free( sgn_store );
		snprintf( errormessage, MSG_SIZE, MEM_ERRMSG );
		errorlevel = 2;
		return false;
	}

	// set up quick access arrays for sign context
	sgn_nbh = sgn_store - 1;
	sgn_nbv = sgn_store - w;

	// set up context quick access array
	pjg_aavrg_prepare( c_absc, c_weight, absv_store, cmp );

	// locally store pointer to coefficients and zero distribution list
	coeffs = colldata[ cmp ][ 0 ];
	zdstls = zdstdata[ cmp ];

	// arithmetic compression loop
	for ( dpos = 0; dpos < bc; dpos++ )
	{
		//calculate x/y positions in band
		p_y = dpos / w;
		// r_y = h - ( p_y + 1 );
		p_x = dpos % w;
		r_x = w - ( p_x + 1 );

		// get segment-number from zero distribution list and segmentation set
		snum = segm_tab[ zdstls[dpos] ];
		// calculate contexts (for bit length)
		ctx_avr = pjg_aavrg_context( c_absc, c_weight, dpos, p_y, p_x, r_x ); // AVERAGE context
		ctx_len = BITLEN1024P( ctx_avr ); // BITLENGTH context
		int ctx_shift = ctx_len;
		int ctx_dim   = max_len + 1;
		if ( use_cc ) {
			int y_abs = ABS( y_coeffs[ dpos ] );
			int y_clen = BITLEN1024P( y_abs );
			if ( y_clen > 7 ) y_clen = 7;
			ctx_shift = ( ctx_len << 3 ) | y_clen;
			ctx_dim   = ( max_len + 1 ) << 3;
		}
		// v4.0b: diagonal/anti-diagonal absv variance from already-encoded
		// neighbors. |L - T| captures main-diagonal slope; |T - TR| captures
		// anti-diagonal slope at the top edge. Both available pre-encode in raster.
		// Gated by pjg_use_diag_dc_now so v4.0a files decode without it.
		if ( pjg_use_diag_dc_now ) {
			int diag_var = 0;
			if ( p_y > 0 ) {
				int top_v = (int) c_absc[2][dpos];
				if ( p_x > 0 ) diag_var += ABS( (int) c_absc[5][dpos] - top_v );
				if ( r_x > 0 ) diag_var += ABS( top_v - (int) c_absc[3][dpos] );
			}
			int diag_ctx = ( diag_var < 2 ) ? 0
			             : ( diag_var < 8 ) ? 1
			             : ( diag_var < 32 ) ? 2
			             : 3;
			ctx_shift += diag_ctx * ctx_dim;
		}
		// shift context / do context modelling (segmentation is done per context)
		shift_model( mod_len, ctx_shift, snum );

		// simple treatment if coefficient is zero
		if ( coeffs[ dpos ] == 0 ) {
			// encode bit length (0) of current coefficient
			encode_ari( enc, mod_len, 0 );
		}
		else {
			// get absolute val, sign & bit length for current coefficient
			absv = ABS( coeffs[dpos] );
			clen = BITLEN1024P( absv );
			sgn = ( coeffs[dpos] > 0 ) ? 0 : 1;
			// encode bit length of current coefficient
			encode_ari( enc, mod_len, clen );
			// encoding of residual
			// first set bit must be 1, so we start at clen - 2
			for ( bp = clen - 2; bp >= 0; bp-- ) {
				shift_model( mod_res, snum, bp ); // shift in 2 contexts
				// encode/get bit
				bt = BITN( absv, bp );
				encode_ari( enc, mod_res, bt );
			}
			// encode sign (left + top neighbor context)
			ctx_sgn = ( p_x > 0 ) ? sgn_nbh[ dpos ] : 0;
			if ( p_y > 0 ) ctx_sgn += 3 * sgn_nbv[ dpos ];
			if ( ctx_sgn > 8 ) ctx_sgn = 8;
			mod_sgn->shift_context( ctx_sgn );
			encode_ari( enc, mod_sgn, sgn );
			// store absolute value and sign
			absv_store[ dpos ] = absv;
			sgn_store[ dpos ] = sgn + 1;
		}
	}

	// free memory / clear models
	free( absv_store );
	free( sgn_store );
	delete ( mod_len );
	delete ( mod_res );
	delete ( mod_sgn );
	
	
	return true;
}


/* -----------------------------------------------
	encodes high (7x7) AC coefficients to pjg
	----------------------------------------------- */
INTERN bool pjg_encode_ac_high( ArithmeticEncoder* enc, int cmp )
{
	unsigned char* segm_tab;
	
	model_s* mod_len;
	model_b* mod_sgn;
	model_b* mod_res;
	
	unsigned char* zdstls; // pointer to zero distribution list
	unsigned char* eob_x; // pointer to x eobs
	unsigned char* eob_y; // pointer to y eobs
	signed short* coeffs; // pointer to current coefficent data
	
	unsigned short* absv_store; // absolute coefficients values storage
	unsigned short* c_absc[ 6 ]; // quick access array for contexts
	int c_weight[ 6 ]; // weighting for contexts
	
	unsigned char* sgn_store; // sign storage for context	
	unsigned char* sgn_nbh; // left signs neighbor
	unsigned char* sgn_nbv; // upper signs neighbor

	int ctx_avr; // 'average' context
	int ctx_len; // context for bit length
	int ctx_sgn; // context for sign
	
	int max_val; // max value
	int max_len; // max bitlength
	
	int bpos, dpos;
	int clen, absv, sgn;
	int snum;
	int bt, bp;
	int i;
	
	int b_x, b_y;
	int p_x, p_y;
	int r_x; //, r_y;
	int w, bc;


	// v4.0 cross-component: Cb/Cr on sequential path use Y's bit-length at the
	// same (bpos,dpos) as extra context. Only enabled for matching geometry
	// (4:4:4); 4:2:x weakens the correlation (downsampling averages chroma) so
	// gate on exact block-count equality.
	bool use_cc = pjg_use_crosscomp_now && cmp != 0 && cmpc >= 2
	            && cmpnfo[cmp].bc == cmpnfo[0].bc;
	signed short* y_coeffs = NULL; // set per bpos inside the loop when use_cc

	// decide segmentation setting
	segm_tab = segm_tables[ segm_cnt[ cmp ] - 1 ];

	// init models for bitlenghts and -patterns
	{
		int mod_len_maxc = ( segm_cnt[cmp] > 11 ) ? segm_cnt[cmp] : 11;
		if ( use_cc ) mod_len_maxc = 128; // holds compound (ctx_len<<3|y_class)
		mod_len = INIT_MODEL_S( 11, mod_len_maxc, 2 );
	}
	mod_res = INIT_MODEL_B( ( segm_cnt[cmp] < 16 ) ? 1 << 4 : segm_cnt[cmp], 2 );
	mod_sgn = INIT_MODEL_B( 27, 1 );

	// set width/height of each band
	bc = cmpnfo[cmp].bc;
	w = cmpnfo[cmp].bch;

	// allocate memory for absolute values & signs storage
	absv_store = (unsigned short*) calloc ( bc, sizeof( short ) );
	sgn_store = (unsigned char*) calloc ( bc, sizeof( char ) );
	zdstls = (unsigned char*) calloc ( bc, sizeof( char ) );
	if ( ( absv_store == NULL ) || ( sgn_store == NULL ) || ( zdstls == NULL ) ) {
		if ( absv_store != NULL ) free( absv_store );
		if ( sgn_store != NULL ) free( sgn_store );
		if ( zdstls != NULL ) free( zdstls );
		snprintf( errormessage, MSG_SIZE, MEM_ERRMSG );
		errorlevel = 2;
		return false;
	}

	// set up quick access arrays for signs context
	sgn_nbh = sgn_store - 1;
	sgn_nbv = sgn_store - w;

	// locally store pointer to eob x / eob y
	eob_x = eobxhigh[ cmp ];
	eob_y = eobyhigh[ cmp ];

	// preset x/y eobs
	memset( eob_x, 0x00, bc * sizeof( char ) );
	memset( eob_y, 0x00, bc * sizeof( char ) );

	// make a local copy of the zero distribution list
	for ( dpos = 0; dpos < bc; dpos++ )
		zdstls[ dpos ] = zdstdata[ cmp ][ dpos ];

	// work through lower 7x7 bands in order of freqscan
	for ( i = 1; i < 64; i++ )
	{
		// work through blocks in order of frequency scan
		bpos = (int) freqscan[cmp][i];
		b_x = unzigzag[ bpos ] % 8;
		b_y = unzigzag[ bpos ] / 8;

		if ( ( b_x == 0 ) || ( b_y == 0 ) )
			continue; // process remaining coefficients elsewhere

		// preset absolute values/sign storage
		memset( absv_store, 0x00, bc * sizeof( short ) );
		memset( sgn_store, 0x00, bc * sizeof( char ) );

		// set up average context quick access arrays
		pjg_aavrg_prepare( c_absc, c_weight, absv_store, cmp );

		// locally store pointer to coefficients
		coeffs = colldata[ cmp ][ bpos ];
		if ( use_cc ) y_coeffs = colldata[ 0 ][ bpos ];

		// get max bit length
		max_val = MAX_V( cmp, bpos );
		max_len = BITLEN1024P( max_val );

		// arithmetic compression loo
		for ( dpos = 0; dpos < bc; dpos++ )
		{
			// skip if beyound eob
			if ( zdstls[dpos] == 0 )
				continue;

			//calculate x/y positions in band
			p_y = dpos / w;
			// r_y = h - ( p_y + 1 );
			p_x = dpos % w;
			r_x = w - ( p_x + 1 );

			// get segment-number from zero distribution list and segmentation set
			snum = segm_tab[ zdstls[dpos] ];
			// calculate contexts (for bit length)
			ctx_avr = pjg_aavrg_context( c_absc, c_weight, dpos, p_y, p_x, r_x ); // AVERAGE context
			ctx_len = BITLEN1024P( ctx_avr ); // BITLENGTH context
			int ctx_shift = ctx_len;
			if ( use_cc ) {
				int y_abs = ABS( y_coeffs[ dpos ] );
				int y_clen = BITLEN1024P( y_abs );
				if ( y_clen > 7 ) y_clen = 7;
				ctx_shift = ( ctx_len << 3 ) | y_clen;
			}
			// shift context / do context modelling (segmentation is done per context)
			shift_model( mod_len, ctx_shift, snum );
			mod_len->exclude_symbols(max_len);

			// simple treatment if coefficient is zero
			if ( coeffs[ dpos ] == 0 ) {
				// encode bit length (0) of current coefficien
				encode_ari( enc, mod_len, 0 );
			}
			else {
				// get absolute val, sign & bit length for current coefficient
				absv = ABS( coeffs[dpos] );
				clen = BITLEN1024P( absv );
				sgn = ( coeffs[dpos] > 0 ) ? 0 : 1;
				// encode bit length of current coefficient				
				encode_ari( enc, mod_len, clen );
				// encoding of residual
				// first set bit must be 1, so we start at clen - 2
				for ( bp = clen - 2; bp >= 0; bp-- ) { 
					shift_model( mod_res, snum, bp ); // shift in 2 contexts
					// encode/get bit
					bt = BITN( absv, bp );
					encode_ari( enc, mod_res, bt );
				}
				// encode sign (left + top + top-left diagonal context)
				ctx_sgn = ( p_x > 0 ) ? sgn_nbh[ dpos ] : 0;
				if ( p_y > 0 ) ctx_sgn += 3 * sgn_nbv[ dpos ];
				if ( p_x > 0 && p_y > 0 ) { int diag = sgn_store[ dpos - 1 - w ]; if ( diag > 0 ) ctx_sgn += 9 * diag; }
				if ( ctx_sgn > 26 ) ctx_sgn = 26;
				mod_sgn->shift_context( ctx_sgn );
				encode_ari( enc, mod_sgn, sgn );
				// store absolute value/sign, decrement zdst
				absv_store[ dpos ] = absv;
				sgn_store[ dpos ] = sgn + 1;
				zdstls[dpos]--;
				// recalculate x/y eob				
				if ( b_x > eob_x[dpos] ) eob_x[dpos] = b_x;
				if ( b_y > eob_y[dpos] ) eob_y[dpos] = b_y;
			}
		}
		// flush models
		mod_len->flush_model();
		mod_res->flush_model();
		mod_sgn->flush_model();
	}
	
	// free memory / clear models
	free( absv_store );
	free( sgn_store );
	free( zdstls );
	delete ( mod_len );
	delete ( mod_res );
	delete ( mod_sgn );
	
	
	return true;
}


/* -----------------------------------------------
	encodes first row/col AC coefficients to pjg
	----------------------------------------------- */
INTERN bool pjg_encode_ac_low( ArithmeticEncoder* enc, int cmp )
{
	model_s* mod_len;
	model_b* mod_sgn;
	model_b* mod_res;
	model_b* mod_top;
	
	unsigned char* zdstls; // pointer to row/col # of non-zeroes
	signed short* coeffs; // pointer to current coefficent data
	
	signed short* coeffs_x[ 8 ]; // prediction coeffs - current block
	signed short* coeffs_a[ 8 ]; // prediction coeffs - neighboring block
	int pred_cf[ 8 ]; // prediction multipliers
	
	int ctx_lak; // lakhani context
	int ctx_abs; // absolute context
	int ctx_len; // context for bit length
	int ctx_res; // bit plane context for residual
	int ctx_sgn; // context for sign
	
	int max_valp; // max value (+)
	int max_valn; // max value (-)
	int max_len; // max bitlength
	int thrs_bp; // residual threshold bitplane
	int* edge_c; // edge criteria
	
	int bpos, dpos;
	int clen, absv, sgn;
	int bt, bp;
	int i;

	int b_x, b_y;
	int p_x, p_y;
	int w, bc;


	// v4.0 cross-component: AC-low Cb/Cr use Y bit-len at same (bpos,dpos).
	bool use_cc = pjg_use_crosscomp_now && cmp != 0 && cmpc >= 2
	            && cmpnfo[cmp].bc == cmpnfo[0].bc;
	signed short* y_coeffs = NULL;

	// init models for bitlenghts and -patterns
	{
		int mod_len_maxc = ( segm_cnt[cmp] > 11 ) ? segm_cnt[cmp] : 11;
		if ( use_cc ) mod_len_maxc = 128; // compound (ctx_len<<3|y_class)
		mod_len = INIT_MODEL_S( 11, mod_len_maxc, 2 );
	}
	mod_res = INIT_MODEL_B( 1 << 4, 2 );
	mod_top = INIT_MODEL_B( ( nois_trs[cmp] > 4 ) ? 1 << nois_trs[cmp] : 1 << 4, 3 );
	mod_sgn = INIT_MODEL_B( 11, 1 );

	// set width/height of each band
	bc = cmpnfo[cmp].bc;
	w = cmpnfo[cmp].bch;

	// work through each first row / first collumn band
	for ( i = 2; i < 16; i++ )
	{
		// alternate between first row and first collumn
		b_x = ( i % 2 == 0 ) ? i / 2 : 0;
		b_y = ( i % 2 == 1 ) ? i / 2 : 0;
		bpos = (int) zigzag[ b_x + (8*b_y) ];

		// locally store pointer to band coefficients
		coeffs = colldata[ cmp ][ bpos ];
		if ( use_cc ) y_coeffs = colldata[ 0 ][ bpos ];
		// store pointers to prediction coefficients
		if ( b_x == 0 ) {
			for ( ; b_x < 8; b_x++ ) {
				coeffs_x[ b_x ] = colldata[ cmp ][ zigzag[b_x+(8*b_y)] ];
				coeffs_a[ b_x ] = colldata[ cmp ][ zigzag[b_x+(8*b_y)] ] - 1;
				pred_cf[ b_x ] = icos_base_8x8[ b_x * 8 ] * QUANT ( cmp, zigzag[b_x+(8*b_y)] );
			} b_x = 0;
			zdstls = zdstylow[ cmp ];
			edge_c = &p_x;
		}
		else { // if ( b_y == 0 )
			for ( ; b_y < 8; b_y++ ) {
				coeffs_x[ b_y ] = colldata[ cmp ][ zigzag[b_x+(8*b_y)] ];
				coeffs_a[ b_y ] = colldata[ cmp ][ zigzag[b_x+(8*b_y)] ] - w;
				pred_cf[ b_y ] = icos_base_8x8[ b_y * 8 ] * QUANT ( cmp, zigzag[b_x+(8*b_y)] );
			} b_y = 0;
			zdstls = zdstxlow[ cmp ];
			edge_c = &p_y;
		}
		
		// get max bit length / other info
		max_valp = MAX_V( cmp, bpos );
		max_valn = -max_valp;
		max_len = BITLEN1024P( max_valp );
		thrs_bp = ( max_len > nois_trs[cmp] ) ? max_len - nois_trs[cmp] : 0;
		
		// arithmetic compression loop
		for ( dpos = 0; dpos < bc; dpos++ )
		{
			// skip if beyound eob
			if ( zdstls[ dpos ] == 0 )
				continue;
			
			// calculate x/y positions in band
			p_y = dpos / w;
			p_x = dpos % w;
			
			// edge treatment / calculate LAKHANI context
			if ( (*edge_c) > 0 )
				ctx_lak = pjg_lakh_context( coeffs_x, coeffs_a, pred_cf, dpos );
			else ctx_lak = 0;
			ctx_lak = CLAMPED( max_valn, max_valp, ctx_lak );
			ctx_len = BITLEN2048N( ctx_lak ); // BITLENGTH context
			int ctx_shift = ctx_len;
			if ( use_cc ) {
				int y_abs = ABS( y_coeffs[ dpos ] );
				int y_clen = BITLEN1024P( y_abs );
				if ( y_clen > 7 ) y_clen = 7;
				ctx_shift = ( ctx_len << 3 ) | y_clen;
			}

			// shift context / do context modelling (segmentation is done per context)
			shift_model( mod_len, ctx_shift, zdstls[ dpos ] );
			mod_len->exclude_symbols(max_len);
			
			// simple treatment if coefficient is zero
			if ( coeffs[ dpos ] == 0 ) {
				// encode bit length (0) of current coefficient
				encode_ari( enc, mod_len, 0 );
			}
			else {
				// get absolute val, sign & bit length for current coefficient
				absv = ABS( coeffs[dpos] );
				clen = BITLEN2048N( absv );
				sgn = ( coeffs[dpos] > 0 ) ? 0 : 1;
				// encode bit length of current coefficient
				encode_ari( enc, mod_len, clen );
				// encoding of residual
				bp = clen - 2; // first set bit must be 1, so we start at clen - 2
				ctx_res = ( bp >= thrs_bp ) ? 1 : 0;
				ctx_abs = ABS( ctx_lak );
				ctx_sgn = ( ctx_lak == 0 ) ? 0 : ( ctx_lak > 0 ) ? 1 : 2;
				for ( ; bp >= thrs_bp; bp-- ) {						
					shift_model( mod_top, ctx_abs >> thrs_bp, ctx_res, clen - thrs_bp ); // shift in 3 contexts
					// encode/get bit
					bt = BITN( absv, bp );
					encode_ari( enc, mod_top, bt );
					// update context
					ctx_res = ctx_res << 1;
					if ( bt ) ctx_res |= 1; 
				}
				for ( ; bp >= 0; bp-- ) {
					shift_model( mod_res, zdstls[ dpos ], bp ); // shift in 2 contexts
					// encode/get bit
					bt = BITN( absv, bp );
					encode_ari( enc, mod_res, bt );
				}
				// encode sign
				shift_model( mod_sgn, ctx_len, ctx_sgn );
				encode_ari( enc, mod_sgn, sgn );
				// decrement # of non zeroes
				zdstls[ dpos ]--;
			}
		}
		// flush models
		mod_len->flush_model();
		mod_res->flush_model();
		mod_top->flush_model();
		mod_sgn->flush_model();
	}
	
	// free memory / clear models
	delete ( mod_len );
	delete ( mod_res );
	delete ( mod_top );
	delete ( mod_sgn );
	
	
	return true;
}


/* -----------------------------------------------
	encodes a stream of generic (8bit) data to pjg
	----------------------------------------------- */
INTERN bool pjg_encode_generic( ArithmeticEncoder* enc, unsigned char* data, int len )
{
	model_s* model;
	int i;
	
	
	// arithmetic encode data
	model = INIT_MODEL_S( 256 + 1, 256, 1 );
	for ( i = 0; i < len; i++ )
	{
		encode_ari( enc, model, data[ i ] );
		model->shift_context( data[ i ] );
	}
	// encode end-of-data symbol (256)
	encode_ari( enc, model, 256 );
	delete( model );
	
	
	return true;
}


/* -----------------------------------------------
	encodes one bit to pjg
	----------------------------------------------- */
INTERN bool pjg_encode_bit( ArithmeticEncoder* enc, unsigned char bit )
{
	model_b* model;
	
	
	// encode one bit
	model = INIT_MODEL_B( 1, -1 );
	encode_ari( enc, model, bit );
	delete( model );
	
	
	return true;
}


/* -----------------------------------------------
	encodes frequency scanorder to pjg
	----------------------------------------------- */
INTERN bool pjg_decode_zstscan( ArithmeticDecoder* dec, int cmp )
{	
	model_s* model;;
	
	unsigned char freqlist[ 64 ];
	int tpos; // true position
	int cpos; // coded position
	int i;
	
	
	// set first position in zero sort scan
	zsrtscan[ cmp ][ 0 ] = 0;
	
	// preset freqlist
	for ( i = 0; i < 64; i++ )
		freqlist[ i ] = stdscan[ i ];
		
	// init model
	model = INIT_MODEL_S( 64, 64, 1 );
	
	// encode scanorder
	for ( i = 1; i < 64; i++ )
	{			
		// reduce range of model
		model->exclude_symbols(64 - i);
		
		// decode symbol
		cpos = decode_ari( dec, model );
		model->shift_context( cpos );
		
		if ( cpos == 0 ) {
			// remaining list is identical to scan
			// fill the scan & make a quick exit				
			for ( tpos = 0; i < 64; i++ ) {
				while ( freqlist[ ++tpos ] == 0 );
				zsrtscan[ cmp ][ i ] = freqlist[ tpos ];
			}
			break;
		}
		
		// decode position from list
		for ( tpos = 0; tpos < 64; tpos++ ) {
			if ( freqlist[ tpos ] != 0 ) cpos--;
			if ( cpos == 0 ) break;
		}
			
		// write decoded position to zero sort scan
		zsrtscan[ cmp ][ i ] = freqlist[ tpos ];
		// remove from list
		freqlist[ tpos ] = 0;
	}
	
	// delete model
	delete( model  );		
	
	// set zero sort scan as freqscan
	freqscan[ cmp ] = zsrtscan[ cmp ];
	
	
	return true;
}


/* -----------------------------------------------
	decodes # of non zeroes from pjg (high)
	----------------------------------------------- */
INTERN bool pjg_decode_zdst_high( ArithmeticDecoder* dec, int cmp )
{
	model_s* model;
	
	unsigned char* zdstls;
	int dpos;
	int a, b;
	int bc;
	int w;
	
	
	// init model, constants
	model = INIT_MODEL_S( 49 + 1, 25 + 1, 1 );
	zdstls = zdstdata[ cmp ];
	w = cmpnfo[cmp].bch;
	bc = cmpnfo[cmp].bc;
	
	// arithmetic decode zero-distribution-list
	for ( dpos = 0; dpos < bc; dpos++ )	{			
		// context modelling - use average of above and left as context		
		get_context_nnb( dpos, w, &a, &b );
		a = ( a >= 0 ) ? zdstls[ a ] : 0;
		b = ( b >= 0 ) ? zdstls[ b ] : 0;
		// shift context
		model->shift_context( ( a + b + 2 ) / 4 );
		// decode symbol
		zdstls[ dpos ] = decode_ari( dec, model );
	}
	
	// clean up
	delete( model );
	
	
	return true;
}


/* -----------------------------------------------
	decodes # of non zeroes from pjg (low)
	----------------------------------------------- */	
INTERN bool pjg_decode_zdst_low( ArithmeticDecoder* dec, int cmp )
{
	model_s* model;
	
	unsigned char* zdstls_x;
	unsigned char* zdstls_y;
	unsigned char* ctx_zdst;
	unsigned char* ctx_eobx;
	unsigned char* ctx_eoby;
	
	int dpos;
	int bc;
	
	
	// init model, constants
	model = INIT_MODEL_S( 8, 8, 2 );
	zdstls_x = zdstxlow[ cmp ];
	zdstls_y = zdstylow[ cmp ];
	ctx_eobx = eobxhigh[ cmp ];
	ctx_eoby = eobyhigh[ cmp ];
	ctx_zdst = zdstdata[ cmp ];
	bc = cmpnfo[cmp].bc;
	
	// arithmetic encode zero-distribution-list (first row)
	for ( dpos = 0; dpos < bc; dpos++ ) {
		model->shift_context( ( ctx_zdst[dpos] + 3 ) / 7 ); // shift context
		model->shift_context( ctx_eobx[dpos] ); // shift context
		zdstls_x[ dpos ] = decode_ari( dec, model ); // decode symbol
	}
	// arithmetic encode zero-distribution-list (first collumn)
	for ( dpos = 0; dpos < bc; dpos++ ) {
		model->shift_context( ( ctx_zdst[dpos] + 3 ) / 7 ); // shift context
		model->shift_context( ctx_eoby[dpos] ); // shift context
		zdstls_y[ dpos ] = decode_ari( dec, model ); // decode symbol
	}
	
	// clean up
	delete( model );
	
	
	return true;
}


/* -----------------------------------------------
	decodes DC coefficients from pjg
	----------------------------------------------- */
INTERN bool pjg_decode_dc( ArithmeticDecoder* dec, int cmp )
{
	unsigned char* segm_tab;

	model_s* mod_len;
	model_b* mod_sgn;
	model_b* mod_res;

	unsigned char* zdstls; // pointer to zero distribution list
	signed short* coeffs; // pointer to current coefficent data

	unsigned short* absv_store; // absolute coefficients values storage
	unsigned short* c_absc[ 6 ]; // quick access array for contexts
	int c_weight[ 6 ]; // weighting for contexts

	unsigned char* sgn_store; // sign storage for context
	unsigned char* sgn_nbh; // left signs neighbor
	unsigned char* sgn_nbv; // upper signs neighbor

	int ctx_avr; // 'average' context
	int ctx_len; // context for bit length
	int ctx_sgn; // context for sign

	int max_val; // max value
	int max_len; // max bitlength

	int dpos;
	int clen, absv, sgn;
	int snum;
	int bt, bp;

	int p_x, p_y;
	int r_x; //, r_y;
	int w, bc;


	// v4.0 cross-component DC: mirror of encoder.
	bool use_cc = pjg_use_crosscomp_now && cmp != 0 && cmpc >= 2
	            && cmpnfo[cmp].bc == cmpnfo[0].bc;
	signed short* y_coeffs = use_cc ? colldata[ 0 ][ 0 ] : NULL;

	// decide segmentation setting
	segm_tab = segm_tables[ segm_cnt[ cmp ] - 1 ];

	// get max absolute value/bit length
	max_val = MAX_V( cmp, 0 );
	max_len = BITLEN1024P( max_val );

	// init models for bitlenghts and -patterns
	{
		int mod_len_maxc = ( segm_cnt[cmp] > max_len ) ? segm_cnt[cmp] : max_len + 1;
		if ( use_cc ) mod_len_maxc = ( ( max_len + 1 ) << 3 );
		// v4.0b: 4 diag-variance buckets multiply the context space (only when
		// flag set — mirrors encoder gating so v4.0a files decode with same
		// model dims as v4.0a encoder used)
		if ( pjg_use_diag_dc_now ) mod_len_maxc <<= 2;
		mod_len = INIT_MODEL_S( max_len + 1, mod_len_maxc, 2 );
	}
	mod_res = INIT_MODEL_B( ( segm_cnt[cmp] < 16 ) ? 1 << 4 : segm_cnt[cmp], 2 );
	mod_sgn = INIT_MODEL_B( 9, 1 );

	// set width/height of each band
	bc = cmpnfo[cmp].bc;
	w = cmpnfo[cmp].bch;

	// allocate memory for absolute values and sign storage
	absv_store = (unsigned short*) calloc ( bc, sizeof( short ) );
	sgn_store = (unsigned char*) calloc ( bc, sizeof( char ) );
	if ( ( absv_store == NULL ) || ( sgn_store == NULL ) ) {
		if ( absv_store != NULL ) free( absv_store );
		if ( sgn_store != NULL ) free( sgn_store );
		snprintf( errormessage, MSG_SIZE, MEM_ERRMSG );
		errorlevel = 2;
		return false;
	}

	// set up quick access arrays for sign context
	sgn_nbh = sgn_store - 1;
	sgn_nbv = sgn_store - w;

	// set up context quick access array
	pjg_aavrg_prepare( c_absc, c_weight, absv_store, cmp );

	// locally store pointer to coefficients and zero distribution list
	coeffs = colldata[ cmp ][ 0 ];
	zdstls = zdstdata[ cmp ];

	// arithmetic compression loop
	for ( dpos = 0; dpos < bc; dpos++ )
	{
		//calculate x/y positions in band
		p_y = dpos / w;
		// r_y = h - ( p_y + 1 );
		p_x = dpos % w;
		r_x = w - ( p_x + 1 );

		// get segment-number from zero distribution list and segmentation set
		snum = segm_tab[ zdstls[dpos] ];
		// calculate contexts (for bit length)
		ctx_avr = pjg_aavrg_context( c_absc, c_weight, dpos, p_y, p_x, r_x ); // AVERAGE context
		ctx_len = BITLEN1024P( ctx_avr ); // BITLENGTH context
		int ctx_shift = ctx_len;
		int ctx_dim   = max_len + 1;
		if ( use_cc ) {
			int y_abs = ABS( y_coeffs[ dpos ] );
			int y_clen = BITLEN1024P( y_abs );
			if ( y_clen > 7 ) y_clen = 7;
			ctx_shift = ( ctx_len << 3 ) | y_clen;
			ctx_dim   = ( max_len + 1 ) << 3;
		}
		// v4.0b: mirror of encoder — diagonal/anti-diagonal absv variance.
		// Gated by pjg_use_diag_dc_now (false for v4.0a files, true for v4.0b).
		if ( pjg_use_diag_dc_now ) {
			int diag_var = 0;
			if ( p_y > 0 ) {
				int top_v = (int) c_absc[2][dpos];
				if ( p_x > 0 ) diag_var += ABS( (int) c_absc[5][dpos] - top_v );
				if ( r_x > 0 ) diag_var += ABS( top_v - (int) c_absc[3][dpos] );
			}
			int diag_ctx = ( diag_var < 2 ) ? 0
			             : ( diag_var < 8 ) ? 1
			             : ( diag_var < 32 ) ? 2
			             : 3;
			ctx_shift += diag_ctx * ctx_dim;
		}
		// shift context / do context modelling (segmentation is done per context)
		shift_model( mod_len, ctx_shift, snum );
		// decode bit length of current coefficient
		clen = decode_ari( dec, mod_len );

		// simple treatment if coefficient is zero
		if ( clen == 0 ) {
			// coeffs[ dpos ] = 0;
		}
		else {
			// decoding of residual
			absv = 1;
			// first set bit must be 1, so we start at clen - 2
			for ( bp = clen - 2; bp >= 0; bp-- ) {
				shift_model( mod_res, snum, bp ); // shift in 2 contexts
				// decode bit
				bt = decode_ari( dec, mod_res );
				// update absv
				absv = absv << 1;
				if ( bt ) absv |= 1;
			}
			// decode sign (left + top neighbor context)
			ctx_sgn = ( p_x > 0 ) ? sgn_nbh[ dpos ] : 0;
			if ( p_y > 0 ) ctx_sgn += 3 * sgn_nbv[ dpos ];
			if ( ctx_sgn > 8 ) ctx_sgn = 8;
			mod_sgn->shift_context( ctx_sgn );
			sgn = decode_ari( dec, mod_sgn );
			// copy to colldata
			coeffs[ dpos ] = ( sgn == 0 ) ? absv : -absv;
			// store absolute value and sign
			absv_store[ dpos ] = absv;
			sgn_store[ dpos ] = sgn + 1;
		}
	}

	// free memory / clear models
	free( absv_store );
	free( sgn_store );
	delete ( mod_len );
	delete ( mod_res );
	delete ( mod_sgn );
	
	
	return true;
}


/* -----------------------------------------------
	decodes high (7x7) AC coefficients to pjg
	----------------------------------------------- */
INTERN bool pjg_decode_ac_high( ArithmeticDecoder* dec, int cmp )
{
	unsigned char* segm_tab;
	
	model_s* mod_len;
	model_b* mod_sgn;
	model_b* mod_res;
	
	unsigned char* zdstls; // pointer to zero distribution list
	unsigned char* eob_x; // pointer to x eobs
	unsigned char* eob_y; // pointer to y eobs
	signed short* coeffs; // pointer to current coefficent data
	
	unsigned short* absv_store; // absolute coefficients values storage
	unsigned short* c_absc[ 6 ]; // quick access array for contexts
	int c_weight[ 6 ]; // weighting for contexts
	
	unsigned char* sgn_store; // sign storage for context	
	unsigned char* sgn_nbh; // left signs neighbor
	unsigned char* sgn_nbv; // upper signs neighbor

	int ctx_avr; // 'average' context
	int ctx_len; // context for bit length
	int ctx_sgn; // context for sign
	
	int max_val; // max value
	int max_len; // max bitlength
	
	int bpos, dpos;
	int clen, absv, sgn;
	int snum;
	int bt, bp;
	int i;
	
	int b_x, b_y;
	int p_x, p_y;
	int r_x;
	int w, bc;


	// v4.0 cross-component: mirror of encoder — only active for matching block
	// geometry (4:4:4); 4:2:x gate ruled out by measurement.
	bool use_cc = pjg_use_crosscomp_now && cmp != 0 && cmpc >= 2
	            && cmpnfo[cmp].bc == cmpnfo[0].bc;
	signed short* y_coeffs = NULL; // set per bpos inside the loop when use_cc

	// decide segmentation setting
	segm_tab = segm_tables[ segm_cnt[ cmp ] - 1 ];

	// init models for bitlenghts and -patterns
	{
		int mod_len_maxc = ( segm_cnt[cmp] > 11 ) ? segm_cnt[cmp] : 11;
		if ( use_cc ) mod_len_maxc = 128; // holds compound (ctx_len<<3|y_class)
		mod_len = INIT_MODEL_S( 11, mod_len_maxc, 2 );
	}
	mod_res = INIT_MODEL_B( ( segm_cnt[cmp] < 16 ) ? 1 << 4 : segm_cnt[cmp], 2 );
	mod_sgn = INIT_MODEL_B( 27, 1 );

	// set width/height of each band
	bc = cmpnfo[cmp].bc;
	w = cmpnfo[cmp].bch;

	// allocate memory for absolute values & signs storage
	absv_store = (unsigned short*) calloc ( bc, sizeof( short ) );
	sgn_store = (unsigned char*) calloc ( bc, sizeof( char ) );
	zdstls = (unsigned char*) calloc ( bc, sizeof( char ) );
	if ( ( absv_store == NULL ) || ( sgn_store == NULL ) || ( zdstls == NULL ) ) {
		if ( absv_store != NULL ) free( absv_store );
		if ( sgn_store != NULL ) free( sgn_store );
		if ( zdstls != NULL ) free( zdstls );
		snprintf( errormessage, MSG_SIZE, MEM_ERRMSG );
		errorlevel = 2;
		return false;
	}
	
	// set up quick access arrays for signs context
	sgn_nbh = sgn_store - 1;
	sgn_nbv = sgn_store - w;	
	
	// locally store pointer to eob x / eob y
	eob_x = eobxhigh[ cmp ];
	eob_y = eobyhigh[ cmp ];
	
	// preset x/y eobs
	memset( eob_x, 0x00, bc * sizeof( char ) );
	memset( eob_y, 0x00, bc * sizeof( char ) );
	
	// make a local copy of the zero distribution list
	for ( dpos = 0; dpos < bc; dpos++ )
		zdstls[ dpos ] = zdstdata[ cmp ][ dpos ];
	
	// work through lower 7x7 bands in order of freqscan
	for ( i = 1; i < 64; i++ )
	{
		// work through blocks in order of frequency scan
		bpos = (int) freqscan[cmp][i];
		b_x = unzigzag[ bpos ] % 8;
		b_y = unzigzag[ bpos ] / 8;

		if ( ( b_x == 0 ) || ( b_y == 0 ) )
				continue; // process remaining coefficients elsewhere

		// preset absolute values/sign storage
		memset( absv_store, 0x00, bc * sizeof( short ) );
		memset( sgn_store, 0x00, bc * sizeof( char ) );

		// set up average context quick access arrays
		pjg_aavrg_prepare( c_absc, c_weight, absv_store, cmp );

		// locally store pointer to coefficients
		coeffs = colldata[ cmp ][ bpos ];
		if ( use_cc ) y_coeffs = colldata[ 0 ][ bpos ];

		// get max bit length
		max_val = MAX_V( cmp, bpos );
		max_len = BITLEN1024P( max_val );

		// arithmetic compression loop
		for ( dpos = 0; dpos < bc; dpos++ )
		{
			// skip if beyound eob
			if ( zdstls[dpos] == 0 )
				continue;

			//calculate x/y positions in band
			p_y = dpos / w;
			// r_y = h - ( p_y + 1 );
			p_x = dpos % w;
			r_x = w - ( p_x + 1 );

			// get segment-number from zero distribution list and segmentation set
			snum = segm_tab[ zdstls[dpos] ];
			// calculate contexts (for bit length)
			ctx_avr = pjg_aavrg_context( c_absc, c_weight, dpos, p_y, p_x, r_x ); // AVERAGE context
			ctx_len = BITLEN1024P( ctx_avr ); // BITLENGTH context
			int ctx_shift = ctx_len;
			if ( use_cc ) {
				int y_abs = ABS( y_coeffs[ dpos ] );
				int y_clen = BITLEN1024P( y_abs );
				if ( y_clen > 7 ) y_clen = 7;
				ctx_shift = ( ctx_len << 3 ) | y_clen;
			}
			// shift context / do context modelling (segmentation is done per context)
			shift_model( mod_len, ctx_shift, snum );
			mod_len->exclude_symbols(max_len);

			// decode bit length of current coefficient
			clen = decode_ari( dec, mod_len );
			// simple treatment if coefficient is zero
			if ( clen == 0 ) {
				// coeffs[ dpos ] = 0;
			}
			else {
				// decoding of residual
				absv = 1;
				// first set bit must be 1, so we start at clen - 2
				for ( bp = clen - 2; bp >= 0; bp-- ) {
					shift_model( mod_res, snum, bp ); // shift in 2 contexts
					// decode bit
					bt = decode_ari( dec, mod_res );
					// update absv
					absv = absv << 1;
					if ( bt ) absv |= 1; 
				}
				// decode sign (left + top + top-left diagonal context)
				ctx_sgn = ( p_x > 0 ) ? sgn_nbh[ dpos ] : 0;
				if ( p_y > 0 ) ctx_sgn += 3 * sgn_nbv[ dpos ];
				if ( p_x > 0 && p_y > 0 ) { int diag = sgn_store[ dpos - 1 - w ]; if ( diag > 0 ) ctx_sgn += 9 * diag; }
				if ( ctx_sgn > 26 ) ctx_sgn = 26;
				mod_sgn->shift_context( ctx_sgn );
				sgn = decode_ari( dec, mod_sgn );
				// copy to colldata
				coeffs[ dpos ] = ( sgn == 0 ) ? absv : -absv;
				// store absolute value/sign, decrement zdst
				absv_store[ dpos ] = absv;
				sgn_store[ dpos ] = sgn + 1;
				zdstls[dpos]--;
				// recalculate x/y eob
				if ( b_x > eob_x[dpos] ) eob_x[dpos] = b_x;
				if ( b_y > eob_y[dpos] ) eob_y[dpos] = b_y;	
			}
		}
		// flush models
		mod_len->flush_model();
		mod_res->flush_model();
		mod_sgn->flush_model();
	}
	
	// free memory / clear models
	free( absv_store );
	free( sgn_store );
	free( zdstls );
	delete ( mod_len );
	delete ( mod_res );
	delete ( mod_sgn );
	
	
	return true;
}


/* -----------------------------------------------
	decodes high (7x7) AC coefficients to pjg
	----------------------------------------------- */
INTERN bool pjg_decode_ac_low( ArithmeticDecoder* dec, int cmp )
{
	model_s* mod_len;
	model_b* mod_sgn;
	model_b* mod_res;
	model_b* mod_top;
	
	unsigned char* zdstls; // pointer to row/col # of non-zeroes
	signed short* coeffs; // pointer to current coefficent data
	
	signed short* coeffs_x[ 8 ]; // prediction coeffs - current block
	signed short* coeffs_a[ 8 ]; // prediction coeffs - neighboring block
	int pred_cf[ 8 ]; // prediction multipliers

	int ctx_lak; // lakhani context
	int ctx_abs; // absolute context
	int ctx_len; // context for bit length
	int ctx_res; // bit plane context for residual
	int ctx_sgn; // context for sign
	
	int max_valp; // max value (+)
	int max_valn; // max value (-)
	int max_len; // max bitlength
	int thrs_bp; // residual threshold bitplane
	int* edge_c; // edge criteria
	
	int bpos, dpos;
	int clen, absv, sgn;
	int bt, bp;
	int i;

	int b_x, b_y;
	int p_x, p_y;
	int w, bc;


	// v4.0 cross-component: AC-low Cb/Cr use Y bit-len at same (bpos,dpos).
	bool use_cc = pjg_use_crosscomp_now && cmp != 0 && cmpc >= 2
	            && cmpnfo[cmp].bc == cmpnfo[0].bc;
	signed short* y_coeffs = NULL;

	// init models for bitlenghts and -patterns
	{
		int mod_len_maxc = ( segm_cnt[cmp] > 11 ) ? segm_cnt[cmp] : 11;
		if ( use_cc ) mod_len_maxc = 128; // compound (ctx_len<<3|y_class)
		mod_len = INIT_MODEL_S( 11, mod_len_maxc, 2 );
	}
	mod_res = INIT_MODEL_B( 1 << 4, 2 );
	mod_top = INIT_MODEL_B( ( nois_trs[cmp] > 4 ) ? 1 << nois_trs[cmp] : 1 << 4, 3 );
	mod_sgn = INIT_MODEL_B( 11, 1 );

	// set width/height of each band
	bc = cmpnfo[cmp].bc;
	w = cmpnfo[cmp].bch;

	// work through each first row / first collumn band
	for ( i = 2; i < 16; i++ )
	{
		// alternate between first row and first collumn
		b_x = ( i % 2 == 0 ) ? i / 2 : 0;
		b_y = ( i % 2 == 1 ) ? i / 2 : 0;
		bpos = (int) zigzag[ b_x + (8*b_y) ];

		// locally store pointer to band coefficients
		coeffs = colldata[ cmp ][ bpos ];
		if ( use_cc ) y_coeffs = colldata[ 0 ][ bpos ];
		// store pointers to prediction coefficients
		if ( b_x == 0 ) {
			for ( ; b_x < 8; b_x++ ) {
				coeffs_x[ b_x ] = colldata[ cmp ][ zigzag[b_x+(8*b_y)] ];
				coeffs_a[ b_x ] = colldata[ cmp ][ zigzag[b_x+(8*b_y)] ] - 1;
				pred_cf[ b_x ] = icos_base_8x8[ b_x * 8 ] * QUANT ( cmp, zigzag[b_x+(8*b_y)] );
			} b_x = 0;
			zdstls = zdstylow[ cmp ];
			edge_c = &p_x;
		}
		else { // if ( b_y == 0 )
			for ( ; b_y < 8; b_y++ ) {
				coeffs_x[ b_y ] = colldata[ cmp ][ zigzag[b_x+(8*b_y)] ];
				coeffs_a[ b_y ] = colldata[ cmp ][ zigzag[b_x+(8*b_y)] ] - w;
				pred_cf[ b_y ] = icos_base_8x8[ b_y * 8 ] * QUANT ( cmp, zigzag[b_x+(8*b_y)] );
			} b_y = 0;
			zdstls = zdstxlow[ cmp ];
			edge_c = &p_y;
		}
		
		// get max bit length / other info
		max_valp = MAX_V( cmp, bpos );
		max_valn = -max_valp;
		max_len = BITLEN1024P( max_valp );
		thrs_bp = ( max_len > nois_trs[cmp] ) ? max_len - nois_trs[cmp] : 0;
		
		// arithmetic compression loop
		for ( dpos = 0; dpos < bc; dpos++ )
		{
			// skip if beyound eob
			if ( zdstls[ dpos ] == 0 )
				continue;
			
			//calculate x/y positions in band
			p_y = dpos / w;
			p_x = dpos % w;
			
			// edge treatment / calculate LAKHANI context
			if ( (*edge_c) > 0 )
				ctx_lak = pjg_lakh_context( coeffs_x, coeffs_a, pred_cf, dpos );
			else ctx_lak = 0;
			ctx_lak = CLAMPED( max_valn, max_valp, ctx_lak );
			ctx_len = BITLEN2048N( ctx_lak ); // BITLENGTH context
			int ctx_shift = ctx_len;
			if ( use_cc ) {
				int y_abs = ABS( y_coeffs[ dpos ] );
				int y_clen = BITLEN1024P( y_abs );
				if ( y_clen > 7 ) y_clen = 7;
				ctx_shift = ( ctx_len << 3 ) | y_clen;
			}
			// shift context / do context modelling (segmentation is done per context)
			shift_model( mod_len, ctx_shift, zdstls[ dpos ] );
			mod_len->exclude_symbols(max_len);

			// decode bit length of current coefficient
			clen = decode_ari( dec, mod_len );
			// simple treatment if coefficients == 0
			if ( clen == 0 ) {
				// coeffs[ dpos ] = 0;
			}
			else {
				// decoding of residual
				bp = clen - 2; // first set bit must be 1, so we start at clen - 2
				ctx_res = ( bp >= thrs_bp ) ? 1 : 0;
				ctx_abs = ABS( ctx_lak );
				ctx_sgn = ( ctx_lak == 0 ) ? 0 : ( ctx_lak > 0 ) ? 1 : 2;
				for ( ; bp >= thrs_bp; bp-- ) {						
					shift_model( mod_top, ctx_abs >> thrs_bp, ctx_res, clen - thrs_bp ); // shift in 3 contexts
					// decode bit
					bt = decode_ari( dec, mod_top );
					// update context
					ctx_res = ctx_res << 1;
					if ( bt ) ctx_res |= 1; 
				}
				absv = ( ctx_res == 0 ) ? 1 : ctx_res; // !!!!
				for ( ; bp >= 0; bp-- ) {
					shift_model( mod_res, zdstls[ dpos ], bp ); // shift in 2 contexts
					// decode bit
					bt = decode_ari( dec, mod_res );
					// update absv
					absv = absv << 1;
					if ( bt ) absv |= 1; 
				}
				// decode sign
				shift_model( mod_sgn, zdstls[ dpos ], ctx_sgn );
				sgn = decode_ari( dec, mod_sgn );
				// copy to colldata
				coeffs[ dpos ] = ( sgn == 0 ) ? absv : -absv;
				// decrement # of non zeroes
				zdstls[ dpos ]--;
			}
		}
		// flush models
		mod_len->flush_model();
		mod_res->flush_model();
		mod_top->flush_model();
		mod_sgn->flush_model();
	}
	
	// free memory / clear models
	delete ( mod_len );
	delete ( mod_res );
	delete ( mod_top );
	delete ( mod_sgn );
	
	
	return true;
}


/* -----------------------------------------------
	deodes a stream of generic (8bit) data from pjg
	----------------------------------------------- */
INTERN bool pjg_decode_generic( ArithmeticDecoder* dec, unsigned char** data, int* len )
{
	MemoryWriter* bwrt;
	model_s* model;
	int c;
	
	
	// start byte writer
	bwrt = new MemoryWriter();
	
	// decode header, ending with 256 symbol
	// 64 MB limit guards against corrupt streams where the end symbol (256) never appears.
	// Must be large enough for JPEGs with embedded thumbnails / large APP segments (~2 MB headers seen).
	const int decode_limit = 64 * 1024 * 1024;
	model = INIT_MODEL_S( 256 + 1, 256, 1 );
	while ( true ) {
		c = decode_ari( dec, model );
		if ( c == 256 ) break;
		if ( bwrt->num_bytes_written() >= (size_t) decode_limit ) {
			delete( model );
			delete bwrt;
			snprintf( errormessage, MSG_SIZE, "corrupt data: decoder exceeded size limit" );
			errorlevel = 2;
			return false;
		}
		bwrt->write_byte( (unsigned char) c );
		model->shift_context( c );
	}
	delete( model );
	
	// check for out of memory
	if ( bwrt->error() ) {
		delete bwrt;
		snprintf( errormessage, MSG_SIZE, MEM_ERRMSG );
		errorlevel = 2;
		return false;
	}
	
	// get data/length and close byte writer
	(*data) = bwrt->get_c_data();
	if ( len != NULL ) (*len) = bwrt->num_bytes_written();
	delete bwrt;
	
	
	return true;
}


/* -----------------------------------------------
	decodes one bit from pjg
	----------------------------------------------- */
INTERN bool pjg_decode_bit( ArithmeticDecoder* dec, unsigned char* bit )
{
	model_b* model;
	
	
	model = INIT_MODEL_B( 1, -1 );
	(*bit) = decode_ari( dec, model );
	delete( model );
	
	
	return true;
}


/* -----------------------------------------------
	get zero sort frequency scan vector
	----------------------------------------------- */
INTERN void pjg_get_zerosort_scan( unsigned char* sv, int cmp )
{
	unsigned int zdist[ 64 ]; // distributions of zeroes per band
	int bc = cmpnfo[cmp].bc;
	int bpos, dpos;	
	bool done = false;
	int swap;
	int i;
	
		
	// preset sv & zdist
	for ( i = 0; i < 64; i++ ) {
		sv[ i ] = i;
		zdist[ i ] = 0;
	}	
	
	// count zeroes for each frequency
	for ( bpos = 0; bpos < 64; bpos++ )
	for ( dpos = 0; dpos < bc; dpos++ )			
		if ( colldata[cmp][bpos][dpos] == 0 ) zdist[ bpos ]++;
	
	// bubble sort according to count of zeroes (descending order)
	while ( !done ) {
		done = true;
		for ( i = 2; i < 64; i++ )
		if ( zdist[ i ] < zdist[ i - 1 ] ) {
		
			swap = zdist[ i ];
			zdist[ i ] = zdist[ i - 1 ];
			zdist[ i - 1 ] = swap;
			
			swap = sv[ i ];
			sv[ i ] = sv[ i - 1 ];
			sv[ i - 1 ] = swap;
			
			done = false;			
		}
	}
}


/* -----------------------------------------------
	optimizes JFIF header for compression
	----------------------------------------------- */
INTERN bool pjg_optimize_header( void )
{
	unsigned char  type = 0x00; // type of current marker segment
	unsigned int   len  = 0; // length of current marker segment
	unsigned int   hpos = 0; // position in header
	
	unsigned int fpos; // end of marker position
	unsigned int skip; // bytes to skip
	unsigned int spos; // sub position
	int i;
	
	
	// search for DHT (0xFFC4) & DQT (0xFFDB) marker segments
	// header parser loop
	while ( (int)hpos + 4 <= hdrs ) {
		type = hdrdata[ hpos + 1 ];
		len = 2 + B_SHORT( hdrdata[ hpos + 2 ], hdrdata[ hpos + 3 ] );
		if ( type == 0xC4 ) { // for DHT
			fpos = hpos + len; // reassign length to end position
			hpos += 4; // skip marker & length
			while ( hpos < fpos ) {
				hpos++;
				// table found - compare with each of the four standard tables		
				for ( i = 0; i < 4; i++ ) {
					for ( spos = 0; spos < std_huff_lengths[ i ]; spos++ ) {
						if ( hdrdata[ hpos + spos ] != std_huff_tables[ i ][ spos ] )
							break;
					}
					// check if comparison ok
					if ( spos != std_huff_lengths[ i ] )
						continue;
					
					// if we get here, the table matches the standard table
					// number 'i', so it can be replaced
					hdrdata[ hpos + 0 ] = std_huff_lengths[ i ] - 16 - i;
					hdrdata[ hpos + 1 ] = i;
					for ( spos = 2; spos < std_huff_lengths[ i ]; spos++ )
						hdrdata[ hpos + spos ] = 0x00;
					// everything done here, so leave
					break;
				}
								
				skip = 16;
				for ( i = 0; i < 16; i++ )		
					skip += ( int ) hdrdata[ hpos + i ];				
				hpos += skip;
			}
		}
		else if ( type == 0xDB ) { // for DQT
			fpos = hpos + len; // reassign length to end position
			hpos += 4; // skip marker & length
			while ( hpos < fpos ) {
				i = LBITS( hdrdata[ hpos ], 4 );				
				hpos++;
				// table found
				if ( i == 1 ) { // get out for 16 bit precision
					hpos += 128;
					continue;
				}
				// do diff coding for 8 bit precision
				for ( spos = 63; spos > 0; spos-- )
					hdrdata[ hpos + spos ] -= hdrdata[ hpos + spos - 1 ];
					
				hpos += 64;
			}
		}
		else { // skip segment
			hpos += len;
		}		
	}
	
	
	return true;
}


/* -----------------------------------------------
	undoes the header optimizations
	----------------------------------------------- */
INTERN bool pjg_unoptimize_header( void )
{
	unsigned char  type = 0x00; // type of current marker segment
	unsigned int   len  = 0; // length of current marker segment
	unsigned int   hpos = 0; // position in header
	
	unsigned int fpos; // end of marker position
	unsigned int skip; // bytes to skip
	unsigned int spos; // sub position	
	int i;
	
	
	// search for DHT (0xFFC4) & DQT (0xFFDB) marker segments
	// header parser loop
	while ( (int)hpos + 4 <= hdrs ) {
		type = hdrdata[ hpos + 1 ];
		len = 2 + B_SHORT( hdrdata[ hpos + 2 ], hdrdata[ hpos + 3 ] );

		if ( type == 0xC4 ) { // for DHT
			fpos = hpos + len; // reassign length to end position
			hpos += 4; // skip marker & length
			while ( hpos < fpos ) {			
				hpos++;
				// table found - check if modified
				if ( hdrdata[ hpos ] > 2 ) {	
					// reinsert the standard table
					i = hdrdata[ hpos + 1 ];
					for ( spos = 0; spos < std_huff_lengths[ i ]; spos++ ) {
						hdrdata[ hpos + spos ] = std_huff_tables[ i ][ spos ];
					}
				}
								
				skip = 16;
				for ( i = 0; i < 16; i++ )		
					skip += ( int ) hdrdata[ hpos + i ];				
				hpos += skip;
			}
		}
		else if ( type == 0xDB ) { // for DQT
			fpos = hpos + len; // reassign length to end position
			hpos += 4; // skip marker & length
			while ( hpos < fpos ) {
				i = LBITS( hdrdata[ hpos ], 4 );				
				hpos++;
				// table found
				if ( i == 1 ) { // get out for 16 bit precision
					hpos += 128;
					continue;
				}
				// undo diff coding for 8 bit precision
				for ( spos = 1; spos < 64; spos++ )
					hdrdata[ hpos + spos ] += hdrdata[ hpos + spos - 1 ];
					
				hpos += 64;
			}
		}
		else { // skip segment
			hpos += len;
		}		
	}
	
	
	return true;
}


/* -----------------------------------------------
	preparations for special average context
	----------------------------------------------- */
INTERN void pjg_aavrg_prepare( unsigned short** abs_coeffs, int* weights, unsigned short* abs_store, int cmp )
{
	int w = cmpnfo[cmp].bch;
	
	// set up quick access arrays for all prediction positions
	abs_coeffs[ 0 ] = abs_store + (  0 + ((-2)*w) ); // top-top
	abs_coeffs[ 1 ] = abs_store + ( -1 + ((-1)*w) ); // top-left
	abs_coeffs[ 2 ] = abs_store + (  0 + ((-1)*w) ); // top
	abs_coeffs[ 3 ] = abs_store + (  1 + ((-1)*w) ); // top-right
	abs_coeffs[ 4 ] = abs_store + ( -2 + (( 0)*w) ); // left-left
	abs_coeffs[ 5 ] = abs_store + ( -1 + (( 0)*w) ); // left
	// copy context weighting factors
	weights[ 0 ] = abs_ctx_weights_lum[ 0 ][ 0 ][ 2 ]; // top-top
	weights[ 1 ] = abs_ctx_weights_lum[ 0 ][ 1 ][ 1 ]; // top-left
	weights[ 2 ] = abs_ctx_weights_lum[ 0 ][ 1 ][ 2 ]; // top
	weights[ 3 ] = abs_ctx_weights_lum[ 0 ][ 1 ][ 3 ]; // top-right
	weights[ 4 ] = abs_ctx_weights_lum[ 0 ][ 2 ][ 0 ]; // left-left
	weights[ 5 ] = abs_ctx_weights_lum[ 0 ][ 2 ][ 1 ]; // left
}


/* -----------------------------------------------
	special average context used in coeff encoding
	----------------------------------------------- */
INTERN int pjg_aavrg_context( unsigned short** abs_coeffs, int* weights, int pos, int p_y, int p_x, int r_x )
{
	int ctx_avr = 0; // AVERAGE context
	int w_ctx = 0; // accumulated weight of context
	int w_curr; // current weight of context
	
	
	// different cases due to edge treatment
	if ( p_y >= 2 ) {
		w_curr = weights[ 0 ]; ctx_avr += abs_coeffs[ 0 ][ pos ] * w_curr; w_ctx += w_curr;
		w_curr = weights[ 2 ]; ctx_avr += abs_coeffs[ 2 ][ pos ] * w_curr; w_ctx += w_curr;
		if ( p_x >= 2 ) {
			w_curr = weights[ 1 ]; ctx_avr += abs_coeffs[ 1 ][ pos ] * w_curr; w_ctx += w_curr;
			w_curr = weights[ 4 ]; ctx_avr += abs_coeffs[ 4 ][ pos ] * w_curr; w_ctx += w_curr;
			w_curr = weights[ 5 ]; ctx_avr += abs_coeffs[ 5 ][ pos ] * w_curr; w_ctx += w_curr;
		}
		else if ( p_x == 1 ) {
			w_curr = weights[ 1 ]; ctx_avr += abs_coeffs[ 1 ][ pos ] * w_curr; w_ctx += w_curr;
			w_curr = weights[ 5 ]; ctx_avr += abs_coeffs[ 5 ][ pos ] * w_curr; w_ctx += w_curr;
		}
		if ( r_x >= 1 ) {
			w_curr = weights[ 3 ]; ctx_avr += abs_coeffs[ 3 ][ pos ] * w_curr; w_ctx += w_curr;
		}
	}
	else if ( p_y == 1 ) {
		w_curr = weights[ 2 ]; ctx_avr += abs_coeffs[ 2 ][ pos ] * w_curr; w_ctx += w_curr;
		if ( p_x >= 2 ) {
			w_curr = weights[ 1 ]; ctx_avr += abs_coeffs[ 1 ][ pos ] * w_curr; w_ctx += w_curr;
			w_curr = weights[ 4 ]; ctx_avr += abs_coeffs[ 4 ][ pos ] * w_curr; w_ctx += w_curr;
			w_curr = weights[ 5 ]; ctx_avr += abs_coeffs[ 5 ][ pos ] * w_curr; w_ctx += w_curr;
		}
		else if ( p_x == 1 ) {
			w_curr = weights[ 1 ]; ctx_avr += abs_coeffs[ 1 ][ pos ] * w_curr; w_ctx += w_curr;
			w_curr = weights[ 5 ]; ctx_avr += abs_coeffs[ 5 ][ pos ] * w_curr; w_ctx += w_curr;
		}
		if ( r_x >= 1 ) {
			w_curr = weights[ 3 ]; ctx_avr += abs_coeffs[ 3 ][ pos ] * w_curr; w_ctx += w_curr;
		}
	}
	else {
		if ( p_x >= 2 ) {
			w_curr = weights[ 4 ]; ctx_avr += abs_coeffs[ 4 ][ pos ] * w_curr; w_ctx += w_curr;
			w_curr = weights[ 5 ]; ctx_avr += abs_coeffs[ 5 ][ pos ] * w_curr; w_ctx += w_curr;
		}
		else if ( p_x == 1 ) {
			w_curr = weights[ 5 ]; ctx_avr += abs_coeffs[ 5 ][ pos ] * w_curr; w_ctx += w_curr;
		}
	}
	
	// return average context
	return ( w_ctx != 0 ) ? ( ctx_avr + ( w_ctx / 2 ) ) / w_ctx : 0;
}


/* -----------------------------------------------
	lakhani ac context used in coeff encoding
	----------------------------------------------- */
INTERN int pjg_lakh_context( signed short** coeffs_x, signed short** coeffs_a, int* pred_cf, int pos )
{
	int pred = 0;
	
	// calculate partial prediction
	pred -= ( coeffs_x[ 1 ][ pos ] + coeffs_a[ 1 ][ pos ] ) * pred_cf[ 1 ];
	pred -= ( coeffs_x[ 2 ][ pos ] - coeffs_a[ 2 ][ pos ] ) * pred_cf[ 2 ];
	pred -= ( coeffs_x[ 3 ][ pos ] + coeffs_a[ 3 ][ pos ] ) * pred_cf[ 3 ];
	pred -= ( coeffs_x[ 4 ][ pos ] - coeffs_a[ 4 ][ pos ] ) * pred_cf[ 4 ];
	pred -= ( coeffs_x[ 5 ][ pos ] + coeffs_a[ 5 ][ pos ] ) * pred_cf[ 5 ];
	pred -= ( coeffs_x[ 6 ][ pos ] - coeffs_a[ 6 ][ pos ] ) * pred_cf[ 6 ];
	pred -= ( coeffs_x[ 7 ][ pos ] + coeffs_a[ 7 ][ pos ] ) * pred_cf[ 7 ];
	// normalize / quantize partial prediction
	pred = ( ( pred > 0 ) ? ( pred + (pred_cf[0]/2) ) : ( pred - (pred_cf[0]/2) ) ) / pred_cf[ 0 ];
	// complete prediction
	pred += coeffs_a[ 0 ][ pos ];
	
	return pred;
}


/* -----------------------------------------------
	Calculates coordinates for nearest neighbor context
	----------------------------------------------- */
INTERN void get_context_nnb( int pos, int w, int *a, int *b )
{
	// this function calculates and returns coordinates for
	// a simple 2D context
	if ( pos == 0 ) {
		*a = -1;
		*b = -1;
	}
	else if ( ( pos % w ) == 0 ) {
		*b = pos - w;
		if ( pos >= ( w << 1 ) )
			*a = pos - ( w << 1 );
		else
			*a = *b;
	}
	else if ( pos < w ) {
		*a = pos - 1;
		if ( pos >= 2 )
			*b = pos - 2;
		else
			*b = *a;
	}
	else {
		*a = pos - 1;
		*b = pos - w;
	}
}

/* ----------------------- End of PJG specific functions -------------------------- */

/* ----------------------- Begin ofDCT specific functions -------------------------- */


/* -----------------------------------------------
	inverse DCT transform using precalc tables (fast)
	----------------------------------------------- */
#if !defined(BUILD_LIB) && defined(DEV_BUILD)
INTERN int idct_2d_fst_8x8( int cmp, int dpos, int ix, int iy )
{
	int idct = 0;
	int ixy;
	
	
	// calculate start index
	ixy = ( ( iy << 3 ) + ix ) << 6;
	
	// begin transform
	idct += colldata[ cmp ][  0 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 0 ];
	idct += colldata[ cmp ][  1 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 1 ];
	idct += colldata[ cmp ][  5 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 2 ];
	idct += colldata[ cmp ][  6 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 3 ];
	idct += colldata[ cmp ][ 14 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 4 ];
	idct += colldata[ cmp ][ 15 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 5 ];
	idct += colldata[ cmp ][ 27 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 6 ];
	idct += colldata[ cmp ][ 28 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 7 ];
	idct += colldata[ cmp ][  2 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 8 ];
	idct += colldata[ cmp ][  4 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 9 ];
	idct += colldata[ cmp ][  7 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 10 ];
	idct += colldata[ cmp ][ 13 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 11 ];
	idct += colldata[ cmp ][ 16 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 12 ];
	idct += colldata[ cmp ][ 26 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 13 ];
	idct += colldata[ cmp ][ 29 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 14 ];
	idct += colldata[ cmp ][ 42 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 15 ];
	idct += colldata[ cmp ][  3 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 16 ];
	idct += colldata[ cmp ][  8 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 17 ];
	idct += colldata[ cmp ][ 12 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 18 ];
	idct += colldata[ cmp ][ 17 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 19 ];
	idct += colldata[ cmp ][ 25 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 20 ];
	idct += colldata[ cmp ][ 30 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 21 ];
	idct += colldata[ cmp ][ 41 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 22 ];
	idct += colldata[ cmp ][ 43 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 23 ];
	idct += colldata[ cmp ][  9 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 24 ];
	idct += colldata[ cmp ][ 11 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 25 ];
	idct += colldata[ cmp ][ 18 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 26 ];
	idct += colldata[ cmp ][ 24 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 27 ];
	idct += colldata[ cmp ][ 31 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 28 ];
	idct += colldata[ cmp ][ 40 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 29 ];
	idct += colldata[ cmp ][ 44 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 30 ];
	idct += colldata[ cmp ][ 53 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 31 ];
	idct += colldata[ cmp ][ 10 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 32 ];
	idct += colldata[ cmp ][ 19 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 33 ];
	idct += colldata[ cmp ][ 23 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 34 ];
	idct += colldata[ cmp ][ 32 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 35 ];
	idct += colldata[ cmp ][ 39 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 36 ];
	idct += colldata[ cmp ][ 45 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 37 ];
	idct += colldata[ cmp ][ 52 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 38 ];
	idct += colldata[ cmp ][ 54 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 39 ];
	idct += colldata[ cmp ][ 20 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 40 ];
	idct += colldata[ cmp ][ 22 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 41 ];
	idct += colldata[ cmp ][ 33 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 42 ];
	idct += colldata[ cmp ][ 38 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 43 ];
	idct += colldata[ cmp ][ 46 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 44 ];
	idct += colldata[ cmp ][ 51 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 45 ];
	idct += colldata[ cmp ][ 55 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 46 ];
	idct += colldata[ cmp ][ 60 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 47 ];
	idct += colldata[ cmp ][ 21 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 48 ];
	idct += colldata[ cmp ][ 34 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 49 ];
	idct += colldata[ cmp ][ 37 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 50 ];
	idct += colldata[ cmp ][ 47 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 51 ];
	idct += colldata[ cmp ][ 50 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 52 ];
	idct += colldata[ cmp ][ 56 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 53 ];
	idct += colldata[ cmp ][ 59 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 54 ];
	idct += colldata[ cmp ][ 61 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 55 ];
	idct += colldata[ cmp ][ 35 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 56 ];
	idct += colldata[ cmp ][ 36 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 57 ];
	idct += colldata[ cmp ][ 48 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 58 ];
	idct += colldata[ cmp ][ 49 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 59 ];
	idct += colldata[ cmp ][ 57 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 60 ];
	idct += colldata[ cmp ][ 58 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 61 ];
	idct += colldata[ cmp ][ 62 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 62 ];
	idct += colldata[ cmp ][ 63 ][ dpos ] * adpt_idct_8x8[ cmp ][ ixy + 63 ];
	
	
	return idct;
}
#endif


/* -----------------------------------------------
	inverse DCT transform using precalc tables (fast)
	----------------------------------------------- */
INTERN int idct_2d_fst_8x1( int cmp, int dpos, int ix, int /*iy*/ )
{
	int idct = 0;
	int ixy;
	
	
	// calculate start index
	ixy = ix << 3;
	
	// begin transform
	idct += colldata[ cmp ][  0 ][ dpos ] * adpt_idct_8x1[ cmp ][ ixy + 0 ];
	idct += colldata[ cmp ][  1 ][ dpos ] * adpt_idct_8x1[ cmp ][ ixy + 1 ];
	idct += colldata[ cmp ][  5 ][ dpos ] * adpt_idct_8x1[ cmp ][ ixy + 2 ];
	idct += colldata[ cmp ][  6 ][ dpos ] * adpt_idct_8x1[ cmp ][ ixy + 3 ];
	idct += colldata[ cmp ][ 14 ][ dpos ] * adpt_idct_8x1[ cmp ][ ixy + 4 ];
	idct += colldata[ cmp ][ 15 ][ dpos ] * adpt_idct_8x1[ cmp ][ ixy + 5 ];
	idct += colldata[ cmp ][ 27 ][ dpos ] * adpt_idct_8x1[ cmp ][ ixy + 6 ];
	idct += colldata[ cmp ][ 28 ][ dpos ] * adpt_idct_8x1[ cmp ][ ixy + 7 ];
	
	
	return idct;
}


/* -----------------------------------------------
	inverse DCT transform using precalc tables (fast)
	----------------------------------------------- */
INTERN int idct_2d_fst_1x8( int cmp, int dpos, int /*ix*/, int iy )
{
	int idct = 0;
	int ixy;
	
	
	// calculate start index
	ixy = iy << 3;
	
	// begin transform
	idct += colldata[ cmp ][  0 ][ dpos ] * adpt_idct_1x8[ cmp ][ ixy + 0 ];
	idct += colldata[ cmp ][  2 ][ dpos ] * adpt_idct_1x8[ cmp ][ ixy + 1 ];
	idct += colldata[ cmp ][  3 ][ dpos ] * adpt_idct_1x8[ cmp ][ ixy + 2 ];
	idct += colldata[ cmp ][  9 ][ dpos ] * adpt_idct_1x8[ cmp ][ ixy + 3 ];
	idct += colldata[ cmp ][ 10 ][ dpos ] * adpt_idct_1x8[ cmp ][ ixy + 4 ];
	idct += colldata[ cmp ][ 20 ][ dpos ] * adpt_idct_1x8[ cmp ][ ixy + 5 ];
	idct += colldata[ cmp ][ 21 ][ dpos ] * adpt_idct_1x8[ cmp ][ ixy + 6 ];
	idct += colldata[ cmp ][ 35 ][ dpos ] * adpt_idct_1x8[ cmp ][ ixy + 7 ];
	
	
	return idct;
}

/* ----------------------- End of DCT specific functions -------------------------- */

/* ----------------------- Begin of prediction functions -------------------------- */


/* -----------------------------------------------
	returns predictor for collection data
	----------------------------------------------- */
#if defined(USE_PLOCOI)
// LOCO-I predictor: median(a+b-c, min(a,b), max(a,b))
static inline int plocoi( int a, int b, int c ) {
	int mx = ( a > b ) ? a : b;
	int mn = ( a < b ) ? a : b;
	int pred = a + b - c;
	if ( pred < mn ) return mn;
	if ( pred > mx ) return mx;
	return pred;
}

INTERN int dc_coll_predictor( int cmp, int dpos )
{
	signed short* coefs = colldata[ cmp ][ 0 ];
	int w = cmpnfo[cmp].bch;
	int a, b, c;
	
	if ( dpos < w ) {
		a = coefs[ dpos - 1 ];
		b = 0;
		c = 0;
	}
	else if ( (dpos%w) == 0 ) {
		a = 0;
		b = coefs[ dpos - w ];
		c = 0;
	}
	else {
		a = coefs[ dpos - 1 ];
		b = coefs[ dpos - w ];
		c = coefs[ dpos - 1 - w ];
	}
	
	return plocoi( a, b, c );
}
#endif


/* -----------------------------------------------
	1D DCT predictor for DC coefficients
	----------------------------------------------- */
#if !defined(USE_PLOCOI)
INTERN int dc_1ddct_predictor( int cmp, int dpos )
{
	int w  = cmpnfo[cmp].bch;
	int px = ( dpos % w );
	int py = ( dpos / w );
	
	int pred;	
	int pa = 0;
	int pb = 0;
	int xa = 0;
	int xb = 0;
	int swap;
	
	
	// store current block DC coefficient
	swap = colldata[ cmp ][ 0 ][ dpos ];
	colldata[ cmp ][ 0 ][ dpos ] = 0;
	
	// calculate prediction
	if ( ( px > 0 ) && ( py > 0 ) ) {
		pa = idct_2d_fst_8x1( cmp, dpos - 1, 7, 0 );
		pb = idct_2d_fst_1x8( cmp, dpos - w, 0, 7 );
		xa = idct_2d_fst_8x1( cmp, dpos, 0, 0 );
		xb = idct_2d_fst_1x8( cmp, dpos, 0, 0 );
		pred = ( ( pa - xa ) + ( pb - xb ) ) * ( 8 / 2 );
	}
	else if ( px > 0 ) {
		pa = idct_2d_fst_8x1( cmp, dpos - 1, 7, 0 );
		xa = idct_2d_fst_8x1( cmp, dpos, 0, 0 );
		pred = ( pa - xa ) * 8;
	}
	else if ( py > 0 ) {
		pb = idct_2d_fst_1x8( cmp, dpos - w, 0, 7 );
		xb = idct_2d_fst_1x8( cmp, dpos, 0, 0 );
		pred = ( pb - xb ) * 8;
	}
	else {
		pred = 0;
	}
	
	// write back current DCT coefficient
	colldata[ cmp ][ 0 ][ dpos ] = swap;	
	
	// clamp and quantize predictor
	pred = CLAMPED( -( 1024 * DCT_RSC_FACTOR ), ( 1016 * DCT_RSC_FACTOR ), pred );
	pred = pred / QUANT( cmp, 0 );
	pred = DCT_RESCALE( pred );
	
	
	return pred;
}
#endif

/* ----------------------- End of prediction functions -------------------------- */

/* ----------------------- Begin of miscellaneous helper functions -------------------------- */


/* -----------------------------------------------
	displays progress bar on screen
	----------------------------------------------- */
#if !defined(BUILD_LIB)
INTERN inline void progress_bar( int current, int last )
{
	int barpos = ( ( current * BARLEN ) + ( last / 2 ) ) / last;
	int i;
	
	
	// generate progress bar
	fprintf( msgout, "[" );
	#if defined(_WIN32)
	for ( i = 0; i < barpos; i++ )
		fprintf( msgout, "#" );
	#else
	for ( i = 0; i < barpos; i++ )
		fprintf( msgout, "\xe2\x96\x88" );
	#endif
	#if defined(_WIN32)
	for (  ; i < BARLEN; i++ )
		fprintf( msgout, " " );
	#else
	for (  ; i < BARLEN; i++ )
		fprintf( msgout, "\xe2\x96\x91" );
	#endif
	fprintf( msgout, "]" );
}
#endif

/* -----------------------------------------------
	creates filename, callocs memory for it
	----------------------------------------------- */
#if !defined(BUILD_LIB)
INTERN inline char* create_filename( const char* base, const char* extension )
{
	// Feature #37: if outdir is set, put the output file there instead of next to the input.
	const char* basename_only = base;
	if ( outdir != NULL ) {
		// Find last path separator to get just the filename part
		const char* sep = strrchr( base, '/' );
	#if defined(_WIN32) || defined(WIN32)
		const char* sep2 = strrchr( base, '\\' );
		if ( sep2 > sep ) sep = sep2;
	#endif
		if ( sep != NULL ) basename_only = sep + 1;
	}

	int dirlen  = ( outdir != NULL ) ? strlen( outdir ) + 1 : 0; // +1 for separator
	int len = dirlen + strlen( basename_only ) + ( ( extension == NULL ) ? 0 : strlen( extension ) + 1 ) + 1;
	char* filename = (char*) calloc( len, sizeof( char ) );

	if ( outdir != NULL ) {
		strcpy( filename, outdir );
		// ensure trailing separator
		int dl = strlen( outdir );
		if ( dl > 0 && outdir[ dl-1 ] != '/'
	#if defined(_WIN32) || defined(WIN32)
			&& outdir[ dl-1 ] != '\\'
	#endif
		) strcat( filename, "/" );
		strcat( filename, basename_only );
	} else {
		strcpy( filename, base );
	}
	set_extension( filename, extension );

	return filename;
}
#endif

/* -----------------------------------------------
	creates filename, callocs memory for it
	----------------------------------------------- */
#if !defined(BUILD_LIB)
INTERN inline char* unique_filename( const char* base, const char* extension )
{
	// If outdir is set, start from create_filename which applies outdir,
	// then add underscores until the name is unique.
	char* filename;
	if ( outdir != NULL ) {
		filename = create_filename( base, extension );
	} else {
		int len = strlen( base ) + ( ( extension == NULL ) ? 0 : strlen( extension ) + 1 ) + 1;
		filename = (char*) calloc( len, sizeof( char ) );
		strcpy( filename, base );
		set_extension( filename, extension );
	}

	// add underscores until unique
	while ( file_exists( filename ) ) {
		int len = strlen( filename ) + 2;
		filename = (char*) realloc( filename, len );
		add_underscore( filename );
	}

	return filename;
}
#endif

/* -----------------------------------------------
	changes extension of filename
	----------------------------------------------- */
#if !defined(BUILD_LIB)
INTERN inline void set_extension( char* filename, const char* extension )
{
	char* extstr;
	
	// find position of extension in filename	
	extstr = ( strrchr( filename, '.' ) == NULL ) ?
		strrchr( filename, '\0' ) : strrchr( filename, '.' );
	
	// set new extension
	if ( extension != NULL ) {
		(*extstr++) = '.';
		strcpy( extstr, extension );
	}
	else
		(*extstr) = '\0';
}
#endif

/* -----------------------------------------------
	adds underscore after filename
	----------------------------------------------- */
#if !defined(BUILD_LIB)
INTERN inline void add_underscore( char* filename )
{
	char* tmpname = (char*) calloc( strlen( filename ) + 1, sizeof( char ) );
	char* extstr;
	
	// copy filename to tmpname
	strcpy( tmpname, filename );
	// search extension in filename
	extstr = strrchr( filename, '.' );
	
	// add underscore before extension
	if ( extstr != NULL ) {
		(*extstr++) = '_';
		strcpy( extstr, strrchr( tmpname, '.' ) ); // safe: same length as original
	}
	else {
		size_t n = strlen( tmpname );
		memcpy( filename, tmpname, n );
		filename[ n ] = '_';
		filename[ n + 1 ] = '\0';
	}
		
	// free memory
	free( tmpname );
}
#endif

/* -----------------------------------------------
	checks if a file exists
	----------------------------------------------- */
INTERN inline bool file_exists( const char* filename )
{
	// needed for both, executable and library
	FILE* fp = fopen( filename, "rb" );
	
	if ( fp == NULL ) return false;
	else {
		fclose( fp );
		return true;
	}
}

/* ----------------------- End of miscellaneous helper functions -------------------------- */

/* ----------------------- Begin of developers functions -------------------------- */


/* -----------------------------------------------
	Writes header file
	----------------------------------------------- */
#if !defined(BUILD_LIB) && defined(DEV_BUILD)
INTERN bool dump_hdr( void )
{
	const char* ext = "hdr";
	const char* basename = filelist[ file_no ];
	
	if ( !dump_file( basename, ext, hdrdata, 1, hdrs ) )
		return false;	
	
	return true;
}
#endif


/* -----------------------------------------------
	Writes huffman coded file
	----------------------------------------------- */
#if !defined(BUILD_LIB) && defined(DEV_BUILD)
INTERN bool dump_huf( void )
{
	const char* ext = "huf";
	const char* basename = filelist[ file_no ];
	
	if ( !dump_file( basename, ext, huffdata, 1, hufs ) )
		return false;
	
	return true;
}
#endif


/* -----------------------------------------------
	Writes collections of DCT coefficients
	----------------------------------------------- */
#if !defined(BUILD_LIB) && defined(DEV_BUILD)
INTERN bool dump_coll( void )
{
	FILE* fp;
	
	char* fn;
	const char* ext[ 4 ];
	const char* base;
	int cmp, bpos, dpos;
	int i, j;
	
	ext[0] = "coll0";
	ext[1] = "coll1";
	ext[2] = "coll2";
	ext[3] = "coll3";
	base = filelist[ file_no ];
	
	
	for ( cmp = 0; cmp < cmpc; cmp++ ) {
		
		// create filename
		fn = create_filename( base, ext[ cmp ] );
		
		// open file for output
		fp = fopen( fn, "wb" );
		if ( fp == NULL ){
			snprintf( errormessage, MSG_SIZE, FWR_ERRMSG, fn);
			errorlevel = 2;
			return false;
		}
		free( fn );
		
		switch ( collmode ) {
			
			case 0: // standard collections
				for ( bpos = 0; bpos < 64; bpos++ )
					fwrite( colldata[cmp][bpos], sizeof( short ), cmpnfo[cmp].bc, fp );
				break;
				
			case 1: // sequential order collections, 'dhufs'
				for ( dpos = 0; dpos < cmpnfo[cmp].bc; dpos++ )
				for ( bpos = 0; bpos < 64; bpos++ )
					fwrite( &(colldata[cmp][bpos][dpos]), sizeof( short ), 1, fp );
				break;
				
			case 2: // square collections
				dpos = 0;
				for ( i = 0; i < 64; ) {
					bpos = zigzag[ i++ ];
					fwrite( &(colldata[cmp][bpos][dpos]), sizeof( short ),
						cmpnfo[cmp].bch, fp );
					if ( ( i % 8 ) == 0 ) {
						dpos += cmpnfo[cmp].bch;
						if ( dpos >= cmpnfo[cmp].bc ) {
							dpos = 0;
						}
						else {
							i -= 8;
						}
					}
				}
				break;
				
			case 3: // uncollections
				for ( i = 0; i < ( cmpnfo[cmp].bcv * 8 ); i++ )			
				for ( j = 0; j < ( cmpnfo[cmp].bch * 8 ); j++ ) {
					bpos = zigzag[ ( ( i % 8 ) * 8 ) + ( j % 8 ) ];
					dpos = ( ( i / 8 ) * cmpnfo[cmp].bch ) + ( j / 8 );
					fwrite( &(colldata[cmp][bpos][dpos]), sizeof( short ), 1, fp );
				}
				break;
				
			case 4: // square collections / alt order (even/uneven)
				dpos = 0;
				for ( i = 0; i < 64; ) {
					bpos = even_zigzag[ i++ ];
					fwrite( &(colldata[cmp][bpos][dpos]), sizeof( short ),
						cmpnfo[cmp].bch, fp );
					if ( ( i % 8 ) == 0 ) {
						dpos += cmpnfo[cmp].bch;
						if ( dpos >= cmpnfo[cmp].bc ) {
							dpos = 0;
						}
						else {
							i -= 8;
						}
					}
				}
				break;
				
			case 5: // uncollections / alt order (even/uneven)
				for ( i = 0; i < ( cmpnfo[cmp].bcv * 8 ); i++ )			
				for ( j = 0; j < ( cmpnfo[cmp].bch * 8 ); j++ ) {
					bpos = even_zigzag[ ( ( i % 8 ) * 8 ) + ( j % 8 ) ];
					dpos = ( ( i / 8 ) * cmpnfo[cmp].bch ) + ( j / 8 );
					fwrite( &(colldata[cmp][bpos][dpos]), sizeof( short ), 1, fp );
				}
				break;
		}
		
		fclose( fp );
	}
	
	return true;
}
#endif


/* -----------------------------------------------
	Writes zero distribution data to file;
	----------------------------------------------- */
#if !defined(BUILD_LIB) && defined(DEV_BUILD)
INTERN bool dump_zdst( void )
{
	const char* ext[4];
	const char* basename;
	int cmp;
	
	
	ext[0] = "zdst0";
	ext[1] = "zdst1";
	ext[2] = "zdst2";
	ext[3] = "zdst3";
	basename = filelist[ file_no ];
	
	for ( cmp = 0; cmp < cmpc; cmp++ )
		if ( !dump_file( basename, ext[cmp], zdstdata[cmp], 1, cmpnfo[cmp].bc ) )
			return false;
			
	
	return true;
}
#endif


/* -----------------------------------------------
	Writes to file
	----------------------------------------------- */
#if !defined(BUILD_LIB) && defined(DEV_BUILD)
INTERN bool dump_file( const char* base, const char* ext, void* data, int bpv, int size )
{	
	FILE* fp;
	char* fn;
	
	// create filename
	fn = create_filename( base, ext );
	
	// open file for output
	fp = fopen( fn, "wb" );	
	if ( fp == NULL ) {
		snprintf( errormessage, MSG_SIZE, FWR_ERRMSG, fn);
		errorlevel = 2;
		return false;
	}
	free( fn );
	
	// write & close
	fwrite( data, bpv, size, fp );
	fclose( fp );
	
	return true;
}
#endif


/* -----------------------------------------------
	Writes error info file
	----------------------------------------------- */
#if !defined(BUILD_LIB) && defined(DEV_BUILD)
INTERN bool dump_errfile( void )
{
	FILE* fp;
	char* fn;
	
	
	// return immediately if theres no error
	if ( errorlevel == 0 ) return true;
	
	// create filename based on errorlevel
	if ( errorlevel == 1 ) {
		fn = create_filename( filelist[ file_no ], "wrn.nfo" );
	}
	else {
		fn = create_filename( filelist[ file_no ], "err.nfo" );
	}
	
	// open file for output
	fp = fopen( fn, "w" );
	if ( fp == NULL ){
		snprintf( errormessage, MSG_SIZE, FWR_ERRMSG, fn);
		errorlevel = 2;
		return false;
	}
	free( fn );
	
	// write status and errormessage to file
	fprintf( fp, "--> error (level %i) in file \"%s\" <--\n", errorlevel, filelist[ file_no ] );
	fprintf( fp, "\n" );
	// write error specification to file
	fprintf( fp, " %s -> %s:\n", get_status( errorfunction ),
			( errorlevel == 1 ) ? "warning" : "error" );
	fprintf( fp, " %s\n", errormessage );
	
	// done, close file
	fclose( fp );
	
	
	return true;
}
#endif


/* -----------------------------------------------
	Writes info to textfile
	----------------------------------------------- */
#if !defined(BUILD_LIB) && defined(DEV_BUILD)
INTERN bool dump_info( void )
{	
	FILE* fp;
	char* fn;
	
	unsigned char  type = 0x00; // type of current marker segment
	unsigned int   len  = 0; // length of current marker segment
	unsigned int   hpos = 0; // position in header		
	
	int cmp, bpos;
	int i;
	
	
	// create filename
	fn = create_filename( filelist[ file_no ], "nfo" );
	
	// open file for output
	fp = fopen( fn, "w" );
	if ( fp == NULL ){
		snprintf( errormessage, MSG_SIZE, FWR_ERRMSG, fn);
		errorlevel = 2;
		return false;
	}
	free( fn );

	// info about image
	fprintf( fp, "<Infofile for JPEG image %s>\n\n\n", jpgfilename );
	fprintf( fp, "coding process: %s\n", ( jpegtype == 1 ) ? "sequential" : "progressive" );
	// fprintf( fp, "no of scans: %i\n", scnc );
	fprintf( fp, "imageheight: %i / imagewidth: %i\n", imgheight, imgwidth );
	fprintf( fp, "component count: %i\n", cmpc );
	fprintf( fp, "mcu count: %i/%i/%i (all/v/h)\n\n", mcuc, mcuv, mcuh );
	
	// info about header
	fprintf( fp, "\nfile header structure:\n" );
	fprintf( fp, " type  length   hpos\n" );
	// header parser loop
	for ( hpos = 0; (int)hpos + 4 <= hdrs; hpos += len ) {
		type = hdrdata[ hpos + 1 ];
		len = 2 + B_SHORT( hdrdata[ hpos + 2 ], hdrdata[ hpos + 3 ] );
		fprintf( fp, " FF%2X  %6i %6i\n", (int) type, (int) len, (int) hpos );
	}
	fprintf( fp, " _END       0 %6i\n", (int) hpos );
	fprintf( fp, "\n" );
	
	// info about compression settings	
	fprintf( fp, "\ncompression settings:\n" );
	fprintf( fp, " no of segments    ->  %3i[0] %3i[1] %3i[2] %3i[3]\n",
			segm_cnt[0], segm_cnt[1], segm_cnt[2], segm_cnt[3] );
	fprintf( fp, " noise threshold   ->  %3i[0] %3i[1] %3i[2] %3i[3]\n",
			nois_trs[0], nois_trs[1], nois_trs[2], nois_trs[3] );
	fprintf( fp, "\n" );
	
	// info about components
	for ( cmp = 0; cmp < cmpc; cmp++ ) {
		fprintf( fp, "\n" );
		fprintf( fp, "component number %i ->\n", cmp );
		fprintf( fp, "sample factors: %i/%i (v/h)\n", cmpnfo[cmp].sfv, cmpnfo[cmp].sfh );
		fprintf( fp, "blocks per mcu: %i\n", cmpnfo[cmp].mbs );
		fprintf( fp, "block count (mcu): %i/%i/%i (all/v/h)\n",
			cmpnfo[cmp].bc, cmpnfo[cmp].bcv, cmpnfo[cmp].bch );
		fprintf( fp, "block count (sng): %i/%i/%i (all/v/h)\n",
			cmpnfo[cmp].nc, cmpnfo[cmp].ncv, cmpnfo[cmp].nch );
		fprintf( fp, "quantiser table ->" );
		for ( i = 0; i < 64; i++ ) {
			bpos = zigzag[ i ];
			if ( ( i % 8 ) == 0 ) fprintf( fp, "\n" );
			fprintf( fp, "%4i, ", QUANT( cmp, bpos ) );
		}
		fprintf( fp, "\n" );
		fprintf( fp, "maximum values ->" );
		for ( i = 0; i < 64; i++ ) {
			bpos = zigzag[ i ];
			if ( ( i % 8 ) == 0 ) fprintf( fp, "\n" );
			fprintf( fp, "%4i, ", MAX_V( cmp, bpos ) );
		}
		fprintf( fp, "\n\n" );
	}
	
	
	fclose( fp );
	
	
	return true;
}
#endif


/* -----------------------------------------------
	Writes distribution for use in valdist.h
	----------------------------------------------- */
#if !defined(BUILD_LIB) && defined(DEV_BUILD)
INTERN bool dump_dist( void )
{
	FILE* fp;
	char* fn;
	
	unsigned int dist[ 1024 + 1 ];
	int cmp, bpos, dpos;
	int i;
	
	
	// create filename
	fn = create_filename( filelist[ file_no ], "dist" );
	
	// open file for output
	fp = fopen( fn, "wb" );
	free( fn );
	if ( fp == NULL ){
		snprintf( errormessage, MSG_SIZE, FWR_ERRMSG, fn);
		errorlevel = 2;
		return false;
	}
	
	// calculate & write distributions for each frequency
	for ( cmp = 0; cmp < cmpc; cmp++ )
	for ( bpos = 0; bpos < 64; bpos++ ) {		
		// preset dist with zeroes
		for ( i = 0; i <= 1024; i++ ) dist[ i ] = 0;
		// get distribution
		for ( dpos = 0; dpos < cmpnfo[cmp].bc; dpos++ )
			dist[ ABS( colldata[cmp][bpos][dpos] ) ]++;
		// write to file
		fwrite( dist, sizeof( int ), 1024 + 1, fp );
	}
	
	
	// close file
	fclose( fp );
	
	return true;
}
#endif


/* -----------------------------------------------
	Do inverse DCT and write pgms
	----------------------------------------------- */
#if !defined(BUILD_LIB) && defined(DEV_BUILD)
INTERN bool dump_pgm( void )
{	
	unsigned char* imgdata;
	
	FILE* fp;
	char* fn;
	const char* ext[4];
	
	int cmp, dpos;
	int pix_v;
	int xpos, ypos, dcpos;
	int x, y;
	
	
	ext[0] = "cmp0.pgm";
	ext[1] = "cmp1.pgm";
	ext[2] = "cmp2.pgm";
	ext[3] = "cmp3.pgm";
	
	
	for ( cmp = 0; cmp < cmpc; cmp++ )
	{
		// create filename
		fn = create_filename( filelist[ file_no ], ext[ cmp ] );
		
		// open file for output
		fp = fopen( fn, "wb" );		
		if ( fp == NULL ){
			snprintf( errormessage, MSG_SIZE, FWR_ERRMSG, fn );
			errorlevel = 2;
			return false;
		}
		free( fn );
		
		// alloc memory for image data
		imgdata = (unsigned char*) calloc ( cmpnfo[cmp].bc * 64, sizeof( char ) );
		if ( imgdata == NULL ) {
			fclose( fp );
			snprintf( errormessage, MSG_SIZE, MEM_ERRMSG );
			errorlevel = 2;
			return false;
		}
		
		for ( dpos = 0; dpos < cmpnfo[cmp].bc; dpos++ )	{	
			// do inverse DCT, store in imgdata
			dcpos  = ( ( ( dpos / cmpnfo[cmp].bch ) * cmpnfo[cmp].bch ) << 6 ) +
					   ( ( dpos % cmpnfo[cmp].bch ) << 3 );
			for ( y = 0; y < 8; y++ ) {
				ypos = dcpos + ( y * ( cmpnfo[cmp].bch << 3 ) );
				for ( x = 0; x < 8; x++ ) {
					xpos = ypos + x;
					pix_v = idct_2d_fst_8x8( cmp, dpos, x, y );
					pix_v = DCT_RESCALE( pix_v );
					pix_v = pix_v + 128;
					imgdata[ xpos ] = ( unsigned char ) CLAMPED( 0, 255, pix_v );
				}
			}			
		}
		
		// write PGM header
		fprintf( fp, "P5\n" );
		fprintf( fp, "# created by %s v%i.%i%s (%s) by %s\n",
			apptitle, appversion / 10, appversion % 10, subversion, versiondate, author );
		fprintf( fp, "%i %i\n", cmpnfo[cmp].bch * 8, cmpnfo[cmp].bcv * 8 );
		fprintf( fp, "255\n" );
		
		// write image data
		fwrite( imgdata, sizeof( char ), cmpnfo[cmp].bc * 64, fp );
		
		// free memory
		free( imgdata );
		
		// close file
		fclose( fp );
	}
	
	return true;
}
#endif

/* ----------------------- End of developers functions -------------------------- */


/* -----------------------------------------------
	list stats about a JPEG file without compressing
	----------------------------------------------- */
#if !defined(BUILD_LIB)
INTERN bool list_jpg( void )
{
	auto fmt_size = []( int64_t bytes ) -> std::string {
		char buf[32];
		if ( bytes >= 1024 * 1024 )
			snprintf( buf, sizeof(buf), "%.2f MB", bytes / (1024.0*1024.0) );
		else if ( bytes >= 1024 )
			snprintf( buf, sizeof(buf), "%.1f KB", bytes / 1024.0 );
		else
			snprintf( buf, sizeof(buf), "%lld B", (long long) bytes );
		return buf;
	};

	const char* color_mode = ( cmpc == 1 ) ? "grayscale" :
	                          ( cmpc == 3 ) ? "YCbCr (color)" :
	                          ( cmpc == 4 ) ? "CMYK" : "unknown";

	fprintf( msgout, "  size    : %s\n", fmt_size( jpgfilesize ).c_str() );
	fprintf( msgout, "  dimensions : %i x %i\n", imgwidth, imgheight );
	fprintf( msgout, "  components : %i (%s)\n", cmpc, color_mode );

	pjgfilesize = 0;
	return true;
}
#endif


/* -----------------------------------------------
	list info about a PJG file without decompressing
	----------------------------------------------- */

#if !defined(BUILD_LIB)
INTERN bool list_pjg( void )
{
	long pjg_size = (long) str_in->get_size();

	// read version from header: skip 2-byte magic, read hcode
	str_in->rewind();
	unsigned char magic[2];
	str_in->read( magic, 2 );
	unsigned char hcode = 0;
	str_in->read_byte( &hcode );
	// if hcode == 0x00 it's a custom-settings block — skip 8 bytes then read actual version
	// if hcode == 0x01 it's an sfth parallel-format marker — skip it and read the version byte
	bool is_sfth = false;
	if ( hcode == 0x00 ) {
		str_in->skip( 8 );
		str_in->read_byte( &hcode );
	} else if ( hcode == 0x01 ) {
		is_sfth = true;
		str_in->read_byte( &hcode );
	}
	int ver_major = hcode / 10;
	int ver_minor = hcode % 10;

	auto fmt_size = []( long bytes ) -> std::string {
		char buf[32];
		if ( bytes >= 1024 * 1024 )
			snprintf( buf, sizeof(buf), "%.2f MB", bytes / (1024.0*1024.0) );
		else if ( bytes >= 1024 )
			snprintf( buf, sizeof(buf), "%.1f KB", bytes / 1024.0 );
		else
			snprintf( buf, sizeof(buf), "%ld B", bytes );
		return buf;
	};

	if ( is_sfth )
		fprintf( msgout, "  version : v%i.%i (parallel)\n", ver_major, ver_minor );
	else
		fprintf( msgout, "  version : v%i.%i\n", ver_major, ver_minor );
	fprintf( msgout, "  packed  : %s\n", fmt_size( pjg_size ).c_str() );

	pjgfilesize = (int) pjg_size;
	jpgfilesize  = 0;

	return true;
}
#endif

/* ----------------------- End of file -------------------------- */
