use serde_json::Value;

const PREFIX: &str = "MAKEVN_PR_DIAGRAM_JSON=";

fn payload(line: &str) -> Option<Value> {
    let value: Value = serde_json::from_str(line.strip_prefix(PREFIX)?).ok()?;
    if value["format"].as_str() != Some("mermaid") {
        return None;
    }
    value["markdown"].as_str()?;
    Some(value)
}

pub(crate) fn extract(output: String, tool: &str, params: &Value) -> (String, Option<Value>) {
    if tool != "verify_changes_preview" || params["arguments"]["diagram"] != true {
        return (output, None);
    }
    let mut diagram = None;
    let lines: Vec<&str> = output.lines().filter(|line| {
        if let Some(value) = payload(line) {
            diagram = Some(value);
            false
        } else {
            true
        }
    }).collect();
    (lines.join("\n"), diagram)
}

pub(crate) fn attach(structured: &mut Value, diagram: Option<Value>) {
    if let Some(diagram) = diagram {
        structured["untrustedData"]["diagram"] = diagram;
    }
}

#[cfg(test)]
#[path = "mcp_diagram_test.rs"]
mod tests;
