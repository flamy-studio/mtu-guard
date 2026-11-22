fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=Cargo.toml");
    println!("cargo:rerun-if-changed=favicon.ico");
    println!("cargo:rerun-if-changed=app.manifest");

    // Check the target, not the host, so cross-compilation keeps Windows resources.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }

    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc") {
        let features = std::env::var("CARGO_CFG_TARGET_FEATURE").unwrap_or_default();
        assert!(
            features.split(',').any(|feature| feature == "crt-static"),
            "MTU Guard requires static CRT; keep .cargo/config.toml and do not override +crt-static"
        );
    }

    // https://docs.rs/winresource/latest/winresource/struct.WindowsResource.html
    winresource::WindowsResource::new()
        .set_language(0x0409)
        .set_icon("favicon.ico")
        .set_manifest_file("app.manifest")
        .set(
            "FileDescription",
            "MTU Guard - IPv4 MTU service for Withen Network",
        )
        .set("ProductName", "MTU Guard")
        .set("CompanyName", "Flamy Studio")
        .set("LegalCopyright", "Copyright (c) 2026 Flamy Studio")
        .set("InternalName", "withen-mtu-guard")
        .set("OriginalFilename", "withen-mtu-guard.exe")
        .set("FileVersion", env!("CARGO_PKG_VERSION"))
        .set("ProductVersion", env!("CARGO_PKG_VERSION"))
        .compile()
        .expect("failed to compile MTU Guard resources; install MSVC Build Tools and Windows SDK");
}
