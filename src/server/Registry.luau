--!strict
-- Service locator. Services never require each other directly (that creates require
-- cycles); they look each other up here at call time. The bootstrap registers every
-- service before any Init runs, so lookups inside Init/Start/handlers always succeed.

local Registry = {}

local services: { [string]: any } = {}

function Registry.register(name: string, service: any)
	assert(services[name] == nil, "service registered twice: " .. name)
	services[name] = service
end

function Registry.get(name: string): any
	local service = services[name]
	assert(service, "unknown service: " .. name)
	return service
end

return Registry
