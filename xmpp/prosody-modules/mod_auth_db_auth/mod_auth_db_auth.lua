-- Authenticates users against MyLittleServer's db-auth, like mod_auth_http, and offers
-- SCRAM-SHA-256(-PLUS) to users that have SCRAM credentials there.

local async = require "prosody.util.async";
local base64_decode = require "prosody.util.encodings".base64.decode;
local http = require "prosody.net.http";
local jid_prepped_split = require "prosody.util.jid".prepped_split;
local json = require "prosody.util.json";
local new_sasl = require "prosody.util.sasl".new;

local host = module.host;
local api_base = assert(module:get_option_string("db_auth_url"), "db_auth_url is required"):gsub("/$", "");

local function request(method, name, params)
	local wait, done = async.waiter();
	local url, ex = api_base.."/"..name, { method = method };
	if method == "POST" then
		ex.headers = { ["Content-Type"] = "application/x-www-form-urlencoded" };
		ex.body = http.formencode(params);
	else
		url = url.."?"..http.formencode(params);
	end
	local code, body;
	http.request(url, ex, function (body_, code_)
		body, code = body_, code_;
		done();
	end);
	wait();
	return code, body;
end

local function request_json(method, name, params)
	local code, body = request(method, name, params);
	if code ~= 200 then return nil; end
	return json.decode(body);
end

local function get_scram_sha_256(username)
	local result = request_json("GET", "scram_sha_256", { user = username });
	if not result or type(result.scram_sha256) ~= "string" then return nil; end
	local iterations, salt, stored_key, server_key = result.scram_sha256:match("^{SCRAM%-SHA%-256}(%d+),([^,]+),([^,]+),([^,]+)$");
	if not iterations then
		module:log("error", "Unexpected SCRAM credentials format for %s", username);
		return nil;
	end
	return base64_decode(stored_key), base64_decode(server_key), tonumber(iterations), base64_decode(salt);
end

local provider = {};

function provider.test_password(username, password)
	return request("POST", "check_password", { user = username, password = password }) == 200;
end

function provider.set_password(username, password)
	local code = request("POST", "set_password", { user = username, password = password });
	return code == 201;
end

function provider.user_exists(username)
	return request("GET", "user_exists", { user = username }) == 200;
end

function provider.users()
	return function () return nil; end
end

function provider.create_user()
	return nil, "Not supported";
end

function provider.delete_user()
	return nil, "Not supported";
end

-- Clients can't fall back to PLAIN once they pick SCRAM, so offer it only when the account
-- named in the stream header has SCRAM credentials. A PLAIN login creates them.
module:hook("stream-features", function (event)
	local session = event.origin;
	local from = event.stream and event.stream.from;
	if session.username or not from then return; end
	local node, from_host = jid_prepped_split(from);
	if node and from_host == host and get_scram_sha_256(node) then
		session.db_auth_scram_user = node;
	end
end, 1000);

function provider.get_sasl_handler(session)
	local profile = {
		plain_test = function (_, username, password)
			return provider.test_password(username, password), true;
		end;
	};
	if session and session.db_auth_scram_user then
		profile.scram_sha_256 = function (_, username)
			local stored_key, server_key, iterations, salt = get_scram_sha_256(username);
			if not stored_key then return; end
			return stored_key, server_key, iterations, salt, true;
		end;
	end
	return new_sasl(host, profile);
end

module:provides("auth", provider);
