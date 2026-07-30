-- ── Whitelist config ────────────────────────────────────────────────
-- WHITELIST_ENABLED = true   -> only the HWIDs listed below can load
-- WHITELIST_ENABLED = false  -> public mode: anyone can load
local WHITELIST_ENABLED = true

-- [ raw gethwid() ] = expiry (Unix time). Gate kicks if os.time() > expiry.
local entries = {
    ["ca4169567d75af4344c01ec48172ce22f2f57a44363ddf9b07b5fbe0a687d00c21f8db56b3d5aa46c4006b8498687c37"] = 9999999999,
    ["92d23061dce80448f72c8fa5ae3176cf9a56825a6ae6b866642f69b56f6e3094"] = 9999999999,
    ["a0199fdb2af3c31ecb1fda711f416e3ab1adde87a1bcc07a16b1fdad20a1b204"] = 9999999999,
    ["007b8b7c93e2b0dc5b339c35ee64e5381620cdcbd70264728f7eed29db3d1573"] = 9999999999,
    ["dbd3b6d26112833de9cb652b06e39b23c35abc3e68e1b3690dd0b81dccbd46e3"] = 9999999999,
    ["ba1baf74e06f93e359950d899412dcde40839760bd98071a5d9e360038fce06a"] = 9999999999,
    ["954754c7d3af11f0a1ae806e6f6e6963"] = 9999999999,
    ["48F8A5C43036B8573CA5351EBEFB7B"] = 9999999999,
    ["b9a2ae61e747798afbe9995c4c271b8f7d424e60d84aa457113599ccc6de8cec"] = 9999999999,
    ["642D690A3C07B40438F435679889F8"] = 9999999999,
    ["EDIT-THIS-LATER"] = 9999999999,
    ["EDIT-THIS-LATER"] = 9999999999,
    ["EDIT-THIS-LATER"] = 9999999999,
    ["EDIT-THIS-LATER"] = 9999999999,
    ["EDIT-THIS-LATER"] = 9999999999,
    
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
