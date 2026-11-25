--!nonstrict

noctalia.setUpdateInterval(1000)

local lastLayout = nil

-- Track the global layout option, not activeworkspace.tiledLayout. The latter
-- can disagree with the persisted config and made the bar widget show the
-- default `scrolling` even after a layout had been selected.
local function poll()
  if not noctalia.commandExists("hyprctl") then
    return
  end
  noctalia.runAsync("hyprctl getoption general:layout -j", function(result)
    if result.exitCode ~= 0 then
      return
    end
    local data = noctalia.json.decode(result.stdout)
    if type(data) ~= "table" or type(data.str) ~= "string" then
      return
    end
    local layout = data.str
    if layout ~= lastLayout then
      lastLayout = layout
      noctalia.state.set("hypr_layouts_state", { layout = layout })
    end
  end)
end

function update()
  poll()
end

poll()
