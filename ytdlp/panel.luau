--!nonstrict
-- YT-DLP panel

local url = ""
local selectedMode = 1

function onUrlChange(val)
  url = val or ""
end

function onExtract()
  noctalia.notify("YT-DLP", "Extract clicked! URL: " .. url)
end

function onDownload()
  noctalia.notify("YT-DLP", "Download clicked! URL: " .. url)
end

function onCloseClicked()
  panel.close()
end

function onOpen()
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "YT-DLP", fontSize = 16, fontWeight = "bold", color = "primary" }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.separator({}),
    ui.label({ text = "URL: " .. url, fontSize = 12 }),
    ui.input({ key = "url", placeholder = "Paste URL", value = url, onChange = "onUrlChange" }),
    ui.row({ gap = 8 }, {
      ui.button({ text = "Extract", variant = "primary", disabled = url == "", onClick = "onExtract" }),
      ui.button({ text = "Download", variant = "primary", disabled = url == "", onClick = "onDownload" }),
    }),
  }))
end

function onClose()
end
