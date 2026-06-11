local bot = {}; do
    local group = ui.create("AI Bot", "Smart Bot")

    -- ============ UI (packed into table M to stay under Lua's 60-upvalue limit) ============
    local M = {}
    M.walk_to_enemy   = group:switch("Walk to enemy")
    local wg          = M.walk_to_enemy:create()
    M.stop_distance   = wg:slider("Stop distance", 50, 600, 200, 1)
    M.move_speed      = wg:slider("Move speed", 0, 450, 250, 1)
    M.look_at_enemy   = wg:switch("Look at enemy", false)

    M.nav_rays        = wg:slider("Path scan rays", 8, 128, 24, 1)
    M.scan_distance   = wg:slider("Scan distance", 100, 8192, 2400, 1)
    M.probe_distance  = wg:slider("Probe step", 80, 600, 280, 1, "Length of each probe step")
    M.enemy_bias      = wg:slider("Enemy bias", 0, 100, 70, 1)
    M.continuity      = wg:slider("Continuity bonus", 0, 200, 120, 1)
    M.turn_speed      = wg:slider("Turn speed", 3, 45, 18, 1)
    M.trace_height    = wg:slider("Trace height", 18, 64, 36, 1)

    M.wall_fear       = wg:switch("Move away from walls", true)
    M.fear_distance   = wg:slider("Wall keep distance", 10, 150, 55, 1)
    M.push_strength   = wg:slider("Wall push strength", 0, 100, 35, 1)
    M.wall_fear:set_callback(function(self)
        local v = self:get()
        M.fear_distance:visibility(v)
        M.push_strength:visibility(v)
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

    local function open_dist_dir(lp, origin, dir, max_dist)
        local to = vector(origin.x + dir.x * max_dist, origin.y + dir.y * max_dist, origin.z)
        return trace_world(origin, to, lp) * max_dist
    end

    -- 2-step lookahead: walk along dir, then from there head toward enemy.
    -- score = distance to enemy after both steps (lower = better)
    local function probe_path_score(lp, origin, dir, enemy_pos, step_dist)
        local s1 = vector(origin.x + dir.x * step_dist, origin.y + dir.y * step_dist, origin.z)
        local frac1 = trace_world(origin, s1, lp)
        local travel1 = frac1 * step_dist
        if travel1 > 4 then travel1 = travel1 - 4 end
        local p1 = vector(origin.x + dir.x * travel1, origin.y + dir.y * travel1, origin.z)

        local dx = enemy_pos.x - p1.x
        local dy = enemy_pos.y - p1.y
        local d2e = math.sqrt(dx * dx + dy * dy)
        if d2e < 1 then return 999999, 1 end

        local tex, tey = dx / d2e, dy / d2e
        local s2len = math.min(step_dist, d2e)
        local s2 = vector(p1.x + tex * s2len, p1.y + tey * s2len, origin.z)
        local frac2 = trace_world(p1, s2, lp)
        local travel2 = frac2 * s2len
        local p2 = vector(p1.x + tex * travel2, p1.y + tey * travel2, origin.z)

        local fdx = enemy_pos.x - p2.x
        local fdy = enemy_pos.y - p2.y
        local final_dist = math.sqrt(fdx * fdx + fdy * fdy)
        local openness = travel1 / step_dist
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
        local best_score, best_dir = math.huge, nil
        for i = 0, rays - 1 do
            local angle = (i / rays) * 360
            local dir = rotate_dir(vector(1, 0, 0), angle)
            local fd, op = probe_path_score(lp, origin, dir, enemy_pos, step_dist)
            if op < 0.15 then fd = fd + 50000 end
            if S.persisted_dir then
                local al = dir.x * S.persisted_dir.x + dir.y * S.persisted_dir.y
                if al > 0 then fd = fd - cont * al end
            end
            if fd < best_score then best_score = fd; best_dir = dir end
        end
        return best_dir or vector(1, 0, 0)
    end

    local function find_open_corridor(lp)
        local feet = lp:get_origin()
        local origin = vector(feet.x, feet.y, feet.z + M.trace_height:get())
        local md = M.scan_distance:get()
        local best_open, best_dir = -1, nil
        for i = 0, 31 do
            local a = (i / 32) * 360
            local pd = rotate_dir(vector(1, 0, 0), a)
            local od = open_dist_dir(lp, origin, pd, md)
            if od > best_open then best_open = od; best_dir = pd end
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
                if bd then sim_dir = bd end
                travel = 15
            end

            local nxt = vector(cur.x + sim_dir.x * travel, cur.y + sim_dir.y * travel, cur.z)
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
            sim_dir = bd
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
            S.recorded[#S.recorded + 1] = capture_frame(cmd)
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
                cmd.view_angles.x = math.deg(-math.atan2(dz, d2d))
                cmd.view_angles.y = math.deg(math.atan2(dy, dx))
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

        if M.wall_follow:get() and S.stuck_counter > 12 then
            local need_new = (S.escape_dir == nil) or (globals.tickcount > S.escape_until)
            if not need_new then
                local feet = lp:get_origin()
                local origin = vector(feet.x, feet.y, feet.z + M.trace_height:get())
                if open_dist_dir(lp, origin, S.escape_dir, M.scan_distance:get()) < 50 then
                    need_new = true
                end
            end
            if need_new then
                S.escape_dir = find_open_corridor(lp)
                S.escape_until = globals.tickcount + M.commit_ticks:get()
            end
            final_dir = S.escape_dir or enemy_dir
            S.persisted_dir = final_dir
        else
            S.escape_dir = nil
            -- HEAVY: recompute desired direction only every 6 ticks (cached)
            if S.cached_desired == nil or (globals.tickcount - S.last_choose_tick) >= 6 then
                local desired = choose_direction(lp, enemy_pos)
                local feet = lp:get_origin()
                local origin = vector(feet.x, feet.y, feet.z + M.trace_height:get())
                local wpx, wpy = compute_wall_push(lp, origin)
                local nx, ny = desired.x + wpx, desired.y + wpy
                local nl = math.sqrt(nx * nx + ny * ny)
                if nl > 0.001 then desired = vector(nx / nl, ny / nl, 0) end
                S.cached_desired = desired
                S.last_choose_tick = globals.tickcount
            end
            if not S.persisted_dir then
                S.persisted_dir = S.cached_desired
            else
                S.persisted_dir = rotate_towards(S.persisted_dir, S.cached_desired, M.turn_speed:get())
            end
            final_dir = S.persisted_dir
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

        fix_movement(cmd, final_dir, M.move_speed:get())

        local did_jump = false
        if need_jump and M.jump_obstacles:get() and on_ground and headroom then
            cmd.in_jump = true; did_jump = true
        elseif S.stuck_counter > 16 and M.jump_obstacles:get() and on_ground and headroom then
            cmd.in_jump = true; did_jump = true
        elseif M.auto_bhop:get() and on_ground and not need_crouch and headroom then
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
            if #pp > 1 then
                for i = 1, #pp - 1 do
                    local a = pp[i]:to_screen()
                    local b = pp[i + 1]:to_screen()
                    if a and b then
                        local alpha = math.floor(255 - (i / #pp) * 100)
                        render.line(a, b, color(40, 160, 255, alpha))
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
