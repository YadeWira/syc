fn main() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    // ── packJPG ──────────────────────────────────────────────────────────────
    let pjg_src = [
        "vendor/packjpg/aricoder.cpp",
        "vendor/packjpg/bitops.cpp",
        "vendor/packjpg/packjpg.cpp",
    ];

    let mut pjg_build = cc::Build::new();
    pjg_build
        .cpp(true)
        .std("c++17")
        .opt_level(3)
        .flag_if_supported("-funroll-loops")
        .flag_if_supported("-ffast-math")
        .flag_if_supported("-fomit-frame-pointer")
        .flag_if_supported("-Wall")
        .define("BUILD_LIB", None)
        .cpp_link_stdlib(None);

    if target_os != "windows" {
        pjg_build.define("UNIX", None);
    }

    pjg_build.files(pjg_src).compile("packjpg");

    // ── packPNG ──────────────────────────────────────────────────────────────
    let mut ppg_build = cc::Build::new();
    ppg_build
        .cpp(true)
        .std("c++17")
        .opt_level(3)
        .flag_if_supported("-funroll-loops")
        .flag_if_supported("-ffast-math")
        .flag_if_supported("-fomit-frame-pointer")
        .flag_if_supported("-Wall")
        .define("BUILD_LIB", None)
        .cpp_link_stdlib(None);

    if target_os == "windows" {
        // On Windows cross-compile there is no system liblzma. Use the static
        // library that lzma-sys already built for this target (via DEP_LZMA_ROOT)
        // and add the bundled xz-5.2 headers from the lzma-sys crate source.
        if let Ok(lzma_root) = std::env::var("DEP_LZMA_ROOT") {
            ppg_build.include(format!("{lzma_root}/include"));
            println!("cargo:rustc-link-search=native={lzma_root}/lib");
        } else {
            // Fallback: find lzma.h inside the lzma-sys bundled xz source tree.
            let cargo_home = std::env::var("CARGO_HOME")
                .unwrap_or_else(|_| format!("{}/.cargo", std::env::var("HOME").unwrap_or_default()));
            let lzma_sys_src = format!(
                "{}/registry/src/index.crates.io-1949cf8c6b5b557f/lzma-sys-0.1.20/xz-5.2/src/liblzma/api",
                cargo_home
            );
            ppg_build.include(&lzma_sys_src);
        }
        ppg_build.include("/usr/x86_64-w64-mingw32/include");
    }

    ppg_build.file("vendor/packpng/packpng.cpp").compile("packpng");

    // Link zlib and liblzma (packPNG runtime deps).
    if target_os == "windows" {
        println!("cargo:rustc-link-lib=static=z");
        // lzma is already linked by lzma-sys; no explicit link needed here.
    } else {
        println!("cargo:rustc-link-lib=z");
        println!("cargo:rustc-link-lib=lzma");
    }

    // ── C++ stdlib (shared by both) ──────────────────────────────────────────
    if target_os == "windows" {
        println!("cargo:rustc-link-lib=static=stdc++");
        println!("cargo:rustc-link-lib=static=gcc");
        println!("cargo:rustc-link-lib=static=gcc_eh");
    } else {
        println!("cargo:rustc-link-lib=stdc++");
    }

    println!("cargo:rerun-if-changed=vendor/packjpg");
    println!("cargo:rerun-if-changed=vendor/packpng");
}
