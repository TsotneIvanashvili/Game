-- Source tree + module system.
--
-- The Rojo mapping mirrors default.project.json (luaurun can only compile files, not read
-- JSON, so the mapping is restated in init.luau; keep the two in sync):
--   ReplicatedStorage.Shared                     <- src/shared
--   ServerScriptService.Server                   <- src/server   (init.server.luau => Script)
--   StarterPlayer.StarterPlayerScripts.Client    <- src/client   (init.client.luau => LocalScript)
-- Directories become Folders (or the init.* script), `X.luau` a ModuleScript, `X.server.luau` a
-- Script, `X.client.luau` a LocalScript. luaurun cannot list directories either, so children
-- are materialized lazily the first time something looks them up by name (FindFirstChild,
-- WaitForChild, `script.Parent.X`). Limitation: GetChildren() on a source folder only lists
-- children that were already looked up.
--
-- require() caches per context (the server and every client are separate Luau VMs in Roblox),
-- runs the module in the calling thread (it may yield), detects recursive requires, enforces
-- "exactly one return value", and remembers modules that failed to load.

return function(M)
	local S = M.S
	local fmt = string.format

	local probeCache: { [string]: string | boolean } = {}
	local function probe(path: string): string?
		local cached = probeCache[path]
		if cached ~= nil then
			return if cached then cached :: string else nil
		end
		local ok, err = pcall(__loadfile, path)
		local result: string | boolean
		if ok then
			result = "file"
		else
			local msg = tostring(err)
			if string.find(msg, "Is a directory", 1, true) then
				result = "dir"
			elseif string.find(msg, "No such file", 1, true) then
				result = false
			else
				result = "file" -- exists but does not compile: require() reports the error
			end
		end
		probeCache[path] = result
		return if result then result :: string else nil
	end

	local lazyResolve
	local function makeNode(className: string, name: string, file: string?, dir: string?, owner: any)
		local inst = M.create(className, { shared = true })
		inst._p.Name = name
		if file then
			rawset(inst, "_file", file)
		end
		if dir then
			rawset(inst, "_dir", dir)
			rawset(inst, "_lazy", lazyResolve)
		end
		if owner then
			rawset(inst, "_owner", owner)
		end
		return inst
	end

	-- Builds the instance for a path (file or directory), or nil when it doesn't exist.
	local function nodeFor(base: string, name: string, owner: any)
		if probe(base .. ".luau") then
			return makeNode("ModuleScript", name, base .. ".luau", nil, owner)
		elseif probe(base .. ".server.luau") then
			return makeNode("Script", name, base .. ".server.luau", nil, owner)
		elseif probe(base .. ".client.luau") then
			return makeNode("LocalScript", name, base .. ".client.luau", nil, owner)
		elseif probe(base) == "dir" then
			if probe(base .. "/init.luau") then
				return makeNode("ModuleScript", name, base .. "/init.luau", base, owner)
			elseif probe(base .. "/init.server.luau") then
				return makeNode("Script", name, base .. "/init.server.luau", base, owner)
			elseif probe(base .. "/init.client.luau") then
				return makeNode("LocalScript", name, base .. "/init.client.luau", base, owner)
			end
			return makeNode("Folder", name, nil, base, owner)
		end
		return nil
	end

	function lazyResolve(self, name: string)
		if name == "" or string.find(name, "[/\\%.]") then
			return nil
		end
		local missing = rawget(self, "_missing")
		if missing and missing[name] then
			return nil
		end
		local inst = nodeFor(rawget(self, "_dir") .. "/" .. name, name, rawget(self, "_owner"))
		if not inst then
			if not missing then
				missing = {}
				rawset(self, "_missing", missing)
			end
			missing[name] = true
			return nil
		end
		local prev = S.current
		S.current = M.serverCtx
		M.setParent(inst, self)
		S.current = prev
		return inst
	end

	-- Mounts `path` (relative to the repo root) as child `name` of `parent`.
	function M.mount(parent, name: string, path: string)
		local inst = nodeFor(M.root .. "/" .. path, name, nil)
		if not inst then
			error("mock: project path missing: " .. path)
		end
		M.setParent(inst, parent)
		return inst
	end

	-- Globals -----------------------------------------------------------------------------------
	local function join(...)
		local n = select("#", ...)
		local parts = {}
		for i = 1, n do
			parts[i] = tostring((select(i, ...)))
		end
		return table.concat(parts, " ")
	end
	local function noop() end

	local settingsObj = setmetatable({}, {
		__index = function()
			return setmetatable({}, {
				__index = function()
					return 0
				end,
				__newindex = noop,
			})
		end,
	})
	local userSettings = {
		GetService = function(_, _name)
			return setmetatable({}, {
				__index = function(_, k)
					if k == "SavedQualityLevel" then
						return M.Enum.SavedQualitySetting and nil
					end
					return nil
				end,
			})
		end,
	}

	function M.makeGlobals(ctx)
		local g = {}
		for _, k in
			{
				"assert",
				"error",
				"getmetatable",
				"ipairs",
				"next",
				"pairs",
				"pcall",
				"rawequal",
				"rawget",
				"rawlen",
				"rawset",
				"select",
				"setmetatable",
				"tonumber",
				"tostring",
				"type",
				"unpack",
				"xpcall",
				"getfenv",
				"setfenv",
				"newproxy",
				"gcinfo",
			}
		do
			-- selene: allow(global_usage)
			g[k] = _G[k]
		end
		g.ypcall = pcall
		g.math = math
		g.string = string
		g.table = table
		g.coroutine = coroutine
		g.utf8 = utf8
		g.bit32 = bit32
		g.buffer = buffer
		g.vector = vector
		g.os = {
			clock = function()
				return 100 + S.now
			end,
			time = function(t)
				if t ~= nil then
					return os.time(t)
				end
				return math.floor(M.wallClock())
			end,
			date = function(f, t)
				return os.date(f, t or math.floor(M.wallClock()))
			end,
			difftime = os.difftime,
		}
		g.debug = {
			traceback = debug.traceback,
			info = debug.info,
			profilebegin = noop,
			profileend = noop,
			setmemorycategory = noop,
			resetmemorycategory = noop,
			dumpcodesize = noop,
		}
		g.collectgarbage = function(opt)
			if opt == nil or opt == "count" then
				return collectgarbage("count")
			end
			error("collectgarbage must be called with 'count'; got " .. tostring(opt), 2)
		end
		g.typeof = M.typeof
		g.print = function(...)
			M.log(S.current or ctx, "print", join(...))
		end
		g.warn = function(...)
			M.log(S.current or ctx, "warn", join(...))
		end
		g.printidentity = noop
		g.require = M.require
		g.game = M.game
		g.Game = M.game
		g.workspace = M.workspace
		g.Workspace = M.workspace
		g.Enum = M.Enum
		g.Instance = M.Instance
		for name, t in M.types do
			g[name] = t
		end
		g.task = M.task
		g.wait = M.wait
		g.delay = M.delay
		g.spawn = M.spawn
		g.tick = function()
			return M.wallClock()
		end
		g.time = function()
			return S.now
		end
		g.elapsedTime = function()
			return S.now
		end
		g.settings = function()
			return settingsObj
		end
		g.UserSettings = function()
			return userSettings
		end
		g.version = function()
			return "0.0.0.0"
		end
		g.shared = {}
		g._G = {}
		g._VERSION = "Luau"
		return g
	end

	local function envFor(ctx, scriptInst)
		return setmetatable({ script = scriptInst }, { __index = ctx.globals })
	end
	M.envFor = envFor

	-- require ------------------------------------------------------------------------------------
	M.moduleTraces = {}
	function M.require(target)
		local ctx = S.current or M.serverCtx
		if type(target) == "number" then
			error("mock: require(assetId) is not supported", 2)
		end
		if not M.isInstance(target) or target._cls.name ~= "ModuleScript" then
			error("Attempted to call require with invalid argument(s).", 2)
		end
		if not M.visibleTo(target, ctx) then
			error("Attempted to call require with invalid argument(s).", 2)
		end
		local cache = ctx.modules
		local co = coroutine.running()
		local entry = cache[target]
		if entry then
			if entry.state == "done" then
				return entry.value
			elseif entry.state == "failed" then
				error("Requested module experienced an error while loading: " .. M.fullName(target), 2)
			end
			-- Loading in some thread. Same chain of requires = recursion.
			for _, t in entry.chain do
				if t == co then
					error("Requested module was required recursively: " .. M.fullName(target), 2)
				end
			end
			while entry.state == "loading" do
				M.task.wait(0)
			end
			if entry.state == "failed" then
				error("Requested module experienced an error while loading: " .. M.fullName(target), 2)
			end
			return entry.value
		end
		entry = { state = "loading", chain = { co } }
		cache[target] = entry
		local builtin = rawget(target, "_builtin")
		if builtin then
			entry.value = builtin(ctx)
			entry.state = "done"
			return entry.value
		end
		local file = rawget(target, "_file")
		if not file then
			entry.state = "failed"
			error("mock: ModuleScript " .. M.fullName(target) .. " has no source", 2)
		end
		local okLoad, fn = pcall(__loadfile, file)
		if not okLoad then
			entry.state = "failed"
			error(M.cleanTrace(tostring(fn)), 2)
		end
		setfenv(fn, envFor(ctx, target))
		local results = table.pack(xpcall(fn, function(err)
			local tb = M.cleanTrace(debug.traceback(tostring(err), 2))
			table.insert(M.moduleTraces, { ctx = ctx.name, module = M.fullName(target), traceback = tb })
			return err
		end))
		if not results[1] then
			entry.state = "failed"
			error(results[2], 0)
		end
		if results.n ~= 2 then
			entry.state = "failed"
			error(
				fmt("Module code did not return exactly one value (%s returned %d)", M.fullName(target), results.n - 1),
				2
			)
		end
		entry.value = results[2]
		entry.state = "done"
		return entry.value
	end

	-- Runs a Script/LocalScript in `ctx` (a fresh thread, like the engine starting a script).
	function M.runScript(scriptInst, ctx)
		local file = rawget(scriptInst, "_file")
		if not file then
			return
		end
		local fn = __loadfile(file)
		setfenv(fn, envFor(ctx, scriptInst))
		local co = S.newThread(fn, ctx)
		S.resume(co, ctx)
		return co
	end
end
