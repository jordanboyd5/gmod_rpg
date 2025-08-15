-- lua/rpg_chat/db.lua
-- Chat DB layer for mySQLOO. We DO NOT create a new connection.
-- We attach to an existing mySQLOO database object you already use.

-- Note: mysqloo might not be require()'d yet when this file loads.
-- Do NOT index mysqloo directly without checking for nil.

RPG_CHAT_DB = RPG_CHAT_DB or {}
RPG_CHAT_DB._db = RPG_CHAT_DB._db or rawget(_G, "RPG_DB") -- adopt existing global if present

-- === Safe status helpers (work even if mysqloo is not loaded yet) ===
local function dbStatus(db)
  if not db then return -1 end
  local ok, st = pcall(function() return db:status() end)
  if not ok then return -1 end
  return st
end

local function statusIsConnected(db)
  local st = dbStatus(db)
  -- mysqloo.DATABASE_CONNECTED == 2, but mysqloo may not be loaded yet.
  return st == 2 or (_G.mysqloo and st == mysqloo.DATABASE_CONNECTED)
end

local function statusIsConnecting(db)
  local st = dbStatus(db)
  -- mysqloo.DATABASE_CONNECTING == 1
  return st == 1 or (_G.mysqloo and st == mysqloo.DATABASE_CONNECTING)
end

local function okDB()
  return statusIsConnected(RPG_CHAT_DB._db)
end

-- Public: call this from your own DB bootstrap (recommended)
function RPG_CHAT_DB.SetConnection(db)
  RPG_CHAT_DB._db = db
  if SERVER then timer.Simple(0, RPG_CHAT_DB.Init) end
end

-- ====== Auto-attach helpers (no credentials needed) ======
local function _isDB(obj)
  if not obj then return false end
  local ok, _ = pcall(function() return obj:status() end)
  return ok
end

-- Attach by global name, e.g. rpg_chat_db_attach RPG_DB
function RPG_CHAT_DB.AttachFromGlobal(varname)
  local obj = rawget(_G, varname)
  if not _isDB(obj) then
    print(("[RPG_CHAT][DB] Global '%s' is not a mySQLOO DB object."):format(tostring(varname)))
    return false
  end
  RPG_CHAT_DB._db = obj
  print(("[RPG_CHAT][DB] Attached to global '%s'"):format(varname))
  timer.Simple(0, RPG_CHAT_DB.Init)
  return true
end

-- Heuristic scan of globals for a connected mySQLOO DB (last resort)
function RPG_CHAT_DB.TryAutoAttach()
  if okDB() or statusIsConnecting(RPG_CHAT_DB._db) then return true end

  -- Priority 1: a global named RPG_DB (common in projects)
  local g = rawget(_G, "RPG_DB")
  if _isDB(g) and statusIsConnected(g) then
    return RPG_CHAT_DB.AttachFromGlobal("RPG_DB")
  end

  -- Priority 2: scan _G for any connected mySQLOO DB
  for k, v in pairs(_G) do
    if _isDB(v) and statusIsConnected(v) then
      RPG_CHAT_DB._db = v
      print(("[RPG_CHAT][DB] Auto-attached to global '%s' (connected)."):format(tostring(k)))
      timer.Simple(0, RPG_CHAT_DB.Init)
      return true
    end
  end

  return false
end

-- ====== DDL (sequential) ======
local CREATES = {
  [[
    CREATE TABLE IF NOT EXISTS rpg_chat_messages(
      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
      type TINYINT NOT NULL,
      sender_steamid64 BIGINT UNSIGNED NOT NULL,
      sender_name VARCHAR(64) NOT NULL,
      sender_rank VARCHAR(32) NOT NULL,
      target_steamid64 BIGINT UNSIGNED NULL,
      message TEXT NOT NULL,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY(id),
      KEY idx_created_at (created_at),
      KEY idx_type_time (type, created_at),
      KEY idx_sender_time (sender_steamid64, created_at),
      KEY idx_target_time (target_steamid64, created_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
  ]],
  [[
    CREATE TABLE IF NOT EXISTS rpg_chat_mutes(
      steamid64 BIGINT UNSIGNED NOT NULL,
      muted_by_steamid64 BIGINT UNSIGNED NOT NULL,
      reason VARCHAR(255) NULL,
      expires_at TIMESTAMP NULL,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY(steamid64),
      KEY idx_expires (expires_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
  ]],
  [[
    CREATE TABLE IF NOT EXISTS rpg_players_seen(
      steamid64 BIGINT UNSIGNED NOT NULL,
      last_name VARCHAR(64) NOT NULL,
      last_rank VARCHAR(32) NOT NULL,
      last_seen_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      PRIMARY KEY(steamid64),
      KEY idx_last_seen (last_seen_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
  ]],
  [[
    CREATE TABLE IF NOT EXISTS rpg_reports(
      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
      reporter_steamid64 BIGINT UNSIGNED NOT NULL,
      target_steamid64 BIGINT UNSIGNED NOT NULL,
      category VARCHAR(32) NULL,
      description TEXT NOT NULL,
      attached_message_ids TEXT NULL,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      status ENUM('open','triage','closed') NOT NULL DEFAULT 'open',
      PRIMARY KEY(id),
      KEY idx_target (target_steamid64, created_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
  ]],
}

local _initAttempts = 0
local _retentionTimerName = "RPG_CHAT_DB_Retention"

local function logActiveSchema(cb)
  if not okDB() then
    print("[RPG_CHAT][DB] Not connected (cannot query active schema).")
    if cb then cb(false) end
    return
  end
  local q = RPG_CHAT_DB._db:query("SELECT DATABASE() AS db, VERSION() AS v")
  function q:onSuccess(data)
    local row = data and data[1] or {}
    print(string.format("[RPG_CHAT][DB] Active schema: %s | MySQL version: %s", tostring(row.db), tostring(row.v)))
    if cb then cb(true, row.db) end
  end
  function q:onError(err)
    print("[RPG_CHAT][DB] Failed to fetch active schema: " .. tostring(err))
    if cb then cb(false) end
  end
  q:start()
end

local function runSequentialCreates(i)
  if i > #CREATES then
    print("[RPG_CHAT][DB] Tables ensured.")
    if not timer.Exists(_retentionTimerName) then
      timer.Create(_retentionTimerName, 3600, 0, function()
        if not okDB() then return end
        local days = tonumber(RPG_CHAT.Config.RetentionDays) or 7
        local del = RPG_CHAT_DB._db:prepare("DELETE FROM rpg_chat_messages WHERE created_at < NOW() - INTERVAL ? DAY")
        del:setNumber(1, days)
        function del:onError(err) print("[RPG_CHAT][DB] Retention error: " .. tostring(err)) end
        del:start()

        local prune = RPG_CHAT_DB._db:query("DELETE FROM rpg_chat_mutes WHERE expires_at IS NOT NULL AND expires_at < NOW() - INTERVAL 30 DAY")
        function prune:onError(err) print("[RPG_CHAT][DB] Mutes prune error: " .. tostring(err)) end
        prune:start()
      end)
    end
    return
  end

  local sql = CREATES[i]
  local q = RPG_CHAT_DB._db:query(sql)
  function q:onSuccess()
    print(string.format("[RPG_CHAT][DB] CREATE %d/%d OK", i, #CREATES))
    runSequentialCreates(i + 1)
  end
  function q:onError(err)
    print(string.format("[RPG_CHAT][DB] CREATE %d/%d ERROR: %s", i, #CREATES, tostring(err)))
    runSequentialCreates(i + 1) -- continue
  end
  q:start()
end

function RPG_CHAT_DB.Init()
  if not RPG_CHAT_DB._db then
    _initAttempts = _initAttempts + 1
    -- Try auto-attach before retrying
    if RPG_CHAT_DB.TryAutoAttach() then return end
    print(("[RPG_CHAT][DB] No DB object yet (attempt %d). Retrying in 5s..."):format(_initAttempts))
    timer.Create("RPG_CHAT_DB_InitRetry", 5, 1, RPG_CHAT_DB.Init)
    return
  end

  if not okDB() then
    _initAttempts = _initAttempts + 1
    print(("[RPG_CHAT][DB] DB not connected yet (attempt %d). Retrying in 5s..."):format(_initAttempts))
    timer.Create("RPG_CHAT_DB_InitRetry", 5, 1, RPG_CHAT_DB.Init)
    return
  end

  print("[RPG_CHAT][DB] Connected. Checking active schema…")
  logActiveSchema(function()
    print("[RPG_CHAT][DB] Ensuring tables sequentially…")
    runSequentialCreates(1)
  end)
end

-- ===== Public query helpers =====
function RPG_CHAT_DB.InsertMessage(row, cb)
  if not okDB() then
    print("[RPG_CHAT][DB] InsertMessage skipped: DB not connected")
    if cb then cb(false) end
    return
  end
  local st = RPG_CHAT_DB._db:prepare([[
    INSERT INTO rpg_chat_messages(type, sender_steamid64, sender_name, sender_rank, target_steamid64, message)
    VALUES(?,?,?,?,?,?)
  ]])
  st:setNumber(1, row.type)
  st:setString(2, row.sender64)
  st:setString(3, row.sender_name)
  st:setString(4, row.sender_rank)
  if row.target64 and row.target64 ~= "0" then st:setString(5, row.target64) else st:setNull(5) end
  st:setString(6, row.message)
  function st:onSuccess() if cb then cb(true, self:lastInsert()) end end
  function st:onError(err) print("[RPG_CHAT][DB] InsertMessage error: " .. tostring(err)); if cb then cb(false) end end
  st:start()
end

function RPG_CHAT_DB.SelectPMHistory(a64, b64, limit, offset, cb)
  if not okDB() then return cb and cb(false, {}) end
  local st = RPG_CHAT_DB._db:prepare([[
    SELECT id, type, sender_steamid64, sender_name, sender_rank, target_steamid64, message, UNIX_TIMESTAMP(created_at) AS ts
    FROM rpg_chat_messages
    WHERE type = ? AND
      ((sender_steamid64 = ? AND target_steamid64 = ?) OR (sender_steamid64 = ? AND target_steamid64 = ?))
    ORDER BY id DESC
    LIMIT ? OFFSET ?
  ]])
  st:setNumber(1, RPG_CHAT.TYPE.WHISPER)
  st:setString(2, a64) st:setString(3, b64)
  st:setString(4, b64) st:setString(5, a64)
  st:setNumber(6, limit or 50)
  st:setNumber(7, offset or 0)
  function st:onSuccess(data) cb(true, data or {}) end
  function st:onError(err) print("[RPG_CHAT][DB] SelectPMHistory error: " .. tostring(err)); cb(false, {}) end
  st:start()
end

function RPG_CHAT_DB.SelectAdminHistory(params, cb)
  if not okDB() then return cb and cb(false, {}) end
  local where, args = {"1=1"}, {}
  local function add(cond, val) where[#where+1] = cond; args[#args+1] = val end
  if params.type then add("type = ?", params.type) end
  if params.sender64 then add("sender_steamid64 = ?", params.sender64) end
  if params.target64 then add("target_steamid64 = ?", params.target64) end
  if params.contains then add("message LIKE ?", "%" .. params.contains .. "%") end
  if params.since then add("created_at >= FROM_UNIXTIME(?)", params.since) end
  if params.until_ts then add("created_at <= FROM_UNIXTIME(?)", params.until_ts) end

  local sql = [[
    SELECT id, type, sender_steamid64, sender_name, sender_rank, target_steamid64, message, UNIX_TIMESTAMP(created_at) AS ts
    FROM rpg_chat_messages
    WHERE ]] .. table.concat(where, " AND ") .. [[
    ORDER BY id DESC
    LIMIT ? OFFSET ?
  ]]
  local st = RPG_CHAT_DB._db:prepare(sql)
  local idx = 1
  for _, v in ipairs(args) do
    if isnumber(v) then st:setNumber(idx, v) else st:setString(idx, v) end
    idx = idx + 1
  end
  st:setNumber(idx, params.limit or 50)
  st:setNumber(idx+1, params.offset or 0)
  function st:onSuccess(data) cb(true, data or {}) end
  function st:onError(err) print("[RPG_CHAT][DB] SelectAdminHistory error: " .. tostring(err)); cb(false, {}) end
  st:start()
end

function RPG_CHAT_DB.SetMute(target64, by64, reason, expiresAtUnix, cb)
  if not okDB() then return cb and cb(false) end
  local st = RPG_CHAT_DB._db:prepare([[
    REPLACE INTO rpg_chat_mutes(steamid64, muted_by_steamid64, reason, expires_at)
    VALUES(?, ?, ?, IF(? IS NULL, NULL, FROM_UNIXTIME(?)))
  ]])
  st:setString(1, target64)
  st:setString(2, by64)
  st:setString(3, reason or "")
  if expiresAtUnix then st:setNumber(4, expiresAtUnix) st:setNumber(5, expiresAtUnix) else st:setNull(4) st:setNull(5) end
  function st:onSuccess() if cb then cb(true) end end
  function st:onError(err) print("[RPG_CHAT][DB] SetMute error: " .. tostring(err)); if cb then cb(false) end end
  st:start()
end

function RPG_CHAT_DB.GetMute(target64, cb)
  if not okDB() then return cb and cb(false, nil) end
  local st = RPG_CHAT_DB._db:prepare([[
    SELECT steamid64, muted_by_steamid64, reason, UNIX_TIMESTAMP(expires_at) AS exp
    FROM rpg_chat_mutes
    WHERE steamid64 = ?
  ]])
  st:setString(1, target64)
  function st:onSuccess(data) cb(true, data and data[1] or nil) end
  function st:onError(err) print("[RPG_CHAT][DB] GetMute error: " .. tostring(err)); cb(false, nil) end
  st:start()
end

function RPG_CHAT_DB.Unmute(target64, cb)
  if not okDB() then return cb and cb(false) end
  local st = RPG_CHAT_DB._db:prepare("DELETE FROM rpg_chat_mutes WHERE steamid64 = ?")
  st:setString(1, target64)
  function st:onSuccess() if cb then cb(true) end end
  function st:onError(err) print("[RPG_CHAT][DB] Unmute error: " .. tostring(err)); if cb then cb(false) end end
  st:start()
end

function RPG_CHAT_DB.UpsertSeen(ply)
  if not okDB() or not IsValid(ply) then return end
  local st = RPG_CHAT_DB._db:prepare([[
    REPLACE INTO rpg_players_seen(steamid64, last_name, last_rank, last_seen_at)
    VALUES(?, ?, ?, NOW())
  ]])
  st:setString(1, ply:SteamID64())
  st:setString(2, string.sub(ply:Nick() or "", 1, 64))
  st:setString(3, string.sub((RPG_PERMS_ADAPTER.TopRankName(ply) or "player"),1,32))
  st:start()
end

function RPG_CHAT_DB.FetchRecentPlayers(exclude64Set, cb)
  if not okDB() then return cb and cb(false, {}) end
  local st = RPG_CHAT_DB._db:query([[
    SELECT steamid64, last_name, last_rank, UNIX_TIMESTAMP(last_seen_at) AS last_seen
    FROM rpg_players_seen
    WHERE last_seen_at >= NOW() - INTERVAL 24 HOUR
    ORDER BY last_name ASC
  ]])
  function st:onSuccess(data)
    local out = {}
    for _, row in ipairs(data or {}) do
      if not exclude64Set[row.steamid64] then table.insert(out, row) end
    end
    cb(true, out)
  end
  function st:onError(err) print("[RPG_CHAT][DB] FetchRecentPlayers error: " .. tostring(err)); cb(false, {}) end
  st:start()
end

function RPG_CHAT_DB.InsertReport(report, cb)
  if not okDB() then return cb and cb(false) end
  local st = RPG_CHAT_DB._db:prepare([[
    INSERT INTO rpg_reports(reporter_steamid64, target_steamid64, category, description, attached_message_ids)
    VALUES(?,?,?,?,?)
  ]])
  st:setString(1, report.reporter64)
  st:setString(2, report.target64)
  st:setString(3, report.category or "")
  st:setString(4, report.description or "")
  st:setString(5, report.attached_ids or "")
  function st:onSuccess() if cb then cb(true, self:lastInsert()) end end
  function st:onError(err) print("[RPG_CHAT][DB] InsertReport error: " .. tostring(err)); if cb then cb(false) end end
  st:start()
end

-- ===== Bootstrapping / debug =====
if SERVER then
  hook.Add("Initialize", "RPG_CHAT_DB_Init", function()
    timer.Simple(0, RPG_CHAT_DB.Init)
  end)

  concommand.Add("rpg_chat_db_status", function(ply)
    if IsValid(ply) then return end
    if not RPG_CHAT_DB._db then
      print("[RPG_CHAT][DB] No connection object set. Use rpg_chat_db_attach <GlobalName> or call RPG_CHAT_DB.SetConnection(db).")
      return
    end
    local st = dbStatus(RPG_CHAT_DB._db)
    local statusStr =
      (st == 2 and "CONNECTED") or
      (st == 1 and "CONNECTING") or
      (st == 0 and "NOT_CONNECTED") or
      ("UNKNOWN(" .. tostring(st) .. ")")
    print("[RPG_CHAT][DB] Status: " .. statusStr)
    logActiveSchema()
  end)

  -- Manually attach by global name, e.g.: rpg_chat_db_attach RPG_DB
  concommand.Add("rpg_chat_db_attach", function(ply, _, args)
    if IsValid(ply) then return end
    local name = args[1]
    if not name or name == "" then
      print("Usage: rpg_chat_db_attach <GlobalVarName>")
      return
    end
    RPG_CHAT_DB.AttachFromGlobal(name)
  end)

  -- Force create tables again
  concommand.Add("rpg_chat_db_init_now", function(ply)
    if IsValid(ply) then return end
    RPG_CHAT_DB.Init()
  end)

  -- Background: keep trying to auto-attach until connected
  timer.Create("RPG_CHAT_DB_AutoAttach", 5, 0, function()
    if okDB() or statusIsConnecting(RPG_CHAT_DB._db) then return end
    RPG_CHAT_DB.TryAutoAttach()
  end)
end
