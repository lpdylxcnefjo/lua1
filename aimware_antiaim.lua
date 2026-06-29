-- Aimware CS2 - Anti-Aim Builder
-- Per weapon-group (Pistols / Heavy Pistols / Rifles & Snipers) and per movement
-- state (Standing / Moving / Crouched / In Air) yaw config, plus pitch, manual
-- directions, conditions, on-screen indicator.
-- Sets view angles in PreMove (matches the working Aimware example).

local TAB = gui.Reference("Ragebot", "Anti-Aim")

-- ============================================================
-- constants
-- ============================================================
local GROUPS    = { "Pistols", "Heavy Pistols", "Rifles & Snipers" }
local STATES    = { "Standing", "Moving", "Crouched", "In Air" }
local YAW_MODES = { "Disabled", "Static", "Jitter", "Spin" }

local IN_ATTACK   = bit.lshift(1, 0)
local IN_FORWARD  = bit.lshift(1, 3)
local IN_BACK     = bit.lshift(1, 4)
local ON_USE      = bit.lshift(1, 5)
local IN_LEFT     = bit.lshift(1, 9)
local IN_RIGHT    = bit.lshift(1, 10)
local MOVE_BITS   = IN_FORWARD + IN_BACK + IN_LEFT + IN_RIGHT
local FL_ONGROUND = bit.lshift(1, 0)
local FL_DUCKING  = bit.lshift(1, 1)
local MOVETYPE_LADDER = 9
local FAKE_PITCH  = -3402823346297399750336966557696 -- fake-down exploit value

-- ====== weapon -> group mapping (EDIT ME) ===================
-- GetWeaponType() category ints (CS standard): 0 knife, 1 pistol, 2 smg,
-- 3 rifle, 4 shotgun, 5 sniper, 6 machinegun, 7 c4, 9 grenade.
-- Heavy pistols (Deagle / R8) share category 1 with light pistols and need the
-- specific weapon id to separate -- left to fill once that accessor is known.
local TYPE_TO_GROUP = {
	[1] = 1, -- pistols
	[2] = 3, -- smg     -> rifles & snipers
	[3] = 3, -- rifle   -> rifles & snipers
	[4] = 3, -- shotgun -> rifles & snipers
	[5] = 3, -- sniper  -> rifles & snipers
	[6] = 3, -- mg      -> rifles & snipers
}
-- specific weapon ids that should map to "Heavy Pistols" (fill when known)
local HEAVY_PISTOL_IDS = { --[[ [1] = true, [64] = true ]] }

-- ============================================================
-- GUI
-- ============================================================
local g = {}

g.master = gui.Checkbox(TAB, "aa_master", "Enable AA Builder", false)
g.base   = gui.Combobox(TAB, "aa_base",   "Yaw Base", "Local View", "At Target", "Auto Yaw")
g.egroup = gui.Combobox(TAB, "aa_egroup", "Edit Group", unpack(GROUPS))
g.estate = gui.Combobox(TAB, "aa_estate", "Edit State", unpack(STATES))

-- per group + per state yaw controls (only the selected pair is shown)
local st = {}
for gi = 1, #GROUPS do
	st[gi] = {}
	local gkey = GROUPS[gi]:gsub("[%s&]", ""):lower()
	for si = 1, #STATES do
		local skey = STATES[si]:gsub("%s", ""):lower()
		local p = "aa_" .. gkey .. "_" .. skey .. "_"
		-- labels must be unique across the whole tab (duplicate display names
		-- break GetValue / SetInvisible targeting), so prefix with the group.
		local label = GROUPS[gi] .. " " .. STATES[si] .. ": "
		st[gi][si] = {
			mode  = gui.Combobox(TAB, p .. "mode",  label .. "Mode", unpack(YAW_MODES)),
			yaw   = gui.Slider  (TAB, p .. "yaw",   label .. "Yaw",          180, -180, 180, 0.1),
			left  = gui.Slider  (TAB, p .. "left",  label .. "Left",          30, 0, 180, 0.1),
			right = gui.Slider  (TAB, p .. "right", label .. "Right",         30, 0, 180, 0.1),
			speed = gui.Slider  (TAB, p .. "speed", label .. "Jitter Speed",   4, 2, 32, 2),
			spin  = gui.Slider  (TAB, p .. "spin",  label .. "Spin Speed",    -5, -45, 45, 0.1),
		}
	end
end

-- pitch
g.pitch       = gui.Combobox(TAB, "aa_pitch",       "Pitch", "Disabled", "Down", "Up", "Jitter", "Zero", "Fake Down", "Custom")
g.pitch_value = gui.Slider  (TAB, "aa_pitch_value", "Pitch Offset", -89, -89, 89, 0.1)

-- manual directions
g.key_right   = gui.Keybox(TAB, "aa_key_right",   "Manual Right",   0)
g.key_left    = gui.Keybox(TAB, "aa_key_left",    "Manual Left",    0)
g.key_back    = gui.Keybox(TAB, "aa_key_back",    "Manual Back",    0)
g.key_forward = gui.Keybox(TAB, "aa_key_forward", "Manual Forward", 0)

-- conditions
g.on_ladder    = gui.Checkbox(TAB, "aa_on_ladder",    "Disable on Ladder",  true)
g.on_use       = gui.Checkbox(TAB, "aa_on_use",       "Disable on Use",     true)
g.disable_shot = gui.Checkbox(TAB, "aa_disable_shot", "Disable on Shot",    true)
g.anti_invalid = gui.Checkbox(TAB, "aa_anti_invalid", "Anti-Invalid Angle", true)
g.indicator    = gui.Checkbox(TAB, "aa_indicator",    "Indicator",          true)

-- ============================================================
-- state
-- ============================================================
local pre_va = EulerAngles(0, 0, 0)
local manual = 0 -- 0 none, 1 right, 2 left, 3 back, 4 forward
local cur_state_name = "Standing"
local cur_group_name = "Pistols"
local cur_yaw = 0
local cur_target = false

-- ============================================================
-- helpers
-- ============================================================
local function field_int(ent, name)
	local ok, v = pcall(function() return ent:GetFieldInt(name) end)
	if ok and v then return v end
	return 0
end

-- yaw (deg) toward the closest alive enemy, or nil.
-- Prefers an opposing-team player, but if the team field can't be read in this
-- build it falls back to the nearest non-local alive player (the duel target).
local function target_yaw(lp)
	local best_enemy, best_enemy_d
	local best_any,   best_any_d
	pcall(function()
		local my_team = field_int(lp, "m_iTeamNum")
		local my_pos  = lp:GetAbsOrigin()
		local players = entities.FindByClass("CCSPlayer")
		for i = 1, #players do
			local e = players[i]
			if e and e ~= lp and e:IsAlive() then
				local dir = e:GetAbsOrigin() - my_pos
				local d   = dir.x * dir.x + dir.y * dir.y
				if d > 1 then
					local yaw = dir:Angles().y
					local et  = field_int(e, "m_iTeamNum")
					if my_team ~= 0 and et ~= 0 and et ~= my_team then
						if not best_enemy_d or d < best_enemy_d then best_enemy_d = d; best_enemy = yaw end
					end
					if not best_any_d or d < best_any_d then best_any_d = d; best_any = yaw end
				end
			end
		end
	end)
	return best_enemy or best_any
end

local function weapon_group(lp)
	local wt = 1
	pcall(function() wt = lp:GetWeaponType() end)
	if wt == 1 then
		-- heavy pistol separation needs the specific weapon id (see above)
		return 1
	end
	return TYPE_TO_GROUP[wt] or 3
end

local function current_state(lp, cmd)
	local flags = field_int(lp, "m_fFlags")
	if bit.band(flags, FL_ONGROUND) == 0 then return 4 end -- In Air
	if bit.band(flags, FL_DUCKING) ~= 0 then return 3 end  -- Crouched
	local buttons = cmd:GetButtons()
	if bit.band(buttons, MOVE_BITS) ~= 0
		or math.abs(cmd:GetForwardMove()) > 5 or math.abs(cmd:GetSideMove()) > 5 then
		return 2 -- Moving
	end
	return 1 -- Standing
end

-- yaw produced by a state's mode, relative to the base; nil = leave native yaw
local function state_yaw(s, tick)
	local mode = s.mode:GetValue() -- 0 Disabled,1 Static,2 Jitter,3 Spin
	local center = s.yaw:GetValue()
	if mode == 1 then
		return center
	elseif mode == 2 then
		local l, r = s.left:GetValue(), s.right:GetValue()
		if l == 0 and r == 0 then return center end
		local speed = math.max(2, s.speed:GetValue())
		local phase = math.floor(tick / (speed / 2)) % 2
		return phase == 0 and (center - l) or (center + r)
	elseif mode == 3 then
		return center + (tick * s.spin:GetValue()) % 360
	end
	return nil
end

-- ============================================================
-- main anti-aim
-- ============================================================
local function pre_move(cmd)
	pre_va = cmd:GetViewAngles()
	if not g.master:GetValue() then return end

	local lp = entities.GetLocalPlayer()
	if not lp or not lp:IsAlive() then return end

	local move_type = field_int(lp, "m_nActualMoveType")
	local buttons   = cmd:GetButtons()
	if g.on_ladder:GetValue() and move_type == MOVETYPE_LADDER then return end
	if g.on_use:GetValue() and bit.band(buttons, ON_USE) ~= 0 then return end
	if g.disable_shot:GetValue() and bit.band(buttons, IN_ATTACK) ~= 0 then return end

	-- base yaw
	local base_mode = g.base:GetValue() -- 0 Local View, 1 At Target, 2 Auto Yaw
	local base
	if base_mode == 1 then
		local ty = target_yaw(lp)
		cur_target = ty ~= nil
		base = ty or (pre_va.y + 180)
	else
		cur_target = false
		base = pre_va.y -- Local View / Auto Yaw both build off local view
	end

	local va    = cmd:GetViewAngles()
	local tick  = globals.TickCount()
	local group = weapon_group(lp)
	local state = current_state(lp, cmd)

	-- yaw: manual override takes precedence over the per-state mode
	if manual == 1 then
		va.y = base - 90
	elseif manual == 2 then
		va.y = base + 90
	elseif manual == 3 then
		va.y = base + 180
	elseif manual == 4 then
		va.y = base
	else
		local off = state_yaw(st[group][state], tick)
		if off == nil then
			va.y = pre_va.y -- mode Disabled: leave native yaw untouched
		else
			va.y = base + off
		end
	end

	-- pitch
	local pm = g.pitch:GetValue() -- 0 Disabled,1 Down,2 Up,3 Jitter,4 Zero,5 Fake,6 Custom
	if pm == 1 then
		va.x = 89
	elseif pm == 2 then
		va.x = -89
	elseif pm == 3 then
		va.x = (tick % 2 == 0) and 89 or -89
	elseif pm == 4 then
		va.x = 0
	elseif pm == 5 then
		va.x = FAKE_PITCH
	elseif pm == 6 then
		va.x = g.pitch_value:GetValue()
	end

	-- anti-invalid clamp
	if g.anti_invalid:GetValue() then
		if va.y > 180 then va.y = va.y - 360 elseif va.y < -180 then va.y = va.y + 360 end
		if va.x > 89 then va.x = 89 elseif va.x < -89 then va.x = -89 end
	end
	va.z = 0

	cur_group_name = GROUPS[group]
	cur_state_name = STATES[state]
	cur_yaw = va.y
	cmd:SetViewAngles(va)
end

-- ============================================================
-- input + UI visibility + indicator
-- ============================================================
local function handle_key(keybox, id)
	local key = keybox:GetValue()
	if key ~= 0 and input.IsButtonPressed(key) then
		manual = (manual == id) and 0 or id
	end
end

local screen_x, screen_y = draw.GetScreenSize()

local function on_draw()
	-- show only the selected group+state controls, and only the ones its mode uses
	local sg = g.egroup:GetValue() + 1
	local ss = g.estate:GetValue() + 1
	for gi = 1, #GROUPS do
		for si = 1, #STATES do
			local s = st[gi][si]
			local shown = (gi == sg and si == ss)
			local mode  = s.mode:GetValue() -- 0 Disabled,1 Static,2 Jitter,3 Spin
			s.mode:SetInvisible(not shown)
			s.yaw:SetInvisible(not (shown and mode ~= 0))
			s.left:SetInvisible(not (shown and mode == 2))
			s.right:SetInvisible(not (shown and mode == 2))
			s.speed:SetInvisible(not (shown and mode == 2))
			s.spin:SetInvisible(not (shown and mode == 3))
		end
	end
	g.pitch_value:SetInvisible(g.pitch:GetValue() ~= 6)

	if not g.master:GetValue() then return end

	-- manual direction toggles
	handle_key(g.key_right, 1)
	handle_key(g.key_left, 2)
	handle_key(g.key_back, 3)
	handle_key(g.key_forward, 4)

	-- indicator
	if g.indicator:GetValue() then
		local cx, cy = screen_x / 2, screen_y / 2
		local dir = "AUTO"
		if manual == 1 then dir = "RIGHT"
		elseif manual == 2 then dir = "LEFT"
		elseif manual == 3 then dir = "BACK"
		elseif manual == 4 then dir = "FORWARD" end
		draw.Color(120, 200, 255, 255)
		draw.TextShadow(cx - 60, cy + 16, "AA: " .. cur_group_name)
		draw.TextShadow(cx - 60, cy + 31, "STATE: " .. cur_state_name)
		draw.TextShadow(cx - 60, cy + 46, "DIR: " .. dir)
		draw.TextShadow(cx - 60, cy + 61, string.format("YAW: %.1f", cur_yaw))
		if g.base:GetValue() == 1 then
			draw.TextShadow(cx - 60, cy + 76, "TARGET: " .. (cur_target and "YES" or "NONE"))
		end
	end
end

-- ============================================================
-- callbacks
-- ============================================================
callbacks.Register("PreMove", "aa_premove", pre_move)
callbacks.Register("Draw", "aa_draw", on_draw)
