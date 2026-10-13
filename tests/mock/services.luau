-- DataModel and services: game, Workspace, Players (with an R15-like character rig),
-- RunService, CollectionService, TweenService, DataStoreService, HttpService (JSON),
-- input services, ProximityPromptService, StarterGui, Lighting, Debris, Pathfinding, ...
-- Context-dependent members (Players.LocalPlayer, workspace.CurrentCamera, RunService:IsClient,
-- UserInputService state, ContextActionService bindings) read the running context.

return function(M)
	local S = M.S
	local task = M.task
	local T = M.types
	local Enum = M.Enum
	local N, RO, ANY, COMPUTED = M.N, M.RO, M.ANY, M.COMPUTED
	local class = M.class
	local raw, store = M.raw, M.store
	local v3 = M.v3
	local fmt = string.format
	local function noop() end
	local function c3(r, g, b)
		return T.Color3.fromRGB(r, g, b)
	end
	local function ctxOf()
		return S.current or M.serverCtx
	end
	local function serverOnly(method: string)
		if ctxOf().isClient then
			error(method .. " can only be called from the server", 3)
		end
	end
	local function clientOnly(method: string)
		if not ctxOf().isClient then
			error(method .. " can only be called from the client", 3)
		end
	end

	-- JSON (strict, used by HttpService and DataStores) -------------------------------------------
	local JSON = {}
	M.JSON = JSON
	local function encodeString(s: string): string
		return '"'
			.. string.gsub(s, '[%c"\\]', function(ch)
				local map = {
					['"'] = '\\"',
					["\\"] = "\\\\",
					["\n"] = "\\n",
					["\r"] = "\\r",
					["\t"] = "\\t",
					["\b"] = "\\b",
					["\f"] = "\\f",
				}
				return map[ch] or fmt("\\u%04x", string.byte(ch))
			end)
			.. '"'
	end
	function JSON.encode(value: any, context: string): string
		local seen = {}
		local function enc(v, path)
			local t = M.typeof(v)
			if t == "nil" then
				return "null"
			elseif t == "boolean" then
				return tostring(v)
			elseif t == "number" then
				if v ~= v or v == math.huge or v == -math.huge then
					error(fmt("%s: can't convert %s to JSON (at %s)", context, tostring(v), path), 0)
				end
				if v == math.floor(v) and math.abs(v) < 1e15 then
					return fmt("%d", v)
				end
				return fmt("%.17g", v)
			elseif t == "string" then
				return encodeString(v)
			elseif t == "table" then
				if seen[v] then
					error(fmt("%s: tables cannot be cyclic (at %s)", context, path), 0)
				end
				seen[v] = true
				local n = #v
				local count = 0
				local hasString, hasOther = false, false
				for k in v do
					count += 1
					if type(k) == "string" then
						hasString = true
					elseif not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
						hasOther = true
					end
				end
				local out
				if count == n and not hasString then
					local items = {}
					for i = 1, n do
						items[i] = enc(v[i], path .. "[" .. i .. "]")
					end
					out = "[" .. table.concat(items, ",") .. "]"
				else
					if hasOther or (n > 0 and hasString) then
						error(
							fmt("%s: can't convert mixed or non-string-keyed table to JSON (at %s)", context, path),
							0
						)
					end
					local keys = {}
					for k in v do
						table.insert(keys, k)
					end
					table.sort(keys)
					local items = {}
					for _, k in keys do
						table.insert(items, encodeString(k) .. ":" .. enc(v[k], path .. "." .. k))
					end
					out = "{" .. table.concat(items, ",") .. "}"
				end
				seen[v] = nil
				return out
			end
			error(fmt("%s: can't convert %s to JSON (at %s)", context, t, path), 0)
			return ""
		end
		return enc(value, "root")
	end
	function JSON.decode(s: string): any
		if type(s) ~= "string" then
			error("Can't parse JSON: string expected", 3)
		end
		local pos = 1
		local function fail(msg)
			error("Can't parse JSON: " .. msg .. " at " .. pos, 0)
		end
		local function ws()
			pos = string.find(s, "[^ \t\r\n]", pos) or #s + 1
		end
		local value
		local function str()
			pos += 1
			local out = {}
			while true do
				local ch = string.sub(s, pos, pos)
				if ch == "" then
					fail("unterminated string")
				elseif ch == '"' then
					pos += 1
					break
				elseif ch == "\\" then
					local e = string.sub(s, pos + 1, pos + 1)
					local map =
						{ n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
					if e == "u" then
						table.insert(out, utf8.char(tonumber(string.sub(s, pos + 2, pos + 5), 16) or 63))
						pos += 6
					else
						table.insert(out, map[e] or e)
						pos += 2
					end
				else
					table.insert(out, ch)
					pos += 1
				end
			end
			return table.concat(out)
		end
		function value()
			ws()
			local ch = string.sub(s, pos, pos)
			if ch == "{" then
				pos += 1
				local obj = {}
				ws()
				if string.sub(s, pos, pos) == "}" then
					pos += 1
					return obj
				end
				while true do
					ws()
					if string.sub(s, pos, pos) ~= '"' then
						fail("expected key")
					end
					local k = str()
					ws()
					if string.sub(s, pos, pos) ~= ":" then
						fail("expected ':'")
					end
					pos += 1
					obj[k] = value()
					ws()
					local d = string.sub(s, pos, pos)
					pos += 1
					if d == "}" then
						return obj
					elseif d ~= "," then
						fail("expected ',' or '}'")
					end
				end
			elseif ch == "[" then
				pos += 1
				local arr = {}
				ws()
				if string.sub(s, pos, pos) == "]" then
					pos += 1
					return arr
				end
				while true do
					table.insert(arr, value())
					ws()
					local d = string.sub(s, pos, pos)
					pos += 1
					if d == "]" then
						return arr
					elseif d ~= "," then
						fail("expected ',' or ']'")
					end
				end
			elseif ch == '"' then
				return str()
			elseif string.sub(s, pos, pos + 3) == "true" then
				pos += 4
				return true
			elseif string.sub(s, pos, pos + 4) == "false" then
				pos += 5
				return false
			elseif string.sub(s, pos, pos + 3) == "null" then
				pos += 4
				return nil
			end
			local numStr = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			if not numStr or numStr == "" then
				fail("unexpected character '" .. ch .. "'")
			end
			pos += #numStr
			return tonumber(numStr)
		end
		local result = value()
		ws()
		if pos <= #s then
			fail("trailing characters")
		end
		return result
	end

	-- Service base + DataModel -------------------------------------------------------------------
	class("ServiceProvider", "Instance", { abstract = true })
	local serviceClassOf: { [string]: string } = {}
	local function service(name: string, def: any)
		def = def or {}
		def.service = true
		class(name, def.parent or "Instance", def)
		serviceClassOf[name] = name
	end

	local function getService(self, name)
		if type(name) ~= "string" then
			error("Argument 1 missing or nil", 2)
		end
		local existing = rawget(self, "_services")[name]
		if existing then
			return existing
		end
		if not serviceClassOf[name] then
			error(fmt("'%s' is not a valid Service name", name), 2)
		end
		local inst = M.create(name, { shared = true })
		inst._p.Name = name
		rawget(self, "_services")[name] = inst
		M.setParent(inst, self)
		if M.onServiceCreated then
			M.onServiceCreated(name, inst)
		end
		return inst
	end

	class("DataModel", "ServiceProvider", {
		notCreatable = true,
		props = {
			JobId = RO(""),
			PlaceId = RO(0),
			GameId = RO(0),
			PlaceVersion = RO(0),
			CreatorId = RO(0),
			CreatorType = ANY(nil),
			PrivateServerId = RO(""),
			PrivateServerOwnerId = RO(0),
			Genre = ANY(nil),
			Workspace = COMPUTED(function()
				return M.workspace
			end),
		},
		methods = {
			GetService = getService,
			FindService = function(self, name)
				return rawget(self, "_services")[name]
			end,
			BindToClose = function(_, fn)
				serverOnly("BindToClose")
				if type(fn) ~= "function" then
					error("invalid argument #1 to 'BindToClose' (function expected)", 2)
				end
				table.insert(M.closeCallbacks, { fn = fn, ctx = ctxOf() })
			end,
			IsLoaded = function()
				return true
			end,
			GetJobsInfo = function()
				return {}
			end,
		},
		events = { "Loaded", "Close", "GraphicsQualityChangeRequest" },
	})
	M.closeCallbacks = {}

	-- Workspace ------------------------------------------------------------------------------------
	service("Workspace", {
		parent = "Model",
		props = {
			Gravity = 196.2,
			FallenPartsDestroyHeight = -500,
			CurrentCamera = {
				__spec = true,
				type = "Instance",
				nilable = true,
				class = "Camera",
				get = function()
					return ctxOf().camera
				end,
				set = function(_, v)
					ctxOf().camera = v
				end,
			},
			StreamingEnabled = false,
			StreamingMinRadius = 64,
			StreamingTargetRadius = 1024,
			StreamingIntegrityMode = ANY(nil),
			StreamingPauseMode = Enum.StreamingPauseMode.Default,
			StreamOutBehavior = ANY(nil),
			ModelStreamingBehavior = ANY(nil),
			DistributedGameTime = COMPUTED(function()
				return S.now
			end),
			Terrain = COMPUTED(function()
				return M.terrain
			end),
			SignalBehavior = Enum.SignalBehavior.Deferred,
			AirDensity = 0.0012,
			GlobalWind = v3(0, 0, 0),
			AllowThirdPartySales = false,
			ClientAnimatorThrottling = ANY(nil),
			InterpolationThrottling = ANY(nil),
			TouchesUseCollisionGroups = false,
			PhysicsSteppingMethod = ANY(nil),
			Retargeting = ANY(nil),
			MeshPartHeadsAndAccessories = ANY(nil),
			ReplicateInstanceDestroySetting = ANY(nil),
			RejectCharacterDeletions = ANY(nil),
		},
		methods = {
			Raycast = function(_, origin, direction, params)
				return M.raycast(origin, direction, params)
			end,
			Spherecast = function(_, origin, _radius, direction, params)
				return M.raycast(origin, direction, params) -- approximated by a ray
			end,
			Blockcast = function(_, frame, _size, direction, params)
				return M.raycast(frame.Position, direction, params) -- approximated by a ray
			end,
			Shapecast = function(_, part, direction, params)
				return M.raycast(raw(part, "CFrame").Position, direction, params)
			end,
			GetPartBoundsInBox = function(_, frame, size, params)
				return M.partBoundsInBox(frame, size, params)
			end,
			GetPartBoundsInRadius = function(_, pos, radius, params)
				return M.partBoundsInRadius(pos, radius, params)
			end,
			GetPartsInPart = function(_, part, params)
				return M.partsInPart(part, params)
			end,
			GetServerTimeNow = function()
				return M.wallClock()
			end,
			GetRealPhysicsFPS = function()
				return 60
			end,
			GetNumAwakeParts = function()
				return 0
			end,
			FindPartOnRay = function(_, ray, ignore)
				local params = T.RaycastParams.new()
				if ignore then
					params.FilterDescendantsInstances = { ignore }
				end
				local hit = M.raycast(ray.Origin, ray.Direction, params)
				if hit then
					return hit.Instance, hit.Position, hit.Normal, hit.Material
				end
				return nil, ray.Origin + ray.Direction, v3(0, 0, 0), Enum.Material.Air
			end,
			BulkMoveTo = function(_, parts, frames)
				for i, p in parts do
					p.CFrame = frames[i]
				end
			end,
			ArePartsTouchingOthers = function()
				return false
			end,
			JoinToOutsiders = noop,
			UnjoinFromOutsiders = noop,
			PGSIsEnabled = function()
				return true
			end,
		},
		events = { "PersistentLoaded" },
	})

	-- CollectionService ------------------------------------------------------------------------------
	local tagged: { [string]: { [any]: boolean } } = {}
	local tagSignals: { [string]: { added: any, removed: any } } = {}
	local function sigsFor(tag: string)
		local s = tagSignals[tag]
		if not s then
			s = { added = M.newSignal("InstanceAdded:" .. tag), removed = M.newSignal("InstanceRemoved:" .. tag) }
			tagSignals[tag] = s
		end
		return s
	end
	local function visFilter(inst)
		return function(ctx)
			return M.visibleTo(inst, ctx)
		end
	end
	function M.addTag(inst, tag)
		if type(tag) ~= "string" then
			error("invalid argument #2 to 'AddTag' (string expected, got " .. M.typeof(tag) .. ")", 3)
		end
		local tags = rawget(inst, "_tags")
		if not tags then
			tags = {}
			rawset(inst, "_tags", tags)
		end
		if tags[tag] then
			return
		end
		tags[tag] = true
		tagged[tag] = tagged[tag] or {}
		tagged[tag][inst] = true
		if rawget(inst, "_inGame") then
			M.fireFiltered(sigsFor(tag).added, visFilter(inst), inst)
		end
	end
	function M.removeTag(inst, tag)
		local tags = rawget(inst, "_tags")
		if not tags or not tags[tag] then
			return
		end
		tags[tag] = nil
		if tagged[tag] then
			tagged[tag][inst] = nil
		end
		if rawget(inst, "_inGame") then
			M.fireFiltered(sigsFor(tag).removed, visFilter(inst), inst)
		end
	end
	function M.clearTags(inst)
		local tags = rawget(inst, "_tags")
		if tags then
			for tag in tags do
				if tagged[tag] then
					tagged[tag][inst] = nil
				end
			end
		end
	end
	function M.tagMembershipChanged(inst, inGame)
		local tags = rawget(inst, "_tags")
		if not tags then
			return
		end
		for tag in tags do
			local s = sigsFor(tag)
			M.fireFiltered(if inGame then s.added else s.removed, visFilter(inst), inst)
		end
	end
	service("CollectionService", {
		methods = {
			AddTag = function(_, inst, tag)
				if not M.isInstance(inst) then
					error("invalid argument #1 to 'AddTag' (Instance expected, got " .. M.typeof(inst) .. ")", 2)
				end
				M.addTag(inst, tag)
			end,
			RemoveTag = function(_, inst, tag)
				M.removeTag(inst, tag)
			end,
			HasTag = function(_, inst, tag)
				if not M.isInstance(inst) then
					error("invalid argument #1 to 'HasTag' (Instance expected, got " .. M.typeof(inst) .. ")", 2)
				end
				local tags = rawget(inst, "_tags")
				return tags ~= nil and tags[tag] == true
			end,
			GetTagged = function(_, tag)
				if type(tag) ~= "string" then
					error("invalid argument #1 to 'GetTagged' (string expected, got " .. M.typeof(tag) .. ")", 2)
				end
				local out = {}
				local ctx = ctxOf()
				for inst in tagged[tag] or {} do
					if rawget(inst, "_inGame") and M.visibleTo(inst, ctx) then
						table.insert(out, inst)
					end
				end
				table.sort(out, function(a, b)
					return a._id < b._id
				end)
				return out
			end,
			GetTags = function(_, inst)
				return inst:GetTags()
			end,
			GetAllTags = function()
				local out = {}
				for tag in tagged do
					table.insert(out, tag)
				end
				return out
			end,
			GetInstanceAddedSignal = function(_, tag)
				if type(tag) ~= "string" then
					error("invalid argument #1 to 'GetInstanceAddedSignal' (string expected)", 2)
				end
				return sigsFor(tag).added
			end,
			GetInstanceRemovedSignal = function(_, tag)
				if type(tag) ~= "string" then
					error("invalid argument #1 to 'GetInstanceRemovedSignal' (string expected)", 2)
				end
				return sigsFor(tag).removed
			end,
		},
		events = { "TagAdded", "TagRemoved" },
	})

	-- RunService -------------------------------------------------------------------------------------
	service("RunService", {
		props = { ClientGitHash = RO("mock") },
		methods = {
			IsClient = function()
				return ctxOf().isClient == true
			end,
			IsServer = function()
				return ctxOf().isClient ~= true
			end,
			IsStudio = function()
				return M.isStudio == true
			end,
			IsRunning = function()
				return true
			end,
			IsRunMode = function()
				return false
			end,
			IsEdit = function()
				return false
			end,
			BindToRenderStep = function(_, name, priority, fn)
				clientOnly("BindToRenderStep")
				if type(name) ~= "string" or type(priority) ~= "number" or type(fn) ~= "function" then
					error("invalid arguments to 'BindToRenderStep' (string, number, function expected)", 2)
				end
				local ctx = ctxOf()
				ctx.renderSteps[name] = { priority = priority, fn = fn }
			end,
			UnbindFromRenderStep = function(_, name)
				clientOnly("UnbindFromRenderStep")
				ctxOf().renderSteps[name] = nil
			end,
			Pause = noop,
			Run = noop,
			Stop = noop,
		},
		events = {
			"Heartbeat",
			"Stepped",
			"RenderStepped",
			"PreRender",
			"PreSimulation",
			"PostSimulation",
			"PreAnimation",
		},
	})

	-- Players / Player / character rig ------------------------------------------------------------------
	service("Players", {
		props = {
			LocalPlayer = COMPUTED(function()
				return ctxOf().player
			end),
			CharacterAutoLoads = true,
			RespawnTime = 5,
			MaxPlayers = RO(12),
			PreferredPlayers = RO(8),
			BubbleChat = RO(true),
			ClassicChat = RO(false),
			UseStrafingAnimations = false,
		},
		methods = {
			GetPlayers = function(self)
				local out = {}
				for _, c in self:GetChildren() do
					if c._cls.name == "Player" then
						table.insert(out, c)
					end
				end
				return out
			end,
			GetPlayerByUserId = function(self, userId)
				if type(userId) ~= "number" then
					error(
						"invalid argument #1 to 'GetPlayerByUserId' (number expected, got " .. M.typeof(userId) .. ")",
						2
					)
				end
				for _, p in self:GetPlayers() do
					if raw(p, "UserId") == userId then
						return p
					end
				end
				return nil
			end,
			GetPlayerFromCharacter = function(_, character)
				return M.playerFromCharacter(character)
			end,
			GetUserIdFromNameAsync = function(self, name)
				for _, p in self:GetPlayers() do
					if p.Name == name then
						return raw(p, "UserId")
					end
				end
				error("HTTP 400 (Bad Request)", 2)
			end,
			GetNameFromUserIdAsync = function(self, id)
				local p = self:GetPlayerByUserId(id)
				if p then
					return p.Name
				end
				error("HTTP 400 (Bad Request)", 2)
			end,
			GetUserThumbnailAsync = function()
				return "rbxthumb://type=AvatarHeadShot&id=1&w=150&h=150", true
			end,
			GetHumanoidDescriptionFromUserId = function()
				return M.create("HumanoidDescription")
			end,
			CreateHumanoidModelFromDescription = function()
				return M.buildRig("Dummy")
			end,
			Chat = noop,
		},
		events = { "PlayerAdded", "PlayerRemoving", "PlayerMembershipChanged" },
	})

	function M.playerFromCharacter(character)
		if character == nil then
			return nil
		end
		for _, p in M.players:GetChildren() do
			if p._cls.name == "Player" and p._p.Character == character then
				return p
			end
		end
		return nil
	end

	class("Player", "Instance", {
		notCreatable = true,
		props = {
			UserId = RO(0),
			DisplayName = "",
			Character = {
				__spec = true,
				type = "Instance",
				nilable = true,
				class = "Model",
				set = function(self, v)
					M.store(self, "Character", v)
				end,
			},
			CharacterAppearanceId = 0,
			CanLoadCharacterAppearance = true,
			Team = N("Instance", "Team"),
			TeamColor = T.BrickColor.new("White"),
			Neutral = true,
			AccountAge = RO(365),
			MembershipType = RO(Enum.MembershipType.None),
			FollowUserId = RO(0),
			LocaleId = RO("en-us"),
			GameplayPaused = false,
			CameraMode = Enum.CameraMode.Classic,
			CameraMaxZoomDistance = 128,
			CameraMinZoomDistance = 0.5,
			DevComputerMovementMode = Enum.DevComputerMovementMode.UserChoice,
			DevTouchMovementMode = Enum.DevTouchMovementMode.UserChoice,
			DevEnableMouseLock = true,
			DevCameraOcclusionMode = ANY(nil),
			DevComputerCameraMode = ANY(nil),
			DevTouchCameraMode = ANY(nil),
			AutoJumpEnabled = true,
			HealthDisplayDistance = 100,
			NameDisplayDistance = 100,
			RespawnLocation = N("Instance", "SpawnLocation"),
			ReplicationFocus = N("Instance"),
			HasVerifiedBadge = RO(false),
		},
		methods = {
			LoadCharacter = function(self)
				serverOnly("LoadCharacter")
				if not rawget(self, "_parent") then
					error("LoadCharacter can only be called when Player is in the world", 2)
				end
				M.loadCharacter(self)
			end,
			LoadCharacterAsync = function(self)
				M.loadCharacter(self)
			end,
			Kick = function(self, message)
				M.log(ctxOf(), "info", fmt("[mock] %s kicked: %s", self.Name, tostring(message)))
				rawset(self, "_kicked", message or true)
				if ctxOf().isClient then
					-- a client may only kick its own player
					if ctxOf().player ~= self then
						error("Cannot kick a non-local Player from a LocalScript", 2)
					end
				end
				task.defer(function()
					M.removePlayer(self)
				end)
			end,
			GetMouse = function(self)
				clientOnly("GetMouse")
				local ctx = ctxOf()
				if not ctx.mouse then
					ctx.mouse = M.create("Mouse")
				end
				local _ = self
				return ctx.mouse
			end,
			HasAppearanceLoaded = function(self)
				return rawget(self, "_appearanceLoaded") == true
			end,
			IsFriendsWith = function()
				return false
			end,
			GetRankInGroup = function()
				return 0
			end,
			GetRoleInGroup = function()
				return "Guest"
			end,
			IsInGroup = function()
				return false
			end,
			GetFriendsOnline = function()
				return {}
			end,
			GetJoinData = function()
				return {}
			end,
			GetNetworkPing = function()
				return 0.05
			end,
			RequestStreamAroundAsync = function(_, pos, timeout)
				if M.typeof(pos) ~= "Vector3" then
					error(
						"invalid argument #1 to 'RequestStreamAroundAsync' (Vector3 expected, got "
							.. M.typeof(pos)
							.. ")",
						2
					)
				end
				if timeout ~= nil and type(timeout) ~= "number" then
					error("invalid argument #2 to 'RequestStreamAroundAsync' (number expected)", 2)
				end
				task.wait(0)
			end,
			ClearCharacterAppearance = noop,
			DistanceFromCharacter = function(self, point)
				local character = self._p.Character
				local root = character and M.findChild(character, "HumanoidRootPart")
				if not root then
					return 0
				end
				return (raw(root, "CFrame").Position - point).Magnitude
			end,
			SetSuperSafeChat = noop,
		},
		events = {
			"CharacterAdded",
			"CharacterRemoving",
			"CharacterAppearanceLoaded",
			"Chatted",
			"Idled",
			"OnTeleport",
		},
	})

	-- R15-like rig. Sizes match the classic blocky R15 avatar; HipHeight 2 matches the legs, so
	-- the HumanoidRootPart centre stands 3 studs above the ground.
	local RIG = {
		{ "HumanoidRootPart", nil, v3(2, 2, 1), v3(0, 0, 0) },
		{ "LowerTorso", "HumanoidRootPart", v3(2, 0.4, 1), v3(0, -0.8, 0) },
		{ "UpperTorso", "LowerTorso", v3(2, 1.6, 1), v3(0, 0.2, 0) },
		{ "Head", "UpperTorso", v3(2, 1, 1), v3(0, 1.5, 0) },
		{ "LeftUpperArm", "UpperTorso", v3(1, 1.2, 1), v3(-1.5, 0.4, 0) },
		{ "LeftLowerArm", "LeftUpperArm", v3(1, 1, 1), v3(-1.5, -0.7, 0) },
		{ "LeftHand", "LeftLowerArm", v3(1, 0.3, 1), v3(-1.5, -1.35, 0) },
		{ "RightUpperArm", "UpperTorso", v3(1, 1.2, 1), v3(1.5, 0.4, 0) },
		{ "RightLowerArm", "RightUpperArm", v3(1, 1, 1), v3(1.5, -0.7, 0) },
		{ "RightHand", "RightLowerArm", v3(1, 0.3, 1), v3(1.5, -1.35, 0) },
		{ "LeftUpperLeg", "LowerTorso", v3(1, 0.9, 1), v3(-0.5, -1.45, 0) },
		{ "LeftLowerLeg", "LeftUpperLeg", v3(1, 0.8, 1), v3(-0.5, -2.3, 0) },
		{ "LeftFoot", "LeftLowerLeg", v3(1, 0.3, 1), v3(-0.5, -2.85, 0) },
		{ "RightUpperLeg", "LowerTorso", v3(1, 0.9, 1), v3(0.5, -1.45, 0) },
		{ "RightLowerLeg", "RightUpperLeg", v3(1, 0.8, 1), v3(0.5, -2.3, 0) },
		{ "RightFoot", "RightLowerLeg", v3(1, 0.3, 1), v3(0.5, -2.85, 0) },
	}
	local JOINT_NAMES = {
		LowerTorso = "Root",
		UpperTorso = "Waist",
		Head = "Neck",
		LeftUpperArm = "LeftShoulder",
		LeftLowerArm = "LeftElbow",
		LeftHand = "LeftWrist",
		RightUpperArm = "RightShoulder",
		RightLowerArm = "RightElbow",
		RightHand = "RightWrist",
		LeftUpperLeg = "LeftHip",
		LeftLowerLeg = "LeftKnee",
		LeftFoot = "LeftAnkle",
		RightUpperLeg = "RightHip",
		RightLowerLeg = "RightKnee",
		RightFoot = "RightAnkle",
	}
	-- Accessory attachments: part, name, local offset.
	local ATTACH = {
		{ "Head", "HatAttachment", v3(0, 0.6, 0) },
		{ "Head", "HairAttachment", v3(0, 0.6, 0) },
		{ "Head", "FaceFrontAttachment", v3(0, 0, -0.6) },
		{ "Head", "FaceCenterAttachment", v3(0, 0, 0) },
		{ "UpperTorso", "NeckAttachment", v3(0, 0.8, 0) },
		{ "UpperTorso", "BodyFrontAttachment", v3(0, -0.2, -0.5) },
		{ "UpperTorso", "BodyBackAttachment", v3(0, -0.2, 0.5) },
		{ "UpperTorso", "LeftCollarAttachment", v3(-1, 0.8, 0) },
		{ "UpperTorso", "RightCollarAttachment", v3(1, 0.8, 0) },
		{ "LowerTorso", "WaistFrontAttachment", v3(0, -0.2, -0.5) },
		{ "LowerTorso", "WaistBackAttachment", v3(0, -0.2, 0.5) },
		{ "LowerTorso", "WaistCenterAttachment", v3(0, -0.2, 0) },
		{ "LeftUpperArm", "LeftShoulderAttachment", v3(0, 0.6, 0) },
		{ "RightUpperArm", "RightShoulderAttachment", v3(0, 0.6, 0) },
		{ "LeftHand", "LeftGripAttachment", v3(0, -0.15, 0) },
		{ "RightHand", "RightGripAttachment", v3(0, -0.15, 0) },
		{ "LeftFoot", "LeftFootAttachment", v3(0, -0.15, 0) },
		{ "RightFoot", "RightFootAttachment", v3(0, -0.15, 0) },
		{ "HumanoidRootPart", "RootAttachment", v3(0, 0, 0) },
	}

	function M.buildRig(name: string)
		local model = M.create("Model", { shared = true })
		model._p.Name = name
		local parts = {}
		for _, def in RIG do
			local partName, _, size, offset = def[1], def[2], def[3], def[4]
			local part = M.create(if partName == "Head" then "Part" else "Part", { shared = true })
			part._p.Name = partName
			part._p.Size = size
			part._p.CFrame = T.CFrame.new(offset)
			part._p.Color = if partName == "HumanoidRootPart" then c3(163, 162, 165) else c3(234, 184, 146)
			part._p.Material = Enum.Material.Plastic
			if partName == "HumanoidRootPart" then
				part._p.Transparency = 1
				part._p.CanCollide = false
			end
			if partName == "Head" then
				local mesh = M.create("SpecialMesh", { shared = true })
				mesh._p.MeshType = Enum.MeshType.Head
				mesh._p.Scale = v3(1.25, 1.25, 1.25)
				M.setParent(mesh, part)
				local face = M.create("Decal", { shared = true })
				face._p.Name = "face"
				face._p.Texture = "rbxasset://textures/face.png"
				M.setParent(face, part)
			end
			parts[partName] = part
			M.setParent(part, model)
		end
		for _, def in RIG do
			local partName, parentName = def[1], def[2]
			if parentName then
				local p0, p1 = parts[parentName], parts[partName]
				local joint = M.create("Motor6D", { shared = true })
				joint._p.Name = JOINT_NAMES[partName]
				local mid = (raw(p0, "CFrame").Position + raw(p1, "CFrame").Position) / 2
				joint._p.C0 = raw(p0, "CFrame"):Inverse() * T.CFrame.new(mid)
				joint._p.C1 = raw(p1, "CFrame"):Inverse() * T.CFrame.new(mid)
				joint.Part0 = p0
				joint.Part1 = p1
				M.setParent(joint, p1)
				local a0 = M.create("Attachment", { shared = true })
				a0._p.Name = JOINT_NAMES[partName] .. "RigAttachment"
				a0._p.CFrame = joint._p.C0
				M.setParent(a0, p0)
				local a1 = M.create("Attachment", { shared = true })
				a1._p.Name = JOINT_NAMES[partName] .. "RigAttachment"
				a1._p.CFrame = joint._p.C1
				M.setParent(a1, p1)
			end
		end
		for _, def in ATTACH do
			local a = M.create("Attachment", { shared = true })
			a._p.Name = def[2]
			a._p.CFrame = T.CFrame.new(def[3])
			M.setParent(a, parts[def[1]])
		end
		local humanoid = M.create("Humanoid", { shared = true })
		local animator = M.create("Animator", { shared = true })
		M.setParent(animator, humanoid)
		M.setParent(humanoid, model)
		model._p.PrimaryPart = parts.HumanoidRootPart
		-- Two accessories so hat/hair code paths have something to work on.
		for _, acc in
			{
				{ "Hair", Enum.AccessoryType.Hair, "HairAttachment" },
				{ "Hat", Enum.AccessoryType.Hat, "HatAttachment" },
			}
		do
			local accessory = M.create("Accessory", { shared = true })
			accessory._p.Name = acc[1] .. "Accessory"
			accessory._p.AccessoryType = acc[2]
			local handle = M.create("Part", { shared = true })
			handle._p.Name = "Handle"
			handle._p.Size = v3(1.6, 0.6, 1.4)
			handle._p.CanCollide = false
			handle._p.Massless = true
			handle._p.CFrame = raw(parts.Head, "CFrame") * T.CFrame.new(0, 0.7, 0)
			M.setParent(handle, accessory)
			local att = M.create("Attachment", { shared = true })
			att._p.Name = acc[3]
			M.setParent(att, handle)
			local weld = M.create("Weld", { shared = true })
			weld._p.Name = "AccessoryWeld"
			weld.Part0 = handle
			weld.Part1 = parts.Head
			M.setParent(weld, handle)
			M.setParent(accessory, model)
		end
		local colors = M.create("BodyColors", { shared = true })
		M.setParent(colors, model)
		return model, humanoid, parts.HumanoidRootPart
	end

	local spawnRng = T.Random.new(7)
	local function spawnCFrame(): any
		local candidates = {}
		for _, d in M.descendantsRaw(M.workspace, {}) do
			if d._cls.name == "SpawnLocation" and raw(d, "Enabled") then
				table.insert(candidates, d)
			end
		end
		if #candidates == 0 then
			return T.CFrame.new(0, 100, 0), nil
		end
		local spawn = candidates[spawnRng:NextInteger(1, #candidates)]
		local c = raw(spawn, "CFrame")
		local size = raw(spawn, "Size")
		-- Random point on the top face, like the engine.
		local ox = spawnRng:NextNumber(-1, 1) * math.max(size.X / 2 - 1.5, 0)
		local oz = spawnRng:NextNumber(-1, 1) * math.max(size.Z / 2 - 1.5, 0)
		return T.CFrame.new(c * v3(ox, size.Y / 2 + 3.1, oz)), spawn
	end

	function M.loadCharacter(player)
		local old = player._p.Character
		if old then
			M.fire(M.getEvent(player, "CharacterRemoving"), old)
			M.storeShared(player, "Character", nil)
			if not rawget(old, "_destroyed") then
				old:Destroy()
			end
		end
		-- ResetOnSpawn: ScreenGuis in PlayerGui that reset are destroyed, StarterGui re-copied.
		local gui = M.findChild(player, "PlayerGui")
		if gui then
			for _, c in table.clone(rawget(gui, "_children") or {}) do
				if c._cls.isa.LayerCollector and raw(c, "ResetOnSpawn") then
					c:Destroy()
				end
			end
			M.copyStarterGui(player)
		end
		local rig, humanoid = M.buildRig(player.Name)
		rawset(player, "_appearanceLoaded", false)
		local frame, spawn = spawnCFrame()
		local prev = S.current
		S.current = M.serverCtx
		local health = M.create("Script", { shared = true })
		health._p.Name = "Health"
		M.setParent(health, rig)
		humanoid._p.DisplayName = raw(player, "DisplayName")
		M.storeShared(player, "Character", rig)
		M.fire(M.getEvent(player, "CharacterAdded"), rig)
		rig.Parent = M.workspace
		rig:PivotTo(frame)
		if spawn and raw(spawn, "Duration") > 0 then
			local ff = M.create("ForceField", { shared = true })
			M.setParent(ff, rig)
			S.at(S.now + raw(spawn, "Duration"), function()
				if not rawget(ff, "_destroyed") then
					ff:Destroy()
				end
			end)
		end
		S.current = prev
		S.at(S.now + 0.1, function()
			if player._p.Character == rig then
				rawset(player, "_appearanceLoaded", true)
				M.fire(M.getEvent(player, "CharacterAppearanceLoaded"), rig)
			end
		end)
		local ctx = rawget(player, "_clientCtx")
		if ctx and ctx.camera then
			ctx.camera._p.CameraSubject = humanoid
		end
		return rig
	end

	function M.onHumanoidDied(h)
		local character = rawget(h, "_parent")
		local player = M.playerFromCharacter(character)
		if not player then
			return
		end
		S.at(S.now + raw(M.players, "RespawnTime"), function()
			if
				player._p.Character == character
				and rawget(player, "_parent")
				and raw(M.players, "CharacterAutoLoads")
			then
				local prev = S.current
				S.current = M.serverCtx
				M.loadCharacter(player)
				S.current = prev
			end
		end)
	end

	-- Team(s) ------------------------------------------------------------------------------------------
	service("Teams", {
		methods = {
			GetTeams = function(self)
				return self:GetChildren()
			end,
		},
	})

	-- Containers --------------------------------------------------------------------------------------
	service("ReplicatedStorage", {})
	service("ReplicatedFirst", {
		methods = {
			RemoveDefaultLoadingScreen = noop,
			IsFinishedReplicating = function()
				return true
			end,
		},
	})
	service("ServerScriptService", { props = { LoadStringEnabled = RO(false) } })
	service("ServerStorage", {})
	service("StarterPack", {})
	service("StarterPlayer", {
		props = {
			CharacterWalkSpeed = 16,
			CharacterJumpHeight = 7.2,
			CharacterJumpPower = 50,
			CharacterUseJumpPower = false,
			CharacterMaxSlopeAngle = 89,
			CameraMaxZoomDistance = 128,
			CameraMinZoomDistance = 0.5,
			CameraMode = Enum.CameraMode.Classic,
			AutoJumpEnabled = true,
			LoadCharacterAppearance = true,
			HealthDisplayDistance = 100,
			NameDisplayDistance = 100,
			EnableMouseLockOption = true,
			DevComputerMovementMode = Enum.DevComputerMovementMode.UserChoice,
			DevTouchMovementMode = Enum.DevTouchMovementMode.UserChoice,
		},
	})
	class("StarterPlayerScripts", "Instance", { notCreatable = true })
	class("StarterCharacterScripts", "Instance", { notCreatable = true })

	service("StarterGui", {
		props = {
			ShowDevelopmentGui = true,
			ResetPlayerGuiOnSpawn = true,
			ScreenOrientation = ANY(nil),
			VirtualCursorMode = ANY(nil),
		},
		methods = {
			SetCore = function(_, name, _value)
				clientOnly("SetCore")
				if type(name) ~= "string" then
					error("invalid argument #1 to 'SetCore' (string expected)", 2)
				end
			end,
			GetCore = function(_, name)
				clientOnly("GetCore")
				if type(name) ~= "string" then
					error("invalid argument #1 to 'GetCore' (string expected)", 2)
				end
				return nil
			end,
			SetCoreGuiEnabled = function(_, coreType, enabled)
				clientOnly("SetCoreGuiEnabled")
				if
					M.typeof(coreType) ~= "EnumItem"
					or coreType.EnumType ~= Enum.CoreGuiType
					or type(enabled) ~= "boolean"
				then
					error("invalid arguments to 'SetCoreGuiEnabled' (CoreGuiType, bool expected)", 2)
				end
				ctxOf().coreGui[coreType] = enabled
			end,
			GetCoreGuiEnabled = function(_, coreType)
				local v = ctxOf().coreGui and ctxOf().coreGui[coreType]
				return v ~= false
			end,
		},
	})
	function M.copyStarterGui(player)
		local gui = M.findChild(player, "PlayerGui")
		local sg = M.starterGui
		if not gui or not sg then
			return
		end
		for _, c in rawget(sg, "_children") or {} do
			if c._cls.isa.LayerCollector then
				local copy = c:Clone()
				M.setParent(copy, gui)
			end
		end
	end

	service("Lighting", {
		props = {
			ClockTime = {
				__spec = true,
				default = 14,
				type = "number",
				set = function(self, v)
					store(self, "ClockTime", v % 24)
					M.changed(self, "TimeOfDay", nil)
				end,
			},
			TimeOfDay = COMPUTED(function(self)
				local t = raw(self, "ClockTime")
				local h = math.floor(t)
				local m = math.floor((t - h) * 60)
				local s = math.floor(((t - h) * 60 - m) * 60)
				return fmt("%02d:%02d:%02d", h, m, s)
			end, function(self, v)
				local h, m, s = string.match(v, "^(%d+):?(%d*):?(%d*)$")
				self.ClockTime = (tonumber(h) or 0) + (tonumber(m) or 0) / 60 + (tonumber(s) or 0) / 3600
			end, "string"),
			Brightness = 2,
			Ambient = c3(70, 70, 70),
			OutdoorAmbient = c3(70, 70, 70),
			FogColor = c3(192, 192, 192),
			FogEnd = 100000,
			FogStart = 0,
			GlobalShadows = true,
			EnvironmentDiffuseScale = 0,
			EnvironmentSpecularScale = 0,
			ExposureCompensation = 0,
			GeographicLatitude = 41.733,
			ColorShift_Top = c3(0, 0, 0),
			ColorShift_Bottom = c3(0, 0, 0),
			ShadowSoftness = 0.2,
			Technology = Enum.Technology.ShadowMap,
			LightingStyle = ANY(nil),
			PrioritizeLightingQuality = ANY(nil),
		},
		methods = {
			GetMinutesAfterMidnight = function(self)
				return raw(self, "ClockTime") * 60
			end,
			SetMinutesAfterMidnight = function(self, minutes)
				self.ClockTime = minutes / 60
			end,
			GetSunDirection = function(self)
				local a = (raw(self, "ClockTime") - 6) / 12 * math.pi
				return v3(math.cos(a), math.sin(a), 0.3).Unit
			end,
			GetMoonDirection = function(self)
				local a = (raw(self, "ClockTime") - 18) / 12 * math.pi
				return v3(math.cos(a), math.sin(a), -0.3).Unit
			end,
		},
		events = { "LightingChanged" },
	})

	-- TweenService ------------------------------------------------------------------------------------
	local TWEENABLE = {
		number = true,
		boolean = true,
		Vector3 = true,
		Vector2 = true,
		CFrame = true,
		Color3 = true,
		UDim2 = true,
		UDim = true,
		Rect = true,
		NumberRange = true,
		EnumItem = false,
	}
	class("TweenBase", "Instance", {
		abstract = true,
		props = { PlaybackState = RO(Enum.PlaybackState.Begin) },
		methods = {
			Play = function(self)
				M.tweenPlay(self)
			end,
			Pause = function(self)
				rawset(self, "_active", false)
				M.storeShared(self, "PlaybackState", Enum.PlaybackState.Paused)
			end,
			Cancel = function(self)
				rawset(self, "_active", false)
				M.storeShared(self, "PlaybackState", Enum.PlaybackState.Cancelled)
				M.fire(M.getEvent(self, "Completed"), Enum.PlaybackState.Cancelled)
			end,
		},
		events = { "Completed" },
	})
	class("Tween", "TweenBase", {
		notCreatable = true,
		props = { Instance = RO(nil), TweenInfo = ANY(nil) },
	})
	local activeTweens: { [any]: boolean } = {}
	local function lerp(a, b, t)
		local ty = M.typeof(a)
		if ty == "number" then
			return a + (b - a) * t
		elseif ty == "boolean" then
			return if t >= 1 then b else a
		elseif ty == "UDim" then
			return T.UDim.new(a.Scale + (b.Scale - a.Scale) * t, a.Offset + (b.Offset - a.Offset) * t)
		elseif ty == "NumberRange" or ty == "Rect" then
			return if t >= 1 then b else a
		end
		return a:Lerp(b, t)
	end
	local function ease(info, t)
		local style = info.EasingStyle.Name
		local dir = info.EasingDirection.Name
		local function f(x)
			if style == "Linear" then
				return x
			elseif style == "Sine" then
				return 1 - math.cos(x * math.pi / 2)
			elseif style == "Back" then
				return x * x * (2.70158 * x - 1.70158)
			elseif style == "Quart" then
				return x ^ 4
			elseif style == "Quint" then
				return x ^ 5
			elseif style == "Exponential" then
				return if x == 0 then 0 else 2 ^ (10 * x - 10)
			elseif style == "Circular" then
				return 1 - math.sqrt(1 - x * x)
			elseif style == "Cubic" then
				return x ^ 3
			end
			return x * x
		end
		if dir == "In" then
			return f(t)
		elseif dir == "Out" then
			return 1 - f(1 - t)
		end
		return if t < 0.5 then f(t * 2) / 2 else 1 - f((1 - t) * 2) / 2
	end
	function M.tweenPlay(tween)
		if rawget(tween, "_active") then
			return
		end
		local target = tween._p.Instance
		local start = {}
		for k in rawget(tween, "_goals") do
			start[k] = target[k]
		end
		rawset(tween, "_start", start)
		rawset(tween, "_t0", S.now)
		rawset(tween, "_active", true)
		rawset(tween, "_ctx", ctxOf())
		M.storeShared(tween, "PlaybackState", Enum.PlaybackState.Playing)
		activeTweens[tween] = true
	end
	table.insert(S.frameHooks, function()
		for tween in table.clone(activeTweens) do
			if not rawget(tween, "_active") then
				activeTweens[tween] = nil
				continue
			end
			local info = tween._p.TweenInfo
			local target = tween._p.Instance
			local elapsed = S.now - rawget(tween, "_t0") - info.DelayTime
			if elapsed < 0 then
				continue
			end
			local duration = math.max(info.Time, 1e-6)
			local cycles = info.RepeatCount
			local cycleLen = duration * (if info.Reverses then 2 else 1)
			local cycle = math.floor(elapsed / cycleLen)
			local done = cycles >= 0 and cycle > cycles
			local local_ = if done then (if info.Reverses then 0 else duration) else elapsed - cycle * cycleLen
			local t
			if info.Reverses and local_ > duration then
				t = 1 - (local_ - duration) / duration
			else
				t = math.min(local_ / duration, 1)
			end
			if done then
				t = if info.Reverses then 0 else 1
			end
			local alpha = ease(info, t)
			local prev = S.current
			S.current = rawget(tween, "_ctx")
			if not rawget(target, "_destroyed") then
				for k, goal in rawget(tween, "_goals") do
					target[k] = if alpha >= 1 then goal else lerp(rawget(tween, "_start")[k], goal, alpha)
				end
			end
			S.current = prev
			if done then
				rawset(tween, "_active", false)
				activeTweens[tween] = nil
				M.storeShared(tween, "PlaybackState", Enum.PlaybackState.Completed)
				M.fire(M.getEvent(tween, "Completed"), Enum.PlaybackState.Completed)
			end
		end
	end)
	service("TweenService", {
		methods = {
			Create = function(_, inst, info, goals)
				if not M.isInstance(inst) then
					error("invalid argument #1 to 'Create' (Instance expected, got " .. M.typeof(inst) .. ")", 2)
				end
				if M.typeof(info) ~= "TweenInfo" then
					error("invalid argument #2 to 'Create' (TweenInfo expected, got " .. M.typeof(info) .. ")", 2)
				end
				if type(goals) ~= "table" or getmetatable(goals) ~= nil then
					error("invalid argument #3 to 'Create' (table expected, got " .. M.typeof(goals) .. ")", 2)
				end
				for k, v in goals do
					local spec = inst._cls.props[k]
					if not spec then
						error(
							fmt("TweenService:Create no property named '%s' for object '%s'", tostring(k), inst._p.Name),
							2
						)
					end
					local current = inst[k]
					local ct, vt = M.typeof(current), M.typeof(v)
					if not TWEENABLE[ct] then
						error(
							fmt(
								"TweenService:Create property named '%s' on object '%s' is not a data type that can be tweened",
								k,
								inst._p.Name
							),
							2
						)
					end
					if ct ~= vt then
						error(
							fmt(
								"TweenService:Create property named '%s' cannot be tweened due to type mismatch (property is a '%s', but given type is '%s')",
								k,
								ct,
								vt
							),
							2
						)
					end
				end
				local tween = M.create("Tween")
				tween._p.Instance = inst
				tween._p.TweenInfo = info
				rawset(tween, "_goals", table.clone(goals))
				return tween
			end,
			GetValue = function(_, alpha, style, direction)
				return ease({ EasingStyle = style, EasingDirection = direction }, alpha)
			end,
			SmoothDamp = function(_, _current, target, velocity)
				return target, velocity
			end,
		},
	})

	-- DataStoreService --------------------------------------------------------------------------------
	M.dataStores = {}
	M.dataStoreLatency = 0 -- virtual seconds each request yields
	M.dataStoreFailure = nil :: string?
	class("GlobalDataStore", "Instance", {
		notCreatable = true,
		methods = (function()
			local function request(self, op: string)
				serverOnly("DataStore:" .. op)
				task.wait(M.dataStoreLatency)
				if M.dataStoreFailure then
					error(M.dataStoreFailure, 3)
				end
				return rawget(self, "_data")
			end
			local function checkKey(key)
				if type(key) ~= "string" or #key == 0 or #key > 50 then
					error("invalid key: must be a non-empty string of at most 50 characters", 3)
				end
			end
			local function encode(value)
				local ok, result = pcall(JSON.encode, value, "DataStore value")
				if not ok then
					error("104: Cannot store value in data store: " .. tostring(result), 3)
				end
				if #result > 4194304 then
					error("105: Serialized value exceeds 4MB limit", 3)
				end
				return result
			end
			return {
				GetAsync = function(self, key)
					checkKey(key)
					local data = request(self, "GetAsync")
					local stored = data[key]
					if stored == nil then
						return nil, nil
					end
					return JSON.decode(stored), { Version = "1", CreatedTime = 0, UpdatedTime = 0 }
				end,
				SetAsync = function(self, key, value)
					checkKey(key)
					local data = request(self, "SetAsync")
					data[key] = encode(value)
					return "1"
				end,
				UpdateAsync = function(self, key, transform)
					checkKey(key)
					if type(transform) ~= "function" then
						error("invalid argument #2 to 'UpdateAsync' (function expected)", 2)
					end
					local data = request(self, "UpdateAsync")
					local stored = data[key]
					local old = if stored ~= nil then JSON.decode(stored) else nil
					-- The transform must not yield (the engine errors if it does).
					local co = coroutine.create(transform)
					local ok, result = coroutine.resume(co, old, { Version = "1" })
					if not ok then
						error(result, 2)
					end
					if coroutine.status(co) ~= "dead" then
						error("UpdateAsync transform function yielded; it must not yield", 2)
					end
					if result == nil then
						return nil
					end
					data[key] = encode(result)
					return JSON.decode(data[key])
				end,
				RemoveAsync = function(self, key)
					checkKey(key)
					local data = request(self, "RemoveAsync")
					local stored = data[key]
					data[key] = nil
					return if stored then JSON.decode(stored) else nil
				end,
				IncrementAsync = function(self, key, delta)
					checkKey(key)
					local data = request(self, "IncrementAsync")
					local value = (if data[key] then JSON.decode(data[key]) else 0) + (delta or 1)
					data[key] = encode(value)
					return value
				end,
			}
		end)(),
	})
	class("DataStore", "GlobalDataStore", { notCreatable = true })
	class("OrderedDataStore", "GlobalDataStore", {
		notCreatable = true,
		methods = {
			GetSortedAsync = function()
				error("mock: OrderedDataStore:GetSortedAsync is not emulated", 2)
			end,
		},
	})
	service("DataStoreService", {
		methods = {
			GetDataStore = function(_, name, scope)
				serverOnly("GetDataStore")
				if type(name) ~= "string" or #name == 0 or #name > 50 then
					error(
						"invalid argument #1 to 'GetDataStore' (non-empty string of at most 50 characters expected)",
						2
					)
				end
				local id = name .. "/" .. tostring(scope or "global")
				local ds = M.dataStores[id]
				if not ds then
					ds = M.create("DataStore", { shared = true })
					ds._p.Name = name
					rawset(ds, "_data", {})
					M.dataStores[id] = ds
				end
				return ds
			end,
			GetGlobalDataStore = function(self)
				return self:GetDataStore("global")
			end,
			GetOrderedDataStore = function(_, name)
				local ds = M.create("OrderedDataStore", { shared = true })
				ds._p.Name = name
				rawset(ds, "_data", {})
				return ds
			end,
			GetRequestBudgetForRequestType = function()
				return 100
			end,
		},
	})

	-- HttpService -----------------------------------------------------------------------------------
	local guidCounter = 0
	service("HttpService", {
		props = { HttpEnabled = false },
		methods = {
			JSONEncode = function(_, value)
				return JSON.encode(value, "JSONEncode")
			end,
			JSONDecode = function(_, s)
				return JSON.decode(s)
			end,
			GenerateGUID = function(_, wrap)
				guidCounter += 1
				local hex = fmt(
					"%08X-%04X-%04X-%04X-%012X",
					guidCounter,
					0x4000,
					0x8000,
					guidCounter % 65536,
					guidCounter * 7919
				)
				if wrap == false then
					return hex
				end
				return "{" .. hex .. "}"
			end,
			UrlEncode = function(_, s)
				return (string.gsub(s, "[^%w%-_%.~]", function(ch)
					return fmt("%%%02X", string.byte(ch))
				end))
			end,
			GetAsync = function()
				error("Http requests are not enabled. Enable via game settings", 2)
			end,
			PostAsync = function()
				error("Http requests are not enabled. Enable via game settings", 2)
			end,
			RequestAsync = function()
				error("Http requests are not enabled. Enable via game settings", 2)
			end,
		},
	})

	service("TextService", {
		methods = {
			GetTextSize = function(_, text, size, _font, _frame)
				if type(text) ~= "string" or type(size) ~= "number" then
					error("invalid arguments to 'GetTextSize' (string, number expected)", 2)
				end
				return T.Vector2.new(#text * size * 0.5, size)
			end,
			GetTextBoundsAsync = function(_, params)
				return T.Vector2.new(#(params.Text or "") * (params.Size or 14) * 0.5, params.Size or 14)
			end,
			FilterStringAsync = function(_, text)
				return {
					GetNonChatStringForBroadcastAsync = function()
						return text
					end,
				}
			end,
		},
	})

	-- Input --------------------------------------------------------------------------------------------
	class("InputObject", "Instance", {
		notCreatable = true,
		props = {
			KeyCode = Enum.KeyCode.Unknown,
			UserInputType = Enum.UserInputType.None,
			UserInputState = Enum.UserInputState.None,
			Position = v3(0, 0, 0),
			Delta = v3(0, 0, 0),
		},
		methods = {
			IsModifierKeyDown = function()
				return false
			end,
		},
	})
	service("UserInputService", {
		props = {
			TouchEnabled = RO(false),
			KeyboardEnabled = RO(true),
			MouseEnabled = RO(true),
			GamepadEnabled = RO(false),
			AccelerometerEnabled = RO(false),
			GyroscopeEnabled = RO(false),
			VREnabled = RO(false),
			MouseBehavior = Enum.MouseBehavior.Default,
			MouseIconEnabled = true,
			MouseIcon = "",
			MouseDeltaSensitivity = 1,
			ModalEnabled = false,
			OnScreenKeyboardVisible = RO(false),
		},
		methods = {
			IsKeyDown = function(_, key)
				if M.typeof(key) ~= "EnumItem" or key.EnumType ~= Enum.KeyCode then
					error("invalid argument #1 to 'IsKeyDown' (KeyCode expected, got " .. M.typeof(key) .. ")", 2)
				end
				local keys = ctxOf().keysDown
				return keys ~= nil and keys[key] == true
			end,
			IsMouseButtonPressed = function(_, button)
				local keys = ctxOf().keysDown
				return keys ~= nil and keys[button] == true
			end,
			GetKeysPressed = function()
				local out = {}
				for k in ctxOf().keysDown or {} do
					local io = M.create("InputObject")
					io._p.KeyCode = k
					table.insert(out, io)
				end
				return out
			end,
			GetMouseLocation = function()
				return T.Vector2.new(960, 540)
			end,
			GetMouseDelta = function()
				return T.Vector2.zero
			end,
			GetFocusedTextBox = function()
				return nil
			end,
			GetLastInputType = function()
				return Enum.UserInputType.Keyboard
			end,
			GetConnectedGamepads = function()
				return {}
			end,
			GetNavigationGamepads = function()
				return {}
			end,
			GetGamepadConnected = function()
				return false
			end,
			GetStringForKeyCode = function(_, key)
				return key.Name
			end,
			GetDeviceType = function()
				return nil
			end,
		},
		events = {
			"InputBegan",
			"InputEnded",
			"InputChanged",
			"JumpRequest",
			"WindowFocused",
			"WindowFocusReleased",
			"TouchStarted",
			"TouchEnded",
			"TouchMoved",
			"TouchTap",
			"LastInputTypeChanged",
			"TextBoxFocused",
			"TextBoxFocusReleased",
			"GamepadConnected",
			"GamepadDisconnected",
		},
	})
	service("ContextActionService", {
		methods = (function()
			local function bind(name, fn, touch, priority, inputs)
				if type(name) ~= "string" then
					error("invalid argument #1 to 'BindAction' (string expected)", 3)
				end
				if type(fn) ~= "function" then
					error("invalid argument #2 to 'BindAction' (function expected)", 3)
				end
				for i, input in inputs do
					if
						M.typeof(input) ~= "EnumItem"
						or (
							input.EnumType ~= Enum.KeyCode
							and input.EnumType ~= Enum.UserInputType
							and input.EnumType ~= Enum.PlayerActions
						)
					then
						error(
							fmt(
								"invalid argument #%d to 'BindAction' (KeyCode/UserInputType expected, got %s)",
								i + 3,
								M.typeof(input)
							),
							3
						)
					end
				end
				local ctx = ctxOf()
				ctx.actions[name] =
					{ fn = fn, touch = touch, priority = priority, inputs = inputs, order = S.frame + #inputs * 0 }
				ctx.actionSeq = (ctx.actionSeq or 0) + 1
				ctx.actions[name].seq = ctx.actionSeq
			end
			return {
				BindAction = function(_, name, fn, touch, ...)
					bind(name, fn, touch, 2000, { ... })
				end,
				BindActionAtPriority = function(_, name, fn, touch, priority, ...)
					if type(priority) ~= "number" then
						error("invalid argument #4 to 'BindActionAtPriority' (number expected)", 2)
					end
					bind(name, fn, touch, priority, { ... })
				end,
				UnbindAction = function(_, name)
					ctxOf().actions[name] = nil
				end,
				UnbindAllActions = function()
					table.clear(ctxOf().actions)
				end,
				GetBoundActionInfo = function(_, name)
					local a = ctxOf().actions[name]
					return if a
						then { priorityLevel = a.priority, inputTypes = a.inputs, createTouchButton = a.touch }
						else {}
				end,
				GetAllBoundActionInfo = function()
					local out = {}
					for name, a in ctxOf().actions do
						out[name] = { priorityLevel = a.priority, inputTypes = a.inputs }
					end
					return out
				end,
				SetTitle = function(_, name, title)
					if type(name) ~= "string" or type(title) ~= "string" then
						error("invalid arguments to 'SetTitle' (string, string expected)", 2)
					end
				end,
				SetImage = noop,
				SetDescription = noop,
				SetPosition = noop,
				GetButton = function()
					return nil
				end,
				BindActivate = noop,
				UnbindActivate = noop,
			}
		end)(),
		events = { "LocalToolEquipped", "LocalToolUnequipped" },
	})

	service("ProximityPromptService", {
		props = { Enabled = true, MaxPromptsVisible = 16, MaxIndicatorsVisible = 16 },
		events = {
			"PromptTriggered",
			"PromptTriggerEnded",
			"PromptShown",
			"PromptHidden",
			"PromptButtonHoldBegan",
			"PromptButtonHoldEnded",
		},
	})
	service("SoundService", {
		props = {
			AmbientReverb = ANY(nil),
			DistanceFactor = 3.33,
			DopplerScale = 1,
			RolloffScale = 1,
			RespectFilteringEnabled = true,
			VolumetricAudio = ANY(nil),
		},
		methods = {
			PlayLocalSound = function(_, sound)
				if not (M.isInstance(sound) and sound:IsA("Sound")) then
					error("invalid argument #1 to 'PlayLocalSound' (Sound expected)", 2)
				end
			end,
			SetListener = noop,
			GetListener = function()
				return nil
			end,
		},
	})
	service("Debris", {
		props = { MaxItems = 1000 },
		methods = {
			AddItem = function(_, inst, lifetime)
				if not M.isInstance(inst) then
					error("invalid argument #1 to 'AddItem' (Instance expected, got " .. M.typeof(inst) .. ")", 2)
				end
				S.at(S.now + (tonumber(lifetime) or 10), function()
					if not rawget(inst, "_destroyed") then
						local prev = S.current
						S.current = M.serverCtx
						inst:Destroy()
						S.current = prev
					end
				end)
			end,
		},
	})
	class("Path", "Instance", {
		notCreatable = true,
		props = { Status = RO(Enum.PathStatus.NoPath) },
		methods = {
			ComputeAsync = function(self, a, b)
				task.wait(0)
				rawset(self, "_points", { a, b })
				M.storeShared(self, "Status", Enum.PathStatus.Success)
			end,
			GetWaypoints = function(self)
				local out = {}
				for _, p in rawget(self, "_points") or {} do
					table.insert(out, { Position = p, Action = Enum.PathWaypointAction.Walk, Label = "" })
				end
				return out
			end,
			CheckOcclusionAsync = function()
				return -1
			end,
		},
		events = { "Blocked", "Unblocked" },
	})
	service("PathfindingService", {
		methods = {
			CreatePath = function()
				return M.create("Path")
			end,
		},
	})
	service("PhysicsService", {
		methods = {
			RegisterCollisionGroup = noop,
			CollisionGroupSetCollidable = noop,
			CollisionGroupsAreCollidable = function()
				return true
			end,
			IsCollisionGroupRegistered = function()
				return true
			end,
			GetRegisteredCollisionGroups = function()
				return {}
			end,
		},
	})
	service("MarketplaceService", {
		methods = {
			UserOwnsGamePassAsync = function()
				task.wait(0)
				return false
			end,
			PromptGamePassPurchase = noop,
			PromptProductPurchase = noop,
			GetProductInfo = function()
				return {}
			end,
		},
		events = { "PromptGamePassPurchaseFinished", "PromptProductPurchaseFinished" },
	})
	service("BadgeService", {
		methods = {
			AwardBadge = function()
				task.wait(0)
				return true
			end,
			UserHasBadgeAsync = function()
				return false
			end,
		},
	})
	service("TeleportService", { methods = { Teleport = noop, TeleportAsync = noop } })
	service("GuiService", {
		props = {
			MenuIsOpen = RO(false),
			AutoSelectGuiEnabled = true,
			SelectedObject = N("Instance"),
			TouchControlsEnabled = true,
		},
		methods = {
			GetGuiInset = function()
				return T.Vector2.new(0, 36), T.Vector2.zero
			end,
			IsTenFootInterface = function()
				return false
			end,
		},
		events = { "MenuOpened", "MenuClosed" },
	})
	service("LocalizationService", { props = { RobloxLocaleId = RO("en-us"), SystemLocaleId = RO("en-us") } })
	service("Chat", { props = { BubbleChatEnabled = false, LoadDefaultChat = true } })
	service("TextChatService", { props = { ChatVersion = ANY(nil) } })
	service(
		"HapticService",
		{ methods = {
			IsVibrationSupported = function()
				return false
			end,
			SetMotor = noop,
		} }
	)
	service("VRService", { props = { VREnabled = RO(false) } })
	service("Stats", { methods = {
		GetTotalMemoryUsageMb = function()
			return 0
		end,
	} })
	service("PolicyService", {
		methods = {
			GetPolicyInfoForPlayerAsync = function()
				return { AreAdsAllowed = false, ArePaidRandomItemsRestricted = false }
			end,
		},
	})
	service("MessagingService", {
		methods = {
			PublishAsync = noop,
			SubscribeAsync = function()
				return { Disconnect = noop }
			end,
		},
	})
	service("AssetService", {})
	service(
		"ContentProvider",
		{ props = { RequestQueueSize = RO(0) }, methods = {
			PreloadAsync = function()
				task.wait(0)
			end,
		} }
	)
	service("InsertService", {})
	service("SocialService", {})
	service("GroupService", {})
	service("UserService", {})
	service("AnalyticsService", {
		methods = {
			LogCustomEvent = noop,
			LogEconomyEvent = noop,
			LogProgressionEvent = noop,
			LogOnboardingFunnelStepEvent = noop,
		},
	})
end
