--!nonstrict
-- YT-DLP panel - ultra simple

local url = ""

function onUrlChange(val)
  url = val or ""
end

function onTest()
  noctalia.notify("YT-DLP", "Button clicked! URL=" .. url)
end

function onCloseClicked()
  panel.close()
end

local render

render = function()
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "YT-DLP", fontSize = 16, fontWeight = "bold", color = "primary" }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.separator({}),
    ui.label({ text = "URL", fontSize = 12 }),
    ui.input({ key = "url", placeholder = "Paste URL", value = url, onChange = "onUrlChange" }),
    ui.button({ text = "Test Alert", variant = "primary", onClick = "onTest" }),
    ui.label({ text = "URL entered: " .. url, fontSize = 11, color = "on_surface_variant" }),
  }))
end

function onOpen()
  render()
end

function onClose()
end
