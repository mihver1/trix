use axum::{Json, extract::State};

use crate::state::AppState;
use trix_types::{HealthResponse, ServiceStatus, VersionResponse};

pub async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    let db_ok = state.db.ping().await.is_ok();
    let blob_ok = state.blob_store.root().exists();
    let status = if db_ok && blob_ok {
        ServiceStatus::Ok
    } else {
        ServiceStatus::Degraded
    };

    Json(HealthResponse {
        service: state.build.service.to_owned(),
        status,
        version: state.build.version.to_owned(),
        uptime_ms: state.started_at.elapsed().as_millis() as u64,
    })
}

pub async fn version(State(state): State<AppState>) -> Json<VersionResponse> {
    Json(VersionResponse {
        service: state.build.service.to_owned(),
        version: state.build.version.to_owned(),
        git_sha: state.build.git_sha.map(str::to_owned),
    })
}
