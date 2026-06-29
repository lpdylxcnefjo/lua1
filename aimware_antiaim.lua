-- Aimware CS2 - Anti-Aim Builder
-- Yaw Base:
--   Local View - manual builder, per weapon-group x per movement state.
--   Auto Yaw   - built-in tuned values per weapon class + movement state.
-- Plus pitch, manual directions, conditions, on-screen indicator.
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

local SWITCH_JITTER_AMOUNT = 30 -- deg shake right after a manual switch
local SWITCH_JITTER_TICKS  = 2  -- how long the shake lasts
local SWEEP_TICKS          = 2  -- ticks to rotate between manuals (through back)

-- Auto Yaw: tuned yaw offset (relative to local view) per state.
-- state index: 1 Standing, 2 Moving, 3 Crouched, 4 In Air.
local AUTO_YAW = {
	knife  = { -167, -164, -169, -167 }, -- knife (GetWeaponType == 0)
	pistol = { -169, -169, -162, -173 }, -- pistols (GetWeaponType == 1)
	other  = { -145, -152, -158, -154 }, -- rifles & snipers (everything else)
}

-- Manual Left / Right yaw offset (relative to local view) per state.
-- Used in BOTH Local View and Auto Yaw. Knife uses the pistol values.
-- each entry: { left, right }; state index 1 Standing,2 Moving,3 Crouch,4 Air.
local MANUAL = {
	pistol = { { 100, -75 }, { 100, -80 }, { 111, -65 }, { 93, -78 } },
	other  = { { 124, -52 }, { 117, -67 }, { 108, -70 }, { 120, -62 } },
}

-- ============================================================
-- GUI
-- ============================================================
local g = {}

g.master = gui.Checkbox(TAB, "aa_master", "Enable AA Builder", false)
g.base   = gui.Combobox(TAB, "aa_base",   "Yaw Base", "Local View", "Auto Yaw")
g.egroup = gui.Combobox(TAB, "aa_egroup", "Edit Group", unpack(GROUPS))
g.estate = gui.Combobox(TAB, "aa_estate", "Edit State", unpack(STATES))

-- manual builder: per group + per state controls (only the selected pair shown).
-- labels are prefixed with the group so display names stay unique across the tab.
local st = {}
for gi = 1, #GROUPS do
	st[gi] = {}
	local gkey = GROUPS[gi]:gsub("[%s&]", ""):lower()
	for si = 1, #STATES do
		local skey = STATES[si]:gsub("%s", ""):lower()
		local p = "aa_" .. gkey .. "_" .. skey .. "_"
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
g.key_forward = gui.Keybox(TAB, "aa_key_forward", "Manual Forward", 0)

-- brief jitter at the moment a manual direction is switched
g.switch_jitter = gui.Checkbox(TAB, "aa_switch_jitter", "Manual Switch Jitter", true)

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
local manual = 0 -- 0 none, 1 right, 2 left, 3 forward
local prev_manual = 0
local switch_tick = -1000 -- tick of last manual switch (for the shake)
local cur_off    = 0  -- current applied yaw offset (continuous, unwrapped)
local sweep_from = 0
local sweep_to   = 0
local sweep_start = -1000 -- tick the through-back rotation started
local cur_state_name = "Standing"
local cur_group_name = "Pistols"
local cur_yaw = 0

-- ============================================================
-- helpers
-- ============================================================
local function field_int(ent, name)
	local ok, v = pcall(function() return ent:GetFieldInt(name) end)
	if ok and v then return v end
	return 0
end

-- weapon class for Auto Yaw: "knife" / "pistol" / "other"
local function weapon_class(lp)
	local wt = -1
	pcall(function() wt = lp:GetWeaponType() end)
	if wt == 0 then return "knife" end
	if wt == 1 then return "pistol" end
	return "other"
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

local function wrap180(a)
	a = a % 360
	if a > 180 then a = a - 360 end
	return a
end

-- continuous target so the rotation between manuals passes through the back
-- (~180) instead of crossing the front (0). `from` continuous, `to` wrapped.
local function sweep_target(from, to)
	local fw = wrap180(from)
	if fw >= 0 and to <= 0 then
		return from + ((to + 360) - fw) -- increase through +180
	elseif fw <= 0 and to >= 0 then
		return from + ((to - 360) - fw) -- decrease through -180
	end
	return from + (to - fw) -- same side: direct
end

-- manual-builder yaw offset (relative to base); nil = leave native yaw
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

	local va     = cmd:GetViewAngles()
	local tick   = globals.TickCount()
	local base   = pre_va.y -- local view
	local state  = current_state(lp, cmd)
	local wclass = weapon_class(lp)
	local group  = (wclass == "pistol") and 1 or 3

	-- target yaw offset for the active mode (manual offsets are tuned per weapon
	-- and state; knife -> pistol)
	local mcls = (wclass == "other") and "other" or "pistol"
	local goal
	if manual == 1 then
		goal = MANUAL[mcls][state][2] -- right
	elseif manual == 2 then
		goal = MANUAL[mcls][state][1] -- left
	elseif manual == 3 then
		goal = 0 -- forward
	elseif g.base:GetValue() == 1 then
		goal = AUTO_YAW[wclass][state] -- Auto Yaw
	else
		goal = state_yaw(st[group][state], tick) -- Local View builder (may be nil)
	end

	-- detect a manual switch: left<->right rotates through the back
	if manual ~= prev_manual then
		if (manual == 1 or manual == 2) and goal then
			sweep_from  = cur_off
			sweep_to    = sweep_target(cur_off, goal)
			sweep_start = tick
		end
		if manual ~= 0 then switch_tick = tick end
		prev_manual = manual
	end

	if goal == nil then
		va.y   = pre_va.y -- builder disabled: leave native yaw
		cur_off = 0
	else
		if (manual == 1 or manual == 2) and (tick - sweep_start) < SWEEP_TICKS then
			local p = (tick - sweep_start) / SWEEP_TICKS
			cur_off = sweep_from + (sweep_to - sweep_from) * p
		else
			cur_off = cur_off + wrap180(goal - cur_off) -- track shortest
		end
		va.y = base + cur_off
	end

	-- brief shake right after switching a manual direction
	if manual ~= 0 and g.switch_jitter:GetValue()
		and (tick - switch_tick) < SWITCH_JITTER_TICKS then
		va.y = va.y + (((tick % 2) == 0) and SWITCH_JITTER_AMOUNT or -SWITCH_JITTER_AMOUNT)
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

	cur_group_name = (wclass == "knife") and "Knife"
		or (wclass == "pistol") and "Pistols" or "Rifles & Snipers"
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
		if manual == id then
			manual = 0
		else
			manual = id
			switch_tick = globals.TickCount() -- trigger switch jitter
		end
	end
end

local screen_x, screen_y = draw.GetScreenSize()

local function on_draw()
	-- manual builder controls only matter in Local View
	local manual_mode = g.base:GetValue() == 0
	local sg = g.egroup:GetValue() + 1
	local ss = g.estate:GetValue() + 1
	g.egroup:SetInvisible(not manual_mode)
	g.estate:SetInvisible(not manual_mode)
	for gi = 1, #GROUPS do
		for si = 1, #STATES do
			local s = st[gi][si]
			local shown = manual_mode and (gi == sg and si == ss)
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
	handle_key(g.key_forward, 3)

	-- indicator
	if g.indicator:GetValue() then
		local cx, cy = screen_x / 2, screen_y / 2
		local dir = "AUTO"
		if manual == 1 then dir = "RIGHT"
		elseif manual == 2 then dir = "LEFT"
		elseif manual == 3 then dir = "FORWARD" end
		draw.Color(120, 200, 255, 255)
		draw.TextShadow(cx - 60, cy + 16, "AA: " .. (g.base:GetValue() == 1 and "AUTO" or "MANUAL"))
		draw.TextShadow(cx - 60, cy + 31, cur_group_name .. " / " .. cur_state_name)
		draw.TextShadow(cx - 60, cy + 46, "DIR: " .. dir)
		draw.TextShadow(cx - 60, cy + 61, string.format("YAW: %.1f", cur_yaw))
	end
end

-- ============================================================
-- callbacks
-- ============================================================
callbacks.Register("PreMove", "aa_premove", pre_move)
callbacks.Register("Draw", "aa_draw", on_draw)
