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
-- extra duck peek assist keybox lives in Ragebot > Main
local TABM = gui.Reference("Ragebot", "Main")

-- ============================================================
-- constants
-- ============================================================
local STATES = { "Standing", "Moving", "Crouched", "In Air" }

local IN_ATTACK   = bit.lshift(1, 0)
local IN_JUMP     = bit.lshift(1, 1)
local IN_DUCK     = bit.lshift(1, 2)
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

local DUCK_COOLDOWN_TICKS = 96 -- ~1.5s re-crouch after a shot (64 tick)

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

-- extra duck peek assist (Ragebot > Main): hold the bind and you stay crouched,
-- standing up automatically whenever an enemy is on screen (Shadow-style, but
-- without bullet-trace damage which this API can't do)
g.duck_peek    = gui.Keybox(TABM, "aa_duck_peek", "Duck Peek Assist+", 0)

-- locate the native "Duck Peek assist" keybind (Ragebot > Main) so we can read
-- the key the user bound there and drive the duck ourselves
local function find_child(obj, name)
	local found
	pcall(function()
		for child in obj:Children() do
			if child:GetName() == name then found = child; return end
			local sub = find_child(child, name)
			if sub then found = sub; return end
		end
	end)
	return found
end

local native_duck
pcall(function()
	native_duck = find_child(gui.Reference("Ragebot", "Main"), "Duck Peek assist")
end)

-- ============================================================
-- state
-- ============================================================
local pre_va = EulerAngles(0, 0, 0)
local duck_can_peek = false -- Duck Peek: enemy in view (computed in Draw)
local duck_active   = false -- Duck Peek: bind held
local duck_cd_until = 0     -- Duck Peek: re-crouch until this tick after a shot
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

-- pull origin as plain numbers (nil if unavailable / at world origin)
local function origin_of(e)
	local ok, p = pcall(function() return e:GetAbsOrigin() end)
	if not ok or not p then return nil end
	if p.x == 0 and p.y == 0 and p.z == 0 then return nil end
	return p
end

-- The cheat calls DrawESP for every player it draws (the actual players in this
-- build - FindByClass("CCSPlayer") returns nothing here). We collect those
-- entities each ESP pass and target from them. Weapons are filtered out by
-- requiring health, and we cache the last enemy so turning away (which stops
-- the ESP draw for that player) doesn't instantly drop the target.
local TARGET_HOLD_TICKS = 512 -- keep last target this long after it leaves ESP (~8s)
local esp_targets   = {} -- entities from the last completed ESP pass
local esp_frame     = {} -- staging for the current pass
local esp_last_tick = -1
local last_target   = nil -- remembered enemy entity
local last_target_t = -1000
local last_target_p = nil -- last good position of the remembered enemy
local target_count  = 0  -- live enemies seen last pass (for the indicator)

local function is_live_player(e)
	local alive = false
	pcall(function() alive = e:IsAlive() end)
	if not alive and field_int(e, "m_iHealth") <= 0 then return false end
	-- players have health; dropped weapons / props don't
	if field_int(e, "m_iHealth") <= 0 then return false end
	return true
end

local function on_draw_esp(builder)
	local ok, e = pcall(function() return builder:GetEntity() end)
	if not ok or not e then return end
	local t = globals.TickCount()
	if t ~= esp_last_tick then -- new frame -> publish previous pass, start fresh
		esp_targets = esp_frame
		esp_frame = {}
		esp_last_tick = t
	end
	esp_frame[#esp_frame + 1] = e
end

-- yaw that points at the nearest live enemy player (nil if none found / cached)
local function target_yaw(lp)
	local my = origin_of(lp)
	if not my then return nil end
	local myteam = field_int(lp, "m_iTeamNum")
	local now = globals.TickCount()
	local best_e, best_p, best_d
	target_count = 0
	for i = 1, #esp_targets do
		local e = esp_targets[i]
		if e ~= lp and is_live_player(e) then
			local t = field_int(e, "m_iTeamNum")
			local enemy = not (myteam ~= 0 and t ~= 0 and t == myteam)
			local p = enemy and origin_of(e) or nil
			if p then
				target_count = target_count + 1
				local d2 = (p.x - my.x) ^ 2 + (p.y - my.y) ^ 2 + (p.z - my.z) ^ 2
				if d2 > 1 and (not best_d or d2 < best_d) then
					best_e, best_p, best_d = e, p, d2
				end
			end
		end
	end
	-- nothing visible this pass: keep the last enemy for a while (re-read its
	-- position, or use the last good one if it went stale off-screen)
	if not best_p and last_target and (now - last_target_t) <= TARGET_HOLD_TICKS then
		best_p = origin_of(last_target) or last_target_p
	end
	if best_e then last_target = best_e; last_target_t = now; last_target_p = best_p end
	if not best_p then return nil end
	local ya
	local ok = pcall(function() ya = (best_p - my):Angles().y end)
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
-- force crouch (try the method API, fall back to the field API)
local function force_duck(cmd)
	local ok = pcall(function()
		local b = cmd:GetButtons()
		if bit.band(b, IN_DUCK) == 0 then cmd:SetButtons(b + IN_DUCK) end
	end)
	if not ok then pcall(function() cmd.in_duck = true end) end
end

-- is a live enemy on screen (in front of you) within a centred FOV box and
-- `range` units? used by Duck Peek Auto to decide when to stand up. We use the
-- actual screen projection instead of raw angles - reliable and FOV-correct.
local function enemy_in_view(lp, fov, range)
	local my = origin_of(lp)
	if not my then return false end
	local myteam = field_int(lp, "m_iTeamNum")
	local range2 = (range > 0) and (range * range) or nil
	local sx, sy
	pcall(function() sx, sy = draw.GetScreenSize() end)
	if not sx or not sy then sx, sy = 1920, 1080 end
	local cx, cy = sx / 2, sy / 2
	local frac = math.max(1, fov) / 180 -- fov 180 = whole screen, 30 = centre
	local hx, hy = (sx / 2) * frac, (sy / 2) * frac
	for i = 1, #esp_targets do
		local e = esp_targets[i]
		if e ~= lp and is_live_player(e) then
			local t = field_int(e, "m_iTeamNum")
			if not (myteam ~= 0 and t ~= 0 and t == myteam) then
				local p = origin_of(e)
				if p then
					local d2 = (p.x - my.x) ^ 2 + (p.y - my.y) ^ 2 + (p.z - my.z) ^ 2
					if not range2 or d2 <= range2 then
						local px, py
						pcall(function() px, py = client.WorldToScreen(p) end)
						-- valid (in front) and inside the FOV box around the centre
						if px and py and px == px and py == py
							and math.abs(px - cx) <= hx and math.abs(py - cy) <= hy then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

local function pre_move(cmd)
	pre_va = cmd:GetViewAngles()

	-- duck peek assist (bind held). while active: stay crouched and crawl when
	-- you're moving (no need to stand in the open); only stand to peek when you
	-- stop (parked behind cover) AND an enemy is on screen. After a shot we
	-- re-crouch and wait ~1.5s. Independent of the AA builder.
	if duck_active then
		local in_cd = globals.TickCount() < duck_cd_until
		local b = cmd:GetButtons()
		local moving = bit.band(b, MOVE_BITS) ~= 0
			or math.abs(cmd:GetForwardMove()) > 5 or math.abs(cmd:GetSideMove()) > 5
		local want_stand = duck_can_peek and not moving and not in_cd
		if not want_stand then force_duck(cmd) end
	end

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

	-- pitch value + how "down" it is (1 = full down -> full Auto Yaw,
	-- 0 = level/up -> straight yaw). Auto Yaw is scaled by this factor.
	local pm = g.pitch:GetValue() -- 0 Disabled,1 Down,2 Up,3 Jitter,4 Zero,5 Fake,6 Custom
	local pitch_val, pfactor
	if pm == 1 then     pitch_val = 89;  pfactor = 1
	elseif pm == 2 then pitch_val = -89; pfactor = 0
	elseif pm == 3 then pitch_val = (tick % 2 == 0) and 89 or -89; pfactor = (pitch_val > 0) and 1 or 0
	elseif pm == 4 then pitch_val = 0;   pfactor = 0
	elseif pm == 5 then pitch_val = FAKE_PITCH; pfactor = 1 -- fake down
	elseif pm == 6 then pitch_val = g.pitch_value:GetValue(); pfactor = math.max(0, math.min(1, pitch_val / 89))
	else                pitch_val = nil; pfactor = math.max(0, math.min(1, pre_va.x / 89)) end -- Disabled: keep player's pitch

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
		-- Auto Yaw is always on. Pitch blends the yaw: full down = tuned
		-- per-weapon/state value, level/up = straight back (+/-180). + Yaw
		-- Offset + Modifier jitter, built on the chosen base reference.
		local av   = AUTO_YAW[wclass][state]
		local back = (av < 0) and -180 or 180
		goal = back + (av - back) * pfactor + g.yaw_offset:GetValue() + modifier_jitter(tick)
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

	-- apply pitch (nil = Disabled -> keep the player's pitch)
	if pitch_val ~= nil then va.x = pitch_val end

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

	-- Duck Peek: hold the bind to activate (sits + auto stands while held).
	-- Read our keybox, or fall back to the native "Duck Peek assist".
	local dk = g.duck_peek:GetValue()
	if dk == 0 and native_duck then pcall(function() dk = native_duck:GetValue() end) end
	duck_active = type(dk) == "number" and dk ~= 0 and input.IsButtonDown(dk)

	-- decide "enemy on screen" here (screen projection only works in Draw).
	-- Full FOV (180), no distance limit. Independent of the AA master.
	local dlp = entities.GetLocalPlayer()
	local alive = false
	if dlp then pcall(function() alive = dlp:IsAlive() end) end
	-- never peek/stand with a knife out - stay crouched
	duck_can_peek = alive and weapon_class(dlp) ~= "knife"
		and enemy_in_view(dlp, 180, 0)

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
			draw.TextShadow(cx - 60, cy + 76, string.format("TARGET: %s (%d)",
				cur_target and "YES" or "NONE", target_count))
		end
	end
end

-- duck peek re-crouch logic (no hitlog UI):
--   our shot           -> re-crouch ~1.5s (miss / hit-without-kill both count)
--   our shot kills      -> clear the cooldown (no need to hide, peek the next one)
local function on_event(event)
	local name = event:GetName()
	if name == "weapon_fire" then
		local ok = pcall(function()
			if client.GetPlayerIndexByUserID(event:GetInt("userid")) == client.GetLocalPlayerIndex() then
				duck_cd_until = globals.TickCount() + DUCK_COOLDOWN_TICKS
			end
		end)
		if not ok then duck_cd_until = globals.TickCount() + DUCK_COOLDOWN_TICKS end
	elseif name == "player_hurt" then
		pcall(function()
			local by_me = client.GetPlayerIndexByUserID(event:GetInt("attacker")) == client.GetLocalPlayerIndex()
			if by_me and event:GetInt("health") <= 0 then duck_cd_until = 0 end -- killed
		end)
	end
end
pcall(function() client.AllowListener("weapon_fire") end)
pcall(function() client.AllowListener("player_hurt") end)

-- ============================================================
-- callbacks
-- ============================================================
callbacks.Register("PreMove", "aa_premove", pre_move)
callbacks.Register("Draw", "aa_draw", on_draw)
callbacks.Register("DrawESP", "aa_esp", on_draw_esp)
callbacks.Register("FireGameEvent", "aa_event", on_event)
