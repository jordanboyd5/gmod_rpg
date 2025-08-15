-- lua/rpg_perms/ui_cl.lua
if not CLIENT then return end

local state = {
  roles = {},
  players = {},
  access = { moderation=false, roleAssign=false, roleEdit=false, reports=false }
}

-- Open panel request
local function RequestOpen()
  net.Start("rpg_perms_open_admin")
  net.SendToServer()
end
concommand.Add("rpg_admin", RequestOpen)
hook.Add("OnPlayerChat", "rpg_perms_open_cmd", function(ply, txt)
  if ply ~= LocalPlayer() then return end
  if string.lower(txt) == "!admin" then RequestOpen() return true end
end)

-- Small helpers
local function toast(ok, msg)
  chat.AddText(ok and Color(80,220,120) or Color(220,80,80), "[PERMS] ", color_white, msg or (ok and "OK" or "Failed"))
end
local function isSid64(s) return isstring(s) and #s >= 17 and s:match("^%d+$") end

-- === UI builders ===
local function buildModerationPage(parent)
  local pnl = vgui.Create("Panel", parent)
  -- Targets
  local sidEntry = vgui.Create("DTextEntry", pnl)
  sidEntry:SetPos(10, 10); sidEntry:SetSize(240, 24); sidEntry:SetPlaceholderText("SteamID64 (select row or paste)")
  local reasonEntry = vgui.Create("DTextEntry", pnl)
  reasonEntry:SetPos(260, 10); reasonEntry:SetSize(300, 24); reasonEntry:SetPlaceholderText("Reason (optional)")
  local minsEntry = vgui.Create("DTextEntry", pnl)
  minsEntry:SetPos(570, 10); minsEntry:SetSize(60, 24); minsEntry:SetPlaceholderText("mins")

  local function send(action, withMinutes)
    local sid = sidEntry:GetText()
    if not isSid64(sid) then return toast(false, "Enter a valid SteamID64") end
    local minutes = withMinutes and tonumber(minsEntry:GetText()) or nil
    net.Start("rpg_moderate_action")
      net.WriteTable({ action=action, targetSid64=sid, minutes=minutes, reason=reasonEntry:GetText() })
    net.SendToServer()
  end

  local y = 44
  local buttons = {
    {txt="Mute", fn=function() send("mute", true) end},
    {txt="Warn", fn=function() send("warn") end},
    {txt="Kick", fn=function() send("kick") end},
    {txt="Temp Ban", fn=function() send("ban_temp", true) end},
    {txt="Perm Ban", fn=function() send("ban_perm") end},
  }
  for i, b in ipairs(buttons) do
    local btn = vgui.Create("DButton", pnl)
    btn:SetPos(10 + (i-1)*110, y)
    btn:SetSize(100, 28)
    btn:SetText(b.txt)
    btn.DoClick = b.fn
  end

  -- Online players table (for convenience)
  local list = vgui.Create("DListView", pnl)
  list:SetPos(10, 84)
  list:SetSize(760, 360)
  list:AddColumn("Name"); list:AddColumn("SteamID64"); list:AddColumn("Roles")
  for _, p in ipairs(state.players or {}) do
    list:AddLine(p.name, p.sid, table.concat(p.roles or {}, ", "))
  end
  function list:OnRowSelected(_, line)
    sidEntry:SetText(line:GetColumnText(2))
  end

  return pnl
end

local function buildRoleAssignmentPage(parent)
  local pnl = vgui.Create("Panel", parent)
  local sidEntry = vgui.Create("DTextEntry", pnl)
  sidEntry:SetPos(10, 10); sidEntry:SetSize(240, 24); sidEntry:SetPlaceholderText("SteamID64 (online or offline)")
  local roleCombo = vgui.Create("DComboBox", pnl)
  roleCombo:SetPos(260, 10); roleCombo:SetSize(150, 24); roleCombo:SetValue("Select role")
  for _, r in ipairs(state.roles or {}) do roleCombo:AddChoice(r.name) end
  local minsEntry = vgui.Create("DTextEntry", pnl)
  minsEntry:SetPos(420, 10); minsEntry:SetSize(60, 24); minsEntry:SetPlaceholderText("mins")
  local reasonEntry = vgui.Create("DTextEntry", pnl)
  reasonEntry:SetPos(490, 10); reasonEntry:SetSize(280, 24); reasonEntry:SetPlaceholderText("reason (optional)")

  local function chosenRole()
    local v = roleCombo:GetValue()
    if not v or v == "" or v == "Select role" then return nil end
    return v
  end

  local grantBtn = vgui.Create("DButton", pnl)
  grantBtn:SetPos(10, 44); grantBtn:SetSize(120, 26); grantBtn:SetText("Grant role")
  grantBtn.DoClick = function()
    local sid, role = sidEntry:GetText(), chosenRole()
    if not isSid64(sid) then return toast(false, "Enter a valid SteamID64") end
    if not role then return toast(false, "Choose a role") end
    net.Start("rpg_perms_grant_role")
      net.WriteTable({ targetSid64=sid, roleName=role, minutes=tonumber(minsEntry:GetText()) or 0, reason=reasonEntry:GetText() })
    net.SendToServer()
  end

  local revokeBtn = vgui.Create("DButton", pnl)
  revokeBtn:SetPos(140, 44); revokeBtn:SetSize(120, 26); revokeBtn:SetText("Revoke role")
  revokeBtn.DoClick = function()
    local sid, role = sidEntry:GetText(), chosenRole()
    if not isSid64(sid) then return toast(false, "Enter a valid SteamID64") end
    if not role then return toast(false, "Choose a role to revoke") end
    net.Start("rpg_perms_revoke_role")
      net.WriteTable({ targetSid64=sid, roleName=role })
    net.SendToServer()
  end

  -- Online convenience table
  local list = vgui.Create("DListView", pnl)
  list:SetPos(10, 84); list:SetSize(760, 360)
  list:AddColumn("Name"); list:AddColumn("SteamID64"); list:AddColumn("Roles")
  for _, p in ipairs(state.players or {}) do list:AddLine(p.name, p.sid, table.concat(p.roles or {}, ", ")) end
  function list:OnRowSelected(_, line)
    local sid = line:GetColumnText(2); sidEntry:SetText(sid)
    local firstRole = string.match(line:GetColumnText(3) or "", "([^,%s]+)")
    if firstRole and firstRole ~= "" then roleCombo:SetValue(firstRole) end
  end

  return pnl
end

local function buildRoleEditingPage(parent)
  local pnl = vgui.Create("Panel", parent)

  -- Left: roles list
  local list = vgui.Create("DListView", pnl)
  list:SetPos(10, 10); list:SetSize(300, 434)
  list:AddColumn("Role"); list:AddColumn("Priority")
  for _, r in ipairs(state.roles or {}) do list:AddLine(r.name, tostring(r.priority or 0)) end

  -- Right: editor
  local nameEntry = vgui.Create("DTextEntry", pnl); nameEntry:SetPos(320, 10); nameEntry:SetSize(200, 22); nameEntry:SetPlaceholderText("name (new or existing)")
  local dispEntry = vgui.Create("DTextEntry", pnl); dispEntry:SetPos(320, 40); dispEntry:SetSize(200, 22); dispEntry:SetPlaceholderText("display name")
  local priEntry  = vgui.Create("DTextEntry", pnl); priEntry:SetPos(530, 10); priEntry:SetSize(80, 22);  priEntry:SetPlaceholderText("priority")
  local colorEntry= vgui.Create("DTextEntry", pnl); colorEntry:SetPos(530, 40); colorEntry:SetSize(80, 22); colorEntry:SetPlaceholderText("color (hex)")

  local createBtn = vgui.Create("DButton", pnl); createBtn:SetPos(620, 10); createBtn:SetSize(150, 22); createBtn:SetText("Create role")
  createBtn.DoClick = function()
    if nameEntry:GetText() == "" then return toast(false, "Role name required") end
    local colorVal = tonumber(colorEntry:GetText()) or 0xFFFFFF
    net.Start("rpg_roles_create")
      net.WriteTable({ name=nameEntry:GetText(), display_name=dispEntry:GetText(), priority=tonumber(priEntry:GetText()) or 0, color=colorVal })
    net.SendToServer()
  end

  local updateBtn = vgui.Create("DButton", pnl); updateBtn:SetPos(620, 40); updateBtn:SetSize(150, 22); updateBtn:SetText("Update role")
  updateBtn.DoClick = function()
    if nameEntry:GetText() == "" then return toast(false, "Role name required") end
    local colorVal = tonumber(colorEntry:GetText()) or 0xFFFFFF
    net.Start("rpg_roles_update")
      net.WriteTable({ name=nameEntry:GetText(), display_name=dispEntry:GetText(), priority=tonumber(priEntry:GetText()) or 0, color=colorVal })
    net.SendToServer()
  end

  local deleteBtn = vgui.Create("DButton", pnl); deleteBtn:SetPos(620, 70); deleteBtn:SetSize(150, 22); deleteBtn:SetText("Delete role")
  deleteBtn.DoClick = function()
    if nameEntry:GetText() == "" then return toast(false, "Role name required") end
    net.Start("rpg_roles_delete"); net.WriteTable({ name=nameEntry:GetText() }); net.SendToServer()
  end

  -- Perm editor
  local permName = vgui.Create("DTextEntry", pnl); permName:SetPos(320, 100); permName:SetSize(200, 22); permName:SetPlaceholderText("permission (e.g., player.kick)")
  local effCombo = vgui.Create("DComboBox", pnl); effCombo:SetPos(530, 100); effCombo:SetSize(120, 22); effCombo:SetValue("allow/deny")
  effCombo:AddChoice("allow"); effCombo:AddChoice("deny")

  local setPermBtn = vgui.Create("DButton", pnl); setPermBtn:SetPos(660, 100); setPermBtn:SetSize(110, 22); setPermBtn:SetText("Set perm")
  setPermBtn.DoClick = function()
    if nameEntry:GetText() == "" then return toast(false, "Role name required") end
    local effect = effCombo:GetValue()
    if effect ~= "allow" and effect ~= "deny" then return toast(false, "Choose allow/deny") end
    net.Start("rpg_roles_set_perm")
      net.WriteTable({ roleName=nameEntry:GetText(), permName=permName:GetText(), effect=effect })
    net.SendToServer()
  end

  local remPermBtn = vgui.Create("DButton", pnl); remPermBtn:SetPos(660, 130); remPermBtn:SetSize(110, 22); remPermBtn:SetText("Remove perm")
  remPermBtn.DoClick = function()
    if nameEntry:GetText() == "" then return toast(false, "Role name required") end
    net.Start("rpg_roles_remove_perm")
      net.WriteTable({ roleName=nameEntry:GetText(), permName=permName:GetText() })
    net.SendToServer()
  end

  function list:OnRowSelected(_, line)
    nameEntry:SetText(line:GetColumnText(1))
    priEntry:SetText(line:GetColumnText(2))
  end

  return pnl
end

local function buildReportsPage(parent)
  local pnl = vgui.Create("Panel", parent)

  -- Submit new report
  local targetEntry = vgui.Create("DTextEntry", pnl); targetEntry:SetPos(10, 10); targetEntry:SetSize(340, 22); targetEntry:SetPlaceholderText("Target SteamID64s (comma-separated)")
  local descEntry   = vgui.Create("DTextEntry", pnl); descEntry:SetPos(360, 10); descEntry:SetSize(340, 22); descEntry:SetPlaceholderText("Description")
  local submitBtn   = vgui.Create("DButton", pnl); submitBtn:SetPos(710, 10); submitBtn:SetSize(60, 22); submitBtn:SetText("Submit")
  submitBtn.DoClick = function()
    local targets = {}
    for sid in string.gmatch(targetEntry:GetText() or "", "([^,%s]+)") do
      if isSid64(sid) then table.insert(targets, sid) end
    end
    net.Start("rpg_reports_submit")
      net.WriteTable({ targets=targets, description=descEntry:GetText() })
    net.SendToServer()
  end

  -- Reports list
  local list = vgui.Create("DListView", pnl)
  list:SetPos(10, 44); list:SetSize(760, 400)
  list:AddColumn("ID"); list:AddColumn("Status"); list:AddColumn("Reporter"); list:AddColumn("Targets"); list:AddColumn("Description"); list:AddColumn("Handled By")

  local function refresh()
    net.Start("rpg_reports_fetch"); net.SendToServer()
  end

  -- Action buttons
  local idEntry = vgui.Create("DTextEntry", pnl); idEntry:SetPos(10, 450); idEntry:SetSize(60, 22); idEntry:SetPlaceholderText("Report ID")
  local noteEntry = vgui.Create("DTextEntry", pnl); noteEntry:SetPos(80, 450); noteEntry:SetSize(500, 22); noteEntry:SetPlaceholderText("Note (optional)")
  local actions = {
    {"Claim","claim"}, {"Resolve","resolve"}, {"Close","close"}, {"Reopen","reopen"}
  }
  for i, pair in ipairs(actions) do
    local btn = vgui.Create("DButton", pnl)
    btn:SetPos(590 + (i-1)*45, 450); btn:SetSize(40, 22); btn:SetText(pair[1])
    btn.DoClick = function()
      local id = tonumber(idEntry:GetText()); if not id then return toast(false, "Enter Report ID") end
      net.Start("rpg_reports_action"); net.WriteTable({ id=id, op=pair[2], note=noteEntry:GetText() }); net.SendToServer()
    end
  end

  function list:OnRowSelected(_, line)
    idEntry:SetText(line:GetColumnText(1))
  end

  -- Hook payload
  net.Receive("rpg_reports_payload", function()
    list:Clear()
    local rows = net.ReadTable() or {}
    for _, r in ipairs(rows) do
      list:AddLine(tostring(r.id), r.status or "", r.reporter_sid or "", r.targets_json or "[]", r.description or "", r.handled_by or "")
    end
  end)

  net.Receive("rpg_reports_updated", function() refresh() end)

  -- Initial fetch
  timer.Simple(0.05, refresh)

  return pnl
end

-- Build the whole window with tabs
local function buildUI()
  if IsValid(state.frame) then state.frame:Close() end
  local f = vgui.Create("DFrame")
  f:SetSize(800, 540); f:Center(); f:SetTitle("RPG Admin"); f:MakePopup()
  state.frame = f

  local tabs = vgui.Create("DPropertySheet", f)
  tabs:SetPos(5, 30); tabs:SetSize(790, 505)

  if state.access.moderation then tabs:AddSheet("Moderation", buildModerationPage(tabs), "icon16/user_gray.png") end
  if state.access.roleAssign then tabs:AddSheet("Role Assignment", buildRoleAssignmentPage(tabs), "icon16/group_key.png") end
  if state.access.roleEdit   then tabs:AddSheet("Role Editing", buildRoleEditingPage(tabs), "icon16/wrench.png") end
  if state.access.reports    then tabs:AddSheet("Reports", buildReportsPage(tabs), "icon16/report.png") end
end

-- Bootstrap payload
net.Receive("rpg_perms_bootstrap", function()
  local payload = net.ReadTable() or {}
  state.roles   = payload.roles or {}
  state.players = payload.players or {}
  state.access  = payload.access or state.access
  buildUI()
end)

-- Action result toast
net.Receive("rpg_perms_action_result", function()
  local ok = net.ReadBool(); local msg = net.ReadString()
  toast(ok, msg)
  -- Refresh after server-side changes
  timer.Simple(0.15, function() if IsValid(state.frame) then RequestOpen() end end)
end)

-- Live refresh notice
net.Receive("rpg_perms_live_refresh", function()
  chat.AddText(Color(80,180,255), "[PERMS] ", color_white, "Your permissions were updated.")
end)

-- Lightweight report command for players
hook.Add("OnPlayerChat", "rpg_reports_open_cmd", function(ply, txt)
  if ply ~= LocalPlayer() then return end
  if string.lower(txt) == "!report" then
    -- open reports tab quickly
    RequestOpen()
    return true
  end
end)
