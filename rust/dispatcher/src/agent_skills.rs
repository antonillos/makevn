//! Inventory and ownership of the portable workflow skill bundle.
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
        let entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path();
        let ty = entry.file_type().map_err(|e| e.to_string())?;
        if ty.is_dir() {
            collect(root, &path, files)?;
        } else if ty.is_file() {
            let relative = path.strip_prefix(root).map_err(|e| e.to_string())?;
            let name = relative.to_str().ok_or("Skill paths must be UTF-8")?;
            files.insert(name.to_owned(), fs::read(&path).map_err(|e| e.to_string())?);
        } else {
            return Err(format!("Unsupported skill resource: {}", path.display()));
        }
    }
    Ok(())
}

fn inventory(root: &Path, required: bool) -> Result<Inventory, String> {
    let mut files = Inventory::new();
    for name in NAMES {
        let dir = root.join(name);
        agent_transaction::reject_links(&dir)?;
        if !dir.exists() && !required {
            continue;
        }
        collect(root, &dir, &mut files)?;
        if required {
            let key = format!("{name}/SKILL.md");
            let text = files.get(&key).ok_or_else(|| format!("Missing {key}"))?;
            let text = std::str::from_utf8(text).map_err(|e| e.to_string())?;
            if !text.starts_with(&format!("---\nname: {name}\n"))
                || !text.contains("\ndescription:")
            {
                return Err(format!("Invalid skill metadata: {key}"));
            }
        }
    }
    Ok(files)
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
        for name in NAMES {
            if target.join(name).exists() {
                return Err(format!(
                    "Unmanaged skill directory: {}",
                    target.join(name).display()
                ));
            }
        }
    }
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
        Some(serde_json::to_vec_pretty(&owner).map_err(|e| e.to_string())?),
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
        for name in NAMES {
            if target.join(name).exists() {
                return Err(format!(
                    "Unmanaged skill directory: {}",
                    target.join(name).display()
                ));
            }
        }
        return Ok("absent".into());
    };
    if owner.version != version || owner.files != hashes(&desired) {
        return Ok(format!("outdated (registered {})", owner.version));
    }
    Ok("current (five skills; client loading unverified)".into())
}

pub fn source(root: &Path) -> PathBuf {
    root.join("share/makevn/skills")
}

#[cfg(test)]
#[path = "agent_skills_test.rs"]
mod tests;
