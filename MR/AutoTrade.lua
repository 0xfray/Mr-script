-- Universal Auto-Trade v1.14-confirm  |  bundled by tools/bundle.py - do not edit.
-- Source of truth: src/*.lua  (regenerate: python tools/bundle.py)
local __M = {}
__M["lib.parse"] = (function()
local M = {}

-- Returns the first gem amount found in `s` as an integer, or nil.
-- Understands k/m suffixes (case-insensitive) and comma grouping.
function M.gems(s)
  if type(s) ~= "string" then return nil end
  s = s:lower()
  -- number with optional k/m suffix: e.g. 1.1m, 900k, 7k
  local num, suffix = s:match("([%d][%d,%.]*)%s*([km])")
  if num then
    local n = tonumber((num:gsub(",", "")))
    if not n then return nil end
    if suffix == "k" then n = n * 1000 elseif suffix == "m" then n = n * 1000000 end
    return math.floor(n + 0.5)
  end
  -- plain number, possibly comma-grouped
  local plain = s:match("[%d][%d,]*%.?%d*")
  if plain then
    local n = tonumber((plain:gsub(",", "")))
    if n then return math.floor(n + 0.5) end
  end
  return nil
end

return M

end)()
__M["lib.orders"] = (function()
-- Sell-order queue. Each order = { item, qty, price, sold }. The bot fills the
-- first active order (sold < qty) at its fixed price until done, then moves on.
-- Pure logic - no Roblox globals; TDD'd in tests/orders_test.lua.
local M = {}

-- Upsert an order for `item`: replace qty+price, preserve progress (clamped).
-- Returns the order, or (nil, reason) on invalid input.
function M.add(cfg, item, qty, price)
  if type(item) ~= "string" or item == "" then return nil, "no item" end
  qty = math.floor(tonumber(qty) or 0)
  price = math.floor(tonumber(price) or 0)
  if qty <= 0 then return nil, "quantity must be > 0" end
  if price <= 0 then return nil, "price must be > 0" end
  cfg.orders = cfg.orders or {}
  for _, o in ipairs(cfg.orders) do
    if o.item == item then
      o.qty, o.price = qty, price
      o.sold = math.min(o.sold or 0, qty)
      return o
    end
  end
  local o = { item = item, qty = qty, price = price, sold = 0 }
  table.insert(cfg.orders, o)
  return o
end

function M.remove(cfg, item)
  if type(cfg.orders) ~= "table" then return false end
  for i, o in ipairs(cfg.orders) do
    if o.item == item then table.remove(cfg.orders, i); return true end
  end
  return false
end

function M.clear(cfg) cfg.orders = {} end

-- First order still needing units, optionally filtered by isSellable(item).
function M.next(cfg, isSellable)
  for _, o in ipairs((cfg and cfg.orders) or {}) do
    if (o.sold or 0) < (o.qty or 0) and (not isSellable or isSellable(o.item)) then
      return o
    end
  end
  return nil
end

-- Record one sold unit of `item`. Returns (sold, qty, done) or nil if unknown.
function M.recordSale(cfg, item)
  for _, o in ipairs((cfg and cfg.orders) or {}) do
    if o.item == item then
      o.sold = (o.sold or 0) + 1
      return o.sold, o.qty, (o.sold >= (o.qty or 0))
    end
  end
  return nil
end

-- Total units still to sell across all orders.
function M.remaining(cfg)
  local n = 0
  for _, o in ipairs((cfg and cfg.orders) or {}) do
    n = n + math.max(0, (o.qty or 0) - (o.sold or 0))
  end
  return n
end

-- True only when there ARE orders and every one is filled (so "no orders" is
-- distinct from "all done" - the caller idles differently for each).
function M.allDone(cfg)
  local any = false
  for _, o in ipairs((cfg and cfg.orders) or {}) do
    any = true
    if (o.sold or 0) < (o.qty or 0) then return false end
  end
  return any
end

-- UI summary: { "Big Tip Jar  12/100 @ 750k", ... }. shortFn formats the price.
function M.summaryLines(cfg, shortFn)
  local out = {}
  for _, o in ipairs((cfg and cfg.orders) or {}) do
    local p = shortFn and shortFn(o.price or 0) or tostring(o.price or 0)
    out[#out + 1] = ("%s  %d/%d @ %s"):format(o.item, o.sold or 0, o.qty or 0, p)
  end
  return out
end

return M

end)()
__M["lib.feed"] = (function()
local M = {}

-- Normalize a raw feed table { [name] = {value=?, demand=?} }.
-- Drops entries that aren't tables. Marks nil-value entries as naValue=true.
function M.normalize(raw)
  local out = {}
  if type(raw) ~= "table" then return out end
  for name, entry in pairs(raw) do
    if type(name) == "string" and type(entry) == "table" then
      local value = tonumber(entry.value)
      out[name] = {
        value = value,                 -- may be nil
        demand = tonumber(entry.demand) or 0,
        naValue = value == nil,
      }
    end
  end
  return out
end

function M.count(norm)
  local n = 0
  for _ in pairs(norm) do n = n + 1 end
  return n
end

return M

end)()
__M["lib.config"] = (function()
local M = {}

function M.defaults()
  return {
    enabled = false,
    testMode = true,          -- do everything but never press confirm (safe)
    -- Sell orders: { { item, qty, price, sold }, ... }. The bot fills each at
    -- its fixed price until qty is met, then stops. (See lib/orders.)
    orders = {},
    stopAtGemCap = true,      -- stop selling once gems reach gemCap
    minSellPct = 90,          -- hard floor: never confirm a sale below value * this%
    globalMarkupPct = 5,      -- ask = value * (1 + markup/100)
    bandPct = 10,             -- ceiling/floor = value * (1 +/- band/100)
    demandScaling = true,     -- high demand -> more markup, less concession
    tradeUnitMode = "single_type_qty", -- single_copy | single_type_qty | multi_basket
    tradeTimeoutSec = 60,
    negotiation = { maxRounds = 4, concedeStepPct = 3, chatCooldownSec = 4 },
    ads = { rotatingAds = false, autoInvite = false, stockOnly = true, intervalSec = 45 },
    items = {},               -- [name] = { value?, markupPct?, bandPct?, forSale? }

    -- Auto-buyer at gem cap (OFF by default; sell mode is the primary use)
    buyEnabled = false,
    gemCap = 100000000,       -- switch to buy-only at/above this many gems
    gemCapBuffer = 5000000,   -- resume selling once gems fall below (cap - buffer)
    buyDiscountPct = 10,      -- maxBuy = value * (1 - buyDiscount/100)
    buy = {},                 -- [name] = { wantBuy?, maxBuyPrice?, maxQty? }

    -- Scam-guard + per-player throttling
    cooldownSec = 30,         -- min seconds between trades with the same player
    blocklist = {},           -- [playerName] = true

    -- 24/7 survival
    survival = { autoReconnect = true, antiAfk = true, watchdog = true,
                 watchdogMaxErrors = 5 },

    -- Discord webhook (url stored locally only; blank = disabled)
    webhook = { url = "", onSale = true, onCap = true, onDisconnect = true, onError = true },

    -- Confirm gate + invites
    requireBuyerConfirm = false, -- if true, wait for the buyer to confirm before
                                 -- we do (safer, but deadlocks if they wait on us)
    confirmVerifyTimeoutSec = 10, -- wait this long for the trade to clear after confirm
    inviteCooldownSec = 120,     -- min seconds between auto-invites to the same player
    acceptTimeoutSec = 15,       -- give up on an accepted invite if no trade window opens

    -- Housekeeping
    feedRefreshSec = 1800,    -- re-fetch the value feed every 30 min (0 = never)
    -- Array (not a set): numeric map keys don't survive the JSON persist round-trip.
    expectedPlaceIds = { 13200523806, 13279398864 }, -- Trading Plaza, Pro Trading Plaza
  }
end

-- Is auto-trading allowed in this place? Honors the expectedPlaceIds allow-list
-- plus a legacy scalar `expectedPlaceId` from old saved settings. No config at
-- all = no restriction.
function M.placeAllowed(cfg, placeId)
  local pid = tonumber(placeId)
  if not pid then return false end
  local ids = (type(cfg) == "table") and cfg.expectedPlaceIds or nil
  local legacy = (type(cfg) == "table") and tonumber(cfg.expectedPlaceId) or nil
  local hasList = type(ids) == "table" and next(ids) ~= nil
  if not hasList and not legacy then return true end -- no restriction configured
  if hasList then
    for _, v in ipairs(ids) do
      if tonumber(v) == pid then return true end
    end
  end
  return legacy == pid
end

-- Deep-merge override onto base (base is not mutated). Map tables recurse;
-- scalars and ARRAYS replace wholesale (index-wise merging an array would make
-- it impossible to ever shrink a saved list below the default length).
function M.merge(base, override)
  local out = {}
  for k, v in pairs(base) do
    if type(v) == "table" then out[k] = M.merge(v, {}) else out[k] = v end
  end
  if type(override) == "table" then
    for k, v in pairs(override) do
      if type(v) == "table" and type(out[k]) == "table" and v[1] == nil then
        out[k] = M.merge(out[k], v)
      else
        out[k] = v
      end
    end
  end
  return out
end

return M

end)()
__M["lib.pricing"] = (function()
local M = {}

local function round(n) return math.floor(n + 0.5) end

-- Returns { ask, ceiling, floor } for `qty` copies, or nil if unsellable.
-- feedEntry: { value?, demand?, naValue? }   override: { value?, markupPct?, bandPct? }
function M.quote(cfg, feedEntry, override, qty)
  override = override or {}
  qty = qty or 1
  local base = tonumber(override.value) or tonumber(feedEntry and feedEntry.value)
  if not base then return nil end  -- N/A and no override

  local markup = tonumber(override.markupPct) or cfg.globalMarkupPct or 0
  local band   = tonumber(override.bandPct)   or cfg.bandPct or 0
  local demand = tonumber(feedEntry and feedEntry.demand) or 0

  if cfg.demandScaling then
    -- demand 0..10 -> markup +0..+50% of itself; band shrinks up to -40%
    markup = markup * (1 + demand / 20)
    band   = band   * (1 - demand / 25)
  end

  local ask     = round(base * (1 + markup / 100)) * qty
  local ceiling = round(base * (1 + band / 100)) * qty
  local floor   = round(base * (1 - band / 100)) * qty
  return { ask = ask, ceiling = ceiling, floor = floor }
end

-- Buy-side quote for the auto-buyer (gem-cap mode).
-- Returns { max, floorBid } for `qty` copies, or nil if no base price.
--   max      = the most you'll pay (value * (1 - buyDiscount%), or explicit override)
--   floorBid = your opening lowball (max * (1 - band%))
function M.buyQuote(cfg, feedEntry, override, qty)
  override = override or {}
  qty = qty or 1
  local explicit = tonumber(override.maxBuyPrice)
  local base = explicit or tonumber(feedEntry and feedEntry.value)
  if not base then return nil end

  local band = tonumber(override.bandPct) or cfg.bandPct or 0
  local maxUnit
  if explicit then
    maxUnit = explicit
  else
    local discount = tonumber(override.buyDiscountPct) or cfg.buyDiscountPct or 0
    local demand = tonumber(feedEntry and feedEntry.demand) or 0
    if cfg.demandScaling then discount = discount * (1 - demand / 25) end -- high demand -> pay more
    maxUnit = base * (1 - discount / 100)
  end

  local max = round(maxUnit) * qty
  local floorBid = round(maxUnit * (1 - band / 100)) * qty
  return { max = max, floorBid = floorBid }
end

return M

end)()
__M["lib.negotiation"] = (function()
local M = {}

-- Current accept-threshold for a given round: starts at ceiling, steps down
-- toward floor by concedeStepPct of (ceiling-floor) per round, clamped at floor.
function M.threshold(cfg, quote, round)
  local step = (cfg.negotiation and cfg.negotiation.concedeStepPct or 0) / 100
  local span = quote.ceiling - quote.floor
  local t = quote.ceiling - span * step * (round or 0)
  if t < quote.floor then t = quote.floor end
  return math.floor(t + 0.5)
end

-- Decide the next move.
-- state: { offeredGems, targetChatNumber, round, elapsed }
-- Returns { action = "ACCEPT"|"COUNTER"|"HOLD"|"ABORT", amount?, message? }
function M.decide(cfg, quote, state)
  local maxRounds = cfg.negotiation and cfg.negotiation.maxRounds or 3
  local threshold = M.threshold(cfg, quote, state.round or 0)
  local offered = tonumber(state.offeredGems) or 0

  if offered >= threshold then
    return { action = "ACCEPT" }
  end

  local chat = tonumber(state.targetChatNumber)
  -- Out of rounds and still short -> give up.
  if (state.round or 0) >= maxRounds then
    return { action = "ABORT" }
  end

  if chat and chat >= quote.floor then
    -- counter toward the midpoint of their chat number and our threshold
    local counter = math.floor((chat + threshold) / 2 + 0.5)
    if counter < quote.floor then counter = quote.floor end
    if counter > quote.ceiling then counter = quote.ceiling end
    return { action = "COUNTER", amount = counter,
             message = ("I can do %d"):format(counter) }
  end

  if chat and chat < quote.floor then
    return { action = "ABORT" }
  end

  -- No usable signal yet: hold and wait for them to move.
  return { action = "HOLD" }
end

-- BUY side (auto-buyer). Threshold RISES from floorBid toward max over rounds.
function M.thresholdBuy(cfg, bq, round)
  local step = (cfg.negotiation and cfg.negotiation.concedeStepPct or 0) / 100
  local span = bq.max - bq.floorBid
  local t = bq.floorBid + span * step * (round or 0)
  if t > bq.max then t = bq.max end
  return math.floor(t + 0.5)
end

-- Decide the next BUY move.
-- state: { sellerAsk, round, elapsed }  (sellerAsk = gems the seller wants)
-- Returns { action = "ACCEPT"|"COUNTER"|"HOLD"|"ABORT", amount?, message? }
function M.decideBuy(cfg, bq, state)
  local maxRounds = cfg.negotiation and cfg.negotiation.maxRounds or 3
  local threshold = M.thresholdBuy(cfg, bq, state.round or 0)
  local ask = tonumber(state.sellerAsk)

  -- Seller wants no more than our current willingness -> buy.
  if ask and ask <= threshold then
    return { action = "ACCEPT" }
  end

  if (state.round or 0) >= maxRounds then
    return { action = "ABORT" }
  end

  if not ask then
    return { action = "HOLD" }
  end

  -- Counter upward, but never above our hard max.
  local bid
  if ask <= bq.max then
    bid = math.floor((threshold + ask) / 2 + 0.5)
  else
    bid = threshold           -- their ask exceeds our max; hold our line, keep trying
  end
  if bid > bq.max then bid = bq.max end
  if bid < bq.floorBid then bid = bq.floorBid end
  return { action = "COUNTER", amount = bid, message = ("I can pay %d"):format(bid) }
end

return M

end)()
__M["lib.ads"] = (function()
local M = {}

-- Short human form of a gem amount: 945000 -> "945k", 3675000 -> "3.7m",
-- 1000000 -> "1m", 810 -> "810". Always returns a single string.
function M.short(n)
  if n >= 1000000 then
    local s = ("%.1fm"):format(n / 1000000)
    s = (s:gsub("%.0m", "m"))
    return s
  elseif n >= 1000 then
    return ("%.0fk"):format(n / 1000)
  end
  return tostring(n)
end

-- Build a single advertisement line from listings { {name, ask}, ... }.
-- Returns nil when there is nothing to advertise.
function M.line(listings, opts)
  opts = opts or {}
  local maxItems = opts.maxItems or 5
  if #listings == 0 then return nil end
  local shown = math.min(maxItems, #listings)
  local parts = {}
  for i = 1, shown do
    parts[#parts + 1] = ("%s %s"):format(listings[i].name, M.short(listings[i].ask))
  end
  local msg = "Selling: " .. table.concat(parts, ", ")
  local omitted = #listings - shown
  if omitted > 0 then msg = msg .. (" +%d more"):format(omitted) end
  return msg .. " — msg me"
end

return M

end)()
__M["lib.capmode"] = (function()
local M = {}

-- Decide sell vs buy mode with hysteresis around the gem cap.
--   gems >= cap                    -> "buy"
--   in buy mode until gems drop below (cap - buffer), then "sell"
--   buyEnabled = false             -> always "sell"
function M.mode(cfg, gems, currentMode)
  gems = tonumber(gems) or 0
  if not cfg.buyEnabled then return "sell" end
  local cap = tonumber(cfg.gemCap) or math.huge
  local buffer = tonumber(cfg.gemCapBuffer) or 0
  if gems >= cap then return "buy" end
  if currentMode == "buy" and gems >= (cap - buffer) then return "buy" end
  return "sell"
end

return M

end)()
__M["lib.scamguard"] = (function()
local M = {}

-- Final safety check re-run in the same tick right before confirming a SELL:
-- the gems currently in the window must still meet the agreed threshold.
-- Defends against last-second offer swaps.
function M.safeToConfirmSell(agreedThreshold, currentOffered)
  local a = tonumber(agreedThreshold)
  local c = tonumber(currentOffered)
  if not a or not c then return false end
  return c >= a
end

-- Same idea for a BUY: the seller must not have raised what they want above
-- the amount we agreed to pay.
function M.safeToConfirmBuy(agreedPay, sellerWantsNow)
  local a = tonumber(agreedPay)
  local c = tonumber(sellerWantsNow)
  if not a or not c then return false end
  return c <= a
end

return M

end)()
__M["lib.cooldown"] = (function()
local M = {}

-- Per-player gate: blocklist first, then a min-seconds-between-trades cooldown.
-- `player` is either a scalar key or a { uid?, name? } table; the blocklist may
-- be keyed by name, numeric uid, or stringified uid.
-- Returns (allowed: bool, reason: string?).
local function blocked(bl, player)
  if not (bl and player) then return false end
  if type(player) == "table" then
    if player.name ~= nil and bl[player.name] then return true end
    if player.uid ~= nil and (bl[player.uid] or bl[tostring(player.uid)]) then return true end
    return false
  end
  return bl[player] ~= nil and bl[player] ~= false
end

function M.allow(cfg, player, lastTradeAt, now)
  if blocked(cfg.blocklist, player) then
    return false, "blocked"
  end
  local cd = tonumber(cfg.cooldownSec) or 0
  if lastTradeAt and now and (now - lastTradeAt) < cd then
    return false, "cooldown"
  end
  return true, nil
end

return M

end)()
__M["lib.stats"] = (function()
local M = {}

function M.new(startTime)
  return { trades = 0, sells = 0, buys = 0, profit = 0,
           gemsIn = 0, gemsOut = 0, startTime = startTime or 0 }
end

-- Record a completed sell: received `gems`, item was worth `cost` to us.
function M.recordSell(s, gems, cost)
  gems = tonumber(gems) or 0
  cost = tonumber(cost) or 0
  s.trades = s.trades + 1
  s.sells = s.sells + 1
  s.gemsIn = s.gemsIn + gems
  s.profit = s.profit + (gems - cost)
  return s
end

-- Record a completed buy: paid `gems`.
function M.recordBuy(s, gems)
  gems = tonumber(gems) or 0
  s.trades = s.trades + 1
  s.buys = s.buys + 1
  s.gemsOut = s.gemsOut + gems
  s.profit = s.profit - gems
  return s
end

-- Profit per hour given the current time.
function M.profitPerHour(s, now)
  local dt = (tonumber(now) or 0) - (s.startTime or 0)
  if dt <= 0 then return 0 end
  return math.floor(s.profit / (dt / 3600) + 0.5)
end

return M

end)()
__M["lib.webhook"] = (function()
local M = {}

-- Build the Discord message content for an event, or nil for unknown events.
-- The actual HTTP POST is done by glue (runtime); this stays pure/testable.
function M.content(event, data)
  data = data or {}
  if event == "sale" then
    return ("Sold %s x%d for %s gems (profit %s)")
      :format(tostring(data.item or "?"), tonumber(data.qty) or 1,
              tostring(data.gems or 0), tostring(data.profit or 0))
  elseif event == "buy" then
    return ("Bought %s x%d for %s gems")
      :format(tostring(data.item or "?"), tonumber(data.qty) or 1, tostring(data.gems or 0))
  elseif event == "cap" then
    return ("Gem cap reached (%s). Switching to buy mode."):format(tostring(data.gems or 0))
  elseif event == "disconnect" then
    return "Disconnected - attempting reconnect..."
  elseif event == "reconnect" then
    return "Reconnected."
  elseif event == "error" then
    return ("Error: %s"):format(tostring(data.msg or "unknown"))
  end
  return nil
end

-- Whether this event should fire, based on config + a non-empty url.
function M.enabledFor(cfg, event)
  local w = cfg.webhook
  if not w or not w.url or w.url == "" then return false end
  if event == "sale" or event == "buy" then return w.onSale ~= false end
  if event == "cap" then return w.onCap ~= false end
  if event == "disconnect" or event == "reconnect" then return w.onDisconnect ~= false end
  if event == "error" then return w.onError ~= false end
  return false
end

return M

end)()
__M["lib.logbuf"] = (function()
local M = {}
M.__index = M

-- Ring buffer of timestamped log lines, plus a formatter for the debug report.
-- Pure: the caller supplies timestamps (os.clock/os.time) so this stays testable.
function M.new(capacity)
  return setmetatable({ cap = capacity or 400, lines = {}, counts = {} }, M)
end

-- level: "INFO" | "WARN" | "ERROR" | "OK" | "STEP"
function M:add(level, msg, t)
  level = level or "INFO"
  self.counts[level] = (self.counts[level] or 0) + 1
  local line = ("[%s] %-5s %s"):format(tostring(t or 0), level, tostring(msg))
  self.lines[#self.lines + 1] = line
  if #self.lines > self.cap then
    table.remove(self.lines, 1)
  end
  return line
end

function M:info(m, t)  return self:add("INFO", m, t) end
function M:warn(m, t)  return self:add("WARN", m, t) end
function M:err(m, t)   return self:add("ERROR", m, t) end
function M:ok(m, t)    return self:add("OK", m, t) end
function M:step(m, t)  return self:add("STEP", m, t) end

function M:errorCount() return self.counts["ERROR"] or 0 end

-- Render the full report with a header and a counts summary.
function M:report(header)
  local out = {}
  out[#out + 1] = "===== " .. (header or "AutoTrade Debug Report") .. " ====="
  local summary = {}
  for _, lvl in ipairs({ "STEP", "OK", "INFO", "WARN", "ERROR" }) do
    if self.counts[lvl] then summary[#summary + 1] = lvl .. "=" .. self.counts[lvl] end
  end
  out[#out + 1] = "summary: " .. table.concat(summary, " ")
  out[#out + 1] = "-----"
  for _, l in ipairs(self.lines) do out[#out + 1] = l end
  out[#out + 1] = "===== end ====="
  return table.concat(out, "\n")
end

return M

end)()
__M["lib.dump"] = (function()
local M = {}

-- Render a scalar/short description of any value.
function M.value(v)
  local ty = type(v)
  if ty == "string" then
    if #v > 60 then v = v:sub(1, 60) .. "..." end
    return '"' .. v .. '"'
  elseif ty == "number" or ty == "boolean" then
    return tostring(v)
  elseif ty == "table" then
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    return ("table[%d]"):format(n)
  elseif ty == "function" then
    return "function"
  end
  return ty
end

-- Serialize a table's structure to a list of "key = value" lines, depth-limited.
-- opts: { maxDepth = 2, maxKeys = 40, indent = "  " }
function M.lines(t, opts)
  opts = opts or {}
  local maxDepth = opts.maxDepth or 2
  local maxKeys = opts.maxKeys or 40
  local indent = opts.indent or "  "
  local out = {}
  if type(t) ~= "table" then out[1] = M.value(t); return out end

  local function walk(tb, depth, prefix)
    local keys = {}
    for k in pairs(tb) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local shown = 0
    for _, k in ipairs(keys) do
      shown = shown + 1
      if shown > maxKeys then
        out[#out + 1] = prefix .. "... (+" .. (#keys - maxKeys) .. " more keys)"
        break
      end
      local v = tb[k]
      out[#out + 1] = prefix .. tostring(k) .. " = " .. M.value(v)
      if type(v) == "table" and depth < maxDepth then
        walk(v, depth + 1, prefix .. indent)
      end
    end
    if #keys == 0 then out[#out + 1] = prefix .. "(empty)" end
  end

  walk(t, 1, "")
  return out
end

-- Convenience: joined string.
function M.text(t, opts)
  return table.concat(M.lines(t, opts), "\n")
end

return M

end)()
__M["lib.tradefields"] = (function()
-- Robust readers for the live activeTrade object. The game's exact field names
-- aren't fully confirmed, so we try known names first, then fuzzy-scan by keyword.
-- Each reader returns (value, fieldNameUsed) so the caller can log what matched.
local M = {}

-- One scanner pair, parametrized by a coercion: coerce(raw) -> value|nil.
local function coerceStrictNumber(v) if type(v) == "number" then return v end return nil end
local function coerceBool(v) if type(v) == "boolean" then return v end return nil end

local function firstKnown(at, names, coerce)
  for _, k in ipairs(names) do
    local v = coerce(at[k])
    if v ~= nil then return v, k end
  end
  return nil
end

local function fuzzyScan(at, mustA, mustB, coerce)
  for k, raw in pairs(at) do
    if type(k) == "string" then
      local v = coerce(raw)
      if v ~= nil then
        local lk = k:lower()
        if lk:find(mustA) and (not mustB or lk:find(mustB)) then return v, k end
      end
    end
  end
  return nil
end

-- Gems the buyer (target/other player) has put into the window.
function M.buyerGems(at)
  if type(at) ~= "table" then return 0, nil end
  local v, k = firstKnown(at, { "sentGemsTarget", "offeredGemsTarget", "gemsTarget", "targetGems" }, tonumber)
  if v then return v, k end
  v, k = fuzzyScan(at, "gem", "target", coerceStrictNumber)
  if v then return v, k end
  return 0, nil
end

-- Gems we (the player) have put in.
function M.myGems(at)
  if type(at) ~= "table" then return 0, nil end
  local v, k = firstKnown(at, { "sentGemsPlayer", "offeredGemsPlayer", "gemsPlayer", "playerGems" }, tonumber)
  if v then return v, k end
  v, k = fuzzyScan(at, "gem", "player", coerceStrictNumber)
  if v then return v, k end
  return 0, nil
end

-- Whether the buyer (target) has pressed confirm. Returns nil when no matching
-- field exists (unknown - caller must NOT treat that as false-and-keep-waiting
-- silently, and must NEVER treat it as confirmed).
function M.targetConfirmed(at)
  if type(at) ~= "table" then return nil, nil end
  local v, k = firstKnown(at, { "targetConfirmed", "targetAccepted", "confirmedTarget" }, coerceBool)
  if v ~= nil then return v, k end
  v, k = fuzzyScan(at, "confirm", "target", coerceBool)
  if v ~= nil then return v, k end
  v, k = fuzzyScan(at, "accept", "target", coerceBool)
  if v ~= nil then return v, k end
  return nil, nil
end

-- The other player's user id. Live activeTrade has no targetID field - it has
-- `target`/`player` Player objects (target = the other party) - so fall back to
-- reading .UserId off those.
function M.partnerId(at)
  if type(at) ~= "table" then return nil end
  local id = at.targetID or at.targetId or at.partnerID or at.otherID or at.otherId
  if id then return id end
  local function uid(p)
    if type(p) == "userdata" or type(p) == "table" then
      local ok, v = pcall(function() return p.UserId end)
      if ok and v then return v end
    end
    return nil
  end
  return uid(at.target) or uid(at.player)
end

return M

end)()
__M["runtime.persist"] = (function()
-- Executor file persistence. All calls guarded: features degrade, never crash.
local HttpService = game:GetService("HttpService")
local M = {}
local FOLDER = "OdResto"
local SETTINGS = FOLDER .. "/autotrade_settings.json"
local FEEDCACHE = FOLDER .. "/value_cache.json"
local STATS = FOLDER .. "/autotrade_stats.json"

local function ensureFolder()
  if makefolder and (isfolder == nil or not isfolder(FOLDER)) then
    pcall(makefolder, FOLDER)
  end
end

local function readJson(path)
  if not (isfile and isfile(path) and readfile) then return nil end
  local ok, raw = pcall(readfile, path)
  if not ok then return nil end
  local ok2, tbl = pcall(function() return HttpService:JSONDecode(raw) end)
  return ok2 and tbl or nil
end

local function writeJson(path, tbl)
  if not writefile then return false end
  ensureFolder()
  local ok, raw = pcall(function() return HttpService:JSONEncode(tbl) end)
  if not ok then return false end
  return (pcall(writefile, path, raw))
end

function M.loadSettings() return readJson(SETTINGS) end
function M.saveSettings(tbl) return writeJson(SETTINGS, tbl) end
function M.loadFeedCache() return readJson(FEEDCACHE) end
function M.saveFeedCache(tbl) return writeJson(FEEDCACHE, tbl) end
function M.loadStats() return readJson(STATS) end
function M.saveStats(tbl) return writeJson(STATS, tbl) end

return M

end)()
__M["runtime.remotes"] = (function()
local Players = game:GetService("Players")
local M = {}

-- Core remotes the trade flow must have.
local REQUIRED = { "trading_acceptinvite", "trading_additem", "trading_removeitem",
                   "trading_confirmtrade", "trading_abort", "trading_sendmessage" }
-- Extra remotes (looked up but not fatal if absent). Only trading_sendinvite is
-- real - the deob shows the game has NO status/invite events; status comes from
-- Library.Network.Invoke("Trading_GetStatus") (see gamedata.getStatus).
local OPTIONAL = { "trading_sendinvite", "trading_updategemoffer" }

function M.resolveRemotes(timeout)
  timeout = timeout or 30

  local function tryParent(parent)
    if not parent then return nil end
    local things = parent:FindFirstChild("__THINGS")
    if not things then return nil end
    local remotes = things:FindFirstChild("__REMOTES")
    if not remotes then return nil end
    local out = { __container = remotes }
    for _, n in ipairs(REQUIRED) do
      local r = remotes:WaitForChild(n, timeout)
      if not r then return nil, "missing required remote " .. n end
      out[n] = r
    end
    for _, n in ipairs(OPTIONAL) do
      out[n] = remotes:FindFirstChild(n) -- may be nil
    end
    return out
  end

  pcall(function() workspace:WaitForChild("__THINGS", timeout) end)
  local out = tryParent(workspace)
  if out then return out, "workspace" end
  out = tryParent(Players.LocalPlayer)
  if out then return out, "localplayer" end

  local remotes
  pcall(function()
    for _, d in ipairs(game:GetDescendants()) do
      if d.Name == "__REMOTES" then remotes = d; break end
    end
  end)
  if remotes then
    local out2 = { __container = remotes }
    for _, n in ipairs(REQUIRED) do
      local r = remotes:FindFirstChild(n)
      if not r then return nil, "missing required remote " .. n .. " (via search)" end
      out2[n] = r
    end
    for _, n in ipairs(OPTIONAL) do out2[n] = remotes:FindFirstChild(n) end
    return out2, "search:" .. remotes:GetFullName()
  end
  return nil, "no __THINGS.__REMOTES found"
end

return M

end)()
__M["runtime.gamedata"] = (function()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local M = {}

-- Acquire the client Library module: require(Framework.Library).
function M.root(timeout)
  timeout = timeout or 30
  local ok, root = pcall(function()
    local fw = ReplicatedStorage:WaitForChild("Framework", timeout)
    local libmod = fw:WaitForChild("Library", timeout)
    return require(libmod)
  end)
  if ok and type(root) == "table" then return root end
  return nil, tostring(root)
end

-- Build a catalog `name -> { id, className }` from root.Directory.<category>,
-- where each entry is { ID="156", name="Wave Set", className="Furniture", ... }.
-- Non-item sub-tables (Tiers, goals) lack name+ID and are skipped.
function M.catalog(root)
  local cat = {}
  local dir = root and root.Directory
  if type(dir) == "table" then
    for _, ctbl in pairs(dir) do
      if type(ctbl) == "table" then
        for _, entry in pairs(ctbl) do
          if type(entry) == "table" then
            local id = entry.ID or entry.id or entry.itemID
            local name = entry.name or entry.Name
            if id and name and not cat[name] then
              cat[name] = { id = tostring(id), className = entry.className or entry.class,
                            subClass = entry.subClass or entry.subclass }
            end
          end
        end
      end
    end
  end
  return cat
end

-- Own gem balance: LocalPlayer.leaderstats.Gems.Value (report-confirmed).
function M.gems()
  local ok, v = pcall(function()
    local ls = Players.LocalPlayer:FindFirstChild("leaderstats")
    local g = ls and ls:FindFirstChild("Gems")
    return g and g.Value
  end)
  return (ok and tonumber(v)) or 0
end

-- Unwrap a status payload to the object holding incomingInvites/activeTrade.
-- Network.Invoke returns the table directly, but stay tolerant of a one-level
-- wrap and of an idle status that has none of the known keys (pass it through
-- so the one-time dump in main reveals the real shape).
local function looksLikeStatus(t)
  return type(t) == "table" and (t.incomingInvites ~= nil or t.activeTrade ~= nil
    or t.outgoingInvites ~= nil or t.tradeUID ~= nil)
end

function M.unwrapStatus(a)
  if type(a) ~= "table" then return nil end
  if looksLikeStatus(a) then return a end
  if looksLikeStatus(a[1]) then return a[1] end
  if next(a) == nil then return a end -- empty table = idle status, harmless
  return nil -- unrecognized shape: NOT a healthy poll (may be an error payload)
end

-- Current trade status via the framework network layer (the game's ONLY status
-- mechanism - there is no trading_getstatus remote). Confirmed from the deob:
-- Library.Network.Invoke is a plain function, the remote NAME is its first
-- argument (dot-call; a colon-call would shift the args and break it).
-- Returns (status) | (nil, err) | (nil, err, rawTable) - raw lets the caller
-- dump an unrecognized shape once for diagnosis.
function M.getStatus(root)
  local net = root and root.Network
  local inv = type(net) == "table" and net.Invoke or nil
  if type(inv) ~= "function" then return nil, "no Network.Invoke on Library root" end
  local ok, res = pcall(inv, "Trading_GetStatus")
  if not ok then return nil, tostring(res) end
  if type(res) ~= "table" then return nil, "status is " .. type(res) end
  local s = M.unwrapStatus(res)
  if not s then return nil, "unrecognized status shape", res end
  return s, nil
end

-- Resolve a live Player from an invite uid.
function M.playerFromUid(uid)
  local n = tonumber(uid)
  if not n then return nil end
  local ok, p = pcall(function() return Players:GetPlayerByUserId(n) end)
  return ok and p or nil
end

-- Find the live trade object in a status table. A real Trading_GetStatus dump
-- (2026-07-23) showed top-level keys busyPlayers/history/incomingInvites/
-- outgoingInvites/tradeSettings and NO activeTrade while idle - so the trade
-- object's key is unconfirmed and we search: known names first, then any
-- trade-ish top-level key holding (or mapping our uid to) a table with
-- offered/confirm/tradeUID-style fields. Returns (trade, keyPath).
local KNOWN_TRADE_KEYS = { "activeTrade", "trade", "currentTrade", "activeTrades" }
local function tradeLike(t)
  if type(t) ~= "table" then return false end
  for k in pairs(t) do
    if type(k) == "string" then
      local lk = k:lower()
      if lk:find("offered") or lk:find("tradeuid") or lk:find("confirmed") then return true end
    end
  end
  return false
end

function M.findActiveTrade(s)
  if type(s) ~= "table" then return nil end
  local me = Players.LocalPlayer and Players.LocalPlayer.UserId
  -- deob-confirmed exact name: any non-empty table counts (a just-opened trade
  -- may not have offered/confirm fields yet)
  if type(s.activeTrade) == "table" and next(s.activeTrade) ~= nil then return s.activeTrade, "activeTrade" end
  for _, k in ipairs(KNOWN_TRADE_KEYS) do
    local v = s[k]
    if type(v) == "table" then
      if tradeLike(v) then return v, k end
      if me then
        local mine = v[me] or v[tostring(me)]
        if tradeLike(mine) then return mine, k .. "[me]" end
      end
    end
  end
  for k, v in pairs(s) do
    if type(k) == "string" and type(v) == "table" then
      local lk = k:lower()
      if lk:find("trade") and not lk:find("history") and not lk:find("settings") and not lk:find("invite") then
        if tradeLike(v) then return v, k end
        if me then
          local mine = v[me] or v[tostring(me)]
          if tradeLike(mine) then return mine, k .. "[me]" end
        end
      end
    end
  end
  return nil
end

-- Role-aware view of the live activeTrade. Confirmed from a remote-spy capture:
-- fields are offeredGems{Player,Target}, offeredItems{Player,Target},
-- {player,target}Confirmed, plus `player`/`target` Player objects and tradeUID.
-- CRUCIALLY the inviter is "target" and the invitee is "player", so which side
-- is US varies per trade - match LocalPlayer, then read OUR vs THEIR fields.
local function cap(s) return s:sub(1, 1):upper() .. s:sub(2) end
function M.tradeInfo(at)
  if type(at) ~= "table" then return nil end
  local me = Players.LocalPlayer and Players.LocalPlayer.UserId
  local function uidOf(p)
    if type(p) ~= "userdata" and type(p) ~= "table" then return nil end
    local ok, v = pcall(function() return p.UserId end)
    return ok and v or nil
  end
  local mySide
  if me then
    if uidOf(at.player) == me then mySide = "player"
    elseif uidOf(at.target) == me then mySide = "target" end
  end
  local known = mySide ~= nil
  mySide = mySide or "player"
  local their = (mySide == "player") and "target" or "player"
  local mc, tc = cap(mySide), cap(their)
  return {
    mySide = mySide, theirSide = their, sideKnown = known,
    myGems = tonumber(at["offeredGems" .. mc]) or 0,
    buyerGems = tonumber(at["offeredGems" .. tc]) or 0,
    myItems = at["offeredItems" .. mc],
    theirItems = at["offeredItems" .. tc],
    iConfirmed = at[mySide .. "Confirmed"],
    theirConfirmed = at[their .. "Confirmed"],
    tradeUID = at.tradeUID,
  }
end

-- Does the server currently mark US as in a trade? (busyPlayers is uid-keyed,
-- confirmed from a live dump.) A strong signal that a trade window is open
-- even if we haven't located the trade object's field yet.
function M.myBusy(s)
  local me = Players.LocalPlayer and Players.LocalPlayer.UserId
  return M.isBusy(s, me)
end

-- Is player `uid` currently in a trade? Live dumps proved you CANNOT accept an
-- invite from a busy player (they're mid-trade with someone else) - the accept
-- silently opens no window. So we skip busy inviters.
function M.isBusy(s, uid)
  local bp = type(s) == "table" and s.busyPlayers or nil
  if type(bp) ~= "table" or uid == nil then return false end
  return (bp[uid] or bp[tostring(uid)] or bp[tonumber(uid)]) and true or false
end

return M

end)()
__M["runtime.inventory"] = (function()
local M = {}

-- Returns { [name] = qty } for items the player owns, or nil when the
-- inventory can't be read (unknown - callers must not treat that as "owns
-- nothing"). Uses the live Framework Library's Inventory.GetItemCount function
-- (confirmed 2026-07-23: Inventory is a module of functions, and
-- GetOwnedByClassAndSubclass(class, subclass) returns a count). GetItemCount's
-- exact signature isn't documented, so we self-calibrate: try a few call
-- shapes over the catalog and keep the one that returns numbers for our items
-- and a positive count for at least one (the player does own things).
function M.owned(root, catalog)
  if type(root) ~= "table" or type(catalog) ~= "table" then return nil end
  local inv = root.Inventory
  if type(inv) ~= "table" then return nil end
  local getCount = inv.GetItemCount
  if type(getCount) ~= "function" then return nil end

  -- candidate GetItemCount signatures (dot-call; c = catalog entry)
  local sigs = {
    function(c) return getCount(c.id) end,
    function(c) return getCount(tonumber(c.id)) end,
    function(c) return getCount(c.className, c.subClass, c.id) end,
    function(c) return getCount(c.className, c.id) end,
  }

  local names = {}
  for name in pairs(catalog) do names[#names + 1] = name end
  if #names == 0 then return nil end

  local function score(sig)
    local numeric, positives = 0, 0
    for _, name in ipairs(names) do
      local ok, v = pcall(sig, catalog[name])
      if ok and type(v) == "number" then
        numeric = numeric + 1
        if v > 0 then positives = positives + 1 end
      end
    end
    return numeric, positives
  end

  local best
  for _, sig in ipairs(sigs) do
    local numeric, positives = score(sig)
    if numeric >= math.floor(#names * 0.8) and positives > 0 then best = sig; break end
  end
  if not best then return nil end

  local owned = {}
  for _, name in ipairs(names) do
    local ok, v = pcall(best, catalog[name])
    if ok and type(v) == "number" and v > 0 then owned[name] = v end
  end
  return owned
end

return M

end)()
__M["runtime.prober"] = (function()
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local dump = __M["lib.dump"]
local gamedata = __M["runtime.gamedata"]
local M = {}

local function has(fn) return type(fn) == "function" end

-- Run a probe; if it errors, LOG the error (never silently swallow).
local function safe(log, label, t, fn)
  local ok, err = pcall(fn)
  if not ok then log:err(label .. " probe FAILED: " .. tostring(err), t) end
end

-- Log a table dump as multiple indented INFO lines.
local function logDump(log, label, tbl, t, opts)
  log:info(label .. ":", t)
  for _, line in ipairs(dump.lines(tbl, opts)) do log:info("  " .. line, t) end
end

function M.run(log, t)
  local lp = Players.LocalPlayer

  safe(log, "executor", t, function()
    local name = (identifyexecutor and identifyexecutor()) or (getexecutorname and getexecutorname()) or "unknown"
    log:info("executor: " .. tostring(name), t)
    log:info("caps: http=" .. tostring(has(http_request) or has(request))
      .. " clipboard=" .. tostring(has(setclipboard) or has(toclipboard))
      .. " files=" .. tostring(has(writefile) and has(readfile)), t)
    log:info(("place=%s job=%s player=%s"):format(tostring(game.PlaceId), tostring(game.JobId), tostring(lp and lp.Name)), t)
  end)

  -- REMOTES: base uses workspace.__THINGS.__REMOTES; check workspace then LocalPlayer.
  safe(log, "remotes", t, function()
    local function dumpRemotes(parent, label)
      local things = parent and parent:FindFirstChild("__THINGS")
      if not things then log:info(label .. ".__THINGS: not found", t); return false end
      local remotes = things:FindFirstChild("__REMOTES")
      if not remotes then log:warn(label .. ".__THINGS has no __REMOTES", t); return false end
      local names = {}
      for _, c in ipairs(remotes:GetChildren()) do names[#names + 1] = c.Name .. "(" .. c.ClassName .. ")" end
      log:ok(("__REMOTES @ %s [%d]: %s"):format(label, #names, table.concat(names, ", ")), t)
      return true
    end
    if not dumpRemotes(workspace, "workspace") and not dumpRemotes(lp, "LocalPlayer") then
      log:warn("searching all descendants for __REMOTES...", t)
      local found = 0
      for _, d in ipairs(game:GetDescendants()) do
        if d.Name == "__REMOTES" then log:ok("found __REMOTES at: " .. d:GetFullName(), t); found = found + 1 end
      end
      if found == 0 then log:err("NO __REMOTES anywhere in the game", t) end
    end
  end)

  -- LEADERSTATS + Gems
  safe(log, "leaderstats", t, function()
    local ls = lp:FindFirstChild("leaderstats")
    if not ls then log:warn("no leaderstats", t); return end
    for _, v in ipairs(ls:GetChildren()) do log:info("leaderstats." .. v.Name .. " = " .. tostring(v.Value), t) end
    local g = ls:FindFirstChild("Gems")
    if g then log:ok("GEMS = " .. tostring(g.Value), t) else log:warn("no leaderstats.Gems (cap mode needs it)", t) end
  end)

  -- FRAMEWORK -> Library root (trade data + item catalog)
  safe(log, "framework", t, function()
    local fw = ReplicatedStorage:FindFirstChild("Framework")
    if not fw then log:err("no ReplicatedStorage.Framework", t); return end
    log:ok("Framework present (" .. fw.ClassName .. ")", t)
    local kids = {}
    for _, c in ipairs(fw:GetChildren()) do kids[#kids + 1] = c.Name .. "(" .. c.ClassName .. ")" end
    log:info("Framework children: " .. table.concat(kids, ", "), t)

    local libmod = fw:FindFirstChild("Library")
    if not libmod then log:err("no Framework.Library child (base requires this)", t); return end
    local ok, root = pcall(require, libmod)
    if not ok then log:err("require(Framework.Library) errored: " .. tostring(root), t); return end
    if type(root) ~= "table" then log:err("Library returned " .. type(root) .. " (expected table)", t); return end

    logDump(log, "Library root keys", root, t, { maxDepth = 1, maxKeys = 70 })

    -- Item categories: dump a few sample entries so we can find the id field.
    -- Inventory gets all its keys dumped - the live shape is a module of
    -- functions (GetSlot, GetOwnedByClassAndSubclass, ...) we still need to map.
    for _, catego in ipairs({ "Furniture", "Appliance", "Directory", "Inventory", "Food" }) do
      local tbl = root[catego]
      if type(tbl) == "table" then
        local n = 0
        local sampleMax = (catego == "Inventory") and 12 or 3
        for k, v in pairs(tbl) do
          n = n + 1
          if n <= sampleMax then logDump(log, catego .. "[" .. tostring(k) .. "]", (type(v) == "table" and v) or { value = v }, t, { maxDepth = 2 }) end
        end
        log:ok(catego .. " count = " .. n, t)
      end
    end
  end)

  -- INVENTORY API experiment: the live Library.Inventory is a module of
  -- functions with no known signatures (no reference implementation exists).
  -- Try the obvious call shapes under pcall and dump what comes back, so a
  -- future release can implement real stock reading.
  safe(log, "inventory-api", t, function()
    local fw = ReplicatedStorage:FindFirstChild("Framework")
    local libmod = fw and fw:FindFirstChild("Library")
    if not libmod then return end
    local ok, root = pcall(require, libmod)
    if not ok or type(root) ~= "table" then return end
    local inv = root.Inventory
    if type(inv) ~= "table" then log:info("Inventory is " .. type(inv), t); return end
    local function tryCall(fname, label, args)
      local f = inv[fname]
      if type(f) ~= "function" then log:info("no " .. fname .. " function", t); return end
      local okc, res = pcall(f, table.unpack(args, 1, args.n or #args))
      if not okc then
        log:info(fname .. " " .. label .. " errored: " .. tostring(res), t)
      elseif type(res) == "table" then
        logDump(log, fname .. " " .. label, res, t, { maxDepth = 2, maxKeys = 12 })
      else
        log:info(fname .. " " .. label .. " -> " .. tostring(res) .. " (" .. type(res) .. ")", t)
      end
    end
    -- GetOwnedByClassAndSubclass confirmed: dot-call (class, subclass) -> count.
    tryCall("GetOwnedByClassAndSubclass", 'f("Furniture","Chair")', { "Furniture", "Chair" })
    -- Map GetItemCount + Get so per-item ownership can be read. "13" = Wooden
    -- Counter (a Furniture/Table item), a good known id to probe.
    tryCall("GetItemCount", 'f("13")', { "13" })
    tryCall("GetItemCount", 'f(13)', { 13 })
    tryCall("GetItemCount", 'f("Furniture","Table","13")', { "Furniture", "Table", "13" })
    tryCall("GetItemCount", 'f("Furniture","13")', { "Furniture", "13" })
    tryCall("Get", 'f()', { n = 0 })
    tryCall("Get", 'f("13")', { "13" })
    tryCall("Get", 'f("Furniture")', { "Furniture" })
  end)

  -- TRADING STATUS: exercise the exact same path the trade loop uses
  -- (gamedata.getStatus -> Library.Network.Invoke("Trading_GetStatus")) so the
  -- probe can't pass while live polling is broken.
  safe(log, "trading-status", t, function()
    local fw = ReplicatedStorage:FindFirstChild("Framework")
    local libmod = fw and fw:FindFirstChild("Library")
    if not libmod then log:warn("no Framework.Library (status probe skipped)", t); return end
    local ok, root = pcall(require, libmod)
    if not ok or type(root) ~= "table" then log:err("Library require failed in status probe", t); return end
    local net = root.Network
    log:info("Network type = " .. type(net) .. ", Invoke type = " .. type(type(net) == "table" and net.Invoke or nil), t)
    local status, serr, raw = gamedata.getStatus(root)
    if not status then
      log:err("Trading_GetStatus poll FAILED: " .. tostring(serr), t)
      if type(raw) == "table" then logDump(log, "raw status payload", raw, t, { maxDepth = 2, maxKeys = 40 }) end
      return
    end
    logDump(log, "Trading_GetStatus", status, t, { maxDepth = 2, maxKeys = 40 })
    if type(status.activeTrade) == "table" then
      logDump(log, "status.activeTrade", status.activeTrade, t, { maxDepth = 2, maxKeys = 40 })
    end
    if type(status.incomingInvites) == "table" then
      logDump(log, "status.incomingInvites", status.incomingInvites, t, { maxDepth = 2, maxKeys = 20 })
    end
    log:ok("Trading_GetStatus poll works", t)
  end)

  -- chat channel
  safe(log, "chat", t, function()
    local tcs = game:GetService("TextChatService")
    local chans = tcs:FindFirstChild("TextChannels")
    local rbx = chans and chans:FindFirstChild("RBXGeneral")
    log:info("RBXGeneral channel present: " .. tostring(rbx ~= nil), t)
  end)
end

return M

end)()
__M["runtime.webhook_send"] = (function()
local HttpService = game:GetService("HttpService")
local webhook = __M["lib.webhook"]
local M = {}

local function httpPost(url, jsonBody)
  local req = http_request or request or (syn and syn.request) or (fluxus and fluxus.request)
  if not req then return false end
  return (pcall(function()
    req({
      Url = url,
      Method = "POST",
      Headers = { ["Content-Type"] = "application/json" },
      Body = jsonBody,
    })
  end))
end

-- send(cfg, event, data) -> bool. No-op unless the event is enabled + url set.
function M.send(cfg, event, data)
  if not webhook.enabledFor(cfg, event) then return false end
  local content = webhook.content(event, data)
  if not content then return false end
  local ok, body = pcall(function() return HttpService:JSONEncode({ content = content }) end)
  if not ok then return false end
  return httpPost(cfg.webhook.url, body)
end

return M

end)()
__M["runtime.survival"] = (function()
local Players = game:GetService("Players")
local M = {}

-- Anti-AFK: defeat the 20-minute idle kick via VirtualUser on the Idled signal.
function M.startAntiAfk(cfg)
  if not (cfg.survival and cfg.survival.antiAfk) then return end
  pcall(function()
    local VirtualUser = game:GetService("VirtualUser")
    Players.LocalPlayer.Idled:Connect(function()
      pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
      end)
    end)
  end)
end

-- Auto-reconnect: on a disconnect/kick error, rejoin the same place.
-- CONFIRM IN-GAME: the exact disconnect signal your executor surfaces.
function M.startReconnect(cfg, onEvent)
  if not (cfg.survival and cfg.survival.autoReconnect) then return end
  pcall(function()
    local GuiService = game:GetService("GuiService")
    local TeleportService = game:GetService("TeleportService")
    GuiService.ErrorMessageChanged:Connect(function(msg)
      if onEvent then onEvent("disconnect", { msg = tostring(msg) }) end
      task.wait(1)
      pcall(function() TeleportService:Teleport(game.PlaceId, Players.LocalPlayer) end)
    end)
  end)
end

-- Watchdog: run `fn` in a loop; if it errors, report + retry up to maxErrors.
function M.watchdog(cfg, name, fn, onEvent)
  if not (cfg.survival and cfg.survival.watchdog) then
    task.spawn(fn); return
  end
  task.spawn(function()
    local errs = 0
    while true do
      local ok, err = pcall(fn)
      if ok then break end
      errs = errs + 1
      if onEvent then onEvent("error", { msg = name .. ": " .. tostring(err) }) end
      if errs >= (cfg.survival.watchdogMaxErrors or 5) then break end
      task.wait(2)
    end
  end)
end

return M

end)()
__M["runtime.trade"] = (function()
local pricing = __M["lib.pricing"]
local negotiation = __M["lib.negotiation"]
local scamguard = __M["lib.scamguard"]
local gamedata = __M["runtime.gamedata"]

local M = {}

-- deps: { remotes, cfg, feed, catalog, getActiveTrade, refreshStatus,
--         pickSellItem, pickBuyItem, sendTradeMsg, log, mode, onSold, onBought }
function M.new(deps)
  return setmetatable({ d = deps, busy = false, loggedSide = false }, { __index = M })
end

-- Role-aware view of the trade (which side is us varies: inviter=target,
-- invitee=player). Logs our detected role once.
function M:info(at)
  local ti = gamedata.tradeInfo(at)
  if ti and not self.loggedSide then
    self.loggedSide = true
    self.d.log(("trade role: we are '%s'%s; buyer gems from offeredGems%s")
      :format(ti.mySide, ti.sideKnown and "" or " [GUESSED - couldn't match LocalPlayer]",
        (ti.theirSide == "player") and "Player" or "Target"))
  end
  return ti
end

-- Gems the buyer (the OTHER party) has put in. When SELLING we add items, never
-- gems, so our own offeredGems is 0 - which means the buyer's gems are simply
-- the larger of the two offeredGems fields. That's robust even if we can't tell
-- which side is us, so we use it whenever the role is uncertain.
function M:buyerGems(at)
  local ti = self:info(at)
  if not ti then return 0 end
  if ti.sideKnown then return ti.buyerGems or 0 end
  return math.max(ti.myGems or 0, ti.buyerGems or 0)
end

-- Whether the buyer has pressed confirm. nil = unknown (never confirm on it).
function M:targetConfirmed(at)
  local ti = self:info(at)
  if not ti then return nil end
  return ti.theirConfirmed
end

-- Live trade object via a fresh status poll (searched, not just .activeTrade -
-- the live status shape differs from the deob); falls back to the cached
-- status when the poll itself fails.
function M:freshTrade()
  local d = self.d
  if d.refreshStatus then
    local s = d.refreshStatus()
    if type(s) == "table" then return (gamedata.findActiveTrade(s)) end
  end
  return d.getActiveTrade()
end

-- Wait until the other player presses confirm (the game's own vendor script
-- gates on targetConfirmed before firing trading_confirmtrade). Gets its OWN
-- full window - negotiation time already spent must not shrink the human
-- buyer's time to press confirm. minGems: also abort if their offered gems
-- drop below it (sell mode). Returns true, or (false, reason).
function M:waitTargetConfirm(minGems)
  local d = self.d
  local warned = false
  local t0 = os.time()
  while os.time() - t0 <= (d.cfg.tradeTimeoutSec or 60) do
    local at = self:freshTrade()
    if type(at) ~= "table" then return false, "trade vanished while waiting for confirm" end
    if minGems then
      local bg = self:buyerGems(at)
      if bg < minGems then
        return false, ("buyer lowered gems to %s (required %s)"):format(tostring(bg), tostring(minGems))
      end
    end
    local confirmed = self:targetConfirmed(at)
    if confirmed == true then return true end
    if confirmed == nil and not warned then
      warned = true
      d.log("no target-confirm field on activeTrade - will time out rather than blind-confirm")
    end
    task.wait(0.5)
  end
  return false, "timeout waiting for other player to confirm"
end

-- After firing confirm, wait for the trade to actually complete (activeTrade
-- clears or tradeUID changes) before the sale/buy is recorded. Judges ONLY on
-- fresh successful polls - a failed poll must not be mistaken for "no change"
-- (or the cached still-open trade would suppress recording a completed sale).
function M:verifyCompletion(prevUID)
  local d = self.d
  local deadline = os.time() + (d.cfg.confirmVerifyTimeoutSec or 10)
  while os.time() <= deadline do
    task.wait(0.5)
    local s = d.refreshStatus and d.refreshStatus()
    if type(s) == "table" then
      local at = s.activeTrade
      if type(at) ~= "table" then return true end
      if prevUID ~= nil and at.tradeUID ~= nil and at.tradeUID ~= prevUID then return true end
    end
  end
  return false
end

-- Shared confirm protocol: fire the confirm remote, verify completion.
-- Spy-confirmed: trading_confirmtrade takes the ENTIRE current trade object as
-- its argument (not no-args) - the server validates you're confirming the exact
-- state you see. Returns true only when the trade demonstrably finished.
function M:confirmTrade(fresh)
  local prevUID = (type(fresh) == "table") and fresh.tradeUID or nil
  self:fireTrade("Trading_ConfirmTrade", "trading_confirmtrade", fresh)
  return self:verifyCompletion(prevUID)
end

-- Confirm the sale now (buyer gems already meet `required`), then wait for the
-- buyer to also confirm and the countdown to finish. Records the sale only if
-- our gem balance actually rises (so an abort/scam doesn't count as a sale). If
-- the buyer drops gems below `required` after we confirm (the trade state
-- change also un-confirms us), we bail; if our confirm gets reset, we re-fire.
function M:confirmAndComplete(setName, fresh, required, marketVal)
  local d = self.d
  local prevUID = (type(fresh) == "table") and fresh.tradeUID or nil
  local gemsBefore = d.getGems and d.getGems() or nil
  d.log(("CONFIRMING sell of %s: buyer gems %s >= required %s"):format(setName, tostring(self:buyerGems(fresh)), tostring(required)))
  self:fireTrade("Trading_ConfirmTrade", "trading_confirmtrade", fresh)

  local deadline = os.time() + (d.cfg.tradeTimeoutSec or 60)
  while os.time() <= deadline do
    task.wait(0.5)
    local s = d.refreshStatus and d.refreshStatus()
    local at = s and gamedata.findActiveTrade(s) or nil
    if type(at) ~= "table" or (prevUID and at.tradeUID and at.tradeUID ~= prevUID) then
      -- trade window closed - completed OR aborted. Confirm via our gem balance.
      task.wait(0.5)
      local gemsAfter = d.getGems and d.getGems() or nil
      if gemsBefore and gemsAfter and gemsAfter > gemsBefore then
        if d.onSold then d.onSold(setName, 1, gemsAfter - gemsBefore, marketVal or 0) end
      else
        d.log("trade window closed but gems did not increase - not recording (buyer aborted?)")
      end
      return
    end
    local bg = self:buyerGems(at)
    if bg < required then
      return self:abort(("buyer reduced gems to %s after confirm - aborting"):format(tostring(bg)))
    end
    -- if a state change un-confirmed us but gems are still good, re-confirm
    local ti = self:info(at)
    if ti and ti.iConfirmed == false then
      self:fireTrade("Trading_ConfirmTrade", "trading_confirmtrade", at)
    end
  end
  return self:abort("confirmed but trade didn't complete (buyer never confirmed)")
end

function M:handle(invite)
  if self.busy then return end
  self.busy = true
  local ok, err = pcall(function()
    if self.d.mode and self.d.mode() == "buy" and self.d.cfg.buyEnabled then
      self:runBuy(invite)
    else
      self:runSell(invite)
    end
  end)
  if not ok then self:abort("error: " .. tostring(err)) end
  self.busy = false
end

function M:waitForTrade(timeout)
  local d = self.d
  local start = os.time()
  local warnedBusy = false
  repeat
    local at = self:freshTrade()
    if type(at) == "table" then return at end
    -- Key diagnostic: the server says we're in a trade but we can't find the
    -- trade object - the field name differs from every guess. Dump everything.
    if not warnedBusy and d.myBusy and d.myBusy() then
      warnedBusy = true
      d.log("server marks us BUSY (trade open) but no trade object found in status - dumping full status")
      if d.dumpFullStatus then d.dumpFullStatus("full status while busy") end
    end
    task.wait(0.4)
  until os.time() - start > (timeout or 15)
  return self:freshTrade()
end

-- Fire a trade action via Network.Fire (game-exact) with a direct-remote
-- fallback. Spy-confirmed the game routes everything through Network.Fire.
function M:fireTrade(netName, remoteName, ...)
  if self.d.fire then return self.d.fire(netName, remoteName, ...) end
  local r = self.d.remotes[remoteName]
  if r then pcall(r.FireServer, r, ...); return true end
  return false
end

-- Accept + wait for the window. Spy-confirmed: the game accepts via
-- Network.Fire("Trading_AcceptInvite", Player) - the Player OBJECT.
function M:acceptAndWait(invite)
  local d = self.d
  if invite.active then return self:waitForTrade(d.cfg.acceptTimeoutSec or 15) end
  local who = invite.player
  if type(who) ~= "userdata" and invite.uid then who = gamedata.playerFromUid(invite.uid) end
  if type(who) ~= "userdata" then d.log("no Player object to accept invite - skipping"); return nil end
  d.log("accepting invite (Player) " .. tostring(invite.name or ""))
  self:fireTrade("Trading_AcceptInvite", "trading_acceptinvite", who)
  local at = self:waitForTrade(d.cfg.acceptTimeoutSec or 15)
  if not at and d.dumpFullStatus then d.dumpFullStatus("full status after accept never showed a trade") end
  return at
end

-- Is our item already sitting in the trade? Uses OUR side (role-aware).
-- Prevents re-adding the same item on a re-handled window.
function M:itemAlreadyOffered(at, id)
  local ti = self:info(at)
  local mine = ti and ti.myItems or nil
  if type(mine) ~= "table" then return false end
  for _, it in pairs(mine) do
    local iid = (type(it) == "table" and (it.itemID or it.id or it.ID)) or it
    if iid ~= nil and tostring(iid) == tostring(id) then return true end
  end
  return false
end

-- ---- SELL -------------------------------------------------------------------
function M:runSell(invite)
  local d = self.d
  local at = self:acceptAndWait(invite)
  if not at then return self:abort("no active trade after accept") end

  local order = d.pickSellItem and d.pickSellItem(at)
  if not order then return self:abort("no active sell order (add one on the Items tab)") end
  local setName = (type(order) == "table") and order.item or order
  if not d.catalog[setName] then return self:abort("'" .. tostring(setName) .. "' has no game item id - pick another") end

  local feedEntry = d.feed[setName]
  local orderPrice = (type(order) == "table") and tonumber(order.price) or nil
  local quote, hardFloor
  if orderPrice then
    -- Fixed-price order: sell firmly at the user's price, never below it.
    quote = { ask = orderPrice, ceiling = orderPrice, floor = orderPrice }
    hardFloor = orderPrice
  else
    local override = (d.cfg.items or {})[setName] or {}
    quote = pricing.quote(d.cfg, feedEntry or {}, override, 1)
    if not quote then return self:abort("unpriceable: " .. setName) end
    local marketVal = feedEntry and tonumber(feedEntry.value)
    hardFloor = marketVal and math.floor(marketVal * (d.cfg.minSellPct or 90) / 100) or quote.floor
  end
  -- cost basis for profit stats = item's market worth (fall back to the price)
  local marketVal = (feedEntry and tonumber(feedEntry.value)) or orderPrice or 0

  -- add our item once (don't pile it on if a re-handle left it in the window)
  local itemId = d.catalog[setName].id
  if self:itemAlreadyOffered(self:freshTrade() or at, itemId) then
    d.log(setName .. " already offered in this trade - not re-adding")
  elseif not self:addItem(setName) then
    return self:abort("could not add " .. setName)
  end
  if d.sendTradeMsg then
    d.sendTradeMsg(("Selling %s for %s gems - add gems and confirm!"):format(setName, tostring(quote.ask)))
  end
  d.log(("SELL %s | ask %s ceiling %s floor %s hardFloor %s | buyer has %s")
    :format(setName, tostring(quote.ask), tostring(quote.ceiling), tostring(quote.floor), tostring(hardFloor), tostring(self:buyerGems(at))))

  -- Patient loop: wait (HOLD) for the buyer to add gems up to tradeTimeoutSec;
  -- only abort early if they actively offer a positive amount that's too low.
  -- `round` advances only on real haggling (chat counters), not passive waits.
  local start = os.time()
  local round = 0
  while true do
    if os.time() - start > (d.cfg.tradeTimeoutSec or 60) then return self:abort("timeout waiting for buyer gems") end
    local cur = self:freshTrade()
    if type(cur) ~= "table" then return self:abort("trade window closed") end
    local bg = self:buyerGems(cur)
    local decision = negotiation.decide(d.cfg, quote, { offeredGems = bg, round = round, elapsed = os.time() - start })
    d.log(("round %d: buyer=%s decision=%s"):format(round, tostring(bg), decision.action))

    if decision.action == "ACCEPT" then
      local required = math.max(negotiation.threshold(d.cfg, quote, round), hardFloor)
      local fresh = self:freshTrade() or cur
      local fg = self:buyerGems(fresh)
      if not scamguard.safeToConfirmSell(required, fg) then
        return self:abort(("safety: buyer %s < required %s (hardFloor %s)"):format(tostring(fg), tostring(required), tostring(hardFloor)))
      end
      -- optional extra safety: wait for the buyer to press confirm first. OFF by
      -- default (it deadlocks when the buyer is waiting on US).
      if d.cfg.requireBuyerConfirm then
        local okc, why = self:waitTargetConfirm(required)
        if not okc then return self:abort(why) end
      end
      if d.cfg.testMode then
        d.log(("TEST MODE: WOULD CONFIRM sell of %s - buyer gems %s >= required %s (not confirming)")
          :format(setName, tostring(fg), tostring(required)))
        task.wait(1)
        return self:abort("test mode (no confirm)")
      end
      return self:confirmAndComplete(setName, fresh, required, marketVal)
    elseif decision.action == "COUNTER" then
      if d.sendTradeMsg then d.sendTradeMsg(decision.message) end
      round = round + 1
      task.wait(d.cfg.negotiation.chatCooldownSec or 4)
    elseif decision.action == "ABORT" then
      -- buyer actively put in gems but too few -> give up; if they just haven't
      -- added anything yet, keep waiting until the timeout above
      if bg and bg > 0 then return self:abort(("buyer offer too low (%s)"):format(tostring(bg))) end
      task.wait(2)
    else
      task.wait(2)
    end
  end
end

-- ---- BUY (gem-cap mode) -----------------------------------------------------
function M:runBuy(invite)
  local d = self.d
  local at = self:acceptAndWait(invite)
  if not at then return self:abort("buy: no active trade") end

  local setName = d.pickBuyItem and d.pickBuyItem(at)
  if not setName then return self:abort("buy: item not on buy list") end
  local feedEntry = d.feed[setName]
  local wantEntry = (d.cfg.buy or {})[setName] or {}
  local bq = pricing.buyQuote(d.cfg, feedEntry or {}, wantEntry, 1)
  if not bq then return self:abort("no buy price: " .. setName) end

  local start = os.time()
  for round = 0, (d.cfg.negotiation.maxRounds or 3) do
    local cur = self:freshTrade() or at
    local ask = self:buyerGems(cur)
    local decision = negotiation.decideBuy(d.cfg, bq, { sellerAsk = ask, round = round, elapsed = os.time() - start })
    if decision.action == "ACCEPT" then
      local fresh = self:freshTrade() or cur
      if not scamguard.safeToConfirmBuy(bq.max, self:buyerGems(fresh)) then
        return self:abort("scam-guard: seller raised price")
      end
      if d.cfg.requireBuyerConfirm then
        local okc, why = self:waitTargetConfirm(nil)
        if not okc then return self:abort("buy: " .. tostring(why)) end
      end
      fresh = self:freshTrade() or fresh
      if not scamguard.safeToConfirmBuy(bq.max, self:buyerGems(fresh)) then
        return self:abort("scam-guard: seller raised price at confirm")
      end
      local paid = self:buyerGems(fresh)
      if d.cfg.testMode then
        d.log(("TEST MODE: WOULD BUY %s for %s (sellerConfirmed=%s) - not confirming"):format(
          setName, tostring(paid), tostring(self:targetConfirmed(fresh))))
        return self:abort("test mode (no confirm)")
      end
      if self:confirmTrade(fresh) then
        if d.onBought then d.onBought(setName, 1, paid) end
      else
        d.log("confirm fired but buy did not complete in time - buy NOT recorded")
      end
      return
    elseif decision.action == "COUNTER" then
      if d.sendTradeMsg then d.sendTradeMsg(decision.message) end
      task.wait(d.cfg.negotiation.chatCooldownSec or 4)
    elseif decision.action == "ABORT" then
      return self:abort("buy negotiation failed")
    else
      task.wait(2)
    end
    if os.time() - start > (d.cfg.tradeTimeoutSec or 60) then return self:abort("timeout") end
  end
  return self:abort("buy max rounds")
end

-- ---- shared -----------------------------------------------------------------
function M:addItem(setName)
  local c = self.d.catalog[setName]
  if not c then self.d.log("no itemID for '" .. tostring(setName) .. "'"); return false end
  -- Spy-confirmed: the descriptor is passed DIRECTLY (not array-wrapped) -
  -- trading_additem:FireServer({itemID="4", className="Appliance"}).
  local descriptor = { itemID = tostring(c.id), className = c.className or setName }
  self:fireTrade("Trading_AddItem", "trading_additem", descriptor)
  self.d.log(("added %s (id %s class %s)"):format(setName, tostring(c.id), tostring(c.className)))
  return true
end

function M:abort(reason)
  self:fireTrade("Trading_Abort", "trading_abort")
  self.d.log("Aborted: " .. reason)
end

return M

end)()
__M["runtime.advertiser"] = (function()
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ads = __M["lib.ads"]
local M = {}

-- cloneref hides our reference to the service from the game's anti-cheat hooks
-- (executor builtin; harmless passthrough where it isn't available).
local function cref(o) return (cloneref and cloneref(o)) or o end

-- Legacy remote path (fallback only - on this game the remote EXISTS but is
-- inert: FireServer succeeds yet nothing posts, which is why v1.9.1's
-- ChatVersion-based routing looked "sent" but showed nothing).
local function sayLegacy(text)
  return pcall(function()
    local ev = cref(ReplicatedStorage):FindFirstChild("DefaultChatSystemChatEvents")
    local req = ev and ev:FindFirstChild("SayMessageRequest")
    if not req then error("no SayMessageRequest") end
    req:FireServer(text, "All")
  end)
end

-- Post to public chat. Route by which channel EXISTS (method calls are
-- cloneref-safe) rather than reading .ChatVersion (that PROPERTY misreads off a
-- clonereffed service - it reported Legacy on this modern game). My Restaurant
-- is TextChatService (RBXGeneral confirmed present), so SendAsync is primary.
-- Returns (ok, err, path) so callers can log which path actually sent.
local function sendChat(text)
  text = tostring(text)
  local ok, err = pcall(function()
    local channels = cref(TextChatService):FindFirstChild("TextChannels")
    local ch = channels and channels:FindFirstChild("RBXGeneral")
    if not ch then error("no RBXGeneral channel") end
    ch:SendAsync(text)
  end)
  if ok then return true, nil, "SendAsync" end
  local okL, errL = sayLegacy(text)
  if okL then return true, nil, "SayMessageRequest" end
  return false, tostring(err) .. " / " .. tostring(errL), nil
end
M.sendChat = sendChat

-- Advertise the active sell orders at their fixed prices (skip filled orders,
-- and out-of-stock ones when inventory is known).
local function buildListings(cfg, feed, owned)
  local listings = {}
  for _, o in ipairs(cfg.orders or {}) do
    if (o.sold or 0) < (o.qty or 0) then
      if (not owned) or (owned[o.item] and owned[o.item] > 0) then
        listings[#listings + 1] = { name = o.item, ask = tonumber(o.price) or 0 }
      end
    end
  end
  return listings
end
M.buildListings = buildListings

-- deps: { cfg, feed, ownedFn, log, remotes, isBusy, hasActiveTrade }
function M.start(deps)
  local cfg = deps.cfg

  -- Ad loop. Chat sends go through the filter + rate limits and spam is an
  -- account-ban vector, so the interval is floored at 45s.
  local warnedOff, warnedNoInv, loggedChatPath = false, false, false
  task.spawn(function()
    while true do
      if cfg.enabled and cfg.ads.rotatingAds then
        warnedOff = false
        local owned = nil
        if cfg.ads.stockOnly then
          owned = deps.ownedFn and deps.ownedFn() or nil
          if owned == nil and not warnedNoInv then
            -- the live Library.Inventory can't be read yet: advertise anyway
            -- (the user picked what they're selling) rather than go silent
            warnedNoInv = true
            deps.log("stock unknown - advertising without stock check")
          end
        end
        local listings = buildListings(cfg, deps.feed, owned)
        local line = ads.line(listings, { maxItems = 5 })
        if line then
          local ok, err, path = sendChat(line)
          if ok and not loggedChatPath then loggedChatPath = true; deps.log("chat path = " .. tostring(path)) end
          deps.log(ok and ("Ad sent: " .. line) or ("Ad FAILED (chat): " .. tostring(err)))
        else
          deps.log("Ad skipped: no active sell orders" .. (owned and " (in stock)" or "") .. " - add one on the Items tab")
        end
      elseif cfg.enabled and not cfg.ads.rotatingAds and not warnedOff then
        warnedOff = true
        deps.log("Ads OFF (turn on 'Rotating Chat Ads' to advertise)")
      end
      task.wait(math.max(45, cfg.ads.intervalSec or 45))
    end
  end)

  -- Auto-invite loop: trading_sendinvite:FireServer(player) is a real remote
  -- (the game's own script uses it). Only fires when idle, per-player cooldown,
  -- never to blocklisted players.
  local lastInvited = {}
  local function isBlocklisted(plr)
    local bl = cfg.blocklist
    return bl and (bl[plr.Name] or bl[plr.UserId] or bl[tostring(plr.UserId)]) and true or false
  end
  task.spawn(function()
    while true do
      task.wait(15)
      if cfg.enabled and cfg.ads.autoInvite
        and (deps.fire or (deps.remotes and deps.remotes.trading_sendinvite))
        and not (deps.isBusy and deps.isBusy())
        and not (deps.hasActiveTrade and deps.hasActiveTrade()) then
        pcall(function()
          local now = os.time()
          local window = cfg.inviteCooldownSec or 120
          for uid, at in pairs(lastInvited) do -- keep the 24/7 table bounded
            if (now - at) > window then lastInvited[uid] = nil end
          end
          local sent = 0
          for _, plr in ipairs(Players:GetPlayers()) do
            if sent >= 5 then break end
            -- don't invite players already mid-trade (they can't accept us)
            local busy = deps.isBusyPlayer and deps.isBusyPlayer(plr.UserId)
            if plr ~= Players.LocalPlayer and not isBlocklisted(plr) and not busy then
              local last = lastInvited[plr.UserId]
              if not last or (now - last) >= window then
                if deps.fire then deps.fire("Trading_SendInvite", "trading_sendinvite", plr)
                else deps.remotes.trading_sendinvite:FireServer(plr) end
                lastInvited[plr.UserId] = now
                sent = sent + 1
                deps.log("invited " .. plr.Name)
                task.wait(0.5)
              end
            end
          end
        end)
      end
    end
  end)
end

return M

end)()
__M["runtime.ui"] = (function()
local M = {}

local WINDUI_URL = "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"

-- Build a self-contained WindUI window for the layer. Independent of the base
-- (the base's own window handle is locked inside its obfuscated VM).
-- deps: { cfg, feed, save, stats, onToggleEnabled }
-- Returns the window handle (with :setStatus) or nil on failure.
function M.build(deps)
  local cfg, save = deps.cfg, deps.save
  local ok, WindUI = pcall(function()
    return loadstring(game:HttpGet(WINDUI_URL))()
  end)
  if not ok or not WindUI then return nil end

  -- Reopen key for the hide/show fallback below. We bind this ourselves and do
  -- NOT also pass WindUI's ToggleKey option - both handling the same key would
  -- double-toggle and cancel out.
  local TOGGLE_KEY = Enum.KeyCode.RightControl

  local Window = WindUI:CreateWindow({
    Title = "Universal Auto-Trade",
    Icon = "arrows-exchange",
    Author = "by 0xfray",
    Folder = "OdResto",
    Size = UDim2.fromOffset(580, 520),
    Transparent = true,
    Theme = "Dark",
    -- Floating button shown while the window is closed/minimized (newer WindUI
    -- releases; older ones just ignore unknown options).
    OpenButton = {
      Title = "Open Auto-Trade",
      Enabled = true,
      Draggable = true,
      OnlyMobile = false,
    },
  })

  local Main = Window:Tab({ Title = "Auto-Trade", Icon = "coins" })
  local Items = Window:Tab({ Title = "Items", Icon = "list" })
  local Safety = Window:Tab({ Title = "24/7 & Safety", Icon = "shield" })
  local Diag = Window:Tab({ Title = "Diagnostics", Icon = "bug" })

  local statusParagraph = Main:Paragraph({
    Title = "Status", Desc = "Idle - not enabled.",
  })

  -- ---- Diagnostics tab ----
  Diag:Paragraph({ Title = "Controls",
    Desc = "Right Ctrl hides/shows this window. When it's minimized, a floating 'Open Auto-Trade' button also brings it back." })
  Diag:Paragraph({ Title = "Debug report",
    Desc = "Press Copy, then paste it back to get help. It lists remotes, gem sources, and boot steps." })
  Diag:Button({ Title = "Copy Debug Report", Icon = "clipboard-copy",
    Callback = function()
      local copied = deps.debug and deps.debug.copy and deps.debug.copy()
      pcall(function()
        WindUI:Notify({ Title = "Auto-Trade",
          Content = copied and "Copied! Paste it back." or "Printed to console (no clipboard).",
          Duration = 5 })
      end)
    end })
  Diag:Button({ Title = "Print Debug Report to Console", Icon = "terminal",
    Callback = function() if deps.debug and deps.debug.print then deps.debug.print() end end })
  Diag:Button({ Title = "Send Test Chat Message", Icon = "message-square",
    Callback = function()
      if not (deps.debug and deps.debug.testChat) then return end
      local ok, err, path = deps.debug.testChat()
      pcall(function()
        WindUI:Notify({ Title = "Auto-Trade",
          Content = ok and ("Sent via " .. tostring(path) .. " - check chat.") or ("Failed: " .. tostring(err)),
          Duration = 6 })
      end)
    end })

  -- ---- Main tab: enable + advertising. What/how-much/price live on Items. ----
  Main:Toggle({ Title = "Enable Universal Auto-Trade", Value = cfg.enabled,
    Callback = function(v) cfg.enabled = v; save(cfg); if deps.onToggleEnabled then deps.onToggleEnabled(v) end end })
  Main:Toggle({ Title = "Test Mode (accepts + adds item, never confirms)", Value = cfg.testMode ~= false,
    Callback = function(v) cfg.testMode = v; save(cfg) end })
  Main:Paragraph({ Title = "How it works",
    Desc = "Add sell orders on the Items tab (item + quantity + price each). The bot fills each order at your price until the quantity is done or your gems hit the cap." })
  Main:Toggle({ Title = "Rotating Chat Ads", Value = cfg.ads.rotatingAds,
    Callback = function(v) cfg.ads.rotatingAds = v; save(cfg) end })
  Main:Toggle({ Title = "Auto-Invite Nearby", Value = cfg.ads.autoInvite,
    Callback = function(v) cfg.ads.autoInvite = v; save(cfg) end })
  Main:Toggle({ Title = "Ads: In-Stock Only", Value = cfg.ads.stockOnly,
    Callback = function(v) cfg.ads.stockOnly = v; save(cfg) end })

  -- ---- Items tab: sell-order builder ----
  local orders  = deps.orders
  local shortFn = deps.shortFn or tostring
  local parse   = deps.parse

  Items:Paragraph({ Title = "Add a sell order",
    Desc = deps.itemsAreOwned and "Items you own that can be traded."
      or "Showing all sellable items (couldn't read your inventory yet - it'll narrow to what you own once that's mapped)." })

  local opts = {}
  for _, n in ipairs(deps.itemOptions or {}) do opts[#opts + 1] = n end
  if #opts == 0 then opts = { "(no items)" } end
  local selItem, selQty, selPrice = opts[1], 1, nil

  Items:Dropdown({ Title = "Item", Values = opts, Value = opts[1],
    Callback = function(sel) selItem = sel end })
  Items:Input({ Title = "Quantity (e.g. 100)",
    Callback = function(txt) selQty = math.floor(tonumber((txt:gsub("[^%d]", ""))) or 0) end })
  Items:Input({ Title = "Price each (e.g. 750k)",
    Callback = function(txt) selPrice = parse and parse.gems(txt) or tonumber(txt) end })

  local ordersPara = Items:Paragraph({ Title = "Current orders", Desc = "(none)" })
  local function refreshOrders()
    local lines = orders.summaryLines(cfg, shortFn)
    pcall(function() ordersPara:SetDesc(#lines > 0 and table.concat(lines, "\n") or "(none)") end)
  end
  refreshOrders()

  local function notify(txt) pcall(function() WindUI:Notify({ Title = "Auto-Trade", Content = txt, Duration = 5 }) end) end
  Items:Button({ Title = "Add / Update Order", Icon = "plus",
    Callback = function()
      local o, err = orders.add(cfg, selItem, selQty, selPrice)
      if o then save(cfg); refreshOrders()
        notify(("Selling %d x %s @ %s each"):format(o.qty, o.item, shortFn(o.price)))
      else notify("Couldn't add order: " .. tostring(err)) end
    end })
  Items:Button({ Title = "Remove Selected Item's Order", Icon = "trash",
    Callback = function() if orders.remove(cfg, selItem) then save(cfg); refreshOrders() end end })
  Items:Button({ Title = "Clear All Orders", Icon = "trash-2",
    Callback = function() orders.clear(cfg); save(cfg); refreshOrders() end })

  -- ---- Safety / 24-7 tab ----
  Safety:Toggle({ Title = "Auto-Buyer at Gem Cap", Value = cfg.buyEnabled,
    Callback = function(v) cfg.buyEnabled = v; save(cfg) end })
  Safety:Input({ Title = "Gem Cap (default 100000000)",
    Callback = function(txt) cfg.gemCap = deps.parse and deps.parse.gems(txt) or tonumber(txt) or cfg.gemCap; save(cfg) end })
  Safety:Toggle({ Title = "Stop Selling at Gem Cap", Value = cfg.stopAtGemCap ~= false,
    Callback = function(v) cfg.stopAtGemCap = v; save(cfg) end })
  Safety:Input({ Title = "Buy Discount % (default 10)",
    Callback = function(txt) cfg.buyDiscountPct = tonumber(txt) or cfg.buyDiscountPct; save(cfg) end })
  Safety:Input({ Title = "Player Cooldown sec (default 30)",
    Callback = function(txt) cfg.cooldownSec = tonumber(txt) or cfg.cooldownSec; save(cfg) end })
  Safety:Toggle({ Title = "Wait for Buyer Confirm first (may stall)", Value = cfg.requireBuyerConfirm == true,
    Callback = function(v) cfg.requireBuyerConfirm = v; save(cfg) end })
  Safety:Input({ Title = "Invite Cooldown sec (default 120)",
    Callback = function(txt) cfg.inviteCooldownSec = tonumber(txt) or cfg.inviteCooldownSec; save(cfg) end })
  Safety:Toggle({ Title = "Auto-Reconnect", Value = cfg.survival.autoReconnect,
    Callback = function(v) cfg.survival.autoReconnect = v; save(cfg) end })
  Safety:Toggle({ Title = "Anti-AFK", Value = cfg.survival.antiAfk,
    Callback = function(v) cfg.survival.antiAfk = v; save(cfg) end })
  Safety:Input({ Title = "Discord Webhook URL (blank = off)",
    Callback = function(txt) cfg.webhook.url = txt or ""; save(cfg) end })

  -- Keyboard fallback to get the window back when it's closed/minimized, in
  -- case the WindUI release in use lacks the floating OpenButton. Prefers
  -- Window:Toggle() (hide AND show); falls back to Window:Open() (show only).
  pcall(function()
    local UIS = game:GetService("UserInputService")
    UIS.InputBegan:Connect(function(input, gameProcessed)
      if gameProcessed then return end
      if input.KeyCode ~= TOGGLE_KEY then return end
      pcall(function()
        if type(Window.Toggle) == "function" then Window:Toggle()
        elseif type(Window.Open) == "function" then Window:Open() end
      end)
    end)
  end)

  local handle = { window = Window, status = statusParagraph }
  function handle.setStatus(text)
    pcall(function() statusParagraph:SetDesc(text) end)
  end
  function handle.notify(text)
    pcall(function() WindUI:Notify({ Title = "Auto-Trade", Content = text, Duration = 8 }) end)
  end
  handle.notify("Right Ctrl hides/shows this window. A floating 'Open Auto-Trade' button appears when minimized.")
  return handle
end

return M

end)()
-- === main ===
-- Universal Auto-Trade - STANDALONE. Talks to the game directly
-- (workspace.__THINGS.__REMOTES + Framework.Library) and builds its own WindUI.
local CONFIG = {
  feedUrl = "https://raw.githubusercontent.com/0xfray/Mr-script/refs/heads/main/MR/value.lua",
  version = "v1.14-confirm",
}

local libConfig  = __M["lib.config"]
local libFeed    = __M["lib.feed"]
local capmode    = __M["lib.capmode"]
local libStats   = __M["lib.stats"]
local LogBuf     = __M["lib.logbuf"]
local dump       = __M["lib.dump"]
local remotesM   = __M["runtime.remotes"]
local gamedata   = __M["runtime.gamedata"]
local persist    = __M["runtime.persist"]
local inventory  = __M["runtime.inventory"]
local prober     = __M["runtime.prober"]
local TradeM     = __M["runtime.trade"]
local advertiser = __M["runtime.advertiser"]
local survival   = __M["runtime.survival"]
local webhookSend= __M["runtime.webhook_send"]
local cooldownLib= __M["lib.cooldown"]
local tradefields= __M["lib.tradefields"]
local ordersLib  = __M["lib.orders"]
local libAds     = __M["lib.ads"]
local parse      = __M["lib.parse"]
local ui         = __M["runtime.ui"]

local dbg = LogBuf.new(1200)
local function nows() return string.format("%.2fs", os.clock()) end
local function logp(t) print("[AutoTrade] " .. t); dbg:info(t, nows()) end
local function logstep(t) print("[AutoTrade] * " .. t); dbg:step(t, nows()) end
local function logwarn(t) warn("[AutoTrade] " .. t); dbg:warn(t, nows()) end
local function logok(t) print("[AutoTrade] OK " .. t); dbg:ok(t, nows()) end
local function logDump(label, tbl) dbg:info(label .. ":", nows()); for _, l in ipairs(dump.lines(tbl, { maxDepth = 3, maxKeys = 40 })) do dbg:info("  " .. l, nows()) end end

logstep("boot " .. CONFIG.version)

local cfg = libConfig.merge(libConfig.defaults(), persist.loadSettings() or {})
logok("settings loaded (enabled=" .. tostring(cfg.enabled) .. " testMode=" .. tostring(cfg.testMode) .. ")")

local function fetchFeed()
  local ok, raw = pcall(function() return loadstring(game:HttpGet(CONFIG.feedUrl))() end)
  if ok and type(raw) == "table" then persist.saveFeedCache(raw); return libFeed.normalize(raw) end
  return nil, raw
end
local feed, feedErr = fetchFeed()
if feed then logok("feed fetched (" .. libFeed.count(feed) .. " items)")
else feed = libFeed.normalize(persist.loadFeedCache() or {})
  logwarn("feed fetch failed (" .. tostring(feedErr) .. "); cache=" .. libFeed.count(feed) .. " items") end

local statsObj = persist.loadStats() or libStats.new(os.time())
local function onEvent(event, data) pcall(webhookSend.send, cfg, event, data) end
local function copyReport()
  local r = dbg:report("AutoTrade " .. CONFIG.version)
  if setclipboard then pcall(setclipboard, r) elseif toclipboard then pcall(toclipboard, r) end
  print(r)
end

-- ---- connect to the game -----------------------------------------------------
local wrongPlace = not libConfig.placeAllowed(cfg, game.PlaceId)
local remotes, rroot, catalog
if wrongPlace then
  logwarn(("WRONG GAME: place=%s (need Trading Plaza 13200523806 or Pro Plaza 13279398864)"):format(tostring(game.PlaceId)))
else
  logstep("resolving remotes (workspace.__THINGS.__REMOTES)")
  local rerr; remotes, rerr = remotesM.resolveRemotes(20)
  if remotes then logok("remotes resolved via " .. tostring(rerr)) else logwarn("remotes NOT resolved: " .. tostring(rerr)) end
  logstep("acquiring Framework Library root")
  local rooterr; rroot, rooterr = gamedata.root(20)
  if rroot then logok("Library root acquired") else logwarn("Library root FAILED: " .. tostring(rooterr)) end
  if rroot then catalog = gamedata.catalog(rroot) end
end

logstep("probing environment"); pcall(function() prober.run(dbg, nows()) end); logok("probe complete")

-- ---- sellable list = items in BOTH the game catalog and the value feed -------
local vendItems = {}
if catalog then
  for name in pairs(catalog) do
    if feed[name] and feed[name].value then vendItems[#vendItems + 1] = name end
  end
  table.sort(vendItems)
  logok(("sellable items (in game + value list): %d"):format(#vendItems))
else
  for name in pairs(feed) do vendItems[#vendItems + 1] = name end
  table.sort(vendItems)
end

-- ---- item options for the order builder: your OWNED tradeable items if the
-- inventory can be read, otherwise every sellable item (labeled) ---------------
local itemOptions, itemsAreOwned = vendItems, false
do
  local ownedMap = catalog and inventory.owned(rroot, catalog) or nil
  if type(ownedMap) == "table" and next(ownedMap) then
    local owned = {}
    for name in pairs(ownedMap) do
      if feed[name] and feed[name].value and catalog[name] then owned[#owned + 1] = name end
    end
    if #owned > 0 then table.sort(owned); itemOptions, itemsAreOwned = owned, true end
  end
  logok(("item options: %d (%s)"):format(#itemOptions, itemsAreOwned and "your inventory" or "all sellable - inventory unreadable"))
end

-- ---- build UI (now that we know what's sellable) -----------------------------
local uiHandle = ui.build({ cfg = cfg, feed = feed, vendItems = vendItems,
  itemOptions = itemOptions, itemsAreOwned = itemsAreOwned,
  orders = ordersLib, shortFn = libAds.short, parse = parse,
  save = persist.saveSettings, stats = statsObj,
  debug = { copy = copyReport, print = function() print(dbg:report("AutoTrade " .. CONFIG.version)) end,
    testChat = function()
      local ok, err, path = advertiser.sendChat("[AutoTrade] chat test - please ignore")
      logp(ok and ("chat test sent via " .. tostring(path)) or ("chat test FAILED: " .. tostring(err)))
      return ok, err, path
    end },
  onToggleEnabled = function() end })
if uiHandle then logok("WindUI panel loaded") else logwarn("WindUI panel FAILED to load") end
local function setStatus(t) if uiHandle and uiHandle.setStatus then uiHandle.setStatus(t) end end
if wrongPlace then
  setStatus("Wrong game. Open the Trading Plaza (13200523806) or Pro Plaza (13279398864), then reload.")
  if uiHandle and uiHandle.notify then uiHandle.notify("Open a Trading Plaza to trade.") end
end

survival.startAntiAfk(cfg); survival.startReconnect(cfg, onEvent)
logok("survival started")

-- ---- trading -----------------------------------------------------------------
if remotes and rroot then
  local catCount = 0; for _ in pairs(catalog) do catCount = catCount + 1 end
  logok("item catalog built (" .. tostring(catCount) .. " ids)")

  local latestStatus
  local pollOkN, pollFailN, pollStreakFail, lastPollErr = 0, 0, 0, nil
  local dumpedStatus, dumpedAT, dumpedInvite = false, false, false
  local loggedTradeKey = false
  local function getActiveTrade()
    local at, key = gamedata.findActiveTrade(latestStatus)
    if at and not loggedTradeKey then
      loggedTradeKey = true
      logp("active trade object found under status." .. tostring(key))
    end
    return at
  end
  local function getGems() return gamedata.gems() end

  -- Fire a trade action the way the GAME does: Library.Network.Fire("Trading_X",
  -- ...) - the remote-spy showed the game routes EVERY trade action through this
  -- (never a direct remote FireServer), so our direct calls may not fully take.
  -- Falls back to the __REMOTES remote if the Network layer is unavailable.
  local firedVia
  local function fire(netName, remoteName, ...)
    local net = rroot and rroot.Network
    if net and type(net.Fire) == "function" then
      local ok = pcall(net.Fire, netName, ...)
      if ok then
        if firedVia ~= "Network.Fire" then firedVia = "Network.Fire"; logok("trade actions via Network.Fire") end
        return true
      end
    end
    local r = remotes[remoteName]
    if r then
      pcall(r.FireServer, r, ...)
      if firedVia ~= "remote" then firedVia = "remote"; logwarn("trade actions via direct remote (no Network.Fire)") end
      return true
    end
    return false
  end
  local function sendTradeMsg(text) fire("Trading_SendMessage", "trading_sendmessage", text) end

  -- Live status poll: Library.Network.Invoke("Trading_GetStatus") - the game's
  -- ONLY status source (there are no status remotes/events). Tracks health so
  -- the debug report proves whether polling works. A short staleness cache
  -- keeps the 1s loop and the in-trade 0.4-0.5s waits sharing one result
  -- stream instead of each hitting the rate-limited server.
  local lastPollOkClock, dumpedBadStatus = nil, false
  local function refreshStatus()
    if latestStatus and lastPollOkClock and (os.clock() - lastPollOkClock) < 0.4 then
      return latestStatus
    end
    local s, serr, raw = gamedata.getStatus(rroot)
    if s then
      pollOkN = pollOkN + 1; pollStreakFail = 0; lastPollOkClock = os.clock()
      if pollOkN == 1 then logok("status poll OK (Network.Invoke Trading_GetStatus)") end
      latestStatus = s
    else
      pollFailN = pollFailN + 1; pollStreakFail = pollStreakFail + 1; lastPollErr = serr
      if raw and not dumpedBadStatus then dumpedBadStatus = true; logDump("unrecognized status shape", raw) end
      if pollStreakFail == 10 then logwarn("status poll failed 10x in a row: " .. tostring(serr)) end
    end
    return s
  end

  local function isSellable(name) return (name and catalog[name] and feed[name] and feed[name].value) and true or false end
  -- Returns the current sell ORDER (item + fixed price) to work, or nil.
  local function pickSellItem(_at) return ordersLib.next(cfg, isSellable) end
  local function pickBuyItem(at)
    local offered = at and at.offeredItemsTarget
    if type(offered) == "table" then for _, it in pairs(offered) do local c = (type(it) == "table" and (it.class or it.className or it.name)) or it; if c and cfg.buy[c] and cfg.buy[c].wantBuy then return c end end end
    return nil
  end

  local lastMode = "sell"
  local function mode()
    local gems = getGems(); local m = capmode.mode(cfg, gems, lastMode)
    if m == "buy" and lastMode ~= "buy" then onEvent("cap", { gems = gems }); logp("gem cap -> buy mode") end
    lastMode = m; return m
  end
  local function onSold(item, qty, gems, cost)
    libStats.recordSell(statsObj, gems, cost)
    local sold, oqty, done = ordersLib.recordSale(cfg, item)
    persist.saveStats(statsObj); persist.saveSettings(cfg)
    onEvent("sale", { item = item, qty = qty, gems = gems, profit = gems - cost })
    local prog = sold and (" [%d/%s]"):format(sold, tostring(oqty)) or ""
    logp(("SOLD %s for %s%s"):format(item, tostring(gems), prog))
    setStatus(("Sold %s for %s%s"):format(item, tostring(gems), prog))
    if done then logp(("ORDER COMPLETE: %s %d/%d"):format(item, sold, oqty)) end
    if ordersLib.allDone(cfg) then logp("All sell orders complete - idling."); setStatus("All sell orders complete.") end
  end
  local function onBought(item, qty, gems)
    libStats.recordBuy(statsObj, gems); persist.saveStats(statsObj)
    onEvent("buy", { item = item, qty = qty, gems = gems }); logp(("BOUGHT %s for %s"):format(item, tostring(gems)))
  end

  local runner = TradeM.new({
    remotes = remotes, cfg = cfg, feed = feed, catalog = catalog, fire = fire,
    getActiveTrade = getActiveTrade, refreshStatus = refreshStatus, sendTradeMsg = sendTradeMsg, getGems = getGems,
    myBusy = function() return gamedata.myBusy(latestStatus) end,
    dumpFullStatus = function(label) logDump(label, latestStatus or {}) end,
    pickSellItem = pickSellItem, pickBuyItem = pickBuyItem,
    log = logp, mode = mode, onSold = onSold, onBought = onBought,
  })

  -- one gated + busy-aware dispatcher (stops the invite spam)
  local cooldownState = {}
  local function gate(uid, name)
    uid = tonumber(uid) or uid -- one key per player whether ids arrive as string or number
    local t = os.time()
    -- prune stale entries so a 24/7 session doesn't grow this forever
    for k, at in pairs(cooldownState) do
      if (t - at) > math.max(300, (cfg.cooldownSec or 30) * 4) then cooldownState[k] = nil end
    end
    local okg, reason = cooldownLib.allow(cfg, { uid = uid, name = name }, cooldownState[uid], t)
    if okg then cooldownState[uid] = t end
    return okg, reason
  end
  local function playerName(p)
    if type(p) == "userdata" then local ok, n = pcall(function() return p.Name end); return ok and n or "?" end
    return tostring(p)
  end
  -- Should we be trading right now? nil = yes; else a human-readable reason.
  -- Stops when gems hit the cap (and we're not buying) or no order needs units.
  local lastIdle
  local function idleReason()
    if cfg.buyEnabled then return nil end -- buy mode has its own item logic
    local gems = getGems()
    if cfg.stopAtGemCap and gems >= (tonumber(cfg.gemCap) or math.huge) then
      return ("gem cap reached (%s) - stopping"):format(tostring(gems))
    end
    if not ordersLib.next(cfg, isSellable) then
      return ordersLib.allDone(cfg) and "all sell orders complete"
        or "no active sell order - add one on the Items tab"
    end
    return nil
  end
  local function idle()
    local r = idleReason()
    if r and r ~= lastIdle then logp("idle: " .. r) end
    lastIdle = r
    return r ~= nil
  end
  -- Handlers run in task.spawn so the 1s status poll keeps running mid-trade
  -- (runner.busy is set before any yield, so no double-dispatch).
  local function tryHandleInvite(uid, player)
    if not cfg.enabled or not uid or runner.busy then return end
    if idle() then return end
    local name = playerName(player)
    if not gate(uid, player and name or nil) then return end
    logp(("HANDLING invite from %s uid=%s"):format(name, tostring(uid)))
    task.spawn(function() runner:handle({ uid = uid, player = player, name = name }) end)
  end
  -- Handle each OPEN trade window exactly once. Without this, an open trade the
  -- buyer keeps alive (e.g. after we abort) gets re-dispatched every tick and
  -- our item is re-added indefinitely - a giveaway risk. Cleared when the trade
  -- closes (see processStatus), so a genuinely new trade (new UID) is handled.
  local handledTradeUID
  local function tryHandleActiveTrade(at)
    if not cfg.enabled or runner.busy then return end
    local tuid = type(at) == "table" and at.tradeUID or nil
    if tuid and tuid == handledTradeUID then return end -- already handled this window
    if idle() then return end
    local uid = tradefields.partnerId(at)
    local player = uid and gamedata.playerFromUid(uid) or nil
    if uid then
      local okg, reason = gate(uid, player and player.Name or nil)
      if not okg then
        if reason == "blocked" then
          -- blocklisted partner holds a window open: decline it instead of
          -- deadlocking (processStatus skips invites while any trade is open).
          handledTradeUID = tuid
          logp("declining active trade with BLOCKED partner uid=" .. tostring(uid))
          fire("Trading_Abort", "trading_abort")
        end
        return
      end
    end
    handledTradeUID = tuid
    logp("HANDLING active trade" .. (player and (" with " .. player.Name) or "") .. " uid=" .. tostring(uid))
    task.spawn(function() runner:handle({ active = true, uid = uid, player = player, name = player and player.Name or nil }) end)
  end

  local busySkipLogged = {}
  local function processStatus(s)
    if type(s) ~= "table" then return end
    latestStatus = s
    if not dumpedStatus then dumpedStatus = true; logDump("status (trimmed)", { activeTrade = s.activeTrade, incomingInvites = s.incomingInvites, outgoingInvites = s.outgoingInvites }) end
    local at = (gamedata.findActiveTrade(s))
    if type(at) == "table" then
      if not dumpedAT then dumpedAT = true; logDump("activeTrade fields", at) end
      -- a trade window is already open (their accept, or our own outgoing
      -- invite got accepted) - drive it; never also dispatch invites now
      tryHandleActiveTrade(at)
      return
    end
    handledTradeUID = nil -- no open trade -> next one (new UID) may be handled
    local inv = s.incomingInvites
    if type(inv) == "table" then
      for key, entry in pairs(inv) do
        if not dumpedInvite then dumpedInvite = true; logDump("incomingInvites entry", (type(entry) == "table" and entry) or { value = entry }) end
        local uid = (type(entry) == "table" and (entry.uid or entry.id)) or key
        uid = tonumber(uid) or uid  -- one cooldown entry per player, string or number key
        -- Skip inviters the server marks busy: a live dump proved accepting a
        -- busy player's invite opens NO trade window (they're mid-trade with
        -- someone else) - it just hangs, then aborts. Wait for a free inviter.
        if gamedata.isBusy(s, uid) then
          if not busySkipLogged[uid] then
            busySkipLogged[uid] = true
            logp("skipping invite from busy (mid-trade) player uid=" .. tostring(uid))
          end
        else
          busySkipLogged[uid] = nil
          local player = gamedata.playerFromUid(uid)
          if not player then
            -- only a real Player instance is usable (as accept arg / blocklist
            -- name); a raw table would FireServer garbage - fall back to entry.inviter
            local e = type(entry) == "table" and (entry.inviter or entry.player) or nil
            if type(e) == "userdata" then player = e end
          end
          tryHandleInvite(uid, player)
        end
      end
    end
  end

  local ticks = 0
  survival.watchdog(cfg, "trade-loop", function()
    while true do
      ticks = ticks + 1
      local s = refreshStatus()
      if s then processStatus(s) end
      if ticks % 15 == 1 then
        local nInv = 0
        local inv = latestStatus and latestStatus.incomingInvites
        if type(inv) == "table" then for _ in pairs(inv) do nInv = nInv + 1 end end
        logp(("heartbeat: enabled=%s testMode=%s orders=%d units_left=%d busy=%s activeTrade=%s gems=%s poll=%d/%d invites=%d%s"):format(
          tostring(cfg.enabled), tostring(cfg.testMode), #(cfg.orders or {}), ordersLib.remaining(cfg),
          tostring(runner.busy), tostring(getActiveTrade() ~= nil), tostring(getGems()),
          pollOkN, pollFailN, nInv,
          (pollStreakFail > 0 and lastPollErr) and (" lastPollErr=" .. tostring(lastPollErr)) or ""))
      end
      task.wait(1)
    end
  end, onEvent)

  advertiser.start({ cfg = cfg, feed = feed, log = logp,
    ownedFn = function() return inventory.owned(rroot, catalog) end,
    remotes = remotes, fire = fire,
    isBusy = function() return runner.busy end,
    hasActiveTrade = function() return getActiveTrade() ~= nil end,
    isBusyPlayer = function(userId) return gamedata.isBusy(latestStatus, userId) end })
  setStatus("Ready. Trading " .. (cfg.enabled and "ENABLED" or "disabled") .. (cfg.testMode and " (TEST)" or "") .. ".")
  logok("trading wired")
elseif not wrongPlace then
  setStatus("Not fully wired (remotes=" .. tostring(remotes ~= nil) .. " root=" .. tostring(rroot ~= nil) .. ").")
end

if (cfg.feedRefreshSec or 0) > 0 then
  task.spawn(function()
    while true do
      task.wait(cfg.feedRefreshSec); local fresh = fetchFeed()
      if fresh then for k in pairs(feed) do feed[k] = nil end; for k, v in pairs(fresh) do feed[k] = v end; logp("feed refreshed") end
    end
  end)
end

logstep("ready. items=" .. libFeed.count(feed) .. " options=" .. #itemOptions .. " orders=" .. #(cfg.orders or {}) .. " remotes=" .. tostring(remotes ~= nil) .. " root=" .. tostring(rroot ~= nil))
logp("Add a sell order on the Items tab (item + quantity + price each), enable, keep Test Mode ON, then Copy Debug Report.")
