-- Compiles one file with the real Luau compiler (ROOT = file path). Catches syntax that
-- StyLua accepts but Roblox rejects, e.g. ambiguous call syntax across lines.
local ok, err = pcall(__loadfile, ROOT)
if not ok then
	error(err)
end
