-- Applies mod_limit_auth's per-IP throttle to SASL2 (XEP-0388) authentication,
-- which mod_limit_auth itself only counts but doesn't refuse.

local st = require "prosody.util.stanza";

module:depends("limit_auth");
module:depends("sasl2");

local throttles = module:shared("limit_auth/throttles");

module:hook("stanza/urn:xmpp:sasl:2:authenticate", function (event)
	local origin = event.origin;
	if origin.type ~= "c2s_unauthed" then return end
	local throttle = throttles[origin.ip];
	if throttle and not throttle:peek(1) then
		origin.log("warn", "Too many authentication attempts for ip %s", origin.ip);
		origin.send(st.stanza("failure", { xmlns = "urn:xmpp:sasl:2" })
			:tag("temporary-auth-failure", { xmlns = "urn:ietf:params:xml:ns:xmpp-sasl" }));
		return true;
	end
end, 10);
