-- Universal Auto-Trade SPY v1 - logs what the GAME sends when you act manually.
-- Hooks outgoing remote calls (FireServer / InvokeServer / SendAsync) and the
-- Framework Library.Network Invoke/Fire layer, printing the exact arguments -
-- so we can see precisely how the game accepts invites, adds gems/items, sends
-- trade messages, and confirms. Read-only: every hook just LOGS then calls the
-- original. Standalone (no dependencies on AutoTrade).
--
--   USAGE: run this ALONE (disable/close AutoTrade first). Then manually:
--   accept an invite, add an item, add gems, send a trade message, confirm.
--   Press F8 to copy the full log (also saved to OdResto/spy_log.txt), then
--   paste it back. F9 clears the log.

local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")

local START = os.clock()
local buf, MAX = {}, 2000
local busy = false -- reentrancy guard so our own logging never re-hooks

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
  if low:find("getstatus") then return false end -- our/their poll spam
  if underRemotes(self) then return true end
  return low:find("trad") or low:find("invite") or low:find("gem")
      or low:find("item") or low:find("message") or low:find("chat") ~= nil
end

-- ---- hook __namecall (FireServer / InvokeServer / SendAsync) -----------------
if hookmetamethod and getnamecallmethod then
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
else
  warn("[SPY] no hookmetamethod/getnamecallmethod - remote args won't be captured on this executor")
end

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

-- ---- copy / clear -----------------------------------------------------------
local function dump()
  local report = "===== AutoTrade SPY log =====\n" .. table.concat(buf, "\n") .. "\n===== end ====="
  if setclipboard then pcall(setclipboard, report) elseif toclipboard then pcall(toclipboard, report) end
  if writefile then
    pcall(function()
      if makefolder and not (isfolder and isfolder("OdResto")) then pcall(makefolder, "OdResto") end
      writefile("OdResto/spy_log.txt", report)
    end)
  end
  print(report)
  print(("[SPY] copied %d lines (F8). Paste it back."):format(#buf))
end

UIS.InputBegan:Connect(function(input, gp)
  if gp then return end
  if input.KeyCode == Enum.KeyCode.F8 then dump()
  elseif input.KeyCode == Enum.KeyCode.F9 then buf = {}; print("[SPY] log cleared (F9)") end
end)

log("spy", "READY. Do your actions manually (accept invite, add item, add gems, send msg, confirm). Press F8 to copy.")
print("[SPY] Universal Auto-Trade SPY active. F8 = copy log, F9 = clear.")
