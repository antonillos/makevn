use serde_json::json;

#[test]
fn diagram_is_extracted_only_for_the_explicit_preview_option() {
    let line = "MAKEVN_PR_DIAGRAM_JSON={\"format\":\"mermaid\",\"markdown\":\"```mermaid\\nflowchart LR\\n```\"}";
    let output = format!("Preview\n{line}\nDiagnostic");
    let params = json!({"arguments":{"diagram":true}});
    let (text, diagram) = super::extract(output.clone(), "verify_changes_preview", &params);
    assert_eq!(text, "Preview\nDiagnostic");
    assert_eq!(diagram.unwrap()["format"], "mermaid");
    assert_eq!(super::extract(output.clone(), "test", &params), (output.clone(), None));
    assert_eq!(super::extract(output.clone(), "verify_changes_preview", &json!({})), (output, None));
}

#[test]
fn malformed_or_unrecognized_payloads_are_preserved_as_output() {
    for value in ["invalid", "{}", "{\"format\":\"dot\",\"markdown\":\"x\"}", "{\"format\":\"mermaid\"}"] {
        let output = format!("MAKEVN_PR_DIAGRAM_JSON={value}");
        assert_eq!(super::extract(output.clone(), "verify_changes_preview", &json!({"arguments":{"diagram":true}})),
                   (output, None));
    }
}
