local bot = {}; do
    local group = ui.create("AI Bot", "Smart Bot")

    -- ============ MAIN ============
    local walk_to_enemy = group:switch("Walk to enemy")
    local walk_group = walk_to_enemy:create()
    local stop_distance = walk_group:slider("Stop distance", 50, 600, 200, 1)
    local move_speed = walk_group:slider("Move speed", 0, 450, 250, 1)
    local look_at_enemy = walk_group:switch("Look at enemy", false)

    -- ============ NAVIGATION ============
    local nav_rays = walk_group:slider("Path scan rays", 8, 128, 24, 1)
    local scan_distance = walk_group:slider("Scan distance", 100, 8192, 2400, 1)
    local probe_distance = walk_group:slider("Probe step", 80, 600, 280, 1, "Length of each probe step")
    local enemy_bias = walk_group:slider("Enemy bias", 0, 100, 70, 1, "How strongly to head toward the enemy vs open space")
    local continuity_bonus = walk_group:slider("Continuity bonus", 0, 200, 120, 1, "Extra score for staying on the current heading")
    local turn_speed = walk_group:slider("Turn speed", 3, 45, 18, 1, "Max degrees to rotate per tick")
    local trace_height = walk_group:slider("Trace height", 18, 64, 36, 1)

    -- ============ WALL AVOIDANCE (gentle modifier) ============
    local wall_fear = walk_group:switch("Move away from walls", true)
    local fear_distance = walk_group:slider("Wall keep distance", 10, 150, 55, 1, "Start pushing away when a wall is closer than this")
    local push_strength = walk_group:slider("Wall push strength", 0, 100, 35, 1)
    wall_fear:set_callback(function(self)
        local v = self:get()
        fear_distance:visibility(v)
        push_strength:visibility(v)
    end, true)

    -- ============ STUCK / ESCAPE ============
    local wall_follow = walk_group:switch("Escape when stuck", true)
    local stuck_speed = walk_group:slider("Stuck speed", 1, 100, 35, 1)
    local commit_ticks = walk_group:slider("Escape commit ticks", 8, 96, 40, 1)

    -- ============ MOVEMENT EXTRAS ============
    local auto_bhop = walk_group:switch("Auto bhop", true)
    local ceiling_check = walk_group:switch("Don't jump under ceiling", true)
    local ceiling_clearance = walk_group:slider("Ceiling clearance", 4, 64, 24, 1, "Min free space above head to allow jumping")
    ceiling_check:set_callback(function(self)
        ceiling_clearance:visibility(self:get())
    end, true)
    local jump_obstacles = walk_group:switch("Jump obstacles", true)
    local crouch_gaps = walk_group:switch("Auto crouch", true)
    local use_ladders = walk_group:switch("Use ladders", true)

    -- ============ COMBAT (no auto-fire) ============
    local combat_enable = walk_group:switch("Auto combat", true)
    local fire_min_damage = walk_group:slider("Fire min damage", 1, 120, 10, 1)
    local crouch_on_fire = walk_group:switch("Crouch when can hit", true)
    local auto_dt = walk_group:switch("Auto Double Tap", true)
    local auto_airlag = walk_group:switch("Auto air lag exploit", true)

    local draw_nav = walk_group:switch("Draw navigation", true)

    -- ============ RECORD / REPLAY ============
    local record_key = group:hotkey("Record (hold)", 0x52)
    local play_trigger = group:combo("Replay trigger", "Enemy near", "Hotkey", "Auto on approach")
    local play_key = group:hotkey("Replay key", 0x54)
    local trigger_distance = group:slider("Trigger distance", 50, 1500, 400, 1)
    local loop_replay = group:switch("Loop replay", false)
    local clear_btn = group:button("Clear recording")

    play_trigger:set_callback(function(self)
        local v = self:get()
        play_key:visibility(v == "Hotkey")
        trigger_distance:visibility(v == "Enemy near" or v == "Auto on approach")
    end, true)

    -- ============ CHEAT REFERENCES ============
    local is_dt = ui.find("Aimbot", "Ragebot", "Main", "Double Tap")
    local fl_limit = ui.find("Aimbot", "Ragebot", "Main", "Double Tap", "Fake Lag Limit")

    -- ============ STATE ============
    local recorded = {}
    local is_recording, is_replaying = false, false
    local replay_index = 1
    local last_rec_key, last_play_key = false, false
    local predicted_path = {}
    local last_predict_tick = 0
    local cached_desired = nil
    local last_choose_tick = 0
    local cached_need_jump, cached_need_crouch, cached_headroom = false, false, true
    local last_vert_tick = 0
    local persisted_dir = nil
    local stuck_counter = 0
    local escape_dir = nil
    local escape_until = 0
    local chosen_ray_idx = -1

    clear_btn:set_callback(function()
        recorded = {}
        is_replaying = false
        replay_index = 1
    end)

    local FL_ONGROUND = 1
    local MOVETYPE_LADDER = 9

    local function reset_overrides()
        if is_dt then is_dt:override() end
        if fl_limit then fl_limit:override() end
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

    -- =====================================================================
    -- PROBE PATH: 2-step lookahead navigation
    -- Step 1: cast a ray in direction `dir` from origin, walk as far as clear
    -- Step 2: from that endpoint, cast toward the enemy position
    -- Score = how close we get to the enemy after both steps
    -- This gives actual pathfinding around corners and obstacles.
    -- =====================================================================
    local function probe_path_score(lp, origin, dir, enemy_pos, step_dist)
        -- Step 1: walk along dir
        local step1_end_x = origin.x + dir.x * step_dist
        local step1_end_y = origin.y + dir.y * step_dist
        local step1_target = vector(step1_end_x, step1_end_y, origin.z)
        local frac1 = trace_world(origin, step1_target, lp)
        -- actual endpoint after step1 (stop a bit short of wall)
        local travel1 = frac1 * step_dist
        if travel1 > 4 then travel1 = travel1 - 4 end
        local p1 = vector(origin.x + dir.x * travel1, origin.y + dir.y * travel1, origin.z)

        -- Step 2: from p1, try to go toward enemy
        local dx = enemy_pos.x - p1.x
        local dy = enemy_pos.y - p1.y
        local d2e = math.sqrt(dx * dx + dy * dy)
        if d2e < 1 then return 999999 end -- already at enemy

        local to_e_x = dx / d2e
        local to_e_y = dy / d2e
        local step2_len = math.min(step_dist, d2e)
        local step2_target = vector(p1.x + to_e_x * step2_len, p1.y + to_e_y * step2_len, origin.z)
        local frac2 = trace_world(p1, step2_target, lp)
        local travel2 = frac2 * step2_len

        local p2 = vector(p1.x + to_e_x * travel2, p1.y + to_e_y * travel2, origin.z)

        -- final distance to enemy after both steps (lower = better)
        local fdx = enemy_pos.x - p2.x
        local fdy = enemy_pos.y - p2.y
        local final_dist = math.sqrt(fdx * fdx + fdy * fdy)

        -- also penalize if step1 hit a wall immediately (don't walk into walls)
        local openness = travel1 / step_dist

        return final_dist, openness, p1, p2
    end

    -- =====================================================================
    -- WALL REPULSION (gentle omnidirectional push away from nearby walls)
    -- This is just a soft modifier, not the primary steering.
    -- =====================================================================
    local function compute_wall_push(lp, origin)
        if not wall_fear:get() then return 0, 0 end
        local fd = fear_distance:get()
        local probes = 12
        local rep_x, rep_y, max_close = 0, 0, 0
        for i = 0, probes - 1 do
            local a = (i / probes) * 360
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
        rep_x, rep_y = rep_x / rlen, rep_y / rlen
        local k = max_close * (push_strength:get() / 100)
        return rep_x * k, rep_y * k
    end

    -- =====================================================================
    -- CHOOSE BEST DIRECTION using probe_path with continuity bonus
    -- =====================================================================
    local function choose_direction(lp, enemy_pos)
        local feet = lp:get_origin()
        local h = trace_height:get()
        local origin = vector(feet.x, feet.y, feet.z + h)
        local rays = math.floor(nav_rays:get())
        local step_dist = probe_distance:get()
        local cont_bonus = continuity_bonus:get()

        local best_score = math.huge
        local best_dir = nil
        local best_idx = -1

        for i = 0, rays - 1 do
            local angle = (i / rays) * 360
            local dir = rotate_dir(vector(1, 0, 0), angle)
            local final_dist, openness = probe_path_score(lp, origin, dir, enemy_pos, step_dist)

            if not final_dist then final_dist = 999999 end
            if not openness then openness = 0 end

            -- skip rays that immediately hit a wall (less than min clearance)
            if openness < 0.15 then
                final_dist = final_dist + 50000
            end

            -- continuity bonus: if we already have a chosen direction,
            -- give a big bonus (lower score) to rays close to it
            if persisted_dir then
                local align = dir.x * persisted_dir.x + dir.y * persisted_dir.y
                -- align is -1..1, where 1 = same direction
                -- subtract bonus scaled by alignment (1 = full bonus)
                if align > 0 then
                    final_dist = final_dist - cont_bonus * align
                end
            end

            if final_dist < best_score then
                best_score = final_dist
                best_dir = dir
                best_idx = i
            end
        end

        chosen_ray_idx = best_idx
        return best_dir or vector(1, 0, 0)
    end

    -- most open direction in a full circle (escape route when boxed in)
    local function find_open_corridor(lp)
        local feet = lp:get_origin()
        local origin = vector(feet.x, feet.y, feet.z + trace_height:get())
        local md = scan_distance:get()
        local rays = 32
        local best_open, best_dir = -1, nil
        for i = 0, rays - 1 do
            local a = (i / rays) * 360
            local pd = rotate_dir(vector(1, 0, 0), a)
            local od = open_dist_dir(lp, origin, pd, md)
            if od > best_open then
                best_open = od
                best_dir = pd
            end
        end
        return best_dir, best_open
    end

    -- =====================================================================
    -- PREDICT PATH (blue visualization + navigation)
    -- SHORT steps (60u) so it traces tightly around walls and curves through
    -- corridors all the way to the enemy. Blacklists blocked sectors.
    -- =====================================================================
    local function predict_route(lp, enemy_pos, start_dir, max_steps)
        local feet = lp:get_origin()
        local h = trace_height:get()
        local pts = { vector(feet.x, feet.y, feet.z + h) }
        local steps = max_steps or 40
        local step_dist = 80  -- step length; longer = fewer total traces
        local cont_bonus = continuity_bonus:get()
        local cur = pts[1]
        local sim_dir = start_dir
        -- blacklist: track ray indices that led into walls so we don't retry
        local blocked = {}

        for s = 1, steps do
            local travel = open_dist_dir(lp, cur, sim_dir, step_dist)
            if travel > 4 then travel = travel - 4 end

            -- if we hit a wall (travel too short), blacklist this direction
            if travel < 15 then
                -- blacklist a 30-degree sector so we don't retry this wall
                local blocked_angle = math.deg(math.atan2(sim_dir.y, sim_dir.x))
                blocked[math.floor(blocked_angle / 30) * 30] = true

                -- immediately re-pick direction excluding blocked ones
                local rays = 16
                local best_score = math.huge
                local best_dir = nil
                local ep = vector(enemy_pos.x, enemy_pos.y, cur.z)

                for i = 0, rays - 1 do
                    local angle = (i / rays) * 360
                    local ray_key = math.floor(angle / 30) * 30
                    if not blocked[ray_key] then
                        local rd = rotate_dir(vector(1, 0, 0), angle)
                        local fd, openness = probe_path_score(lp, cur, rd, ep, step_dist)
                        if not fd then fd = 999999 end
                        if not openness then openness = 0 end
                        if openness < 0.15 then fd = fd + 50000 end

                        local align = rd.x * sim_dir.x + rd.y * sim_dir.y
                        if align > 0 then fd = fd - cont_bonus * align * 0.5 end

                        if fd < best_score then
                            best_score = fd
                            best_dir = rd
                        end
                    end
                end

                if best_dir then
                    sim_dir = best_dir  -- HARD snap, no smoothing
                end
                -- try again with new direction but minimal movement
                travel = 15
            end

            local nxt = vector(cur.x + sim_dir.x * travel, cur.y + sim_dir.y * travel, cur.z)
            pts[#pts + 1] = nxt

            -- reached enemy?
            local dxe = enemy_pos.x - nxt.x
            local dye = enemy_pos.y - nxt.y
            local dist_to_enemy = math.sqrt(dxe * dxe + dye * dye)
            if dist_to_enemy < stop_distance:get() then break end

            -- re-evaluate direction from new position (excluding blocked)
            local rays = 16
            local best_score = math.huge
            local best_dir = sim_dir
            local ep = vector(enemy_pos.x, enemy_pos.y, nxt.z)

            for i = 0, rays - 1 do
                local angle = (i / rays) * 360
                local ray_key = math.floor(angle / 30) * 30
                if not blocked[ray_key] then
                    local rd = rotate_dir(vector(1, 0, 0), angle)
                    local ray_open = open_dist_dir(lp, nxt, rd, step_dist)
                    if ray_open > 15 then
                    local fd, openness = probe_path_score(lp, nxt, rd, ep, step_dist)
                    if not fd then fd = 999999 end
                    if not openness then openness = 0 end
                    if openness < 0.15 then fd = fd + 50000 end

                    -- strong continuity so the line doesn't zigzag
                    local align = rd.x * sim_dir.x + rd.y * sim_dir.y
                    if align > 0 then fd = fd - cont_bonus * align end

                    if fd < best_score then
                        best_score = fd
                        best_dir = rd
                    end
                    end
                end
            end

            -- apply wall push gently
            local wpx, wpy = compute_wall_push(lp, nxt)
            local nx = best_dir.x + wpx * 0.5
            local ny = best_dir.y + wpy * 0.5
            local nl = math.sqrt(nx * nx + ny * ny)
            if nl > 0.001 then
                best_dir = vector(nx / nl, ny / nl, 0)
            end

            -- HARD direction change (no rotate_towards = decisive line)
            sim_dir = best_dir
            cur = nxt
        end

        return pts
    end

    local function fix_movement(cmd, world_dir, speed)
        local yaw = cmd.view_angles.y
        local move_yaw_world = math.deg(math.atan2(world_dir.y, world_dir.x))
        local delta = math.rad(move_yaw_world - yaw)
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
                lp
            )
        end
        local h_foot = t(12)
        local h_shin = t(24)
        local h_waist = t(40)
        local h_chest = t(54)
        local h_head = t(64)
        local h_top = t(72)

        local need_jump, need_crouch = false, false
        if (h_foot < 0.9 or h_shin < 0.9) and h_waist > 0.95 and h_chest > 0.95 then
            need_jump = true
        end
        if (h_head < 0.9 or h_chest < 0.9 or h_top < 0.9) and h_foot > 0.9 and h_shin > 0.9 then
            need_crouch = true
        end
        local up = trace_world(
            vector(feet.x, feet.y, feet.z + 50),
            vector(feet.x, feet.y, feet.z + 72), lp
        )
        if up < 0.9 then need_crouch = true; need_jump = false end
        return need_jump, need_crouch
    end

    local function has_headroom(lp)
        local feet = lp:get_origin()
        local base = feet.z + 72
        local tr = trace_world(
            vector(feet.x, feet.y, base),
            vector(feet.x, feet.y, base + ceiling_clearance:get()),
            lp
        )
        local fwd = vector():angles(0, lp:get_angles().y)
        local tr_fwd = trace_world(
            vector(feet.x, feet.y, base),
            vector(feet.x + fwd.x * 16, feet.y + fwd.y * 16, base + ceiling_clearance:get()),
            lp
        )
        return tr > 0.95 and tr_fwd > 0.95
    end

    local function check_ladder(lp)
        if lp.m_MoveType == MOVETYPE_LADDER then return true, "on_ladder" end
        local feet = lp:get_origin()
        local fwd = vector():angles(0, lp:get_angles().y)
        local from = vector(feet.x, feet.y, feet.z + 30)
        local to = vector(feet.x + fwd.x * 40, feet.y + fwd.y * 40, feet.z + 30)
        local tr = utils.trace_line(from, to, lp)
        if tr.fraction < 1 and tr.surface then
            local sname = tr.surface.name or ""
            if string.find(string.lower(sname), "ladder") then return true, "near_ladder" end
        end
        return false
    end

    -- combat: can we hit the enemy from current eye position?
    local function can_hit(lp, enemy)
        local eye = lp:get_eye_position()
        if not eye then return false, 0 end
        local hitboxes = { 1, 2, 3, 0 } -- head, chest, stomach, generic (API: 1=head)
        for _, hb in ipairs(hitboxes) do
            local hp = enemy:get_hitbox_position(hb)
            if hp then
                local dmg = utils.trace_bullet(lp, eye, hp)
                if dmg and dmg >= fire_min_damage:get() then
                    return true, dmg
                end
            end
        end
        return false, 0
    end

    -- air lag: toggle DT off/on every 6 ticks while airborne
    local airlag_state = true
    local function do_airlag(cmd, lp)
        if not is_dt then return end
        local in_air = bit.band(lp.m_fFlags, FL_ONGROUND) == 0
        if not in_air then
            is_dt:override(true)
            airlag_state = true
            return
        end
        if globals.tickcount % 6 == 0 then
            airlag_state = not airlag_state
        end
        is_dt:override(airlag_state)
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
            is_recording, is_replaying = false, false
            reset_overrides()
            return
        end

        -- RECORDING
        local rkey = record_key:get() or false
        if rkey and not last_rec_key then
            recorded = {}; is_recording = true; is_replaying = false
        end
        if not rkey and last_rec_key then is_recording = false end
        last_rec_key = rkey

        if is_recording then
            recorded[#recorded + 1] = capture_frame(cmd)
            return
        end

        local enemy, dist = get_closest_enemy(lp)

        -- REPLAY TRIGGER
        local should_start = false
        local trig = play_trigger:get()
        if #recorded > 0 and not is_replaying then
            if trig == "Hotkey" then
                local pk = play_key:get() or false
                if pk and not last_play_key then should_start = true end
                last_play_key = pk
            elseif trig == "Enemy near" then
                if enemy and dist <= trigger_distance:get() then should_start = true end
            elseif trig == "Auto on approach" then
                if enemy and dist <= stop_distance:get() then should_start = true end
            end
        end
        if should_start then is_replaying = true; replay_index = 1 end

        if is_replaying then
            local frame = recorded[replay_index]
            if not frame then
                if loop_replay:get() then replay_index = 1; frame = recorded[1]
                else is_replaying = false; return end
            end
            local yaw_offset = 0
            if enemy then
                local mo, eo = lp:get_origin(), enemy:get_origin()
                yaw_offset = math.deg(math.atan2(eo.y - mo.y, eo.x - mo.x)) - recorded[1].yaw
            end
            apply_frame(cmd, frame, yaw_offset)
            replay_index = replay_index + 1
            return
        end

        if not (walk_to_enemy:get() and enemy) then
            predicted_path = {}
            persisted_dir = nil
            stuck_counter = 0
            escape_dir = nil
            reset_overrides()
            return
        end

        local mo = lp:get_origin()
        local eo = enemy:get_origin()
        local enemy_dir = mo:to(eo)
        enemy_dir.z = 0
        enemy_dir:normalize()

        local on_ground = lp.m_fFlags and bit.band(lp.m_fFlags, FL_ONGROUND) == 1

        -- ===== AUTO DT / AIR LAG (no shooting) =====
        if combat_enable:get() then
            if auto_airlag:get() then
                do_airlag(cmd, lp)
            elseif auto_dt:get() and is_dt then
                is_dt:override(true)
            end
        else
            reset_overrides()
        end

        -- ===== COMBAT: if we can hit AND see the enemy, stop and crouch (NO auto fire) =====
        if combat_enable:get() then
            -- first check: is the enemy actually visible? (not behind a wall)
            local eye = lp:get_eye_position()
            local enemy_head = enemy:get_hitbox_position(1)
            local enemy_visible = false
            if eye and enemy_head then
                local vis_frac = trace_world(eye, enemy_head, lp)
                enemy_visible = vis_frac > 0.95
            end

            if enemy_visible then
                local hittable, dmg = can_hit(lp, enemy)
                if hittable then
                    cmd.forwardmove = 0
                    cmd.sidemove = 0
                    cmd.in_jump = false
                    if crouch_on_fire:get() then
                        cmd.in_duck = true
                    end
                    return
                end
            end
        end

        if look_at_enemy:get() then
            local eye = lp:get_eye_position()
            local head = enemy:get_hitbox_position(1) or enemy:get_eye_position()
            if head then
                local dx, dy, dz = head.x - eye.x, head.y - eye.y, head.z - eye.z
                local d2d = math.sqrt(dx * dx + dy * dy)
                cmd.view_angles.x = math.deg(-math.atan2(dz, d2d))
                cmd.view_angles.y = math.deg(math.atan2(dy, dx))
            end
        end

        if dist <= stop_distance:get() then
            cmd.forwardmove = 0
            cmd.sidemove = 0
            predicted_path = {}
            persisted_dir = nil
            stuck_counter = 0
            escape_dir = nil
            return
        end

        -- ===== LADDER =====
        if use_ladders:get() then
            local on_ladder, ltype = check_ladder(lp)
            if on_ladder then
                fix_movement(cmd, vector():angles(0, lp:get_angles().y), move_speed:get())
                if ltype == "on_ladder" then
                    cmd.view_angles.x = -45
                    cmd.upmove = move_speed:get()
                end
                cmd.in_jump = false
                return
            end
        end

        -- ===== STUCK DETECTION =====
        local vel = lp.m_vecVelocity
        local cur_speed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
        if on_ground and cur_speed < stuck_speed:get() then
            stuck_counter = stuck_counter + 1
        else
            stuck_counter = math.max(0, stuck_counter - 1)
        end

        -- ===== PICK DIRECTION =====
        local final_dir
        local enemy_pos = vector(eo.x, eo.y, mo.z + trace_height:get())

        if wall_follow:get() and stuck_counter > 12 then
            -- really stuck: commit to the most open corridor
            local need_new = (escape_dir == nil) or (globals.tickcount > escape_until)
            if not need_new then
                local feet = lp:get_origin()
                local origin = vector(feet.x, feet.y, feet.z + trace_height:get())
                if open_dist_dir(lp, origin, escape_dir, scan_distance:get()) < 50 then
                    need_new = true
                end
            end
            if need_new then
                escape_dir = find_open_corridor(lp)
                escape_until = globals.tickcount + commit_ticks:get()
            end
            final_dir = escape_dir or enemy_dir
            persisted_dir = final_dir
        else
            escape_dir = nil

            -- HEAVY: only recompute the desired direction every 6 ticks (cached).
            -- Between recomputes we just keep steering toward the cached target,
            -- which keeps movement smooth while massively cutting trace count.
            if cached_desired == nil or (globals.tickcount - last_choose_tick) >= 6 then
                local desired = choose_direction(lp, enemy_pos)

                -- apply gentle wall repulsion (also part of the heavy recompute)
                local feet = lp:get_origin()
                local origin = vector(feet.x, feet.y, feet.z + trace_height:get())
                local wpx, wpy = compute_wall_push(lp, origin)
                local nx = desired.x + wpx
                local ny = desired.y + wpy
                local nl = math.sqrt(nx * nx + ny * ny)
                if nl > 0.001 then
                    desired = vector(nx / nl, ny / nl, 0)
                end

                cached_desired = desired
                last_choose_tick = globals.tickcount
            end

            -- strong continuity: smoothly rotate toward the cached dir each tick
            if not persisted_dir then
                persisted_dir = cached_desired
            else
                persisted_dir = rotate_towards(persisted_dir, cached_desired, turn_speed:get())
            end
            final_dir = persisted_dir
        end

        -- build predicted route for blue path visualizer (throttled: heavy on traces)
        if draw_nav:get() then
            if globals.tickcount - last_predict_tick >= 12 then
                predicted_path = predict_route(lp, enemy_pos, final_dir, 30)
                last_predict_tick = globals.tickcount
            end
        else
            predicted_path = {}
        end

        -- ===== VERTICAL (jump vs crouch) - cached every 3 ticks =====
        if (globals.tickcount - last_vert_tick) >= 3 then
            cached_need_jump, cached_need_crouch = scan_vertical(lp, final_dir)
            cached_headroom = (not ceiling_check:get()) or has_headroom(lp)
            last_vert_tick = globals.tickcount
        end
        local need_jump, need_crouch = cached_need_jump, cached_need_crouch
        local headroom = cached_headroom
        if not headroom then
            need_jump = false
            need_crouch = true
        end

        fix_movement(cmd, final_dir, move_speed:get())

        local did_jump = false
        if need_jump and jump_obstacles:get() and on_ground and headroom then
            cmd.in_jump = true
            did_jump = true
        elseif stuck_counter > 16 and jump_obstacles:get() and on_ground and headroom then
            cmd.in_jump = true
            did_jump = true
        elseif auto_bhop:get() and on_ground and not need_crouch and headroom then
            cmd.in_jump = true
            did_jump = true
        end

        if need_crouch and crouch_gaps:get() and not did_jump then
            cmd.in_duck = true
            cmd.in_jump = false
        end
    end)

    -- ============ HUD + NAV DRAW ============
    events.render:set(function()
        if draw_nav:get() and walk_to_enemy:get() then
            -- blue predicted route = where the bot will steer (curves around walls)
            if #predicted_path > 1 then
                for i = 1, #predicted_path - 1 do
                    local a = predicted_path[i]:to_screen()
                    local b = predicted_path[i + 1]:to_screen()
                    if a and b then
                        local alpha = math.floor(255 - (i / #predicted_path) * 100)
                        render.line(a, b, color(40, 160, 255, alpha))
                    end
                end
            end
        end

        local screen = render.screen_size()
        local x, y = screen.x * 0.5, screen.y * 0.72
        local status, clr
        if is_recording then
            status = string.format("RECORDING... (%d)", #recorded); clr = color(255, 60, 60, 230)
        elseif is_replaying then
            status = string.format("REPLAYING %d/%d", replay_index, #recorded); clr = color(60, 150, 255, 230)
        elseif walk_to_enemy:get() then
            local extra = (escape_dir ~= nil) and " [ESCAPING WALL]" or ""
            status = "NAVIGATING" .. extra; clr = color(60, 255, 130, 230)
        else
            return
        end
        render.text(2, vector(x, y), clr, "c", status)
    end)

    events.shutdown:set(function()
        is_recording, is_replaying = false, false
        persisted_dir = nil
        stuck_counter = 0
        escape_dir = nil
        reset_overrides()
    end)
end
