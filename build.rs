fn main() {
    let src = [
        "vendor/packjpg/aricoder.cpp",
        "vendor/packjpg/bitops.cpp",
        "vendor/packjpg/packjpg.cpp",
    ];

    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .opt_level(3)
        .flag_if_supported("-funroll-loops")
        .flag_if_supported("-ffast-math")
        .flag_if_supported("-fomit-frame-pointer")
        .flag_if_supported("-Wall")
        .define("BUILD_LIB", None)
        .define("UNIX", None)
        .files(src)
        .compile("packjpg");

    println!("cargo:rerun-if-changed=vendor/packjpg");
}
