/*
This is a demo to show a number of different ways to render a game with a fixed-timestep simulation.

By Jakub Tomšů

Read https://jakubtomsu.github.io/posts/fixed_timestep_without_interpolation for more info.

Controls
- Use WASD to move the player, space to dash and M to shoot a bullet.
- Use left/right arrow keys to change the simulation mode
- Use up/down arrow keys to change the TPS
*/
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
    2,
    4,
    5,
    10,
    15,
    30,
    40,
    50,
    60,
    75,
    100,
    120,
    180,
    240,
    480,
}

// "Fixed_Interpolated" and "Fixed_Render_Tick" are by far the most important
Simulation_Mode :: enum u8 {
    // This is always "smooth" but not fixed timestep.
    // Sort of like a reference implementation.
    Frame = 0,
    Fixed_No_Smooth,
    Fixed_Interpolated,
    Fixed_Render_Tick,
    Fixed_Accumulated_Render_Tick,
}

g_player_walk_texture: rl.Texture
g_player_idle_texture: rl.Texture
g_bullet_texture: rl.Texture
PLAYER_SPRITE_SIZE_X :: 48
PLAYER_SPRITE_SIZE_Y :: 64
BULLET_SPRITE_SIZE_X :: 16
BULLET_SPRITE_SIZE_Y :: 16

main :: proc() {
    rl.SetConfigFlags({.VSYNC_HINT, .MSAA_4X_HINT})
    rl.InitWindow(1000, 700, "Fixed Timestep Demo")
    defer rl.CloseWindow()

    g_player_idle_texture = rl.LoadTexture("player_idle.png")
    g_player_walk_texture = rl.LoadTexture("player_walk.png")
    g_bullet_texture = rl.LoadTexture("bullet.png")

    tick_input: Input
    game: Game
    temp_game: Game
    interpolated_game: Game // you don't need this in practice!

    game.player_pos = {WINDOW_SIZE_X, WINDOW_SIZE_Y} / 2

    sim_mode: Simulation_Mode
    delta_index: i32 = 2
    slowmo: bool

    accumulator: f32
    prev_accumulator: f32

    draw_debug := true

    for !rl.WindowShouldClose() {
        rl.BeginDrawing()
        defer rl.EndDrawing()
        rl.ClearBackground({40, 45, 50, 255})

        delta := 1.0 / _tick_nums[delta_index]

        if rl.IsKeyPressed(.UP)   do delta_index = (delta_index + 1) %% len(_tick_nums)
        if rl.IsKeyPressed(.DOWN) do delta_index = (delta_index - 1) %% len(_tick_nums)

        if rl.IsKeyPressed(.RIGHT) do sim_mode = Simulation_Mode((int(sim_mode) + 1) %% len(Simulation_Mode))
        if rl.IsKeyPressed(.LEFT)  do sim_mode = Simulation_Mode((int(sim_mode) - 1) %% len(Simulation_Mode))

        if rl.IsKeyPressed(.R) do slowmo = !slowmo
        if rl.IsKeyPressed(.F) do draw_debug = !draw_debug

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
        frame_input.actions[.Shoot] = input_flags_from_key(.M)

        tick_input.cursor = frame_input.cursor
        // _accumulate_ temp flags instead of overwriting
        for flags, action in frame_input.actions {
            tick_input.actions[action] += flags
        }

        // Note: some of the code is duplicated between some of the cases
        // just to make it clearer, since you probably care only one particluar case.
        switch sim_mode {
        case .Frame:
            game_tick(&game, frame_input, rl.GetFrameTime())
            game_draw(game)
            accumulator = 0
            // The rest is just to make the transition to other sim modes less harsh,
            // feel free to ignore it.
            tick_input = {}
            runtime.mem_copy_non_overlapping(&temp_game, &game, size_of(Game))

        case .Fixed_No_Smooth:
            any_tick := accumulator > delta
            defer if any_tick do tick_input = {}
            for ;accumulator > delta; accumulator -= delta {
                game_tick(&game, tick_input, delta)
                input_clear_temp(&tick_input)
            }
            game_draw(game)

        case .Fixed_Interpolated:
            any_tick := accumulator > delta
            defer if any_tick do tick_input = {}
            for ;accumulator > delta; accumulator -= delta {
                runtime.mem_copy_non_overlapping(&temp_game, &game, size_of(Game))
                game_tick(&game, tick_input, delta)
                input_clear_temp(&tick_input)
            }
            alpha := accumulator / delta
            runtime.mem_copy_non_overlapping(&interpolated_game, &game, size_of(Game))
            game_interpolate(&interpolated_game, game, temp_game, alpha)
            if draw_debug {
                game_draw(temp_game, rl.Fade(rl.RED, 0.8))
                game_draw(game, rl.Fade(rl.GREEN, 0.8))
            }
            game_draw(interpolated_game)

        case .Fixed_Render_Tick:
            any_tick := accumulator > delta
            defer if any_tick do tick_input = {}
            for ;accumulator > delta; accumulator -= delta {
                game_tick(&game, tick_input, delta)
                input_clear_temp(&tick_input)
            }
            runtime.mem_copy_non_overlapping(&temp_game, &game, size_of(Game))
            game_tick(&temp_game, tick_input, accumulator)
            if draw_debug {
                game_draw(game, rl.Fade(rl.RED, 0.8))
            }
            game_draw(temp_game)

        case .Fixed_Accumulated_Render_Tick:
            any_tick := accumulator > delta
            defer if any_tick do tick_input = {}
            for ;accumulator > delta; accumulator -= delta {
                game_tick(&game, tick_input, delta)
                input_clear_temp(&tick_input)
            }
            if any_tick {
                runtime.mem_copy_non_overlapping(&temp_game, &game, size_of(Game))
                prev_accumulator = 0
            }
            // input_clear_temp(&frame_input) // !
            game_tick(&temp_game, frame_input, accumulator - prev_accumulator)
            if draw_debug {
                game_draw(game, rl.Fade(rl.RED, 0.8))
            }
            game_draw(temp_game)
            prev_accumulator = accumulator
        }

        action_colors: [Input_Action]rl.Color
        for action in Input_Action {
            mask := bit_set[Input_Flag]{.Down, .Pressed}
            if frame_input.actions[action] & mask != {} {
                action_colors[action] = {220, 230, 240, 255}
            } else if tick_input.actions[action] & mask != {} {
                action_colors[action] = {50, 150, 150, 255}
            } else {
                action_colors[action] = {80, 90, 100, 255}
            }
        }

        rl.DrawRectangleV({10, WINDOW_SIZE_Y - 60}, 20, action_colors[.Left])
        rl.DrawRectangleV({70, WINDOW_SIZE_Y - 60}, 20, action_colors[.Right])
        rl.DrawRectangleV({40, WINDOW_SIZE_Y - 90}, 20, action_colors[.Up])
        rl.DrawRectangleV({40, WINDOW_SIZE_Y - 30}, 20, action_colors[.Down])

        rl.DrawRectangleV({120, WINDOW_SIZE_Y - 30}, 20, action_colors[.Dash])
        rl.DrawRectangleV({160, WINDOW_SIZE_Y - 30}, 20, action_colors[.Shoot])

        rl.DrawFPS(2, 2)
        rl.DrawText(fmt.ctprintf("Sim Mode: {} (left/right)", sim_mode), 2, 22, 20, rl.WHITE)
        rl.DrawText(fmt.ctprintf("Delta: {} ({} TPS) (up/down)", delta, _tick_nums[delta_index]), 2, 44, 20, rl.WHITE)
        rl.DrawText(fmt.ctprintf("Accumulator: {}", accumulator), 2, 66, 20, rl.WHITE)
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

Game :: struct {
    player_pos:        rl.Vector2,
    player_dir:        rl.Vector2,
    player_anim_timer: f32,
    player_moving:     bool,
    bullets:           [1024]Bullet,
}

Bullet :: struct {
    pos:         rl.Vector2,
    vel:         rl.Vector2,
    time:        f32,
    generation:  u32,
}

game_tick :: proc(game: ^Game, input: Input, delta: f32) {
    move_dir: rl.Vector2
    if .Down in input.actions[ .Left] do move_dir.x -= 1
    if .Down in input.actions[.Right] do move_dir.x += 1
    if .Down in input.actions[   .Up] do move_dir.y -= 1
    if .Down in input.actions[ .Down] do move_dir.y += 1

    moving := move_dir != 0

    if moving && .Pressed in input.actions[.Dash] {
        game.player_pos += move_dir * 120
    }

    if moving {
        move_dir = linalg.normalize(move_dir)
        game.player_dir = move_dir
    }

    game.player_pos += move_dir * delta * 150
    game.player_anim_timer += delta
    game.player_moving = moving

    for &bullet in game.bullets {
        if bullet.time == 0 do continue
        bullet.pos += bullet.vel * delta
        bullet.time += delta
        if bullet.time > 0.5 {
            bullet.time = 0
        }
    }

    if .Pressed in input.actions[.Shoot] {
        // Insert, this is a bit dumb. This should
        for &bullet in game.bullets {
            if bullet.time != 0 do continue
            bullet.pos = game.player_pos + game.player_dir * 20
            bullet.vel = game.player_dir * 1000
            bullet.time = 1e-6
            bullet.generation += 1
            break
        }
    }
}

game_draw :: proc(game: Game, tint := rl.WHITE) {
    PIXEL_SCALE :: 5

    // Player
    {
        tex := game.player_moving ? g_player_walk_texture : g_player_idle_texture

        // HACK
        dir_row := 0
        if game.player_dir.y >= 0 {
            if game.player_dir.y > 0.86 {
                dir_row = 0
            } else {
                dir_row = game.player_dir.x > 0 ? 5 : 1
            }
        } else {
            if game.player_dir.y < -0.86 {
                dir_row = 3
            } else {
                dir_row = game.player_dir.x > 0 ? 4 : 2
            }
        }

        src_rect := rl.Rectangle{
            f32(int(game.player_anim_timer * 10)) * PLAYER_SPRITE_SIZE_X,
            f32(dir_row) * PLAYER_SPRITE_SIZE_Y,
            PLAYER_SPRITE_SIZE_X,
            PLAYER_SPRITE_SIZE_Y,
        }

        dst_rect := rl.Rectangle{
            game.player_pos.x,
            game.player_pos.y,
            PLAYER_SPRITE_SIZE_X * PIXEL_SCALE,
            PLAYER_SPRITE_SIZE_Y * PIXEL_SCALE,
        }

        rl.DrawTexturePro(tex, src_rect, dst_rect, {dst_rect.width * 0.5, dst_rect.height * 0.5}, 0, tint)
    }

    for bullet in game.bullets {
        if bullet.time == 0 do continue

        src_rect := rl.Rectangle{
            f32(int(bullet.time * 20)) * BULLET_SPRITE_SIZE_X,
            0,
            BULLET_SPRITE_SIZE_X,
            BULLET_SPRITE_SIZE_Y,
        }

        dst_rect := rl.Rectangle{
            bullet.pos.x,
            bullet.pos.y,
            BULLET_SPRITE_SIZE_X * PIXEL_SCALE,
            BULLET_SPRITE_SIZE_Y * PIXEL_SCALE,
        }


        rl.DrawTexturePro(
            g_bullet_texture,
            src_rect,
            dst_rect,
            {dst_rect.width * 0.5, dst_rect.height * 0.5},
            0,
            tint,
        )
    }
}

// This is a separate proc just because of the structure of this example,
// if you wanted interpolation in practice you could inline it into the game_draw proc.
// Assumes 'result' starts out with the same state as 'game'
game_interpolate :: proc(result: ^Game, game, prev_game: Game, alpha: f32) {
    result.player_pos = lerp(prev_game.player_pos, game.player_pos, alpha)
    result.player_anim_timer = lerp(prev_game.player_anim_timer, game.player_anim_timer, alpha)

    for bullet, i in game.bullets {
        prev_bullet := prev_game.bullets[i]
        if bullet.time == 0 || prev_bullet.generation != game.bullets[i].generation {
            result.bullets[i].time = 0
            continue
        }
        result.bullets[i] = {
            pos  = lerp(prev_bullet.pos,  bullet.pos,  alpha),
            vel  = lerp(prev_bullet.vel,  bullet.vel,  alpha),
            time = lerp(prev_bullet.time, bullet.time, alpha),
            generation = bullet.generation,
        }
    }
}

lerp :: proc(a, b: $T, t: f32) -> T {
    return a * (1 - t) + b * t
}