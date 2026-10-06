-- Minimal test harness for pure-logic modules. Runs in a plain Luau VM (no Roblox):
-- it fakes the `script` instance tree so `require(script.Parent.X)` resolves to files,
-- and stubs the few Roblox datatypes the config modules construct (Vector3, Color3).
--
-- Run: tests/run.sh   (needs the `luaurun` binary; see docs/TESTING.md)

local ROOT = ...

-- Roblox datatype stubs -------------------------------------------------------------------
local Vector3Meta = {}
Vector3Meta.__index = Vector3Meta
local function v3(x, y, z)
	local v = setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3Meta)
	v.Magnitude = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	return v
end
Vector3Meta.__add = function(a, b)
	return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3Meta.__sub = function(a, b)
	return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3 = { new = v3 }
Color3 = {
	fromRGB = function(r, g, b)
		return { R = r / 255, G = g / 255, B = b / 255 }
	end,
	new = function(r, g, b)
		return { R = r, G = g, B = b }
	end,
}

-- Fake instance tree mapped onto the filesystem --------------------------------------------
local cache = {}

local function node(path, parent)
	local n = { __path = path, Parent = parent }
	return setmetatable(n, {
		__index = function(self, key)
			local childPath = rawget(self, "__path") .. "/" .. key
			local child = node(childPath, self)
			rawset(self, key, child)
			return child
		end,
	})
end

local function fakeRequire(target)
	local path = rawget(target, "__path")
	if cache[path] ~= nil then
		return cache[path]
	end
	local fn = __loadfile(path .. ".luau")
	-- selene: allow(global_usage)
	local env = setmetatable({ script = target, require = fakeRequire }, { __index = _G })
	setfenv(fn, env)
	local result = fn()
	cache[path] = result
	return result
end

local srcRoot = node(ROOT .. "/src", nil)
local Shared = srcRoot.shared

-- Test runner --------------------------------------------------------------------------------
local passed, failed = 0, 0
local failures = {}

local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, name .. "\n      " .. tostring(err))
	end
end

local function eq(a, b, msg)
	if a ~= b then
		error((msg or "expected equal") .. ": got " .. tostring(a) .. ", expected " .. tostring(b), 2)
	end
end

local function near(a, b, eps, msg)
	if math.abs(a - b) > (eps or 1e-6) then
		error((msg or "expected near") .. ": got " .. tostring(a) .. ", expected " .. tostring(b), 2)
	end
end

local function truthy(v, msg)
	if not v then
		error(msg or "expected truthy", 2)
	end
end

local function report()
	print(string.format("\n%d passed, %d failed", passed, failed))
	for _, f in failures do
		print("  FAIL " .. f)
	end
	if failed > 0 then
		error("tests failed")
	end
end

return {
	require = fakeRequire,
	Shared = Shared,
	test = test,
	eq = eq,
	near = near,
	truthy = truthy,
	report = report,
}
