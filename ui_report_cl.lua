include("autorun/sh_rpg_chat.lua")

function RPG_Report_Open()
  local fr = vgui.Create("DFrame")
  fr:SetTitle("Report Player")
  fr:SetSize(520, 480)
  fr:Center()
  fr:MakePopup()

  local top = vgui.Create("DPanel", fr)
  top:Dock(TOP); top:SetTall(100); top:DockMargin(5,5,5,0)

  local lbl = vgui.Create("DLabel", top); lbl:SetText("Select player to report (online first, then recent offline):")
  lbl:Dock(TOP); lbl:DockMargin(0,0,0,5)

  local combo = vgui.Create("DComboBox", top)
  combo:Dock(TOP)

  local cat = vgui.Create("DComboBox", top); cat:Dock(TOP); cat:DockMargin(0,5,0,0)
  cat:SetValue("Category (optional)")
  cat:AddChoice("Harassment")
  cat:AddChoice("Cheating")
  cat:AddChoice("Spam")
  cat:AddChoice("Other")

  local desc = vgui.Create("DTextEntry", fr)
  desc:Dock(FILL); desc:DockMargin(5,5,5,5); desc:SetMultiline(true); desc:SetPlaceholderText("Describe what happened...")

  -- Recent chat attachment
  local attachPanel = vgui.Create("DPanel", fr)
  attachPanel:Dock(BOTTOM); attachPanel:SetTall(150); attachPanel:DockMargin(5,0,5,5)
  local attachLbl = vgui.Create("DLabel", attachPanel); attachLbl:SetText("Attach recent chat lines (optional):")
  attachLbl:Dock(TOP)

  local list = vgui.Create("DListView", attachPanel)
  list:Dock(FILL)
  list:AddColumn("Select")
  list:AddColumn("Time")
  list:AddColumn("Sender")
  list:AddColumn("Message")

  -- Populate attach list from client buffer
  local function refreshAttach()
    list:Clear()
    for _, r in ipairs(RPG_CHAT.RecentBuffer or {}) do
      local when = os.date("%H:%M:%S", r.ts or os.time())
      list:AddLine("", when, r.senderName or r.sender64, r.text or "")
    end
  end
  refreshAttach()

  -- Submit
  local submit = vgui.Create("DButton", fr)
  submit:Dock(BOTTOM); submit:SetTall(32); submit:SetText("Submit Report")
  submit.DoClick = function()
    local sel = combo:GetSelected()
    if not sel then notification.AddLegacy("Select a player to report.", NOTIFY_ERROR, 4) return end
    local target64 = sel.Data or sel.DataID or sel.Steam64 or sel.Value or ""
    local category = select(2, cat:GetSelected()) or ""
    local description = desc:GetValue() or ""

    -- For MVP, we attach no DB IDs (those are admin history). We can still include a snapshot length.
    local attachedIds = "" -- could be comma list if mapping existed client-side

    net.Start("rpg_report_submit")
      net.WriteString(target64)
      net.WriteString(category)
      net.WriteString(description)
      net.WriteString(attachedIds)
    net.SendToServer()
  end

  net.Receive("rpg_report_submit_res", function()
    local ok = net.ReadBool()
    local id = net.ReadUInt(32)
    if ok then
      notification.AddLegacy("Report submitted. ID #" .. id, NOTIFY_GENERIC, 5)
      fr:Close()
    else
      notification.AddLegacy("Failed to submit report.", NOTIFY_ERROR, 5)
    end
  end)

  -- Load player list
  net.Start("rpg_report_player_list_req"); net.SendToServer()
  net.Receive("rpg_report_player_list_res", function()
    combo:Clear()
    local onlineCount = net.ReadUInt(16)
    for i=1,onlineCount do
      local s64 = net.ReadString()
      local name = net.ReadString()
      local online = net.ReadBool()
      combo:AddChoice(("[Online] %s (%s)"):format(name, s64), s64)
    end
    local offCount = net.ReadUInt(16)
    for i=1,offCount do
      local s64 = net.ReadString()
      local name = net.ReadString()
      local online = net.ReadBool()
      combo:AddChoice(("[Recent] %s (%s)"):format(name, s64), s64)
    end
  end)
end
