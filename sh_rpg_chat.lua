if SERVER then AddCSLuaFile() end

RPG_CHAT = RPG_CHAT or {}
RPG_CHAT.Version = "0.1.0"

-- Channel types
RPG_CHAT.TYPE = {
  GLOBAL = 1,
  WHISPER = 2,
  ADMINS  = 3,
  SYSTEM  = 4
}

-- Net strings
local NETS = {
  "rpg_chat_send",
  "rpg_chat_broadcast",
  "rpg_chat_pm_history_req",
  "rpg_chat_pm_history_res",
  "rpg_chat_admin_history_req",
  "rpg_chat_admin_history_res",
  "rpg_chat_mute_req",
  "rpg_chat_mute_res",
  "rpg_chat_mute_push",
  "rpg_report_open",
  "rpg_report_player_list_req",
  "rpg_report_player_list_res",
  "rpg_report_submit",
  "rpg_report_submit_res",
  "rpg_chat_recent_buffer_req",
  "rpg_chat_recent_buffer_res"
}

if SERVER then
  for _, n in ipairs(NETS) do util.AddNetworkString(n) end
end

-- Colors (client-only use, but define shared for consistency)
RPG_CHAT.Colors = {
  Global = Color(255,255,255),
  Whisper = Color(135,206,250),
  Admin = Color(255,215,0),
  System = Color(255,160,122),
  Name = Color(180, 220, 255),
  Rank = Color(180, 255, 180),
}

-- Emoji alias map (subset; extend as needed)
RPG_CHAT.Emoji = {
  [":shrug:"] = "¯\\_(ツ)_/¯",
  [":smile:"] = "😄",
  [":sad:"] = "😢",
  [":thumbsup:"] = "👍",
  [":heart:"] = "❤️",
  [":thinking:"] = "🤔",
}

function RPG_CHAT.ParseEmoji(text)
  for k,v in pairs(RPG_CHAT.Emoji) do
    text = string.Replace(text, k, v)
  end
  return text
end

-- Simple string trim/len clamps
function RPG_CHAT.TrimTo(text, max)
  text = string.Trim(tostring(text or ""))
  if #text > max then
    text = string.sub(text, 1, max)
  end
  return text
end

-- Prefix builder; server caches top rank in sv file
function RPG_CHAT.FormatPrefix(rankName)
  if not rankName or rankName == "" or string.lower(rankName) == "player" then return nil end
  return "[" .. rankName .. "]"
end

-- For routing unknown slash/bang commands to your project:
-- hook.Add("RPG_Chat_UnknownSlashCommand", "YourHandler", function(ply, text) ... end)

-- Shared config
RPG_CHAT.Config = {
  MaxMessageLen = 300,
  WhisperAliases = {["/w"]=true, ["/whisper"]=true, ["/pm"]=true, ["/msg"]=true},
  AdminAliases = {["/admins"]=true, ["/a"]=true, ["/asay"]=true},
  ReplyAlias = "/r",
  RetentionDays = 7,

  -- Anti-spam token bucket defaults (mods+ are immune serverside)
  Spam = {
    Global = { rate = 1/0.75, burst = 3 },   -- 1 msg / 0.75s, burst 3
    Private = { rate = 1/0.5,  burst = 5 },  -- 1 msg / 0.5s, burst 5
    DuplicateWindow = 8,                     -- seconds to block duplicates
    Escalation = {5, 30, 120},               -- cooldowns (s) for 1st/2nd; 3rd triggers auto-mute 120s
    AutoMuteSeconds = 120
  }
}

-- Small helpers for SteamID64
function RPG_CHAT.Steam64(ply)
  if isstring(ply) then return ply end
  if not IsValid(ply) then return "0" end
  return ply:SteamID64() or "0"
end

-- Client recent buffer (declared here for both realms to reference symbol)
if CLIENT then
  RPG_CHAT.RecentBuffer = RPG_CHAT.RecentBuffer or {} -- { {ts, type, sender64, senderName, text, target64?}, ... } (local only)
end
