--[[
================================================================================
  glitch.lua -- occasional CRT / horror "signal disruption" overlay for Conky

  https://github.com/TitanicRuby/conky-crt-glitch

  Theme-agnostic: works on top of ANY Conky theme that uses Cairo. It doesn't
  read or depend on your theme's config, fonts, or other Lua scripts -- it
  only asks Conky for the current window (conky_window) and corrupts a
  snapshot of whatever has already been drawn.

  Wiring (add to your conky.config table, alongside anything already there):
      lua_load = '/path/to/glitch.lua'
      lua_draw_hook_post = 'glitch'

  If you already load other Lua scripts, add this one to the same lua_load
  line (paths are whitespace- or ';'-separated), and add lua_draw_hook_post
  only if nothing else already uses the _post hook.

  It runs on the *post* draw hook, i.e. AFTER Conky has painted your normal
  widgets for the current tick, so it layers on top. When no burst is active
  the hook returns immediately and your theme renders exactly as it always
  has -- no Conky config state is mutated, so "normal" is always one tick
  away. All drawing is wrapped in pcall(): if a Cairo call misbehaves, the
  effect silently disables itself for a while and your theme keeps working.

  Behaviour:
    * After Conky starts, waits MIN_GAP..MAX_GAP seconds (random) before the
      first glitch, then re-rolls that wait after every glitch. Never a
      fixed schedule.
    * A glitch is normally ONE Conky tick (length = your update_interval).
      A fraction of triggers (PROFILE.double_chance) are a 2-tick sequence:
      a signal-drop dip, then a heavier tear/static frame.

  Aggressiveness is chosen with PROFILE below:
    * 'full'     -- tears with transparent rips, wide channel split, dense
                    static, black dropout blocks, occasional FULL black frame
                    and a cut-to-black lead-in on 2-tick sequences.
    * 'moderate' -- slice tears + static + chromatic split + scanlines;
                    only brief / partial dark dips, never a full opaque
                    black frame.
    * 'subtle'   -- (shipped default) ghosted tears only (no transparent
                    rips), narrow split, light static, faint scanlines,
                    minimal darkening. Safe, low-key default for a fresh
                    install.

  Manual preview (no need to wait for the random timer):
      touch /tmp/conky_glitch_now
  The next tick consumes that file and fires a burst.

  Want a faster, actually-animated burst instead of a single held frame?
  Lower update_interval in your conky.config (e.g. 0.1). The scheduler here
  is wall-clock based (os.time()), so the random gap between glitches is
  unaffected; only the per-burst tick count would want raising so a burst
  still lasts a few hundred ms .. ~1s -- see the README's Tuning section.
================================================================================
]]

require 'cairo'

--------------------------------------------------------------------------------
-- aggressiveness profile  --  set to 'full', 'moderate' or 'subtle'
--------------------------------------------------------------------------------
local PROFILE = 'subtle'

local PROFILES = {
    full = {
        intensity       = 1.00,   -- master scale: tear distance, noise, split width
        double_chance   = 0.18,   -- chance a trigger is a 2-tick sequence
        hard_tears      = true,   -- wipe bands to transparent (wallpaper shows through)
        allow_full_black = true,  -- occasional full opaque black frame + cut-to-black lead-in
        brownout_chance = 0.40,   -- chance of a partial dark wash on a normal tick
        brownout_max    = 0.60,   -- max alpha of that dark wash
        dropout_max     = 6,      -- upper bound on data-loss blocks per tick
        dropout_alpha   = 1.00,   -- alpha of the solid-black dropout blocks
    },
    moderate = {
        intensity       = 0.60,
        double_chance   = 0.12,
        hard_tears      = true,
        allow_full_black = false, -- brief / partial dips only, never a full black frame
        brownout_chance = 0.35,
        brownout_max    = 0.45,
        dropout_max     = 4,
        dropout_alpha   = 0.90,
    },
    subtle = {
        intensity       = 0.32,
        double_chance   = 0.00,
        hard_tears      = false,
        allow_full_black = false,
        brownout_chance = 0.20,
        brownout_max    = 0.25,
        dropout_max     = 2,
        dropout_alpha   = 0.70,
    },
}

local P = PROFILES[PROFILE] or PROFILES.subtle

--------------------------------------------------------------------------------
-- tunables (profile-independent)
--------------------------------------------------------------------------------
local MIN_GAP       = 20     -- seconds: shortest wait between glitches
local MAX_GAP       = 90     -- seconds: longest wait between glitches
local FAIL_COOLDOWN = 120    -- seconds to back off if a draw call errors

--------------------------------------------------------------------------------
-- persistent state (one Lua state lives for Conky's whole lifetime)
--------------------------------------------------------------------------------
local seeded     = false
local next_at    = 0    -- os.time() at which the next burst should fire
local burst_left = 0    -- number of glitch ticks still to render (0 = idle)

local function reseed()
    math.randomseed(os.time() * 1000 + math.floor((os.clock() * 1e6) % 1e6))
    math.random(); math.random(); math.random()
    seeded = true
end

local function schedule_next(now)
    next_at = now + math.random(MIN_GAP, MAX_GAP)
end

--------------------------------------------------------------------------------
-- small helpers
--------------------------------------------------------------------------------
local function rnd(a, b)   return a + math.random() * (b - a) end
local function chance(p)   return math.random() < p end

local function box(cr, x, y, w, h, r, g, b, a)
    cairo_set_source_rgba(cr, r, g, b, a)
    cairo_rectangle(cr, x, y, w, h)
    cairo_fill(cr)
end

-- copy the current window contents into a fresh ARGB image surface
local function snapshot(disp, drawable, vis, w, h)
    local xs  = cairo_xlib_surface_create(disp, drawable, vis, w, h)
    local img = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h)
    local ic  = cairo_create(img)
    cairo_set_source_surface(ic, xs, 0, 0)
    cairo_paint(ic)
    cairo_destroy(ic)
    cairo_surface_destroy(xs)
    return img
end

--------------------------------------------------------------------------------
-- individual artifacts
--------------------------------------------------------------------------------

-- horizontal slice tearing: chop the frame into bands and shove them sideways.
-- With P.hard_tears, ~50% of bands are wiped to transparent first (so whatever
-- is behind Conky shows through the seam); otherwise every band is a ghosted
-- double-exposure.
local function tearing(cr, snap, w, h, s)
    local y = 0
    while y < h do
        local bh = rnd(h * 0.02, h * 0.18)
        local dx = 0
        if chance(0.72) then dx = (chance(0.5) and -1 or 1) * rnd(8, 78) * s end
        local dy = rnd(-3, 3)

        cairo_save(cr)
        cairo_rectangle(cr, 0, y, w, bh)
        cairo_clip(cr)

        if P.hard_tears and chance(0.5) then
            cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
            cairo_paint(cr)
            cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        end

        cairo_set_source_surface(cr, snap, dx, dy)
        cairo_paint(cr)

        if chance(0.28) then
            local r = chance(0.5) and 1 or 0
            local b = 1 - r
            box(cr, 0, y, w, bh, r, 0, b, rnd(0.06, 0.22))
        end
        cairo_restore(cr)

        y = y + bh + rnd(0, h * 0.05)
    end
end

-- chromatic aberration / RGB channel split: paint the snapshot's alpha as a
-- red ghost shifted one way and a cyan ghost shifted the other, added on top
-- of the untouched original.
local function chroma(cr, snap, w, h, s)
    local d = rnd(2, 13) * s
    cairo_save(cr)
    cairo_set_operator(cr, CAIRO_OPERATOR_ADD)
    cairo_set_source_rgb(cr, 0.95, 0.02, 0.02)
    cairo_mask_surface(cr, snap, -d, rnd(-2, 2))
    cairo_set_source_rgb(cr, 0.02, 0.85, 0.95)
    cairo_mask_surface(cr, snap,  d, rnd(-2, 2))
    cairo_restore(cr)
end

-- a band of white/grey static noise with a dark wash under it
local function static_band(cr, w, h, s)
    local by = rnd(0, h * 0.80)
    local bh = rnd(h * 0.05, h * 0.30) * (0.6 + s)
    if by + bh > h then bh = h - by end

    cairo_save(cr)
    cairo_rectangle(cr, 0, by, w, bh)
    cairo_clip(cr)
    box(cr, 0, by, w, bh, 0, 0, 0, rnd(0.10, 0.38))

    local n = math.floor(rnd(180, 520) * s)
    for _ = 1, n do
        local x = math.random() * w
        local yy = by + math.random() * bh
        local v = rnd(0.25, 1.0)
        cairo_set_source_rgba(cr, v, v, v, rnd(0.15, 0.72))
        cairo_rectangle(cr, x, yy, rnd(1, 14), rnd(1, 2))
        cairo_fill(cr)
    end
    cairo_restore(cr)
end

-- data-loss blocks: some near-solid black, some displaced copies of the frame.
-- These are thin horizontal strips, never a full-frame fill.
local function dropouts(cr, snap, w, h)
    for _ = 1, math.random(2, P.dropout_max) do
        local bw = rnd(w * 0.15, w * 0.72)
        local bh = rnd(h * 0.01, h * 0.06)
        local x  = math.random() * (w - bw)
        local yy = math.random() * (h - bh)
        if chance(0.5) then
            box(cr, x, yy, bw, bh, 0, 0, 0, P.dropout_alpha)
        else
            cairo_save(cr)
            cairo_rectangle(cr, x, yy, bw, bh)
            cairo_clip(cr)
            cairo_set_source_surface(cr, snap, rnd(-45, 45), rnd(-4, 4))
            cairo_paint(cr)
            cairo_restore(cr)
        end
    end
end

-- CRT scanlines plus one brighter "vertical refresh" bar
local function scanlines(cr, w, h)
    cairo_set_source_rgba(cr, 0, 0, 0, 0.16)
    local y = 0
    while y < h do
        cairo_rectangle(cr, 0, y, w, 1)
        y = y + 3
    end
    cairo_fill(cr)

    cairo_set_source_rgba(cr, 1, 1, 1, 0.05)
    cairo_rectangle(cr, 0, math.random() * h, w, rnd(18, 90))
    cairo_fill(cr)
end

local function blackout(cr, w, h, amt)
    box(cr, 0, 0, w, h, 0, 0, 0, amt)
end

--------------------------------------------------------------------------------
-- one glitch tick
--------------------------------------------------------------------------------
local function render_tick(first_of_two)
    local w, h = conky_window.width, conky_window.height
    if w == 0 or h == 0 then return end

    local disp = conky_window.display
    local drw  = conky_window.drawable
    local vis  = conky_window.visual

    local cs = cairo_xlib_surface_create(disp, drw, vis, w, h)
    local cr = cairo_create(cs)
    local snap = snapshot(disp, drw, vis, w, h)

    local s = P.intensity * rnd(0.7, 1.0)

    if first_of_two then
        -- lead the sequence with a signal-drop dip
        if P.allow_full_black and chance(0.55) then
            blackout(cr, w, h, rnd(0.90, 1.0))          -- hard cut to black
        else
            blackout(cr, w, h, rnd(0.28, P.brownout_max)) -- partial dip only
        end
        if chance(0.6) then static_band(cr, w, h, s) end
    else
        -- corrupted freeze-frame: stack the artifacts
        tearing(cr, snap, w, h, s)
        chroma(cr, snap, w, h, s)
        for _ = 1, math.random(1, 3) do static_band(cr, w, h, s) end
        dropouts(cr, snap, w, h)
        if chance(0.55) then scanlines(cr, w, h) end
        if chance(P.brownout_chance) then
            blackout(cr, w, h, rnd(0.15, P.brownout_max))            -- brownout
        end
        if P.allow_full_black and chance(0.15) then
            blackout(cr, w, h, rnd(0.90, 1.0))                       -- full drop
        end
    end

    cairo_surface_destroy(snap)
    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end

--------------------------------------------------------------------------------
-- driver
--------------------------------------------------------------------------------
local function drive()
    if conky_window == nil then return end
    if not seeded then reseed() end

    local now = os.time()

    if next_at == 0 then          -- first ever call: arm the timer, draw nothing
        schedule_next(now)
        return
    end

    -- manual preview:  touch /tmp/conky_glitch_now
    local f = io.open('/tmp/conky_glitch_now', 'r')
    if f then
        f:close()
        os.remove('/tmp/conky_glitch_now')
        if burst_left == 0 then
            burst_left = chance(P.double_chance) and 2 or 1
        end
    end

    if burst_left == 0 then
        if now < next_at then return end       -- still waiting: nothing to draw
        burst_left = chance(P.double_chance) and 2 or 1
        schedule_next(now)
    end

    render_tick(burst_left == 2)
    burst_left = burst_left - 1
end

function conky_glitch()
    local ok = pcall(drive)
    if not ok then
        -- a Cairo call blew up: stand down for a while, keep the theme alive
        burst_left = 0
        next_at = os.time() + FAIL_COOLDOWN
    end
    return ''
end
