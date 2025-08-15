-- lua/autorun/server/rpg_chat_sv.lua

-- Safe AddCSLuaFile that checks existence first
local function SafeAdd(path)
  if file.Exists(path, "LUA") then
    AddCSLuaFile(path)
  else
    print(("[RPG_CHAT] Warning: AddCSLuaFile skipped, missing '%s'"):format(path))
  end
end

-- Always ship the shared + main client files
SafeAdd("autorun/sh_rpg_chat.lua")
SafeAdd("rpg_perms/adapters/chat_perms_sh.lua")
SafeAdd("rpg_chat/db.lua")
SafeAdd("autorun/client/rpg_chat_cl.lua")

-- Optional client UIs (only added if present)
SafeAdd("rpg_admin/ui_chat_history_cl.lua")
SafeAdd("rpg_report/ui_report_cl.lua")

-- Require shared files server-side
include("autorun/sh_rpg_chat.lua")
include("rpg_perms/adapters/chat_perms_sh.lua")
include("rpg_chat/db.lua")

-- =======================
-- Net names (server must register)
-- =======================
util.AddNetworkString("rpg_chat_send")
util.AddNetworkString("rpg_chat_broadcast")
util.AddNetworkString("rpg_chat_pm_history_req")
util.AddNetworkString("rpg_chat_pm_history_res")
util.AddNetworkString("rpg_chat_admin_history_req")
util.AddNetworkString("rpg_chat_admin_history_res")
util.AddNetworkString("rpg_chat_mute_req")
util.AddNetworkString("rpg_chat_mute_res")
util.AddNetworkString("rpg_chat_mute_push")
util.AddNetworkString("rpg_chat_recent_buffer_req")
util.AddNetworkString("rpg_chat_recent_buffer_res")
util.AddNetworkString("rpg_report_open")
util.AddNetworkString("rpg_report_player_list_req")
util.AddNetworkString("rpg_report_player_list_res")
util.AddNetworkString("rpg_report_submit")
util.AddNetworkString("rpg_report_submit_res")

-- =======================
-- Rank cache
-- =======================
local TOPRANK = TOPRANK or {} -- steam64 -> rankName
local function getTopRankName(ply)
  local s64 = RPG_CHAT.Steam64(ply)
  if not s64 or s64 == "0" then return "player" end
  local rn = TOPRANK[s64]
  if rn then return rn end
  rn = RPG_PERMS_ADAPTER.TopRankName(ply) or "player"
  TOPRANK[s64] = rn
  return rn
end

hook.Add("PlayerInitialSpawn", "RPG_CHAT_CacheRank", function(ply)
  TOPRANK[RPG_CHAT.Steam64(ply)] = RPG_PERMS_ADAPTER.TopRankName(ply) or "player"
  RPG_CHAT_DB.UpsertSeen(ply)
end)

hook.Add("PlayerDisconnected", "RPG_CHAT_UpdateSeen", function(ply)
  RPG_CHAT_DB.UpsertSeen(ply)
end)

timer.Create("RPG_CHAT_SeenHeartbeat", 600, 0, function()
  for _, ply in ipairs(player.GetAll()) do RPG_CHAT_DB.UpsertSeen(ply) end
end)

-- =======================
-- Anti-spam (token bucket)
-- =======================
local SPAM = {} -- steam64 -> state
local function spamState(ply)
  local s64 = RPG_CHAT.Steam64(ply)
  local st = SPAM[s64]
  if not st then
    st = {
      lastText = "",
      dupUntil = 0,
      strikes = 0,
      cooldownUntil = 0,
      buckets = {
        [RPG_CHAT.TYPE.GLOBAL]  = { tokens = RPG_CHAT.Config.Spam.Global.burst, last = CurTime() },
        [RPG_CHAT.TYPE.WHISPER] = { tokens = RPG_CHAT.Config.Spam.Private.burst, last = CurTime() },
        [RPG_CHAT.TYPE.ADMINS]  = { tokens = RPG_CHAT.Config.Spam.Private.burst, last = CurTime() },
      }
    }
    SPAM[s64] = st
  end
  return st
end

local function allowSpam(ply, chType, text)
  if RPG_PERMS_ADAPTER.IsModPlus(ply) then return true, nil end -- mods+ immune

  local st = spamState(ply)
  local now = CurTime()

  if st.cooldownUntil and now < st.cooldownUntil then
    return false, ("Slow down. You can chat again in %ds."):format(math.ceil(st.cooldownUntil - now))
  end

  -- Duplicate block
  if st.lastText == text and st.dupUntil and now < st.dupUntil then
    return false, "Duplicate message blocked."
  end

  local bucket = st.buckets[chType]
  if not bucket then return true end

  local conf = (chType == RPG_CHAT.TYPE.GLOBAL) and RPG_CHAT.Config.Spam.Global or RPG_CHAT.Config.Spam.Private
  local dt = now - (bucket.last or now)
  bucket.last = now
  bucket.tokens = math.min(conf.burst, (bucket.tokens or conf.burst) + dt * conf.rate)

  if bucket.tokens >= 1 then
    bucket.tokens = bucket.tokens - 1
    st.lastText = text
    st.dupUntil = now + (RPG_CHAT.Config.Spam.DuplicateWindow or 8)
    return true, nil
  end

  -- Trip: escalation
  st.strikes = (st.strikes or 0) + 1
  local esc = RPG_CHAT.Config.Spam.Escalation
  local cd = esc[math.min(st.strikes, #esc)]
  if st.strikes >= 3 then
    -- Auto-mute
    local seconds = RPG_CHAT.Config.Spam.AutoMuteSeconds or 120
    local tar64 = RPG_CHAT.Steam64(ply)
    RPG_CHAT_DB.SetMute(tar64, "0", "Spam Filter", os.time() + seconds, function()
      -- Log a report from spam filter
      local rep = {
        reporter64 = "0",
        target64 = tar64,
        category = "Spam Filter",
        description = ("Auto-mute (%ds) due to repeated spam trips. Last message: %s"):format(seconds, text),
        attached_ids = ""
      }
      RPG_CHAT_DB.InsertReport(rep)
    end)

    -- Notify staff + player
    net.Start("rpg_chat_mute_push")
      net.WriteString(tar64)
      net.WriteString("Spam Filter")
      net.WriteUInt(seconds, 16)
      net.WriteString("Auto-mute due to spam")
    net.Broadcast()

    return false, ("You were auto-muted for %d seconds due to spam."):format(seconds)
  else
    st.cooldownUntil = now + cd
    return false, ("You're sending messages too fast. Wait %ds."):format(cd)
  end
end

local function isMuted(ply, cb)
  local s64 = RPG_CHAT.Steam64(ply)
  RPG_CHAT_DB.GetMute(s64, function(ok, row)
    if not ok or not row then return cb(false) end
    if row.exp and row.exp > os.time() then return cb(true, row) end
    -- Expired -> clean up
    if row.exp and row.exp <= os.time() then
      RPG_CHAT_DB.Unmute(s64)
    end
    cb(false)
  end)
end

-- =======================
-- Broadcasting
-- =======================
local function sendBroadcast(payload, recipients)
  net.Start("rpg_chat_broadcast")
    net.WriteUInt(payload.type, 3)
    net.WriteString(payload.sender64 or "0")
    net.WriteString(payload.senderName or "Console")
    net.WriteString(payload.senderRank or "player")
    net.WriteString(payload.target64 or "0")
    net.WriteString(payload.text or "")
    net.WriteUInt(payload.ts or os.time(), 32)
    net.WriteUInt(payload.dbid or 0, 32)
  if recipients then net.Send(recipients) else net.Broadcast() end
end

-- Send immediately; persist in background (so chat works even if DB is down)
local function broadcastAndPersist(payload, recipients)
  sendBroadcast(payload, recipients)
  RPG_CHAT_DB.InsertMessage({
    type = payload.type,
    sender64 = payload.sender64,
    sender_name = payload.senderName,
    sender_rank = payload.senderRank,
    target64 = (payload.target64 ~= "0") and payload.target64 or nil,
    message = payload.text
  }, function(ok, id)
    -- Optional: could push an ID update; not necessary for MVP.
  end)
end

-- =======================
-- Helpers
-- =======================
local function splitWords(s)
  local t = {}
  for w in string.gmatch(s or "", "%S+") do t[#t+1] = w end
  return t
end

local LAST_PM_TARGET = {} -- steam64 -> last pm partner steam64 for /r
local function setLastPM(a64, b64)
  LAST_PM_TARGET[a64] = b64
end

-- =======================
-- Whisper
-- =======================
local function handleWhisper(ply, text)
  local parts = splitWords(text)
  table.remove(parts, 1) -- strip command
  local targetToken = parts[1]
  if not targetToken then return false, "Usage: /w <name|steamid64> <message>" end
  table.remove(parts, 1)
  local body = table.concat(parts, " ")
  body = RPG_CHAT.TrimTo(RPG_CHAT.ParseEmoji(body), RPG_CHAT.Config.MaxMessageLen)

  -- Resolve target
  local targets = {}
  if string.match(targetToken, "^%d+$") then
    for _, p in ipairs(player.GetAll()) do
      if p:SteamID64() == targetToken then targets = { p } break end
    end
  end
  if #targets == 0 then
    local lower = string.lower(targetToken)
    for _, p in ipairs(player.GetAll()) do
      if string.find(string.lower(p:Nick()), lower, 1, true) then
        table.insert(targets, p)
      end
    end
  end

  if #targets == 0 then
    return false, "No matching player for that name/ID."
  elseif #targets > 1 then
    net.Start("rpg_chat_pm_history_res")
      net.WriteBool(false) -- collision list
      net.WriteUInt(#targets, 8)
      for _, p in ipairs(targets) do
        net.WriteString(p:SteamID64())
        net.WriteString(p:Nick())
        net.WriteString(getTopRankName(p))
      end
    net.Send(ply)
    return false, nil
  end

  local target = targets[1]
  if not IsValid(target) then return false, "That player is no longer online." end

  local allowed, err = allowSpam(ply, RPG_CHAT.TYPE.WHISPER, body)
  if not allowed then return false, err end

  isMuted(ply, function(muted, mrow)
    if muted then
      net.Start("rpg_chat_mute_res")
        net.WriteBool(false)
        net.WriteString(mrow.reason or "You are muted.")
      net.Send(ply)
      return
    end

    local payload = {
      type = RPG_CHAT.TYPE.WHISPER,
      sender64 = RPG_CHAT.Steam64(ply),
      senderName = ply:Nick(),
      senderRank = getTopRankName(ply),
      target64 = RPG_CHAT.Steam64(target),
      text = body,
      ts = os.time()
    }

    -- Set /r pairs then broadcast+persist
    setLastPM(payload.sender64, payload.target64)
    setLastPM(payload.target64, payload.sender64)
    broadcastAndPersist(payload, { ply, target })
  end)

  return true
end

-- =======================
-- Admins channel
-- =======================
local function handleAdmins(ply, text)
  local parts = splitWords(text)
  table.remove(parts, 1)
  local body = table.concat(parts, " ")
  body = RPG_CHAT.TrimTo(RPG_CHAT.ParseEmoji(body), RPG_CHAT.Config.MaxMessageLen)

  if not RPG_PERMS_ADAPTER.IsModPlus(ply) then
    return false, "Only staff can use /admins."
  end

  local allowed, err = allowSpam(ply, RPG_CHAT.TYPE.ADMINS, body)
  if not allowed then return false, err end

  local recipients = {}
  for _, p in ipairs(player.GetAll()) do
    if RPG_PERMS_ADAPTER.IsModPlus(p) then table.insert(recipients, p) end
  end

  local payload = {
    type = RPG_CHAT.TYPE.ADMINS,
    sender64 = RPG_CHAT.Steam64(ply),
    senderName = ply:Nick(),
    senderRank = getTopRankName(ply),
    target64 = "0",
    text = body,
    ts = os.time()
  }

  broadcastAndPersist(payload, recipients)
  return true
end

-- =======================
-- PlayerSay intercept
-- =======================
hook.Add("PlayerSay", "RPG_CHAT_PlayerSay", function(ply, text, team)
  text = tostring(text or "")
  local lower = string.Trim(string.lower(text))

  -- Special-case: !report (open report UI for all players)
  if lower == "!report" or string.StartWith(lower, "!report ") then
    net.Start("rpg_report_open"); net.Send(ply)
    return "" -- don't echo command
  end

  -- /reply
  if string.StartWith(lower, RPG_CHAT.Config.ReplyAlias .. " ") then
    local tar = LAST_PM_TARGET[RPG_CHAT.Steam64(ply)]
    if not tar then return "" end
    local rest = string.Trim(string.sub(text, #RPG_CHAT.Config.ReplyAlias + 2))
    handleWhisper(ply, "/w " .. tar .. " " .. rest)
    return ""
  end

  -- whispers
  do
    local cmd = string.match(lower, "^(%/%w+)")
    if cmd and RPG_CHAT.Config.WhisperAliases[cmd] then
      local ok, err = handleWhisper(ply, text)
      if err then
        net.Start("rpg_chat_broadcast")
          net.WriteUInt(RPG_CHAT.TYPE.SYSTEM, 3)
          net.WriteString(RPG_CHAT.Steam64(ply))
          net.WriteString("System")
          net.WriteString("system")
          net.WriteString("0")
          net.WriteString(err)
          net.WriteUInt(os.time(), 32)
          net.WriteUInt(0, 32)
        net.Send(ply)
      end
      return ""
    end
  end

  -- admins
  do
    local cmd = string.match(lower, "^(%/%w+)")
    if cmd and RPG_CHAT.Config.AdminAliases[cmd] then
      local ok, err = handleAdmins(ply, text)
      if err then
        net.Start("rpg_chat_broadcast")
          net.WriteUInt(RPG_CHAT.TYPE.SYSTEM, 3)
          net.WriteString(RPG_CHAT.Steam64(ply))
          net.WriteString("System")
          net.WriteString("system")
          net.WriteString("0")
          net.WriteString(err)
          net.WriteUInt(os.time(), 32)
          net.WriteUInt(0, 32)
        net.Send(ply)
      end
      return ""
    end
  end

  -- mute/unmute (mods+)
  if string.StartWith(lower, "/mute ") or string.StartWith(lower, "!mute ") then
    if not RPG_PERMS_ADAPTER.IsModPlus(ply) then return "" end
    local parts = splitWords(text); table.remove(parts, 1)
    local who = parts[1]; local minutes = tonumber(parts[2] or "0"); local reason = table.concat(parts, " ", 3)
    if not who then ply:ChatPrint("Usage: /mute <name|steamid64> [minutes] [reason]"); return "" end
    local target
    if who:match("^%d+$") then
      for _,p in ipairs(player.GetAll()) do if p:SteamID64()==who then target=p break end end
    else
      local l = string.lower(who)
      for _,p in ipairs(player.GetAll()) do if string.find(string.lower(p:Nick()), l, 1, true) then target=p break end end
    end
    if not IsValid(target) then ply:ChatPrint("Player not found."); return "" end

    local exp = minutes and minutes>0 and (os.time() + math.floor(minutes*60)) or nil
    RPG_CHAT_DB.SetMute(target:SteamID64(), ply:SteamID64(), reason or "Muted by staff", exp, function()
      net.Start("rpg_chat_mute_push")
        net.WriteString(target:SteamID64())
        net.WriteString(ply:Nick())
        net.WriteUInt(minutes or 0, 16)
        net.WriteString(reason or "")
      net.Broadcast()
    end)
    return ""
  end

  if string.StartWith(lower, "/unmute ") or string.StartWith(lower, "!unmute ") then
    if not RPG_PERMS_ADAPTER.IsModPlus(ply) then return "" end
    local who = string.Trim(string.sub(text, 9))
    local target
    if who:match("^%d+$") then
      for _,p in ipairs(player.GetAll()) do if p:SteamID64()==who then target=p break end end
    else
      local l = string.lower(who)
      for _,p in ipairs(player.GetAll()) do if string.find(string.lower(p:Nick()), l, 1, true) then target=p break end end
    end
    if not IsValid(target) then ply:ChatPrint("Player not found."); return "" end
    RPG_CHAT_DB.Unmute(target:SteamID64(), function()
      net.Start("rpg_chat_mute_push")
        net.WriteString(target:SteamID64())
        net.WriteString(ply:Nick())
        net.WriteUInt(0, 16)
        net.WriteString("Unmuted")
      net.Broadcast()
    end)
    return ""
  end

  -- Unknown slash/bang -> let your project handle it (DO NOT swallow)
  if string.StartWith(lower, "/") or string.StartWith(lower, "!") then
    local handled = hook.Run("RPG_Chat_UnknownSlashCommand", ply, text)
    if handled ~= nil then return "" end
    -- Return nil so other systems can process the command
    return nil
  end

  -- Global chat
  local body = RPG_CHAT.TrimTo(RPG_CHAT.ParseEmoji(text), RPG_CHAT.Config.MaxMessageLen)
  local allowed, err = allowSpam(ply, RPG_CHAT.TYPE.GLOBAL, body)
  if not allowed then if err then ply:ChatPrint(err) end; return "" end

  isMuted(ply, function(muted, mrow)
    if muted then ply:ChatPrint(mrow.reason or "You are muted."); return end

    local payload = {
      type = RPG_CHAT.TYPE.GLOBAL,
      sender64 = RPG_CHAT.SteamID64 and RPG_CHAT.Steam64(ply) or ply:SteamID64(),
      senderName = ply:Nick(),
      senderRank = getTopRankName(ply),
      target64 = "0",
      text = body,
      ts = os.time()
    }
    broadcastAndPersist(payload, nil) -- everyone online
  end)

  return "" -- suppress default chat text
end)

-- Clear /r pairs on disconnect
hook.Add("PlayerDisconnected", "RPG_CHAT_ClearPairs", function(ply)
  LAST_PM_TARGET[RPG_CHAT.Steam64(ply)] = nil
end)

-- =======================
-- PM History
-- =======================
net.Receive("rpg_chat_pm_history_req", function(len, ply)
  local other64 = net.ReadString()
  local page = net.ReadUInt(16)
  local limit = 50
  local offset = (math.max(page, 1) - 1) * limit

  RPG_CHAT_DB.SelectPMHistory(RPG_CHAT.Steam64(ply), other64, limit, offset, function(ok, rows)
    net.Start("rpg_chat_pm_history_res")
      net.WriteBool(true) -- isHistory
      net.WriteUInt(#rows, 16)
      for _, r in ipairs(rows) do
        net.WriteUInt(r.type, 3)
        net.WriteString(r.sender_steamid64 or "0")
        net.WriteString(r.sender_name or "Unknown")
        net.WriteString(r.sender_rank or "player")
        net.WriteString(r.target_steamid64 or "0")
        net.WriteString(r.message or "")
        net.WriteUInt(r.ts or 0, 32)
        net.WriteUInt(r.id or 0, 32)
      end
    net.Send(ply)
  end)
end)

-- =======================
-- Admin history
-- =======================
net.Receive("rpg_chat_admin_history_req", function(_, ply)
  if not RPG_PERMS_ADAPTER.IsModPlus(ply) then return end

  local params = {}
  params.type = net.ReadUInt(3); if params.type == 0 then params.type = nil end
  params.sender64 = net.ReadString(); if params.sender64 == "" then params.sender64 = nil end
  params.target64 = net.ReadString(); if params.target64 == "" then params.target64 = nil end
  params.contains = net.ReadString(); if params.contains == "" then params.contains = nil end
  params.since = net.ReadUInt(32); if params.since == 0 then params.since = nil end
  params.until_ts = net.ReadUInt(32); if params.until_ts == 0 then params.until_ts = nil end
  params.page = net.ReadUInt(16)
  params.limit = 50
  params.offset = (math.max(params.page, 1) - 1) * params.limit

  RPG_CHAT_DB.SelectAdminHistory(params, function(ok, rows)
    net.Start("rpg_chat_admin_history_res")
      net.WriteUInt(#rows, 16)
      for _, r in ipairs(rows) do
        net.WriteUInt(r.type, 3)
        net.WriteString(r.sender_steamid64 or "0")
        net.WriteString(r.sender_name or "Unknown")
        net.WriteString(r.sender_rank or "player")
        net.WriteString(r.target_steamid64 or "0")
        net.WriteString(r.message or "")
        net.WriteUInt(r.ts or 0, 32)
        net.WriteUInt(r.id or 0, 32)
      end
    net.Send(ply)
  end)
end)

-- =======================
-- Reports UI plumbing
-- =======================
concommand.Add("rpg_open_report", function(ply) -- helper for testing; actual trigger via !report
  net.Start("rpg_report_open"); net.Send(ply)
end)

net.Receive("rpg_report_player_list_req", function(_, ply)
  local online = player.GetAll()
  table.sort(online, function(a,b) return string.lower(a:Nick()) < string.lower(b:Nick()) end)
  local exclude = {}
  for _, p in ipairs(online) do exclude[p:SteamID64()] = true end

  local function sendList(recent)
    net.Start("rpg_report_player_list_res")
      net.WriteUInt(#online, 16)
      for _, p in ipairs(online) do
        net.WriteString(p:SteamID64()); net.WriteString(p:Nick()); net.WriteBool(true)
      end
      net.WriteUInt(#recent, 16)
      for _, r in ipairs(recent) do
        net.WriteString(r.steamid64 or "0"); net.WriteString(r.last_name or "Unknown"); net.WriteBool(false)
      end
    net.Send(ply)
  end

  RPG_CHAT_DB.FetchRecentPlayers(exclude, function(ok, recent) sendList(recent or {}) end)
end)

net.Receive("rpg_report_submit", function(_, ply)
  local target64 = net.ReadString()
  local category = net.ReadString()
  local description = net.ReadString()
  local attachedIds = net.ReadString()

  local rep = {
    reporter64 = RPG_CHAT.Steam64(ply),
    target64 = target64,
    category = category,
    description = description,
    attached_ids = attachedIds
  }
  RPG_CHAT_DB.InsertReport(rep, function(ok, id)
    net.Start("rpg_report_submit_res")
      net.WriteBool(ok and true or false)
      net.WriteUInt(tonumber(id or 0), 32)
    net.Send(ply)
  end)
end)

-- =======================
-- Misc
-- =======================
-- Server stubs (no receive body needed)
net.Receive("rpg_chat_broadcast", function() end)
