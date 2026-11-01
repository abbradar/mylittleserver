-- Authenticated users may only use their own addresses (including aliases) in
-- the From: header. Postfix already checks that the envelope sender is owned by
-- the user (`reject_sender_login_mismatch`), so require From: to match it.
rspamd_config.MLS_FROM_NOT_ENVELOPE = {
  callback = function(task)
    if not task:get_user() then
      return false
    end
    local smtp_from = task:get_from('smtp')
    local mime_from = task:get_from('mime')
    if not smtp_from or not smtp_from[1] or smtp_from[1].addr == '' then
      return true
    end
    if not mime_from or #mime_from ~= 1 then
      return true
    end
    return mime_from[1].addr:lower() ~= smtp_from[1].addr:lower()
  end,
  score = 0.0,
  description = 'From: header does not match the envelope sender of an authenticated user',
  group = 'headers',
}
