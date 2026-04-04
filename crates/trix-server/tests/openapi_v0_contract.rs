use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::PathBuf;

fn openapi_path_methods() -> BTreeMap<String, BTreeSet<String>> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../openapi/v0.yaml");
    let yaml = fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", path.display()));

    let mut in_paths = false;
    let mut current_path: Option<String> = None;
    let mut out = BTreeMap::<String, BTreeSet<String>>::new();

    for line in yaml.lines() {
        if !in_paths {
            if line.trim() == "paths:" {
                in_paths = true;
            }
            continue;
        }

        if !line.starts_with(' ') && !line.trim().is_empty() {
            break;
        }

        if let Some(path) = line
            .strip_prefix("  ")
            .and_then(|value| value.strip_suffix(':'))
            .filter(|value| value.starts_with('/'))
        {
            current_path = Some(path.to_owned());
            out.entry(path.to_owned()).or_default();
            continue;
        }

        if let Some(method) = line
            .strip_prefix("    ")
            .and_then(|value| value.strip_suffix(':'))
            .filter(|value| matches!(*value, "get" | "post" | "put" | "patch" | "delete" | "head"))
        {
            let path = current_path
                .as_ref()
                .unwrap_or_else(|| panic!("method {method} appeared before any path"));
            out.entry(path.clone())
                .or_default()
                .insert(method.to_ascii_uppercase());
        }
    }

    out
}

fn routes_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/routes")
}

fn route_source(module: &str) -> String {
    let path = routes_dir().join(format!("{module}.rs"));
    fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", path.display()))
}

fn collect_invocations(source: &str, needle: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut offset = 0usize;

    while let Some(found) = source[offset..].find(needle) {
        let start = offset + found + needle.len();
        let mut depth = 1i32;
        let mut end = start;

        for (relative_index, ch) in source[start..].char_indices() {
            match ch {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth == 0 {
                        end = start + relative_index;
                        break;
                    }
                }
                _ => {}
            }
        }

        assert!(depth == 0, "unterminated invocation for {needle}");
        out.push(source[start..end].trim().to_owned());
        offset = end + 1;
    }

    out
}

fn split_top_level_args(invocation: &str) -> Vec<String> {
    let mut args = Vec::new();
    let mut depth = 0i32;
    let mut start = 0usize;

    for (index, ch) in invocation.char_indices() {
        match ch {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            ',' if depth == 0 => {
                args.push(invocation[start..index].trim().to_owned());
                start = index + 1;
            }
            _ => {}
        }
    }

    args.push(invocation[start..].trim().to_owned());
    args
}

fn first_string_literal(input: &str) -> Option<String> {
    let start = input.find('"')?;
    let rest = &input[start + 1..];
    let end = rest.find('"')?;
    Some(rest[..end].to_owned())
}

fn module_name(expr: &str) -> Option<String> {
    expr.trim()
        .strip_suffix("::router()")
        .map(str::trim)
        .map(ToOwned::to_owned)
}

fn http_methods(expr: &str) -> BTreeSet<String> {
    [
        ("get(", "GET"),
        ("post(", "POST"),
        ("put(", "PUT"),
        ("patch(", "PATCH"),
        ("delete(", "DELETE"),
        ("head(", "HEAD"),
    ]
    .into_iter()
    .filter_map(|(needle, method)| expr.contains(needle).then(|| method.to_owned()))
    .collect()
}

fn join_paths(prefix: &str, path: &str) -> String {
    if prefix.is_empty() {
        return path.to_owned();
    }
    if path == "/" {
        return prefix.to_owned();
    }
    format!("{}{}", prefix.trim_end_matches('/'), path)
}

fn merge_path_methods(
    target: &mut BTreeMap<String, BTreeSet<String>>,
    source: BTreeMap<String, BTreeSet<String>>,
) {
    for (path, methods) in source {
        target.entry(path).or_default().extend(methods);
    }
}

fn source_route_path_methods(module: &str, prefix: &str) -> BTreeMap<String, BTreeSet<String>> {
    let source = route_source(module);
    let mut out = BTreeMap::<String, BTreeSet<String>>::new();

    for route in collect_invocations(&source, ".route(") {
        let args = split_top_level_args(&route);
        let route_path = first_string_literal(&args[0])
            .unwrap_or_else(|| panic!("route invocation missing path literal: {route}"));
        let methods = http_methods(args.get(1).map(String::as_str).unwrap_or_default());
        out.entry(join_paths(prefix, &route_path))
            .or_default()
            .extend(methods);
    }

    for nest in collect_invocations(&source, ".nest(") {
        let args = split_top_level_args(&nest);
        let nested_prefix = join_paths(
            prefix,
            &first_string_literal(&args[0])
                .unwrap_or_else(|| panic!("nest invocation missing path literal: {nest}")),
        );
        let nested_module = module_name(args.get(1).map(String::as_str).unwrap_or_default())
            .unwrap_or_else(|| panic!("nest invocation missing module router(): {nest}"));
        merge_path_methods(
            &mut out,
            source_route_path_methods(&nested_module, &nested_prefix),
        );
    }

    for merge in collect_invocations(&source, ".merge(") {
        let args = split_top_level_args(&merge);
        let merged_module = module_name(args.first().map(String::as_str).unwrap_or_default())
            .unwrap_or_else(|| panic!("merge invocation missing module router(): {merge}"));
        merge_path_methods(&mut out, source_route_path_methods(&merged_module, prefix));
    }

    out
}

fn server_route_path_methods() -> BTreeMap<String, BTreeSet<String>> {
    source_route_path_methods("mod", "/v0")
}

#[test]
fn documented_v0_paths_and_methods_match_contract_catalog() {
    assert_eq!(openapi_path_methods(), server_route_path_methods());
}

#[test]
fn documented_v0_operation_ids_are_unique() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../openapi/v0.yaml");
    let yaml = fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", path.display()));

    let mut seen = BTreeSet::new();
    for operation_id in yaml
        .lines()
        .filter_map(|line| line.trim().strip_prefix("operationId: "))
    {
        assert!(
            seen.insert(operation_id.to_owned()),
            "duplicate operationId found in openapi/v0.yaml: {operation_id}"
        );
    }
}
