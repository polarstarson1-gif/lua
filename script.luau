-- Roblox: sulfurmelt | Discord: omorune (1136974289053159456)
-- Gold Collection System: DataStore with session locks, metatable data wrapper, leaderstats, and physics respawn
-- Main components interact: loadPlayer -> acquireLock -> getData -> PlayerData -> makeLeaderstats -> gold touch -> savePlayer

-- services
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- data stores
-- mainStore is primary save, backupStore is redundancy in case main write fails
local mainStore = DataStoreService:GetDataStore("PlayerGoldV1")
local backupStore = DataStoreService:GetDataStore("PlayerGoldBackup")

-- remote
-- used to sync gold to client UI, server remains authoritative
local updateGold = ReplicatedStorage:WaitForChild("UpdateGold", 10)

-- workspace objects
local ballsFolder = workspace:WaitForChild("Balls", 10)
local map = workspace:WaitForChild("Map", 10)
local objectives = map and map:WaitForChild("Objectives", 10)
local goldPart = objectives and objectives:WaitForChild("Gold", 10)

-- stop if gold part missing
if not goldPart then
	warn("Gold part missing")
	return
end

-- setup gold part
goldPart.CanCollide = false
goldPart.Anchored = true

-- config
local SPAWN_HEIGHT = 10
local DATA_VERSION = 2
local LOCK_TIME = 300
local AUTOSAVE = 120
local MAX_RETRIES = 3

-- caches
local playerData = {}
local lastTouch = {}
local sessionLocks = {}

-- PlayerData class using metatable (open source OOP pattern.)
-- metatable keeps methods out of saved data, DataStore only stores plain values
local PlayerData = {}
PlayerData.__index = PlayerData

function PlayerData.new(userId, base)
	setmetatable(base, PlayerData)
	base.UserId = userId
	return base
end

function PlayerData:AddGold(amount)
	self.Gold += amount
	self.TotalCollected += amount
end

function PlayerData:ToSave()
	return {
		Gold = self.Gold,
		TotalCollected = self.TotalCollected,
		LastLogin = os.time(),
		Version = DATA_VERSION,
		SessionStart = self.SessionStart,
	}
end

-- take session lock
-- UpdateAsync is atomic, prevents two servers from owning the same profile
local function acquireLock(userId)
	local key = "lock_"..userId
	local now = os.time()
	local ok, result = pcall(function()
		return mainStore:UpdateAsync(key, function(old)
			if not old or old < now then
				return now + LOCK_TIME
			end
			return nil
		end)
	end)
	if ok and result and result > now then
		sessionLocks[userId] = true
		return true
	end
	return false
end

-- release session lock
local function releaseLock(userId)
	if not sessionLocks[userId] then return end
	pcall(function() mainStore:RemoveAsync("lock_"..userId) end)
	sessionLocks[userId] = nil
end

-- refresh session lock
-- extends lock during long play sessions
local function refreshLock(userId)
	pcall(function()
		mainStore:UpdateAsync("lock_"..userId, function(old)
			if old then return os.time() + LOCK_TIME end
			return nil
		end)
	end)
end

-- load data from datastore
-- retries handle temporary Roblox datastore outages
local function getData(userId)
	local key = "data_"..userId
	for i = 1, MAX_RETRIES do
		local ok, data = pcall(function() return mainStore:GetAsync(key) end)
		if ok then return data end
		task.wait(0.5)
	end
	return nil
end

-- save data to datastore
local function saveData(userId, data)
	local key = "data_"..userId
	-- save main
	for i = 1, MAX_RETRIES do
		local ok = pcall(function() mainStore:SetAsync(key, data) end)
		if ok then break end
		task.wait(0.5)
	end
	-- save backup
	pcall(function() backupStore:SetAsync(key, data) end)
end

-- default data for new player
local function defaultData()
	return {
		Gold = 0,
		TotalCollected = 0,
		LastLogin = os.time(),
		Version = DATA_VERSION,
		SessionStart = os.time(),
	}
end

-- migrate old data format
-- ensures older saves get missing fields without wiping progress
local function migrate(old)
	if type(old) ~= "table" then old = {} end
	old.Gold = old.Gold or 0
	old.TotalCollected = old.TotalCollected or old.Gold
	old.LastLogin = os.time()
	old.SessionStart = old.SessionStart or os.time()
	old.Version = DATA_VERSION
	return old
end

-- create leaderstats
local function makeLeaderstats(player, data)
	-- create folder
	local ls = Instance.new("Folder")
	ls.Name = "leaderstats"
	ls.Parent = player
	-- gold value
	local g = Instance.new("IntValue")
	g.Name = "Gold"
	g.Value = data.Gold
	g.Parent = ls
	-- total value
	local t = Instance.new("IntValue")
	t.Name = "Total"
	t.Value = data.TotalCollected
	t.Parent = ls
end

-- load player
local function loadPlayer(player)
	-- run in background
	task.spawn(function()
		local userId = player.UserId
		-- take lock
		if not acquireLock(userId) then
			player:Kick("Data open elsewhere")
			return
		end
		-- load data
		local raw = getData(userId)
		-- use saved or default
		local base = raw and migrate(raw) or defaultData()
		local data = PlayerData.new(userId, base)
		-- cache
		playerData[userId] = data
		-- setup stats
		makeLeaderstats(player, data)
		-- send gold to client
		updateGold:FireClient(player, data.Gold)
	end)
end

-- save player
local function savePlayer(player, leaving)
	local userId = player.UserId
	local data = playerData[userId]
	if not data then return end
	-- write data
	saveData(userId, data:ToSave())
	if leaving then
		-- cleanup
		releaseLock(userId)
		playerData[userId] = nil
		lastTouch[userId] = nil
	else
		-- keep lock alive
		refreshLock(userId)
	end
end

-- player added
Players.PlayerAdded:Connect(loadPlayer)

-- player removing
Players.PlayerRemoving:Connect(function(p) savePlayer(p, true) end)

-- autosave loop
-- background saves reduce loss if server crashes
task.spawn(function()
	while true do
		task.wait(AUTOSAVE)
		for _, plr in ipairs(Players:GetPlayers()) do
			task.spawn(savePlayer, plr, false)
		end
	end
end)

-- gold touch
-- validates ball, checks distance/speed, awards gold, respawns with CFrame math
goldPart.Touched:Connect(function(hit)
	-- must be basepart
	if not hit or not hit:IsA("BasePart") then return end
	-- must be in balls folder
	if not ballsFolder or not hit:IsDescendantOf(ballsFolder) then return end
	-- get player from ball name
	local player = Players:FindFirstChild(hit.Name)
	if not player then return end
	local userId = player.UserId
	local data = playerData[userId]
	if not data then return end
	-- debounce 1 second
	local now = os.clock()
	if lastTouch[userId] and now - lastTouch[userId] < 1 then return end
	-- distance check
	if (hit.Position - goldPart.Position).Magnitude > 35 then return end
	-- speed check
	if hit.AssemblyLinearVelocity.Magnitude > 350 then return end
	-- anchored check
	if hit.Anchored then return end
	-- update last touch
	lastTouch[userId] = now
	-- add gold using metatable method
	data:AddGold(10)
	-- update leaderstats
	local ls = player:FindFirstChild("leaderstats")
	if ls then
		ls.Gold.Value = data.Gold
		ls.Total.Value = data.TotalCollected
	end
	-- update client
	updateGold:FireClient(player, data.Gold)
	-- reset ball with CFrame math and physics
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp then
		-- stop motion
		hit.AssemblyLinearVelocity = Vector3.zero
		hit.AssemblyAngularVelocity = Vector3.zero
		-- build spawn CFrame facing gold
		local spawnPos = hrp.Position + Vector3.new(0, SPAWN_HEIGHT, 0)
		local lookAt = Vector3.new(goldPart.Position.X, spawnPos.Y, goldPart.Position.Z)
		local targetCFrame = CFrame.lookAt(spawnPos, lookAt)
		hit:PivotTo(targetCFrame)
		-- small physics nudge to show control
		hit:ApplyImpulse(Vector3.new(0, 5, 0))
	end
end)

-- shutdown
-- BindToClose guarantees final save when server closes
game:BindToClose(function()
	-- save all players
	for _, plr in ipairs(Players:GetPlayers()) do
		savePlayer(plr, true)
	end
end)
