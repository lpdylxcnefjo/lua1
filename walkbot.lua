local bot = {}; do
    local group = ui.create("AI Bot", "Smart Bot")

    -- ============ UI (packed into table M to stay under Lua's 60-upvalue limit) ============
    local M = {}
    M.walk_to_enemy   = group:switch("Walk to enemy")
    local wg          = M.walk_to_enemy:create()
    M.stop_distance   = wg:slider("Stop distance", 50, 600, 200, 1)
    M.move_speed      = wg:slider("Move speed", 0, 450, 250, 1)
    M.look_at_enemy   = wg:switch("Look at enemy", false)
    M.look_smooth     = wg:switch("Smooth look", true)
    M.look_speed      = wg:slider("Look speed", 1, 30, 10, 1, "Max degrees turned toward the enemy per tick")
    M.look_at_enemy:set_callback(function(self)
        local v = self:get()
        M.look_smooth:visibility(v)
        M.look_speed:visibility(v and M.look_smooth:get())
    end, true)
    M.look_smooth:set_callback(function(self)
        M.look_speed:visibility(M.look_at_enemy:get() and self:get())
    end, true)

    M.nav_rays        = wg:slider("Path scan rays", 8, 128, 24, 1)
    M.scan_distance   = wg:slider("Scan distance", 100, 8192, 2400, 1)
    M.probe_distance  = wg:slider("Probe step", 80, 600, 280, 1, "Length of each probe step")
    M.enemy_bias      = wg:slider("Enemy bias", 0, 100, 70, 1)
    M.continuity      = wg:slider("Continuity bonus", 0, 200, 120, 1)
    M.turn_speed      = wg:slider("Turn speed", 3, 45, 18, 1)
    M.trace_height    = wg:slider("Trace height", 18, 64, 36, 1)
    M.corner_peek     = wg:switch("Look around corners", true)

    M.wall_fear       = wg:switch("Move away from walls", true)
    M.fear_distance   = wg:slider("Wall keep distance", 10, 150, 55, 1)
    M.push_strength   = wg:slider("Wall push strength", 0, 100, 35, 1)
    M.wall_fear:set_callback(function(self)
        local v = self:get()
        M.fear_distance:visibility(v)
        M.push_strength:visibility(v)
    end, true)

    M.avoid_ledges    = wg:switch("Avoid ledges", true)
    M.max_drop        = wg:slider("Max safe drop", 32, 512, 200, 1, "Refuse paths that drop more than this far down")
    M.avoid_ledges:set_callback(function(self)
        M.max_drop:visibility(self:get())
    end, true)

    M.wall_follow     = wg:switch("Escape when stuck", true)
    M.stuck_speed     = wg:slider("Stuck speed", 1, 100, 35, 1)
    M.commit_ticks    = wg:slider("Escape commit ticks", 8, 96, 40, 1)

    M.auto_bhop       = wg:switch("Auto bhop", true)
    M.ceiling_check   = wg:switch("Don't jump under ceiling", true)
    M.ceiling_clear   = wg:slider("Ceiling clearance", 4, 64, 24, 1)
    M.ceiling_check:set_callback(function(self)
        M.ceiling_clear:visibility(self:get())
    end, true)
    M.jump_obstacles  = wg:switch("Jump obstacles", true)
    M.crouch_gaps     = wg:switch("Auto crouch", true)
    M.use_ladders     = wg:switch("Use ladders", true)

    M.combat_enable   = wg:switch("Auto combat", true)
    M.fire_min_damage = wg:slider("Fire min damage", 1, 120, 10, 1)
    M.crouch_on_fire  = wg:switch("Crouch when can hit", true)
    M.auto_dt         = wg:switch("Auto Double Tap", true)
    M.auto_airlag     = wg:switch("Auto air lag exploit", true)

    M.draw_nav        = wg:switch("Draw navigation", true)

    M.record_key      = group:hotkey("Record (hold)", 0x52)
    M.play_trigger    = group:combo("Replay trigger", "Enemy near", "Hotkey", "Auto on approach")
    M.play_key        = group:hotkey("Replay key", 0x54)
    M.trigger_dist    = group:slider("Trigger distance", 50, 1500, 400, 1)
    M.loop_replay     = group:switch("Loop replay", false)
    M.max_rec_frames  = group:slider("Max record frames", 256, 16384, 4096, 1, "Stop recording past this many frames")
    M.clear_btn       = group:button("Clear recording")

    M.play_trigger:set_callback(function(self)
        local v = self:get()
        M.play_key:visibility(v == "Hotkey")
        M.trigger_dist:visibility(v == "Enemy near" or v == "Auto on approach")
    end, true)

    -- cheat references
    M.is_dt    = ui.find("Aimbot", "Ragebot", "Main", "Double Tap")
    M.fl_limit = ui.find("Aimbot", "Ragebot", "Main", "Double Tap", "Fake Lag Limit")

    -- ============ STATE (packed into table S) ============
    local S = {
        recorded = {},
        is_recording = false,
        is_replaying = false,
        replay_index = 1,
        last_rec_key = false,
        last_play_key = false,
        predicted_path = {},
        last_predict_tick = 0,
        cached_desired = nil,
        last_choose_tick = 0,
        cached_need_jump = false,
        cached_need_crouch = false,
        cached_headroom = true,
        last_vert_tick = 0,
        persisted_dir = nil,
        stuck_counter = 0,
        escape_dir = nil,
        escape_until = 0,
        airlag_state = true,
    }

    M.clear_btn:set_callback(function()
        S.recorded = {}
        S.is_replaying = false
        S.replay_index = 1
    end)

    local FL_ONGROUND = 1
    local MOVETYPE_LADDER = 9

    -- ============ HELPERS ============
    local function reset_overrides()
        if M.is_dt then M.is_dt:override() end
        if M.fl_limit then M.fl_limit:override() end
    end

    local function get_closest_enemy(lp)
        local enemies = entity.get_players(true)
        if not enemies then return nil end
        local mo = lp:get_origin()
        local bd, b = math.huge, nil
        for i = 1, #enemies do
            local e = enemies[i]
            if e:is_alive() then
                local d = mo:dist(e:get_origin())
                if d < bd then bd, b = d, e end
            end
        end
        return b, bd
    end

    local function rotate_dir(dir, deg)
        local r = math.rad(deg)
        local c, s = math.cos(r), math.sin(r)
        return vector(dir.x * c - dir.y * s, dir.x * s + dir.y * c, 0)
    end

    local function signed_angle(a, b)
        local dot = a.x * b.x + a.y * b.y
        local det = a.x * b.y - a.y * b.x
        return math.deg(math.atan2(det, dot))
    end

    local function rotate_towards(from, to, max_step)
        local ang = signed_angle(from, to)
        local step = math.max(-max_step, math.min(max_step, ang))
        return rotate_dir(from, step)
    end

    local function trace_world(from, to, lp)
        local tr = utils.trace_line(from, to, lp, nil, 1)
        return tr.fraction
    end

    -- body-width footprint so navigation respects the player's ~32u hull and
    -- won't try to squeeze through gaps/corners a thin ray falsely reports open.
    -- Three sweeps cover the whole body column (feet-above-step / torso / head)
    -- so passages blocked at any height are detected, not just at the waist.
    local NAV_HULL_MIN = vector(-16, -16, 0)
    local NAV_HULL_MAX = vector(16, 16, 18)
    local NAV_ANCHORS  = { 18, 36, 54 } -- feet (above 18u step) / body / head, from feet
    local function trace_path(from, to, lp)
        local th = M.trace_height:get()
        local fz, tz = from.z - th, to.z - th -- back down to feet level
        local best = 1
        for i = 1, #NAV_ANCHORS do
            local h = NAV_ANCHORS[i]
            local fr = utils.trace_hull(
                vector(from.x, from.y, fz + h), vector(to.x, to.y, tz + h),
                NAV_HULL_MIN, NAV_HULL_MAX, lp, nil, 1).fraction
            if fr < best then best = fr end
        end
        return best
    end

    local function norm_angle(a)
        while a > 180 do a = a - 360 end
        while a < -180 do a = a + 360 end
        return a
    end

    -- distance down to solid ground beneath a point; >= max_drop means a cliff/pit
    local function ground_drop(lp, x, y, z_feet, max_drop)
        local top = vector(x, y, z_feet + 8)
        local bottom = vector(x, y, z_feet - max_drop)
        return trace_world(top, bottom, lp) * (max_drop + 8) - 8
    end

    -- absolute Z of the floor under (x, y), searched around a reference height
    local function ground_z(lp, x, y, ref_z)
        local up, down = 64, 256
        local top = vector(x, y, ref_z + up)
        local fr = trace_world(top, vector(x, y, ref_z - down), lp)
        return (ref_z + up) - fr * (up + down)
    end

    -- Catmull-Rom spline point (for a smoothly curving nav line)
    local function catmull(p0, p1, p2, p3, t)
        local t2, t3 = t * t, t * t * t
        local function c(a, b, cc, d)
            return 0.5 * ((2 * b) + (-a + cc) * t + (2 * a - 5 * b + 4 * cc - d) * t2 + (-a + 3 * b - 3 * cc + d) * t3)
        end
        return vector(c(p0.x, p1.x, p2.x, p3.x), c(p0.y, p1.y, p2.y, p3.y), c(p0.z, p1.z, p2.z, p3.z))
    end

    local function open_dist_dir(lp, origin, dir, max_dist)
        local to = vector(origin.x + dir.x * max_dist, origin.y + dir.y * max_dist, origin.z)
        return trace_path(origin, to, lp) * max_dist
    end

    -- 2-step lookahead: walk along dir, then from there head toward enemy.
    -- score = distance to enemy after both steps (lower = better)
    local function probe_path_score(lp, origin, dir, enemy_pos, step_dist)
        local s1 = vector(origin.x + dir.x * step_dist, origin.y + dir.y * step_dist, origin.z)
        local frac1 = trace_path(origin, s1, lp)
        local travel1 = frac1 * step_dist
        if travel1 > 4 then travel1 = travel1 - 4 end
        local p1 = vector(origin.x + dir.x * travel1, origin.y + dir.y * travel1, origin.z)

        local dx = enemy_pos.x - p1.x
        local dy = enemy_pos.y - p1.y
        local d2e = math.sqrt(dx * dx + dy * dy)
        if d2e < 1 then return 999999, 1 end

        local openness = travel1 / step_dist
        local s2len = math.min(step_dist, d2e)
        local base_ang = math.atan2(dy, dx)
        local final_dist
        if M.corner_peek:get() then
            -- peek around the corner: fan onward rays from p1 toward the enemy and
            -- keep the one that ends up closest (best route around a wall)
            final_dist = d2e
            for k = -2, 2 do
                local ang = base_ang + math.rad(k * 30)
                local cx, cy = math.cos(ang), math.sin(ang)
                local travel2 = trace_path(p1, vector(p1.x + cx * s2len, p1.y + cy * s2len, origin.z), lp) * s2len
                local px, py = p1.x + cx * travel2, p1.y + cy * travel2
                local fdx, fdy = enemy_pos.x - px, enemy_pos.y - py
                local fdist = math.sqrt(fdx * fdx + fdy * fdy)
                if fdist < final_dist then final_dist = fdist end
            end
        else
            local tex, tey = dx / d2e, dy / d2e
            local travel2 = trace_path(p1, vector(p1.x + tex * s2len, p1.y + tey * s2len, origin.z), lp) * s2len
            local px, py = p1.x + tex * travel2, p1.y + tey * travel2
            local fdx, fdy = enemy_pos.x - px, enemy_pos.y - py
            final_dist = math.sqrt(fdx * fdx + fdy * fdy)
        end
        if M.avoid_ledges:get() then
            local th = M.trace_height:get()
            local md = M.max_drop:get()
            if ground_drop(lp, p1.x, p1.y, p1.z - th, md) >= md then
                final_dist = final_dist + 80000
            end
        end
        return final_dist, openness
    end

    local function compute_wall_push(lp, origin)
        if not M.wall_fear:get() then return 0, 0 end
        local fd = M.fear_distance:get()
        local rep_x, rep_y, max_close = 0, 0, 0
        for i = 0, 11 do
            local a = (i / 12) * 360
            local pd = rotate_dir(vector(1, 0, 0), a)
            local od = open_dist_dir(lp, origin, pd, fd)
            if od < fd then
                local c = 1 - od / fd
                rep_x = rep_x - pd.x * c * c
                rep_y = rep_y - pd.y * c * c
                if c > max_close then max_close = c end
            end
        end
        local rlen = math.sqrt(rep_x * rep_x + rep_y * rep_y)
        if rlen < 0.001 then return 0, 0 end
        local k = max_close * (M.push_strength:get() / 100)
        return (rep_x / rlen) * k, (rep_y / rlen) * k
    end

    local function choose_direction(lp, enemy_pos)
        local feet = lp:get_origin()
        local origin = vector(feet.x, feet.y, feet.z + M.trace_height:get())
        local rays = math.floor(M.nav_rays:get())
        local step_dist = M.probe_distance:get()
        local cont = M.continuity:get()
        local bias = M.enemy_bias:get() / 100
        local best_score, best_dir = math.huge, nil
        for i = 0, rays - 1 do
            local angle = (i / rays) * 360
            local dir = rotate_dir(vector(1, 0, 0), angle)
            local fd, op = probe_path_score(lp, origin, dir, enemy_pos, step_dist)
            if op < 0.15 then fd = fd + 50000 end
            -- Enemy bias: low bias rewards open corridors, high bias beelines to the enemy
            fd = fd - op * step_dist * (1 - bias)
            if S.persisted_dir then
                local al = dir.x * S.persisted_dir.x + dir.y * S.persisted_dir.y
                if al > 0 then
                    fd = fd - cont * al
                elseif al < -0.25 then
                    fd = fd + 30000 -- don't flip-flop straight backwards
                end
            end
            if fd < best_score then best_score = fd; best_dir = dir end
        end
        return best_dir or vector(1, 0, 0)
    end

    -- Most open direction to escape a wall, biased toward the enemy so the bot
    -- doesn't just sprint to the most open corner away from its target.
    local function find_open_corridor(lp, enemy_dir)
        local feet = lp:get_origin()
        local origin = vector(feet.x, feet.y, feet.z + M.trace_height:get())
        local md = M.scan_distance:get()
        local best_score, best_dir, best_open = -1, nil, 0
        for i = 0, 31 do
            local a = (i / 32) * 360
            local pd = rotate_dir(vector(1, 0, 0), a)
            local od = open_dist_dir(lp, origin, pd, md)
            local score = od
            if enemy_dir then
                local al = pd.x * enemy_dir.x + pd.y * enemy_dir.y -- -1..1
                score = od * (1 + 0.35 * al)
            end
            if score > best_score then best_score = score; best_dir = pd; best_open = od end
        end
        return best_dir, best_open
    end

    -- blue predicted route: simulate forward, hug walls, curve to enemy
    local function predict_route(lp, enemy_pos, start_dir, max_steps)
        local feet = lp:get_origin()
        local pts = { vector(feet.x, feet.y, feet.z + M.trace_height:get()) }
        local steps = max_steps or 30
        local step_dist = 80
        local cont = M.continuity:get()
        local cur = pts[1]
        local sim_dir = start_dir
        local blocked = {}

        for s = 1, steps do
            local travel = open_dist_dir(lp, cur, sim_dir, step_dist)
            if travel > 4 then travel = travel - 4 end

            if travel < 15 then
                local ba = math.deg(math.atan2(sim_dir.y, sim_dir.x))
                blocked[math.floor(ba / 30) * 30] = true
                local bs, bd = math.huge, nil
                local ep = vector(enemy_pos.x, enemy_pos.y, cur.z)
                for i = 0, 15 do
                    local angle = (i / 16) * 360
                    local rk = math.floor(angle / 30) * 30
                    if not blocked[rk] then
                        local rd = rotate_dir(vector(1, 0, 0), angle)
                        local fd, op = probe_path_score(lp, cur, rd, ep, step_dist)
                        if op < 0.15 then fd = fd + 50000 end
                        local al = rd.x * sim_dir.x + rd.y * sim_dir.y
                        if al > 0 then fd = fd - cont * al * 0.5 end
                        if fd < bs then bs = fd; bd = rd end
                    end
                end
                if bd then sim_dir = rotate_towards(sim_dir, bd, 40) end
                travel = 15
            end

            local th = M.trace_height:get()
            local nx_x, nx_y = cur.x + sim_dir.x * travel, cur.y + sim_dir.y * travel
            local target_z = ground_z(lp, nx_x, nx_y, cur.z - th) + th
            -- clamp vertical change so the line follows slopes/stairs without spikes
            local dz = math.max(-24, math.min(24, target_z - cur.z))
            local nxt = vector(nx_x, nx_y, cur.z + dz)
            pts[#pts + 1] = nxt

            local dxe = enemy_pos.x - nxt.x
            local dye = enemy_pos.y - nxt.y
            if math.sqrt(dxe * dxe + dye * dye) < M.stop_distance:get() then break end

            local bs, bd = math.huge, sim_dir
            local ep = vector(enemy_pos.x, enemy_pos.y, nxt.z)
            for i = 0, 15 do
                local angle = (i / 16) * 360
                local rk = math.floor(angle / 30) * 30
                if not blocked[rk] then
                    local rd = rotate_dir(vector(1, 0, 0), angle)
                    local ro = open_dist_dir(lp, nxt, rd, step_dist)
                    if ro > 15 then
                        local fd, op = probe_path_score(lp, nxt, rd, ep, step_dist)
                        if op < 0.15 then fd = fd + 50000 end
                        local al = rd.x * sim_dir.x + rd.y * sim_dir.y
                        if al > 0 then fd = fd - cont * al end
                        if fd < bs then bs = fd; bd = rd end
                    end
                end
            end

            local wpx, wpy = compute_wall_push(lp, nxt)
            local nx = bd.x + wpx * 0.5
            local ny = bd.y + wpy * 0.5
            local nl = math.sqrt(nx * nx + ny * ny)
            if nl > 0.001 then bd = vector(nx / nl, ny / nl, 0) end
            sim_dir = rotate_towards(sim_dir, bd, 40)
            cur = nxt
        end
        return pts
    end

    local function fix_movement(cmd, world_dir, speed)
        local yaw = cmd.view_angles.y
        local move_yaw = math.deg(math.atan2(world_dir.y, world_dir.x))
        local delta = math.rad(move_yaw - yaw)
        cmd.forwardmove = math.cos(delta) * speed
        cmd.sidemove = -math.sin(delta) * speed
    end

    local function scan_vertical(lp, dir)
        local feet = lp:get_origin()
        local ahead = 32
        local function t(hh)
            return trace_world(
                vector(feet.x, feet.y, feet.z + hh),
                vector(feet.x + dir.x * ahead, feet.y + dir.y * ahead, feet.z + hh),
                lp)
        end
        local h_foot, h_shin, h_waist = t(12), t(24), t(40)
        local h_chest, h_head, h_top = t(54), t(64), t(72)
        local need_jump, need_crouch = false, false
        if (h_foot < 0.9 or h_shin < 0.9) and h_waist > 0.95 and h_chest > 0.95 then
            need_jump = true
        end
        if (h_head < 0.9 or h_chest < 0.9 or h_top < 0.9) and h_foot > 0.9 and h_shin > 0.9 then
            need_crouch = true
        end
        local up = trace_world(vector(feet.x, feet.y, feet.z + 50), vector(feet.x, feet.y, feet.z + 72), lp)
        if up < 0.9 then need_crouch = true; need_jump = false end
        return need_jump, need_crouch
    end

    local function has_headroom(lp)
        local feet = lp:get_origin()
        local base = feet.z + 72
        local cc = M.ceiling_clear:get()
        local tr = trace_world(vector(feet.x, feet.y, base), vector(feet.x, feet.y, base + cc), lp)
        local fwd = vector():angles(0, lp:get_angles().y)
        local tr2 = trace_world(vector(feet.x, feet.y, base),
            vector(feet.x + fwd.x * 16, feet.y + fwd.y * 16, base + cc), lp)
        return tr > 0.95 and tr2 > 0.95
    end

    local function check_ladder(lp)
        if lp.m_MoveType == MOVETYPE_LADDER then return true, "on_ladder" end
        local feet = lp:get_origin()
        local fwd = vector():angles(0, lp:get_angles().y)
        local tr = utils.trace_line(
            vector(feet.x, feet.y, feet.z + 30),
            vector(feet.x + fwd.x * 40, feet.y + fwd.y * 40, feet.z + 30), lp)
        if tr.fraction < 1 and tr.surface then
            local sn = tr.surface.name or ""
            if string.find(string.lower(sn), "ladder") then return true, "near_ladder" end
        end
        return false
    end

    -- can we hit the enemy from current eye position? (head=1 per API)
    local function can_hit(lp, enemy)
        local eye = lp:get_eye_position()
        if not eye then return false end
        local hitboxes = { 1, 2, 3, 0 }
        for _, hb in ipairs(hitboxes) do
            local hp = enemy:get_hitbox_position(hb)
            if hp then
                local dmg = utils.trace_bullet(lp, eye, hp)
                if dmg and dmg >= M.fire_min_damage:get() then return true, dmg end
            end
        end
        return false
    end

    -- air lag: toggle DT off/on every 6 ticks while airborne
    local function do_airlag(cmd, lp)
        if not M.is_dt then return end
        if bit.band(lp.m_fFlags, FL_ONGROUND) ~= 0 then
            M.is_dt:override(true)
            S.airlag_state = true
            return
        end
        if globals.tickcount % 6 == 0 then S.airlag_state = not S.airlag_state end
        M.is_dt:override(S.airlag_state)
    end

    local function capture_frame(cmd)
        return {
            forwardmove = cmd.forwardmove, sidemove = cmd.sidemove, upmove = cmd.upmove,
            in_jump = cmd.in_jump, in_duck = cmd.in_duck,
            in_attack = cmd.in_attack, in_attack2 = cmd.in_attack2,
            pitch = cmd.view_angles.x, yaw = cmd.view_angles.y,
        }
    end

    local function apply_frame(cmd, frame, yaw_offset)
        cmd.forwardmove = frame.forwardmove
        cmd.sidemove = frame.sidemove
        cmd.upmove = frame.upmove
        cmd.in_jump = frame.in_jump
        cmd.in_duck = frame.in_duck
        cmd.in_attack = frame.in_attack
        cmd.in_attack2 = frame.in_attack2
        cmd.view_angles.x = frame.pitch
        cmd.view_angles.y = frame.yaw + (yaw_offset or 0)
    end

    -- ============ MAIN LOOP ============
    events.createmove:set(function(cmd)
        local lp = entity.get_local_player()
        if not lp or not lp:is_alive() then
            S.is_recording, S.is_replaying = false, false
            reset_overrides()
            return
        end

        -- recording
        local rkey = M.record_key:get() or false
        if rkey and not S.last_rec_key then
            S.recorded = {}; S.is_recording = true; S.is_replaying = false
        end
        if not rkey and S.last_rec_key then S.is_recording = false end
        S.last_rec_key = rkey

        if S.is_recording then
            if #S.recorded < M.max_rec_frames:get() then
                S.recorded[#S.recorded + 1] = capture_frame(cmd)
            else
                S.is_recording = false
            end
            return
        end

        local enemy, dist = get_closest_enemy(lp)

        -- replay trigger
        local should_start = false
        local trig = M.play_trigger:get()
        if #S.recorded > 0 and not S.is_replaying then
            if trig == "Hotkey" then
                local pk = M.play_key:get() or false
                if pk and not S.last_play_key then should_start = true end
                S.last_play_key = pk
            elseif trig == "Enemy near" then
                if enemy and dist <= M.trigger_dist:get() then should_start = true end
            elseif trig == "Auto on approach" then
                if enemy and dist <= M.stop_distance:get() then should_start = true end
            end
        end
        if should_start then S.is_replaying = true; S.replay_index = 1 end

        if S.is_replaying then
            local frame = S.recorded[S.replay_index]
            if not frame then
                if M.loop_replay:get() then S.replay_index = 1; frame = S.recorded[1]
                else S.is_replaying = false; return end
            end
            local yaw_offset = 0
            if enemy then
                local mo, eo = lp:get_origin(), enemy:get_origin()
                yaw_offset = math.deg(math.atan2(eo.y - mo.y, eo.x - mo.x)) - S.recorded[1].yaw
            end
            apply_frame(cmd, frame, yaw_offset)
            S.replay_index = S.replay_index + 1
            return
        end

        if not (M.walk_to_enemy:get() and enemy) then
            S.predicted_path = {}
            S.persisted_dir = nil
            S.stuck_counter = 0
            S.escape_dir = nil
            reset_overrides()
            return
        end

        local mo = lp:get_origin()
        local eo = enemy:get_origin()
        local enemy_dir = mo:to(eo)
        enemy_dir.z = 0
        enemy_dir:normalize()

        local on_ground = lp.m_fFlags and bit.band(lp.m_fFlags, FL_ONGROUND) == 1

        -- DT / air lag (no shooting)
        if M.combat_enable:get() then
            if M.auto_airlag:get() then
                do_airlag(cmd, lp)
            elseif M.auto_dt:get() and M.is_dt then
                M.is_dt:override(true)
            end
        else
            reset_overrides()
        end

        -- combat: stop+crouch only if we SEE and can hit the enemy (no auto fire)
        if M.combat_enable:get() then
            local eye = lp:get_eye_position()
            local head = enemy:get_hitbox_position(1)
            local visible = false
            if eye and head then
                visible = trace_world(eye, head, lp) > 0.95
            end
            if visible and can_hit(lp, enemy) then
                cmd.forwardmove = 0
                cmd.sidemove = 0
                cmd.in_jump = false
                if M.crouch_on_fire:get() then cmd.in_duck = true end
                return
            end
        end

        if M.look_at_enemy:get() then
            local eye = lp:get_eye_position()
            local head = enemy:get_hitbox_position(1) or enemy:get_eye_position()
            if eye and head then
                local dx, dy, dz = head.x - eye.x, head.y - eye.y, head.z - eye.z
                local d2d = math.sqrt(dx * dx + dy * dy)
                local want_pitch = math.deg(-math.atan2(dz, d2d))
                local want_yaw = math.deg(math.atan2(dy, dx))
                if M.look_smooth:get() then
                    local ls = M.look_speed:get()
                    local cy, cx = cmd.view_angles.y, cmd.view_angles.x
                    local dyaw = math.max(-ls, math.min(ls, norm_angle(want_yaw - cy)))
                    local dpit = math.max(-ls, math.min(ls, want_pitch - cx))
                    cmd.view_angles.y = cy + dyaw
                    cmd.view_angles.x = cx + dpit
                else
                    cmd.view_angles.x = want_pitch
                    cmd.view_angles.y = want_yaw
                end
            end
        end

        if dist <= M.stop_distance:get() then
            cmd.forwardmove = 0
            cmd.sidemove = 0
            S.predicted_path = {}
            S.persisted_dir = nil
            S.stuck_counter = 0
            S.escape_dir = nil
            return
        end

        -- ladder
        if M.use_ladders:get() then
            local on_ladder, ltype = check_ladder(lp)
            if on_ladder then
                fix_movement(cmd, vector():angles(0, lp:get_angles().y), M.move_speed:get())
                if ltype == "on_ladder" then
                    cmd.view_angles.x = -45
                    cmd.upmove = M.move_speed:get()
                end
                cmd.in_jump = false
                return
            end
        end

        -- stuck detection
        local vel = lp.m_vecVelocity
        local cur_speed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
        if on_ground and cur_speed < M.stuck_speed:get() then
            S.stuck_counter = S.stuck_counter + 1
        else
            S.stuck_counter = math.max(0, S.stuck_counter - 1)
        end

        -- pick direction
        local final_dir
        local enemy_pos = vector(eo.x, eo.y, mo.z + M.trace_height:get())

        if M.wall_follow:get() and S.stuck_counter > 18 then
            local need_new = (S.escape_dir == nil) or (globals.tickcount > S.escape_until)
            if not need_new then
                local feet = lp:get_origin()
                local origin = vector(feet.x, feet.y, feet.z + M.trace_height:get())
                if open_dist_dir(lp, origin, S.escape_dir, M.scan_distance:get()) < 50 then
                    need_new = true
                end
            end
            if need_new then
                S.escape_dir = find_open_corridor(lp, enemy_dir)
                S.escape_until = globals.tickcount + M.commit_ticks:get()
            end
            final_dir = S.escape_dir or enemy_dir
            S.persisted_dir = final_dir
        else
            S.escape_dir = nil
            -- HEAVY: recompute desired direction only every 6 ticks (cached).
            -- Wall push is applied per-tick below, not baked in here.
            if S.cached_desired == nil or (globals.tickcount - S.last_choose_tick) >= 6 then
                S.cached_desired = choose_direction(lp, enemy_pos)
                S.last_choose_tick = globals.tickcount
            end
            if not S.persisted_dir then
                S.persisted_dir = S.cached_desired
            else
                S.persisted_dir = rotate_towards(S.persisted_dir, S.cached_desired, M.turn_speed:get())
            end
            final_dir = S.persisted_dir
        end

        -- responsive wall avoidance: steer off nearby walls every tick (not cached)
        local eye_origin = vector(mo.x, mo.y, mo.z + M.trace_height:get())
        do
            local wpx, wpy = compute_wall_push(lp, eye_origin)
            if wpx ~= 0 or wpy ~= 0 then
                local nx, ny = final_dir.x + wpx, final_dir.y + wpy
                local nl = math.sqrt(nx * nx + ny * ny)
                if nl > 0.001 then final_dir = vector(nx / nl, ny / nl, 0) end
            end
        end

        -- blue predicted route (throttled every 12 ticks)
        if M.draw_nav:get() then
            if globals.tickcount - S.last_predict_tick >= 12 then
                S.predicted_path = predict_route(lp, enemy_pos, final_dir, 30)
                S.last_predict_tick = globals.tickcount
            end
        else
            S.predicted_path = {}
        end

        -- vertical (jump vs crouch) cached every 3 ticks
        if (globals.tickcount - S.last_vert_tick) >= 3 then
            S.cached_need_jump, S.cached_need_crouch = scan_vertical(lp, final_dir)
            S.cached_headroom = (not M.ceiling_check:get()) or has_headroom(lp)
            S.last_vert_tick = globals.tickcount
        end
        local need_jump, need_crouch = S.cached_need_jump, S.cached_need_crouch
        local headroom = S.cached_headroom
        if not headroom then need_jump = false; need_crouch = true end

        -- hard ledge guard: never walk straight off a deadly drop
        if M.avoid_ledges:get() and on_ground then
            local md = M.max_drop:get()
            local ax, ay = mo.x + final_dir.x * 45, mo.y + final_dir.y * 45
            if ground_drop(lp, ax, ay, mo.z, md) >= md then
                cmd.forwardmove = 0
                cmd.sidemove = 0
                S.stuck_counter = S.stuck_counter + 2
                return
            end
        end

        fix_movement(cmd, final_dir, M.move_speed:get())

        local did_jump = false
        if need_jump and M.jump_obstacles:get() and on_ground and headroom then
            cmd.in_jump = true; did_jump = true
        elseif S.stuck_counter > 22 and M.jump_obstacles:get() and on_ground and headroom then
            cmd.in_jump = true; did_jump = true
        elseif S.escape_dir and on_ground and headroom and M.jump_obstacles:get() and (globals.tickcount % 20 < 2) then
            cmd.in_jump = true; did_jump = true
        elseif M.auto_bhop:get() and on_ground and not need_crouch and headroom
               and not S.escape_dir and S.stuck_counter < 4
               and open_dist_dir(lp, eye_origin, final_dir, 130) > 100 then
            cmd.in_jump = true; did_jump = true
        end

        if need_crouch and M.crouch_gaps:get() and not did_jump then
            cmd.in_duck = true
            cmd.in_jump = false
        end
    end)

    -- ============ HUD + NAV DRAW ============
    events.render:set(function()
        if M.draw_nav:get() and M.walk_to_enemy:get() then
            local pp = S.predicted_path
            local n = #pp
            if n > 1 then
                local SEG = 8 -- sub-samples per segment -> smooth curve
                local prev_scr = pp[1]:to_screen()
                for i = 1, n - 1 do
                    local p0 = pp[math.max(1, i - 1)]
                    local p1 = pp[i]
                    local p2 = pp[i + 1]
                    local p3 = pp[math.min(n, i + 2)]
                    for s = 1, SEG do
                        local cur_scr = catmull(p0, p1, p2, p3, s / SEG):to_screen()
                        if prev_scr and cur_scr then
                            local alpha = math.floor(255 - (i / n) * 120)
                            render.line(prev_scr, cur_scr, color(40, 160, 255, alpha))
                        end
                        prev_scr = cur_scr or prev_scr
                    end
                end
            end
        end

        local screen = render.screen_size()
        local x, y = screen.x * 0.5, screen.y * 0.72
        local status, clr
        if S.is_recording then
            status = string.format("RECORDING... (%d)", #S.recorded); clr = color(255, 60, 60, 230)
        elseif S.is_replaying then
            status = string.format("REPLAYING %d/%d", S.replay_index, #S.recorded); clr = color(60, 150, 255, 230)
        elseif M.walk_to_enemy:get() then
            local extra = (S.escape_dir ~= nil) and " [ESCAPING WALL]" or ""
            status = "NAVIGATING" .. extra; clr = color(60, 255, 130, 230)
        else
            return
        end
        render.text(2, vector(x, y), clr, "c", status)
    end)

    events.shutdown:set(function()
        S.is_recording, S.is_replaying = false, false
        S.persisted_dir = nil
        S.stuck_counter = 0
        S.escape_dir = nil
        reset_overrides()
    end)
end
