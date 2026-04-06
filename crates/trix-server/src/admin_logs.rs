use std::{
    collections::VecDeque,
    fmt,
    sync::{Mutex, MutexGuard},
    time::{SystemTime, UNIX_EPOCH},
};

use serde_json::{Map, Number, Value};
use tracing::{
    Event, Level, Subscriber,
    field::{Field, Visit},
};
use tracing_subscriber::{Layer, layer::Context};
use trix_types::{AdminServerLogEntry, AdminServerLogLevel, AdminServerLogListResponse};

const DEFAULT_LOG_CAPACITY: usize = 2_000;

#[derive(Default)]
struct LogBufferState {
    next_entry_id: u64,
    dropped_entries: u64,
    entries: VecDeque<AdminServerLogEntry>,
}

pub struct AdminLogBuffer {
    capacity: usize,
    inner: Mutex<LogBufferState>,
}

impl Default for AdminLogBuffer {
    fn default() -> Self {
        Self::new(DEFAULT_LOG_CAPACITY)
    }
}

impl AdminLogBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(1),
            inner: Mutex::new(LogBufferState::default()),
        }
    }

    pub fn snapshot(&self, limit: usize) -> AdminServerLogListResponse {
        let state = self.lock();
        let entries = state.entries.iter().rev().take(limit).cloned().collect();
        AdminServerLogListResponse {
            entries,
            dropped_entries: state.dropped_entries,
        }
    }

    fn push_captured_event(
        &self,
        level: AdminServerLogLevel,
        target: String,
        module_path: Option<String>,
        file: Option<String>,
        line: Option<u32>,
        message: String,
        fields: Map<String, Value>,
    ) {
        let recorded_at_unix_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let rendered = render_message(&message, &fields);
        let mut state = self.lock();
        let entry_id = state.next_entry_id;
        state.next_entry_id = state.next_entry_id.saturating_add(1);
        state.entries.push_back(AdminServerLogEntry {
            entry_id,
            recorded_at_unix_ms,
            level,
            target,
            module_path,
            file,
            line,
            message,
            fields: Value::Object(fields),
            rendered,
        });
        if state.entries.len() > self.capacity {
            state.entries.pop_front();
            state.dropped_entries = state.dropped_entries.saturating_add(1);
        }
    }

    fn lock(&self) -> MutexGuard<'_, LogBufferState> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[derive(Clone)]
pub struct AdminLogLayer {
    buffer: std::sync::Arc<AdminLogBuffer>,
}

impl AdminLogLayer {
    pub fn new(buffer: std::sync::Arc<AdminLogBuffer>) -> Self {
        Self { buffer }
    }
}

impl<S> Layer<S> for AdminLogLayer
where
    S: Subscriber,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let metadata = event.metadata();
        let mut visitor = JsonFieldVisitor::default();
        event.record(&mut visitor);
        let message = visitor
            .fields
            .remove("message")
            .and_then(|value| match value {
                Value::String(text) => Some(text),
                other => Some(json_value_inline(&other)),
            })
            .unwrap_or_else(|| metadata.name().to_owned());

        self.buffer.push_captured_event(
            map_level(*metadata.level()),
            metadata.target().to_owned(),
            metadata.module_path().map(str::to_owned),
            metadata.file().map(str::to_owned),
            metadata.line(),
            message,
            visitor.fields,
        );
    }
}

#[derive(Default)]
struct JsonFieldVisitor {
    fields: Map<String, Value>,
}

impl JsonFieldVisitor {
    fn insert(&mut self, field: &Field, value: Value) {
        self.fields.insert(field.name().to_owned(), value);
    }
}

impl Visit for JsonFieldVisitor {
    fn record_bool(&mut self, field: &Field, value: bool) {
        self.insert(field, Value::Bool(value));
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        self.insert(field, Value::Number(Number::from(value)));
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.insert(field, Value::Number(Number::from(value)));
    }

    fn record_f64(&mut self, field: &Field, value: f64) {
        let rendered = Number::from_f64(value)
            .map(Value::Number)
            .unwrap_or_else(|| Value::String(value.to_string()));
        self.insert(field, rendered);
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        self.insert(field, Value::String(value.to_owned()));
    }

    fn record_error(&mut self, field: &Field, value: &(dyn std::error::Error + 'static)) {
        self.insert(field, Value::String(value.to_string()));
    }

    fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
        self.insert(field, Value::String(format!("{value:?}")));
    }
}

fn map_level(level: Level) -> AdminServerLogLevel {
    match level {
        Level::TRACE => AdminServerLogLevel::Trace,
        Level::DEBUG => AdminServerLogLevel::Debug,
        Level::INFO => AdminServerLogLevel::Info,
        Level::WARN => AdminServerLogLevel::Warn,
        Level::ERROR => AdminServerLogLevel::Error,
    }
}

fn render_message(message: &str, fields: &Map<String, Value>) -> String {
    if fields.is_empty() {
        return message.to_owned();
    }
    let suffix = fields
        .iter()
        .map(|(key, value)| format!("{key}={}", json_value_inline(value)))
        .collect::<Vec<_>>()
        .join(" ");
    format!("{message} {suffix}")
}

fn json_value_inline(value: &Value) -> String {
    match value {
        Value::Null => "null".to_owned(),
        Value::Bool(flag) => flag.to_string(),
        Value::Number(number) => number.to_string(),
        Value::String(text) => text.clone(),
        Value::Array(_) | Value::Object(_) => value.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use tracing::{info, subscriber::with_default};
    use tracing_subscriber::{EnvFilter, layer::SubscriberExt};

    use super::{AdminLogBuffer, AdminLogLayer};

    #[test]
    fn snapshot_returns_newest_entries_first_and_tracks_drops() {
        let buffer = AdminLogBuffer::new(2);
        buffer.push_captured_event(
            trix_types::AdminServerLogLevel::Info,
            "test".to_owned(),
            None,
            None,
            None,
            "first".to_owned(),
            serde_json::Map::new(),
        );
        buffer.push_captured_event(
            trix_types::AdminServerLogLevel::Info,
            "test".to_owned(),
            None,
            None,
            None,
            "second".to_owned(),
            serde_json::Map::new(),
        );
        buffer.push_captured_event(
            trix_types::AdminServerLogLevel::Info,
            "test".to_owned(),
            None,
            None,
            None,
            "third".to_owned(),
            serde_json::Map::new(),
        );

        let snapshot = buffer.snapshot(10);
        assert_eq!(snapshot.dropped_entries, 1);
        assert_eq!(snapshot.entries.len(), 2);
        assert_eq!(snapshot.entries[0].message, "third");
        assert_eq!(snapshot.entries[1].message, "second");
    }

    #[test]
    fn layer_captures_message_and_fields() {
        let buffer = Arc::new(AdminLogBuffer::new(8));
        let subscriber = tracing_subscriber::registry()
            .with(EnvFilter::new("info"))
            .with(AdminLogLayer::new(buffer.clone()));

        with_default(subscriber, || {
            info!(target: "admin_logs_test", request_id = 42_u64, "hello world");
        });

        let snapshot = buffer.snapshot(5);
        assert_eq!(snapshot.entries.len(), 1);
        let entry = &snapshot.entries[0];
        assert_eq!(entry.target, "admin_logs_test");
        assert_eq!(entry.message, "hello world");
        assert_eq!(entry.fields["request_id"], serde_json::json!(42));
    }
}
