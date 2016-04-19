const std = @import("std");
const Rand = std.Rand;
use @import("math3d.zig");
use @import("c.zig");
use @import("all_shaders.zig");
use @import("static_geometry.zig");
use @import("debug_gl.zig");
use @import("pieces.zig");
use @import("spritesheet.zig");

struct Tetris {
    window: &GLFWwindow,
    shaders: AllShaders,
    static_geometry: StaticGeometry,
    projection: Mat4x4,
    rand: Rand,
    piece_delay: f64,
    delay_left: f64,
    grid: [grid_height][grid_width]Cell,
    next_piece: &Piece,
    cur_piece: &Piece,
    cur_piece_x: i32,
    cur_piece_y: i32,
    cur_piece_rot: i32,
    score: c_int,
    game_over: bool,
    next_particle_index: i32,
    next_falling_block_index: i32,
    font: Spritesheet,
    ghost_y: i32,
    framebuffer_width: c_int,
    framebuffer_height: c_int,
    screen_shake_timeout: f64,
    screen_shake_elapsed: f64,
    level: i32,
    time_till_next_level: f64,
    piece_pool: [pieces.len]i32,
    is_paused: bool,

    particles: [max_particle_count]Particle,
    falling_blocks: [max_falling_block_count]Particle,
}

enum Cell {
    Empty,
    Color: Vec4,
}

struct Particle {
    // TODO make this a maybe
    used: bool,
    color: Vec4,
    pos: Vec3,
    vel: Vec3,
    axis: Vec3,
    scale_w: f32,
    scale_h: f32,
    angle: f32,
    angle_vel: f32,
}

const PI = 3.14159265358979;
const max_particle_count = 500;
const max_falling_block_count = grid_width * grid_height;
const margin_size = 10;
const grid_width = 10;
const grid_height = 20;
const cell_size = 32;
const board_width = grid_width * cell_size;
const board_height = grid_height * cell_size;
const board_left = margin_size;
const board_top = margin_size;

const next_piece_width = margin_size + 4 * cell_size + margin_size;
const next_piece_height = next_piece_width;
const next_piece_left = board_left + board_width + margin_size;
const next_piece_top = board_top + board_height - next_piece_height;

const score_width = next_piece_width;
const score_height = next_piece_height;
const score_left = next_piece_left;
const score_top = next_piece_top - margin_size - score_height;

const level_display_width = next_piece_width;
const level_display_height = next_piece_height;
const level_display_left = next_piece_left;
const level_display_top = score_top - margin_size - level_display_height;

const window_width = next_piece_left + next_piece_width + margin_size;
const window_height = board_top + board_height + margin_size;

const board_color = Vec4 { .data = []f32 {72.0/255.0, 72.0/255.0, 72.0/255.0, 1.0}};

const init_piece_delay = 0.5;
const min_piece_delay = 0.05;
const level_delay_increment = 0.05;

const font_char_width = 18;
const font_char_height = 32;

const gravity = 0.14;
const time_per_level = 60.0;

// TODO use * syntax when it is supported to create this
const empty_row = []Cell{
    Cell.Empty, Cell.Empty, Cell.Empty, Cell.Empty, Cell.Empty,
    Cell.Empty, Cell.Empty, Cell.Empty, Cell.Empty, Cell.Empty,
};


// TODO avoid having to make this function export
export fn tetris_error_callback(err: c_int, description: ?&const u8) {
    printf(c"Error: %s\n", description);
    abort();
}

// TODO avoid having to make this function export
export fn tetris_key_callback(window: ?&GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) {
    if (action != GLFW_PRESS) return;
    const t = (&Tetris)(??glfwGetWindowUserPointer(window));

    switch (key) {
        GLFW_KEY_ESCAPE => glfwSetWindowShouldClose(window, GL_TRUE),
        GLFW_KEY_SPACE => user_drop_cur_piece(t),
        GLFW_KEY_DOWN => user_cur_piece_fall(t),
        GLFW_KEY_LEFT => user_move_cur_piece(t, -1),
        GLFW_KEY_RIGHT => user_move_cur_piece(t, 1),
        GLFW_KEY_UP => user_rotate_cur_piece(t, 1),
        GLFW_KEY_LEFT_SHIFT,
        GLFW_KEY_RIGHT_SHIFT => user_rotate_cur_piece(t, -1),
        GLFW_KEY_R => restart_game(t),
        GLFW_KEY_P => user_toggle_pause(t),
        else => {},
    }
}


var tetris_state : Tetris = undefined;

const font_png = @embed_file("../assets/font.png");

export fn main(argc: c_int, argv: &&u8) -> c_int {
    glfwSetErrorCallback(tetris_error_callback);

    if (glfwInit() == GL_FALSE) {
        printf(c"GLFW init failure\n");
        abort();
    }
    defer glfwTerminate();

    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 2);
    glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GL_TRUE);
    glfwWindowHint(GLFW_OPENGL_DEBUG_CONTEXT, gl_debug_on);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
    glfwWindowHint(GLFW_DEPTH_BITS, 0);
    glfwWindowHint(GLFW_STENCIL_BITS, 8);
    glfwWindowHint(GLFW_RESIZABLE, GL_FALSE);

    var window = glfwCreateWindow(window_width, window_height, c"Tetris", null, null) ?? {
        printf(c"unable to create window\n");
        abort();
    };
    defer glfwDestroyWindow(window);

    glfwSetKeyCallback(window, tetris_key_callback);
    glfwMakeContextCurrent(window);
    glfwSwapInterval(1);

    // create and bind exactly one vertex array per context and use
    // glVertexAttribPointer etc every frame.
    var vertex_array_object : GLuint = undefined;
    glGenVertexArrays(1, &vertex_array_object);
    glBindVertexArray(vertex_array_object);
    defer glDeleteVertexArrays(1, &vertex_array_object);

    const rand_seed = get_random_seed() %% {
        printf(c"unable to get random seed\n");
        abort();
    };

    const t = &tetris_state;
    glfwGetFramebufferSize(window, &t.framebuffer_width, &t.framebuffer_height);
    if (t.framebuffer_width < window_width || t.framebuffer_height < window_height) unreachable{};

    t.window = window;

    t.shaders = create_all_shaders();
    defer t.shaders.destroy();

    t.static_geometry = create_static_geometry();
    defer t.static_geometry.destroy();

    t.font = spritesheet_init(font_png, font_char_width, font_char_height) %% {
        printf(c"unable to read assets\n");
        abort();
    };
    defer t.font.deinit();

    reset_projection(t);
    t.rand = Rand.init(rand_seed);

    restart_game(t);

    glClearColor(0.0, 0.0, 0.0, 1.0);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

    glViewport(0, 0, t.framebuffer_width, t.framebuffer_height);
    glfwSetWindowUserPointer(window, (&c_void)(t));

    assert_no_gl_error();

    const start_time = glfwGetTime();
    var prev_time = start_time;

    while (glfwWindowShouldClose(window) == GL_FALSE) {
        glClear(GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT|GL_STENCIL_BUFFER_BIT);

        const now_time = glfwGetTime();
        const elapsed = now_time - prev_time;
        prev_time = now_time;

        next_frame(t, elapsed);

        draw(t);
        glfwSwapBuffers(window);

        glfwPollEvents();
    }

    assert_no_gl_error();

    return 0;
}

fn fill_rect_mvp(t: &Tetris, color: Vec4, mvp: Mat4x4) {
    t.shaders.primitive.bind();
    t.shaders.primitive.set_uniform_vec4(t.shaders.primitive_uniform_color, color);
    t.shaders.primitive.set_uniform_mat4x4(t.shaders.primitive_uniform_mvp, mvp);

    glBindBuffer(GL_ARRAY_BUFFER, t.static_geometry.rect_2d_vertex_buffer);
    glEnableVertexAttribArray(GLuint(t.shaders.primitive_attrib_position));
    glVertexAttribPointer(GLuint(t.shaders.primitive_attrib_position), 3, GL_FLOAT, GL_FALSE, 0, null);

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

fn fill_rect(t: &Tetris, color: Vec4, x: f32, y: f32, w: f32, h: f32) {
    const model = mat4x4_identity.translate(x, y, 0.0).scale(w, h, 0.0);
    const mvp = t.projection.mult(model);
    fill_rect_mvp(t, color, mvp);
}

fn draw_particle(t: &Tetris, p: Particle) {
    const model = mat4x4_identity
        .translate_by_vec(p.pos)
        .rotate(p.angle, p.axis)
        .scale(p.scale_w, p.scale_h, 0.0);

    const mvp = t.projection.mult(model);

    t.shaders.primitive.bind();
    t.shaders.primitive.set_uniform_vec4(t.shaders.primitive_uniform_color, p.color);
    t.shaders.primitive.set_uniform_mat4x4(t.shaders.primitive_uniform_mvp, mvp);

    glBindBuffer(GL_ARRAY_BUFFER, t.static_geometry.triangle_2d_vertex_buffer);
    glEnableVertexAttribArray(GLuint(t.shaders.primitive_attrib_position));
    glVertexAttribPointer(GLuint(t.shaders.primitive_attrib_position), 3, GL_FLOAT, GL_FALSE, 0, null);

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 3);
}

fn draw_falling_block(t: &Tetris, p: Particle) {
    const model = mat4x4_identity
        .translate_by_vec(p.pos)
        .rotate(p.angle, p.axis)
        .scale(p.scale_w, p.scale_h, 0.0);

    const mvp = t.projection.mult(model);

    fill_rect_mvp(t, p.color, mvp);
}

fn get_random_seed() -> %u32 {
    var seed : u32 = undefined;
    const seed_bytes = (&u8)(&seed)[0...4];
    %return std.os.get_random_bytes(seed_bytes);
    return seed;
}

fn draw_centered_text(t: &Tetris, text: []u8) {
    const label_width = font_char_width * i32(text.len);
    const draw_left = board_left + board_width / 2 - label_width / 2;
    const draw_top = board_top + board_height / 2 - font_char_height / 2;
    draw_text(t, text, draw_left, draw_top, 1.0);
}

fn draw(t: &Tetris) {
    fill_rect(t, board_color, board_left, board_top, board_width, board_height);
    fill_rect(t, board_color, next_piece_left, next_piece_top, next_piece_width, next_piece_height);
    fill_rect(t, board_color, score_left, score_top, score_width, score_height);
    fill_rect(t, board_color, level_display_left, level_display_top, level_display_width, level_display_height);

    if (t.game_over) {
        draw_centered_text(t, "GAME OVER");
    } else if (t.is_paused) {
        draw_centered_text(t, "PAUSED");
    } else {
        const abs_x = board_left + t.cur_piece_x * cell_size;
        const abs_y = board_top + t.cur_piece_y * cell_size;
        draw_piece(t, t.cur_piece, abs_x, abs_y, t.cur_piece_rot);

        const ghost_color = vec4(
            t.cur_piece.color.data[0],
            t.cur_piece.color.data[1],
            t.cur_piece.color.data[2],
            0.2);
        draw_piece_with_color(t, t.cur_piece, abs_x, t.ghost_y, t.cur_piece_rot, ghost_color);

        draw_piece(t, t.next_piece, next_piece_left + margin_size, next_piece_top + margin_size, 0);

        for (t.grid) |row, y| {
            for (row) |cell, x| {
                switch (cell) {
                    Color => |color| {
                        const cell_left = board_left + i32(x) * cell_size;
                        const cell_top = board_top + i32(y) * cell_size;
                        fill_rect(t, color, f32(cell_left), f32(cell_top), cell_size, cell_size);
                    },
                    else => {},
                }
            }
        }
    }

    {
        const score_text = "SCORE:";
        const score_label_width = font_char_width * i32(score_text.len);
        draw_text(t, score_text,
            score_left + score_width / 2 - score_label_width / 2,
            score_top + margin_size, 1.0);
    }
    {
        var score_text_buf: [20]u8 = undefined;
        const len = sprintf(&score_text_buf[0], c"%d", t.score);
        const score_text = score_text_buf[0...len];
        const score_label_width = font_char_width * i32(score_text.len);
        draw_text(t, score_text,
            score_left + score_width / 2 - score_label_width / 2,
            score_top + score_height / 2, 1.0);
    }
    {
        const text = "LEVEL:";
        const text_width = font_char_width * i32(text.len);
        draw_text(t, text,
            level_display_left + level_display_width / 2 - text_width / 2,
            level_display_top + margin_size, 1.0);
    }
    {
        var text_buf: [20]u8 = undefined;
        const len = sprintf(&text_buf[0], c"%d", t.level);
        const text = text_buf[0...len];
        const text_width = font_char_width * i32(text.len);
        draw_text(t, text,
            level_display_left + level_display_width / 2 - text_width / 2,
            level_display_top + level_display_height / 2, 1.0);
    }

    for (t.falling_blocks) |particle| {
        if (particle.used) {
            draw_falling_block(t, particle);
        }
    }

    for (t.particles) |particle| {
        if (particle.used) {
            draw_particle(t, particle);
        }
    }


}

fn draw_text(t: &Tetris, text: []u8, left: i32, top: i32, size: f32) {
    for (text) |c, i| {
        if (c <= '~') {
            const char_left = f32(left) + f32(i * font_char_width) * size;
            const model = mat4x4_identity.translate(char_left, f32(top), 0.0).scale(size, size, 0.0);
            const mvp = t.projection.mult(model);

            // TODO u8 should implicitly cast to i32
            t.font.draw(t.shaders, i32(c), mvp);
        } else {
            unreachable{};
        }
    }
}

fn draw_piece(t: &Tetris, piece: &Piece, left: i32, top: i32, rot: i32) {
    draw_piece_with_color(t, piece, left, top, rot, piece.color);
}

fn draw_piece_with_color(t: &Tetris, piece: &Piece, left: i32, top: i32, rot: i32, color: Vec4) {
    for (piece.layout[rot]) |row, y| {
        for (row) |is_filled, x| {
            if (!is_filled) continue;
            const abs_x = f32(left + x * cell_size);
            const abs_y = f32(top + y * cell_size);

            fill_rect(t, color, abs_x, abs_y, cell_size, cell_size);
        }
    }
}

fn next_frame(t: &Tetris, elapsed: f64) {
    if (t.is_paused) return;

    // TODO for loop with ref
    // TODO maybe unwrap with ref:  if (var *particle ?= t.particles[i]) {
    for (t.falling_blocks) |_, i| {
        const p = &t.falling_blocks[i];

        if (!p.used) continue;
        p.pos = p.pos.add(p.vel);
        p.vel = p.vel.add(vec3(0, gravity, 0));

        p.angle += p.angle_vel;

        if (p.pos.data[1] > f32(t.framebuffer_height)) {
            p.used = false;
        }
    }

    // TODO for loop with ref
    // TODO maybe unwrap with ref:  if (var *particle ?= t.particles[i]) {
    for (t.particles) |_, i| {
        const p = &t.particles[i];
        if (!p.used) continue;
        p.pos = p.pos.add(p.vel);
        p.vel = p.vel.add(vec3(0, gravity, 0));

        p.angle += p.angle_vel;

        if (p.pos.data[1] > f32(window_height) + 10.0) {
            p.used = false;
        }
    }

    if (!t.game_over) {
        t.delay_left -= elapsed;

        if (t.delay_left <= 0) {
            cur_piece_fall(t);

            t.delay_left = t.piece_delay;
        }

        t.time_till_next_level -= elapsed;
        if (t.time_till_next_level <= 0.0) {
            level_up(t);
        }

        compute_ghost(t);
    }

    if (t.screen_shake_elapsed < t.screen_shake_timeout) {
        t.screen_shake_elapsed += elapsed;
        if (t.screen_shake_elapsed >= t.screen_shake_timeout) {
            reset_projection(t);
        } else {
            const rate = 8; // oscillations per sec
            const amplitude = 4; // pixels
            const offset = f32(amplitude * -sin(2.0 * PI * t.screen_shake_elapsed * rate));
            t.projection = mat4x4_ortho(0.0, f32(t.framebuffer_width),
                f32(t.framebuffer_height) + offset, offset);
        }
    }
}

fn level_up(t: &Tetris) {
    t.level += 1;
    t.time_till_next_level = time_per_level;

    const new_piece_delay = t.piece_delay - level_delay_increment;
    t.piece_delay = if (new_piece_delay >= min_piece_delay) new_piece_delay else min_piece_delay;

    activate_screen_shake(t, 0.08);

    const max_lines_to_fill = 4;
    const proposed_lines_to_fill = ((t.level + 2) / 3);
    const lines_to_fill = if (proposed_lines_to_fill > max_lines_to_fill) {
        max_lines_to_fill
    } else {
        proposed_lines_to_fill
    };

    // TODO for with range
    var i : i32 = 0;
    while (i < lines_to_fill) {
        insert_garbage_row_at_bottom(t);
        i += 1;
    }
}

fn insert_garbage_row_at_bottom(t: &Tetris) {
    // move everything up to make room at the bottom
    // TODO for with range
    var y : i32 = 1;
    while (y < t.grid.len) {
        t.grid[y - 1] = t.grid[y];
        y += 1;
    }

    // populate bottom row with garbage and make sure it fills at least
    // one and leaves at least one empty
    while (true) {
        var all_empty = true;
        var all_filled = true;
        const bottom_y = grid_height - 1;
        for (t.grid[bottom_y]) |_, x| {
            const filled = t.rand.boolean();
            if (filled) {
                // TODO type generics so this doesn't have to be a u64
                const index = t.rand.range_u64(0, u64(pieces.len));
                t.grid[bottom_y][x] = Cell.Color(pieces[isize(index)].color);
                all_empty = false;
            } else {
                t.grid[bottom_y][x] = Cell.Empty;
                all_filled = false;
            }
        }
        if (!all_empty && !all_filled) break;
    }
}

fn compute_ghost(t: &Tetris) {
    var off_y : i32 = 1;
    while (!piece_would_collide(t, t.cur_piece, t.cur_piece_x, t.cur_piece_y + off_y, t.cur_piece_rot)) {
        off_y += 1;
    }
    t.ghost_y = board_top + cell_size * (t.cur_piece_y + off_y - 1);
}

fn user_cur_piece_fall(t: &Tetris) {
    if (t.game_over || t.is_paused) return;
    cur_piece_fall(t);
}

fn cur_piece_fall(t: &Tetris) -> bool {
    // if it would hit something, make it stop instead
    if (piece_would_collide(t, t.cur_piece, t.cur_piece_x, t.cur_piece_y + 1, t.cur_piece_rot)) {
        lock_piece(t);
        drop_new_piece(t);
        return true;
    } else {
        t.cur_piece_y += 1;
        return false;
    }
}

fn user_drop_cur_piece(t: &Tetris) {
    if (t.game_over || t.is_paused) return;
    while (!cur_piece_fall(t)) {
        t.score += 1;
    }
}

fn user_move_cur_piece(t: &Tetris, dir: i8) {
    if (t.game_over || t.is_paused) return;
    if (piece_would_collide(t, t.cur_piece, t.cur_piece_x + dir, t.cur_piece_y, t.cur_piece_rot)) {
        return;
    }
    t.cur_piece_x += dir;
}

fn user_rotate_cur_piece(t: &Tetris, rot: i8) {
    if (t.game_over || t.is_paused) return;
    const new_rot = (t.cur_piece_rot + rot + 4) % 4;
    if (piece_would_collide(t, t.cur_piece, t.cur_piece_x, t.cur_piece_y, new_rot)) {
        return;
    }
    t.cur_piece_rot = new_rot;
}

fn user_toggle_pause(t: &Tetris) {
    if (t.game_over) return;

    t.is_paused = !t.is_paused;
}

fn restart_game(t: &Tetris) {
    t.piece_delay = init_piece_delay;
    t.delay_left = init_piece_delay;
    t.score = 0;
    t.game_over = false;
    t.screen_shake_elapsed = 0.0;
    t.screen_shake_timeout = 0.0;
    t.level = 1;
    t.time_till_next_level = time_per_level;
    t.is_paused = false;

    // TODO support the * operator for initializing constant arrays
    reset_piece_pool(t);

    clear_particles(t);
    // TODO support the * operator for initializing constant arrays
    // then do: .grid =  [][grid_width]Cell{[1]Cell{Cell.Empty} * grid_width} * grid_height
    init_empty_grid(t);
    populate_next_piece(t);
    drop_new_piece(t);
}

fn reset_piece_pool(t: &Tetris) {
    // TODO for (t.piece_pool) |*piece|
    for (t.piece_pool) |_, i| {
        t.piece_pool[i] = 1;
    }
}

fn lock_piece(t: &Tetris) {
    t.score += 1;

    for (t.cur_piece.layout[t.cur_piece_rot]) |row, y| {
        for (row) |is_filled, x| {
            if (!is_filled) {
                continue;
            }
            const abs_x = t.cur_piece_x + x;
            const abs_y = t.cur_piece_y + y;
            if (abs_x >= 0 && abs_y >= 0 && abs_x < grid_width && abs_y < grid_height) {
                t.grid[abs_y][abs_x] = Cell.Color(t.cur_piece.color);
            }
        }
    }

    // find lines once and spawn explosions
    for (t.grid) |row, y| {
        var all_filled = true;
        for (t.grid[y]) |cell| {
            const filled = switch (cell) { Empty => false, else => true, };
            if (!filled) {
                all_filled = false;
                break;
            }
        }
        if (all_filled) {
            for (t.grid[y]) |cell, x| {
                const color = switch (cell) { Empty => continue, Color => |c| c,};
                const center_x = f32(board_left + x * cell_size) + f32(cell_size) / 2.0;
                const center_y = f32(board_top + y * cell_size) + f32(cell_size) / 2.0;
                add_explosion(t, color, center_x, center_y);
            }
        }
    }

    // test for line
    var rows_deleted: i32 = 0;
    var y: i32 = grid_height - 1;
    while (y >= 0) {
        var all_filled: bool = true;
        for (t.grid[y]) |cell| {
            const filled = switch (cell) { Empty => false, else => true, };
            if (!filled) {
                all_filled = false;
                break;
            }
        }
        if (all_filled) {
            rows_deleted += 1;
            delete_row(t, y);
        } else {
            y -= 1;
        }
    }

    const score_per_rows_deleted = []c_int { 0, 10, 30, 50, 70};
    t.score += score_per_rows_deleted[rows_deleted];

    if (rows_deleted > 0) {
        activate_screen_shake(t, 0.04);
    }
}


fn reset_projection(t: &Tetris) {
    t.projection = mat4x4_ortho(0.0, f32(t.framebuffer_width), f32(t.framebuffer_height), 0.0);
}

fn activate_screen_shake(t: &Tetris, duration: f64) {
    t.screen_shake_elapsed = 0.0;
    t.screen_shake_timeout = duration;
}

fn delete_row(t: &Tetris, del_index: i32) {
    var y: i32 = del_index;
    while (y >= 1) {
        t.grid[y] = t.grid[y - 1];
        y -= 1;
    }
    t.grid[y] = empty_row;
}

fn cell_empty(t: &Tetris, x: i32, y: i32) -> bool {
    switch (t.grid[y][x]) {
        Empty => true,
        else => false,
    }
}

fn piece_would_collide(t: &Tetris, piece: &Piece, grid_x: i32, grid_y: i32, rot: i32) -> bool {
    for (piece.layout[rot]) |row, y| {
        for (row) |is_filled, x| {
            if (!is_filled) {
                continue;
            }
            const abs_x = grid_x + i32(x);
            const abs_y = grid_y + i32(y);
            if (abs_x >= 0 && abs_y >= 0 && abs_x < grid_width && abs_y < grid_height) {
                if (!cell_empty(t, abs_x, abs_y)) {
                    return true;
                }
            } else if (abs_y >= 0) {
                return true;
            }
        }
    }
    return false;
}

fn populate_next_piece(t: &Tetris) {
    // Let's turn Gambler's Fallacy into Gambler's Accurate Model of Reality.
    var upper_bound: i32 = 0;
    for (t.piece_pool) |count| {
        if (count == 0) unreachable{};
        upper_bound += count;
    }

    // TODO type generics so this doesn't have to be a u64
    const rand_val = i32(t.rand.range_u64(0, u64(upper_bound)));
    var this_piece_upper_bound: i32 = 0;
    var any_zero = false;
    for (t.piece_pool) |count, piece_index| {
        this_piece_upper_bound += count;
        if (rand_val < this_piece_upper_bound) {
            t.next_piece = &pieces[piece_index];
            t.piece_pool[piece_index] -= 1;
            if (count <= 1) {
                any_zero = true;
            }
            break;
        }
    }

    // if any of the pieces are 0, add 1 to all of them
    if (any_zero) {
        for (t.piece_pool) |_, i| {
            t.piece_pool[i] += 1;
        }
    }
}

fn do_game_over(t: &Tetris) {
    t.game_over = true;

    // turn every piece into a falling object
    for (t.grid) |row, y| {
        for (row) |cell, x| {
            const color = switch (cell) { Empty => continue, Color => |c| c,};
            const left = f32(board_left + x * cell_size);
            const top = f32(board_top + y * cell_size);
            t.falling_blocks[get_next_falling_block_index(t)] = create_block_particle(t,
                color, vec3(left, top, 0.0));
        }
    }
}

fn drop_new_piece(t: &Tetris) {
    const start_x = 4;
    const start_y = -1;
    const start_rot = 0;
    if (piece_would_collide(t, t.next_piece, start_x, start_y, start_rot)) {
        do_game_over(t);
        return;
    }


    t.delay_left = t.piece_delay;

    t.cur_piece = t.next_piece;
    t.cur_piece_x = start_x;
    t.cur_piece_y = start_y;
    t.cur_piece_rot = start_rot;

    populate_next_piece(t);
}

fn init_empty_grid(t: &Tetris) {
    // TODO for loop range
    for (t.grid) |row, y| {
        t.grid[y] = empty_row;
    }
}

fn clear_particles(t: &Tetris) {
    // TODO for loop range
    // TODO this crashes compiler, when t.particles is not maybe: t.particles[i] = null;
    for (t.particles) |_, i| {
        t.particles[i].used = false;
    }
    t.next_particle_index = 0;

    for (t.falling_blocks) |_, i| {
        t.falling_blocks[i].used = false;
    }
    t.next_falling_block_index = 0;
}

fn get_next_particle_index(t: &Tetris) -> i32 {
    const result = t.next_particle_index;
    t.next_particle_index = (t.next_particle_index + 1) % max_particle_count;
    return result;
}

fn get_next_falling_block_index(t: &Tetris) -> i32 {
    const result = t.next_falling_block_index;
    t.next_falling_block_index = (t.next_falling_block_index + 1) % max_falling_block_count;
    return result;
}

fn add_explosion(t: &Tetris, color: Vec4, center_x: f32, center_y: f32) {
    const particle_count = 12;
    const particle_size = f32(cell_size) / 3.0;
    // TODO for loop range
    var i: i32 = 0;
    while (i < particle_count) {
        const off_x = t.rand.float32() * f32(cell_size) / 2.0;
        const off_y = t.rand.float32() * f32(cell_size) / 2.0;
        const pos = vec3(center_x + off_x, center_y + off_y, 0.0);
        t.particles[get_next_particle_index(t)] = create_particle(t, color, particle_size, pos);
        i += 1;
    }
}

fn create_particle(t: &Tetris, color: Vec4, size: f32, pos: Vec3) -> Particle {
    var p: Particle = undefined;

    p.angle_vel = t.rand.float32() * 0.1 - 0.05;
    p.angle = t.rand.float32() * 2.0 * PI;
    p.axis = vec3(0.0, 0.0, 1.0);
    p.scale_w = size * (0.8 + t.rand.float32() * 0.4);
    p.scale_h = size * (0.8 + t.rand.float32() * 0.4);
    p.color = color;
    p.pos = pos;

    const vel_x = t.rand.float32() * 2.0 - 1.0;
    const vel_y = -(2.0 + t.rand.float32() * 1.0);
    p.vel = vec3(vel_x, vel_y, 0.0);

    p.used = true;

    return p;
}

fn create_block_particle(t: &Tetris, color: Vec4, pos: Vec3) -> Particle {
    var p: Particle = undefined;

    p.angle_vel = t.rand.float32() * 0.05 - 0.025;
    p.angle = 0;
    p.axis = vec3(0.0, 0.0, 1.0);
    p.scale_w = cell_size;
    p.scale_h = cell_size;
    p.color = color;
    p.pos = pos;

    const vel_x = t.rand.float32() * 0.5 - 0.25;
    const vel_y = -t.rand.float32() * 0.5;
    p.vel = vec3(vel_x, vel_y, 0.0);

    p.used = true;

    return p;
}
