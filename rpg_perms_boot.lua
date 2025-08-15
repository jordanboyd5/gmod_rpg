-- START /lua/autorun/server/rpg_perms_boot.lua
if not SERVER then return end

----------------------------------------------------------------
-- Config (server-only; not sent to clients)
----------------------------------------------------------------
local CFG = {
  host = "127.0.0.1",
  username = "gmod",
  password = "S3cure!Long!Password",
  database = "gmod",
  port = 3306,
  module = "mysqloo",
  migrations_dir = "rpg_perms/migrations", -- DATA only (proprietary)
  connect_retry_base = 2,  -- seconds (exponential backoff)
  connect_retry_max  = 60, -- seconds
}

-- Per-server identifier so rows can be traced to the specific game server.
-- e.g. set +rpg_server_id 1 on box A, 2 on box B, etc.
CreateConVar("rpg_server_id", "1", FCVAR_ARCHIVE, "Identifier for this gameserver instance")
local function GetServerID() return GetConVar("rpg_server_id"):GetInt() or 1 end

----------------------------------------------------------------
-- Optional client files (UI only); no logic is shipped
----------------------------------------------------------------
AddCSLuaFile("rpg_perms/perms_sh.lua")
AddCSLuaFile("rpg_perms/ui_cl.lua")
AddCSLuaFile("autorun/sh_rpg_chat.lua")      -- shared constants/types only
AddCSLuaFile("rpg_admin/ui_chat_history_cl.lua")
AddCSLuaFile("rpg_report/ui_report_cl.lua")

----------------------------------------------------------------
-- Net strings (server-only registration)
----------------------------------------------------------------
local NETS = {
  "rpg_chat_send",
  "rpg_chat_broadcast",
  "rpg_chat_pm_history_req","rpg_chat_pm_history_res",
  "rpg_chat_admin_history_req","rpg_chat_admin_history_res",
  "rpg_chat_mute_req","rpg_chat_mute_res","rpg_chat_mute_push",
  "rpg_report_open","rpg_report_player_list_req","rpg_report_player_list_res",
  "rpg_report_submit","rpg_report_submit_res",
  "rpg_chat_recent_buffer_req","rpg_chat_recent_buffer_res",
}
for _, n in ipairs(NETS) do util.AddNetworkString(n) end

----------------------------------------------------------------
-- DB bootstrap (mysqloo)
----------------------------------------------------------------
RPG_PERMS = RPG_PERMS or {}
RPG_PERMS.DB = RPG_PERMS.DB or nil
RPG_PERMS.Ready = false

local function withQuery(db, sql, onOk, onErr)
  local q = db:query(sql)
  function q:onSuccess(data) if onOk then onOk(data or {}) end end
  function q:onError(err) if onErr then onErr(tostring(err)) else print("[DB] ERROR: "..tostring(err).." SQL="..sql) end end
  q:start()
end

local function runSeries(db, sqlList, done)
  local i = 0
  local function step()
    i = i + 1
    if i > #sqlList then if done then done(true) end return end
    withQuery(db, sqlList[i], step, function(err)
      print("[DB] Series failed: "..tostring(err))
      if done then done(false, err) end
    end)
  end
  step()
end

local function ensureSchemaVersion(db, cb)
  withQuery(db, [[
    CREATE TABLE IF NOT EXISTS schema_version (
      id INT PRIMARY KEY,
      applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  ]], function() cb(true) end, function(err) cb(false, err) end)
end

local function listMigrations()
  if not file.IsDir(CFG.migrations_dir, "DATA") then return {} end
  local files = file.Find(CFG.migrations_dir .. "/*.sql", "DATA")
  table.sort(files) -- lexical order
  return files
end

local function readDataFile(path)
  if not file.Exists(path, "DATA") then return nil end
  return file.Read(path, "DATA")
end

local function runMigrations(db, cb)
  ensureSchemaVersion(db, function(ok, err)
    if not ok then cb(false, err) return end

    withQuery(db, "SELECT id FROM schema_version", function(rows)
      local applied = {}
      for _, r in ipairs(rows) do applied[tonumber(r.id)] = true end

      local pending = {}
      for _, fname in ipairs(listMigrations()) do
        local id = tonumber(string.match(fname, "^(%d+)_"))
        if id and not applied[id] then table.insert(pending, {id = id, fname = fname}) end
      end
      table.sort(pending, function(a,b) return a.id < b.id end)

      local function step(k)
        if k > #pending then cb(true) return end
        local p = pending[k]
        local sql = readDataFile(CFG.migrations_dir .. "/" .. p.fname)
        if not sql then
          print("[DB] Missing migration file: " .. p.fname .. " (skipping)")
          return step(k + 1)
        end
        runSeries(db, {sql, ("INSERT INTO schema_version (id) VALUES (%d)"):format(p.id)}, function(ok2, e2)
          if ok2 then
            print("[DB] Applied migration: " .. p.fname)
            step(k + 1)
          else
            cb(false, e2)
          end
        end)
      end
      step(1)
    end, function(e) cb(false, e) end)
  end)
end

local function applySessionSettings(db)
  -- Strict, portable session + server_id tagging (affects INSERT triggers if you use them)
  runSeries(db, {
    "SET time_zone = '+00:00'",
    "SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci",
    "SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'",
    ("SET @rpg_server_id = %d"):format(GetServerID()),
  }, function(ok, err)
    if ok then
      print(("[DB] Session ready (UTC, utf8mb4, strict, server_id=%d)"):format(GetServerID()))
    else
      print("[DB] Session init FAILED: " .. tostring(err))
    end
  end)
end

local retryTimer = "RPG_PERMS_DB_Retry"
local function connectMySQL()
  local backoff = CFG.connect_retry_base

  local function attempt()
    local ok, err = pcall(require, CFG.module)
    if not ok then
      print("[RPG_PERMS] Failed to load module '"..CFG.module.."': "..tostring(err))
      timer.Simple(math.min(backoff, CFG.connect_retry_max), attempt)
      backoff = math.min(backoff * 2, CFG.connect_retry_max)
      return
    end

    local db = mysqloo.connect(CFG.host, CFG.username, CFG.password, CFG.database, CFG.port)

    function db:onConnected()
      print("[RPG_PERMS] MySQL connected")
      RPG_PERMS.DB = db
      applySessionSettings(db)
      runMigrations(db, function(mok, merr)
        if not mok then
          print("[RPG_PERMS] Migrations FAILED: "..tostring(merr))
          return
        end
        include("rpg_perms/perms_sh.lua") -- define shared enums/ids server-side too
        include("rpg_perms/perms_sv.lua")
        include("rpg_perms/api_sv.lua")

        -- If your chat system offers an attach function, wire it up here (no client code needed)
        if RPG_CHAT_DB and RPG_CHAT_DB.SetConnection then
          RPG_CHAT_DB.SetConnection(db)
          print("[RPG_CHAT] Attached to RPG_PERMS.DB")
        end

        RPG_PERMS.Ready = true
        hook.Run("RPGPermsReady", db)
      end)
    end

    function db:onConnectionFailed(e)
      print("[RPG_PERMS] MySQL connection FAILED: "..tostring(e))
      timer.Simple(math.min(backoff, CFG.connect_retry_max), attempt)
      backoff = math.min(backoff * 2, CFG.connect_retry_max)
    end

    db:connect()
  end

  attempt()
end

hook.Add("Initialize", "RPG_PERMS_Init", connectMySQL)
-- END /lua/autorun/server/rpg_perms_boot.lua
