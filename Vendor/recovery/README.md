# Password recovery runtime

LightZip 0.7 uses independent command-line helpers. No Homebrew installation is required at runtime. The packaged build targets the current Mac architecture and macOS 26.

## Hashcat 7.1.2

Upstream source: https://hashcat.net/files/hashcat-7.1.2.tar.gz
SHA-256: `9546a6326d747530b44fcc079babad40304a87f32d3c9080016d58b39cfc8b96`

Apply LightZip's MIT-licensed patch `patches/0001-low-latency-dispatch.patch` with `patch -p1` in the extracted source directory, then build with Xcode tools: `make -j8`. Copy `hashcat`, `hashcat.hcstat2`, `OpenCL`, `tunings`, and modules 00000 (required for initialization), 11600, 12500, 13000, 13600, 17200, 17210, 17220, 17225, 17230, 23700, 23800. Run `python3 scripts/recovery_cache_key.py Vendor/recovery/hashcat` from the LightZip repository after copying. The app build regenerates this manifest after signing helpers. Dependencies are linked statically except system frameworks/libraries. All upstream licensing is included in `Licenses`; the local patch is also distributed with the app's build notes.

The app copies the signed executable into a private job directory, links kernel sources from a stable ASCII cache path (the Apple compiler cannot use Chinese include paths), and links read-only module resources from its bundle. Hashcat chooses the available backend automatically; on the tested Apple M4 Pro it selects the OpenCL GPU for default runs. Metal was separately verified with `--backend-ignore-opencl`. No CPU fallback is advertised on Apple Silicon. Workload is 1; self-tests and temperature protection remain enabled. Potfile, logging and restore are disabled. Hashes, candidates, results and job files are removed after success, exhaustion, failure or cancellation. Bundled kernel sources and compiled `.kernel` / `.metallib` programs persist in the user's `Caches/local.lightzip.app/RecoveryKernels`, keyed by a SHA-256 manifest of the shipped runtime and macOS version; Hashcat additionally keys programs by GPU, driver and kernel options. For a non-ASCII cache path, stable sources use the current user's macOS temporary directory with an ASCII versioned name. Compiled programs are copied into each job and atomically saved after a successful engine run. The source include path stays stable across jobs because it contributes to Hashcat's kernel identity. Caching is optional; if unavailable, the app falls back to a private copy. A compiled-program or self-test failure with restored programs discards cached binaries and retries compilation once, leaving active source links intact.

Short mask lengths are combined into one bounded, private wordlist so GPU batches can span lengths: up to 1.5 million candidates, covering digits 1–6 or either larger alphabet 1–3 when starting at length 1. Generation uses a 64 KiB buffer and checks cancellation between writes; it never materializes the full unbounded search space. The generated file is mode 0600 and is removed with the job. Any remaining lengths run as lazy masks only after this complete prefix is exhausted, with cumulative progress across both phases. The 7Z optimized kernel is enabled only for the bounded ASCII mask UI (maximum 12 bytes, below the kernel's 20-byte limit). User dictionaries and rules retain the unrestricted pure-kernel behavior.

For generated wordlists only, LightZip sets `LIGHTZIP_RAMP_BATCHES=1`. The local dispatch patch caps the first assignment at 2,048 candidates, then grows through 4,096, 8,192 and so on up to the engine's tuned batch size. This keeps the same process, initialization, kernels and normal offset/progress accounting. It does not change cryptographic computation, autotune, self-tests or temperature protection, and does not require `--force`. Other dictionaries and mask tasks use upstream dispatch. Initialization and autotune still happen on each engine invocation; this is compiled-program caching, not a permanently running GPU service.

## John the Ripper converters

Upstream bleeding-jumbo source snapshot downloaded 2026-09-22:
https://github.com/openwall/john/archive/refs/heads/bleeding-jumbo.tar.gz
Exact corresponding source is distributed as `john-source.tar.gz`.
SHA-256: `4e52df429c4de289162c9d12ea830c8a122f24be0f3f4de2d4f15b7ea1352262`

Build in `src`:

```sh
./configure --disable-openmp --disable-native-tests --without-openssl --without-gmp --disable-opencl
make -s -j8
```

Copy `run/john` and create `zip2john` / `rar2john` symlinks to it. Only the converters are invoked; John does not perform candidate guessing. The helper links only macOS system libraries. GPL v2 or later with the upstream OpenSSL/unRAR exception; full terms and corresponding source accompany the binary. The application communicates with it using an independent process.

## 7z2hashcat 2.2 and Perl support

Unmodified public-domain script:
https://github.com/philsmd/7z2hashcat/blob/master/7z2hashcat.pl
SHA-256: `2ad58723d2dee9df9c789e46a3cfd82415d7e8db419d0bdbbd23621aade80a2a`

Uses macOS `/usr/bin/perl` 5.34 and the bundled Compress::Raw::Lzma 2.219 module (same terms as Perl).
Source: https://cpan.metacpan.org/authors/id/P/PM/PMQS/Compress-Raw-Lzma-2.219.tar.gz
SHA-256: `b01aa36a238b2f3e993a959a925b57c338b1ecf17e9e3a7950d70f12a22124cd`

Build with the system Perl, pointing `LIBLZMA_INCLUDE` and `LIBLZMA_LIB` to an XZ development installation:

```sh
LIBLZMA_INCLUDE=/opt/homebrew/include LIBLZMA_LIB=/opt/homebrew/lib /usr/bin/perl Makefile.PL INSTALL_BASE=/absolute/path/to/Vendor/recovery/perl
make -s
make -s install
```

Bundle liblzma.5.dylib from XZ 5.8.3 (0BSD), beside Lzma.bundle. Change the module dependency to `@loader_path/liblzma.5.dylib` and the dylib ID to the same value using the Xcode `install_name_tool`. Re-sign both after relinking. `scripts/build.py` signs all bundled Mach-O components using the existing local identity. Source and license: https://tukaani.org/xz/ .

## Limits

Format detection uses file signatures; Hashcat identifies the extracted hash mode. Unsupported encryption, incomplete multipart archives, missing tools and unavailable devices produce explicit failures. Converter output is bounded to 64 MiB and conversion to 120 seconds. Self-extracting executables and arbitrary encryption algorithms are not advertised. Dictionary rules operate on the candidate bytes, so ASCII letters/digits/symbols are the most interoperable input; non-UTF-8 recovered passwords cannot be applied by the app. Recovery is a candidate search, not a universal decryption shortcut.

A recovered candidate is checked once using 7-Zip's integrity test on the smallest encrypted member. No archive contents are extracted by recovery. Passwords are not passed in arguments, written to task history or sent over the network. The temporary result file contains hex-encoded plaintext and is private to the job until it is removed.
