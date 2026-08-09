--!nonstrict

noctalia.setUpdateInterval(1000)

local lastLayout = nil

local function poll()
  if not noctalia.commandExists("hyprctl") then
    return
  end
  noctalia.runAsync("hyprctl activeworkspace -j", function(result)
    if result.exitCode ~= 0 then
      return
    end
    local data = noctalia.json.decode(result.stdout)
    if data == nil then
      return
    end
    local layout = data.tiledLayout or ""
    if layout ~= lastLayout then
      lastLayout = layout
      noctalia.state.set("hypr_layouts_state", {
        layout = layout,
        workspace = data.id,
      })
    end
  end)
end

function update()
  poll()
end

poll()
