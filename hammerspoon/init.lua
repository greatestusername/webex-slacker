local webexEmotes = require("webex_emotes")

webexEmotes.start({
  emoteFile = hs.configdir .. "/webex-emotes/emotes.json",

  -- Keep this false for Webex desktop. If you use web.webex.com in a browser,
  -- either set allApps = true or add your browser to allowedApplications.
  allApps = false,

  defaultMode = "image",
  restoreTextClipboard = true,
  filePasteMethod = "applescript",
  send = false,
  sendDelay = 1.2,
  maxMenuAliases = 25,
  tabCompletion = true,
  tabCompletionPastes = true,
  frequentAliases = {},
  showNotifications = true,
  menuBar = true
})

hs.hotkey.bind({"ctrl", "alt", "cmd"}, "R", function()
  hs.reload()
end)

hs.notify.new({
  title = "Hammerspoon",
  informativeText = "Webex emote config loaded"
}):send()
