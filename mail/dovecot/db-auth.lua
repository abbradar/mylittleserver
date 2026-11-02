-- Checks passwords with db-auth, which also limits failed logins per client IP.

local http_client
local check_password_url

local function urlencode(s)
  return (s:gsub("[^%w%-%._~]", function (c)
    return string.format("%%%02X", c:byte())
  end))
end

function script_init(settings)
  check_password_url = settings.db_auth_url .. "/check_password"
  http_client = dovecot.http.client({
    event_parent = dovecot.event(),
    request_max_attempts = 1,
    request_timeout = "10s",
  })
  return 0
end

function script_deinit()
end

function auth_password_verify(req, password)
  local user = req:var_expand("%{user | username}")
  local request = http_client:request {
    url = check_password_url,
    method = "POST",
  }
  request:add_header("Content-Type", "application/x-www-form-urlencoded")
  if req.remote_ip then
    request:add_header("X-Forwarded-For", req.remote_ip)
  end
  request:set_payload("user=" .. urlencode(user) .. "&password=" .. urlencode(password))
  local response = request:submit()
  local status = response:status()
  if status == 200 then
    return dovecot.auth.PASSDB_RESULT_OK, { user = user }
  elseif status == 403 then
    return dovecot.auth.PASSDB_RESULT_PASSWORD_MISMATCH, nil
  end
  return dovecot.auth.PASSDB_RESULT_INTERNAL_FAILURE,
    "db-auth returned " .. status .. " " .. response:reason()
end
