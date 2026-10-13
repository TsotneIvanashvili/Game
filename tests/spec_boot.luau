-- Boot + play-simulation test: runs the REAL server and client bootstraps (src/) inside the
-- headless Roblox emulation in tests/mock, then drives scripted play through the real remotes.
-- Catches what compile/lint/unit tests can't: nil indexing, calls to members that don't exist,
-- wrong argument shapes, misuse of emulated Roblox APIs, broken cross-service flows.
--
-- Any Lua runtime error in any thread (server or client), and any warn() that is not in
-- ALLOWED_WARNINGS, fails the step it happened in. Run: tests/run.sh (or luaurun this file ROOT).

local Mock = __loadfile(ROOT .. "/tests/mock/init.luau")()
local realStart = os.clock()
local rt = Mock.new(ROOT)
rt.latency = 0.05 -- 50 ms each way for remotes, like a decent connection
local Enum = rt.Enum
local typeof = rt.typeof -- Roblox type names for mock datatypes
local v3 = rt.v3
local CFrame = rt.types.CFrame

-- warn() lines the game may legitimately print during this scripted run. Keep this short and
-- explain each entry: everything else is treated as a failure.
local ALLOWED_WARNINGS = {}

-- Reporting ------------------------------------------------------------------------------------
local passed, failed = 0, 0
local failures = {}
local errorCursor, logCursor = 0, 0

local function problemsSinceLastCheck(stepAllowed: { string }?): { string }
	local out = {}
	for i = errorCursor + 1, #rt.errors do
		local e = rt.errors[i]
		table.insert(out, string.format("runtime error in %s:\n%s", e.ctx and e.ctx.name or "?", e.traceback))
	end
	errorCursor = #rt.errors
	for i = logCursor + 1, #rt.logs do
		local l = rt.logs[i]
		if l.kind == "warn" then
			local allowed = false
			for _, list in { ALLOWED_WARNINGS, stepAllowed or {} } do
				for _, pattern in list do
					if string.find(l.msg, pattern) then
						allowed = true
					end
				end
			end
			if not allowed then
				table.insert(out, string.format("unexpected warn [%s @%.2f]: %s", l.ctx, l.t, l.msg))
			end
		end
	end
	logCursor = #rt.logs
	return out
end

-- `allowed`: extra warn() patterns this step expects (e.g. a simulated outage).
local function step(name: string, fn: () -> (), allowed: { string }?)
	local ok, err = xpcall(fn, function(e)
		return rt.cleanTrace(debug.traceback(tostring(e), 2))
	end)
	local problems = problemsSinceLastCheck(allowed)
	if ok and #problems == 0 then
		passed += 1
		print("  ok    " .. name)
		return true
	end
	failed += 1
	if not ok then
		table.insert(problems, 1, "step failed: " .. tostring(err))
	end
	for _, trace in rt.moduleTraces do
		table.insert(problems, "module load error (" .. trace.ctx .. " " .. trace.module .. "):\n" .. trace.traceback)
	end
	table.clear(rt.moduleTraces)
	table.insert(failures, name .. "\n      " .. table.concat(problems, "\n      "))
	print("  FAIL  " .. name)
	for _, p in problems do
		print("        " .. string.gsub(p, "\n", "\n        "))
	end
	return false
end

local function check(cond: any, msg: string)
	if not cond then
		error(msg, 2)
	end
end

local function printLines(prefix: string)
	for _, l in rt.logs do
		if l.kind == "print" and string.sub(l.msg, 1, #prefix) == prefix then
			print("        " .. l.msg)
		end
	end
end

local function findLog(pattern: string, ctxName: string?): string?
	for _, l in rt.logs do
		if (ctxName == nil or l.ctx == ctxName) and string.find(l.msg, pattern) then
			return l.msg
		end
	end
	return nil
end

-- Context helpers --------------------------------------------------------------------------------
local game = rt.game
local sss = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function server(fn: () -> any, timeout: number?): any
	return rt.call(rt.serverCtx, fn, timeout)
end
local function client(player, fn: () -> any, timeout: number?): any
	return rt.call(rt.clientOf(player), fn, timeout)
end
local function serverModule(...: string): any
	local path = { ... }
	return server(function()
		local node = sss.Server
		for _, name in path do
			node = node:WaitForChild(name)
		end
		return rt.require(node)
	end)
end
local function sharedModule(...: string): any
	local path = { ... }
	return server(function()
		local node = ReplicatedStorage:WaitForChild("Shared")
		for _, name in path do
			node = node:WaitForChild(name)
		end
		return rt.require(node)
	end)
end
local function remote(player, name: string): any
	return client(player, function()
		local Remotes = rt.require(ReplicatedStorage.Shared.Net.Remotes)
		return Remotes.get(name)
	end)
end
local function attr(player, name: string): any
	return server(function()
		return player:GetAttribute(name)
	end)
end
local function rootOf(player)
	local character = player._p.Character
	return character and rt.findChild(character, "HumanoidRootPart")
end
local function rootPos(player)
	return rt.raw(rootOf(player), "CFrame").Position
end
local function runUntil(pred: () -> boolean, timeout: number, what: string)
	if not rt.runUntil(pred, timeout) then
		error("timed out after " .. timeout .. "s waiting for " .. what, 2)
	end
end

-- (a) server boot ------------------------------------------------------------------------------------
print("== boot")
local alice, bob
local TerrainModel, WorldLayout, terrainModel
step("mock self-check: datatype math and engine rules", function()
	server(function()
		local T = rt.types
		local function near(a: number, b: number, what: string)
			check(math.abs(a - b) < 1e-6, string.format("%s: %g vs %g", what, a, b))
		end
		local V3, CF = T.Vector3, T.CFrame
		local frame = CF.new(3, -2, 7) * CF.Angles(0.3, -1.1, 0.7)
		local x, y, z = CF.Angles(0.3, -1.1, 0.7):ToEulerAnglesXYZ()
		near(x, 0.3, "ToEulerAnglesXYZ x")
		near(y, -1.1, "ToEulerAnglesXYZ y")
		near(z, 0.7, "ToEulerAnglesXYZ z")
		check((frame * frame:Inverse()):FuzzyEq(CF.identity, 1e-9), "cf * cf:Inverse() ~= identity")
		local v = V3.new(1, 2, 3)
		check(frame:PointToObjectSpace(frame * v):FuzzyEq(v, 1e-9), "PointToObjectSpace round trip")
		check(frame:VectorToObjectSpace(frame:VectorToWorldSpace(v)):FuzzyEq(v, 1e-9), "VectorToWorldSpace round trip")
		local look = CF.lookAt(V3.new(0, 0, 0), V3.new(3, 4, 0)).LookVector
		check(look:FuzzyEq(V3.new(0.6, 0.8, 0), 1e-9), "lookAt LookVector")
		local o = CF.fromOrientation(0.2, 0.5, -0.4)
		local ox, oy, oz = o:ToOrientation()
		near(ox, 0.2, "ToOrientation x")
		near(oy, 0.5, "ToOrientation y")
		near(oz, -0.4, "ToOrientation z")
		check(V3.xAxis:Cross(V3.yAxis) == V3.zAxis, "x cross y ~= z")
		local h, sat, val = T.Color3.fromHSV(0.3, 0.6, 0.9):ToHSV()
		near(h, 0.3, "HSV h")
		near(sat, 0.6, "HSV s")
		near(val, 0.9, "HSV v")
		check(typeof(V3.zero) == "Vector3" and typeof(frame) == "CFrame", "typeof datatypes")
		check(Enum.Material.Snow == Enum.Material.Snow and Enum.Material.Snow ~= Enum.Material.Ice, "enum identity")
		check(not pcall(function()
			return (Enum.Material :: any).Snwo
		end), "unknown Enum.Material item did not error")
		local part = rt.Instance.new("Part")
		check(not pcall(function()
			(part :: any).Sizee = V3.one
		end), "unknown property write did not error")
		check(not pcall(function()
			part.Size = 5 :: any
		end), "wrong property type did not error")
		check(not pcall(function()
			part:SetAttribute("T", {})
		end), "table attribute did not error")
		part.Anchored = true
		part.Size = V3.new(10, 2, 10)
		part.CFrame = CF.new(5000, 100, 5000)
		part.Parent = rt.workspace
		check(not pcall(function()
			part:SetNetworkOwner(nil)
		end), "SetNetworkOwner on an anchored part did not error")
		local hit = rt.workspace:Raycast(V3.new(5001, 120, 5001), V3.new(0, -50, 0))
		check(hit and hit.Instance == part and hit.Normal:FuzzyEq(V3.yAxis, 1e-9), "raycast missed the part top")
		near(hit.Position.Y, 101, "raycast hit height")
		local model = rt.Instance.new("Model")
		part.Parent = model
		model.PrimaryPart = part
		model.Parent = rt.workspace
		model:PivotTo(CF.new(6000, 50, 6000))
		check(part.Position == V3.new(6000, 50, 6000), "PivotTo did not move the primary part")
		model:Destroy()
		check(not pcall(function()
			part.Parent = rt.workspace
		end), "reparenting a destroyed part did not error")
	end)
end)

step("inject terrain surface from Shared/Logic/TerrainModel", function()
	TerrainModel = sharedModule("Logic", "TerrainModel")
	WorldLayout = sharedModule("Config", "WorldLayout")
	terrainModel = TerrainModel.new(WorldLayout)
	-- Rays that hit a cliff face report the voxel material inside it (the ice body), not the
	-- snow on top, exactly as the voxels WorldBuilder writes.
	local function materialAt(x: number, y: number, z: number): string
		return terrainModel.voxelMaterial(x, y, z)
	end
	rt.setTerrainSurface(terrainModel.heightAt, terrainModel.normalAt, materialAt)
end)

step("server bootstrap builds the world and starts every service", function()
	-- Alice is already connected while the world builds (spawns must wait for it).
	alice = rt.addPlayer("Alice", 1001)
	rt.bootServer()
	runUntil(function()
		return findLog("^%[Report%]") ~= nil
	end, 10, "[Report] line")
	printLines("[World]")
	printLines("[Server]")
	printLines("[Report]")
	check(findLog("^%[World%] terrain ok"), "world terrain not ok: " .. tostring(findLog("^%[World%]")))
	check(findLog("^%[Server%] 15 services started"), "not every service started")
	local report = findLog("^%[Report%]") :: string
	for _, field in
		{
			"camps",
			"checkpoint rings",
			"sleep spots",
			"supply crates",
			"outfitters",
			"wood",
			"water",
			"hazards",
			"summit",
			"world parts",
		}
	do
		local n = tonumber(string.match(report, field .. " (%d+)"))
		check(n and n > 0, "[Report] " .. field .. " is " .. tostring(n))
	end
end)

-- (b) two players join, clients run the real client bootstrap -----------------------------------------
print("== join")
step("second player joins after boot; 60 virtual seconds pass", function()
	rt.run(1)
	bob = rt.addPlayer("Bob", 1002)
	rt.run(60)
end)

-- Clicks the first visible TextButton whose text is `text` in the player's ScreenGui `guiName`.
local function clickButton(player, guiName: string, text: string)
	local button = client(player, function()
		local gui = player.PlayerGui:WaitForChild(guiName, 5)
		for _, d in gui:GetDescendants() do
			if d:IsA("TextButton") and d.Text == text then
				return d
			end
		end
		return nil
	end)
	check(button, guiName .. " has no '" .. text .. "' button")
	rt.click(button)
	rt.run(0.3)
end

step("both clients dismiss the title screen (PLAY) and the HUD runs", function()
	for _, p in { alice, bob } do
		clickButton(p, "Title", "PLAY")
		check(not client(p, function()
			return p.PlayerGui.Title.Enabled
		end), p.Name .. " title screen still up after PLAY")
	end
	rt.run(2)
	client(alice, function()
		local texts = {}
		for _, d in alice.PlayerGui.HUD:GetDescendants() do
			if d:IsA("TextLabel") then
				texts[d.Text] = true
			end
		end
		local elevation = math.floor(alice:GetAttribute("ElevationM") or 0)
		local found = false
		for text in texts do
			if string.find(text, "^[%d,]+ m$") and text ~= "0 m" then
				found = true
			end
		end
		check(found or elevation == 0, "HUD altitude never left its default")
	end)
end)

step("characters spawned in the world", function()
	for _, p in { alice, bob } do
		local root = rootOf(p)
		check(root, p.Name .. " has no character/HumanoidRootPart")
		check(root:IsDescendantOf(rt.workspace), p.Name .. " character not in Workspace")
		local h = p._p.Character:FindFirstChildOfClass("Humanoid")
		check(rt.raw(h, "Health") > 0, p.Name .. " is dead")
		local pos = rootPos(p)
		local ground = terrainModel.heightAt(pos.X, pos.Z)
		check(
			math.abs(pos.Y - ground) < 30,
			string.format("%s floating/fallen: y %.1f ground %.1f", p.Name, pos.Y, ground)
		)
	end
end)

step("gear built for both players", function()
	printLines("[Equipment]")
	for _, p in { alice, bob } do
		local line = findLog("^%[Equipment%] " .. p.Name .. ": gear built")
		check(line, "no [Equipment] line for " .. p.Name)
		local n = tonumber(string.match(line :: string, "%((%d+) parts%)"))
		check(n and n > 0, "gear has no parts for " .. p.Name)
	end
end)

step("HUD ScreenGuis exist in each client's PlayerGui", function()
	for _, p in { alice, bob } do
		client(p, function()
			local gui = p:WaitForChild("PlayerGui")
			for _, name in { "HUD", "Notifications", "Hotbar", "Backpack", "BuildBook" } do
				local sg = gui:FindFirstChild(name)
				check(sg and sg:IsA("ScreenGui"), p.Name .. " missing ScreenGui " .. name)
			end
		end)
		-- The server must not see client-created UI.
		server(function()
			check(p.PlayerGui:FindFirstChild("HUD") == nil, "server can see a client-only ScreenGui")
		end)
	end
end)

step("survival attributes are published", function()
	for _, p in { alice, bob } do
		for _, name in
			{
				"Stamina",
				"MaxStamina",
				"Warmth",
				"TempC",
				"Hunger",
				"Thirst",
				"Oxygen",
				"ElevationM",
				"Exertion",
				"Zone",
				"Weather",
			}
		do
			local v = attr(p, name)
			check(v ~= nil, p.Name .. " attribute " .. name .. " missing")
		end
		-- Clients read the same values.
		client(p, function()
			check(typeof(p:GetAttribute("Stamina")) == "number", "client can't read Stamina")
		end)
	end
end)

-- (c) scripted play through the real remotes ---------------------------------------------------------
print("== play")
local Registry = serverModule("Registry")
local PlayerStore = serverModule("PlayerStore")

local function teleport(player, position)
	server(function()
		local record = PlayerStore.get(player)
		player.Character:PivotTo(CFrame.new(position))
		if record then
			PlayerStore.teleported(record)
		end
	end)
	rt.run(0.3)
end
local function standAt(x: number, z: number)
	return v3(x, terrainModel.heightAt(x, z) + 3, z)
end
-- An open patch of terrain near `near` (nothing built on it) where two players can stand.
local function clearSpot(near)
	local params = rt.types.RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { alice._p.Character, bob._p.Character }
	for radius = 0, 60, 6 do
		for i = 0, 7 do
			local a = i / 8 * math.pi * 2
			local x, z = near.X + math.cos(a) * radius, near.Z + math.sin(a) * radius
			local ok = true
			for _, dx in { 0, 2.5 } do
				local hit = rt.raycast(v3(x + dx, terrainModel.heightAt(x + dx, z) + 20, z), v3(0, -40, 0), params)
				if not hit or hit.Instance ~= rt.terrain or terrainModel.slopeAt(x + dx, z) > 15 then
					ok = false
				end
			end
			if ok then
				return x, z
			end
		end
	end
	error("no clear spot near " .. tostring(near))
end
local function pairUp()
	local x, z = clearSpot(rootPos(alice))
	teleport(alice, standAt(x, z))
	teleport(bob, standAt(x + 2.5, z))
end

local function stackOf(player, itemId: string)
	local snap = client(player, function()
		return remote(player, "GetSnapshot"):InvokeServer()
	end)
	for _, s in snap.stacks do
		if s.itemId == itemId then
			return s, snap
		end
	end
	return nil, snap
end

step("inventory: Tab opens the pack, GetSnapshot returns the starter pack", function()
	rt.input(rt.clientOf(alice), Enum.KeyCode.Tab, true)
	rt.input(rt.clientOf(alice), Enum.KeyCode.Tab, false)
	rt.run(0.5)
	local bar, snap = stackOf(alice, "energy_bar")
	check(typeof(snap) == "table" and typeof(snap.stacks) == "table", "snapshot has no stacks")
	check(bar and bar.qty >= 1, "starter energy bars missing")
	check(typeof(bar.uid) == "string", "stack uid is not a string")
	rt.input(rt.clientOf(alice), Enum.KeyCode.Tab, true)
	rt.input(rt.clientOf(alice), Enum.KeyCode.Tab, false)
	rt.run(0.3)
end)

step("use an energy bar through the Inventory remote", function()
	server(function()
		PlayerStore.get(alice).survival.hunger = 40
	end)
	local bar = stackOf(alice, "energy_bar")
	local before = bar.qty
	local ok, msg = client(alice, function()
		return remote(alice, "Inventory"):InvokeServer("Use", bar.uid)
	end)
	check(ok == true, "Use failed: " .. tostring(msg))
	local after = stackOf(alice, "energy_bar")
	check((after and after.qty or 0) == before - 1, "energy bar not consumed")
	check(server(function()
		return PlayerStore.get(alice).survival.hunger
	end) > 40, "hunger did not improve")
end)

step("GearToggle hides the helmet (H opens the gear menu)", function()
	rt.input(rt.clientOf(alice), Enum.KeyCode.H, true)
	rt.input(rt.clientOf(alice), Enum.KeyCode.H, false)
	rt.run(0.3)
	client(alice, function()
		remote(alice, "GearToggle"):FireServer("Helmet", false)
	end)
	rt.run(1)
	check(attr(alice, "GearHelmet") == false, "GearHelmet still shown")
	client(alice, function()
		remote(alice, "GearToggle"):FireServer("Helmet", true)
	end)
	rt.run(1)
	check(attr(alice, "GearHelmet") == true, "GearHelmet not restored")
	rt.input(rt.clientOf(alice), Enum.KeyCode.H, true)
	rt.input(rt.clientOf(alice), Enum.KeyCode.H, false)
end)

step("sprint: holding Shift while moving makes the server exertion 'sprint'", function()
	local ctx = rt.clientOf(alice)
	ctx.moveVector = v3(0, 0, -1)
	rt.input(ctx, Enum.KeyCode.LeftShift, true)
	runUntil(function()
		return attr(alice, "Exertion") == "sprint"
	end, 5, "Exertion == sprint")
	rt.input(ctx, Enum.KeyCode.LeftShift, false)
	ctx.moveVector = nil
	rt.run(1)
	runUntil(function()
		return attr(alice, "Exertion") ~= "sprint"
	end, 5, "sprint to end")
end)

step("build a campfire with the Build remote at a valid nearby spot", function()
	local BuildingService = Registry.get("BuildingService")
	local RecipeDefs = sharedModule("Config", "RecipeDefs")
	local recipe = RecipeDefs.ById.campfire
	server(function()
		check(Registry.get("InventoryService").add(alice, "wood", 3) == 3, "could not give wood")
	end)
	-- Pick a spot the server would accept (search a ring around the player).
	local target
	server(function()
		local pos = rootPos(alice)
		for radius = 5, 12, 3 do
			for i = 0, 11 do
				local a = i / 12 * math.pi * 2
				local p = pos + v3(math.cos(a) * radius, 0, math.sin(a) * radius)
				local frame = BuildingService.validatePlacement(alice, recipe, CFrame.new(p))
				if frame and not target then
					target = CFrame.new(p)
				end
			end
		end
	end)
	check(target, "no valid campfire spot near the player")
	local ok, msg = client(alice, function()
		return remote(alice, "Build"):InvokeServer("campfire", target)
	end, 15)
	check(ok == true, "Build failed: " .. tostring(msg))
	check((stackOf(alice, "wood")) == nil, "wood not consumed")
	check(#rt.workspace.Structures:GetChildren() >= 1, "no structure spawned")
	rt.run(2)
	check(attr(alice, "NearFire") == true, "standing next to the new fire doesn't count as near fire")
end)

local function campByIndex(index: number)
	return server(function()
		for _, camp in game:GetService("CollectionService"):GetTagged("Camp") do
			if camp:GetAttribute("Index") == index then
				return camp
			end
		end
		return nil
	end)
end

step("checkpoint: stepping into a camp's CheckpointRing signs it", function()
	local base = campByIndex(1)
	local ring = base:FindFirstChild("CheckpointRing", true)
	check(ring, "Base Camp has no CheckpointRing")
	teleport(alice, rt.raw(ring, "CFrame").Position + v3(0, 3, 0))
	rt.run(1.5)
	check(attr(alice, "Checkpoint") == 1, "Base Camp ring changed the checkpoint")
	local camp1 = campByIndex(2)
	local ring1 = camp1:FindFirstChild("CheckpointRing", true)
	check(ring1, "Camp 1 has no CheckpointRing")
	teleport(alice, rt.raw(ring1, "CFrame").Position + v3(0, 3, 0))
	runUntil(function()
		return attr(alice, "Checkpoint") == 2
	end, 3, "Checkpoint == 2")
	check(attr(alice, "CheckpointName") == "Camp 1", "CheckpointName not Camp 1")
	-- Back to base camp next to Bob.
	local b = rootPos(bob)
	teleport(alice, standAt(b.X + 3, b.Z))
end)

local function downPlayer(player)
	local SurvivalService = Registry.get("SurvivalService")
	for _ = 1, 20 do
		if attr(player, "Downed") == true then
			break
		end
		server(function()
			SurvivalService.changeHealth(player, -35, "test damage")
		end)
		rt.run(0.2)
	end
	check(attr(player, "Downed") == true, player.Name .. " never went down")
end
local function prompt(player, name: string)
	return server(function()
		return rootOf(player):FindFirstChild(name, true)
	end)
end

step("damage until downed, then the second player revives", function()
	pairUp()
	downPlayer(alice)
	local revive = prompt(alice, "RevivePrompt")
	check(revive and revive:IsA("ProximityPrompt"), "no RevivePrompt on the downed player")
	local ok, reason = client(bob, function()
		return rt.triggerPrompt(revive, bob)
	end, 10)
	check(ok, "could not trigger revive: " .. tostring(reason))
	rt.run(0.5)
	check(attr(alice, "Downed") == false, "still downed after revive")
	local h = alice._p.Character:FindFirstChildOfClass("Humanoid")
	check(rt.raw(h, "Health") > 1, "revived with no health")
end)

step("carry a downed teammate; they move with the carrier", function()
	pairUp()
	downPlayer(alice)
	local carry = prompt(alice, "CarryPrompt")
	check(carry, "no CarryPrompt")
	local ok, reason = client(bob, function()
		return rt.triggerPrompt(carry, bob)
	end, 10)
	check(ok, "could not trigger carry: " .. tostring(reason))
	rt.run(0.5)
	check(attr(bob, "Carrying") == "Alice", "Bob is not carrying Alice")
	check(attr(alice, "CarriedBy") == "Bob", "Alice not CarriedBy Bob")
	local ctx = rt.clientOf(bob)
	ctx.moveVector = v3(1, 0, 0)
	rt.run(2)
	ctx.moveVector = nil
	rt.run(0.3)
	local gap = (rootPos(alice) - rootPos(bob)).Magnitude
	check(gap < 4, string.format("carried player left behind (%.1f studs)", gap))
end)

step("give up while carried: evacuated to camp, pack left on the mountain", function()
	local oldCharacter = alice._p.Character
	client(alice, function()
		remote(alice, "GiveUp"):FireServer()
	end)
	runUntil(function()
		return alice._p.Character ~= oldCharacter and alice._p.Character ~= nil
	end, 5, "Alice to respawn")
	rt.run(1)
	check(attr(alice, "Downed") == false, "still downed after evacuation")
	check(attr(bob, "Carrying") == nil, "Bob still carrying after evacuation")
	check(attr(alice, "CarriedBy") == nil, "Alice still CarriedBy after evacuation")
	local packs = 0
	server(function()
		for _, d in rt.workspace:GetDescendants() do
			if d.Name == "Pack" or (d:IsA("Model") and string.find(d.Name, "Pack")) then
				packs += 1
			end
		end
	end)
	check(packs > 0, "no dropped pack in the world")
	-- Respawned at the last signed camp (Camp 1).
	local camp1 = campByIndex(2)
	local d = (rootPos(alice) - camp1:GetPivot().Position).Magnitude
	check(d < 80, string.format("evacuated %.0f studs from Camp 1", d))
end)

step("walk the route to the summit; ExpeditionSummary arrives", function()
	local summary
	client(alice, function()
		remote(alice, "ExpeditionSummary").OnClientEvent:Connect(function(stats)
			summary = stats
		end)
	end)
	local points = {}
	for _, s in TerrainModel.segments(WorldLayout) do
		if s.route == "Main" then
			local dx, dz = s.bx - s.ax, s.bz - s.az
			local n = math.max(1, math.ceil(math.sqrt(dx * dx + dz * dz) / 40))
			for k = 0, n do
				table.insert(points, { x = s.ax + dx * k / n, z = s.az + dz * k / n })
			end
		end
	end
	check(#points > 2, "no route points")
	-- Players walk through each camp they pass, which signs it via its CheckpointRing.
	local rings = {}
	for index = 2, #WorldLayout.Camps do
		local ring = campByIndex(index):FindFirstChild("CheckpointRing", true)
		if ring then
			rings[index] = ring
		end
	end
	for _, p in points do
		teleport(alice, standAt(p.x, p.z))
		for index, ring in rings do
			local at = rt.raw(ring, "CFrame").Position
			if (v3(at.X, 0, at.Z) - v3(p.x, 0, p.z)).Magnitude < 80 then
				rings[index] = nil
				teleport(alice, at + v3(0, 3, 0))
				rt.run(1.2)
				teleport(alice, standAt(p.x, p.z))
			end
		end
		if summary then
			break
		end
	end
	runUntil(function()
		return summary ~= nil
	end, 5, "ExpeditionSummary")
	check(summary.sectionComplete == true, "summary does not mark the section complete")
	check(typeof(summary.maxElevationM) == "number" and summary.maxElevationM > 0, "summary has no elevation")
	check(attr(alice, "Checkpoint") >= 3, "route walk did not sign Camp 2")
end)

-- (c, continued) the other systems a play session touches -----------------------------------------------
print("== more systems")
local function tagged(tag: string): { any }
	return server(function()
		return game:GetService("CollectionService"):GetTagged(tag)
	end)
end
local function promptIn(inst, actionText: string)
	return server(function()
		for _, d in inst:GetDescendants() do
			if d:IsA("ProximityPrompt") and d.ActionText == actionText then
				return d
			end
		end
		return nil
	end)
end
local function promptPosition(p)
	return server(function()
		return if p.Parent:IsA("Attachment") then p.Parent.WorldPosition else p.Parent.Position
	end)
end
-- Teleports `player` next to a prompt and holds it. Returns the trigger result.
local function usePrompt(player, p)
	check(p, "prompt missing")
	local at = promptPosition(p)
	teleport(player, at + v3(1.5, 0, 0))
	local ok, reason = client(player, function()
		return rt.triggerPrompt(p, player)
	end, 15)
	check(ok, "could not trigger '" .. p.ActionText .. "': " .. tostring(reason))
	rt.run(0.5)
end
local function invoke(player, remoteName: string, ...)
	local args = table.pack(...)
	return client(player, function()
		return remote(player, remoteName):InvokeServer(table.unpack(args, 1, args.n))
	end, 15)
end
local function count(player, itemId: string): number
	local _, snap = stackOf(player, itemId)
	local n = 0
	for _, st in snap.stacks do
		if st.itemId == itemId then
			n += st.qty
		end
	end
	return n
end
local function buildRecipe(player, recipeId: string)
	local RecipeDefs = sharedModule("Config", "RecipeDefs")
	local recipe = RecipeDefs.ById[recipeId]
	local BuildingService = Registry.get("BuildingService")
	local x, z = clearSpot(rootPos(player))
	teleport(player, standAt(x, z))
	local target
	server(function()
		local pos = rootPos(player)
		for radius = 6, 13, 3.5 do
			for i = 0, 15 do
				local a = i / 16 * math.pi * 2
				local p = pos + v3(math.cos(a) * radius, 0, math.sin(a) * radius)
				if not target and BuildingService.validatePlacement(player, recipe, CFrame.new(p)) then
					target = CFrame.new(p)
				end
			end
		end
	end)
	check(target, "no valid spot for " .. recipeId)
	local ok, msg = invoke(player, "Build", recipeId, target)
	check(ok == true, recipeId .. " build failed: " .. tostring(msg))
end

step("outfitter panel: switch to a large pack and take a tent", function()
	local rack = tagged("Outfitter")[1]
	check(rack, "no outfitter")
	usePrompt(alice, promptIn(rack, "Change gear"))
	check(
		client(alice, function()
			local panels = alice.PlayerGui:FindFirstChild("Panels")
			return panels and panels.Enabled
		end),
		"outfitter panel did not open on the client"
	)
	local ok, msg = invoke(alice, "Outfit", "pack_large")
	check(ok == true, "Outfit pack_large: " .. tostring(msg))
	ok, msg = invoke(alice, "Outfit", "tent_pack")
	check(ok == true, "Outfit tent_pack: " .. tostring(msg))
	ok = invoke(alice, "Outfit", "tent_pack")
	check(ok == false, "outfitter handed out a second tent")
	ok, msg = invoke(alice, "Outfit", "insulated_parka")
	check(ok == true, "Outfit insulated_parka: " .. tostring(msg))
end)

step("supply crate panel: take rations and a first aid kit", function()
	local crate
	for _, c in tagged("SupplyCrate") do
		if c:GetAttribute("CrateId") == "BaseCamp" then
			crate = c
		end
	end
	check(crate, "no BaseCamp supply crate")
	usePrompt(alice, promptIn(crate, "Open supply crate"))
	for _, itemId in { "first_aid_kit", "bandage", "canned_stew" } do
		local ok, msg = invoke(alice, "Supply", "BaseCamp", itemId)
		check(ok == true, "Supply " .. itemId .. ": " .. tostring(msg))
	end
end)

step("gather wood and water at their sources", function()
	local before = count(alice, "wood")
	local wood = tagged("WoodSource")[1]
	usePrompt(alice, promptIn(wood, "Gather wood"))
	check(count(alice, "wood") > before, "gathering gave no wood")
	local water
	for _, w in tagged("WaterSource") do
		water = water or promptIn(w, "Fill bottles")
	end
	check(water, "no water source with a Fill prompt")
	usePrompt(alice, water)
end)

step("build a tent and a wind wall; sleep in the tent; moving gets you up", function()
	buildRecipe(alice, "tent")
	server(function()
		Registry.get("InventoryService").add(alice, "wood", 5)
	end)
	buildRecipe(alice, "wind_wall")
	local tent
	for _, m in rt.workspace.Structures:GetChildren() do
		if promptIn(m, "Sleep in tent") then
			tent = m
		end
	end
	check(tent, "no tent structure")
	usePrompt(alice, promptIn(tent, "Sleep in tent"))
	check(attr(alice, "Resting") == true, "not resting after Sleep")
	local ctx = rt.clientOf(alice)
	ctx.moveVector = v3(1, 0, 0)
	rt.run(1.5)
	ctx.moveVector = nil
	rt.run(0.5)
	check(attr(alice, "Resting") == false, "still resting after walking away")
	usePrompt(alice, promptIn(tent, "Pack up tent"))
	check(count(alice, "tent_pack") == 1, "tent not packed back up")
end)

step("drop an item and pick it back up; give and treat a teammate", function()
	pairUp()
	local stew = stackOf(alice, "canned_stew")
	check(stew, "no canned stew to drop")
	local ok, msg = invoke(alice, "Inventory", "Drop", stew.uid, 1)
	check(ok == true, "Drop: " .. tostring(msg))
	rt.run(0.5)
	local dropped
	server(function()
		for _, d in rt.workspace:GetDescendants() do
			if d:IsA("ProximityPrompt") and d.ActionText == "Pick up" and string.find(d.ObjectText, "Stew") then
				dropped = d
			end
		end
	end)
	check(dropped, "dropped stew has no Pick up prompt")
	usePrompt(alice, dropped)
	check(stackOf(alice, "canned_stew"), "stew not picked back up")
	pairUp()
	local bar = stackOf(alice, "energy_bar")
	ok, msg = invoke(alice, "Inventory", "Give", bar.uid, bob.UserId)
	check(ok == true, "Give: " .. tostring(msg))
	server(function()
		Registry.get("SurvivalService").addInjury(bob, "Bleeding")
	end)
	local bandage = stackOf(alice, "bandage")
	ok, msg = invoke(alice, "Inventory", "Treat", bandage.uid, bob.UserId)
	check(ok == true, "Treat: " .. tostring(msg))
end)

step("ping: G marks the spot under the cursor for the team", function()
	local seen
	client(bob, function()
		remote(bob, "PingBroadcast").OnClientEvent:Connect(function(_, fromName)
			seen = fromName
		end)
	end)
	rt.input(rt.clientOf(alice), Enum.KeyCode.G, true)
	rt.input(rt.clientOf(alice), Enum.KeyCode.G, false)
	runUntil(function()
		return seen ~= nil
	end, 3, "PingBroadcast on Bob's client")
	check(seen == "Alice", "ping from the wrong player")
end)

step("climb: C at a rock wall starts a climb the server accepts; W climbs", function()
	-- A ladder segment ends at a cliff; stand at its foot facing the wall.
	local spot
	for _, sg in TerrainModel.segments(WorldLayout) do
		if sg.via == "Ladder" and not spot then
			spot = sg
		end
	end
	check(spot, "no cliff (ladder segment) in the layout")
	local dir = v3(spot.bx - spot.ax, 0, spot.bz - spot.az).Unit
	-- Beside the ladder (the ladder itself is a TrussPart, which the climbing system leaves to
	-- the engine), walk toward the wall until the terrain rises steeply in front.
	local side = v3(-dir.Z, 0, dir.X)
	local foot = v3(spot.ax, 0, spot.az) + side * 8
	for d = 0, 60, 0.5 do
		local p = foot + dir * d
		local ahead = p + dir * 2.5
		if terrainModel.heightAt(ahead.X, ahead.Z) - terrainModel.heightAt(p.X, p.Z) > 4 then
			foot = p
			break
		end
	end
	local stand = standAt(foot.X, foot.Z)
	server(function()
		alice.Character:PivotTo(CFrame.lookAt(stand, stand + dir))
		PlayerStore.teleported(PlayerStore.get(alice))
	end)
	rt.run(0.5)
	-- The wall is glacier ice: take the ice axe in hand first.
	if not stackOf(alice, "ice_axe") then -- her pack was left on the mountain when evacuated
		server(function()
			Registry.get("InventoryService").add(alice, "ice_axe", 1)
		end)
	end
	local axe = stackOf(alice, "ice_axe")
	check(axe, "no ice axe")
	local ok, msg = invoke(alice, "Inventory", "Hold", axe.uid)
	check(ok == true, "Hold ice axe: " .. tostring(msg))
	rt.run(0.5)
	check(attr(alice, "HeldItem") == "ice_axe", "HeldItem is not the ice axe")
	local ctx = rt.clientOf(alice)
	rt.input(ctx, Enum.KeyCode.C, true)
	rt.input(ctx, Enum.KeyCode.C, false)
	runUntil(function()
		return attr(alice, "Climbing") == true
	end, 3, "server Climbing attribute")
	local y0 = rootPos(alice).Y
	ctx.moveVector = v3(0, 0, -1)
	rt.input(ctx, Enum.KeyCode.W, true)
	rt.run(1.5)
	rt.input(ctx, Enum.KeyCode.W, false)
	ctx.moveVector = nil
	check(rootPos(alice).Y > y0 + 1, string.format("did not climb (y %.1f -> %.1f)", y0, rootPos(alice).Y))
	rt.input(ctx, Enum.KeyCode.C, true)
	rt.input(ctx, Enum.KeyCode.C, false)
	runUntil(function()
		return attr(alice, "Climbing") == false
	end, 5, "climb to stop")
end)

step("fall damage: a long drop hurts", function()
	local x, z = clearSpot(rootPos(alice))
	local h = alice._p.Character:FindFirstChildOfClass("Humanoid")
	server(function()
		h.Health = h.MaxHealth
	end)
	teleport(alice, standAt(x, z) + v3(0, 30, 0))
	rt.run(3)
	check(rt.raw(h, "Health") < rt.raw(h, "MaxHealth"), "a 30-stud fall did no damage")
end)

step("rockfall: a forced rockfall in an occupied zone runs and cleans up", function()
	local DisasterService = Registry.get("DisasterService")
	local zone = tagged("RockfallZone")[1]
	check(zone, "no rockfall zone")
	local c = rt.raw(zone, "CFrame").Position
	teleport(alice, standAt(c.X, c.Z))
	server(function()
		DisasterService.forceRockfall()
	end)
	rt.run(16)
	server(function()
		for _, d in rt.workspace:GetDescendants() do
			check(d.Name ~= "Boulder", "boulder left in the world after the rockfall")
		end
	end)
end)

step("storm: forcing a storm drives server weather and client effects", function()
	server(function()
		Registry.get("WeatherService").force("Storm", 2)
	end)
	local WeatherService = Registry.get("WeatherService")
	runUntil(function()
		return server(function()
			return WeatherService.currentId() == "Storm"
		end)
	end, 240, "weather to reach Storm")
	rt.run(5)
end)

step("death bypassing the downed state respawns at the last camp", function()
	local old = alice._p.Character
	server(function()
		old:FindFirstChildOfClass("Humanoid").Health = 0
	end)
	runUntil(function()
		return alice._p.Character ~= old and rootOf(alice) ~= nil
	end, 10, "respawn")
	rt.run(1)
	local camp = campByIndex(attr(alice, "Checkpoint"))
	local d = (rootPos(alice) - camp:GetPivot().Position).Magnitude
	check(d < 80, string.format("respawned %.0f studs from checkpoint camp", d))
end)

step("DataStore outage: a joining player retries, then plays read-only", function()
	rt.dataStoreFailure = "502: API Services rejected request with error. HTTP 503 (Service Unavailable)"
	local carol = rt.addPlayer("Carol", 1003)
	runUntil(function()
		return attr(carol, "Checkpoint") ~= nil
	end, 60, "Carol to be ready in read-only mode")
	rt.dataStoreFailure = nil
	check(
		server(function()
			return Registry.get("DataService").isReadOnly(carol)
		end),
		"profile not marked read-only after a DataStore outage"
	)
	rt.run(1)
	rt.removePlayer(carol)
	rt.run(1)
end, {
	-- DataService logs every failed attempt; those warnings are the point of this step.
	"^%[DataService%] load Carol failed",
})

-- (d) disconnect while carrying, rejoin -----------------------------------------------------------------
print("== disconnect / rejoin")
step("carrier disconnects mid-carry; the carried player is released", function()
	pairUp()
	downPlayer(alice)
	local ok, reason = client(bob, function()
		return rt.triggerPrompt(prompt(alice, "CarryPrompt"), bob)
	end, 10)
	check(ok, "could not trigger carry: " .. tostring(reason))
	rt.run(0.5)
	check(attr(bob, "Carrying") == "Alice", "Bob is not carrying Alice")
	server(function()
		check(Registry.get("InventoryService").add(bob, "rope", 1) == 1, "could not give Bob a rope")
	end)
	rt.removePlayer(bob)
	rt.run(1)
	check(attr(alice, "CarriedBy") == nil, "Alice still CarriedBy a departed player")
	server(function()
		check(rootOf(alice):FindFirstChild("CarryWeld", true) == nil, "carry weld left on Alice")
		local h = alice.Character:FindFirstChildOfClass("Humanoid")
		check(h.PlatformStand == false, "Alice left PlatformStand")
	end)
end)

step("rejoin within the grace window restores the expedition", function()
	bob = rt.addPlayer("Bob", 1002)
	runUntil(function()
		return attr(bob, "Checkpoint") ~= nil and rootOf(bob) ~= nil
	end, 15, "Bob to be ready again")
	rt.run(2)
	check(stackOf(bob, "rope"), "rejoined Bob lost his pack (the rope given before he left)")
	-- Alice is still down; Bob can revive her again.
	local a = rootPos(alice)
	teleport(bob, standAt(a.X + 2.5, a.Z))
	local ok, reason = client(bob, function()
		return rt.triggerPrompt(prompt(alice, "RevivePrompt"), bob)
	end, 10)
	check(ok, "could not trigger revive after rejoin: " .. tostring(reason))
	rt.run(0.5)
	check(attr(alice, "Downed") == false, "revive after rejoin failed")
end)

step("server shutdown saves profiles (BindToClose)", function()
	check(rt.shutdown(), "BindToClose callbacks did not finish")
	local store = rt.dataStores["PlayerData/global"]
	for _, ds in rt.dataStores do
		store = store or ds
	end
	check(store, "no DataStore was opened")
	local data = rawget(store, "_data")
	check(data["u_1001"] ~= nil, "Alice's profile was never saved")
end)

-- Summary -------------------------------------------------------------------------------------------------
if #rt.notes > 0 then
	print(string.format("== %d replication notes (lossy remote args / client-side reparenting):", #rt.notes))
	local seen = {}
	for _, n in rt.notes do
		if not seen[n] then
			seen[n] = true
			print("  - " .. n)
		end
	end
end
print(
	string.format(
		"\n%d passed, %d failed  (%.0f virtual s in %.1f s real)",
		passed,
		failed,
		rt.S.now,
		os.clock() - realStart
	)
)
for _, f in failures do
	print("  FAIL " .. f)
end
if failed > 0 then
	error("boot tests failed")
end
