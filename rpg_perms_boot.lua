if not SERVER then return end

if SERVER then
  -- Ship client code immediately on map load (not gated on DB)
  AddCSLuaFile("rpg_perms/perms_sh.lua")
  AddCSLuaFile("rpg_perms/ui_cl.lua")
end

-- ==== CONFIG ====
local CFG = {
  host = "127.0.0.1",
  username = "gmod",
  password = "S3cure!Long!Password",
  database = "gmod",
  port = 3306,
  module = "mysqloo", -- ensure the binary is installed
  migrations_dir = "rpg_perms/migrations"
}

-- Expose a tiny namespace
RPG_PERMS = RPG_PERMS or {}
RPG_PERMS.DB = RPG_PERMS.DB or nil
RPG_PERMS.Ready = false

-- Utility: read file(s) from data/ (migrations live in data to make editing easy)
local function ReadDataFile(path)
  local full = "data/" .. path
  if not file.Exists(path, "DATA") then return nil end
  return file.Read(path, "DATA")
end

local function ListDataDir(path)
  if not file.IsDir(path, "DATA") then return {} end
  return file.Find(path .. "/*", "DATA")
end

-- Connect to DB
local function Connect(cb)
  require(CFG.module)
  local db = mysqloo.connect(CFG.host, CFG.username, CFG.password, CFG.database, CFG.port)

  function db:onConnected()
    print("[RPG_PERMS] MySQL connected")
    RPG_PERMS.DB = db
    if cb then cb(true) end
  end

  function db:onConnectionFailed(err)
    print("[RPG_PERMS] MySQL connection FAILED: " .. tostring(err))
    if cb then cb(false, err) end
  end

  db:connect()
end

-- Run migrations in lexical order if not applied
local function RunMigrations(done)
  local files = ListDataDir(CFG.migrations_dir)
  table.sort(files)
  local pending = {}

  -- load applied ids
  local applied = {}
  local q = RPG_PERMS.DB:query("SELECT id FROM schema_version")
  function q:onSuccess(data)
    for _, row in ipairs(data or {}) do
      applied[tonumber(row.id)] = true
    end

    for _, f in ipairs(files) do
      local id = tonumber(string.match(f, "^(%d+)_"))
      if id and not applied[id] then
        table.insert(pending, f)
      end
    end

    local function step(i)
      if i > #pending then
        print("[RPG_PERMS] Migrations complete")
        done(true)
        return
      end
      local fname = pending[i]
      local sql = ReadDataFile(CFG.migrations_dir .. "/" .. fname)
      if not sql then
        print("[RPG_PERMS] Migration file missing: " .. fname)
        return step(i + 1)
      end
      local q2 = RPG_PERMS.DB:query(sql)
      function q2:onSuccess()
        print("[RPG_PERMS] Applied migration: " .. fname)
        step(i + 1)
      end
      function q2:onError(err)
        print("[RPG_PERMS] Migration FAILED (" .. fname .. "): " .. tostring(err))
        done(false, err)
      end
      q2:start()
    end

    step(1)
  end
  function q:onError(err)
    print("[RPG_PERMS] Unable to read schema_version: " .. tostring(err))
    done(false, err)
  end
  q:start()
end

-- Load the module (below) after DB & migrations
local function Bootstrap()
  -- Shared first
  AddCSLuaFile("rpg_perms/perms_sh.lua")
  include("rpg_perms/perms_sh.lua")

  -- Server
  include("rpg_perms/perms_sv.lua")
  include("rpg_perms/api_sv.lua")

  -- Client files
  AddCSLuaFile("rpg_perms/ui_cl.lua")

  print("[RPG_PERMS] Bootstrap complete")
  RPG_PERMS.Ready = true
  hook.Run("RPGPermsReady")
end

-- === NEW: Wire our existing DB connection into the chat system ===
-- We wait for your perms bootstrap to finish, then hand the same mySQLOO
-- connection to the chat module. No new connection or credentials are needed.
hook.Add("RPGPermsReady", "RPG_CHAT_AttachDB", function()
  -- If the chat DB module is already loaded, attach immediately.
  if RPG_PERMS.DB and RPG_CHAT_DB and RPG_CHAT_DB.SetConnection then
    RPG_CHAT_DB.SetConnection(RPG_PERMS.DB)
    print("[RPG_CHAT] Attached to RPG_PERMS.DB")
    return
  end

  -- Otherwise, retry a few times in case chat files load slightly later.
  local attempts = 0
  timer.Create("RPG_CHAT_AttachDB_Retry", 1, 10, function()
    attempts = attempts + 1
    if RPG_PERMS.DB and RPG_CHAT_DB and RPG_CHAT_DB.SetConnection then
      RPG_CHAT_DB.SetConnection(RPG_PERMS.DB)
      print("[RPG_CHAT] Attached to RPG_PERMS.DB (retry " .. attempts .. ")")
      timer.Remove("RPG_CHAT_AttachDB_Retry")
    elseif attempts == 10 then
      print("[RPG_CHAT] Could not attach DB yet; ensure chat files are loading (autorun) and try a map reload.")
    end
  end)
end)

hook.Add("Initialize", "RPG_PERMS_Init", function()
  Connect(function(ok)
    if not ok then return end
    RunMigrations(function(ok2)
      if not ok2 then return end
      Bootstrap()
    end)
  end)
end)
