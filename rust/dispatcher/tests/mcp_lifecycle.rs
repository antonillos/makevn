use std::path::Path;
use std::process::Command;

#[test]
fn real_stdio_execution_lifecycle() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/smoke/execution_mcp_test.py");
    let status = Command::new("python3")
        .arg(root)
        .arg(env!("CARGO_BIN_EXE_makevn-mcp"))
        .status()
        .expect("launch MCP lifecycle integration tests");
    assert!(status.success());
}
