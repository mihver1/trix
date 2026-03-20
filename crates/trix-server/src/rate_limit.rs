use std::{
    collections::{HashMap, VecDeque},
    sync::Arc,
    time::{Duration, Instant},
};

use tokio::sync::Mutex;

#[derive(Debug, Clone)]
pub struct RateLimitRule {
    pub window: Duration,
    pub limit: usize,
}

#[derive(Debug, Clone, Copy)]
pub struct RateLimitDecision {
    pub retry_after_seconds: u64,
}

#[derive(Debug, Default)]
pub struct RateLimiter {
    buckets: Arc<Mutex<HashMap<String, VecDeque<Instant>>>>,
}

impl RateLimiter {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn check(
        &self,
        scope: &str,
        key: impl AsRef<str>,
        rule: &RateLimitRule,
    ) -> Option<RateLimitDecision> {
        let now = Instant::now();
        let bucket_key = format!("{scope}:{}", key.as_ref());
        let mut buckets = self.buckets.lock().await;

        let bucket = buckets.entry(bucket_key).or_default();
        prune_bucket(bucket, now, rule.window);

        if bucket.len() >= rule.limit {
            let retry_after_seconds = bucket
                .front()
                .map(|oldest| {
                    let elapsed = now.saturating_duration_since(*oldest);
                    let remaining = rule.window.saturating_sub(elapsed);
                    remaining.as_secs().max(1)
                })
                .unwrap_or(1);
            return Some(RateLimitDecision {
                retry_after_seconds,
            });
        }

        bucket.push_back(now);
        None
    }
}

fn prune_bucket(bucket: &mut VecDeque<Instant>, now: Instant, window: Duration) {
    while let Some(oldest) = bucket.front().copied() {
        if now.saturating_duration_since(oldest) >= window {
            bucket.pop_front();
        } else {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::{RateLimitRule, RateLimiter};

    #[tokio::test]
    async fn rate_limiter_rejects_after_limit_is_reached() {
        let limiter = RateLimiter::new();
        let rule = RateLimitRule {
            window: Duration::from_secs(60),
            limit: 2,
        };

        assert!(limiter.check("auth", "device-1", &rule).await.is_none());
        assert!(limiter.check("auth", "device-1", &rule).await.is_none());
        assert!(limiter.check("auth", "device-1", &rule).await.is_some());
    }
}
