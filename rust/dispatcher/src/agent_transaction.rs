//! Reversible file replacement for agent configuration and managed skills.
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

pub type Changes = BTreeMap<PathBuf, Option<Vec<u8>>>;

pub fn read(path: &Path) -> Result<Option<Vec<u8>>, String> {
    match fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("Cannot read {}: {error}", path.display())),
    }
}

pub fn reject_links(path: &Path) -> Result<(), String> {
    for ancestor in path.ancestors() {
        if fs::symlink_metadata(ancestor).is_ok_and(|meta| meta.file_type().is_symlink()) {
            return Err(format!(
                "Refusing symlink in managed path: {}",
                ancestor.display()
            ));
        }
    }
    Ok(())
}

struct Transaction {
    created_dirs: Vec<PathBuf>,
    replaced: Changes,
    staged: Vec<PathBuf>,
}

impl Transaction {
    fn create_parent(&mut self, path: &Path) -> Result<(), String> {
        let parent = path.parent().ok_or("Missing parent directory")?;
        if parent.is_dir() {
            return Ok(());
        }
        self.create_parent(parent)?;
        fs::create_dir(parent).map_err(|e| format!("Cannot create {}: {e}", parent.display()))?;
        self.created_dirs.push(parent.to_path_buf());
        Ok(())
    }

    fn stage(&mut self, path: &Path, bytes: &[u8]) -> Result<PathBuf, String> {
        self.create_parent(path)?;
        let temp = path.with_file_name(format!(
            ".makevn-stage-{}-{}",
            std::process::id(),
            self.staged.len()
        ));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .map_err(|e| format!("Cannot stage {}: {e}", path.display()))?;
        self.staged.push(temp.clone());
        file.write_all(bytes).map_err(|e| e.to_string())?;
        if let Ok(metadata) = fs::metadata(path) {
            fs::set_permissions(&temp, metadata.permissions()).map_err(|e| e.to_string())?;
        }
        Ok(temp)
    }

    fn commit(
        &mut self,
        prepared: Vec<(PathBuf, Option<Vec<u8>>, Option<PathBuf>)>,
    ) -> Result<(), String> {
        for (path, original, staged) in prepared {
            let result = match staged {
                Some(temp) => fs::rename(temp, &path),
                None => fs::remove_file(&path),
            };
            if let Err(error) = result {
                let recovery = self.restore();
                return Err(format!(
                    "Cannot replace {}: {error}; rollback errors: {recovery:?}",
                    path.display()
                ));
            }
            self.replaced.insert(path, original);
        }
        Ok(())
    }

    fn restore(&mut self) -> Vec<String> {
        let mut errors = Vec::new();
        for (path, bytes) in &self.replaced {
            let result = match bytes {
                Some(bytes) => fs::write(path, bytes),
                None => fs::remove_file(path),
            };
            if let Err(e) = result {
                errors.push(format!("{}: {e}", path.display()));
            }
        }
        errors
    }
}

impl Drop for Transaction {
    fn drop(&mut self) {
        for path in &self.staged {
            let _ = fs::remove_file(path);
        }
        for dir in self.created_dirs.iter().rev() {
            let _ = fs::remove_dir(dir);
        }
    }
}

pub fn apply(changes: Changes) -> Result<(), String> {
    let mut transaction = Transaction {
        created_dirs: vec![],
        replaced: Changes::new(),
        staged: vec![],
    };
    let mut prepared = Vec::new();
    for (path, bytes) in changes {
        reject_links(&path)?;
        let original = read(&path)?;
        if original == bytes {
            continue;
        }
        let staged = bytes
            .map(|bytes| transaction.stage(&path, &bytes))
            .transpose()?;
        prepared.push((path, original, staged));
    }
    transaction.commit(prepared)
}

#[cfg(test)]
#[path = "agent_transaction_test.rs"]
mod tests;
