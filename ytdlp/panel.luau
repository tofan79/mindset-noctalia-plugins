--!nonstrict
-- YT-DLP panel - minimal test

noctalia.log("ytdlp panel: MINIMAL TEST LOADING")

function onOpen(_context)
  noctalia.log("ytdlp: onOpen called")
  panel.render(ui.column({ flexGrow = 1, gap = 8 }, {
    ui.label({ text = "YT-DLP Panel - TEST", fontSize = 16, fontWeight = "bold", color = "primary" }),
    ui.label({ text = "If you see this, panel works!", fontSize = 12, color = "on_surface" }),
  }))
end

function onClose()
end

function onCloseClicked()
  panel.close()
end

noctalia.log("ytdlp panel: MINIMAL TEST LOADED")
