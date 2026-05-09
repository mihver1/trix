use std::sync::Arc;

use anyhow::Result;
use futures_util::stream::{self, StreamExt};
use tracing::warn;
use trix_push::{
    ApnsDeliveryOutcome, ApnsPushClient, ApnsPushConfig, ApnsPushTarget, TrixApnsWakePayload,
};
use uuid::Uuid;

use crate::{
    config::AppConfig,
    db::{Database, DeviceApnsRegistrationRow},
};

#[derive(Clone, Default)]
pub struct PushNotificationService {
    apns: Option<Arc<ApnsPushClient>>,
}

impl PushNotificationService {
    pub fn from_config(config: &AppConfig) -> Result<Self> {
        let apns = match (
            config.apns_team_id.as_deref(),
            config.apns_key_id.as_deref(),
            config.apns_topic.as_deref(),
            config.apns_private_key_pem.as_deref(),
        ) {
            (Some(team_id), Some(key_id), Some(topic), Some(private_key_pem)) => Some(Arc::new(
                ApnsPushClient::new(ApnsPushConfig::new(team_id, key_id, topic, private_key_pem))?,
            )),
            _ => None,
        };

        Ok(Self { apns })
    }

    pub fn is_delivery_enabled(&self) -> bool {
        self.apns.is_some()
    }

    pub async fn notify_inbox_for_devices(&self, db: Arc<Database>, device_ids: Vec<Uuid>) {
        let Some(apns) = &self.apns else {
            return;
        };
        if device_ids.is_empty() {
            return;
        }

        let registrations = match db.list_device_apns_registrations(&device_ids).await {
            Ok(registrations) => registrations,
            Err(err) => {
                warn!("failed to load APNs registrations: {err}");
                return;
            }
        };
        if registrations.is_empty() {
            return;
        }

        stream::iter(registrations.into_iter())
            .for_each_concurrent(8, |registration| {
                let apns = apns.clone();
                let db = db.clone();
                async move {
                    if deliver_inbox_update(apns, db, registration).await.is_err() {
                        warn!("failed to deliver APNs inbox update");
                    }
                }
            })
            .await;
    }
}

async fn deliver_inbox_update(
    apns: Arc<ApnsPushClient>,
    db: Arc<Database>,
    registration: DeviceApnsRegistrationRow,
) -> Result<()> {
    let outcome = apns
        .deliver_wake(
            ApnsPushTarget {
                token_hex: registration.token_hex,
                environment: registration.environment,
            },
            TrixApnsWakePayload::default(),
        )
        .await?;

    match outcome {
        ApnsDeliveryOutcome::Delivered => {
            db.mark_device_apns_delivery_success(registration.device_id)
                .await?;
        }
        ApnsDeliveryOutcome::Rejected {
            reason,
            disable_registration,
        } => {
            db.record_device_apns_delivery_failure(
                registration.device_id,
                &reason,
                disable_registration,
            )
            .await?;
        }
    }

    Ok(())
}
