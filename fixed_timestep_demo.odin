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

g_character_walk_texture: rl.Texture
g_character_idle_texture: rl.Texture
SPRITE_SIZE_X :: 48
SPRITE_SIZE_Y :: 64

main :: proc() {
    rl.SetConfigFlags({.VSYNC_HINT, .MSAA_4X_HINT})
    rl.InitWindow(1000, 700, "Fixed Timestep Demo")
    defer rl.CloseWindow()

    g_character_idle_texture = rl.LoadTexture("character_idle.png")
    g_character_walk_texture = rl.LoadTexture("character_walk.png")

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
            tick_input = {} // unnecessary

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
            input_clear_temp(&frame_input) // !
            game_tick(&temp_game, frame_input, accumulator - prev_accumulator)
            if draw_debug {
                game_draw(game, rl.Fade(rl.RED, 0.8))
            }
            game_draw(temp_game)
            prev_accumulator = accumulator
        }

        rl.DrawFPS(2, 2)

        rl.DrawText(fmt.ctprintf("Sim Mode: {} (left/right)", sim_mode), 2, 22, 20, rl.WHITE)
        rl.DrawText(fmt.ctprintf("Delta: {} ({} TPS) (up/down)", delta, _tick_nums[delta_index]), 2, 44, 20, rl.WHITE)
        rl.DrawText(fmt.ctprintf("Accumulator: {}", accumulator), 2, 66, 20, rl.WHITE)

        // game_draw_debug(game, rl.Fade(rl.GREEN, 0.5))
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
}

game_draw :: proc(game: Game, tint := rl.WHITE) {
    tex := game.player_moving ? g_character_walk_texture : g_character_idle_texture

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
        f32(int(game.player_anim_timer * 10)) * SPRITE_SIZE_X,
        f32(dir_row) * SPRITE_SIZE_Y,
        SPRITE_SIZE_X,
        SPRITE_SIZE_Y,
    }

    SCALE :: 4
    dst_rect := rl.Rectangle{
        game.player_pos.x,
        game.player_pos.y,
        SPRITE_SIZE_X * SCALE,
        SPRITE_SIZE_Y * SCALE,
    }

    rl.DrawTexturePro(tex, src_rect, dst_rect, {dst_rect.width * 0.5, dst_rect.height * 0.5}, 0, tint)
}

// This is a separate proc just because of the structure of this example,
// if you wanted interpolation in practice you could inline it into the game_draw proc.
// Assumes 'result' starts out with the same state as 'game'
game_interpolate :: proc(result: ^Game, game, prev_game: Game, alpha: f32) {
    result.player_pos = lerp(prev_game.player_pos, game.player_pos, alpha)
    result.player_anim_timer = lerp(prev_game.player_anim_timer, game.player_anim_timer, alpha)
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