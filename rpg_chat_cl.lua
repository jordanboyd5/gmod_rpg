include("autorun/sh_rpg_chat.lua")

-- Suppress default chat UI
hook.Add("OnPlayerChat", "RPG_CHAT_Suppress_Default", function() return true end)
hook.Add("ChatText", "RPG_CHAT_Suppress_System", function() return true end)

-- ===== UI State =====
local ChatUI = {}
local tabs = {} -- key: "all" or "pm_<steam64>"
local frame, sheet, input, addBtn
local pmPages = {} -- steam64 -> current page loaded (for history)
local function ensureFrame()
  if IsValid(frame) then return end
  frame = vgui.Create("DFrame")
  frame:SetTitle("Chat")
  frame:SetSize(580, 320)
  frame:Center()
  frame:MakePopup()
  frame:SetSizable(true)

  sheet = vgui.Create("DPropertySheet", frame)
  sheet:Dock(FILL)

  -- All Chat tab
  local pnl = vgui.Create("DPanel", sheet)
  pnl:Dock(FILL)
  local rich = vgui.Create("RichText", pnl)
  rich:Dock(FILL)
  function rich:PerformLayout()
    self:SetFontInternal("ChatFont")
    self:SetUnderlineFont("ChatFont")
  end
  tabs["all"] = {panel = pnl, rich = rich}
  sheet:AddSheet("All Chat", pnl, "icon16/comments.png")

  -- Input row
  local row = vgui.Create("DPanel", frame)
  row:Dock(BOTTOM)
  row:SetTall(28)
  row:DockMargin(5,5,5,5)

  addBtn = vgui.Create("DButton", row)
  addBtn:SetText("+")
  addBtn:SetWide(28)
  addBtn:Dock(LEFT)
  addBtn:DockMargin(0,0,5,0)
  addBtn.DoClick = function()
    ChatUI.OpenPMChooser()
  end

  input = vgui.Create("DTextEntry", row)
  input:Dock(FILL)
  input:SetUpdateOnType(false)
  input.OnEnter = function(self)
    local txt = self:GetText()
    if txt == "" then return end
    -- Client doesn't send text; server intercepts PlayerSay. Simulate say:
    LocalPlayer():ConCommand("say \"" .. string.gsub(txt, "\"", "\\\"") .. "\"")
    self:SetText("")
  end
end

-- Toggle with default key (y/enter)
hook.Add("PlayerBindPress", "RPG_CHAT_OpenOnSay", function(ply, bind, pressed)
  if not pressed then return end
  bind = string.lower(bind or "")
  if string.find(bind, "messagemode") then
    ensureFrame()
    frame:Show()
    frame:MakePopup()
    if IsValid(input) then input:RequestFocus() end
    return true
  end
end)

-- ===== Render helpers =====
local function addLineTo(tabKey, parts)
  ensureFrame()
  local t = tabs[tabKey]
  if not t then
    return
  end
  local rich = t.rich
  if not IsValid(rich) then return end

  for _, seg in ipairs(parts) do
    if istable(seg) and seg.__col then
      rich:InsertColorChange(seg.r, seg.g, seg.b, seg.a or 255)
    elseif isstring(seg) then
      rich:AppendText(seg)
    end
  end
  rich:AppendText("\n")
  rich:GotoTextEnd()
end

local function C(c) return {__col=true, r=c.r, g=c.g, b=c.b, a=c.a} end

local function printMessage(chType, sender64, senderName, senderRank, target64, text, ts)
  local prefix = RPG_CHAT.FormatPrefix(senderRank)
  local rankPart = prefix and { C(RPG_CHAT.Colors.Rank), "["..senderRank.."] " } or {}
  local namePart = { C(RPG_CHAT.Colors.Name), senderName .. ": " }
  local msgCol = (chType == RPG_CHAT.TYPE.WHISPER) and C(RPG_CHAT.Colors.Whisper)
               or (chType == RPG_CHAT.TYPE.ADMINS) and C(RPG_CHAT.Colors.Admin)
               or (chType == RPG_CHAT.TYPE.SYSTEM) and C(RPG_CHAT.Colors.System)
               or C(RPG_CHAT.Colors.Global)

  -- All Chat shows: GLOBAL+ADMINS+SYSTEM and any WHISPER where I am involved? Requirement says PMs not loaded into All Chat by default.
  if chType ~= RPG_CHAT.TYPE.WHISPER then
    addLineTo("all", { unpack(rankPart), unpack(namePart), msgCol, text })
  end

  -- PM tabs: show if whisper and I am participant
  if chType == RPG_CHAT.TYPE.WHISPER then
    local me64 = LocalPlayer():SteamID64()
    if sender64 == me64 or target64 == me64 then
      local other = (sender64 == me64) and target64 or sender64
      if not tabs["pm_"..other] then
        ChatUI.OpenPMTab(other, "Loading...")
      end
      addLineTo("pm_"..other, { unpack(rankPart), unpack(namePart), msgCol, text })
    end
  end

  -- Maintain local recent buffer (for reports UI)
  table.insert(RPG_CHAT.RecentBuffer, {
    ts = ts or os.time(), type = chType, sender64=sender64, senderName=senderName, text=text, target64=target64
  })
  if #RPG_CHAT.RecentBuffer > 150 then table.remove(RPG_CHAT.RecentBuffer, 1) end
end

-- ===== Net: incoming messages =====
net.Receive("rpg_chat_broadcast", function()
  local chType = net.ReadUInt(3)
  local sender64 = net.ReadString()
  local senderName = net.ReadString()
  local senderRank = net.ReadString()
  local target64 = net.ReadString()
  local text = net.ReadString()
  local ts = net.ReadUInt(32)
  local id = net.ReadUInt(32)

  printMessage(chType, sender64, senderName, senderRank, target64, text, ts)
end)

-- ===== PM chooser & tabs =====
function ChatUI.OpenPMTab(other64, displayName)
  ensureFrame()
  if tabs["pm_"..other64] then
    sheet:SetActiveTab(tabs["pm_"..other64].tab)
    return
  end

  local pnl = vgui.Create("DPanel", sheet)
  pnl:Dock(FILL)
  local rich = vgui.Create("RichText", pnl)
  rich:Dock(FILL)
  function rich:PerformLayout() self:SetFontInternal("ChatFont") end

  local title = "PM: " .. (displayName or other64)
  local tid, tab = sheet:AddSheet(title, pnl, "icon16/user_comment.png")
  tabs["pm_"..other64] = {panel=pnl, rich=rich, tab=tab}

  -- Load first page of history
  pmPages[other64] = 1
  net.Start("rpg_chat_pm_history_req")
    net.WriteString(other64)
    net.WriteUInt(pmPages[other64], 16)
  net.SendToServer()
end

function ChatUI.OpenPMChooser()
  local menu = DermaMenu()
  for _, p in ipairs(player.GetAll()) do
    menu:AddOption(p:Nick(), function() ChatUI.OpenPMTab(p:SteamID64(), p:Nick()) end)
  end
  menu:Open()
end

-- History response or collision list
net.Receive("rpg_chat_pm_history_res", function()
  local isHistory = net.ReadBool()
  if not isHistory then
    -- Collision list for /w
    local count = net.ReadUInt(8)
    local menu = DermaMenu()
    for i=1, count do
      local s64 = net.ReadString()
      local name = net.ReadString()
      local rank = net.ReadString()
      menu:AddOption(("%s [%s]"):format(name, rank), function()
        if IsValid(input) then input:SetText("/w " .. s64 .. " ") input:RequestFocus() input:OnEnter() end
      end)
    end
    menu:Open()
    return
  end

  local n = net.ReadUInt(16)
  if n == 0 then return end
  -- Use the first row to infer the other participant
  local firstSender64 = net.ReadString(); local firstSenderName = net.ReadString(); local firstSenderRank = net.ReadString()
  local firstTarget64 = net.ReadString(); local firstText = net.ReadString(); local firstTs = net.ReadUInt(32); local firstId = net.ReadUInt(32)
  -- rewind reader: we already consumed first row fields; easier approach: store and print then iterate rest
  local me64 = LocalPlayer():SteamID64()
  local other = (firstSender64 == me64) and firstTarget64 or firstSender64
  if not tabs["pm_"..other] then ChatUI.OpenPMTab(other, "Loading...") end
  -- print first
  printMessage(RPG_CHAT.TYPE.WHISPER, firstSender64, firstSenderName, firstSenderRank, firstTarget64, firstText, firstTs)
  -- remaining
  for i=2, n do
    local t = net.ReadUInt(3)
    local s64 = net.ReadString()
    local sname = net.ReadString()
    local srank = net.ReadString()
    local tar64 = net.ReadString()
    local txt = net.ReadString()
    local ts = net.ReadUInt(32)
    local id = net.ReadUInt(32)
    printMessage(t, s64, sname, srank, tar64, txt, ts)
  end
end)

-- ===== Mute pushes =====
net.Receive("rpg_chat_mute_push", function()
  local target64 = net.ReadString()
  local by = net.ReadString()
  local minutes = net.ReadUInt(16)
  local reason = net.ReadString()
  local msg
  if minutes == 0 and reason == "Unmuted" then
    msg = ("System: %s was unmuted by %s"):format(target64, by)
  else
    msg = ("System: %s was muted by %s for %s (%s)"):format(target64, by, minutes>0 and (minutes.."m") or "indefinite", reason)
  end
  printMessage(RPG_CHAT.TYPE.SYSTEM, "0", "System", "system", "0", msg, os.time())
end)

-- ===== Report menu integration =====
-- A very small “recent chats” fetch from client buffer for the UI to consume
net.Receive("rpg_chat_recent_buffer_req", function(_, ply) end) -- server-only, ignore

-- Open report UI with chat command
hook.Add("OnPlayerChat", "RPG_CHAT_Report_OpenCmd", function(ply, text)
  if ply ~= LocalPlayer() then return end
  text = string.Trim(string.lower(text or ""))
  if text == "!report" then
    timer.Simple(0, function()
      net.Start("rpg_report_open"); net.SendToServer() end)
    return true
  end
end)

net.Receive("rpg_report_open", function()
  -- just open client panel
  if not Derma_Notify then end
  include("rpg_report/ui_report_cl.lua")
  RPG_Report_Open()
end)
