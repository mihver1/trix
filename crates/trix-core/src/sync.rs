#[derive(Debug, Clone)]
pub enum CoreEvent {
    Started,
    Stopped,
    SyncTick,
}

pub trait CoreEventSink: Send + Sync + 'static {
    fn publish(&self, event: CoreEvent);
}

#[derive(Debug, Default)]
pub struct SyncCoordinator;

impl SyncCoordinator {
    pub fn new() -> Self {
        Self
    }
}
