use std::{collections::BTreeMap, sync::Arc, time::Duration};

use anyhow::{Context, Result};
use quick_xml::{Reader, events::Event};
use sha1::{Digest, Sha1};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};
use tracing::{info, warn};
use trix_push::{ApnsDeliveryOutcome, ApnsPushClient, ApnsPushTarget, TrixApnsNotificationPayload};

use crate::store::PushRegistrationStore;

const DISCO_INFO_XMLNS: &str = "http://jabber.org/protocol/disco#info";
const DISCO_ITEMS_XMLNS: &str = "http://jabber.org/protocol/disco#items";
const ADHOC_XMLNS: &str = "http://jabber.org/protocol/commands";
const DATA_FORM_XMLNS: &str = "jabber:x:data";
const PUBSUB_XMLNS: &str = "http://jabber.org/protocol/pubsub";
const PUSH_XMLNS: &str = "urn:xmpp:push:0";

#[derive(Clone)]
pub struct XmppComponentConfig {
    pub host: String,
    pub port: u16,
    pub jid: String,
    pub shared_secret: String,
}

pub async fn run_component(
    config: XmppComponentConfig,
    store: Arc<PushRegistrationStore>,
    apns: Arc<ApnsPushClient>,
) {
    loop {
        if let Err(err) = run_once(&config, store.clone(), apns.clone()).await {
            warn!("XMPP push component disconnected: {err}");
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

async fn run_once(
    config: &XmppComponentConfig,
    store: Arc<PushRegistrationStore>,
    apns: Arc<ApnsPushClient>,
) -> Result<()> {
    let mut stream = TcpStream::connect((config.host.as_str(), config.port))
        .await
        .with_context(|| "failed to connect XMPP component socket")?;

    stream
        .write_all(
            format!(
                "<stream:stream xmlns='jabber:component:accept' xmlns:stream='http://etherx.jabber.org/streams' to='{}'>",
                xml_escape(&config.jid)
            )
            .as_bytes(),
        )
        .await?;

    let mut buffer = String::new();
    let mut scratch = [0u8; 4096];
    let stream_id = loop {
        let read = stream.read(&mut scratch).await?;
        if read == 0 {
            anyhow::bail!("XMPP component stream closed before handshake");
        }
        buffer.push_str(&String::from_utf8_lossy(&scratch[..read]));
        if let Some((stream_open, remaining)) = take_stream_open(&buffer) {
            buffer = remaining;
            break extract_attr(&stream_open, "id").context("missing XMPP component stream id")?;
        }
    };

    let handshake = xep0114_handshake(&stream_id, &config.shared_secret);
    stream
        .write_all(format!("<handshake>{handshake}</handshake>").as_bytes())
        .await?;

    loop {
        if let Some(end) = buffer.find("<handshake/>") {
            buffer = buffer[end + "<handshake/>".len()..].to_owned();
            break;
        }
        if let Some(end) = buffer.find("<handshake></handshake>") {
            buffer = buffer[end + "<handshake></handshake>".len()..].to_owned();
            break;
        }
        let read = stream.read(&mut scratch).await?;
        if read == 0 {
            anyhow::bail!("XMPP component stream closed during handshake");
        }
        buffer.push_str(&String::from_utf8_lossy(&scratch[..read]));
        if buffer.contains("<stream:error") {
            anyhow::bail!("XMPP component handshake rejected");
        }
    }

    info!("XMPP push component connected as {}", config.jid);
    loop {
        while let Some(stanza) = take_stanza(&mut buffer) {
            if let Some(response) =
                handle_stanza(&config.jid, &stanza, store.clone(), apns.clone()).await
            {
                stream.write_all(response.as_bytes()).await?;
            }
        }

        let read = stream.read(&mut scratch).await?;
        if read == 0 {
            anyhow::bail!("XMPP component stream closed");
        }
        buffer.push_str(&String::from_utf8_lossy(&scratch[..read]));
    }
}

async fn handle_stanza(
    component_jid: &str,
    stanza: &str,
    store: Arc<PushRegistrationStore>,
    apns: Arc<ApnsPushClient>,
) -> Option<String> {
    let parsed = match ParsedIq::parse(stanza) {
        Ok(parsed) => parsed,
        Err(err) => {
            warn!("failed to parse XMPP component stanza: {err}");
            return None;
        }
    };

    match parsed.kind {
        IqKind::DiscoInfo => Some(disco_info_result(component_jid, &parsed)),
        IqKind::DiscoItems { ref node } => {
            Some(disco_items_result(component_jid, &parsed, node.as_deref()))
        }
        IqKind::AdHoc { ref node } if node == "register-device" => {
            Some(register_device_result(component_jid, &parsed, store).await)
        }
        IqKind::AdHoc { ref node } if node == "unregister-device" => {
            Some(unregister_device_result(component_jid, &parsed, store).await)
        }
        IqKind::PubSubPublish { ref node } => {
            Some(publish_result(component_jid, &parsed, node.as_str(), store, apns).await)
        }
        IqKind::Unsupported => Some(error_result(
            component_jid,
            &parsed,
            "cancel",
            "feature-not-implemented",
        )),
        IqKind::AdHoc { .. } => Some(error_result(
            component_jid,
            &parsed,
            "cancel",
            "item-not-found",
        )),
    }
}

async fn register_device_result(
    component_jid: &str,
    iq: &ParsedIq,
    store: Arc<PushRegistrationStore>,
) -> String {
    let Some(owner) = iq.from.as_deref() else {
        return error_result(component_jid, iq, "modify", "bad-request");
    };
    let Some(provider) = iq.fields.get("provider") else {
        return error_result(component_jid, iq, "modify", "bad-request");
    };
    let Some(device_token) = iq.fields.get("device-token") else {
        return error_result(component_jid, iq, "modify", "bad-request");
    };

    match store.register(owner, provider, device_token).await {
        Ok(registration) => {
            let id = xml_escape(&iq.id);
            let to = iq.from.as_deref().map(xml_escape).unwrap_or_default();
            let from = xml_escape(component_jid);
            let node = xml_escape(&registration.node);
            format!(
                "<iq type='result' id='{id}' from='{from}' to='{to}'><command xmlns='{ADHOC_XMLNS}' node='register-device' status='completed'><x xmlns='{DATA_FORM_XMLNS}' type='result'><field var='node'><value>{node}</value></field><field var='features'><value>{PUSH_XMLNS}</value></field><field var='max-payload-size'><value>0</value></field></x></command></iq>"
            )
        }
        Err(_) => error_result(component_jid, iq, "modify", "bad-request"),
    }
}

async fn unregister_device_result(
    component_jid: &str,
    iq: &ParsedIq,
    store: Arc<PushRegistrationStore>,
) -> String {
    let Some(owner) = iq.from.as_deref() else {
        return error_result(component_jid, iq, "modify", "bad-request");
    };
    let Some(provider) = iq.fields.get("provider") else {
        return error_result(component_jid, iq, "modify", "bad-request");
    };
    let Some(device_token) = iq.fields.get("device-token") else {
        return error_result(component_jid, iq, "modify", "bad-request");
    };

    match store.unregister(owner, provider, device_token).await {
        Ok(()) => {
            let id = xml_escape(&iq.id);
            let to = iq.from.as_deref().map(xml_escape).unwrap_or_default();
            let from = xml_escape(component_jid);
            format!(
                "<iq type='result' id='{id}' from='{from}' to='{to}'><command xmlns='{ADHOC_XMLNS}' node='unregister-device' status='completed'/></iq>"
            )
        }
        Err(_) => error_result(component_jid, iq, "modify", "bad-request"),
    }
}

async fn publish_result(
    component_jid: &str,
    iq: &ParsedIq,
    node: &str,
    store: Arc<PushRegistrationStore>,
    apns: Arc<ApnsPushClient>,
) -> String {
    let Some(registration) = store.registration_for_node(node).await else {
        return error_result(component_jid, iq, "cancel", "item-not-found");
    };

    let target = ApnsPushTarget {
        token_hex: registration.token_hex,
        environment: registration.environment,
    };
    match apns
        .deliver_notification(target, TrixApnsNotificationPayload::default())
        .await
    {
        Ok(ApnsDeliveryOutcome::Delivered) => {
            let _ = store.mark_success(node).await;
            empty_result(component_jid, iq)
        }
        Ok(ApnsDeliveryOutcome::Rejected {
            reason,
            disable_registration,
        }) => {
            let _ = store
                .mark_failure(node, &reason, disable_registration)
                .await;
            error_result(component_jid, iq, "cancel", "service-unavailable")
        }
        Err(_) => {
            let _ = store.mark_failure(node, "delivery_failed", false).await;
            error_result(component_jid, iq, "wait", "service-unavailable")
        }
    }
}

fn disco_info_result(component_jid: &str, iq: &ParsedIq) -> String {
    let id = xml_escape(&iq.id);
    let to = iq.from.as_deref().map(xml_escape).unwrap_or_default();
    let from = xml_escape(component_jid);
    format!(
        "<iq type='result' id='{id}' from='{from}' to='{to}'><query xmlns='{DISCO_INFO_XMLNS}'><identity category='pubsub' type='push' name='Trix APNs Push'/><feature var='{DISCO_INFO_XMLNS}'/><feature var='{DISCO_ITEMS_XMLNS}'/><feature var='{ADHOC_XMLNS}'/><feature var='{DATA_FORM_XMLNS}'/><feature var='{PUBSUB_XMLNS}'/><feature var='{PUSH_XMLNS}'/></query></iq>"
    )
}

fn disco_items_result(component_jid: &str, iq: &ParsedIq, node: Option<&str>) -> String {
    let id = xml_escape(&iq.id);
    let to = iq.from.as_deref().map(xml_escape).unwrap_or_default();
    let from = xml_escape(component_jid);
    if node == Some(ADHOC_XMLNS) {
        format!(
            "<iq type='result' id='{id}' from='{from}' to='{to}'><query xmlns='{DISCO_ITEMS_XMLNS}' node='{ADHOC_XMLNS}'><item jid='{from}' node='register-device' name='Register device'/><item jid='{from}' node='unregister-device' name='Unregister device'/></query></iq>"
        )
    } else {
        format!(
            "<iq type='result' id='{id}' from='{from}' to='{to}'><query xmlns='{DISCO_ITEMS_XMLNS}'/></iq>"
        )
    }
}

fn empty_result(component_jid: &str, iq: &ParsedIq) -> String {
    let id = xml_escape(&iq.id);
    let to = iq.from.as_deref().map(xml_escape).unwrap_or_default();
    let from = xml_escape(component_jid);
    format!("<iq type='result' id='{id}' from='{from}' to='{to}'/>")
}

fn error_result(component_jid: &str, iq: &ParsedIq, error_type: &str, condition: &str) -> String {
    let id = xml_escape(&iq.id);
    let to = iq.from.as_deref().map(xml_escape).unwrap_or_default();
    let from = xml_escape(component_jid);
    let error_type = xml_escape(error_type);
    let condition = xml_escape(condition);
    format!(
        "<iq type='error' id='{id}' from='{from}' to='{to}'><error type='{error_type}'><{condition} xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
    )
}

struct ParsedIq {
    id: String,
    from: Option<String>,
    fields: BTreeMap<String, String>,
    kind: IqKind,
}

enum IqKind {
    DiscoInfo,
    DiscoItems { node: Option<String> },
    AdHoc { node: String },
    PubSubPublish { node: String },
    Unsupported,
}

impl ParsedIq {
    fn parse(xml: &str) -> Result<Self> {
        let mut reader = Reader::from_str(xml);
        reader.config_mut().trim_text(true);

        let mut id = None;
        let mut from = None;
        let mut kind = IqKind::Unsupported;
        let mut fields = BTreeMap::new();
        let mut current_field: Option<String> = None;
        let mut in_value = false;

        loop {
            match reader.read_event()? {
                Event::Start(element) => {
                    let name = local_name(element.name().as_ref()).to_owned();
                    let attrs = attrs(&reader, &element)?;
                    match name.as_str() {
                        "iq" => {
                            id = attrs.get("id").cloned();
                            from = attrs.get("from").cloned();
                        }
                        "query" => match attrs.get("xmlns").map(String::as_str) {
                            Some(DISCO_INFO_XMLNS) => kind = IqKind::DiscoInfo,
                            Some(DISCO_ITEMS_XMLNS) => {
                                kind = IqKind::DiscoItems {
                                    node: attrs.get("node").cloned(),
                                };
                            }
                            _ => {}
                        },
                        "command"
                            if attrs.get("xmlns").map(String::as_str) == Some(ADHOC_XMLNS) =>
                        {
                            if let Some(node) = attrs.get("node") {
                                kind = IqKind::AdHoc { node: node.clone() };
                            }
                        }
                        "publish" => {
                            if let Some(node) = attrs.get("node") {
                                kind = IqKind::PubSubPublish { node: node.clone() };
                            }
                        }
                        "field" => current_field = attrs.get("var").cloned(),
                        "value" => in_value = true,
                        _ => {}
                    }
                }
                Event::Empty(element) => {
                    let name = local_name(element.name().as_ref()).to_owned();
                    let attrs = attrs(&reader, &element)?;
                    match name.as_str() {
                        "query" => match attrs.get("xmlns").map(String::as_str) {
                            Some(DISCO_INFO_XMLNS) => kind = IqKind::DiscoInfo,
                            Some(DISCO_ITEMS_XMLNS) => {
                                kind = IqKind::DiscoItems {
                                    node: attrs.get("node").cloned(),
                                };
                            }
                            _ => {}
                        },
                        "publish" => {
                            if let Some(node) = attrs.get("node") {
                                kind = IqKind::PubSubPublish { node: node.clone() };
                            }
                        }
                        _ => {}
                    }
                }
                Event::Text(text) => {
                    if in_value {
                        if let Some(field) = current_field.as_deref() {
                            fields.insert(field.to_owned(), text.decode()?.into_owned());
                        }
                    }
                }
                Event::End(element) => match local_name(element.name().as_ref()) {
                    "field" => current_field = None,
                    "value" => in_value = false,
                    "iq" => break,
                    _ => {}
                },
                Event::Eof => break,
                _ => {}
            }
        }

        Ok(Self {
            id: id.unwrap_or_else(|| "trix-push-missing-id".to_owned()),
            from,
            fields,
            kind,
        })
    }
}

fn attrs(
    reader: &Reader<&[u8]>,
    element: &quick_xml::events::BytesStart<'_>,
) -> Result<BTreeMap<String, String>> {
    let mut result = BTreeMap::new();
    for attr in element.attributes() {
        let attr = attr?;
        let key = local_name(attr.key.as_ref()).to_owned();
        let value = attr
            .decode_and_unescape_value(reader.decoder())?
            .into_owned();
        result.insert(key, value);
    }
    Ok(result)
}

fn local_name(name: &[u8]) -> &str {
    let raw = std::str::from_utf8(name).unwrap_or_default();
    raw.rsplit_once(':').map(|(_, local)| local).unwrap_or(raw)
}

fn take_stanza(buffer: &mut String) -> Option<String> {
    let iq_end = buffer
        .find("</iq>")
        .map(|index| (index + "</iq>".len(), "iq"));
    let message_end = buffer
        .find("</message>")
        .map(|index| (index + "</message>".len(), "message"));
    let presence_end = buffer
        .find("</presence>")
        .map(|index| (index + "</presence>".len(), "presence"));
    let (end, _) = [iq_end, message_end, presence_end]
        .into_iter()
        .flatten()
        .min_by_key(|(end, _)| *end)?;

    let start = buffer.find('<')?;
    let stanza = buffer[start..end].to_owned();
    *buffer = buffer[end..].to_owned();
    Some(stanza)
}

fn take_stream_open(buffer: &str) -> Option<(String, String)> {
    let start = buffer.find("<stream:stream")?;
    let end = buffer[start..].find('>')? + start;
    Some((buffer[start..=end].to_owned(), buffer[end + 1..].to_owned()))
}

fn extract_attr(xml: &str, name: &str) -> Option<String> {
    for quote in ['"', '\''] {
        let needle = format!("{name}={quote}");
        if let Some(start) = xml.find(&needle) {
            let value_start = start + needle.len();
            let value_end = xml[value_start..].find(quote)? + value_start;
            return Some(xml[value_start..value_end].to_owned());
        }
    }
    None
}

fn xep0114_handshake(stream_id: &str, secret: &str) -> String {
    let mut hasher = Sha1::new();
    hasher.update(stream_id.as_bytes());
    hasher.update(secret.as_bytes());
    hex_lower(&hasher.finalize())
}

fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_martin_register_device_command() {
        let xml = "<iq type='set' id='push-1' from='alice@trix.selfhost.ru/ios' to='push.trix.selfhost.ru'><command xmlns='http://jabber.org/protocol/commands' node='register-device'><x xmlns='jabber:x:data' type='submit'><field var='provider'><value>apns-sandbox</value></field><field var='device-token'><value>001122aabbcc</value></field></x></command></iq>";

        let parsed = ParsedIq::parse(xml).expect("valid register-device stanza");

        assert_eq!(parsed.id, "push-1");
        assert_eq!(parsed.from.as_deref(), Some("alice@trix.selfhost.ru/ios"));
        assert!(matches!(
            parsed.kind,
            IqKind::AdHoc { ref node } if node == "register-device"
        ));
        assert_eq!(
            parsed.fields.get("provider").map(String::as_str),
            Some("apns-sandbox")
        );
        assert_eq!(
            parsed.fields.get("device-token").map(String::as_str),
            Some("001122aabbcc")
        );
    }

    #[test]
    fn parses_ejabberd_push_publish_node() {
        let xml = "<iq type='set' id='push-2' from='trix.selfhost.ru' to='push.trix.selfhost.ru'><pubsub xmlns='http://jabber.org/protocol/pubsub'><publish node='trix-push/abcdef'><item id='notification'/></publish></pubsub></iq>";

        let parsed = ParsedIq::parse(xml).expect("valid pubsub publish stanza");

        assert_eq!(parsed.id, "push-2");
        assert!(matches!(
            parsed.kind,
            IqKind::PubSubPublish { ref node } if node == "trix-push/abcdef"
        ));
    }

    #[test]
    fn extracts_stream_open_after_xml_declaration() {
        let xml = "<?xml version='1.0'?><stream:stream id='abc123' xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:component:accept'><handshake/>";

        let (open, remaining) = take_stream_open(xml).expect("stream open");

        assert_eq!(extract_attr(&open, "id").as_deref(), Some("abc123"));
        assert_eq!(remaining, "<handshake/>");
    }
}
