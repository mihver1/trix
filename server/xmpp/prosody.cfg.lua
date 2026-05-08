-- Trix private XMPP Prosody scaffold.
-- Target XMPP domain: trix.selfhost.ru
--
-- No secrets are stored in this file. Create accounts interactively with
-- prosodyctl and mount TLS certificates through ./certs or a deployment-specific
-- secret store.

admins = { }

pidfile = "/tmp/prosody.pid"
data_path = "/var/lib/prosody"
certificates = "/etc/prosody/certs"

authentication = "internal_hashed"
allow_registration = false

-- Client-to-server only. Do not expose server-to-server federation.
c2s_require_encryption = true
c2s_ports = { 5222 }
c2s_interfaces = { "*" }
s2s_ports = { }
s2s_interfaces = { }
modules_disabled = { "s2s" }

-- HTTP is used by mod_http_file_share. Keep it behind a reverse proxy in
-- deployments; docker-compose binds it to localhost by default.
http_ports = { 5280 }
http_interfaces = { "*" }

log = {
    info = "*console";
}

modules_enabled = {
    "roster";
    "saslauth";
    "tls";
    "disco";
    "carbons";
    "pep";
    "private";
    "blocklist";
    "vcard4";
    "vcard_legacy";
    "version";
    "uptime";
    "time";
    "ping";
    "mam";
    "csi_simple";
    "smacks";
    "limits";
    "http";
}

limits = {
    c2s = {
        rate = "10kb/s";
        burst = "2s";
    };
}

-- Private MVP archive policy. Clients still own OMEMO encryption; this stores
-- encrypted stanzas for multi-device sync/history.
default_archive_policy = true
archive_expires_after = "4w"
max_archive_query_results = 50

VirtualHost "trix.selfhost.ru"
    name = "Trix XMPP"
    disco_items = {
        { "conference.trix.selfhost.ru", "Trix group chats" };
        { "upload.trix.selfhost.ru", "Trix file sharing" };
    }

Component "conference.trix.selfhost.ru" "muc"
    name = "Trix Conferences"
    restrict_room_creation = "local"
    modules_enabled = {
        "muc_mam";
    }
    muc_log_by_default = true
    muc_log_presences = false
    muc_log_expires_after = "4w"

Component "upload.trix.selfhost.ru" "http_file_share"
    name = "Trix HTTP File Sharing"
    http_host = "upload.trix.selfhost.ru"
    http_file_share_size_limit = 16 * 1024 * 1024
    http_file_share_daily_quota = 100 * 1024 * 1024
    http_file_share_global_quota = 1024 * 1024 * 1024
    http_file_share_expires_after = "31 days"
