package fixed_timestep_demo

import rl "vendor:raylib"
import "vendor:raylib/rlgl"
import sa "core:container/small_array"
import "core:math"
import "core:math/linalg"
import "core:fmt"
import "base:runtime"

WINDOW_SIZE_X :: 1000
WINDOW_SIZE_Y :: 700

_tick_nums := [?]f32 {
    1,
    5,
    15,
    30,
    60,
    120,
    240,
}

Simulation_Mode :: enum u8 {
    // This is always "smooth" but not fixed timestep.
    // Sort of like a reference implementation.
    Frame = 0,
    Fixed_No_Smooth,
    Fixed_Interpolated,
    Fixed_Render_Tick,
    Fixed_Accumulated_Render_Tick,
}

main :: proc() {
    rl.SetConfigFlags({.VSYNC_HINT, .MSAA_4X_HINT})
    rl.InitWindow(1000, 700, "Fixed Timestep Demo")
    defer rl.CloseWindow()

    tick_input: Input
    game: Game
    temp_game: Game
    interpolated_game: Game // you don't need this in practice!

    game.player_pos = {BOUNDS_X, BOUNDS_Y} / 2

    sim_mode: Simulation_Mode
    delta_index: i32
    slowmo: bool

    accumulator: f32
    prev_accumulator: f32

    for !rl.WindowShouldClose() {
        rl.BeginDrawing()
        defer rl.EndDrawing()
        rl.ClearBackground({20, 25, 30, 255})

        delta := 1.0 / _tick_nums[delta_index]

        if rl.IsKeyPressed(.UP)   do delta_index = (delta_index + 1) %% len(_tick_nums)
        if rl.IsKeyPressed(.DOWN) do delta_index = (delta_index - 1) %% len(_tick_nums)

        if rl.IsKeyPressed(.RIGHT) do sim_mode = Simulation_Mode((int(sim_mode) + 1) %% len(Simulation_Mode))
        if rl.IsKeyPressed(.LEFT)  do sim_mode = Simulation_Mode((int(sim_mode) - 1) %% len(Simulation_Mode))

        if rl.IsKeyPressed(.Q) do slowmo = !slowmo

        // Note: this input handling is a bit silly with raylib but it's good enough for this example

        frame_time := rl.GetFrameTime()
        if slowmo do frame_time *= 0.1
        accumulator += frame_time

        frame_input: Input
        frame_input.cursor = rl.GetMousePosition()
        frame_input.actions[.Left ] = input_flags_from_key(.A)
        frame_input.actions[.Right] = input_flags_from_key(.D)
        frame_input.actions[.Up   ] = input_flags_from_key(.W)
        frame_input.actions[.Down ] = input_flags_from_key(.S)
        frame_input.actions[.Dash ] = input_flags_from_key(.SPACE)
        frame_input.actions[.Shoot] = input_flags_from_mouse_button(.LEFT)

        tick_input.cursor = frame_input.cursor
        // _accumulate_ temp flags instead of overwriting
        for flags, action in frame_input.actions {
            tick_input.actions[action] -= {.Down}
            tick_input.actions[action] += flags
        }

        // Note: some of the code is duplicated between some of the cases
        // just to make it clearer, since you probably care only one particluar case.
        switch sim_mode {
        case .Frame:
            game_tick(&game, frame_input, rl.GetFrameTime())
            input_clear_temp(&tick_input) // Not necessary
            game_draw(game)
            accumulator = 0

        case .Fixed_No_Smooth:
            for ;accumulator > delta; accumulator -= delta {
                game_tick(&game, tick_input, delta)
                input_clear_temp(&tick_input)
            }
            game_draw(game)

        case .Fixed_Interpolated:
            for ;accumulator > delta; accumulator -= delta {
                runtime.mem_copy_non_overlapping(&temp_game, &game, size_of(Game))
                game_tick(&game, tick_input, delta)
                input_clear_temp(&tick_input)
            }
            alpha := accumulator / delta
            runtime.mem_copy_non_overlapping(&interpolated_game, &game, size_of(Game))
            game_interpolate(&interpolated_game, game, temp_game, alpha)
            game_draw(interpolated_game)

        case .Fixed_Render_Tick:
            for ;accumulator > delta; accumulator -= delta {
                game_tick(&game, tick_input, delta)
                input_clear_temp(&tick_input)
            }
            runtime.mem_copy_non_overlapping(&temp_game, &game, size_of(Game))
            game_tick(&temp_game, tick_input, accumulator)
            game_draw(temp_game)

        case .Fixed_Accumulated_Render_Tick:
            any_tick := accumulator > delta
            for ;accumulator > delta; accumulator -= delta {
                game_tick(&game, tick_input, delta)
                input_clear_temp(&tick_input)
            }
            if any_tick {
                runtime.mem_copy_non_overlapping(&temp_game, &game, size_of(Game))
                prev_accumulator = 0
            }
            input_clear_temp(&frame_input) // !
            game_tick(&temp_game, frame_input, accumulator - prev_accumulator)
            game_draw(temp_game)
            prev_accumulator = accumulator
        }

        rl.DrawFPS(2, 2)

        rl.DrawText(fmt.ctprintf("Sim Mode: {} (left/right)", sim_mode), 2, 22, 20, rl.WHITE)
        rl.DrawText(fmt.ctprintf("Delta: {} ({} TPS) (up/down)", delta, _tick_nums[delta_index]), 2, 44, 20, rl.WHITE)
        rl.DrawText(fmt.ctprintf("Accumulator: {}", accumulator), 2, 66, 20, rl.WHITE)

        game_draw_debug(game, rl.Fade(rl.GREEN, 0.5))
    }
}

////////////////////////////////////////////////////////////////////////////////////
// Input
//

Input :: struct {
    cursor:    rl.Vector2,
    actions:   [Input_Action]bit_set[Input_Flag],
}

Input_Action :: enum u8 {
    Left,
    Right,
    Up,
    Down,
    Dash,
    Shoot,
}

Input_Flag :: enum u8 {
    Down,
    Pressed,
    Released,
}

input_flags_from_key :: proc(key: rl.KeyboardKey) -> (flags: bit_set[Input_Flag]) {
    if rl.IsKeyDown(key) do flags += {.Down}
    if rl.IsKeyPressed(key) do flags += {.Pressed}
    if rl.IsKeyReleased(key) do flags += {.Released}
    return
}

input_flags_from_mouse_button :: proc(mb: rl.MouseButton) -> (flags: bit_set[Input_Flag]) {
    if rl.IsMouseButtonDown(mb) do flags += {.Down}
    if rl.IsMouseButtonPressed(mb) do flags += {.Pressed}
    if rl.IsMouseButtonReleased(mb) do flags += {.Released}
    return
}

input_clear_temp :: proc(input: ^Input) {
    for &action in input.actions {
        action -= ~{.Down} // clear all except down flag
    }
}

////////////////////////////////////////////////////////////////////////////////////
// Game
//

BOUNDS_X :: 800
BOUNDS_Y :: 600

MAX_BULLETS :: 1024
MAX_ENEMIES :: 256
MAX_PARTICLES :: 1024

PLAYER_RAD :: 10
ENEMY_RAD :: 20
BULLET_RAD :: 5
LOOT_RAD :: 30

BULLET_SPEED :: 2000
ENEMY_ACCEL :: 10
PLAYER_ACCEL :: 10000
PLAYER_FRICT :: 100
PLAYER_MIN_CHARGE_TIME :: 0.1
PLAYER_MAX_CHARGE_TIME :: 2

Game :: struct {
    camera_pos:         rl.Vector2,
    shake:              f32,
    spawn_timer:        f32,
    player_pos:         rl.Vector2,
    player_vel:         rl.Vector2,
    player_dash_timer:  f32,
    player_shoot_timer: f32,
    player_ammo:        i32,
    enemies:            [MAX_ENEMIES]Enemy,
    bullets:            [MAX_BULLETS]Bullet,
}

Enemy :: struct {
    pos:          rl.Vector2,
    vel:          rl.Vector2,
    health:       f32,
    state:        Enemy_State,
    damage_timer: f32,
    timer:        f32,
}

Enemy_State :: enum u8 {
    None = 0,
    Default,
    Loot,
}

Bullet :: struct {
    state:    Bullet_State,
    pos:      rl.Vector2,
    vel:      rl.Vector2,
    timer:    f32,
    charge:   f32, // 0..1
}

Bullet_State :: enum u8 {
    None = 0,
    Flying,
}

game_view_offset :: proc(game: Game) -> rl.Vector2 {
    return {game.camera_pos.x - WINDOW_SIZE_X / 2, game.camera_pos.y - WINDOW_SIZE_Y / 2}
}

game_tick :: proc(game: ^Game, input: Input, delta: f32) {
    game.shake = clamp(game.shake - delta, 0, 100)

    cam_target := lerp(game.player_pos, rl.Vector2{BOUNDS_X, BOUNDS_Y} / 2, 0.6)
    game.camera_pos = lerp_exp(game.camera_pos, cam_target, 2 * delta)

    game.spawn_timer += delta
    if game.spawn_timer > 5.0 {
        game.spawn_timer = 0

        // find dead enemy slot in O(n), who cares.
        // In practice use a pool with a free list.
        for &enemies in game.enemies {
            if enemies.state != .None do continue
            enemies = Enemy{
                pos = 0,
                health = 6,
            }
        }
    }

    // Player

    player_move: rl.Vector2
    if .Down in input.actions[ .Left] do player_move.x -= 1
    if .Down in input.actions[.Right] do player_move.x += 1
    if .Down in input.actions[   .Up] do player_move.y -= 1
    if .Down in input.actions[ .Down] do player_move.y += 1

    prev_dash := game.player_dash_timer > 0.0
    game.player_dash_timer -= delta
    if game.player_dash_timer > 0.0 {
    } else {
        if prev_dash do game.player_vel *= 0.2
        game.player_vel += player_move * delta * PLAYER_ACCEL
        // game.player_vel = lerp_exp(game.player_vel, 0, clamp(delta * PLAYER_FRICT, 0, 1))
        game.player_vel /= 1.0 + (delta * PLAYER_FRICT)
    }
    game.player_pos += game.player_vel * delta
    game.player_pos = {
        clamp(game.player_pos.x, 0, BOUNDS_X),
        clamp(game.player_pos.y, 0, BOUNDS_Y),
    }

    if .Pressed in input.actions[.Dash] && game.player_dash_timer < -1 {
        game.player_dash_timer = 0.1
        game.player_vel = player_move * 1000
        game.shake += 2
    }

    if .Released in input.actions[.Shoot] && game.player_shoot_timer > PLAYER_MIN_CHARGE_TIME {
        // linear remap
        charge := clamp((game.player_shoot_timer - PLAYER_MIN_CHARGE_TIME) / PLAYER_MAX_CHARGE_TIME, 0, 1)
        aim_dir := linalg.normalize0(input.cursor - game.player_pos + game_view_offset(game^))
        // Linear search to find empty slot. In practice use a pool with a free list.
        for &bullet in game.bullets {
            if bullet.state != .None do continue
            bullet = Bullet{
                state = .Flying,
                pos = game.player_pos + aim_dir,
                vel = aim_dir * BULLET_SPEED,
                charge = charge,
            }
            break
        }
        game.shake += 0.5
    }

    if .Down in input.actions[.Shoot] {
        game.player_shoot_timer += delta
    } else {
        game.player_shoot_timer = 0
    }

    // Bullets

    for &bullet, i in game.bullets {
        if bullet.state == .None do continue

        bullet.timer += delta
        if bullet.timer > 2 {
            bullet.state = .None
        }

        if bullet.pos.x < 0 || bullet.pos.x > BOUNDS_X ||
           bullet.pos.y < 0 || bullet.pos.y > BOUNDS_Y {
            bullet.state = .None
        }

        move := bullet.vel * delta

        // Silly O(n^2) collision
        hit := false
        for &enemy in game.enemies {
            if enemy.state != .Default do continue
            if !#force_inline test_segment_circle(bullet.pos, move, enemy.pos, ENEMY_RAD) do continue
            hit = true
            bullet.state = .None
            enemy.health -= lerp(f32(1), 4, bullet.charge * bullet.charge)
            enemy.damage_timer = 0
            break
        }

        bullet.pos += move
    }

    // Enemies

    for &enemy, enemy_i in game.enemies {
        switch enemy.state {
        case .None:
        case .Loot:
            if linalg.distance(game.player_pos, enemy.pos) < LOOT_RAD {
                enemy.state = .None
                game.player_ammo += 1
            }

        case .Default:
            if enemy.health <= 0.0 {
                enemy.state = .Loot
            }

            enemy.timer += delta

            enemy.damage_timer += delta
            if enemy.damage_timer < 1.0 {
                break
            }

            dir := linalg.normalize0(game.player_pos - enemy.pos)
            enemy.vel += dir * ENEMY_ACCEL

            // Silly O(n^2) collision again...
            push: rl.Vector2
            for other_enemy, other_enemy_i in game.enemies {
                if other_enemy.state != .Default do continue
                if enemy_i == other_enemy_i do continue
                dir := enemy.pos - other_enemy.pos
                push += dir / (0.5 + linalg.length(dir) * 0.05)
            }
            enemy.vel += push * delta
        }
    }
}

game_draw :: proc(game: Game) {
    rlgl.PushMatrix()
    view_offset := game_view_offset(game)
    rlgl.Translatef(-view_offset.x, -view_offset.y, 0)
    defer rlgl.PopMatrix()

    rl.DrawRectangle(0, 0, BOUNDS_X, BOUNDS_Y, {30, 35, 40, 255})

    rl.DrawRectangleV(game.player_pos - PLAYER_RAD, PLAYER_RAD * 2, game.player_dash_timer < -1 ? rl.WHITE : rl.GRAY)

    for enemy in game.enemies {
        color := [4]f32{0.2, 0.2, 0.2, 1.0}
        color.r = lerp(f32(1), color.r, clamp(enemy.damage_timer * 2, 0, 1))
        color = lerp(([4]f32)(1), color, clamp(enemy.damage_timer * 6, 0, 1))
        height: f32 = 1.3
        height += math.sin(enemy.timer * 5) * 0.1
        height += lerp(f32(0.3), 0, clamp(enemy.damage_timer * 3, 0, 1))
        rl.DrawRectangleV(enemy.pos - ENEMY_RAD, ENEMY_RAD * {1, height}, rl.ColorFromNormalized(color))
    }

    for bullet in game.bullets {
        if bullet.state == .None do continue
        // HACK: don't interpolate just after spawning.
        // Ideally you would handle this with a handle based pool which stores generations.
        // However it's bad the interpolation has shit problem in the first place...
        if bullet.timer <= 0.0001 do continue
        dir := linalg.normalize0(bullet.vel)
        rad := BULLET_RAD * rl.Vector2{1, 10}
        sideways := rl.Vector2{dir.y, -dir.x}
        rl.DrawTriangle(
            bullet.pos + (dir - sideways) * BULLET_RAD,
            bullet.pos + (dir + sideways) * BULLET_RAD,
            bullet.pos - bullet.vel * 0.02,
            {20, 200, 255, 255},
        )
    }
}

// This is a separate proc just because of the structure of this example,
// if you wanted interpolation in practice you could inline it into the game_draw proc.
// Assumes 'result' starts out with the same state as 'game'
game_interpolate :: proc(result: ^Game, game, prev_game: Game, alpha: f32) {
    result.shake = lerp(prev_game.shake, game.shake, alpha)
    result.camera_pos = lerp(prev_game.camera_pos, game.camera_pos, alpha)

    result.player_pos = lerp(prev_game.player_pos, game.player_pos, alpha)
    result.player_vel = lerp(prev_game.player_vel, game.player_vel, alpha)

    for &enemy, i in result.enemies {
        enemy.pos          = lerp(prev_game.enemies[i].pos,          game.enemies[i].pos,          alpha)
        enemy.vel          = lerp(prev_game.enemies[i].vel,          game.enemies[i].vel,          alpha)
        enemy.damage_timer = lerp(prev_game.enemies[i].damage_timer, game.enemies[i].damage_timer, alpha)
    }

    for &bullet, i in result.bullets {
        bullet.pos   = lerp(prev_game.bullets[i].pos,   game.bullets[i].pos,   alpha)
        bullet.vel   = lerp(prev_game.bullets[i].vel,   game.bullets[i].vel,   alpha)
    }
}

game_draw_debug :: proc(game: Game, color: rl.Color) {
    rlgl.PushMatrix()
    view_offset := game_view_offset(game)
    rlgl.Translatef(-view_offset.x, -view_offset.y, 0)
    defer rlgl.PopMatrix()

    rl.DrawCircleLinesV(game.player_pos, PLAYER_RAD, color)

    for enemy, i in game.enemies {
        rl.DrawCircleLinesV(enemy.pos, ENEMY_RAD, color)
    }

    for bullet, i in game.bullets {
        rl.DrawCircleLinesV(bullet.pos, BULLET_RAD, color)
    }
}


////////////////////////////////////////////////////////////////////////////////////
// Utils
//

lerp :: proc(a, b: $T, t: f32) -> T {
    return a * (1 - t) + b * t
}

// Multiply rate by delta to get frame rate independent interpolation
lerp_exp :: proc(a, b: $T, rate: f32) -> T {
    return lerp(b, a, math.exp(-rate))
}

// Segment defined by points [pos, pos + dir]
test_segment_circle :: proc(pos, dir, center: rl.Vector2, rad: f32) -> bool {
    m := pos - center
    c := linalg.dot(m, m) - rad * rad
    // If there is definitely at least one real root, there must be an intersection
    if c <= 0 do return true
    b := linalg.dot(m, dir)
    // Early exit if ray origin outside sphere and ray pointing away from sphere
    if b > 0 do return false
    discr := b * b - c
    // A negative discriminant corresponds to ray missing sphere
    if discr < 0 {
        return false
    }
    t := -b - math.sqrt(discr)
    return t < 1
}