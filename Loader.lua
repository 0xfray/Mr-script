local HttpGet = game.HttpGet
local PlaceId = game.PlaceId

local success, Games = pcall(function()
    return loadstring(HttpGet(game, "https://raw.githubusercontent.com/ditampol-tzuyoon/Ohdear/refs/heads/main/GameList.lua"))()
end)

if not success or not Games then
    warn("Gagal load GameList")
    return
end

local url = Games[PlaceId]
if not url then
    warn("Game tidak didukung:", PlaceId)
    return
end

local ok, err = pcall(function()
    loadstring(HttpGet(game, url))()
end)

if not ok then
    warn("Gagal load script:", err)
end
