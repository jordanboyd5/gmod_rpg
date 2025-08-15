-- lua/rpg_perms/perms_sv.lua
-- Server-only resolver and API
if not SERVER then return end
local DB = assert(RPG_PERMS.DB, "DB not ready")

include("rpg_perms/perms_sh.lua") -- ensure helpers/net names are shared server-side

Perms = Perms or {}
Perms._roles = {}           -- by role_id
Perms._roleByName = {}      -- by role_name
Perms._perms = {}           -- by perm_id
Perms._permByName = {}      -- by name
Perms._rolePerms = {}       -- by role_id => { [permName] = 'allow'|'deny' }
Perms._inherits = {}        -- by role_id => { role_id,... }
Perms._userGrants = {}      -- by steamid64 => { roles = {role_id,...}, overrides = {[permName] = 'allow'|'deny'} }
Perms._effective = {}       -- by steamid64 => { [permName] = 'allow'|'deny' } -- resolved cache
Perms._defaultRoleId = nil

local function nowUTC()
  return os.time()
end

-- === Helpers
local function wildcardMatch(perm, pattern)
  if pattern == "*" then return true end
  if perm == pattern then return true end
  if string.sub(pattern, -2) == ".*" then
    local base = string.sub(pattern, 1, -3)
    return string.sub(perm, 1, #base + 1) == (base .. ".")
  end
  return false
end

-- === Loading
function Perms.ReloadAll(cb)
  -- permissions
  local q1 = DB:query("SELECT id, name FROM permissions")
  function q1:onSuccess(perms)
    Perms._perms, Perms._permByName = {}, {}
    for _, row in ipairs(perms or {}) do
      local id, name = tonumber(row.id), row.name
      Perms._perms[id] = name
      Perms._permByName[name] = id
    end
    -- roles (priority + display_name + color fix)
    local q2 = DB:query("SELECT id, name, display_name, priority, color, is_default, inherits FROM roles")
    function q2:onSuccess(roles)
      Perms._roles, Perms._roleByName, Perms._inherits = {}, {}, {}
      Perms._defaultRoleId = nil
      for _, r in ipairs(roles or {}) do
        local id = tonumber(r.id)
        Perms._roles[id] = {
          id = id,
          name = r.name,
          display_name = r.display_name,
          priority = tonumber(r.priority) or 0,
          color = tonumber(r.color) or 0xFFFFFF,
          is_default = tonumber(r.is_default) or 0,
          inherits = r.inherits
        }
        Perms._roleByName[r.name] = id
        if tonumber(r.is_default) == 1 then
          Perms._defaultRoleId = id
        end
        local ok, arr = pcall(util.JSONToTable, r.inherits or "[]")
        Perms._inherits[id] = ok and arr or {}
      end
      -- map inheritance names->ids if names were used
      for id, arr in pairs(Perms._inherits) do
        local mapped = {}
        for _, maybe in ipairs(arr) do
          if isnumber(maybe) then
            table.insert(mapped, maybe)
          elseif isstring(maybe) and Perms._roleByName[maybe] then
            table.insert(mapped, Perms._roleByName[maybe])
          end
        end
        Perms._inherits[id] = mapped
      end

      -- role_permissions
      local q3 = DB:query([[
        SELECT rp.role_id, p.name AS perm_name, rp.effect
        FROM role_permissions rp
        JOIN permissions p ON p.id = rp.perm_id
      ]])
      function q3:onSuccess(rows)
        Perms._rolePerms = {}
        for _, row in ipairs(rows or {}) do
          local rid = tonumber(row.role_id)
          Perms._rolePerms[rid] = Perms._rolePerms[rid] or {}
          Perms._rolePerms[rid][row.perm_name] = row.effect
        end
        if cb then cb(true) end
      end
      function q3:onError(err)
        print("[RPG_PERMS] load role_permissions failed: " .. tostring(err))
        if cb then cb(false) end
      end
      q3:start()
    end
    function q2:onError(err)
      print("[RPG_PERMS] load roles failed: " .. tostring(err))
      if cb then cb(false) end
    end
    q2:start()
  end
  function q1:onError(err)
    print("[RPG_PERMS] load permissions failed: " .. tostring(err))
    if cb then cb(false) end
  end
  q1:start()
end

-- compute effective map for one user
local function resolveUser(steamid64)
  local grants = Perms._userGrants[steamid64]
  if not grants then
    grants = { roles = {}, overrides = {} }
    Perms._userGrants[steamid64] = grants
  end
  local roles = table.Copy(grants.roles or {})
  if Perms._defaultRoleId and not table.HasValue(roles, Perms._defaultRoleId) then
    table.insert(roles, Perms._defaultRoleId)
  end
  local visited, order = {}, {}
  local function dfs(role_id)
    if visited[role_id] then return end
    visited[role_id] = true
    for _, parent in ipairs(Perms._inherits[role_id] or {}) do
      dfs(parent)
    end
    table.insert(order, role_id)
  end
  for _, rid in ipairs(roles) do dfs(rid) end
  local eff = {}
  for _, rid in ipairs(order) do
    local rp = Perms._rolePerms[rid]
    if rp then
      for perm, effect in pairs(rp) do
        if effect == "deny" then
          eff[perm] = "deny"
        elseif effect == "allow" and eff[perm] ~= "deny" then
          eff[perm] = "allow"
        end
      end
    end
  end
  for perm, effect in pairs(grants.overrides or {}) do
    eff[perm] = effect
  end
  Perms._effective[steamid64] = eff
  return eff
end

-- public: refresh one user (from DB)
function Perms.RefreshUser(steamid64, cb)
  Perms._userGrants[steamid64] = { roles = {}, overrides = {} }
  local sid = DB:escape(tostring(steamid64))
  local q1 = DB:query(string.format([[
    SELECT ur.role_id
    FROM user_roles ur
    WHERE ur.steamid64 = '%s'
      AND (ur.expires_at IS NULL OR ur.expires_at > NOW())
  ]], sid))
  function q1:onSuccess(rows)
    local roles = {}
    for _, r in ipairs(rows or {}) do
      roles[#roles + 1] = tonumber(r.role_id)
    end
    Perms._userGrants[steamid64].roles = roles
    local q2 = DB:query(string.format([[
      SELECT p.name AS perm_name, uo.effect
      FROM user_overrides uo
      JOIN permissions p ON p.id = uo.perm_id
      WHERE uo.steamid64 = '%s'
        AND (uo.expires_at IS NULL OR uo.expires_at > NOW())
    ]], sid))
    function q2:onSuccess(rows2)
      local ov = {}
      for _, r in ipairs(rows2 or {}) do
        ov[r.perm_name] = r.effect
      end
      Perms._userGrants[steamid64].overrides = ov
      resolveUser(steamid64)
      if cb then cb(true) end
    end
    function q2:onError(err)
      print("[RPG_PERMS] overrides load failed: " .. tostring(err))
      if cb then cb(false) end
    end
    q2:start()
  end
  function q1:onError(err)
    print("[RPG_PERMS] roles load failed: " .. tostring(err))
    if cb then cb(false) end
  end
  q1:start()
end

-- Resolve check
function Perms.Has(ply, permName, ctx)
  if not IsValid(ply) then return false, {err="invalid player"} end
  local sid = ply:SteamID64()
  local eff = Perms._effective[sid]
  if not eff then
    Perms.RefreshUser(sid)
    eff = Perms._effective[sid] or {}
  end
  local allow, deny = false, false
  for pattern, effect in pairs(eff) do
    if wildcardMatch(permName, pattern) then
      if effect == "deny" then deny = true end
      if effect == "allow" then allow = true end
    end
  end
  if ctx and ctx.region then
    hook.Run("RPGPermsContextCheck", ply, permName, ctx, function(decision)
      if decision == false then deny = true end
      if decision == true then allow = true end
    end)
  end
  if deny then return false, {source="deny", perm=permName} end
  if allow then return true, {source="allow", perm=permName} end
  return false, {source="none", perm=permName}
end

function Perms.Require(ply, perm, ctx)
  local ok = Perms.Has(ply, perm, ctx)
  if not ok then
    ply:ChatPrint("[Perms] Missing permission: " .. perm)
    return false
  end
  return true
end

-- Hooks
hook.Add("RPGPermsReady", "RPGPerms_LoadCaches", function()
  Perms.ReloadAll(function()
    for _, ply in ipairs(player.GetAll()) do
      Perms.RefreshUser(ply:SteamID64())
    end
  end)
end)

hook.Add("PlayerInitialSpawn", "RPGPerms_OnJoin", function(ply)
  timer.Simple(1, function()
    if not IsValid(ply) then return end
    Perms.RefreshUser(ply:SteamID64())
  end)
end)

-- Debug tools
concommand.Add("perms_debug_check", function(ply, cmd, args)
  if IsValid(ply) then return end
  local sid, perm = args[1], args[2]
  if not sid or not perm then
    print("Usage: perms_debug_check <steamid64> <perm>")
    return
  end
  local fake = { SteamID64 = function() return sid end, IsValid = function() return true end }
  local ok = Perms.Has(fake, perm)
  print(string.format("[Perms] %s => %s", perm, ok and "ALLOW" or "DENY"))
end)

hook.Add("PlayerSay", "RPGPerms_ChatKick", function(ply, text)
  if string.StartWith(string.lower(text), "!kick") then
    if not Perms.Has(ply, "player.kick") then
      ply:ChatPrint("[Perms] You are not allowed to use !kick")
      return ""
    end
  end
end)

concommand.Add("perms_debug_effective", function(ply, cmd, args)
  if IsValid(ply) then return end
  local sid = args[1]
  if not sid then print("Usage: perms_debug_effective <steamid64>") return end
  PrintTable(Perms._effective[sid] or {})
end)

concommand.Add("perms_reload_and_refresh", function(ply, cmd, args)
  if IsValid(ply) then return end
  local sid = args[1]
  if not sid then print("Usage: perms_reload_and_refresh <steamid64>") return end
  Perms.ReloadAll(function()
    Perms.RefreshUser(sid, function() print("[Perms] Reloaded and refreshed " .. sid) end)
  end)
end)
