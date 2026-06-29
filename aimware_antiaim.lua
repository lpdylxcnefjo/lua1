-- Aimware CS2 - Anti-Aim Builder
-- Per-state anti-aim (Standing / Moving / In Air), yaw modes, pitch/roll,
-- manual directions, conditions, on-screen indicator.
-- Sets view angles in PreMove (matches the working Aimware example).

local TAB = gui.Reference("Ragebot", "Anti-Aim")

-- ============================================================
-- constants
-- ============================================================
local STATES      = { "Standing", "Moving", "In Air" }
local YAW_MODES   = { "Disabled", "Static", "Jitter", "Spin", "Random" }
local IN_ATTACK   = bit.lshift(1, 0)
local ON_USE      = bit.lshift(1, 5)
local FL_ONGROUND = bit.lshift(1, 0)
local MOVETYPE_LADDER = 9
local FAKE_PITCH  = -3402823346297399750336966557696 -- fake-down exploit value

-- ============================================================
-- GUI
-- ============================================================
local g = {}

g.master   = gui.Checkbox(TAB, "aa_master",   "Enable AA Builder", false)
g.base     = gui.Combobox(TAB, "aa_base",     "Yaw Base", "Crosshair", "At Target")
g.edit     = gui.Combobox(TAB, "aa_edit",     "Edit State", unpack(STATES))

-- per-state yaw controls (only the selected state's controls are shown)
local st = {}
for i = 1, #STATES do
	local key = STATES[i]:gsub("%s", ""):lower()
	st[i] = {
		mode  = gui.Combobox(TAB, "aa_" .. key .. "_mode",  STATES[i] .. ": Mode", unpack(YAW_MODES)),
		yaw   = gui.Slider  (TAB, "aa_" .. key .. "_yaw",   STATES[i] .. ": Yaw",    180, -180, 180, 0.1),
		left  = gui.Slider  (TAB, "aa_" .. key .. "_left",  STATES[i] .. ": Left",   30, 0, 180, 0.1),
		right = gui.Slider  (TAB, "aa_" .. key .. "_right", STATES[i] .. ": Right",  30, 0, 180, 0.1),
		speed = gui.Slider  (TAB, "aa_" .. key .. "_speed", STATES[i] .. ": Jitter Speed", 4, 2, 32, 2),
		spin  = gui.Slider  (TAB, "aa_" .. key .. "_spin",  STATES[i] .. ": Spin Speed", -5, -45, 45, 0.1),
	}
end

-- pitch / roll
g.pitch       = gui.Combobox(TAB, "aa_pitch",       "Pitch", "Disabled", "Down", "Up", "Jitter", "Zero", "Fake Down", "Custom")
g.pitch_value = gui.Slider  (TAB, "aa_pitch_value", "Pitch Offset", -89, -89, 89, 0.1)
g.roll        = gui.Combobox(TAB, "aa_roll",        "Roll", "Disabled", "Static", "Wave", "Spin")
g.roll_value  = gui.Slider  (TAB, "aa_roll_value",  "Roll Offset", 0, -45, 45, 0.1)

-- manual directions
g.key_right   = gui.Keybox(TAB, "aa_key_right",   "Manual Right",   0)
g.key_left    = gui.Keybox(TAB, "aa_key_left",    "Manual Left",    0)
g.key_back    = gui.Keybox(TAB, "aa_key_back",    "Manual Back",    0)
g.key_forward = gui.Keybox(TAB, "aa_key_forward", "Manual Forward", 0)

-- conditions
g.disable_shot = gui.Checkbox(TAB, "aa_disable_shot", "Disable on Shot", true)
g.anti_invalid = gui.Checkbox(TAB, "aa_anti_invalid", "Anti-Invalid Angle", true)
g.indicator    = gui.Checkbox(TAB, "aa_indicator",    "Indicator", true)

-- ============================================================
-- state
-- ============================================================
local pre_va  = EulerAngles(0, 0, 0)
local manual  = 0 -- 0 none, 1 right, 2 left, 3 back, 4 forward
local cur_state_name = "Standing"
local cur_yaw  = 0

-- ============================================================
-- helpers
-- ============================================================
local function field_int(ent, name)
	local ok, v = pcall(function() return ent:GetFieldInt(name) end)
	if ok and v then return v end
	return 0
end

-- yaw (deg) toward the closest alive enemy, or nil
local function target_yaw(lp)
	local best, best_d
	local ok = pcall(function()
		local my_team = field_int(lp, "m_iTeamNum")
		local my_pos  = lp:GetAbsOrigin()
		local players = entities.FindByClass("CCSPlayer")
		for _, e in ipairs(players) do
			if e and e ~= lp and e:IsAlive() and field_int(e, "m_iTeamNum") ~= my_team then
				local dir = e:GetAbsOrigin() - my_pos
				local d   = dir.x * dir.x + dir.y * dir.y
				if not best_d or d < best_d then
					best_d = d
					best   = dir:Angles().y
				end
			end
		end
	end)
	if ok then return best end
	return nil
end

local function current_state(lp, cmd)
	local flags = field_int(lp, "m_fFlags")
	local on_ground = bit.band(flags, FL_ONGROUND) ~= 0
	if not on_ground then return 3 end
	if math.abs(cmd:GetForwardMove()) > 5 or math.abs(cmd:GetSideMove()) > 5 then return 2 end
	return 1
end

-- yaw produced by a state's mode, relative to the base
local function state_yaw(s, tick)
	local mode = s.mode:GetValue() -- 0 Disabled,1 Static,2 Jitter,3 Spin,4 Random
	local center = s.yaw:GetValue()
	if mode == 0 then
		return nil
	elseif mode == 1 then
		return center
	elseif mode == 2 then
		local l, r = s.left:GetValue(), s.right:GetValue()
		if l == 0 and r == 0 then return center end
		local speed = math.max(2, s.speed:GetValue())
		local phase = math.floor(tick / (speed / 2)) % 2
		return phase == 0 and (center - l) or (center + r)
	elseif mode == 3 then
		return center + (tick * s.spin:GetValue()) % 360
	elseif mode == 4 then
		local l, r = s.left:GetValue(), s.right:GetValue()
		return center + math.random() * (l + r) - l
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

	-- conditions that disable AA
	local weapon_type = lp:GetWeaponType()
	local move_type   = field_int(lp, "m_nActualMoveType")
	local buttons     = cmd:GetButtons()
	if move_type == MOVETYPE_LADDER then return end
	if bit.band(buttons, ON_USE) ~= 0 then return end
	if weapon_type == 0 or weapon_type == 9 then return end -- knife / grenade
	if g.disable_shot:GetValue() and bit.band(buttons, IN_ATTACK) ~= 0 then return end

	-- base yaw
	local base
	if g.base:GetValue() == 1 then
		base = target_yaw(lp) or (pre_va.y + 180)
	else
		base = pre_va.y
	end

	local va   = cmd:GetViewAngles()
	local tick = globals.TickCount()

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
		local s = st[current_state(lp, cmd)]
		local off = state_yaw(s, tick)
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

	-- roll (camera)
	local rm = g.roll:GetValue() -- 0 Disabled,1 Static,2 Wave,3 Spin
	if rm == 1 then
		va.z = g.roll_value:GetValue()
	elseif rm == 2 then
		va.z = math.sin(tick / 100) * 45
	elseif rm == 3 then
		va.z = (tick * 1) % 360
	end

	-- anti-invalid clamp
	if g.anti_invalid:GetValue() then
		if va.y > 180 then va.y = va.y - 360 elseif va.y < -180 then va.y = va.y + 360 end
		if va.x > 89 then va.x = 89 elseif va.x < -89 then va.x = -89 end
		if va.z ~= 0 then va.z = 0 end
	end

	cur_state_name = STATES[current_state(lp, cmd)]
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
	-- show only the selected state's yaw controls
	local sel = g.edit:GetValue() + 1
	for i = 1, #STATES do
		local hidden = (i ~= sel)
		st[i].mode:SetInvisible(hidden)
		st[i].yaw:SetInvisible(hidden)
		st[i].left:SetInvisible(hidden)
		st[i].right:SetInvisible(hidden)
		st[i].speed:SetInvisible(hidden)
		st[i].spin:SetInvisible(hidden)
	end
	g.pitch_value:SetInvisible(g.pitch:GetValue() ~= 6)
	g.roll_value:SetInvisible(g.roll:GetValue() == 0)

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
		draw.TextShadow(cx - 60, cy + 16, "AA: " .. cur_state_name)
		draw.TextShadow(cx - 60, cy + 31, "DIR: " .. dir)
		draw.TextShadow(cx - 60, cy + 46, string.format("YAW: %.1f", cur_yaw))
	end
end

-- ============================================================
-- callbacks
-- ============================================================
callbacks.Register("PreMove", "aa_premove", pre_move)
callbacks.Register("Draw", "aa_draw", on_draw)
