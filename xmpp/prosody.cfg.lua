storage = "sql"
sql = {
    driver = "PostgreSQL";
    database = "prosody";
}

c2s_direct_tls_ports = { 5223 }

http_external_url = "https://xmpp.@domain@/"
http_paths = {
    file_share = "/upload";
}
consider_bosh_secure = true
consider_websocket_secure = true
http_cors_override = {
    bosh = {
        enabled = false;
    };
    websocket = {
        enabled = false;
    };
}

-- FIXME: Move this to the NixOS config.
authentication = "http"
http_auth_url = "http://127.0.0.1:12344/prosody"

welcome_message = "Hello $user! Please visit https://@domain@/private/ for information on this service. Use your login (without domain) and password."

archive_expires_after = "never"
muc_log_by_default = true
muc_log_expires_after = "never"
muc_log_presences = false

use_dane = true
unbound = {
    trustfile = "@dnsRootKey@";
}

anti_spam_services = { "xmppbl.org" }
report_forward_to = { "submit@reports.xmppbl.org" }
report_forward_to_origin = true

turn_external_host = "turn.@domain@"
turn_external_secret = Credential("turn-secret")
turn_external_tcp = true
turn_external_tls_port = 5349

proxy65_ports = { 7777 }

contact_info = {
    abuse = { "mailto:abuse@@domain@", "xmpp:admin@@domain@" };
    admin = { "mailto:admin@@domain@", "xmpp:admin@@domain@" };
}

Component "conference.@domain@" "muc"
    restrict_room_creation = "local"
    max_history_messages = 50
    modules_enabled = {
        "muc_mam";
        "http_muc_log";
    }

Component "proxy65.@domain@" "proxy65"

Component "pubsub.@domain@" "pubsub"
