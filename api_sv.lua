-- lua/rpg_perms/api_sv.lua
if not SERVER then return end
local DB = RPG_PERMS.DB
local function log(msg) print("[RPG_PERMS] " .. msg) end

Perms.API = Perms.API or {}

-- === Helpers ===
local function roleIdByName(name)
  return Perms._roleByName and Perms._roleByName[name or ""] or nil
end
local function permIdByName(name)
  return Perms._permByName and Perms._permByName[name or ""] or nil
end
local function has(ply, perm) return Perms.Has(ply, perm) end

-- === Role Assignment ===
function Perms.API.GrantRole(actorPly, targetSid64, roleName, minutes, reason)
  if not PERMS_IsSteamID64(targetSid64) then return false, "Invalid SteamID64" end
  local rid = roleIdByName(roleName); if not rid then return false, "Unknown role: " .. tostring(roleName) end
  local expires_sql = "NULL"
  if minutes and tonumber(minutes) and tonumber(minutes) > 0 then
    expires_sql = string.format("DATE_ADD(NOW(), INTERVAL %d MINUTE)", tonumber(minutes))
  end
  local q = DB:query(string.format([[
    INSERT INTO user_roles (steamid64, role_id, ctx, expires_at, granted_by, reason)
    VALUES ('%s', %d, NULL, %s, '%s', %s)
    ON DUPLICATE KEY UPDATE expires_at = %s, granted_by = VALUES(granted_by), reason = VALUES(reason)
  ]],
    DB:escape(targetSid64), rid, expires_sql, DB:escape(IsValid(actorPly) and actorPly:SteamID64() or "server"),
    reason and ("'" .. DB:escape(reason) .. "'") or "NULL",
    expires_sql))

  function q:onSuccess()
    log(("Granted role %s to %s"):format(roleName, targetSid64))
    Perms.RefreshUser(targetSid64, function()
      for _, p in ipairs(player.GetAll()) do
        if p:SteamID64() == targetSid64 then
          net.Start("rpg_perms_live_refresh") net.Send(p)
          break
        end
      end
    end)
  end
  function q:onError(err) log("GrantRole failed: " .. tostring(err)) end
  q:start()
  return true
end

function Perms.API.RevokeRole(actorPly, targetSid64, roleName)
  if not PERMS_IsSteamID64(targetSid64) then return false, "Invalid SteamID64" end
  local rid = roleIdByName(roleName); if not rid then return false, "Unknown role: " .. tostring(roleName) end
  local q = DB:query(string.format([[
    DELETE FROM user_roles WHERE steamid64 = '%s' AND role_id = %d
  ]], DB:escape(targetSid64), rid))
  function q:onSuccess()
    log(("Revoked role %s from %s"):format(roleName, targetSid64))
    Perms.RefreshUser(targetSid64, function()
      for _, p in ipairs(player.GetAll()) do
        if p:SteamID64() == targetSid64 then net.Start("rpg_perms_live_refresh") net.Send(p) break end
      end
    end)
  end
  function q:onError(err) log("RevokeRole failed: " .. tostring(err)) end
  q:start()
  return true
end

-- === Role Editing ===
function Perms.API.CreateRole(actorPly, name, display_name, priority, color)
  if not name or name == "" then return false, "Missing role name" end
  local q = DB:query(string.format([[
    INSERT INTO roles (name, display_name, priority, color, is_default, inherits)
    VALUES ('%s','%s', %d, %d, 0, JSON_ARRAY())
  ]], DB:escape(name), DB:escape(display_name or name), tonumber(priority) or 0, tonumber(color) or 0xFFFFFF))
  function q:onSuccess()
    log("Created role " .. name)
    Perms.ReloadAll(function() end)
  end
  function q:onError(err) log("CreateRole failed: " .. tostring(err)) end
  q:start(); return true
end

function Perms.API.UpdateRole(actorPly, name, fields)
  local sets = {}
  if fields.display_name then table.insert(sets, "display_name='"..DB:escape(fields.display_name).."'") end
  if fields.priority then table.insert(sets, "priority="..tonumber(fields.priority)) end
  if fields.color then table.insert(sets, "color="..tonumber(fields.color)) end
  if fields.is_default ~= nil then table.insert(sets, "is_default="..(fields.is_default and 1 or 0)) end
  if #sets == 0 then return false, "No fields to update" end
  local q = DB:query(string.format("UPDATE roles SET %s WHERE name='%s'", table.concat(sets, ","), DB:escape(name)))
  function q:onSuccess() log("Updated role " .. name) Perms.ReloadAll(function() end) end
  function q:onError(err) log("UpdateRole failed: " .. tostring(err)) end
  q:start(); return true
end

function Perms.API.DeleteRole(actorPly, name)
  local rid = roleIdByName(name); if not rid then return false, "Unknown role" end
  local q = DB:query(string.format("DELETE FROM roles WHERE id=%d", rid))
  function q:onSuccess() log("Deleted role " .. name) Perms.ReloadAll(function() end) end
  function q:onError(err) log("DeleteRole failed: " .. tostring(err)) end
  q:start(); return true
end

function Perms.API.SetRolePerm(actorPly, roleName, permName, effect)
  local rid = roleIdByName(roleName); if not rid then return false, "Unknown role" end
  local pid = permIdByName(permName); if not pid then return false, "Unknown perm" end
  if effect ~= "allow" and effect ~= "deny" then return false, "Effect must be allow/deny" end
  local q = DB:query(string.format([[
    INSERT INTO role_permissions (role_id, perm_id, effect)
    VALUES (%d, %d, '%s') ON DUPLICATE KEY UPDATE effect=VALUES(effect)
  ]], rid, pid, DB:escape(effect)))
  function q:onSuccess()
    log(("Set %s.%s=%s"):format(roleName, permName, effect))
    Perms.ReloadAll(function()
      for _, p in ipairs(player.GetAll()) do
        Perms.RefreshUser(p:SteamID64(), function() net.Start("rpg_perms_live_refresh") net.Send(p) end)
      end
    end)
  end
  function q:onError(err) log("SetRolePerm failed: " .. tostring(err)) end
  q:start(); return true
end

function Perms.API.RemoveRolePerm(actorPly, roleName, permName)
  local rid = roleIdByName(roleName); if not rid then return false, "Unknown role" end
  local pid = permIdByName(permName); if not pid then return false, "Unknown perm" end
  local q = DB:query(string.format("DELETE FROM role_permissions WHERE role_id=%d AND perm_id=%d", rid, pid))
  function q:onSuccess()
    log(("Removed %s from %s"):format(permName, roleName))
    Perms.ReloadAll(function()
      for _, p in ipairs(player.GetAll()) do
        Perms.RefreshUser(p:SteamID64(), function() net.Start("rpg_perms_live_refresh") net.Send(p) end)
      end
    end)
  end
  function q:onError(err) log("RemoveRolePerm failed: " .. tostring(err)) end
  q:start(); return true
end

-- === Moderation ===
local function recordModeration(actorSid, targetSid, action, minutes, reason)
  local q = DB:query(string.format([[
    INSERT INTO moderation_actions (actor_sid, target_sid, action, minutes, reason)
    VALUES ('%s','%s','%s', %s, %s)
  ]], DB:escape(actorSid), DB:escape(targetSid), DB:escape(action),
      minutes and tonumber(minutes) or "NULL",
      reason and ("'"..DB:escape(reason).."'") or "NULL"))
  function q:onSuccess() end
  function q:onError(err) log("Record moderation failed: " .. tostring(err)) end
  q:start()
end

local function console(cmd) game.ConsoleCommand(cmd .. "\n") end

local function doModeration(actorPly, payload)
  local action = tostring(payload.action or "")
  local targetSid = tostring(payload.targetSid64 or "")
  local minutes = tonumber(payload.minutes) or 0
  local reason = tostring(payload.reason or "")

  if not PERMS_IsSteamID64(targetSid) then return false, "Invalid SteamID64" end

  if action == "mute" then
    if not has(actorPly, "chat.mute") then return false, "Missing permission: chat.mute" end
    -- Your chat system should enforce mutes; we persist an action for now.
    recordModeration(actorPly:SteamID64(), targetSid, "mute", minutes, reason)
    return true, "Muted (logical) — wire your chat system to respect DB/state."

  elseif action == "warn" then
    if not has(actorPly, "player.warn") then return false, "Missing permission: player.warn" end
    recordModeration(actorPly:SteamID64(), targetSid, "warn", nil, reason)
    return true, "Warn recorded."

  elseif action == "kick" then
    if not has(actorPly, "player.kick") then return false, "Missing permission: player.kick" end
    for _, p in ipairs(player.GetAll()) do
      if p:SteamID64() == targetSid then
        p:Kick(reason ~= "" and reason or "Kicked")
        recordModeration(actorPly:SteamID64(), targetSid, "kick", nil, reason)
        return true, "Kicked."
      end
    end
    return false, "Target not online."

  elseif action == "ban_temp" then
    if not has(actorPly, "player.ban.temp") then return false, "Missing permission: player.ban.temp" end
    if minutes <= 0 then return false, "Minutes must be > 0" end
    console(string.format("banid %d %s kick", minutes, targetSid))
    recordModeration(actorPly:SteamID64(), targetSid, "ban_temp", minutes, reason)
    return true, "Temp ban issued."

  elseif action == "ban_perm" then
    if not has(actorPly, "player.ban.perm") then return false, "Missing permission: player.ban.perm" end
    console(string.format("banid 0 %s kick", targetSid))
    recordModeration(actorPly:SteamID64(), targetSid, "ban_perm", nil, reason)
    return true, "Perm ban issued."
  end

  return false, "Unknown action."
end

-- === Reports ===
local function sendReportsList(toPly)
  -- Last 100 reports, newest first
  local q = DB:query([[
    SELECT id, created_at, reporter_sid, targets_json, description, status, handled_by, resolution_note
    FROM reports ORDER BY id DESC LIMIT 100
  ]])
  function q:onSuccess(rows)
    net.Start("rpg_reports_payload")
      net.WriteTable(rows or {})
    net.Send(toPly)
  end
  function q:onError(err) log("Fetch reports failed: "..tostring(err)) end
  q:start()
end

local function createReport(fromPly, targets, description)
  local targets_json = util.TableToJSON(targets or {})
  local q = DB:query(string.format([[
    INSERT INTO reports (reporter_sid, targets_json, description, status)
    VALUES ('%s','%s','%s','open')
  ]], DB:escape(fromPly and fromPly:SteamID64() or "unknown"),
       DB:escape(targets_json or "[]"), DB:escape(description or "")))
  function q:onSuccess() log("Report created") end
  function q:onError(err) log("Create report failed: "..tostring(err)) end
  q:start()
end

local function actionReport(actorPly, id, op, note)
  local valid = {claim=true, resolve=true, close=true, reopen=true}
  if not valid[op] then return false, "Bad op" end
  local setStatus = {
    claim="claimed",
    resolve="resolved",
    close="closed",
    reopen="open"
  }
  local q = DB:query(string.format([[
    UPDATE reports
    SET status='%s', handled_by='%s', resolution_note=%s
    WHERE id=%d
  ]], DB:escape(setStatus[op]), DB:escape(actorPly:SteamID64()),
       note and ("'"..DB:escape(note).."'") or "resolution_note",
       tonumber(id) or -1))
  function q:onSuccess() end
  function q:onError(err) log("Action report failed: "..tostring(err)) end
  q:start(); return true
end

-- === Net handlers / UI wiring ===
local function accessFlags(ply)
  return {
    moderation = has(ply, "ui.admin.moderation") or has(ply, "ui.admin.open"), -- let mods in via dedicated perm
    roleAssign = has(ply, "ui.admin.perms.edit"),
    roleEdit   = has(ply, "ui.admin.roles.edit"),
    reports    = has(ply, "ui.admin.reports")
  }
end

local function sendBootstrap(toPly)
  -- Roles (for UI dropdowns)
  local roles = {}
  for id, r in pairs(Perms._roles or {}) do
    roles[#roles+1] = {
      id=id, name=r.name, display=r.display_name, priority=tonumber(r.priority) or 0, color=tonumber(r.color) or 0xFFFFFF
    }
  end
  table.SortByMember(roles, "priority", true)

  -- Online players listing
  local players = {}
  for _, p in ipairs(player.GetAll()) do
    local sid = p:SteamID64()
    local grants = Perms._userGrants[sid] or {}
    local roleNames = {}
    for _, rid in ipairs(grants.roles or {}) do
      local rr = Perms._roles[rid]; if rr then table.insert(roleNames, rr.name) end
    end
    players[#players+1] = { sid=sid, name=p:Nick(), roles=roleNames }
  end

  net.Start("rpg_perms_bootstrap")
    net.WriteTable({
      roles=roles,
      players=players,
      access=accessFlags(toPly)
    })
  net.Send(toPly)
end

net.Receive("rpg_perms_open_admin", function(_, ply)
  if not has(ply, "ui.admin.open") and not has(ply, "ui.admin.moderation") then return end
  sendBootstrap(ply)
end)

local function respond(ply, ok, msg)
  net.Start("rpg_perms_action_result")
    net.WriteBool(ok and true or false)
    net.WriteString(msg or (ok and "OK" or "Failed"))
  net.Send(ply)
end

-- Role assignment
net.Receive("rpg_perms_grant_role", function(_, ply)
  if not has(ply, "ui.admin.perms.edit") then return respond(ply, false, "Missing permission: ui.admin.perms.edit") end
  local t = net.ReadTable() or {}
  local ok, err = Perms.API.GrantRole(ply, t.targetSid64, t.roleName, tonumber(t.minutes) or 0, t.reason)
  respond(ply, ok ~= false, err)
end)

net.Receive("rpg_perms_revoke_role", function(_, ply)
  if not has(ply, "ui.admin.perms.edit") then return respond(ply, false, "Missing permission: ui.admin.perms.edit") end
  local t = net.ReadTable() or {}
  local ok, err = Perms.API.RevokeRole(ply, t.targetSid64, t.roleName)
  respond(ply, ok ~= false, err)
end)

-- Role editing
net.Receive("rpg_roles_create", function(_, ply)
  if not has(ply, "ui.admin.roles.edit") then return respond(ply, false, "Missing permission: ui.admin.roles.edit") end
  local t = net.ReadTable() or {}
  local ok, err = Perms.API.CreateRole(ply, t.name, t.display_name, tonumber(t.priority) or 0, tonumber(t.color) or 0xFFFFFF)
  respond(ply, ok ~= false, err)
end)

net.Receive("rpg_roles_update", function(_, ply)
  if not has(ply, "ui.admin.roles.edit") then return respond(ply, false, "Missing permission: ui.admin.roles.edit") end
  local t = net.ReadTable() or {}
  local ok, err = Perms.API.UpdateRole(ply, t.name, {
    display_name = t.display_name, priority = tonumber(t.priority), color = tonumber(t.color), is_default = t.is_default
  })
  respond(ply, ok ~= false, err)
end)

net.Receive("rpg_roles_delete", function(_, ply)
  if not has(ply, "ui.admin.roles.edit") then return respond(ply, false, "Missing permission: ui.admin.roles.edit") end
  local t = net.ReadTable() or {}
  local ok, err = Perms.API.DeleteRole(ply, t.name)
  respond(ply, ok ~= false, err)
end)

net.Receive("rpg_roles_set_perm", function(_, ply)
  if not has(ply, "ui.admin.roles.edit") then return respond(ply, false, "Missing permission: ui.admin.roles.edit") end
  local t = net.ReadTable() or {}
  local ok, err = Perms.API.SetRolePerm(ply, t.roleName, t.permName, t.effect)
  respond(ply, ok ~= false, err)
end)

net.Receive("rpg_roles_remove_perm", function(_, ply)
  if not has(ply, "ui.admin.roles.edit") then return respond(ply, false, "Missing permission: ui.admin.roles.edit") end
  local t = net.ReadTable() or {}
  local ok, err = Perms.API.RemoveRolePerm(ply, t.roleName, t.permName)
  respond(ply, ok ~= false, err)
end)

-- Moderation actions
net.Receive("rpg_moderate_action", function(_, ply)
  if not has(ply, "ui.admin.moderation") and not has(ply, "player.kick") then
    return respond(ply, false, "Missing permission: ui.admin.moderation")
  end
  local t = net.ReadTable() or {}
  local ok, msg = doModeration(ply, t)
  respond(ply, ok, msg)
end)

-- Reports
net.Receive("rpg_reports_submit", function(_, ply)
  -- anyone can submit; gate if desired with 'reports.submit'
  local t = net.ReadTable() or {}
  local targets = istable(t.targets) and t.targets or {}
  if #targets == 0 then
    -- allow empty targets (e.g., RDM with unknown) but preferable at least 1
  end
  createReport(ply, targets, t.description or "")
  respond(ply, true, "Report submitted.")
  net.Start("rpg_reports_updated") net.Send(ply)
end)

net.Receive("rpg_reports_fetch", function(_, ply)
  if not has(ply, "ui.admin.reports") and not has(ply, "ui.admin.moderation") then
    return respond(ply, false, "Missing permission: ui.admin.reports")
  end
  sendReportsList(ply)
end)

net.Receive("rpg_reports_action", function(_, ply)
  if not has(ply, "ui.admin.reports") and not has(ply, "ui.admin.moderation") then
    return respond(ply, false, "Missing permission: ui.admin.reports")
  end
  local t = net.ReadTable() or {}
  local ok, err = actionReport(ply, tonumber(t.id), t.op, t.note)
  respond(ply, ok ~= false, err)
  if ok ~= false then
    sendReportsList(ply)
  end
end)
