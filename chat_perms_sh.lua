-- Adapter to your permissions system.
-- Change only this file if your API differs.

if SERVER then AddCSLuaFile() end
RPG_PERMS_ADAPTER = RPG_PERMS_ADAPTER or {}

-- Expected external API (replace with your actual one):
-- Perms.HasRankAtLeast(ply, "mod") -> boolean
-- Perms.GetTopRank(ply) -> { name="Admin", priority=90 } or { name="player", priority=0 }

local function _fallbackGetTopRank(ply)
  -- If no perms system yet, everyone is "player"
  return { name = "player", priority = 0 }
end

function RPG_PERMS_ADAPTER.IsModPlus(ply)
  if Perms and Perms.HasRankAtLeast then
    return Perms.HasRankAtLeast(ply, "mod")
  end
  -- Fallback: server owners are admins
  return ply:IsAdmin()
end

function RPG_PERMS_ADAPTER.TopRankName(ply)
  if Perms and Perms.GetTopRank then
    local r = Perms.GetTopRank(ply)
    return r and r.name or "player"
  end
  local r = _fallbackGetTopRank(ply)
  return r.name
end
