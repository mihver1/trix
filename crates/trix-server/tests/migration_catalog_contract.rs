use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

fn migrations_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../migrations")
}

#[test]
fn sqlx_migration_versions_are_unique() {
    let migrations_dir = migrations_dir();
    let mut versions = BTreeMap::<u64, Vec<String>>::new();

    for entry in fs::read_dir(&migrations_dir)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", migrations_dir.display()))
    {
        let entry = entry.unwrap_or_else(|err| panic!("failed to read dir entry: {err}"));
        let path = entry.path();

        if path.extension().and_then(|ext| ext.to_str()) != Some("sql") {
            continue;
        }

        let file_name = path
            .file_name()
            .unwrap_or_else(|| panic!("missing file name for {}", path.display()))
            .to_string_lossy()
            .into_owned();
        let (version, _) = file_name.split_once('_').unwrap_or_else(|| {
            panic!("migration file {file_name} is missing the <version>_ prefix")
        });
        let version = version.parse::<u64>().unwrap_or_else(|err| {
            panic!("migration file {file_name} has invalid version {version}: {err}")
        });

        versions.entry(version).or_default().push(file_name);
    }

    let duplicates = versions
        .into_iter()
        .filter_map(|(version, mut files)| {
            if files.len() == 1 {
                return None;
            }
            files.sort();
            Some(format!("version {version}: {}", files.join(", ")))
        })
        .collect::<Vec<_>>();

    assert!(
        duplicates.is_empty(),
        "duplicate SQLx migration versions found:\n{}",
        duplicates.join("\n")
    );
}
