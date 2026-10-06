--!strict
-- Runtime argument validation for anything arriving from a client. Clients can send any
-- value of any type (including NaN, inf, huge strings, nested tables), so every remote
-- declares a schema built from these checkers and RemoteGuard rejects anything else.

export type Checker = (value: any) -> boolean

local Validate = {}

local function finite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

function Validate.number(min: number, max: number): Checker
	return function(v)
		return typeof(v) == "number" and finite(v) and v >= min and v <= max
	end
end

function Validate.integer(min: number, max: number): Checker
	return function(v)
		return typeof(v) == "number" and finite(v) and v == math.floor(v) and v >= min and v <= max
	end
end

function Validate.string(maxLen: number): Checker
	return function(v)
		return typeof(v) == "string" and #v > 0 and #v <= maxLen
	end
end

function Validate.boolean(): Checker
	return function(v)
		return typeof(v) == "boolean"
	end
end

function Validate.vector3(maxMagnitude: number): Checker
	return function(v)
		return typeof(v) == "Vector3" and finite(v.X) and finite(v.Y) and finite(v.Z) and v.Magnitude <= maxMagnitude
	end
end

function Validate.cframe(maxMagnitude: number): Checker
	return function(v)
		if typeof(v) ~= "CFrame" then
			return false
		end
		local components = { v:GetComponents() }
		for _, c in components do
			if not finite(c) then
				return false
			end
		end
		return v.Position.Magnitude <= maxMagnitude
	end
end

function Validate.oneOf(options: { string }): Checker
	local set = {}
	for _, o in options do
		set[o] = true
	end
	return function(v)
		return typeof(v) == "string" and set[v] == true
	end
end

function Validate.optional(check: Checker): Checker
	return function(v)
		return v == nil or check(v)
	end
end

-- Checks a positional argument list. Extra arguments are rejected too.
function Validate.args(schema: { Checker }, args: { any }, n: number): (boolean, string?)
	if n > #schema then
		return false, "too many arguments"
	end
	for i, check in schema do
		if not check(args[i]) then
			return false, "bad argument #" .. i
		end
	end
	return true, nil
end

return Validate
