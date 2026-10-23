--!strict
-- SaturnClient Monitoring Engine v5.0
local http_fn = request or http_request or (syn and syn.request)
if not http_fn then
    warn("[SaturnClient] Экскутор не поддерживает сетевые запросы.")
    return
end

local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")

-- === НАСТРОЙКИ СВЯЗИ ===
local WORKER_URL = "https://cvvclub.capsulen9.workers.dev/"
local SHARED_SECRET = "Saturn-Secure-Key-991"
-- =======================

local localPlayer = Players.LocalPlayer
while not localPlayer do
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    localPlayer = Players.LocalPlayer
end

-- 1. Алгоритм хэширования DJB2 (32-bit без знакопеременных сдвигов)
local function djb2(str: string): string
    local hash = 5381
    for i = 1, #str do
        local byte = string.byte(str, i)
        hash = bit32.band(bit32.lshift(hash, 5) + hash + byte, 0xFFFFFFFF)
    end
    return string.format("%x", hash)
end

-- 2. Аппаратный детект платформы через GetPlatform
local function getPlatformName(): string
    local platformEnum = UserInputService:GetPlatform()
    local name = platformEnum.Name
    if name == "Windows" or name == "UWP" or name == "OSX" then
        return "PC (" .. name .. ")"
    elseif name == "Android" or name == "IOS" then
        return "Mobile (" .. name .. ")"
    elseif name == "XBoxOne" or name == "PS4" or name == "PS5" then
        return "Console (" .. name .. ")"
    end
    return name
end

-- 3. Сбор точных метрик устройства
local function getClientStats()
    local memory = math.floor(Stats:GetTotalMemoryUsageMb())
    local ping = 0
    pcall(function()
        local item = Stats.Network.ServerStatsItem["Data Ping"]
        if item then ping = math.floor(item:GetValue()) end
    end)

    return {
        Ping = ping,
        Memory = memory,
        Platform = getPlatformName(),
    }
end

-- 4. Дедупликация ошибок по хэшу всего сообщения (устраняет коллизии)
local CacheManager = {
    _list = {} :: { [number]: string },
    _set = {} :: { [string]: number },
    _maxSize = 50,
}

function CacheManager.has(hashKey: string): boolean
    local timestamp = CacheManager._set[hashKey]
    if not timestamp then return false end
    return (tick() - timestamp < 120)
end

function CacheManager.add(hashKey: string): ()
    if #CacheManager._list >= CacheManager._maxSize then
        local oldest = table.remove(CacheManager._list, 1)
        if oldest then CacheManager._set[oldest] = nil end
    end
    table.insert(CacheManager._list, hashKey)
    CacheManager._set[hashKey] = tick()
end

local function sanitizeHtml(str: string): string
    local clean = string.gsub(str, "[%z\1-\8\11\12\14-\31]", "")
    clean = string.gsub(clean, "&", "&amp;")
    clean = string.gsub(clean, "<", "&lt;")
    clean = string.gsub(clean, ">", "&gt;")
    return clean
end

-- 5. Отправка с динамической подписью и tick()-кулдауном
local lastRequestTick = 0
local REQUEST_COOLDOWN = 2.0

local function sendThroughGateway(htmlText: string)
    local currentTick = tick()
    if currentTick - lastRequestTick < REQUEST_COOLDOWN then return end
    lastRequestTick = currentTick

    local encodeSuccess, payload = pcall(function()
        return HttpService:JSONEncode({ text = htmlText })
    end)
    if not encodeSuccess or not payload then return end

    -- Формирование временной подписи
    local nowSeconds = os.time()
    local signature = djb2(string.format("%d:%s:%d:%s", localPlayer.UserId, game.JobId, nowSeconds, SHARED_SECRET))

    pcall(function()
        http_fn({
            Url = WORKER_URL,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
                ["X-Saturn-Signature"] = signature,
                ["X-Saturn-Time"] = tostring(nowSeconds),
                ["X-Saturn-Uid"] = tostring(localPlayer.UserId),
                ["X-Saturn-Jid"] = tostring(game.JobId),
            },
            Body = payload
        })
    end)
end

-- 6. Перехват ошибок с хэш-сигнатурой
LogService.MessageOut:Connect(function(msg: string, msgType: Enum.MessageType)
    if msgType ~= Enum.MessageType.MessageError then return end

    -- Хэшируем все сообщение, чтобы ошибки с похожим началом не схлопывались
    local errorHash = djb2(msg)
    if CacheManager.has(errorHash) then return end
    CacheManager.add(errorHash)

    local stats = getClientStats()
    local report = string.format(
        "⚠️ <b>SaturnClient | Ошибка выполнения</b>\n\n"
        .. "👤 <b>User:</b> <code>%s</code> (%d)\n"
        .. "🎮 <b>Place:</b> <code>%d</code>\n"
        .. "📊 <b>Пинг:</b> %d ms | <b>ОЗУ:</b> %d MB\n"
        .. "📱 <b>ОС / Устройство:</b> %s\n"
        .. "⏰ <b>Время:</b> %s\n\n"
        .. "❌ <b>Текст ошибки:</b>\n<code>%s</code>",
        localPlayer.Name,
        localPlayer.UserId,
        game.PlaceId,
        stats.Ping,
        stats.Memory,
        stats.Platform,
        os.date("%H:%M:%S"),
        sanitizeHtml(string.sub(msg, 1, 1000))
    )

    task.spawn(sendThroughGateway, report)
end)

-- 7. Инициализация сессии
task.spawn(function()
    task.wait(1.5)
    local stats = getClientStats()
    local startMessage = string.format(
        "🪐 <b>SaturnClient | Сессия запущена</b>\n\n"
        .. "👤 <b>Игрок:</b> <code>%s</code>\n"
        .. "🆔 <b>UserId:</b> <code>%d</code>\n"
        .. "🕹️ <b>PlaceId:</b> <code>%d</code>\n"
        .. "🌐 <b>JobId:</b> <code>%s</code>\n"
        .. "📊 <b>ОЗУ:</b> %d MB | <b>Пинг:</b> %d ms\n"
        .. "📱 <b>Платформа:</b> %s\n"
        .. "📅 <b>Дата:</b> <code>%s</code>",
        localPlayer.Name,
        localPlayer.UserId,
        game.PlaceId,
        game.JobId,
        stats.Memory,
        stats.Ping,
        stats.Platform,
        os.date("%Y-%m-%d %H:%M:%S")
    )
    sendThroughGateway(startMessage)
end)
