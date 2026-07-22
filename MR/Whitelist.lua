-- ── Whitelist config ────────────────────────────────────────────────
-- WHITELIST_ENABLED = true   -> only the HWIDs listed below can load
-- WHITELIST_ENABLED = false  -> public mode: anyone can load
local WHITELIST_ENABLED = false

-- [ raw gethwid() ] = expiry (Unix time). Gate kicks if os.time() > expiry.
local entries = {
    ["ca4169567d75af4344c01ec48172ce22f2f57a44363ddf9b07b5fbe0a687d00c21f8db56b3d5aa46c4006b8498687c37"] = 1816230439,
}
-- ────────────────────────────────────────────────────────────────────

return setmetatable(entries, {
    __index = function()
        if not WHITELIST_ENABLED then
            return 9999999999   -- toggle OFF: any HWID gets an always-valid expiry
        end
        return nil              -- toggle ON: unlisted HWID -> gate kicks
    end,
})
