use uuid::Uuid;

const ACCOUNT_BOOTSTRAP_DOMAIN: &[u8] = b"trix-account-bootstrap:v1";
const DEVICE_REVOKE_DOMAIN: &[u8] = b"trix-device-revoke:v1";

pub fn account_bootstrap_message(transport_pubkey: &[u8], credential_identity: &[u8]) -> Vec<u8> {
    let mut message = Vec::with_capacity(
        ACCOUNT_BOOTSTRAP_DOMAIN.len() + 8 + transport_pubkey.len() + credential_identity.len(),
    );
    message.extend_from_slice(ACCOUNT_BOOTSTRAP_DOMAIN);
    message.extend_from_slice(&(transport_pubkey.len() as u32).to_be_bytes());
    message.extend_from_slice(transport_pubkey);
    message.extend_from_slice(&(credential_identity.len() as u32).to_be_bytes());
    message.extend_from_slice(credential_identity);
    message
}

pub fn device_revoke_message(device_id: Uuid, reason: &str) -> Vec<u8> {
    let device_id = device_id.to_string();
    let device_id = device_id.as_bytes();
    let reason = reason.as_bytes();

    let mut message =
        Vec::with_capacity(DEVICE_REVOKE_DOMAIN.len() + 8 + device_id.len() + reason.len());
    message.extend_from_slice(DEVICE_REVOKE_DOMAIN);
    message.extend_from_slice(&(device_id.len() as u32).to_be_bytes());
    message.extend_from_slice(device_id);
    message.extend_from_slice(&(reason.len() as u32).to_be_bytes());
    message.extend_from_slice(reason);
    message
}

#[cfg(test)]
mod tests {
    use super::{account_bootstrap_message, device_revoke_message};
    use uuid::Uuid;

    #[test]
    fn account_bootstrap_message_is_stable() {
        let message = account_bootstrap_message(b"transport", b"credential");

        let expected = [
            b"trix-account-bootstrap:v1".as_slice(),
            &(9u32.to_be_bytes()),
            b"transport",
            &(10u32.to_be_bytes()),
            b"credential",
        ]
        .concat();

        assert_eq!(message, expected);
    }

    #[test]
    fn device_revoke_message_is_stable() {
        let device_id = Uuid::parse_str("9f8498f2-0fe4-43a8-9f75-9e220c694f93").unwrap();
        let message = device_revoke_message(device_id, "compromised");

        let expected = [
            b"trix-device-revoke:v1".as_slice(),
            &(36u32.to_be_bytes()),
            b"9f8498f2-0fe4-43a8-9f75-9e220c694f93",
            &(11u32.to_be_bytes()),
            b"compromised",
        ]
        .concat();

        assert_eq!(message, expected);
    }
}
