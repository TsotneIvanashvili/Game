-- Instance system: property bags with a per-class schema (unknown members error exactly like
-- the engine: "X is not a valid member of Part "Workspace.Foo""), typed property writes,
-- hierarchy with Parent locking/circularity checks, signals, attributes (with the engine's
-- type restrictions), tags, Clone/Destroy and WaitForChild.
--
-- Client/server separation (see init.luau): an instance created while a client context runs
-- is owned by that client and is invisible to the server and other clients. A client writing
-- a property/attribute of a server-owned instance only changes its own view (an overlay),
-- exactly like a non-replicating local change in Roblox; the server's next write to that
-- property replicates and clears the overlay. Exception: physics properties of the client's
-- own character parts write through (network ownership).

return function(M)
	local S = M.S
	local fmt = string.format

	local classes: { [string]: any } = {}
	M.classes = classes
	local NILV = {} -- overlay sentinel for "locally set to nil"

	local InstMt = { __type = "Instance" }
	M.InstMt = InstMt
	local nextId = 0

	local function isInstance(v): boolean
		return type(v) == "table" and getmetatable(v) == InstMt
	end
	M.isInstance = isInstance

	-- Spec helpers ----------------------------------------------------------------------------
	-- A property default is either a plain value (type inferred) or a spec built with these.
	function M.N(typeName: string, class: string?)
		return { __spec = true, type = typeName, nilable = true, class = class }
	end
	function M.RO(default: any)
		return { __spec = true, default = default, readonly = true, inferred = true }
	end
	function M.ANY(default: any)
		return { __spec = true, default = default, any = true }
	end
	function M.COMPUTED(get: (any) -> any, set: ((any, any) -> ())?, typeName: string?)
		return { __spec = true, get = get, set = set, readonly = set == nil, type = typeName }
	end

	local function makeSpec(name: string, v: any)
		local spec
		if type(v) == "table" and rawget(v, "__spec") then
			spec = table.clone(v)
		else
			spec = { default = v, inferred = true }
		end
		if spec.inferred then
			local d = spec.default
			local t = M.typeof(d)
			spec.type = t
			if t == "EnumItem" then
				spec.enum = d.EnumType
			end
		end
		if spec.any then
			spec.type = nil
		end
		spec.name = name
		return spec
	end

	-- class(name, parentName, { props = {}, methods = {}, events = {}, abstract, service, init })
	function M.class(name: string, parentName: string?, def: any)
		local parent = parentName and classes[parentName]
		if parentName and not parent then
			error("mock: unknown parent class " .. parentName)
		end
		local cls = {
			name = name,
			parent = parent,
			props = if parent then table.clone(parent.props) else {},
			methods = if parent then table.clone(parent.methods) else {},
			events = if parent then table.clone(parent.events) else {},
			isa = if parent then table.clone(parent.isa) else {},
			inits = if parent then table.clone(parent.inits) else {},
			abstract = def.abstract == true,
			service = def.service == true,
			notCreatable = def.notCreatable == true or def.service == true,
		}
		cls.isa[name] = true
		for k, v in def.props or {} do
			cls.props[k] = makeSpec(k, v)
		end
		for k, fn in def.methods or {} do
			cls.methods[k] = fn
		end
		for _, e in def.events or {} do
			cls.events[e] = true
		end
		if def.init then
			table.insert(cls.inits, def.init)
		end
		classes[name] = cls
		return cls
	end

	-- Visibility / ownership ------------------------------------------------------------------
	local function ctxOf(ctx)
		return ctx or M.serverCtx
	end
	function M.visibleTo(inst, ctx): boolean
		local owner = rawget(inst, "_owner")
		if owner == nil then
			return true
		end
		return owner == ctxOf(ctx)
	end
	local visibleTo = M.visibleTo
	local function hiddenContainer(inst, ctx): boolean
		local c = ctxOf(ctx)
		return c.isClient and rawget(inst, "_serverOnly") == true
	end

	-- Full name: Workspace.Mountain.Camps (DataModel omitted, like the engine).
	local function fullName(inst): string
		local parts = {}
		local node = inst
		while node and not rawget(node, "_isGame") do
			table.insert(parts, 1, node._p.Name)
			node = rawget(node, "_parent")
		end
		return table.concat(parts, ".")
	end
	M.fullName = fullName

	-- Raw property read honouring the running client's overlay.
	local function raw(self, key: string): any
		local loc = rawget(self, "_local")
		if loc then
			local ctx = S.current
			local l = ctx and loc[ctx]
			if l then
				local v = l.p[key]
				if v ~= nil then
					return if v == NILV then nil else v
				end
			end
		end
		local v = self._p[key]
		if v == nil then
			local spec = self._cls.props[key]
			if spec then
				v = spec.default
			end
		end
		return v
	end
	M.raw = raw

	local PHYSICS_PROPS = {
		CFrame = true,
		Position = true,
		Orientation = true,
		Rotation = true,
		AssemblyLinearVelocity = true,
		AssemblyAngularVelocity = true,
		Velocity = true,
	}
	local function ownedByClientCharacter(self, ctx): boolean
		local player = ctx.player
		local character = player and player._p.Character
		if not character then
			return false
		end
		local node = rawget(self, "_parent")
		while node do
			if node == character then
				return true
			end
			node = rawget(node, "_parent")
		end
		return false
	end
	local function writesThrough(self, key: string, ctx): boolean
		if PHYSICS_PROPS[key] and self._cls.isa.BasePart then
			return ownedByClientCharacter(self, ctx)
		end
		return false
	end

	local function getEvent(self, name: string)
		local ev = rawget(self, "_ev")
		if not ev then
			ev = {}
			rawset(self, "_ev", ev)
		end
		local sig = ev[name]
		if not sig then
			sig = M.newSignal(name)
			ev[name] = sig
		end
		return sig
	end
	M.getEvent = getEvent
	local function existingEvent(self, name: string)
		local ev = rawget(self, "_ev")
		return ev and ev[name]
	end
	M.existingEvent = existingEvent

	local function onlyCtx(ctx)
		return function(c)
			return c == ctx
		end
	end

	local function changed(self, key: string, ctx: any)
		local filter = if ctx then onlyCtx(ctx) else nil
		local ev = rawget(self, "_ev")
		if ev and ev.Changed then
			if self._cls.isa.ValueBase then
				if key == "Value" then
					M.fireFiltered(ev.Changed, filter, raw(self, "Value"))
				end
			else
				M.fireFiltered(ev.Changed, filter, key)
			end
		end
		local pev = rawget(self, "_pev")
		if pev and pev[key] then
			M.fireFiltered(pev[key], filter)
		end
	end
	M.changed = changed

	-- Stores a property value: shared, or as an overlay when a client writes a server-owned
	-- instance. Fires change signals when the visible value changed.
	local function store(self, key: string, value: any)
		local ctx = S.current
		local old = raw(self, key)
		if ctx and ctx.isClient and rawget(self, "_owner") == nil and not writesThrough(self, key, ctx) then
			local loc = rawget(self, "_local")
			if not loc then
				loc = {}
				rawset(self, "_local", loc)
			end
			local l = loc[ctx]
			if not l then
				l = { p = {}, a = {} }
				loc[ctx] = l
			end
			l.p[key] = if value == nil then NILV else value
			if old ~= value then
				changed(self, key, ctx)
			end
			return
		end
		self._p[key] = value
		local loc = rawget(self, "_local")
		if loc then
			for _, l in loc do
				l.p[key] = nil
			end
		end
		if old ~= value then
			changed(self, key, nil)
		end
	end
	M.store = store

	-- Engine-side write (physics results, read-only properties): always shared.
	local function storeShared(self, key: string, value: any)
		local old = self._p[key]
		if old == nil then
			local spec = self._cls.props[key]
			old = spec and spec.default
		end
		self._p[key] = value
		local loc = rawget(self, "_local")
		if loc then
			for _, l in loc do
				l.p[key] = nil
			end
		end
		if old ~= value then
			changed(self, key, nil)
		end
	end
	M.storeShared = storeShared

	local function coerce(spec, key: string, v: any): any
		local t = spec.type
		if t == nil then
			return v
		end
		if v == nil then
			if spec.nilable then
				return nil
			end
			error(fmt("Unable to assign property %s. %s expected, got nil", key, t), 4)
		end
		local vt = M.typeof(v)
		if t == "number" then
			if vt == "number" then
				return v
			elseif vt == "string" and tonumber(v) then
				return tonumber(v)
			end
		elseif t == "string" then
			if vt == "string" then
				return v
			elseif vt == "number" then
				return tostring(v)
			end
		elseif t == "EnumItem" then
			local item = M.coerceEnum(spec.enum, v)
			if item then
				return item
			end
			error(
				fmt(
					"Unable to assign property %s. EnumItem of type %s expected, got %s",
					key,
					tostring(spec.enum),
					if vt == "EnumItem" then tostring(v) else vt
				),
				4
			)
		elseif t == "Instance" then
			if vt == "Instance" then
				if spec.class and not v._cls.isa[spec.class] then
					error(fmt("Unable to assign property %s. %s expected, got %s", key, spec.class, v._cls.name), 4)
				end
				return v
			end
		elseif vt == t then
			return v
		end
		error(fmt("Unable to assign property %s. %s expected, got %s", key, t, vt), 4)
		return nil
	end

	local function findChild(self, name: string)
		local ctx = S.current
		if hiddenContainer(self, ctx) then
			return nil
		end
		local children = rawget(self, "_children")
		if children then
			for _, c in children do
				if c._p.Name == name and visibleTo(c, ctx) then
					return c
				end
			end
		end
		local lazy = rawget(self, "_lazy")
		if lazy then
			return lazy(self, name)
		end
		return nil
	end
	M.findChild = findChild

	InstMt.__index = function(self, key)
		local cls = rawget(self, "_cls")
		local spec = cls.props[key]
		if spec then
			local g = spec.get
			if g then
				return g(self)
			end
			if spec.writeOnly then
				error(
					fmt(
						"%s is a callback member of %s; you can only set the callback value, get is not available",
						key,
						cls.name
					),
					2
				)
			end
			return raw(self, key)
		end
		local m = cls.methods[key]
		if m then
			return m
		end
		if cls.events[key] then
			return getEvent(self, key)
		end
		if type(key) == "string" then
			local child = findChild(self, key)
			if child then
				return child
			end
		end
		error(fmt('%s is not a valid member of %s "%s"', tostring(key), cls.name, fullName(self)), 2)
	end

	InstMt.__newindex = function(self, key, value)
		local cls = rawget(self, "_cls")
		local spec = cls.props[key]
		if not spec then
			error(fmt('%s is not a valid member of %s "%s"', tostring(key), cls.name, fullName(self)), 2)
		end
		if spec.readonly then
			error(fmt("Unable to assign property %s. Property is read only", tostring(key)), 2)
		end
		value = coerce(spec, key, value)
		if spec.set then
			spec.set(self, value)
		else
			store(self, key, value)
		end
	end
	InstMt.__tostring = function(self)
		return self._p.Name
	end
	InstMt.__iter = function(self)
		error(fmt("attempt to iterate over an Instance (%s)", fullName(self)), 2)
	end
	InstMt.__len = function(self)
		error(fmt("attempt to get length of an Instance (%s)", fullName(self)), 2)
	end

	-- Hierarchy ------------------------------------------------------------------------------
	local function descendantsRaw(inst, out)
		local children = rawget(inst, "_children")
		if children then
			for _, c in children do
				table.insert(out, c)
				descendantsRaw(c, out)
			end
		end
		return out
	end
	M.descendantsRaw = descendantsRaw

	local function isAncestor(a, b): boolean -- a is an ancestor of b
		local node = rawget(b, "_parent")
		while node do
			if node == a then
				return true
			end
			node = rawget(node, "_parent")
		end
		return false
	end
	M.isAncestor = isAncestor

	local function hasListeners(sig): boolean
		return sig ~= nil and (#sig._conns > 0 or #sig._waiters > 0)
	end

	local function visFilter(inst)
		return function(ctx)
			return visibleTo(inst, ctx)
		end
	end

	-- Moves `self` under `newParent` (nil = remove). Engine bookkeeping + signals.
	local function setParent(self, newParent)
		local old = rawget(self, "_parent")
		if old == newParent then
			return
		end
		if old then
			local list = rawget(old, "_children")
			local i = table.find(list, self)
			if i then
				table.remove(list, i)
			end
			local ev = existingEvent(old, "ChildRemoved")
			if hasListeners(ev) then
				M.fireFiltered(ev, visFilter(self), self)
			end
			-- DescendantRemoving on every ancestor that listens.
			local node = old
			while node do
				local dr = existingEvent(node, "DescendantRemoving")
				if hasListeners(dr) then
					M.fireFiltered(dr, visFilter(self), self)
					for _, d in descendantsRaw(self, {}) do
						M.fireFiltered(dr, visFilter(d), d)
					end
				end
				node = rawget(node, "_parent")
			end
		end
		rawset(self, "_parent", newParent)
		if newParent then
			local list = rawget(newParent, "_children")
			if not list then
				list = {}
				rawset(newParent, "_children", list)
			end
			table.insert(list, self)
		end
		M.onReparent(self, old, newParent)
		if newParent then
			local ev = existingEvent(newParent, "ChildAdded")
			if hasListeners(ev) then
				M.fireFiltered(ev, visFilter(self), self)
			end
			local node = newParent
			while node do
				local da = existingEvent(node, "DescendantAdded")
				if hasListeners(da) then
					M.fireFiltered(da, visFilter(self), self)
					for _, d in descendantsRaw(self, {}) do
						M.fireFiltered(da, visFilter(d), d)
					end
				end
				node = rawget(node, "_parent")
			end
			-- WaitForChild waiters on the new parent.
			local waiters = rawget(newParent, "_waiters")
			if waiters then
				M.wakeChildWaiters(newParent, self)
			end
		end
		-- AncestryChanged on self and every descendant that listens.
		local ac = existingEvent(self, "AncestryChanged")
		if hasListeners(ac) then
			M.fire(ac, self, newParent)
		end
		for _, d in descendantsRaw(self, {}) do
			local dac = existingEvent(d, "AncestryChanged")
			if hasListeners(dac) then
				M.fire(dac, self, newParent)
			end
		end
		changed(self, "Parent", nil)
	end
	M.setParent = setParent

	function M.wakeChildWaiters(parent, child)
		local waiters = rawget(parent, "_waiters")
		if not waiters then
			return
		end
		local name = child._p.Name
		local list = waiters[name]
		if not list then
			return
		end
		local keep = {}
		for _, w in list do
			if visibleTo(child, w.ctx) then
				S.defer({ wakeCo = w.co, tok = w.tok, ctx = w.ctx, args = table.pack(child) })
			else
				table.insert(keep, w)
			end
		end
		waiters[name] = if #keep > 0 then keep else nil
	end

	local function parentSetter(self, newParent)
		if rawget(self, "_locked") then
			error(
				fmt(
					"The Parent property of %s is locked, current parent: NULL, new parent %s",
					self._p.Name,
					if newParent then newParent._p.Name else "NULL"
				),
				3
			)
		end
		if newParent ~= nil then
			if newParent == self or isAncestor(self, newParent) then
				error(
					fmt(
						"Attempt to set parent of %s to %s would result in circular reference",
						fullName(self),
						fullName(newParent)
					),
					3
				)
			end
		end
		if self._cls.service and rawget(self, "_parent") ~= nil then
			error(fmt("%s cannot be reparented", self._cls.name), 3)
		end
		local ctx = S.current
		if ctx and ctx.isClient and rawget(self, "_owner") == nil and rawget(self, "_parent") ~= nil then
			-- Reparenting a replicated instance on a client is local-only in Roblox; we share
			-- the tree, so record it for the report instead of silently diverging.
			table.insert(M.notes, fmt("client %s reparented server instance %s", ctx.name, fullName(self)))
		end
		setParent(self, newParent)
	end

	-- Creation -------------------------------------------------------------------------------
	function M.create(className: string, opts: any?)
		local cls = classes[className]
		if not cls then
			error(fmt('Unable to create an Instance of type "%s"', tostring(className)), 3)
		end
		nextId += 1
		local self = setmetatable({
			_cls = cls,
			_p = { Name = className },
			_id = nextId,
		}, InstMt)
		local ctx = S.current
		if ctx and ctx.isClient and not (opts and opts.shared) then
			rawset(self, "_owner", ctx)
		end
		for _, init in cls.inits do
			init(self)
		end
		return self
	end

	M.Instance = {
		new = function(className, parent)
			if type(className) ~= "string" then
				error("invalid argument #1 to 'new' (string expected, got " .. M.typeof(className) .. ")", 2)
			end
			local cls = classes[className]
			if not cls or cls.abstract or cls.notCreatable then
				error(fmt('Unable to create an Instance of type "%s"', className), 2)
			end
			local inst = M.create(className)
			if parent ~= nil then
				inst.Parent = parent
			end
			return inst
		end,
		fromExisting = function(inst)
			local copy = M.create(inst._cls.name)
			for k, v in inst._p do
				copy._p[k] = v
			end
			return copy
		end,
	}

	-- Attributes -----------------------------------------------------------------------------
	local ATTR_TYPES = {
		string = true,
		boolean = true,
		number = true,
		UDim = true,
		UDim2 = true,
		BrickColor = true,
		Color3 = true,
		Vector2 = true,
		Vector3 = true,
		CFrame = true,
		NumberSequence = true,
		ColorSequence = true,
		NumberRange = true,
		Rect = true,
		Font = true,
		EnumItem = true,
	}
	local function attrValue(self, name: string): any
		local loc = rawget(self, "_local")
		if loc then
			local ctx = S.current
			local l = ctx and loc[ctx]
			if l then
				local v = l.a[name]
				if v ~= nil then
					return if v == NILV then nil else v
				end
			end
		end
		local attrs = rawget(self, "_attrs")
		return attrs and attrs[name]
	end
	local function attrChanged(self, name: string, ctx: any)
		local filter = if ctx then onlyCtx(ctx) else nil
		local ev = existingEvent(self, "AttributeChanged")
		if ev then
			M.fireFiltered(ev, filter, name)
		end
		local aev = rawget(self, "_aev")
		if aev and aev[name] then
			M.fireFiltered(aev[name], filter)
		end
	end

	-- Methods (shared by every Instance) ------------------------------------------------------
	local I = {}
	M.InstanceMethods = I
	local function checkSelf(self, method: string)
		if not isInstance(self) then
			error(fmt("Expected ':' not '.' calling member function %s", method), 3)
		end
	end
	function I.IsA(self, className)
		checkSelf(self, "IsA")
		if type(className) ~= "string" then
			error("Argument 1 missing or nil", 2)
		end
		return self._cls.isa[className] == true or className == "Instance"
	end
	function I.GetChildren(self)
		checkSelf(self, "GetChildren")
		local ctx = S.current
		local out = {}
		if hiddenContainer(self, ctx) then
			return out
		end
		local children = rawget(self, "_children")
		if children then
			for _, c in children do
				if visibleTo(c, ctx) then
					table.insert(out, c)
				end
			end
		end
		return out
	end
	function I.GetDescendants(self)
		checkSelf(self, "GetDescendants")
		local ctx = S.current
		local out = {}
		local function walk(n)
			if hiddenContainer(n, ctx) then
				return
			end
			local children = rawget(n, "_children")
			if children then
				for _, c in children do
					if visibleTo(c, ctx) then
						table.insert(out, c)
						walk(c)
					end
				end
			end
		end
		walk(self)
		return out
	end
	function I.FindFirstChild(self, name, recursive)
		checkSelf(self, "FindFirstChild")
		if type(name) ~= "string" then
			error("Argument 1 missing or nil", 2)
		end
		local direct = findChild(self, name)
		if direct or not recursive then
			return direct
		end
		for _, d in I.GetDescendants(self) do
			if d._p.Name == name then
				return d
			end
		end
		return nil
	end
	function I.FindFirstChildOfClass(self, className)
		checkSelf(self, "FindFirstChildOfClass")
		for _, c in I.GetChildren(self) do
			if c._cls.name == className then
				return c
			end
		end
		return nil
	end
	function I.FindFirstChildWhichIsA(self, className, recursive)
		checkSelf(self, "FindFirstChildWhichIsA")
		local list = if recursive then I.GetDescendants(self) else I.GetChildren(self)
		for _, c in list do
			if c._cls.isa[className] then
				return c
			end
		end
		return nil
	end
	function I.FindFirstDescendant(self, name)
		return I.FindFirstChild(self, name, true)
	end
	function I.FindFirstAncestor(self, name)
		local node = rawget(self, "_parent")
		while node do
			if node._p.Name == name then
				return node
			end
			node = rawget(node, "_parent")
		end
		return nil
	end
	function I.FindFirstAncestorOfClass(self, className)
		local node = rawget(self, "_parent")
		while node do
			if node._cls.name == className then
				return node
			end
			node = rawget(node, "_parent")
		end
		return nil
	end
	function I.FindFirstAncestorWhichIsA(self, className)
		local node = rawget(self, "_parent")
		while node do
			if node._cls.isa[className] then
				return node
			end
			node = rawget(node, "_parent")
		end
		return nil
	end
	function I.IsDescendantOf(self, ancestor)
		checkSelf(self, "IsDescendantOf")
		if not isInstance(ancestor) then
			error("Argument 1 missing or nil", 2)
		end
		return isAncestor(ancestor, self)
	end
	function I.IsAncestorOf(self, descendant)
		checkSelf(self, "IsAncestorOf")
		if not isInstance(descendant) then
			error("Argument 1 missing or nil", 2)
		end
		return isAncestor(self, descendant)
	end
	function I.GetFullName(self)
		checkSelf(self, "GetFullName")
		return fullName(self)
	end
	function I.GetDebugId(self)
		return tostring(self._id)
	end
	function I.WaitForChild(self, name, timeout)
		checkSelf(self, "WaitForChild")
		if type(name) ~= "string" then
			error("Argument 1 missing or nil", 2)
		end
		local found = findChild(self, name)
		if found then
			return found
		end
		local co, tok = S.park()
		local ctx = S.current
		local waiters = rawget(self, "_waiters")
		if not waiters then
			waiters = {}
			rawset(self, "_waiters", waiters)
		end
		waiters[name] = waiters[name] or {}
		table.insert(waiters[name], { co = co, tok = tok, ctx = ctx })
		local where = fullName(self)
		if timeout then
			S.at(S.now + timeout, function()
				S.wake(co, tok, nil)
			end)
		else
			S.at(S.now + 5, function()
				if S.isParked(co, tok) then
					M.warnAs(ctx, fmt("Infinite yield possible on '%s:WaitForChild(\"%s\")'", where, name))
				end
			end)
		end
		return coroutine.yield()
	end
	function I.ClearAllChildren(self)
		for _, c in I.GetChildren(self) do
			if not c._cls.service then
				I.Destroy(c)
			end
		end
	end
	function I.Destroy(self)
		checkSelf(self, "Destroy")
		if rawget(self, "_destroyed") then
			return
		end
		if self._cls.service or rawget(self, "_isGame") then
			error(fmt("%s cannot be destroyed", self._cls.name), 2)
		end
		local ev = existingEvent(self, "Destroying")
		if ev then
			M.fire(ev)
		end
		rawset(self, "_destroyed", true)
		local children = rawget(self, "_children")
		if children then
			for _, c in table.clone(children) do
				I.Destroy(c)
			end
		end
		rawset(self, "_locked", false)
		setParent(self, nil)
		rawset(self, "_locked", true)
		M.onDestroy(self)
		local evs = rawget(self, "_ev")
		if evs then
			for _, sig in evs do
				M.disconnectAll(sig)
			end
		end
		local pev = rawget(self, "_pev")
		if pev then
			for _, sig in pev do
				M.disconnectAll(sig)
			end
		end
		local aev = rawget(self, "_aev")
		if aev then
			for _, sig in aev do
				M.disconnectAll(sig)
			end
		end
	end
	I.Remove = function(self)
		self.Parent = nil
	end
	function I.Clone(self)
		checkSelf(self, "Clone")
		if not self._p.Archivable and self._p.Archivable ~= nil then
			return nil
		end
		local map = {}
		local function copy(src)
			local dst = M.create(
				src._cls.name,
				{ shared = rawget(src, "_owner") == nil and not (S.current and S.current.isClient) }
			)
			map[src] = dst
			for k, v in src._p do
				if k ~= "Parent" then
					dst._p[k] = v
				end
			end
			for _, k in { "_file", "_builtin", "_scriptKind", "_lazy", "_dir" } do
				local v = rawget(src, k)
				if v ~= nil then
					rawset(dst, k, v)
				end
			end
			local attrs = rawget(src, "_attrs")
			if attrs then
				rawset(dst, "_attrs", table.clone(attrs))
			end
			local tags = rawget(src, "_tags")
			if tags then
				for tag in tags do
					M.addTag(dst, tag)
				end
			end
			local children = rawget(src, "_children")
			if children then
				for _, c in children do
					if c._p.Archivable ~= false then
						local cc = copy(c)
						setParent(cc, dst)
					end
				end
			end
			return dst
		end
		local root = copy(self)
		-- Remap references that point inside the cloned subtree.
		for src, dst in map do
			for k, v in src._p do
				if isInstance(v) and map[v] and k ~= "Parent" then
					dst._p[k] = map[v]
				end
			end
		end
		if M.onCloned then
			for _, dst in map do
				M.onCloned(dst)
			end
		end
		return root
	end
	function I.GetAttribute(self, name)
		checkSelf(self, "GetAttribute")
		if type(name) ~= "string" then
			error("Argument 1 missing or nil", 2)
		end
		return attrValue(self, name)
	end
	function I.GetAttributes(self)
		local out = {}
		local attrs = rawget(self, "_attrs")
		if attrs then
			for k in attrs do
				out[k] = attrValue(self, k)
			end
		end
		local loc = rawget(self, "_local")
		local l = loc and S.current and loc[S.current]
		if l then
			for k, v in l.a do
				out[k] = if v == NILV then nil else v
			end
		end
		return out
	end
	function I.SetAttribute(self, name, value)
		checkSelf(self, "SetAttribute")
		if type(name) ~= "string" then
			error("Argument 1 missing or nil", 2)
		end
		if #name > 100 or not string.match(name, "^[%w_]+$") or string.sub(name, 1, 3) == "RBX" then
			error(
				fmt("Attribute name '%s' is invalid (alphanumeric and underscore only, max 100, no RBX prefix)", name),
				2
			)
		end
		if value ~= nil and not ATTR_TYPES[M.typeof(value)] then
			error(fmt("%s is not a supported attribute type", M.typeof(value)), 2)
		end
		local old = attrValue(self, name)
		local ctx = S.current
		if ctx and ctx.isClient and rawget(self, "_owner") == nil then
			local loc = rawget(self, "_local")
			if not loc then
				loc = {}
				rawset(self, "_local", loc)
			end
			local l = loc[ctx]
			if not l then
				l = { p = {}, a = {} }
				loc[ctx] = l
			end
			l.a[name] = if value == nil then NILV else value
			if old ~= value then
				attrChanged(self, name, ctx)
			end
			return
		end
		local attrs = rawget(self, "_attrs")
		if not attrs then
			attrs = {}
			rawset(self, "_attrs", attrs)
		end
		attrs[name] = value
		local loc = rawget(self, "_local")
		if loc then
			for _, l in loc do
				l.a[name] = nil
			end
		end
		if old ~= value then
			attrChanged(self, name, nil)
		end
	end
	function I.GetAttributeChangedSignal(self, name)
		checkSelf(self, "GetAttributeChangedSignal")
		local aev = rawget(self, "_aev")
		if not aev then
			aev = {}
			rawset(self, "_aev", aev)
		end
		local sig = aev[name]
		if not sig then
			sig = M.newSignal("AttributeChanged:" .. name)
			aev[name] = sig
		end
		return sig
	end
	function I.GetPropertyChangedSignal(self, prop)
		checkSelf(self, "GetPropertyChangedSignal")
		if not self._cls.props[prop] then
			error(fmt("%s is not a valid property name.", tostring(prop)), 2)
		end
		local pev = rawget(self, "_pev")
		if not pev then
			pev = {}
			rawset(self, "_pev", pev)
		end
		local sig = pev[prop]
		if not sig then
			sig = M.newSignal("PropertyChanged:" .. prop)
			pev[prop] = sig
		end
		return sig
	end
	function I.AddTag(self, tag)
		M.addTag(self, tag)
	end
	function I.RemoveTag(self, tag)
		M.removeTag(self, tag)
	end
	function I.HasTag(self, tag)
		local tags = rawget(self, "_tags")
		return tags ~= nil and tags[tag] == true
	end
	function I.GetTags(self)
		local out = {}
		local tags = rawget(self, "_tags")
		if tags then
			for t in tags do
				table.insert(out, t)
			end
		end
		return out
	end
	function I.GetActor()
		return nil
	end
	function I.IsPropertyModified(self, prop)
		return self._p[prop] ~= nil
	end

	M.class("Instance", nil, {
		abstract = true,
		props = {
			Name = "Instance",
			ClassName = M.COMPUTED(function(self)
				return self._cls.name
			end),
			Parent = {
				__spec = true,
				type = "Instance",
				nilable = true,
				get = function(self)
					return rawget(self, "_parent")
				end,
				set = parentSetter,
			},
			Archivable = true,
			UniqueId = M.COMPUTED(function(self)
				return tostring(self._id)
			end),
		},
		methods = I,
		events = {
			"Changed",
			"ChildAdded",
			"ChildRemoved",
			"DescendantAdded",
			"DescendantRemoving",
			"AncestryChanged",
			"AttributeChanged",
			"Destroying",
		},
	})
	-- Name setter: wake WaitForChild waiters on rename.
	classes.Instance.props.Name.set = function(self, v)
		store(self, "Name", v)
		local parent = rawget(self, "_parent")
		if parent and rawget(parent, "_waiters") then
			M.wakeChildWaiters(parent, self)
		end
	end
	M.notes = {}
end
