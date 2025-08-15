include("autorun/sh_rpg_chat.lua")

local function openAdminChatHistory()
  local fr = vgui.Create("DFrame")
  fr:SetTitle("Admin: Chat History")
  fr:SetSize(800, 480)
  fr:Center()
  fr:MakePopup()

  -- Filters
  local top = vgui.Create("DPanel", fr)
  top:Dock(TOP); top:SetTall(64); top:DockMargin(5,5,5,0)

  local typeBox = vgui.Create("DComboBox", top); typeBox:Dock(LEFT); typeBox:SetWide(120)
  typeBox:AddChoice("Any Type", 0, true)
  typeBox:AddChoice("Global", RPG_CHAT.TYPE.GLOBAL)
  typeBox:AddChoice("Whisper", RPG_CHAT.TYPE.WHISPER)
  typeBox:AddChoice("Admins",  RPG_CHAT.TYPE.ADMINS)

  local sender = vgui.Create("DTextEntry", top); sender:Dock(LEFT); sender:SetWide(150); sender:SetPlaceholderText("Sender Steam64")
  local target = vgui.Create("DTextEntry", top); target:Dock(LEFT); target:SetWide(150); target:SetPlaceholderText("Target Steam64")
  local contains = vgui.Create("DTextEntry", top); contains:Dock(FILL); contains:SetPlaceholderText("Contains text")
  local page = vgui.Create("DNumberWang", top); page:Dock(RIGHT); page:SetDecimals(0); page:SetMin(1); page:SetMax(100000); page:SetValue(1); page:SetWide(60)

  local go = vgui.Create("DButton", top); go:Dock(RIGHT); go:SetText("Search"); go:SetWide(80)

  -- Table
  local list = vgui.Create("DListView", fr)
  list:Dock(FILL); list:DockMargin(5,5,5,5)
  list:AddColumn("ID")
  list:AddColumn("Type")
  list:AddColumn("Time")
  list:AddColumn("Sender (Rank)")
  list:AddColumn("Target")
  list:AddColumn("Message")

  local function request()
    local _, tval = typeBox:GetSelected()
    net.Start("rpg_chat_admin_history_req")
      net.WriteUInt(tonumber(tval or 0), 3)
      net.WriteString(sender:GetValue() or "")
      net.WriteString(target:GetValue() or "")
      net.WriteString(contains:GetValue() or "")
      net.WriteUInt(0, 32) -- since
      net.WriteUInt(0, 32) -- until
      net.WriteUInt(math.max(1, page:GetValue()), 16)
    net.SendToServer()
  end
  go.DoClick = request
  request()

  net.Receive("rpg_chat_admin_history_res", function()
    list:Clear()
    local n = net.ReadUInt(16)
    for i=1,n do
      local t = net.ReadUInt(3)
      local s64 = net.ReadString()
      local sname = net.ReadString()
      local srank = net.ReadString()
      local tar64 = net.ReadString()
      local msg = net.ReadString()
      local ts = net.ReadUInt(32)
      local id = net.ReadUInt(32)
      local tname = (t==RPG_CHAT.TYPE.GLOBAL and "Global") or (t==RPG_CHAT.TYPE.WHISPER and "Whisper") or (t==RPG_CHAT.TYPE.ADMINS and "Admins") or "System"
      list:AddLine(id, tname, os.date("%Y-%m-%d %H:%M:%S", ts), (sname.." ["..srank.."] ("..s64..")"), tar64~="0" and tar64 or "", msg)
    end
  end)
end

-- You can open this via your existing admin UI where appropriate.
concommand.Add("rpg_admin_chathistory", function() openAdminChatHistory() end)
