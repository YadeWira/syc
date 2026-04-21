fn main() {
    let src = [
        "vendor/packjpg/aricoder.cpp",
        "vendor/packjpg/bitops.cpp",
        "vendor/packjpg/packjpg.cpp",
    ];

    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    let mut build = cc::Build::new();
    build
        .cpp(true)
        .std("c++17")
        .opt_level(3)
        .flag_if_supported("-funroll-loops")
        .flag_if_supported("-ffast-math")
        .flag_if_supported("-fomit-frame-pointer")
        .flag_if_supported("-Wall")
        .define("BUILD_LIB", None)
        // Suppress automatic -lstdc++ so we can control static vs dynamic below.
        .cpp_link_stdlib(None);

    if target_os != "windows" {
        build.define("UNIX", None);
    }

    build.files(src).compile("packjpg");

    // Link the C++ stdlib explicitly.  On Windows-GNU we force static so the
    // binary has no dependency on libstdc++-6.dll or libgcc_s_seh-1.dll.
    if target_os == "windows" {
        println!("cargo:rustc-link-lib=static=stdc++");
        println!("cargo:rustc-link-lib=static=gcc");
        println!("cargo:rustc-link-lib=static=gcc_eh");
    } else {
        println!("cargo:rustc-link-lib=stdc++");
    }

    println!("cargo:rerun-if-changed=vendor/packjpg");
}
