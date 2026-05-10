use std::env;

fn main() {
    println!("cargo:rerun-if-env-changed=MAKEVN_BUILD_VERSION");
    if let Ok(version) = env::var("MAKEVN_BUILD_VERSION") {
        println!("cargo:rustc-env=MAKEVN_BUILD_VERSION={version}");
    }
}
