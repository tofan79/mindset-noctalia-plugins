--!nonstrict
--
-- YT-DLP panel: a pure reader of `noctalia.state`, mirroring Otoru's Panel.qml. Like the
-- widget it owns no state: every interactive control sends a command back to the service
-- through `noctalia.state.set("command", ...)` with a monotonically increasing nonce.
-- Interactive props are the *names* of global functions (the ui bridge resolves handlers
-- by name); variable-grid rows (queue, history) use closures with a stable `key` prop.

local M = {}

local CONTROL_LABEL_WIDTH = 150
local CONTROL_WIDTH = 170

-- ── module state (refreshed from `noctalia.state` on open and on every watch) ───

local settings = {}
local media = nil
local active = {}
local queue = {}
local extracting = false
local errorMessage = ""
local clipboard = {}
local clipboardVersion = 0
local seenClipboardVersion = 0
local urlValue = ""
local nonceCounter = 0

-- option sets rebuilt each render so the selects and their index handlers agree
local qualityOptions = {}
local audioFormatOptions = {}
local audioTrackOptions = {}
local subLangOptions = {}
local postActionOptions = {}
local cookiesBrowserOptions = {}

local function tr(key, subst)
    return noctalia.tr(key, subst)
end

local function val(x)
    if type(x) == "table" then return 0 end
    return tonumber(x) or 0
end

local function expandHome(path)
    local value = tostring(path or "")
    if value:sub(1, 1) == "~" then
        return (noctalia.getenv("HOME") or "") .. value:sub(2)
    end
    return value
end

local function dur(seconds)
    local value = val(seconds)
    local hours = math.floor(value / 3600)
    local minutes = math.floor((value % 3600) / 60)
    local secs = math.floor(value % 60)
    local function pad(n) return string.format("%02d", n) end
    if hours > 0 then
        return string.format("%d:%s:%s", hours, pad(minutes), pad(secs))
    end
    return string.format("%d:%s", minutes, pad(secs))
end

local function sendCommand(action, extra)
    nonceCounter = nonceCounter + 1
    local command = { nonce = (noctalia.nowMs() * 1000) + nonceCounter, action = action }
    for key, value in pairs(extra or {}) do
        command[key] = value
    end
    noctalia.state.set("command", command)
end

-- ── shared bits ────────────────────────────────────────────────────────────────

local function selectFor(options, current, onChange, width)
    local labels = {}
    local selectedIndex = 0
    for index, entry in ipairs(options) do
        labels[index] = entry.label
        if entry.value == current then
            selectedIndex = index - 1
        end
    end
    return ui.select({
        options = labels,
        selectedIndex = selectedIndex,
        width = width or CONTROL_WIDTH,
        onChange = onChange,
    })
end

local function labelRow(label, control)
    return ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = label, color = "on_surface_variant", width = CONTROL_LABEL_WIDTH }),
        ui.spacer({ flexGrow = 1 }),
        control,
    })
end

local function jobFor(mediaInfo)
    return {
        url = type(mediaInfo) == "table" and (mediaInfo.extractedUrl or mediaInfo.webpage_url) or "",
        title = type(mediaInfo) == "table" and mediaInfo.title or "",
        mode = settings.downloadMode or "video",
        quality = settings.quality or "best",
        audioFormat = settings.audioFormat or "best",
        audioLanguage = settings.audioLanguage or "",
    }
end

local function buildJob()
    local job = jobFor(media)
    return job
end

-- ── option sets ────────────────────────────────────────────────────────────────

local function rebuildOptions()
    qualityOptions = { { label = tr("panel.quality_best"), value = "best" } }
    local available = (type(media) == "table" and type(media.availableQualities) == "table")
        and media.availableQualities or {}
    for _, quality in ipairs(available) do
        qualityOptions[#qualityOptions + 1] = { label = quality .. "p", value = quality }
    end

    audioFormatOptions = {
        { label = "Best", value = "best" },
        { label = "mp3", value = "mp3" },
        { label = "m4a", value = "m4a" },
        { label = "opus", value = "opus" },
        { label = "flac", value = "flac" },
        { label = "ogg", value = "ogg" },
    }

    audioTrackOptions = { { label = tr("panel.track_original"), value = "" } }
    for track = 1, 10 do
        audioTrackOptions[#audioTrackOptions + 1] = { label = tostring(track), value = tostring(track) }
    end

    subLangOptions = { { label = tr("panel.sub_all"), value = "all" } }
    local subLanguages = (type(media) == "table" and type(media.subLanguages) == "table")
        and media.subLanguages or {}
    for _, language in ipairs(subLanguages) do
        subLangOptions[#subLangOptions + 1] = { label = language, value = language }
    end

    postActionOptions = {
        { label = tr("panel.post_nothing"), value = "nothing" },
        { label = tr("panel.post_copy"), value = "copy" },
        { label = tr("panel.post_open"), value = "open" },
        { label = tr("panel.post_open_file"), value = "openFile" },
    }

    cookiesBrowserOptions = {
        { label = tr("panel.cookies_off"), value = "" },
        { label = "chrome", value = "chrome" },
        { label = "chromium", value = "chromium" },
        { label = "firefox", value = "firefox" },
        { label = "edge", value = "edge" },
        { label = "brave", value = "brave" },
        { label = "safari", value = "safari" },
    }
end

-- ── header ─────────────────────────────────────────────────────────────────────

local function header()
    local title = tr("panel.title")
    local subtitle = ""
    if extracting then
        subtitle = tr("panel.extracting")
    elseif type(active) == "table" and (active.status == "downloading" or active.status == "preparing") then
        subtitle = tr("panel.status_downloading")
    elseif type(active) == "table" and active.status == "paused" then
        subtitle = tr("panel.status_paused")
    elseif errorMessage ~= "" then
        subtitle = errorMessage
        title = tr("panel.title")
    end
    return ui.row({ align = "center", gap = 10 }, {
        ui.glyph({ name = "brand-youtube-kids", size = 20, color = "primary" }),
        ui.column({ gap = 0, flexGrow = 1 }, {
            ui.label({ text = title, fontSize = 17, fontWeight = "bold" }),
            ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant" }),
        }),
        ui.button({ glyph = "close", variant = "ghost", tooltip = tr("panel.close"), onClick = "onCloseClicked" }),
    })
end

-- ── url entry ──────────────────────────────────────────────────────────────────

local function urlInput()
    -- ui.input is uncontrolled (value seeds once). A forced clipboard read bumps the
    -- key so the field remounts and actually shows what was pasted.
    local key = "url-" .. tostring(seenClipboardVersion)
    local seed = ""
    if clipboard.forced == true and clipboardVersion > seenClipboardVersion then
        seenClipboardVersion = clipboardVersion
        urlValue = tostring(clipboard.text or "")
        seed = urlValue
    end
    return ui.row({ align = "center", gap = 8 }, {
        ui.input({
            key = key,
            value = seed,
            placeholder = tr("panel.url_placeholder"),
            flexGrow = 1,
            onChange = "onUrlChanged",
        }),
        ui.button({ text = tr("panel.paste"), tooltip = tr("panel.read_clipboard"), onClick = "onPasteClicked" }),
        ui.button({ glyph = "eraser", tooltip = tr("panel.clear"), onClick = "onClearClicked" }),
    })
end

local function urlButtons()
    local extractingNow = extracting
    return ui.row({ align = "center", gap = 8 }, {
        ui.button({
            text = extracting and tr("panel.extracting_btn") or tr("panel.extract"),
            variant = "primary",
            enabled = not extracting,
            flexGrow = 1,
            onClick = "onExtractClicked",
        }),
        ui.button({
            text = tr("panel.download"),
            variant = "primary",
            enabled = not extracting,
            flexGrow = 1,
            onClick = "onDownloadClicked",
        }),
        ui.button({ text = tr("panel.queue_next"), enabled = not extracting, onClick = "onEnqueueClicked" }),
    })
end

-- ── media card ─────────────────────────────────────────────────────────────────

local function modeButtons()
    local current = settings.downloadMode or "video"
    return ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("panel.mode"), color = "on_surface_variant" }),
        ui.spacer({ flexGrow = 1 }),
        ui.button({ text = tr("panel.mode_video"), controlSize = "sm", selected = current == "video", onClick = "onModeVideo" }),
        ui.button({ text = tr("panel.mode_audio"), controlSize = "sm", selected = current == "audio", onClick = "onModeAudio" }),
        ui.button({ text = tr("panel.mode_custom"), controlSize = "sm", selected = current == "custom", onClick = "onModeCustom" }),
    })
end

local function mediaCard()
    if media == nil then
        return nil
    end
    local children = {}

    children[#children + 1] = ui.image({
        path = tostring(media.thumbnailPath or media.thumbnail or ""),
        width = 320,
        height = 180,
        radius = 8,
        fit = "cover",
    })

    local sublabel = tostring(media.uploader or "")
    local durationText = dur(media.duration)
    if durationText ~= "0:00" then
        sublabel = sublabel .. "  ·  " .. durationText
    end
    if media.isPlaylist == true then
        sublabel = sublabel .. "  ·  " .. tr("panel.playlist_items", { count = tostring(media.count or "") })
    end
    children[#children + 1] = ui.label({ text = tostring(media.title or ""), fontSize = 14, fontWeight = "bold", maxLines = 3 })
    children[#children + 1] = ui.label({ text = sublabel, fontSize = 11, color = "on_surface_variant" })
    children[#children + 1] = ui.separator({})

    children[#children + 1] = modeButtons()
    local mode = settings.downloadMode or "video"
    if mode == "video" then
        children[#children + 1] = labelRow(tr("panel.quality"), selectFor(qualityOptions, settings.quality or "best", "onQualityChanged"))
    elseif mode == "audio" then
        children[#children + 1] = labelRow(tr("panel.audio_format"), selectFor(audioFormatOptions, settings.audioFormat or "best", "onAudioFormatChanged"))
        children[#children + 1] = labelRow(tr("panel.audio_track"), selectFor(audioTrackOptions, settings.audioLanguage or "", "onAudioTrackChanged"))
    else
        children[#children + 1] = labelRow(tr("panel.custom_format"), ui.input({
            value = tostring(settings.customFormatSelector or ""),
            placeholder = tr("panel.custom_format_placeholder"),
            width = CONTROL_WIDTH,
            onChange = "onFormatChanged",
        }))
    end

    children[#children + 1] = ui.separator({})

    children[#children + 1] = labelRow(tr("panel.sub_language"), selectFor(subLangOptions, settings.subLanguage or "all", "onSubLangChanged"))
    children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("panel.embed_subs"), color = "on_surface_variant" }),
        ui.spacer({ flexGrow = 1 }),
        ui.toggle({ checked = settings.embedSubs == true, onChange = "onToggleEmbedSubs" }),
    })
    children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("panel.include_auto_subs"), color = "on_surface_variant" }),
        ui.spacer({ flexGrow = 1 }),
        ui.toggle({ checked = settings.includeAutoSubs == true, onChange = "onToggleAutoSubs" }),
    })
    children[#children + 1] = ui.separator({})

    children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("panel.save_thumbnail"), color = "on_surface_variant" }),
        ui.spacer({ flexGrow = 1 }),
        ui.toggle({ checked = settings.downloadThumbnail == true, onChange = "onToggleThumbnail" }),
    })
    children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("panel.embed_thumbnail"), color = "on_surface_variant" }),
        ui.spacer({ flexGrow = 1 }),
        ui.toggle({ checked = settings.embedThumbnail == true, onChange = "onToggleEmbedThumb" }),
    })
    children[#children + 1] = ui.separator({})

    children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("panel.skip_sponsor"), color = "on_surface_variant" }),
        ui.spacer({ flexGrow = 1 }),
        ui.toggle({ checked = settings.sponsorBlock == true, onChange = "onToggleSponsorBlock" }),
    })
    if settings.sponsorBlock == true then
        children[#children + 1] = sponsorCategoriesRow()
    end
    children[#children + 1] = ui.separator({})

    children[#children + 1] = labelRow(tr("panel.after_download"), selectFor(postActionOptions, settings.postDownloadAction or "nothing", "onPostActionChanged"))

    return ui.column({ gap = 8, padding = 10, radius = 8, border = true, borderWidth = 1 }, children)
end

local SPONSOR_CATEGORIES = {
    { key = "sponsor", label = "cat.sponsor" },
    { key = "selfpromo", label = "cat.selfpromo" },
    { key = "interaction", label = "cat.interaction" },
    { key = "intro", label = "cat.intro" },
    { key = "outro", label = "cat.outro" },
    { key = "preview", label = "cat.preview" },
    { key = "filler", label = "cat.filler" },
    { key = "music_offtopic", label = "cat.music_offtopic" },
}

local function sponsorCategoriesRow()
    local activeCats = settings.sponsorBlockCategories or {}
    local chips = {}
    for _, category in ipairs(SPONSOR_CATEGORIES) do
        local checked = false
        for _, active in ipairs(activeCats) do
            if active == category.key then checked = true break end
        end
        chips[#chips + 1] = ui.button({
            key = "cat-" .. category.key,
            text = tr(category.label),
            controlSize = "sm",
            selected = checked,
            onClick = function()
                local nextCats = {}
                if checked then
                    for _, existing in ipairs(activeCats) do
                        if existing ~= category.key then nextCats[#nextCats + 1] = existing end
                    end
                else
                    for _, existing in ipairs(activeCats) do nextCats[#nextCats + 1] = existing end
                    nextCats[#nextCats + 1] = category.key
                end
                sendCommand("set_setting", { key = "sponsorBlockCategories", value = nextCats })
            end,
        })
    end
    return ui.row({ align = "start", gap = 4 }, chips)
end

-- ── active job / status card ───────────────────────────────────────────────────

local function statusLine()
    local status = tostring(active and active.status or "idle")
    local color = "on_surface_variant"
    local text = ""
    if status == "preparing" then text = tr("panel.status_preparing")
    elseif status == "downloading" then text = tr("panel.status_downloading"); color = "primary"
    elseif status == "paused" then text = tr("panel.status_paused"); color = "primary"
    elseif status == "completed" then text = tr("panel.status_completed"); color = "primary"
    elseif status == "error" then text = tr("panel.status_error"); color = "error"
    elseif status == "cancelled" then text = tr("panel.status_cancelled")
    end
    return { text = text, color = color }
end

local function activeCard()
    if type(active) ~= "table" or active.status == "idle" then
        return nil
    end
    local status = tostring(active.status)
    local children = {}
    local line = statusLine()
    children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = line.text, color = line.color, fontSize = 12, fontWeight = "bold" }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({ text = tostring(active.title or ""), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    })

    if status == "downloading" or status == "preparing" then
        local progress = type(active.progress) == "table" and active.progress or {}
        local percent = val(progress.percent) / 100
        children[#children + 1] = ui.progress({ progress = percent, height = 6, fill = "primary", track = "surface_variant", radius = 3 })
        local percentText = tostring(progress.percentText or "")
        if percentText == "" then percentText = string.format("%d%%", math.floor(val(progress.percent) + 0.5)) end
        local detail = tostring(progress.size or "")
            .. (progress.speed ~= "" and ("  ·  " .. progress.speed) or "")
            .. (progress.eta ~= "" and ("  ·  " .. tr("panel.eta_remaining", { eta = progress.eta })) or "")
        children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = percentText, fontSize = 20, fontWeight = "bold" }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({ text = detail, fontSize = 11, color = "on_surface_variant" }),
        })
        children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
            ui.button({ text = tr("panel.pause"), controlSize = "sm", enabled = status == "downloading", onClick = "onPauseClicked" }),
            ui.button({ glyph = "player-stop", variant = "destructive", controlSize = "sm", tooltip = tr("panel.cancel"), onClick = "onCancelClicked" }),
            ui.spacer({ flexGrow = 1 }),
            ui.button({ text = tr("panel.open_output_folder"), variant = "ghost", controlSize = "sm", onClick = "onOpenFolderClicked" }),
        })
    elseif status == "paused" then
        children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
            ui.button({ text = tr("panel.resume"), variant = "primary", onClick = "onResumeClicked" }),
            ui.button({ text = tr("panel.cancel"), variant = "ghost", onClick = "onCancelClicked" }),
        })
    elseif status == "completed" then
        children[#children + 1] = ui.label({ text = tostring(active.outputPath or ""), fontSize = 11, maxLines = 2, color = "on_surface_variant" })
        children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
            ui.button({ text = tr("panel.post_copy"), controlSize = "sm", onClick = "onCopyOutputClicked" }),
            ui.button({ text = tr("panel.post_open"), controlSize = "sm", onClick = "onOpenFolderClicked" }),
            ui.button({ text = tr("panel.post_open_file"), controlSize = "sm", onClick = "onOpenOutputFileClicked" }),
            ui.spacer({ flexGrow = 1 }),
            ui.button({ text = tr("panel.clear_activity"), variant = "ghost", controlSize = "sm", onClick = "onClearActivityClicked" }),
        })
    elseif status == "error" then
        children[#children + 1] = ui.label({ text = tostring(active.error or ""), fontSize = 11, color = "error", maxLines = 3 })
        children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
            ui.button({ text = tr("panel.retry_web"), controlSize = "sm", onClick = "onRetryWebClicked" }),
            ui.button({ text = tr("panel.extract"), controlSize = "sm", onClick = "onRetryClicked" }),
            ui.spacer({ flexGrow = 1 }),
            ui.button({ text = tr("panel.clear_activity"), variant = "ghost", controlSize = "sm", onClick = "onClearActivityClicked" }),
        })
    elseif status == "cancelled" then
        children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
            ui.spacer({ flexGrow = 1 }),
            ui.button({ text = tr("panel.clear_activity"), variant = "ghost", controlSize = "sm", onClick = "onClearActivityClicked" }),
        })
    end

    local rawLog = tostring(active.log or "")
    if settings.advancedVisible == true and rawLog ~= "" then
        children[#children + 1] = ui.separator({})
        children[#children + 1] = ui.label({ text = rawLog, fontSize = 10, color = "on_surface_variant", maxLines = 12 })
    end
    return ui.column({ gap = 8, padding = 10, radius = 8, border = true, borderWidth = 1 }, children)
end

-- ── queue ──────────────────────────────────────────────────────────────────────

local function queueCard()
    if #queue == 0 then
        return nil
    end
    local children = {}
    children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("panel.queue_title", { count = tostring(#queue) }), fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
        ui.spacer({ flexGrow = 1 }),
        ui.button({ text = tr("panel.run_queue", { count = tostring(#queue) }), controlSize = "sm", onClick = "onQueueNextClicked" }),
    })
    for index, item in ipairs(queue) do
        children[#children + 1] = ui.row({ key = "queue-" .. index, align = "center", gap = 8 }, {
            ui.label({ text = (tostring(item.title or "") ~= "" and item.title) or item.url, fontSize = 11, maxLines = 1, flexGrow = 1 }),
            ui.button({
                key = "queue-remove-" .. index,
                glyph = "x",
                variant = "ghost",
                controlSize = "sm",
                onClick = function()
                    sendCommand("remove_queued", { index = index })
                end,
            }),
        })
    end
    return ui.column({ gap = 6, padding = 10, radius = 8, border = true, borderWidth = 1 }, children)
end

-- ── history ────────────────────────────────────────────────────────────────────

local function historyCard()
    local history = settings.history or {}
    if type(history) ~= "table" or #history == 0 then
        return nil
    end
    local children = {}
    children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("panel.history_count", { count = tostring(#history) }), fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
        ui.spacer({ flexGrow = 1 }),
        ui.button({ text = tr("panel.clear_history"), variant = "ghost", controlSize = "sm", onClick = "onClearHistory" }),
    })
    local startIndex = math.max(1, #history - 7)
    for index = startIndex, #history do
        local entry = tostring(history[index])
        children[#children + 1] = ui.button({
            key = "history-" .. index,
            text = entry,
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                urlValue = entry
                extractPressed(entry)
            end,
        })
    end
    return ui.column({ gap = 4, padding = 10, radius = 8, border = true, borderWidth = 1 }, children)
end

-- ── advanced settings ──────────────────────────────────────────────────────────

local function toggleRow(label, offset, handler, checked)
    return ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = label, color = "on_surface_variant", width = CONTROL_LABEL_WIDTH + (offset or 0) }),
        ui.spacer({ flexGrow = 1 }),
        ui.toggle({ checked = checked, onChange = handler }),
    })
end

local function advancedSection()
    if settings.advancedVisible ~= true then
        return nil
    end
    local children = {}

    children[#children + 1] = labelRow(tr("panel.download_dir"), ui.input({
        value = tostring(expandHome(settings.downloadDir or "")),
        placeholder = "~/Downloads",
        width = CONTROL_WIDTH,
        onChange = "onDirChanged",
    }))
    children[#children + 1] = labelRow(tr("panel.output_template"), ui.input({
        value = tostring(settings.outputTemplate or ""),
        placeholder = "%(title)s.%(ext)s",
        width = CONTROL_WIDTH,
        onChange = "onOutputTemplateChanged",
    }))
    children[#children + 1] = labelRow(tr("panel.cookies_from_browser"), selectFor(cookiesBrowserOptions, settings.cookiesFromBrowser or "", "onCookiesBrowserChanged"))
    children[#children + 1] = labelRow(tr("panel.cookies_profile"), ui.input({
        value = tostring(settings.cookiesProfile or ""),
        placeholder = tr("panel.cookies_profile"),
        width = CONTROL_WIDTH,
        onChange = "onCookiesProfileChanged",
    }))
    children[#children + 1] = labelRow(tr("panel.cookies_file"), ui.input({
        value = tostring(settings.cookies or ""),
        placeholder = tr("panel.cookies_file"),
        width = CONTROL_WIDTH,
        onChange = "onCookiesFileChanged",
    }))
    children[#children + 1] = labelRow(tr("panel.proxy"), ui.input({
        value = tostring(settings.proxy or ""),
        placeholder = "https://user:pass@host:port",
        width = CONTROL_WIDTH,
        onChange = "onProxyChanged",
    }))
    children[#children + 1] = labelRow(tr("panel.rate_limit"), ui.input({
        value = tostring(settings.rateLimit or ""),
        placeholder = "10M",
        width = CONTROL_WIDTH,
        onChange = "onRateLimitChanged",
    }))
    children[#children + 1] = labelRow(tr("panel.concurrent_fragments"), ui.input({
        value = tostring(settings.concurrentFragments or ""),
        placeholder = "5",
        width = CONTROL_WIDTH,
        onChange = "onConcurrentChanged",
    }))
    children[#children + 1] = labelRow(tr("panel.custom_args"), ui.input({
        value = tostring(settings.customArgs or ""),
        placeholder = "--no-mtime",
        width = CONTROL_WIDTH,
        onChange = "onArgsChanged",
    }))
    children[#children + 1] = toggleRow(tr("panel.use_archive"), 0, "onToggleUseArchive", settings.useArchive == true)
    children[#children + 1] = toggleRow(tr("panel.save_history"), 0, "onToggleSaveHistory", settings.saveHistory ~= false)
    children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
        ui.spacer({ flexGrow = 1 }),
        ui.button({ text = tr("panel.reset_settings"), variant = "destructive", controlSize = "sm", onClick = "onResetSettings" }),
    })

    return ui.column({ gap = 8, padding = 10, radius = 8, border = true, borderWidth = 1 }, children)
end

-- ── render ─────────────────────────────────────────────────────────────────────

local function render()
    local children = {}

    if errorMessage ~= "" then
        children[#children + 1] = ui.label({ text = errorMessage, fontSize = 11, color = "error", maxLines = 3 })
    end
    if extracting then
        children[#children + 1] = ui.label({ text = tr("panel.extracting") .. " …", fontSize = 11, color = "on_surface_variant" })
    end

    local card = mediaCard()
    if card then children[#children + 1] = card end
    local statusCard = activeCard()
    if statusCard then children[#children + 1] = statusCard end
    local qcard = queueCard()
    if qcard then children[#children + 1] = qcard end

    children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
        ui.button({ text = tr("panel.advanced"), glyph = "settings", variant = "ghost", controlSize = "sm", onClick = "onToggleAdvanced" }),
        ui.spacer({ flexGrow = 1 }),
    })
    local advanced = advancedSection()
    if advanced then children[#children + 1] = advanced end

    local hcard = historyCard()
    if hcard then children[#children + 1] = hcard end

    panel.render(ui.column({ padding = 14, gap = 10, flexGrow = 1 }, {
        header(),
        urlInput(),
        urlButtons(),
        ui.scroll({ flexGrow = 1, gap = 10 }, children),
    }))
end

-- entry point (shell calls this global when the panel opens)
function onOpen()
    settings = noctalia.state.get("settings") or {}
    media = noctalia.state.get("media_info")
    active = noctalia.state.get("active_job") or {}
    queue = noctalia.state.get("queue") or {}
    extracting = noctalia.state.get("extracting") == true
    errorMessage = tostring(noctalia.state.get("error_message") or "")
    clipboard = noctalia.state.get("clipboard") or {}
    clipboardVersion = tonumber(clipboard.version) or 0
    urlValue = ""
    rebuildOptions()
    sendCommand("panel_open", { open = true })
    render()
end

-- ── command senders (globals) ─────────────────────────────────────────────────

function onCloseClicked() panel.close() end

function onUrlChanged(text) urlValue = tostring(text or "") end

function onPasteClicked() sendCommand("read_clipboard", { forced = true }) end

function onClearClicked() urlValue = "" end

local function extractPressed(entry)
    sendCommand("extract", { url = entry or urlValue })
end

function onExtractClicked() extractPressed(nil) end

function onDownloadClicked()
    if media == nil then return end
    local payload = { job = buildJob() }
    if payload.job.url ~= "" then sendCommand("download", payload) end
end

function onEnqueueClicked()
    if media == nil then return end
    local payload = { job = buildJob() }
    if payload.job.url ~= "" then sendCommand("enqueue", payload) end
end

function onQueueNextClicked() sendCommand("run_queue", {}) end

function onModeVideo() sendCommand("set_setting", { key = "downloadMode", value = "video" }) end
function onModeAudio() sendCommand("set_setting", { key = "downloadMode", value = "audio" }) end
function onModeCustom() sendCommand("set_setting", { key = "downloadMode", value = "custom" }) end

local function optionAt(options, index)
    return options[(tonumber(index) or 0) + 1]
end

function onQualityChanged(index)
    local entry = optionAt(qualityOptions, index)
    if entry then sendCommand("set_setting", { key = "quality", value = entry.value }) end
end

function onAudioFormatChanged(index)
    local entry = optionAt(audioFormatOptions, index)
    if entry then sendCommand("set_setting", { key = "audioFormat", value = entry.value }) end
end

function onAudioTrackChanged(index)
    local entry = optionAt(audioTrackOptions, index)
    if entry then sendCommand("set_setting", { key = "audioLanguage", value = entry.value }) end
end

function onSubLangChanged(index)
    local entry = optionAt(subLangOptions, index)
    if entry then sendCommand("set_setting", { key = "subLanguage", value = entry.value }) end
end

function onPostActionChanged(index)
    local entry = optionAt(postActionOptions, index)
    if entry then sendCommand("set_setting", { key = "postDownloadAction", value = entry.value }) end
end

function onCookiesBrowserChanged(index)
    local entry = optionAt(cookiesBrowserOptions, index)
    if entry then sendCommand("set_setting", { key = "cookiesFromBrowser", value = entry.value }) end
end

local function boolFrom(state)
    return state == "true" or state == true
end

function onToggleEmbedSubs(state) sendCommand("set_setting", { key = "embedSubs", value = boolFrom(state) }) end
function onToggleAutoSubs(state) sendCommand("set_setting", { key = "includeAutoSubs", value = boolFrom(state) }) end
function onToggleThumbnail(state) sendCommand("set_setting", { key = "downloadThumbnail", value = boolFrom(state) }) end
function onToggleEmbedThumb(state) sendCommand("set_setting", { key = "embedThumbnail", value = boolFrom(state) }) end
function onToggleSponsorBlock(state) sendCommand("set_setting", { key = "sponsorBlock", value = boolFrom(state) }) end
function onToggleUseArchive(state) sendCommand("set_setting", { key = "useArchive", value = boolFrom(state) }) end
function onToggleSaveHistory(state) sendCommand("set_setting", { key = "saveHistory", value = boolFrom(state) }) end

local function textSetting(key, text)
    sendCommand("set_setting", { key = key, value = tostring(text or "") })
end

function onDirChanged(text) textSetting("downloadDir", text) end
function onOutputTemplateChanged(text) textSetting("outputTemplate", text) end
function onFormatChanged(text) textSetting("customFormatSelector", text) end
function onArgsChanged(text) textSetting("customArgs", text) end
function onRateLimitChanged(text) textSetting("rateLimit", text) end
function onConcurrentChanged(text) textSetting("concurrentFragments", text) end
function onProxyChanged(text) textSetting("proxy", text) end
function onCookiesFileChanged(text) textSetting("cookies", text) end
function onCookiesProfileChanged(text) textSetting("cookiesProfile", text) end

function onToggleAdvanced() sendCommand("set_setting", { key = "advancedVisible", value = settings.advancedVisible ~= true }) end
function onResetSettings() sendCommand("reset_settings", {}) end
function onClearHistory() sendCommand("set_setting", { key = "history", value = {} }) end

function onPauseClicked() sendCommand("pause", {}) end
function onResumeClicked() sendCommand("resume", {}) end
function onCancelClicked() sendCommand("cancel", {}) end
function onClearActivityClicked() sendCommand("clear", {}) end
function onRetryWebClicked() sendCommand("retry", { job = nil, url = (type(media) == "table" and media.webpage_url) or urlValue }) end
function onRetryClicked() sendCommand("download", { job = active and active.job }) end

function onOpenOutputFileClicked()
    if active and active.outputPath ~= "" then
        noctalia.runAsync({ "xdg-open", active.outputPath }, function() end)
    end
end

function onOpenFolderClicked()
    if active and active.outputDir ~= "" then
        noctalia.runAsync({ "xdg-open", active.outputDir }, function() end)
    else
        sendCommand("open_folder", {})
    end
end

function onCopyOutputClicked()
    if active and active.outputPath ~= "" then
        noctalia.copyToClipboard(active.outputPath, "text/plain")
    end
end

-- ── state subscriptions ────────────────────────────────────────────────────────

local function refresh(key)
    settings = noctalia.state.get("settings") or {}
    media = noctalia.state.get("media_info")
    active = noctalia.state.get("active_job") or {}
    queue = noctalia.state.get("queue") or {}
    extracting = noctalia.state.get("extracting") == true
    errorMessage = tostring(noctalia.state.get("error_message") or "")
    clipboard = noctalia.state.get("clipboard") or {}
    clipboardVersion = tonumber(clipboard.version) or 0
    rebuildOptions()
    render()
end

noctalia.state.watch("settings", refresh)
noctalia.state.watch("media_info", refresh)
noctalia.state.watch("active_job", refresh)
noctalia.state.watch("queue", refresh)
noctalia.state.watch("extracting", refresh)
noctalia.state.watch("error_message", refresh)
noctalia.state.watch("clipboard", refresh)

return M