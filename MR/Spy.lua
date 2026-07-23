-- Universal Auto-Trade SPY v2 - logs what the GAME sends when you act manually.
-- Hooks outgoing remote calls (FireServer / InvokeServer / SendAsync) and the
-- Framework Library.Network Invoke/Fire layer, printing the exact arguments -
-- so we can see precisely how the game accepts invites, adds gems/items, sends
-- trade messages, and confirms. Read-only: every hook just LOGS then calls the
-- original. Standalone (no dependencies on AutoTrade).
--
--   USAGE: run this ALONE (close AutoTrade first). A small draggable panel
--   appears - do your actions manually (accept invite, add item, add gems, send
--   msg, confirm), then click "Copy Log to Clipboard" and paste it back.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")

local START = os.clock()
local buf, MAX = {}, 2000
local busy = false     -- reentrancy guard so our own logging never re-hooks
local countLabel       -- set once the GUI is built
local dump             -- forward declaration (assigned below; used by the GUI)

-- ---- value formatting -------------------------------------------------------
local function repr(v, depth)
  depth = depth or 0
  local ok, tv = pcall(function() return typeof(v) end)
  tv = ok and tv or type(v)
  if tv == "Instance" then
    local cls, nm = "?", "?"
    pcall(function() cls = v.ClassName end)
    pcall(function() nm = v.Name end)
    if cls == "Player" then
      local uid; pcall(function() uid = v.UserId end)
      return ("Player<%s uid=%s>"):format(nm, tostring(uid))
    end
    return cls .. "<" .. nm .. ">"
  elseif tv == "table" then
    if depth >= 3 then return "{...}" end
    local parts, n = {}, 0
    for k, val in pairs(v) do
      n = n + 1
      if n > 15 then parts[#parts + 1] = "..."; break end
      parts[#parts + 1] = tostring(k) .. "=" .. repr(val, depth + 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  elseif tv == "string" then
    return '"' .. v .. '"'
  end
  return tostring(v)
end

local function reprArgs(...)
  local n = select("#", ...)
  local out = {}
  for i = 1, n do out[i] = repr((select(i, ...))) end
  return table.concat(out, ", ")
end

local function log(cat, msg)
  local line = ("[%8.2fs] %-14s %s"):format(os.clock() - START, cat, msg)
  buf[#buf + 1] = line
  if #buf > MAX then table.remove(buf, 1) end
  print("[SPY] " .. line)
  if countLabel then pcall(function() countLabel.Text = #buf .. " events logged" end) end
end

-- ---- GUI (built FIRST so it always appears even if a hook fails) -------------
local function buildGui()
  local sg = Instance.new("ScreenGui")
  sg.Name = "ATSpy"; sg.ResetOnSpawn = false; sg.IgnoreGuiInset = true
  sg.DisplayOrder = 999999; sg.Enabled = true

  local frame = Instance.new("Frame")
  frame.Size = UDim2.fromOffset(220, 116); frame.Position = UDim2.fromOffset(30, 150)
  frame.BackgroundColor3 = Color3.fromRGB(22, 22, 27); frame.BackgroundTransparency = 0.05
  frame.BorderSizePixel = 0; frame.Active = true; frame.Parent = sg
  Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
  local stroke = Instance.new("UIStroke", frame)
  stroke.Color = Color3.fromRGB(46, 108, 224); stroke.Thickness = 2

  local title = Instance.new("TextLabel")
  title.Size = UDim2.new(1, -12, 0, 18); title.Position = UDim2.fromOffset(8, 6)
  title.BackgroundTransparency = 1; title.TextXAlignment = Enum.TextXAlignment.Left
  title.Font = Enum.Font.GothamBold; title.TextSize = 13
  title.TextColor3 = Color3.fromRGB(235, 235, 240); title.Text = "AutoTrade SPY  (drag)"
  title.Parent = frame

  countLabel = Instance.new("TextLabel")
  countLabel.Size = UDim2.new(1, -12, 0, 15); countLabel.Position = UDim2.fromOffset(8, 26)
  countLabel.BackgroundTransparency = 1; countLabel.TextXAlignment = Enum.TextXAlignment.Left
  countLabel.Font = Enum.Font.Gotham; countLabel.TextSize = 12
  countLabel.TextColor3 = Color3.fromRGB(150, 205, 150); countLabel.Text = #buf .. " events logged"
  countLabel.Parent = frame

  local function mkButton(text, y, color)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -16, 0, 27); b.Position = UDim2.fromOffset(8, y)
    b.BackgroundColor3 = color; b.BorderSizePixel = 0; b.AutoButtonColor = true
    b.Font = Enum.Font.GothamMedium; b.TextSize = 13; b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.Text = text; b.Parent = frame
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
  end

  local copyBtn = mkButton("Copy Log to Clipboard", 48, Color3.fromRGB(46, 108, 224))
  local clearBtn = mkButton("Clear", 80, Color3.fromRGB(70, 70, 80))
  copyBtn.MouseButton1Click:Connect(function()
    local n = dump and dump() or 0
    copyBtn.Text = "Copied " .. tostring(n) .. " lines!"
    task.delay(1.5, function() pcall(function() copyBtn.Text = "Copy Log to Clipboard" end) end)
  end)
  clearBtn.MouseButton1Click:Connect(function()
    buf = {}; if countLabel then countLabel.Text = "0 events logged" end; print("[SPY] log cleared")
  end)

  -- drag
  local dragging, dragStart, startPos
  frame.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
      dragging = true; dragStart = i.Position; startPos = frame.Position
    end
  end)
  frame.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
  end)
  UIS.InputChanged:Connect(function(i)
    if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
      local d = i.Position - dragStart
      frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
  end)

  -- mount to a place the game can't wipe; try each, report where it landed
  local where
  if gethui then local ok = pcall(function() sg.Parent = gethui() end); if ok then where = "gethui" end end
  if not where and syn and syn.protect_gui then pcall(function() syn.protect_gui(sg) end) end
  if not where then local ok = pcall(function() sg.Parent = game:GetService("CoreGui") end); if ok then where = "CoreGui" end end
  if not where then local ok = pcall(function() sg.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end); if ok then where = "PlayerGui" end end
  return where
end

do
  local ok, res = pcall(buildGui)
  if ok and res then
    print("[SPY] GUI mounted in " .. res .. ". Blue-bordered panel top-left - drag it if hidden.")
  else
    warn("[SPY] GUI could not be shown (" .. tostring(res) .. "). Use the F8 key to copy the log instead.")
  end
end

-- ---- copy / save ------------------------------------------------------------
dump = function()
  local report = "===== AutoTrade SPY log =====\n" .. table.concat(buf, "\n") .. "\n===== end ====="
  if setclipboard then pcall(setclipboard, report) elseif toclipboard then pcall(toclipboard, report) end
  if writefile then
    pcall(function()
      if makefolder and not (isfolder and isfolder("OdResto")) then pcall(makefolder, "OdResto") end
      writefile("OdResto/spy_log.txt", report)
    end)
  end
  print(report)
  print(("[SPY] copied %d lines. Paste it back."):format(#buf))
  return #buf
end

-- ---- what to log (skip the high-frequency status poll) ----------------------
local function nameOf(inst)
  local nm = "?"; pcall(function() nm = inst.Name end)
  return nm
end
local function underRemotes(inst)
  local ok, par = pcall(function() return inst.Parent end)
  if not ok or not par then return false end
  return nameOf(par) == "__REMOTES"
end
local function shouldLog(method, self)
  if method == "SendAsync" then return true end -- chat
  local low = nameOf(self):lower()
  if low:find("getstatus") then return false end -- poll spam
  if underRemotes(self) then return true end
  return low:find("trad") or low:find("invite") or low:find("gem")
      or low:find("item") or low:find("message") or low:find("chat") ~= nil
end

-- ---- hook __namecall (FireServer / InvokeServer / SendAsync) -----------------
pcall(function()
  if not (hookmetamethod and getnamecallmethod) then
    warn("[SPY] no hookmetamethod/getnamecallmethod - remote args won't be captured on this executor")
    return
  end
  local old
  old = hookmetamethod(game, "__namecall", function(self, ...)
    if not busy then
      local method = getnamecallmethod()
      if method == "FireServer" or method == "InvokeServer" or method == "SendAsync" then
        busy = true
        local packed = table.pack(...)
        pcall(function()
          if shouldLog(method, self) then
            log(method, nameOf(self) .. "(" .. reprArgs(table.unpack(packed, 1, packed.n)) .. ")")
          end
        end)
        busy = false
      end
    end
    return old(self, ...)
  end)
  log("spy", "namecall hook active (FireServer/InvokeServer/SendAsync)")
end)

-- ---- hook Library.Network.Invoke / .Fire (dot-call function layer) -----------
pcall(function()
  local Library = require(RS:WaitForChild("Framework", 10):WaitForChild("Library", 10))
  local net = type(Library) == "table" and Library.Network
  if type(net) ~= "table" then return end
  for _, fname in ipairs({ "Invoke", "Fire" }) do
    local orig = net[fname]
    if type(orig) == "function" then
      net[fname] = function(...)
        if not busy then
          busy = true
          local packed = table.pack(...)
          pcall(function()
            local first = packed[1]
            if not (type(first) == "string" and first:lower():find("getstatus")) then
              log("Network." .. fname, reprArgs(table.unpack(packed, 1, packed.n)))
            end
          end)
          busy = false
        end
        return orig(...)
      end
    end
  end
  log("spy", "Network.Invoke/Fire hooks active")
end)

-- ---- keyboard backup --------------------------------------------------------
UIS.InputBegan:Connect(function(input, gp)
  if gp then return end
  if input.KeyCode == Enum.KeyCode.F8 then dump()
  elseif input.KeyCode == Enum.KeyCode.F9 then buf = {}; if countLabel then countLabel.Text = "0 events logged" end; print("[SPY] log cleared (F9)") end
end)

log("spy", "READY. Act manually (accept invite, add item, add gems, send msg, confirm), then click Copy.")
print("[SPY] Universal Auto-Trade SPY v2 active.")
