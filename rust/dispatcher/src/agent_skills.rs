//! Inventory and ownership of the portable workflow skill bundle.
use crate::agent_transaction::error_text;
use crate::agent_transaction::{self, Changes};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

pub const NAMES: [&str; 5] = [
    "makevn",
    "makevn-test",
    "makevn-docker",
    "makevn-karate",
    "makevn-quality",
];
const MANIFEST: &str = ".makevn-skills.json";
type Inventory = BTreeMap<String, Vec<u8>>;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    schema: u32,
    version: String,
    files: BTreeMap<String, String>,
}

fn collect(root: &Path, dir: &Path, files: &mut Inventory) -> Result<(), String> {
    agent_transaction::reject_links(dir)?;
    for entry in fs::read_dir(dir).map_err(|e| format!("Cannot inspect {}: {e}", dir.display()))? {
        collect_entry(root, entry.map_err(error_text)?, files)?;
    }
    Ok(())
}

fn collect_entry(root: &Path, entry: fs::DirEntry, files: &mut Inventory) -> Result<(), String> {
    let path = entry.path();
    let ty = entry.file_type().map_err(error_text)?;
    if ty.is_dir() {
        collect(root, &path, files)?;
    } else if ty.is_file() {
        let (name, bytes) = read_resource(root, &path)?;
        files.insert(name, bytes);
    } else {
        return Err(format!("Unsupported skill resource: {}", path.display()));
    }
    Ok(())
}

fn read_resource(root: &Path, path: &Path) -> Result<(String, Vec<u8>), String> {
    let relative = path.strip_prefix(root).map_err(error_text)?;
    let name = relative.to_str().ok_or("Skill paths must be UTF-8")?;
    let bytes = fs::read(path).map_err(error_text)?;
    Ok((name.to_owned(), bytes))
}

fn inventory(root: &Path, required: bool) -> Result<Inventory, String> {
    let mut files = Inventory::new();
    for name in NAMES {
        inspect_skill(root, name, required, &mut files)?;
    }
    Ok(files)
}

fn inspect_skill(
    root: &Path,
    name: &str,
    required: bool,
    files: &mut Inventory,
) -> Result<(), String> {
    let dir = root.join(name);
    agent_transaction::reject_links(&dir)?;
    if !dir.exists() && !required {
        return Ok(());
    }
    collect(root, &dir, files)?;
    if required {
        validate_metadata(files, name)?;
    }
    Ok(())
}

fn validate_metadata(files: &Inventory, name: &str) -> Result<(), String> {
    let key = format!("{name}/SKILL.md");
    let text = files.get(&key).ok_or_else(|| format!("Missing {key}"))?;
    let text = std::str::from_utf8(text).map_err(error_text)?;
    if !text.starts_with(&format!("---\nname: {name}\n")) || !text.contains("\ndescription:") {
        return Err(format!("Invalid skill metadata: {key}"));
    }
    Ok(())
}

fn reject_unmanaged_directories(target: &Path) -> Result<(), String> {
    for name in NAMES {
        if target.join(name).exists() {
            return Err(format!(
                "Unmanaged skill directory: {}",
                target.join(name).display()
            ));
        }
    }
    Ok(())
}

fn hashes(files: &Inventory) -> BTreeMap<String, String> {
    files
        .iter()
        .map(|(name, bytes)| {
            (
                name.clone(),
                Sha256::digest(bytes)
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect(),
            )
        })
        .collect()
}

fn manifest(root: &Path) -> Result<Option<Manifest>, String> {
    agent_transaction::reject_links(&root.join(MANIFEST))?;
    agent_transaction::read(&root.join(MANIFEST))?
        .map(|bytes| {
            let manifest: Manifest = serde_json::from_slice(&bytes)
                .map_err(|e| format!("Invalid ownership manifest: {e}"))?;
            if manifest.schema != 1 {
                return Err("Unsupported skill manifest schema".into());
            }
            Ok(manifest)
        })
        .transpose()
}

fn validate_owned(
    root: &Path,
    current: &Inventory,
    owner: Option<&Manifest>,
) -> Result<(), String> {
    let actual = hashes(current);
    let expected = owner.map(|owner| &owner.files).cloned().unwrap_or_default();
    if actual == expected {
        return Ok(());
    }
    let paths: Vec<_> = actual
        .keys()
        .chain(expected.keys())
        .filter(|key| actual.get(*key) != expected.get(*key))
        .map(|key| root.join(key).display().to_string())
        .collect();
    Err(format!(
        "Unmanaged or locally modified skills; no files changed: {}",
        paths.join(", ")
    ))
}

pub fn prepare(source: &Path, target: &Path, version: &str) -> Result<Changes, String> {
    let desired = inventory(source, true)?;
    let current = inventory(target, false)?;
    let owner = manifest(target)?;
    validate_owned(target, &current, owner.as_ref())?;
    // Empty directories without a manifest are also user-owned.
    if owner.is_none() {
        reject_unmanaged_directories(target)?;
    }
    build_changes(target, current, desired, version)
}

fn build_changes(
    target: &Path,
    current: Inventory,
    desired: Inventory,
    version: &str,
) -> Result<Changes, String> {
    let mut changes = Changes::new();
    for name in current.keys() {
        changes.insert(target.join(name), None);
    }
    let owner = Manifest {
        schema: 1,
        version: version.into(),
        files: hashes(&desired),
    };
    for (name, bytes) in desired {
        changes.insert(target.join(name), Some(bytes));
    }
    changes.insert(
        target.join(MANIFEST),
        Some(serde_json::to_vec_pretty(&owner).map_err(error_text)?),
    );
    Ok(changes)
}

pub fn status(source: &Path, target: &Path, version: &str) -> String {
    match inspect(source, target, version) {
        Ok(status) => status,
        Err(error) => format!("conflict: {error}"),
    }
}

fn inspect(source: &Path, target: &Path, version: &str) -> Result<String, String> {
    let desired = inventory(source, true)?;
    let current = inventory(target, false)?;
    let owner = manifest(target)?;
    validate_owned(target, &current, owner.as_ref())?;
    let Some(owner) = owner else {
        reject_unmanaged_directories(target)?;
        return Ok("absent".into());
    };
    Ok(describe_registration(&owner, &desired, version))
}

fn describe_registration(owner: &Manifest, desired: &Inventory, version: &str) -> String {
    if owner.version != version || owner.files != hashes(desired) {
        return format!("outdated (registered {})", owner.version);
    }
    "current (five skills; client loading unverified)".into()
}

pub fn source(root: &Path) -> PathBuf {
    root.join("share/makevn/skills")
}

#[cfg(test)]
#[path = "agent_skills_test.rs"]
mod tests;
