use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

fn routes_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/routes")
}

fn route_source(module: &str) -> String {
    let path = routes_dir().join(format!("{module}.rs"));
    fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", path.display()))
}

/// Collect the argument lists (as raw strings) of all `needle(...)` calls in `source`.
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

/// Split the top-level comma-separated arguments of an invocation.
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

/// Extract the first double-quoted string literal from `input`, if any.
fn first_string_literal(input: &str) -> Option<String> {
    let start = input.find('"')?;
    let rest = &input[start + 1..];
    let end = rest.find('"')?;
    Some(rest[..end].to_owned())
}

/// Return true if the expression uses `rel(` (a contract-based route path).
fn is_rel_call(expr: &str) -> bool {
    expr.contains("rel(")
}

/// Extract the module name from an expression like `foo::bar::router()`.
fn module_name(expr: &str) -> Option<String> {
    expr.trim()
        .strip_suffix("::router()")
        .map(str::trim)
        .map(ToOwned::to_owned)
}

/// Count the number of distinct HTTP methods in a handler expression.
fn count_http_methods(expr: &str) -> usize {
    let methods = [
        ("get(", "GET"),
        ("post(", "POST"),
        ("put(", "PUT"),
        ("patch(", "PATCH"),
        ("delete(", "DELETE"),
        ("head(", "HEAD"),
    ];
    let count = methods
        .iter()
        .filter(|(needle, _)| expr.contains(needle))
        .count();
    // Default to 1 if we can't determine (e.g. WebSocket upgrade uses `get`)
    count.max(1)
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

/// Counts of routes discovered by scanning source files.
struct RouteCounts {
    /// Total (path, method) pairs from `rel()`-based routes (contract routes).
    contract_method_pairs: usize,
    /// (absolute_path, method) pairs from string-literal routes (non-JSON routes).
    literal_routes: Vec<(String, String)>,
}

fn count_source_routes(module: &str, prefix: &str) -> RouteCounts {
    let source = route_source(module);
    let mut contract_method_pairs = 0usize;
    let mut literal_routes: Vec<(String, String)> = Vec::new();

    for route in collect_invocations(&source, ".route(") {
        let args = split_top_level_args(&route);
        let path_arg = args[0].as_str();
        let handler_arg = args.get(1).map(String::as_str).unwrap_or_default();

        if is_rel_call(path_arg) {
            // Contract-based route: just count (path, method) pairs
            contract_method_pairs += count_http_methods(handler_arg);
        } else if let Some(path_literal) = first_string_literal(path_arg) {
            // String-literal route: record with absolute path for verification
            let abs_path = join_paths(prefix, &path_literal);
            let methods: Vec<String> = [
                ("get(", "GET"),
                ("post(", "POST"),
                ("put(", "PUT"),
                ("patch(", "PATCH"),
                ("delete(", "DELETE"),
                ("head(", "HEAD"),
            ]
            .iter()
            .filter_map(|(needle, method)| {
                handler_arg.contains(needle).then(|| method.to_string())
            })
            .collect();

            if methods.is_empty() {
                // Fallback: count as one route with unknown method
                literal_routes.push((abs_path, "UNKNOWN".to_string()));
            } else {
                for method in methods {
                    literal_routes.push((abs_path.clone(), method));
                }
            }
        } else {
            panic!(
                "route() call in module `{module}` has unparseable path arg: {path_arg}"
            );
        }
    }

    // Recurse into nested modules.
    // Skip empty invocations which can arise from doc-comment matches like `.nest()`.
    for nest in collect_invocations(&source, ".nest(") {
        if nest.is_empty() {
            continue;
        }
        let args = split_top_level_args(&nest);
        let nested_prefix = join_paths(
            prefix,
            &first_string_literal(&args[0])
                .unwrap_or_else(|| panic!("nest invocation missing path literal: {nest}")),
        );
        let nested_module =
            module_name(args.get(1).map(String::as_str).unwrap_or_default())
                .unwrap_or_else(|| panic!("nest invocation missing module router(): {nest}"));
        let nested = count_source_routes(&nested_module, &nested_prefix);
        contract_method_pairs += nested.contract_method_pairs;
        literal_routes.extend(nested.literal_routes);
    }

    // Recurse into merged modules.
    // Skip empty invocations for the same reason as `.nest()`.
    for merge in collect_invocations(&source, ".merge(") {
        if merge.is_empty() {
            continue;
        }
        let args = split_top_level_args(&merge);
        let merged_module =
            module_name(args.first().map(String::as_str).unwrap_or_default())
                .unwrap_or_else(|| panic!("merge invocation missing module router(): {merge}"));
        let merged = count_source_routes(&merged_module, prefix);
        contract_method_pairs += merged.contract_method_pairs;
        literal_routes.extend(merged.literal_routes);
    }

    RouteCounts {
        contract_method_pairs,
        literal_routes,
    }
}

/// Scan all server route source files starting from `routes/mod.rs` under the `/v0` prefix,
/// and return a summary of all discovered routes.
fn server_route_counts() -> RouteCounts {
    count_source_routes("mod", "/v0")
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Verify that every server route is accounted for in the contract:
///
/// 1. The total (path, method) pairs found in source equals
///    `ALL_ENDPOINT_PATHS.len() + NON_JSON_PATHS.len()`.
/// 2. Every string-literal route found in source exists in `NON_JSON_PATHS`.
///
/// This catches:
/// - A new endpoint added to the server but not declared in the contract.
/// - A contract entry that has no corresponding server route.
/// - A non-JSON route (blob, WebSocket) that is missing from `NON_JSON_PATHS`.
#[test]
fn all_server_routes_have_contracts() {
    use trix_types::contract::{ALL_ENDPOINT_PATHS, NON_JSON_PATHS};

    let counts = server_route_counts();

    // Build a set of expected non-JSON (path, method) pairs from the contract.
    let non_json_set: BTreeSet<(String, String)> = NON_JSON_PATHS
        .iter()
        .map(|(path, method)| (path.to_string(), method.as_str().to_string()))
        .collect();

    // Verify every string-literal route is in NON_JSON_PATHS.
    for (path, method) in &counts.literal_routes {
        assert!(
            non_json_set.contains(&(path.clone(), method.clone())),
            "server route ({method} {path}) is not listed in NON_JSON_PATHS"
        );
    }

    // Verify all NON_JSON_PATHS entries are covered by string-literal routes.
    let literal_set: BTreeSet<(String, String)> =
        counts.literal_routes.iter().cloned().collect();
    for (path, method) in NON_JSON_PATHS {
        let key = (path.to_string(), method.as_str().to_string());
        assert!(
            literal_set.contains(&key),
            "NON_JSON_PATHS entry ({} {}) has no matching string-literal .route() in server source",
            method.as_str(),
            path
        );
    }

    // Verify total (path, method) pair count matches sum of both contract lists.
    let expected_total = ALL_ENDPOINT_PATHS.len() + NON_JSON_PATHS.len();
    let actual_total = counts.contract_method_pairs + counts.literal_routes.len();
    assert_eq!(
        actual_total,
        expected_total,
        "mismatch: server source has {actual_total} (path, method) pairs \
         but contract declares {expected_total} \
         ({} in ALL_ENDPOINT_PATHS + {} in NON_JSON_PATHS). \
         Add missing entries to the contract or remove extra routes.",
        ALL_ENDPOINT_PATHS.len(),
        NON_JSON_PATHS.len(),
    );
}

/// Verify that all `operationId` values in the OpenAPI YAML are unique.
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
