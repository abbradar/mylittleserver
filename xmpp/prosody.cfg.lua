storage = "sql"
sql = {
  driver = "PostgreSQL";
}

legacy_ssl_ports = { 5223 }

http_max_content_size = 104857600
http_external_url = "https://xmpp.@domain@/"
cross_domain_bosh = true
consider_bosh_secure = true
cross_domain_websocket = true
consider_websocket_secure = true

-- FIXME: Move this to the NixOS config.
authentication = "http"
http_auth_url = "http://127.0.0.1:12344"

welcome_message = "Hello $user! Please visit https://@domain@/private/ for information on this service. Use your login (without domain) and password."

proxy65_ports = { 7777 }

archive_expires_after = "never"
muc_log_by_default = true
muc_log_expires_after = "never"
muc_log_presences = false

http_upload_external_base_url = "https://xmpp.@domain@/upload/"
http_upload_external_secret = "@uploadSecret@"
http_upload_external_file_size_limit = 104857600

turn_external_host = "turn.@domain@"
turn_external_secret = "@turnSecret@"

contact_info = {
  abuse = { "mailto:abuse@@domain@" };
  admin = { "mailto:admin@@domain@", "xmpp:admin@@domain@" };
}

Component "conference.@domain@" "muc"
  max_history_messages = 50
  modules_enabled = {
    "muc_mam";
    "http_muc_log";
    "vcard_muc";
  }

Component "proxy65.@domain@" "proxy65"

Component "pubsub.@domain@" "pubsub"
