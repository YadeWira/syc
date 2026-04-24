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

    ppg_build.file("vendor/packpng/packpng.cpp").compile("packpng");

    // Link zlib and liblzma (packPNG runtime deps).
    if target_os == "windows" {
        println!("cargo:rustc-link-lib=static=z");
        println!("cargo:rustc-link-lib=static=lzma");
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
