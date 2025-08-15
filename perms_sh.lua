-- lua/rpg_perms/perms_sh.lua
-- Shared enums / net strings / helpers
if SERVER then
  -- Admin open + bootstrap
  util.AddNetworkString("rpg_perms_open_admin")     -- c->s request open
  util.AddNetworkString("rpg_perms_bootstrap")      -- s->c initial payload (roles, players, access flags)
  util.AddNetworkString("rpg_perms_action_result")  -- s->c {ok, msg}
  util.AddNetworkString("rpg_perms_live_refresh")   -- s->c notify a player their perms changed

  -- Role assignment
  util.AddNetworkString("rpg_perms_grant_role")     -- c->s {targetSid64, roleName, minutes?, reason?}
  util.AddNetworkString("rpg_perms_revoke_role")    -- c->s {targetSid64, roleName}

  -- Role editing
  util.AddNetworkString("rpg_roles_create")         -- c->s {name, display_name, priority, color}
  util.AddNetworkString("rpg_roles_update")         -- c->s {name, display_name?, priority?, color?, is_default?}
  util.AddNetworkString("rpg_roles_delete")         -- c->s {name}
  util.AddNetworkString("rpg_roles_set_perm")       -- c->s {roleName, permName, effect} effect='allow'|'deny'
  util.AddNetworkString("rpg_roles_remove_perm")    -- c->s {roleName, permName}

  -- Moderation (online/offline)
  util.AddNetworkString("rpg_moderate_action")      -- c->s {action, targetSid64, minutes?, reason?}
  -- action in {'mute','kick','warn','ban_temp','ban_perm'}

  -- Reports
  util.AddNetworkString("rpg_reports_submit")       -- c->s {targets: [sid64,...], description}
  util.AddNetworkString("rpg_reports_fetch")        -- c->s request list; s->c responds with payload
  util.AddNetworkString("rpg_reports_payload")      -- s->c {reports=[...]}
  util.AddNetworkString("rpg_reports_action")       -- c->s {id, op, note?}  op in {'claim','resolve','close','reopen'}
  util.AddNetworkString("rpg_reports_updated")      -- s->c notify client to refetch
end

function PERMS_IsSteamID64(s)
  return isstring(s) and #s >= 17 and #s <= 20 and s:match("^%d+$") ~= nil
end
