local M = {}

local defaults = {
  emoteFile = hs.configdir .. "/webex-emotes/emotes.json",
  allApps = false,
  allowedApplications = {
    "Webex"
  },
  defaultMode = "image",
  restoreTextClipboard = true,
  pasteDelay = 0.08,
  restartDelay = 0.25,
  restoreDelay = 0.8,
  filePasteMethod = "applescript",
  send = false,
  sendDelay = 1.2,
  maxBufferLength = 120,
  maxMenuAliases = 25,
  tabCompletion = true,
  tabCompletionPastes = true,
  tabCompletionDelay = 0.04,
  frequentAliases = {},
  showNotifications = true,
  menuBar = true
}

local state = {
  config = nil,
  watcher = nil,
  menu = nil,
  enabled = true,
  buffer = "",
  emotes = {},
  aliases = {},
  completionAliases = {},
  maxAliasLength = 0
}

local function notify(title, text)
  if not state.config or not state.config.showNotifications then
    return
  end

  hs.notify.new({
    title = title,
    informativeText = text
  }):send()
end

local function copyTable(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

local function mergeConfig(userConfig)
  local out = copyTable(defaults)
  for key, value in pairs(userConfig or {}) do
    out[key] = value
  end
  return out
end

local function dirname(path)
  return path:match("^(.*)/[^/]*$") or "."
end

local function expandPath(path, baseDir)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local home = os.getenv("HOME") or ""
  local expanded = path:gsub("^~", home)
  if expanded:sub(1, 1) == "/" then
    return expanded
  end

  return baseDir .. "/" .. expanded
end

local function fileExists(path)
  local handle = io.open(path, "rb")
  if handle then
    handle:close()
    return true
  end
  return false
end

local function fileUrl(path)
  local escaped = path:gsub("([^A-Za-z0-9%-._~/])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)

  return "file://" .. escaped
end

local function applescriptString(value)
  return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function validAlias(alias)
  return type(alias) == "string" and alias:match("^:[A-Za-z0-9][A-Za-z0-9_-]*:$") ~= nil
end

local function normalizeEmote(alias, value, baseDir)
  if not validAlias(alias) then
    return nil, "invalid alias " .. tostring(alias)
  end

  local emote
  if type(value) == "string" then
    emote = { path = value }
  elseif type(value) == "table" then
    emote = copyTable(value)
  else
    return nil, "invalid config for " .. alias
  end

  local path = expandPath(emote.path, baseDir)
  if not path then
    return nil, "missing path for " .. alias
  end

  emote.path = path
  emote.mode = emote.mode or state.config.defaultMode
  emote.alias = alias

  return emote, nil
end

local function rebuildAliases()
  state.aliases = {}
  state.completionAliases = {}
  state.maxAliasLength = 0

  for alias, _ in pairs(state.emotes) do
    table.insert(state.aliases, alias)
    if #alias > state.maxAliasLength then
      state.maxAliasLength = #alias
    end
  end

  table.sort(state.aliases, function(left, right)
    return #left > #right
  end)

  local seen = {}
  for _, alias in ipairs(state.config.frequentAliases or {}) do
    if state.emotes[alias] and not seen[alias] then
      table.insert(state.completionAliases, alias)
      seen[alias] = true
    end
  end

  local alphabetical = copyTable(state.aliases)
  table.sort(alphabetical)
  for _, alias in ipairs(alphabetical) do
    if not seen[alias] then
      table.insert(state.completionAliases, alias)
      seen[alias] = true
    end
  end
end

local function loadEmotes()
  local raw = hs.json.read(state.config.emoteFile)
  local baseDir = dirname(state.config.emoteFile)

  state.emotes = {}

  if type(raw) ~= "table" then
    notify("Webex Emotes", "No emotes loaded from " .. state.config.emoteFile)
    rebuildAliases()
    return
  end

  local source = raw.emotes or raw
  local errors = {}

  for alias, value in pairs(source) do
    local emote, err = normalizeEmote(alias, value, baseDir)
    if emote then
      state.emotes[alias] = emote
    else
      table.insert(errors, err)
    end
  end

  rebuildAliases()

  if #errors > 0 then
    notify("Webex Emotes", table.concat(errors, "\n"))
  else
    notify("Webex Emotes", "Loaded " .. tostring(#state.aliases) .. " emote aliases")
  end
end

local function appAllowed()
  if state.config.allApps then
    return true
  end

  local app = hs.application.frontmostApplication()
  if not app then
    return false
  end

  local name = string.lower(app:name() or "")
  local bundleId = string.lower(app:bundleID() or "")

  for _, allowed in ipairs(state.config.allowedApplications or {}) do
    local needle = string.lower(allowed)
    if name:find(needle, 1, true) or bundleId:find(needle, 1, true) then
      return true
    end
  end

  return false
end

local function findAlias()
  for _, alias in ipairs(state.aliases) do
    if state.buffer:sub(-#alias) == alias then
      return alias, state.emotes[alias]
    end
  end

  return nil, nil
end

local function currentAliasPrefix()
  return state.buffer:match("(:[A-Za-z0-9_-]*)$")
end

local function findCompletion(prefix)
  if not state.config.tabCompletion or type(prefix) ~= "string" or prefix == "" then
    return nil, nil
  end

  local lowerPrefix = string.lower(prefix)
  for _, alias in ipairs(state.completionAliases) do
    if string.sub(string.lower(alias), 1, #lowerPrefix) == lowerPrefix then
      return alias, state.emotes[alias]
    end
  end

  return nil, nil
end

local function setClipboardForEmote(emote)
  if not fileExists(emote.path) then
    notify("Webex Emotes", "Missing file for " .. emote.alias .. ": " .. emote.path)
    return false
  end

  if emote.mode == "file" then
    if state.config.filePasteMethod == "applescript" then
      hs.pasteboard.clearContents()
      local ok = hs.osascript.applescript(
        "set the clipboard to (POSIX file " .. applescriptString(emote.path) .. ")"
      )
      if ok then
        return true
      end
    end

    return hs.pasteboard.writeObjects({ url = fileUrl(emote.path) })
  end

  local image = hs.image.imageFromPath(emote.path)
  if not image then
    notify("Webex Emotes", "Could not load image for " .. emote.alias)
    return false
  end

  return hs.pasteboard.writeObjects(image)
end

local function restartWatcher(delay)
  hs.timer.doAfter(delay or state.config.restartDelay, function()
    if state.enabled and state.watcher and not state.watcher:isEnabled() then
      state.watcher:start()
    end
  end)
end

local function deleteAlias(alias, app)
  for _ = 1, #alias do
    hs.eventtap.keyStroke({}, "delete", 0, app)
  end
end

local function pasteEmote(alias, emote)
  if not appAllowed() then
    return
  end

  local app = hs.application.frontmostApplication()
  state.buffer = ""

  if state.watcher then
    state.watcher:stop()
  end

  hs.timer.doAfter(0.02, function()
    deleteAlias(alias, app)

    hs.timer.doAfter(0.04, function()
      local oldText = nil
      if state.config.restoreTextClipboard then
        oldText = hs.pasteboard.getContents()
      end

      if not setClipboardForEmote(emote) then
        restartWatcher()
        return
      end

      hs.timer.doAfter(state.config.pasteDelay, function()
        hs.eventtap.keyStroke({"cmd"}, "v", 0, app)

        local shouldSend = emote.send
        if shouldSend == nil then
          shouldSend = state.config.send
        end

        if shouldSend then
          hs.timer.doAfter(emote.sendDelay or state.config.sendDelay, function()
            hs.eventtap.keyStroke({}, "return", 0, app)
          end)
        end

        if oldText ~= nil and state.config.restoreTextClipboard then
          hs.timer.doAfter(state.config.restoreDelay, function()
            hs.pasteboard.setContents(oldText)
          end)
        end

        restartWatcher()
      end)
    end)
  end)
end

local function completeAlias(prefix, alias, emote)
  local app = hs.application.frontmostApplication()
  local suffix = alias:sub(#prefix + 1)

  if state.watcher then
    state.watcher:stop()
  end

  if suffix ~= "" then
    hs.eventtap.keyStrokes(suffix, app)
  end

  state.buffer = state.buffer .. suffix

  if state.config.tabCompletionPastes then
    hs.timer.doAfter(state.config.tabCompletionDelay, function()
      pasteEmote(alias, emote)
    end)
  else
    restartWatcher()
  end
end

local function trimBuffer()
  local maxLength = math.max(state.config.maxBufferLength, state.maxAliasLength + 5)
  if #state.buffer > maxLength then
    state.buffer = state.buffer:sub(-maxLength)
  end
end

local function handleKeyDown(event)
  if not state.enabled or #state.aliases == 0 or not appAllowed() then
    state.buffer = ""
    return false
  end

  if hs.eventtap.isSecureInputEnabled() then
    state.buffer = ""
    return false
  end

  local flags = event:getFlags()
  if flags.cmd or flags.ctrl or flags.alt or flags.fn then
    state.buffer = ""
    return false
  end

  local keyName = hs.keycodes.map[event:getKeyCode()]
  if keyName == "delete" then
    state.buffer = state.buffer:sub(1, -2)
    return false
  end

  if keyName == "tab" then
    local prefix = currentAliasPrefix()
    local alias, emote = findCompletion(prefix)
    if alias and emote then
      completeAlias(prefix, alias, emote)
      return true
    end

    state.buffer = ""
    return false
  end

  if keyName == "escape" or keyName == "return" then
    state.buffer = ""
    return false
  end

  local chars = event:getCharacters()
  if type(chars) ~= "string" or chars == "" or chars:match("%c") then
    return false
  end

  state.buffer = state.buffer .. chars
  trimBuffer()

  local alias, emote = findAlias()
  if alias and emote then
    pasteEmote(alias, emote)
  end

  return false
end

local function menuItems()
  local items = {
    {
      title = state.enabled and "Disable Emote Paster" or "Enable Emote Paster",
      fn = function()
        state.enabled = not state.enabled
        state.buffer = ""
        if state.enabled and state.watcher then
          state.watcher:start()
        elseif state.watcher then
          state.watcher:stop()
        end
        M.refreshMenu()
      end
    },
    {
      title = "Reload Emotes",
      fn = function()
        loadEmotes()
        M.refreshMenu()
      end
    },
    { title = "-" }
  }

  if #state.aliases == 0 then
    table.insert(items, { title = "No emotes loaded", disabled = true })
    return items
  end

  table.insert(items, {
    title = tostring(#state.aliases) .. " emotes loaded",
    disabled = true
  })

  local visibleCount = math.min(#state.aliases, state.config.maxMenuAliases or 25)
  for index = 1, visibleCount do
    table.insert(items, { title = state.aliases[index], disabled = true })
  end

  if #state.aliases > visibleCount then
    table.insert(items, {
      title = "... " .. tostring(#state.aliases - visibleCount) .. " more",
      disabled = true
    })
  end

  return items
end

function M.refreshMenu()
  if not state.config.menuBar then
    return
  end

  if not state.menu then
    state.menu = hs.menubar.new()
  end

  if state.menu then
    state.menu:setTitle(state.enabled and "WxE" or "WxE-")
    state.menu:setMenu(menuItems)
  end
end

function M.reload()
  loadEmotes()
  M.refreshMenu()
end

function M.stop()
  state.enabled = false
  state.buffer = ""

  if state.watcher then
    state.watcher:stop()
  end

  M.refreshMenu()
end

function M.start(userConfig)
  state.config = mergeConfig(userConfig)
  state.enabled = true
  state.buffer = ""

  loadEmotes()

  if state.watcher then
    state.watcher:stop()
  end

  state.watcher = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, handleKeyDown)
  state.watcher:start()

  M.refreshMenu()

  return M
end

return M
