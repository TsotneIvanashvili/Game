-- Headless Roblox runtime for luaurun. Boots the real game code (src/) in a virtual-time
-- DataModel with one server context and any number of simulated clients.
--
--   local Mock = __loadfile(ROOT .. "/tests/mock/init.luau")()
--   local rt = Mock.new(ROOT)
--   rt.bootServer()                 -- runs ServerScriptService scripts (src/server/init.server.luau)
--   local p1 = rt.addPlayer("Alice") -- joins a player; its client runs src/client/init.client.luau
--   rt.run(10)                      -- advance 10 virtual seconds (30 Hz frames)
--   rt.call(rt.clientOf(p1), function() ... end) -- run code inside a context, waiting for it
--
-- Simplifications (details in the header comment of each tests/mock/*.luau file):
--   * One shared instance tree. Clients see server instances directly (no replication lag);
--     instances a client creates are owned by it and invisible to the server and other
--     clients; client writes to server-owned instances are per-client overlays (local-only),
--     except physics properties of the client's own character (network ownership).
--   * Physics is a kinematic humanoid controller + raycasts; loose parts don't simulate.
--   * Rendering, sound playback, animation playback and terrain voxels are not emulated.

local Mock = {}

local FILES = { "scheduler", "enum", "datatypes", "instance", "classes", "world", "services", "network", "loader" }

function Mock.new(root: string, options: any?)
	local opts = options or {}
	local M: any = { root = root, logs = {}, echo = opts.echo == true, clients = {} }
	M.epoch = 1767225600 -- fixed wall clock (2026-01-01) so runs are reproducible
	M.wallClock = function()
		return M.epoch + M.S.now
	end
	function M.log(ctx, kind: string, msg: string)
		local entry =
			{ t = if M.S then M.S.now else 0, ctx = if ctx then ctx.name else "server", kind = kind, msg = msg }
		table.insert(M.logs, entry)
		if M.echo or kind == "error" then
			print(
				string.format("[%7.2f %s] %s%s", entry.t, entry.ctx, if kind == "print" then "" else kind .. ": ", msg)
			)
		end
		if M.onLog then
			M.onLog(entry)
		end
	end
	function M.warnAs(ctx, msg: string)
		M.log(ctx, "warn", msg)
	end

	for _, name in FILES do
		local chunk = __loadfile(root .. "/tests/mock/" .. name .. ".luau")
		chunk()(M)
	end
	local S = M.S
	math.randomseed(opts.seed or 42)

	-- Contexts ------------------------------------------------------------------------------------
	local function newCtx(name: string, isClient: boolean, player: any?)
		local ctx = {
			name = name,
			isClient = isClient,
			isServer = not isClient,
			player = player,
			modules = {},
			actions = {},
			renderSteps = {},
			keysDown = {},
			coreGui = {},
			dead = false,
		}
		ctx.globals = M.makeGlobals(ctx)
		return ctx
	end
	M.serverCtx = newCtx("server", false)
	S.current = M.serverCtx

	-- Kill switch for a departed client's threads.
	local resume = S.resume
	S.resume = function(co, ctx, ...)
		local c = ctx or S.threadCtx[co]
		if c and c.dead then
			return
		end
		return resume(co, ctx, ...)
	end

	-- DataModel ------------------------------------------------------------------------------------
	local game = M.create("DataModel", { shared = true })
	rawset(game, "_isGame", true)
	rawset(game, "_services", {})
	game._p.Name = "Game"
	M.game = game
	M.workspace = game:GetService("Workspace")
	local workspace = M.workspace
	-- Created before the globals of later contexts read them.
	M.serverCtx.globals = M.makeGlobals(M.serverCtx)
	local terrain = M.create("Terrain", { shared = true })
	terrain._p.Name = "Terrain"
	M.setParent(terrain, workspace)
	M.terrain = terrain
	local serverCamera = M.create("Camera", { shared = true })
	serverCamera._p.Name = "Camera"
	M.setParent(serverCamera, workspace)
	M.serverCtx.camera = serverCamera

	-- default.project.json properties.
	workspace._p.StreamingEnabled = true
	workspace._p.Gravity = 196.2
	local lighting = game:GetService("Lighting")
	lighting._p.ClockTime = 9.5
	lighting._p.Brightness = 2.5
	lighting._p.EnvironmentDiffuseScale = 1
	lighting._p.EnvironmentSpecularScale = 1
	lighting._p.GlobalShadows = true

	local replicatedStorage = game:GetService("ReplicatedStorage")
	local sss = game:GetService("ServerScriptService")
	rawset(sss, "_serverOnly", true)
	rawset(game:GetService("ServerStorage"), "_serverOnly", true)
	M.players = game:GetService("Players")
	M.runService = game:GetService("RunService")
	M.starterGui = game:GetService("StarterGui")
	M.uis = game:GetService("UserInputService")
	M.pps = game:GetService("ProximityPromptService")
	local starterPlayer = game:GetService("StarterPlayer")
	local sps = M.create("StarterPlayerScripts", { shared = true })
	sps._p.Name = "StarterPlayerScripts"
	M.setParent(sps, starterPlayer)
	local scs = M.create("StarterCharacterScripts", { shared = true })
	scs._p.Name = "StarterCharacterScripts"
	M.setParent(scs, starterPlayer)

	-- default.project.json tree.
	M.mount(replicatedStorage, "Shared", "src/shared")
	M.mount(sss, "Server", "src/server")
	M.mount(sps, "Client", "src/client")

	-- Frame signals ---------------------------------------------------------------------------------
	local function clientOnly(c)
		return c ~= nil and c.isClient == true
	end
	table.insert(S.frameHooks, 1, function(dt)
		for _, ctx in M.clients do
			if not ctx.dead then
				M.clientFrame(ctx, dt)
			end
		end
		local rs = M.runService
		M.fireFiltered(M.getEvent(rs, "RenderStepped"), clientOnly, dt)
		M.fireFiltered(M.getEvent(rs, "PreRender"), clientOnly, dt)
		M.fire(M.getEvent(rs, "Stepped"), S.now, dt)
		M.fire(M.getEvent(rs, "PreSimulation"), dt)
	end)
	M.afterResume = function(dt)
		local rs = M.runService
		M.fire(M.getEvent(rs, "Heartbeat"), dt)
		M.fire(M.getEvent(rs, "PostSimulation"), dt)
	end

	-- Per-client frame work: BindToRenderStep callbacks, the default camera and controls.
	function M.clientFrame(ctx, dt)
		local steps = {}
		for name, s in ctx.renderSteps do
			table.insert(steps, { name = name, priority = s.priority, fn = s.fn })
		end
		table.sort(steps, function(a, b)
			if a.priority ~= b.priority then
				return a.priority < b.priority
			end
			return a.name < b.name
		end)
		for _, s in steps do
			S.resume(S.newThread(s.fn, ctx), ctx, dt)
		end
		local player = ctx.player
		local character = player and player._p.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and M.findChild(character, "HumanoidRootPart")
		local cam = ctx.camera
		if cam and root and M.raw(cam, "CameraType") == M.Enum.CameraType.Custom then
			local p = M.raw(root, "CFrame").Position
			local look = M.raw(root, "CFrame").LookVector
			local eye = p - look * 12 + M.v3(0, 5, 0)
			local prev = S.current
			S.current = ctx
			cam.CFrame = M.types.CFrame.lookAt(eye, p + M.v3(0, 1.5, 0))
			S.current = prev
		end
		-- The ControlModule feeds the move vector to Humanoid:Move every frame; only touch the
		-- humanoid when the harness changed it, so Humanoid:MoveTo keeps working.
		if humanoid and ctx.controls and ctx.controls.enabled and ctx.moveVector ~= ctx.appliedMove then
			ctx.appliedMove = ctx.moveVector
			rawset(humanoid, "_moveDir", ctx.moveVector)
			if ctx.moveVector then
				rawset(humanoid, "_moveTarget", nil)
			end
		end
	end

	-- Players / clients --------------------------------------------------------------------------------
	local function playerModule(ctx)
		local controls = { enabled = true }
		ctx.controls = controls
		function controls.GetMoveVector(_self)
			return ctx.moveVector or M.v3(0, 0, 0)
		end
		function controls.Enable(_self, on)
			controls.enabled = on ~= false
		end
		function controls.Disable(_self)
			controls.enabled = false
		end
		function controls.GetActiveController(_self)
			return nil
		end
		local cameras = {}
		function cameras.GetCameraMovementModeFromSettings()
			return nil
		end
		return {
			GetControls = function()
				return controls
			end,
			GetCameras = function()
				return cameras
			end,
			GetClickToMoveController = function()
				return nil
			end,
		}
	end

	local nextUserId = 1000
	function M.addPlayer(name: string, userId: number?)
		local prev = S.current
		S.current = M.serverCtx
		if not userId then
			nextUserId += 1
		end
		local player = M.create("Player", { shared = true })
		player._p.Name = name
		player._p.DisplayName = name
		player._p.UserId = userId or nextUserId
		local ctx = newCtx("client:" .. name, true, player)
		rawset(player, "_clientCtx", ctx)
		table.insert(M.clients, ctx)
		for _, className in { "Backpack", "PlayerGui", "StarterGear" } do
			local c = M.create(className, { shared = true })
			c._p.Name = className
			M.setParent(c, player)
		end
		M.setParent(player, M.players)
		M.fire(M.getEvent(M.players, "PlayerAdded"), player)
		-- Client boot.
		S.current = ctx
		local cam = M.create("Camera")
		cam._p.Name = "Camera"
		M.setParent(cam, workspace)
		ctx.camera = cam
		local ps = M.create("PlayerScripts")
		ps._p.Name = "PlayerScripts"
		M.setParent(ps, player)
		local pm = M.create("ModuleScript")
		pm._p.Name = "PlayerModule"
		rawset(pm, "_builtin", playerModule)
		M.setParent(pm, ps)
		local scripts = {}
		for _, child in rawget(sps, "_children") or {} do
			local copy = child:Clone()
			M.setParent(copy, ps)
			if copy._cls.name == "LocalScript" then
				table.insert(scripts, copy)
			end
		end
		M.copyStarterGui(player)
		S.current = M.serverCtx
		-- Scripts start once the client has "loaded"; characters spawn shortly after.
		S.defer({
			co = S.newThread(function()
				for _, s in scripts do
					M.runScript(s, ctx)
				end
			end, ctx),
			ctx = ctx,
			args = { n = 0 },
		})
		if M.raw(M.players, "CharacterAutoLoads") then
			S.at(S.now + 0.2, function()
				if rawget(player, "_parent") and not player._p.Character and M.raw(M.players, "CharacterAutoLoads") then
					local p2 = S.current
					S.current = M.serverCtx
					M.loadCharacter(player)
					S.current = p2
				end
			end)
		end
		S.current = prev
		return player, ctx
	end

	function M.clientOf(player)
		return rawget(player, "_clientCtx")
	end

	function M.removePlayer(player)
		if not rawget(player, "_parent") then
			return
		end
		local prev = S.current
		S.current = M.serverCtx
		M.fire(M.getEvent(M.players, "PlayerRemoving"), player)
		S.drain()
		local character = player._p.Character
		if character then
			M.fire(M.getEvent(player, "CharacterRemoving"), character)
			if not rawget(character, "_destroyed") then
				character:Destroy()
			end
		end
		M.setParent(player, nil)
		local ctx = rawget(player, "_clientCtx")
		if ctx then
			ctx.dead = true
			-- The client's VM is gone: everything it created goes with it.
			for _, d in M.descendantsRaw(game, {}) do
				if rawget(d, "_owner") == ctx and not rawget(d, "_destroyed") then
					d:Destroy()
				end
			end
		end
		S.current = prev
	end

	-- Harness helpers ------------------------------------------------------------------------------------
	M.FRAME = 1 / 30
	function M.step(dt: number?)
		S.step(dt or M.FRAME)
	end
	function M.run(seconds: number)
		local frames = math.max(1, math.floor(seconds / M.FRAME + 0.5))
		for _ = 1, frames do
			S.step(M.FRAME)
		end
	end
	function M.runUntil(pred: () -> boolean, timeout: number?): boolean
		local deadline = S.now + (timeout or 30)
		while S.now < deadline do
			if pred() then
				return true
			end
			S.step(M.FRAME)
		end
		return pred()
	end

	-- Spawns `fn` in `ctx`; returns a handle that records completion and results.
	function M.spawnIn(ctx, fn, ...)
		local handle = { done = false }
		local co = S.newThread(function(...)
			local results = table.pack(xpcall(fn, function(err)
				handle.traceback = M.cleanTrace(debug.traceback(tostring(err), 2))
				return err
			end, ...))
			handle.ok = results[1]
			if results[1] then
				handle.results = table.pack(table.unpack(results, 2, results.n))
			else
				handle.err = results[2]
			end
			handle.done = true
		end, ctx)
		S.resume(co, ctx, ...)
		S.drain()
		return handle
	end
	-- Runs `fn` in `ctx`, advancing virtual time until it finishes. Errors propagate.
	function M.call(ctx, fn, timeout: number?, ...)
		local handle = M.spawnIn(ctx, fn, ...)
		M.runUntil(function()
			return handle.done
		end, timeout or 30)
		if not handle.done then
			error("mock: call did not finish within " .. tostring(timeout or 30) .. " virtual seconds", 2)
		end
		if not handle.ok then
			error(tostring(handle.err) .. "\n" .. tostring(handle.traceback), 2)
		end
		return table.unpack(handle.results, 1, handle.results.n)
	end

	function M.bootServer()
		for _, child in rawget(sss, "_children") or {} do
			if child._cls.name == "Script" then
				M.runScript(child, M.serverCtx)
			end
		end
		S.drain()
	end

	-- Input: press (began=true) or release a key / mouse button on a client.
	function M.input(ctx, key, began: boolean)
		local Enum = M.Enum
		local prev = S.current
		S.current = ctx
		local io = M.create("InputObject")
		if key.EnumType == Enum.KeyCode then
			io._p.KeyCode = key
			io._p.UserInputType = Enum.UserInputType.Keyboard
		else
			io._p.UserInputType = key
		end
		io._p.UserInputState = if began then Enum.UserInputState.Begin else Enum.UserInputState.End
		ctx.keysDown[key] = if began then true else nil
		-- ContextActionService: highest priority (then most recent) binding first; a handler
		-- returning nil or Sink consumes the input.
		local bound = {}
		for name, a in ctx.actions do
			for _, input in a.inputs do
				if input == key or input == io._p.UserInputType then
					table.insert(bound, { name = name, a = a })
					break
				end
			end
		end
		table.sort(bound, function(x, y)
			if x.a.priority ~= y.a.priority then
				return x.a.priority > y.a.priority
			end
			return x.a.seq > y.a.seq
		end)
		local sunk = false
		for _, b in bound do
			local co = S.newThread(b.a.fn, ctx)
			S.threadCtx[co] = ctx
			local ok, result = coroutine.resume(co, b.name, io._p.UserInputState, io)
			if not ok then
				S.report(result, co, ctx)
			end
			if coroutine.status(co) ~= "dead" or result == nil or result == Enum.ContextActionResult.Sink then
				sunk = true
				break
			end
		end
		local only = function(c)
			return c == ctx
		end
		M.fireFiltered(M.getEvent(M.uis, if began then "InputBegan" else "InputEnded"), only, io, sunk)
		if began and key == Enum.KeyCode.Space and not sunk then
			M.fireFiltered(M.getEvent(M.uis, "JumpRequest"), only)
			local character = ctx.player and ctx.player._p.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid and ctx.controls and ctx.controls.enabled then
				rawset(humanoid, "_wantJump", true)
			end
		end
		S.current = prev
		S.drain()
		return sunk
	end

	-- Clicks a GuiButton on the client that owns it.
	function M.click(button)
		local ctx = rawget(button, "_owner") or M.serverCtx
		local only = function(c)
			return c == ctx
		end
		local io = M.create("InputObject")
		io._p.UserInputType = M.Enum.UserInputType.MouseButton1
		io._p.UserInputState = M.Enum.UserInputState.End
		M.fireFiltered(M.getEvent(button, "MouseButton1Click"), only)
		M.fireFiltered(M.getEvent(button, "Activated"), only, io, 1)
		S.drain()
	end

	-- Triggers a ProximityPrompt as `player` would by holding its key (engine-side checks:
	-- enabled, in range of the prompt's attachment/part). Must run inside M.call (it waits
	-- HoldDuration). Returns ok, reason.
	function M.triggerPrompt(prompt, player)
		if not M.raw(prompt, "Enabled") then
			return false, "prompt disabled"
		end
		local parent = rawget(prompt, "_parent")
		local at
		if parent and parent._cls.name == "Attachment" then
			at = parent.WorldPosition
		elseif parent and parent._cls.isa.BasePart then
			at = M.raw(parent, "CFrame").Position
		else
			return false, "prompt has no world position"
		end
		local character = player._p.Character
		local root = character and M.findChild(character, "HumanoidRootPart")
		if not root then
			return false, "no character"
		end
		local dist = (M.raw(root, "CFrame").Position - at).Magnitude
		if dist > M.raw(prompt, "MaxActivationDistance") then
			return false, string.format("out of range (%.1f > %.1f)", dist, M.raw(prompt, "MaxActivationDistance"))
		end
		local ctx = rawget(player, "_clientCtx")
		local both = function(c)
			return c == M.serverCtx or c == ctx
		end
		local hold = M.raw(prompt, "HoldDuration")
		if hold > 0 then
			M.fireFiltered(M.getEvent(prompt, "PromptButtonHoldBegan"), both, player)
			M.fireFiltered(M.getEvent(M.pps, "PromptButtonHoldBegan"), both, prompt, player)
			M.task.wait(hold)
			M.fireFiltered(M.getEvent(prompt, "PromptButtonHoldEnded"), both, player)
		end
		M.fireFiltered(M.getEvent(prompt, "Triggered"), both, player)
		M.fireFiltered(M.getEvent(M.pps, "PromptTriggered"), both, prompt, player)
		M.fireFiltered(M.getEvent(prompt, "TriggerEnded"), both, player)
		return true
	end

	-- Runs every game:BindToClose callback (server shutdown), waiting up to 30 virtual seconds.
	function M.shutdown()
		local pending = 0
		for _, cb in M.closeCallbacks do
			pending += 1
			M.spawnIn(cb.ctx, function()
				cb.fn()
				pending -= 1
			end)
		end
		M.runUntil(function()
			return pending <= 0
		end, 30)
		return pending <= 0
	end

	return M
end

return Mock
