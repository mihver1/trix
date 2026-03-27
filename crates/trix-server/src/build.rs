#[derive(Debug, Clone)]
pub struct BuildInfo {
    pub service: &'static str,
    pub version: &'static str,
    pub git_sha: Option<&'static str>,
}

impl BuildInfo {
    pub fn current() -> Self {
        Self {
            service: env!("CARGO_PKG_NAME"),
            version: env!("CARGO_PKG_VERSION"),
            git_sha: option_env!("TRIX_GIT_SHA"),
        }
    }
}
