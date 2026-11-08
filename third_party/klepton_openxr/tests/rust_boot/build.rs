fn main() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../build");
    println!("cargo:rustc-link-search=native={}", dir.display());
    println!("cargo:rustc-link-lib=static=klepton-openxr-macos");
    println!("cargo:rerun-if-changed={}", dir.join("libklepton-openxr-macos.a").display());
}
