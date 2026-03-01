-- ChatAutoReply.lua

local ADDON_NAME = ...
ChatAutoReplyDB = ChatAutoReplyDB or {}

-- ============================================================
-- Defaults / Schema
-- ============================================================
local defaults = {
  enabled = true,
  ignoreCase = true,

  ignoreSelf = true,
  ignoreLikelyAddonMessages = true,

  globalCooldownSeconds = 1, -- safety brake across all rules (0 disables)

  rules = {
    {
      enabled = true,
      name = "Hello reply",
      matchMode = "CONTAINS", -- CONTAINS | STARTS | EXACT | WORD
      matchText = "hello",
      replyText = "Hey!",
      perSenderCooldownSeconds = 30,
      channels = {
        guild = true,
        party = false,
        raid  = false,
        whisper = true,
        say = false,
        yell = false,
      },
    },
  },
}

local state = {
  lastGlobalReplyAt = 0,
  -- sender::ruleIndex -> time
  senderRuleLastReplyAt = {},
}

local function CopyDefaults(src, dst)
  if type(dst) ~= "table" then dst = {} end
  for k, v in pairs(src) do
    if type(v) == "table" then
      dst[k] = CopyDefaults(v, dst[k])
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
  return dst
end

local function Now() return GetTime() end

-- ============================================================
-- Migration / Normalization
-- ============================================================
local function NormalizeRule(rule)
  if type(rule) ~= "table" then rule = {} end

  if rule.enabled == nil then rule.enabled = true end
  if not rule.name then rule.name = "Rule" end
  if not rule.matchMode then rule.matchMode = "CONTAINS" end
  if rule.matchText == nil then rule.matchText = "" end
  if rule.replyText == nil then rule.replyText = "" end
  if rule.perSenderCooldownSeconds == nil then rule.perSenderCooldownSeconds = 30 end

  rule.channels = rule.channels or {}
  local ch = rule.channels
  if ch.guild == nil then ch.guild = true end
  if ch.party == nil then ch.party = false end
  if ch.raid == nil then ch.raid = false end
  if ch.whisper == nil then ch.whisper = true end
  if ch.say == nil then ch.say = false end
  if ch.yell == nil then ch.yell = false end

  return rule
end

local function MigrateDB()
  ChatAutoReplyDB = CopyDefaults(defaults, ChatAutoReplyDB)
  ChatAutoReplyDB.rules = ChatAutoReplyDB.rules or {}

  -- Normalize all rules
  for i = 1, #ChatAutoReplyDB.rules do
    ChatAutoReplyDB.rules[i] = NormalizeRule(ChatAutoReplyDB.rules[i])
  end

  -- If no rules exist, add one default
  if #ChatAutoReplyDB.rules == 0 then
    table.insert(ChatAutoReplyDB.rules, NormalizeRule({
      enabled = true,
      name = "New rule",
      matchMode = "CONTAINS",
      matchText = "",
      replyText = "",
      perSenderCooldownSeconds = 30,
      channels = { guild = true, whisper = true },
    }))
  end
end

-- ============================================================
-- Self detection
-- ============================================================
local PLAYER_NAME, PLAYER_FULL

local function GetPlayerFullName()
  local name, realm = UnitName("player")
  realm = realm or GetRealmName() or ""
  realm = realm:gsub("%s+", "")
  if realm ~= "" then
    return name .. "-" .. realm
  end
  return name
end

local function IsSelfSender(sender)
  if not ChatAutoReplyDB.ignoreSelf then return false end
  if not sender or sender == "" then return false end
  return (sender == PLAYER_NAME) or (sender == PLAYER_FULL)
end

-- ============================================================
-- Filtering "addon/bot-ish" messages
-- IMPORTANT: Do NOT block item links (|H...) — guild chat is link-heavy.
-- We only block very common addon/system patterns:
--   - Control code: \001
--   - Texture/icon: |T...|t
--   - Some bracketed prefixes: [DBM], [Details], etc. (optional heuristic)
-- ============================================================
local function LooksLikeAddonMessage(msg)
  if not ChatAutoReplyDB.ignoreLikelyAddonMessages then return false end
  if not msg or msg == "" then return false end

  if msg:find("\001") then return true end
  if msg:find("|T") then return true end

  -- Optional prefix heuristic
  local prefix = msg:match("^%[(.-)%]")
  if prefix then
    local p = prefix:lower()
    if p:find("dbm") or p:find("details") or p:find("bigwigs") or p:find("wa") then
      return true
    end
  end

  return false
end

-- ============================================================
-- Matching
-- ============================================================
local function NormalizeText(s)
  s = s or ""
  if ChatAutoReplyDB.ignoreCase then
    return string.lower(s)
  end
  return s
end

local function EscapePattern(s)
  -- Escapes Lua pattern magic characters
  return (s:gsub("(%W)","%%%1"))
end

local function RuleMatches(rule, msg)
  local needle = NormalizeText(rule.matchText or "")
  if needle == "" then return false end
  local hay = NormalizeText(msg or "")

  local mode = (rule.matchMode or "CONTAINS"):upper()

  if mode == "EXACT" then
    return hay == needle
  elseif mode == "STARTS" then
    return hay:sub(1, #needle) == needle
  elseif mode == "WORD" then
    -- Whole word: use Lua patterns with boundaries approximated
    -- Word chars: alnum + underscore. This is decent for chat use.
    local pat = "%f[%w]" .. EscapePattern(needle) .. "%f[%W]"
    return hay:find(pat) ~= nil
  else
    -- CONTAINS (default): plain substring
    return hay:find(needle, 1, true) ~= nil
  end
end

-- ============================================================
-- Throttling
-- ============================================================
local function GlobalCooldownReady()
  local cd = tonumber(ChatAutoReplyDB.globalCooldownSeconds) or 0
  if cd <= 0 then return true end
  return (Now() - state.lastGlobalReplyAt) >= cd
end

local function PerSenderRuleCooldownReady(ruleIndex, sender)
  local rule = (ChatAutoReplyDB.rules or {})[ruleIndex]
  local cd = tonumber((rule and rule.perSenderCooldownSeconds) or 0) or 0
  if cd <= 0 then return true end

  local key = (sender or "") .. "::" .. tostring(ruleIndex)
  local last = state.senderRuleLastReplyAt[key] or 0
  return (Now() - last) >= cd
end

local function MarkReplied(ruleIndex, sender)
  state.lastGlobalReplyAt = Now()
  local key = (sender or "") .. "::" .. tostring(ruleIndex)
  state.senderRuleLastReplyAt[key] = state.lastGlobalReplyAt
end

-- ============================================================
-- Chat routing (reply ONLY in the channel that triggered)
-- ============================================================
local function SendReply(kind, sender, text)
  if kind == "WHISPER" then
    if sender and sender ~= "" then
      SendChatMessage(text, "WHISPER", nil, sender)
    end
    return
  end
  SendChatMessage(text, kind)
end

local EVENT_MAP = {
  CHAT_MSG_GUILD =        { kind = "GUILD",   key = "guild" },
  CHAT_MSG_PARTY =        { kind = "PARTY",   key = "party" },
  CHAT_MSG_PARTY_LEADER = { kind = "PARTY",   key = "party" },
  CHAT_MSG_RAID =         { kind = "RAID",    key = "raid" },
  CHAT_MSG_RAID_LEADER =  { kind = "RAID",    key = "raid" },
  CHAT_MSG_WHISPER =      { kind = "WHISPER", key = "whisper" },
  CHAT_MSG_SAY =          { kind = "SAY",     key = "say" },
  CHAT_MSG_YELL =         { kind = "YELL",    key = "yell" },
}

local function HandleMessage(eventName, msg, sender)
  if not ChatAutoReplyDB.enabled then return end
  if IsSelfSender(sender) then return end
  if LooksLikeAddonMessage(msg) then return end

  local map = EVENT_MAP[eventName]
  if not map then return end

  if not GlobalCooldownReady() then return end

  local rules = ChatAutoReplyDB.rules or {}
  for i = 1, #rules do
    local rule = rules[i]
    if rule and rule.enabled then
      local ch = rule.channels or {}
      if ch[map.key] then
        if RuleMatches(rule, msg) then
          local reply = rule.replyText or ""
          if reply ~= "" and PerSenderRuleCooldownReady(i, sender) then
            SendReply(map.kind, sender, reply)
            MarkReplied(i, sender)
            return -- first match wins to avoid spam
          end
        end
      end
    end
  end
end


-- ============================================================
-- UI
-- ============================================================
local UI = {
  selectedIndex = 1,
  ruleButtons = {},
}

local function EnsureSelectedIndexValid()
  local n = #(ChatAutoReplyDB.rules or {})
  if n <= 0 then
    UI.selectedIndex = 0
    return
  end
  if UI.selectedIndex < 1 then UI.selectedIndex = 1 end
  if UI.selectedIndex > n then UI.selectedIndex = n end
end

local function NewRule()
  return NormalizeRule({
    enabled = true,
    name = "New rule",
    matchMode = "CONTAINS",
    matchText = "",
    replyText = "",
    perSenderCooldownSeconds = 30,
    channels = {
      guild = true,
      party = false,
      raid  = false,
      whisper = true,
      say = false,
      yell = false,
    },
  })
end

local function DeepCopy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = DeepCopy(v) end
  return r
end

local MATCH_MODES = {
  { key = "CONTAINS", text = "Contains" },
  { key = "STARTS",   text = "Starts With" },
  { key = "EXACT",    text = "Exact" },
  { key = "WORD",     text = "Whole Word" },
}

local function ModeText(key)
  key = (key or "CONTAINS"):upper()
  for _, m in ipairs(MATCH_MODES) do
    if m.key == key then return m.text end
  end
  return "Contains"
end

local function CreateUI()
  if UI.frame then return end

  -- ===== Layout constants =====
  local PAD = 12
  local HEADER_H = 40
  local GAP = 8
  local LINE = 24
  local LABEL = 16

  local LEFT_W = 260
  local RIGHT_W = 420
  local COLUMN_GAP = 13

  local LIST_BTN_H = 22
  local LIST_BTN_GAP = 6
  local LIST_BTN_AREA_H = (LIST_BTN_H * 2) + LIST_BTN_GAP + 8

  local MIN_W = PAD + LEFT_W + COLUMN_GAP + RIGHT_W + PAD
  local MIN_H = 550

  -- ===== Frame =====
  local f = CreateFrame("Frame", "ChatAutoReplyFrame", UIParent, "BackdropTemplate")
  UI.frame = f
  f:SetSize(MIN_W, MIN_H)
  f:SetPoint("CENTER")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:Hide()

  -- Resizing (compat safe)
  f:SetResizable(true)
  if f.SetResizeBounds then
    f:SetResizeBounds(MIN_W, MIN_H)
  elseif f.SetMinResize then
    f:SetMinResize(MIN_W, MIN_H)
  end

  f:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
  })
  f:SetBackdropColor(0, 0, 0, 0.9)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -10)
  title:SetText("ChatAutoReply")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  -- Resize handle (bottom-right)
  local resize = CreateFrame("Button", nil, f)
  resize:SetSize(16, 16)
  resize:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 6)
  resize:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  resize:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  resize:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  resize:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
  resize:SetScript("OnMouseUp", function() f:StopMovingOrSizing() end)
  UI.resize = resize

  -- ===== Panels =====
  local left = CreateFrame("Frame", nil, f)
  left:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -HEADER_H)
  left:SetWidth(LEFT_W)

  local right = CreateFrame("Frame", nil, f)
  right:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + LEFT_W + COLUMN_GAP, -HEADER_H)
  right:SetWidth(RIGHT_W)

  -- ===== Helpers =====
  local function MakeLabel(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText(text)
    return fs
  end

  local function MakeBigLabel(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText(text)
    return fs
  end

  local function MakeEdit(parent, w, x, y, numeric)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(w, 24)
    eb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    eb:SetAutoFocus(false)
    if numeric then eb:SetNumeric(true) end
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return eb
  end

  local function MakeCheck(parent, label, x, y, getFn, setFn, hitExpand)
    local cb = CreateFrame("CheckButton", nil, parent, "ChatConfigCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb:SetSize(24, 24)
    cb.Text:SetText(label)
    cb:SetChecked(getFn() and true or false)
    cb:SetHitRectInsets(-2, -(hitExpand or 220), -2, -2)
    cb:SetScript("OnClick", function(self)
      setFn(self:GetChecked() and true or false)
    end)
    return cb
  end

  -- ============================================================
  -- LEFT PANEL: list + scroll
  -- ============================================================
  local leftTitle = left:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  leftTitle:SetPoint("TOPLEFT", left, "TOPLEFT", 0, 0)
  leftTitle:SetText("Rules")

  local scroll = CreateFrame("ScrollFrame", nil, left, "UIPanelScrollFrameTemplate")
  UI.scroll = scroll

  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(1, 1)
  scroll:SetScrollChild(content)
  UI.listContent = content

  local addBtn = CreateFrame("Button", nil, left, "UIPanelButtonTemplate")
  addBtn:SetSize(80, LIST_BTN_H)
  addBtn:SetText("Add")
  UI.addBtn = addBtn

  local dupBtn = CreateFrame("Button", nil, left, "UIPanelButtonTemplate")
  dupBtn:SetSize(80, LIST_BTN_H)
  dupBtn:SetText("Duplicate")

  local delBtn = CreateFrame("Button", nil, left, "UIPanelButtonTemplate")
  delBtn:SetSize(80, LIST_BTN_H)
  delBtn:SetText("Delete")

  local upBtn = CreateFrame("Button", nil, left, "UIPanelButtonTemplate")
  upBtn:SetSize(80, LIST_BTN_H)
  upBtn:SetText("Up")

  local downBtn = CreateFrame("Button", nil, left, "UIPanelButtonTemplate")
  downBtn:SetSize(80, LIST_BTN_H)
  downBtn:SetText("Down")

  addBtn:SetPoint("BOTTOMLEFT", left, "BOTTOMLEFT", 0, LIST_BTN_H + LIST_BTN_GAP)
  dupBtn:SetPoint("LEFT", addBtn, "RIGHT", 6, 0)
  delBtn:SetPoint("LEFT", dupBtn, "RIGHT", 6, 0)

  upBtn:SetPoint("BOTTOMLEFT", left, "BOTTOMLEFT", 0, 0)
  downBtn:SetPoint("LEFT", upBtn, "RIGHT", 6, 0)

  -- ============================================================
  -- RIGHT PANEL: editor (cursor layout)
  -- ============================================================
  local y = 0

  MakeCheck(right, "Addon enabled", 0, y,
    function() return ChatAutoReplyDB.enabled end,
    function(v) ChatAutoReplyDB.enabled = v end, 180
  )
  MakeCheck(right, "Ignore case", 160, y,
    function() return ChatAutoReplyDB.ignoreCase end,
    function(v) ChatAutoReplyDB.ignoreCase = v end, 140
  )
  y = y - LINE

  MakeCheck(right, "Don't reply to myself", 0, y,
    function() return ChatAutoReplyDB.ignoreSelf end,
    function(v) ChatAutoReplyDB.ignoreSelf = v end, 260
  )
  y = y - LINE

  MakeCheck(right, "Ignore likely addon/bot posts", 0, y,
    function() return ChatAutoReplyDB.ignoreLikelyAddonMessages end,
    function(v) ChatAutoReplyDB.ignoreLikelyAddonMessages = v end, 320
  )
  y = y - (LINE + GAP)

  MakeLabel(right, "Global cooldown (sec):", 0, y)
  local gcBox = MakeEdit(right, 60, 160, y + 4, true)
  gcBox:SetText(tostring(ChatAutoReplyDB.globalCooldownSeconds or 0))
  gcBox:SetScript("OnEnterPressed", function(self)
    ChatAutoReplyDB.globalCooldownSeconds = tonumber(self:GetText()) or 0
    self:ClearFocus()
  end)
  y = y - (LINE + GAP + 6)

  UI.editorTitle = MakeBigLabel(right, "Rule Editor", 0, y)
  y = y - (LABEL + GAP + 6)

  UI.ruleEnabled = MakeCheck(right, "Enabled", 0, y,
    function()
      EnsureSelectedIndexValid()
      local r = (ChatAutoReplyDB.rules or {})[UI.selectedIndex]
      return r and r.enabled
    end,
    function(v)
      local r = (ChatAutoReplyDB.rules or {})[UI.selectedIndex]
      if r then r.enabled = v end
    end, 120
  )
  y = y - (LINE + GAP)

  MakeLabel(right, "Name:", 0, y)
  UI.nameBox = MakeEdit(right, 260, 60, y + 4, false)
  y = y - (LINE + GAP)

  -- Match mode dropdown
  MakeLabel(right, "Match mode:", 0, y)
  local dd = CreateFrame("Frame", "CAR_MatchModeDropDown", right, "UIDropDownMenuTemplate")
  dd:SetPoint("TOPLEFT", right, "TOPLEFT", 80, y + 8)
  UI.modeDropDown = dd
  y = y - (LINE + GAP)

  MakeLabel(right, "Match text:", 0, y)
  y = y - (LABEL + 6)
  UI.matchBox = MakeEdit(right, 380, 0, y, false)
  y = y - (LINE + GAP)

  MakeLabel(right, "Reply text:", 0, y)
  y = y - (LABEL + 6)
  UI.replyBox = MakeEdit(right, 380, 0, y, false)
  y = y - (LINE + GAP)

  MakeLabel(right, "Per-sender cooldown (sec):", 0, y)
  UI.prBox = MakeEdit(right, 60, 190, y + 4, true)
  y = y - (LINE + GAP)

  MakeLabel(right, "Listen to (for this rule):", 0, y)
  y = y - (LABEL + 4)

  UI.chChecks = {}
  local function AddRuleChan(key, label, x)
    UI.chChecks[key] = MakeCheck(right, label, x, y,
      function()
        local r = (ChatAutoReplyDB.rules or {})[UI.selectedIndex]
        local ch = r and r.channels or {}
        return ch[key]
      end,
      function(v)
        local r = (ChatAutoReplyDB.rules or {})[UI.selectedIndex]
        if not r then return end
        r.channels = r.channels or {}
        r.channels[key] = v
      end, 110
    )
  end

  AddRuleChan("guild", "Guild", 0)
  AddRuleChan("party", "Party", 110)
  AddRuleChan("raid",  "Raid",  220)
  y = y - LINE

  AddRuleChan("whisper", "Whisper", 0)
  AddRuleChan("say",     "Say",     110)
  AddRuleChan("yell",    "Yell",    220)
  y = y - (LINE + GAP)

  UI.testBtn = CreateFrame("Button", nil, right, "UIPanelButtonTemplate")
  UI.testBtn:SetSize(120, 22)
  UI.testBtn:SetPoint("TOPLEFT", right, "TOPLEFT", 0, y)
  UI.testBtn:SetText("Test match")

  UI.testOut = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  UI.testOut:SetPoint("LEFT", UI.testBtn, "RIGHT", 10, 0)
  UI.testOut:SetText("")

  y = y - (LINE + GAP)

  -- ============================================================
  -- Layout (resizing)
  -- ============================================================
  local function Layout()
    local w, h = f:GetSize()

    -- Hard clamp in case resize bounds isn't supported
    local clamped = false
    if w < MIN_W then w = MIN_W; clamped = true end
    if h < MIN_H then h = MIN_H; clamped = true end
    if clamped then
      f:SetSize(w, h)
      return
    end

    local panelH = h - HEADER_H - PAD
    if panelH < 200 then panelH = 200 end

    left:SetHeight(panelH)
    right:SetHeight(panelH)

    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", left, "TOPLEFT", 0, -22)
    scroll:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", -28, LIST_BTN_AREA_H)
  end

  f:SetScript("OnSizeChanged", function() Layout() end)
  Layout()

  -- ============================================================
  -- UI Refresh Functions
  -- ============================================================
  local function ClearRuleButtons()
    for _, b in ipairs(UI.ruleButtons) do
      b:Hide()
      b:SetParent(nil)
    end
    UI.ruleButtons = {}
  end

  local function RefreshRuleList()
    ClearRuleButtons()
    EnsureSelectedIndexValid()

    local rules = ChatAutoReplyDB.rules or {}
    local yy = 0
    local maxWidth = 220
    for i = 1, #rules do
      local r = rules[i]
      local btn = CreateFrame("Button", nil, UI.listContent, "UIPanelButtonTemplate")
      btn:SetSize(maxWidth, 22)
      btn:SetPoint("TOPLEFT", UI.listContent, "TOPLEFT", 0, -yy)
      yy = yy + 24

      local name = (r and r.name) or ("Rule " .. i)
      local prefix = (r and r.enabled) and "" or "⛔ "
      btn:SetText(prefix .. name)

      btn:SetScript("OnClick", function()
        UI.selectedIndex = i
        RefreshRuleList()
        UI.RefreshEditor()
      end)

      if i == UI.selectedIndex then btn:LockHighlight() else btn:UnlockHighlight() end
      table.insert(UI.ruleButtons, btn)
    end

    UI.listContent:SetSize(maxWidth, math.max(1, yy))
  end

  function UI.RefreshEditor()
    EnsureSelectedIndexValid()
    local idx = UI.selectedIndex
    local rules = ChatAutoReplyDB.rules or {}

    if idx == 0 or not rules[idx] then
      UI.editorTitle:SetText("Rule Editor (no rules)")
      UI.ruleEnabled:SetChecked(false)
      UI.nameBox:SetText("")
      UI.matchBox:SetText("")
      UI.replyBox:SetText("")
      UI.prBox:SetText("")
      UIDropDownMenu_SetText(UI.modeDropDown, "Contains")
      for _, cb in pairs(UI.chChecks) do cb:SetChecked(false) end
      return
    end

    local r = NormalizeRule(rules[idx])
    rules[idx] = r

    UI.editorTitle:SetText(("Rule Editor (#%d)"):format(idx))
    UI.ruleEnabled:SetChecked(r.enabled and true or false)
    UI.nameBox:SetText(r.name or ("Rule " .. idx))
    UI.matchBox:SetText(r.matchText or "")
    UI.replyBox:SetText(r.replyText or "")
    UI.prBox:SetText(tostring(r.perSenderCooldownSeconds or 0))

    UIDropDownMenu_SetText(UI.modeDropDown, ModeText(r.matchMode))

    local ch = r.channels or {}
    for key, cb in pairs(UI.chChecks) do
      cb:SetChecked(ch[key] and true or false)
    end
  end

  function UI.RefreshAll()
    RefreshRuleList()
    UI.RefreshEditor()
  end

  -- ============================================================
  -- Dropdown init
  -- ============================================================
  UIDropDownMenu_Initialize(UI.modeDropDown, function(frame, level)
    local idx = UI.selectedIndex
    local r = (ChatAutoReplyDB.rules or {})[idx]
    if not r then return end

    for _, m in ipairs(MATCH_MODES) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = m.text
      info.func = function()
        r.matchMode = m.key
        UIDropDownMenu_SetText(UI.modeDropDown, m.text)
      end
      info.checked = ((r.matchMode or "CONTAINS"):upper() == m.key)
      UIDropDownMenu_AddButton(info, level)
    end
  end)

  -- ============================================================
  -- Editor bindings
  -- ============================================================
  UI.ruleEnabled:SetScript("OnClick", function(self)
    EnsureSelectedIndexValid()
    local r = (ChatAutoReplyDB.rules or {})[UI.selectedIndex]
    if not r then return end
    r.enabled = self:GetChecked() and true or false
    RefreshRuleList()
  end)

  local function BindEditBox(box, getter, setter)
    box:SetScript("OnEnterPressed", function(self)
      setter(self:GetText())
      self:ClearFocus()
      UI.RefreshAll()
    end)
    box:SetScript("OnEscapePressed", function(self)
      self:SetText(getter())
      self:ClearFocus()
    end)
  end

  BindEditBox(UI.nameBox,
    function()
      local r = (ChatAutoReplyDB.rules or {})[UI.selectedIndex]
      return r and (r.name or "") or ""
    end,
    function(text)
      local r = (ChatAutoReplyDB.rules or {})[UI.selectedIndex]
      if r then r.name = text end
    end
  )

  BindEditBox(UI.matchBox,
    function()
      local r = (ChatAutoReplyDB.rules or {})[UI.selectedIndex]
      return r and (r.matchText or "") or ""
    end,
    function(text)
      local r = (ChatAutoReplyDB.rules or {})[UI.selectedIndex]
      if r then r.matchText = text end
    end
  )

  BindEditBox(UI.replyBox,
    function()
      local r = (ChatAutoReplyDB.rules or {})[UI.selectedIndex]
      return r and (r.replyText or "") or ""
    end,
    function(text)
      local r = (ChatAutoReplyDB.rules or {})[UI.selectedIndex]
      if r then r.replyText = text end
    end
  )

  UI.prBox:SetScript("OnEnterPressed", function(self)
    local r = (ChatAutoReplyDB.rules or {})[UI.selectedIndex]
    if r then r.perSenderCooldownSeconds = tonumber(self:GetText()) or 0 end
    self:ClearFocus()
    UI.RefreshEditor()
  end)

  for key, cb in pairs(UI.chChecks) do
    cb:SetScript("OnClick", function(self)
      local r = (ChatAutoReplyDB.rules or {})[UI.selectedIndex]
      if not r then return end
      r.channels = r.channels or {}
      r.channels[key] = self:GetChecked() and true or false
    end)
  end

  UI.testBtn:SetScript("OnClick", function()
    local r = (ChatAutoReplyDB.rules or {})[UI.selectedIndex]
    if not r then UI.testOut:SetText("No rule selected") return end
    local msg = UI.matchBox:GetText() or ""
    if msg == "" then UI.testOut:SetText("No match text set") return end
    local ok = RuleMatches(r, msg)
    UI.testOut:SetText(ok and "Would match ✅" or "Would not match ❌")
  end)

  -- ============================================================
  -- Left button actions
  -- ============================================================
  addBtn:SetScript("OnClick", function()
    ChatAutoReplyDB.rules = ChatAutoReplyDB.rules or {}
    table.insert(ChatAutoReplyDB.rules, NewRule())
    UI.selectedIndex = #ChatAutoReplyDB.rules
    UI.RefreshAll()
  end)

  dupBtn:SetScript("OnClick", function()
    EnsureSelectedIndexValid()
    local idx = UI.selectedIndex
    local rules = ChatAutoReplyDB.rules or {}
    if not rules[idx] then return end
    local copy = DeepCopy(rules[idx])
    copy.name = (copy.name or "Rule") .. " (Copy)"
    table.insert(rules, idx + 1, NormalizeRule(copy))
    UI.selectedIndex = idx + 1
    UI.RefreshAll()
  end)

  delBtn:SetScript("OnClick", function()
    EnsureSelectedIndexValid()
    local idx = UI.selectedIndex
    local rules = ChatAutoReplyDB.rules or {}
    if not rules[idx] then return end
    table.remove(rules, idx)
    EnsureSelectedIndexValid()
    UI.RefreshAll()
  end)

  upBtn:SetScript("OnClick", function()
    EnsureSelectedIndexValid()
    local idx = UI.selectedIndex
    local rules = ChatAutoReplyDB.rules or {}
    if idx <= 1 then return end
    rules[idx], rules[idx - 1] = rules[idx - 1], rules[idx]
    UI.selectedIndex = idx - 1
    UI.RefreshAll()
  end)

  downBtn:SetScript("OnClick", function()
    EnsureSelectedIndexValid()
    local idx = UI.selectedIndex
    local rules = ChatAutoReplyDB.rules or {}
    if idx >= #rules then return end
    rules[idx], rules[idx + 1] = rules[idx + 1], rules[idx]
    UI.selectedIndex = idx + 1
    UI.RefreshAll()
  end)

  -- First paint
  UI.RefreshAll()
end

-- ============================================================
-- Slash commands
-- ============================================================
SLASH_CHATAUTOREPLY1 = "/car"
SlashCmdList["CHATAUTOREPLY"] = function(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = msg:match("^(%S+)%s*(.*)$")
  cmd = cmd and cmd:lower() or ""

  CreateUI()
  if UI.frame:IsShown() then UI.frame:Hide() else UI.frame:Show() end
end

-- ============================================================
-- Events
-- ============================================================
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")

f:SetScript("OnEvent", function(self, event, ...)
  if event ~= "ADDON_LOADED" then return end
  local name = ...
  if name ~= "ChatAutoReply" then return end

  MigrateDB()

  PLAYER_NAME = UnitName("player")
  PLAYER_FULL = GetPlayerFullName()

  -- Register chat events
  for evName, _ in pairs(EVENT_MAP) do
    self:RegisterEvent(evName)
  end

  self:SetScript("OnEvent", function(_, ev, msg, sender)
    HandleMessage(ev, msg, sender)
  end)
end)