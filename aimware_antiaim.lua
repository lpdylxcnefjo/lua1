-- Aimware CS2 - Anti-Aim Builder
-- Yaw Base:
--   Local View - yaw stays around the local view, shaped by Offset + Modifier.
--   Auto Yaw   - built-in tuned values per weapon class + movement state.
-- Yaw Offset shifts the base yaw; Modifier adds a jitter pattern on top.
-- Plus pitch, manual directions, conditions, on-screen indicator.
-- Sets view angles in PreMove (matches the working Aimware example).

local TAB  = gui.Reference("Ragebot", "Anti-Aim")
-- manual directions / conditions / indicator live in the Auto Peek tab
local TAB2 = gui.Reference("Ragebot", "Auto Peek")

-- ============================================================
-- constants
-- ============================================================
local STATES = { "Standing", "Moving", "Crouched", "In Air" }

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
-- Auto Yaw is always applied; this only picks the reference the yaw is built on
g.base   = gui.Combobox(TAB, "aa_base",   "Yaw Base", "Local View", "At Target")

-- yaw offset shifts the base yaw (0 = the base value itself)
g.yaw_offset = gui.Slider(TAB, "aa_yaw_offset", "Yaw Offset", 0, -180, 180, 0.1)

-- modifier: jitter pattern applied on top of the base yaw
g.modifier   = gui.Combobox(TAB, "aa_modifier", "Modifier", "Disabled", "Center", "Offset", "3-Way", "5-Way", "Anti-Nixware")
g.mod_left   = gui.Slider  (TAB, "aa_mod_left",   "Modifier Left",   0, 0, 180, 0.1)
g.mod_right  = gui.Slider  (TAB, "aa_mod_right",  "Modifier Right",  0, 0, 180, 0.1)
g.mod_offset = gui.Slider  (TAB, "aa_mod_offset", "Modifier Offset", 60, -180, 180, 0.1)
g.mod_3way   = gui.Slider  (TAB, "aa_mod_3way",   "Modifier Range",  45, 0, 180, 0.1)
g.mod_5way   = gui.Slider  (TAB, "aa_mod_5way",   "Modifier Range",  45, 0, 180, 0.1)
g.mod_delay  = gui.Slider  (TAB, "aa_mod_delay",  "Modifier Delay",   4, 1, 32, 1)
g.mod_random = gui.Checkbox(TAB, "aa_mod_random", "Modifier Random", false)

-- pitch
g.pitch       = gui.Combobox(TAB, "aa_pitch",       "Pitch", "Disabled", "Down", "Up", "Jitter", "Zero", "Fake Down", "Custom")
g.pitch_value = gui.Slider  (TAB, "aa_pitch_value", "Pitch Offset", -89, -89, 89, 0.1)

-- manual directions (Auto Peek tab)
g.key_right   = gui.Keybox(TAB2, "aa_key_right",   "Manual Right",   0)
g.key_left    = gui.Keybox(TAB2, "aa_key_left",    "Manual Left",    0)
g.key_forward = gui.Keybox(TAB2, "aa_key_forward", "Manual Forward", 0)
g.fwd_mode    = gui.Combobox(TAB2, "aa_fwd_mode",   "Forward: Mode", "Toggle", "Hold")

-- brief jitter at the moment a manual direction is switched
g.switch_jitter = gui.Checkbox(TAB2, "aa_switch_jitter", "Manual Switch Jitter", true)

-- conditions
g.on_ladder    = gui.Checkbox(TAB2, "aa_on_ladder",    "Disable on Ladder",  true)
g.on_use       = gui.Checkbox(TAB2, "aa_on_use",       "Disable on Use",     true)
g.disable_shot = gui.Checkbox(TAB2, "aa_disable_shot", "Disable on Shot",    true)
g.anti_invalid = gui.Checkbox(TAB2, "aa_anti_invalid", "Anti-Invalid Angle", true)
g.indicator    = gui.Checkbox(TAB2, "aa_indicator",    "Indicator",          true)

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
local cur_target = false -- At Target: enemy found this frame
local rand_phase = -1 -- last phase a random way value was picked for
local rand_idx   = 0

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

-- yaw that points at the nearest alive enemy (nil if none found)
local function target_yaw(lp)
	local best, best_d
	local my = lp:GetAbsOrigin()
	local myteam = field_int(lp, "m_iTeamNum")
	for _, cls in ipairs({ "CCSPlayer", "C_CSPlayerPawn", "CCSPlayerPawn" }) do
		local ok, list = pcall(function() return entities.FindByClass(cls) end)
		if ok and list then
			for i = 1, #list do
				local e = list[i]
				local alive = false
				pcall(function() alive = e ~= lp and e:IsAlive() end)
				if alive then
					local t = field_int(e, "m_iTeamNum")
					if myteam == 0 or t == 0 or t ~= myteam then
						local ok2, d = pcall(function()
							local p = e:GetAbsOrigin()
							return (p.x - my.x) ^ 2 + (p.y - my.y) ^ 2 + (p.z - my.z) ^ 2
						end)
						if ok2 and d and (not best_d or d < best_d) then
							best, best_d = e, d
						end
					end
				end
			end
			if best then break end
		end
	end
	if not best then return nil end
	local ya
	local ok = pcall(function()
		local dir = best:GetAbsOrigin() - my
		ya = dir:Angles().y
	end)
	if ok and ya then return ya end
	return nil
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

-- modifier jitter offset (added on top of the base yaw). the Delay slider sets
-- how many ticks each step lasts (higher = slower jitter).
local function modifier_jitter(tick)
	local m = g.modifier:GetValue() -- 0 Disabled,1 Center,2 Offset,3 3-Way,4 5-Way,5 Anti-Nixware
	if m == 0 then return 0 end
	local phase = math.floor(tick / math.max(1, g.mod_delay:GetValue()))
	if m == 1 then -- Center: alternate -left / +right
		return ((phase % 2) == 0) and -g.mod_left:GetValue() or g.mod_right:GetValue()
	elseif m == 2 then -- Offset: alternate 0 / offset
		return ((phase % 2) == 0) and 0 or g.mod_offset:GetValue()
	elseif m == 3 or m == 4 then -- 3-Way / 5-Way
		local vals
		if m == 3 then
			local a = g.mod_3way:GetValue()
			vals = { -a, 0, a }
		else
			local a = g.mod_5way:GetValue()
			vals = { -a, -a / 2, 0, a / 2, a }
		end
		local idx
		if g.mod_random:GetValue() then -- pick a random way per step
			if phase ~= rand_phase then
				rand_phase = phase
				rand_idx = math.random(1, #vals)
			end
			idx = rand_idx
		else -- go through the ways in order
			idx = (phase % #vals) + 1
		end
		return vals[idx]
	end
	return 0 -- Anti-Nixware (logic TBD)
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
	local state  = current_state(lp, cmd)
	local wclass = weapon_class(lp)
	local bmode  = g.base:GetValue() -- 0 Local View, 1 At Target
	local has_target = false
	local base = pre_va.y -- local view
	if bmode == 1 then
		local ty = target_yaw(lp)
		if ty then base = ty; has_target = true end
	end

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
	else
		-- Auto Yaw is always on: tuned per-weapon/state value (= 0 on the slider)
		-- + Yaw Offset + Modifier jitter, built on the chosen base reference.
		goal = AUTO_YAW[wclass][state] + g.yaw_offset:GetValue() + modifier_jitter(tick)
	end

	-- detect a manual switch: left<->right rotates through the back
	if manual ~= prev_manual then
		if manual == 1 or manual == 2 then
			sweep_from  = cur_off
			sweep_to    = sweep_target(cur_off, goal)
			sweep_start = tick
		end
		if manual ~= 0 then switch_tick = tick end
		prev_manual = manual
	end

	if (manual == 1 or manual == 2) and (tick - sweep_start) < SWEEP_TICKS then
		local p = (tick - sweep_start) / SWEEP_TICKS
		cur_off = sweep_from + (sweep_to - sweep_from) * p
	else
		cur_off = cur_off + wrap180(goal - cur_off) -- track shortest
	end
	va.y = base + cur_off

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
	cur_target = has_target
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

local function handle_forward()
	local key = g.key_forward:GetValue()
	if key == 0 then return end
	if g.fwd_mode:GetValue() == 1 then -- Hold
		if input.IsButtonDown(key) then
			if manual ~= 3 then manual = 3; switch_tick = globals.TickCount() end
		elseif manual == 3 then
			manual = 0
		end
	else -- Toggle
		handle_key(g.key_forward, 3)
	end
end

local function on_draw()
	local m = g.modifier:GetValue()
	g.mod_left:SetInvisible(m ~= 1)
	g.mod_right:SetInvisible(m ~= 1)
	g.mod_offset:SetInvisible(m ~= 2)
	g.mod_3way:SetInvisible(m ~= 3)
	g.mod_5way:SetInvisible(m ~= 4)
	g.mod_delay:SetInvisible(m == 0 or m == 5)
	g.mod_random:SetInvisible(not (m == 3 or m == 4))
	g.pitch_value:SetInvisible(g.pitch:GetValue() ~= 6)

	if not g.master:GetValue() then return end

	-- manual direction toggles
	handle_key(g.key_right, 1)
	handle_key(g.key_left, 2)
	handle_forward()

	-- indicator
	if g.indicator:GetValue() then
		local cx, cy = screen_x / 2, screen_y / 2
		local dir = "AUTO"
		if manual == 1 then dir = "RIGHT"
		elseif manual == 2 then dir = "LEFT"
		elseif manual == 3 then dir = "FORWARD" end
		local bm = g.base:GetValue()
		local mode = (bm == 1) and "AT TARGET" or "LOCAL"
		draw.Color(120, 200, 255, 255)
		draw.TextShadow(cx - 60, cy + 16, "AUTO YAW: " .. mode)
		draw.TextShadow(cx - 60, cy + 31, cur_group_name .. " / " .. cur_state_name)
		draw.TextShadow(cx - 60, cy + 46, "DIR: " .. dir)
		draw.TextShadow(cx - 60, cy + 61, string.format("YAW: %.1f", cur_yaw))
		if bm == 1 then
			draw.TextShadow(cx - 60, cy + 76, "TARGET: " .. (cur_target and "YES" or "NONE"))
		end
	end
end

-- ============================================================
-- callbacks
-- ============================================================
callbacks.Register("PreMove", "aa_premove", pre_move)
callbacks.Register("Draw", "aa_draw", on_draw)
