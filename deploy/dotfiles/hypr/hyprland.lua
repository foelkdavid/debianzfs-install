-- deploy.sh writes hardware-specific settings outside this symlinked directory.
local configHome = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")
local graphicsConfig = configHome .. "/debian-deploy/graphics.lua"
local deployment = {}
local graphicsFile = io.open(graphicsConfig, "r")
if graphicsFile then
    graphicsFile:close()
    deployment = dofile(graphicsConfig)
end

-- A fallback also covers outputs that are not yet visible to hyprctl at startup.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = deployment.monitor_scale or 1.0 })

-- Use the connected monitor order reported by Hyprland instead of assuming
-- particular connector names. Hyprland reports the primary output first.
local monitors = {}
local monitorList = io.popen("hyprctl monitors 2>/dev/null", "r")
if monitorList then
    for line in monitorList:lines() do
        local name = line:match("^Monitor%s+(%S+)")
        if name then
            monitors[#monitors + 1] = name
        end
    end
    monitorList:close()
end

local homeMonitor = monitors[1]
local secondaryMonitor = monitors[2]

if homeMonitor then
    hl.monitor({
        output = homeMonitor,
        mode = "preferred",
        position = "0x0",
        scale = deployment.monitor_scale or 1.0,
    })
end

if secondaryMonitor then
    hl.monitor({
        output = secondaryMonitor,
        mode = "preferred",
        position = "auto-right",
    })
end

local lockScript = "noctalia msg session lock"

-- AUTOSTART
hl.on("hyprland.start", function()
    hl.exec_cmd("dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE DBUS_SESSION_BUS_ADDRESS")
    hl.exec_cmd("Thunar --daemon")
    hl.exec_cmd("noctalia --daemon")
end)

-----------------------------
-- ENVIRONMENT VARIABLES
-----------------------------

-- Do not force GDK_SCALE=2 together with Hyprland fractional scaling.
-- Let the compositor scale the desktop; only re-enable a toolkit-specific
-- scale if one app family is wrong.
-- hl.env("GDK_SCALE", "2")

hl.env("XCURSOR_SIZE", "32")
hl.env("HYPRCURSOR_SIZE", "32")
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("QT_QPA_PLATFORMTHEME", "gtk")
-- hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
hl.env("GTK_THEME", "Adwaita:dark")

-----------------
-- LOOK AND FEEL
-----------------

hl.config({
    xwayland = {
        force_zero_scaling = true,
    },

    general = {
        gaps_in = 2,
        gaps_out = 8,
        border_size = 4,
        col = {
            active_border = "rgba(d79921ff)",
            inactive_border = "rgba(928374ff)",
        },
        resize_on_border = false,
        allow_tearing = false,
        layout = "master",
    },

    decoration = {
        rounding = 10,
        rounding_power = 2.0,
        active_opacity = 1.0,
        inactive_opacity = 1.0,
        shadow = {
            enabled = not deployment.vm,
        },
        blur = {
            enabled = not deployment.vm,
        },
    },

    animations = {
        enabled = not deployment.vm,
    },

    master = {
        new_status = "master",
        mfact = 0.55,
    },

    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo = true,
        focus_on_activate = false,
        layers_hog_keyboard_focus = false,
    },

    input = {
        kb_layout = "de,de",
        kb_variant = ",bone",
        kb_model = "",
        kb_options = "grp:ctrl_space_toggle",
        kb_rules = "",
        repeat_rate = 100,
        repeat_delay = 300,
        follow_mouse = 0,
        sensitivity = 0,
        touchpad = {
            natural_scroll = false,
        },
    },

    cursor = {
        inactive_timeout = 0,
        hide_on_key_press = false,
        invisible = false,
        no_hardware_cursors = deployment.vm and 1 or 2,
        no_warps = true,
    },
})

hl.curve("easeOutQuint", {
    type = "bezier",
    points = { { 0.23, 1 }, { 0.1, 1 } },
})
hl.curve("easeInOutCubic", {
    type = "bezier",
    points = { { 0.65, 0.05 }, { 0.1, 1 } },
})
hl.curve("linear", {
    type = "bezier",
    points = { { 0, 0 }, { 0.1, 1 } },
})
hl.curve("almostLinear", {
    type = "bezier",
    points = { { 0.5, 0.5 }, { 0.1, 1.0 } },
})
hl.curve("quick", {
    type = "bezier",
    points = { { 0.15, 0 }, { 0.1, 1 } },
})

hl.animation({ leaf = "global", enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "border", enabled = true, speed = 5.39, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows", enabled = true, speed = 4.79, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 4.1, bezier = "easeOutQuint", style = "popin 87%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.49, bezier = "linear", style = "popin 87%" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 1.73, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 1.46, bezier = "almostLinear" })
hl.animation({ leaf = "fade", enabled = true, speed = 3.03, bezier = "quick" })
hl.animation({ leaf = "layers", enabled = true, speed = 3.81, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 4, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 1.5, bezier = "linear", style = "fade" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 1.79, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.39, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesIn", enabled = true, speed = 1.21, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesOut", enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })

----------------
-- KEYBINDINGS
----------------

local mainMod = "SUPER"

-- Programs / session
hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd("alacritty"))
hl.bind(mainMod .. " + D", hl.dsp.exec_cmd("noctalia msg panel-toggle launcher"))
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd("Thunar"))
-- hl.bind(mainMod .. " + N", hl.dsp.exec_cmd("your-notes-command"))
hl.bind(mainMod .. " + Q", hl.dsp.window.close())
hl.bind(mainMod .. " + M", hl.dsp.exit())
hl.bind(mainMod .. " + L", hl.dsp.exec_cmd(lockScript))

-- Screenshot
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.exec_cmd("slurp | grim -g - - | wl-copy -t image/png"))

-- Floating / fullscreen
hl.bind(mainMod .. " + V", hl.dsp.window.float())
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen({ mode = "fullscreen" }))

-- River-like next/previous focus
hl.bind(mainMod .. " + right", hl.dsp.layout("cyclenext"))
hl.bind(mainMod .. " + down", hl.dsp.layout("cyclenext"))
hl.bind(mainMod .. " + left", hl.dsp.layout("cycleprev"))
hl.bind(mainMod .. " + up", hl.dsp.layout("cycleprev"))

-- Switch focus between monitors
hl.bind(mainMod .. " + period", hl.dsp.focus({ monitor = "+1" }))

-- River-like swap next/previous
hl.bind(mainMod .. " + SHIFT + right", hl.dsp.layout("swapnext"))
hl.bind(mainMod .. " + SHIFT + down", hl.dsp.layout("swapnext"))
hl.bind(mainMod .. " + SHIFT + left", hl.dsp.layout("swapprev"))
hl.bind(mainMod .. " + SHIFT + up", hl.dsp.layout("swapprev"))

-- Main/secondary ratio, River rivertile equivalent for the master layout
hl.bind(mainMod .. " + CTRL + left", hl.dsp.layout("mfact -0.05"), { repeating = true })
hl.bind(mainMod .. " + CTRL + right", hl.dsp.layout("mfact +0.05"), { repeating = true })

-- Move/resize with mouse
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })
hl.bind(mainMod .. " + mouse:274", hl.dsp.window.float())

-- Switch workspaces and move the active window with SUPER + [0-9].
for i = 1, 10 do
    local key = i % 10
    hl.bind(mainMod .. " + " .. key, hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

-- SUPER + mouse wheel: switch through open workspaces
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))

--------------------------------
-- WINDOWS AND WORKSPACES
--------------------------------

-- Persistent workspaces for both home monitors.
if homeMonitor then
    for i = 1, 10 do
        hl.workspace_rule({
            workspace = tostring(i),
            monitor = homeMonitor,
            default = i == 1,
            persistent = true,
        })
    end
end

if secondaryMonitor then
    hl.workspace_rule({
        workspace = "11",
        monitor = secondaryMonitor,
        default = true,
        persistent = true,
    })
end

-- Home app placement.
if homeMonitor then
    hl.window_rule({
        match = { class = "^(spotify)$" },
        monitor = homeMonitor,
        workspace = "10 silent",
    })
end

-- Example float rule kept from the work config.
-- hl.window_rule({
--     match = { class = "^(float.*)$", title = "^(foo)$" },
--     float = true,
-- })

-- Useful rules kept from the old configuration.
hl.window_rule({
    match = { class = ".*" },
    suppress_event = "maximize",
})

hl.window_rule({
    match = {
        class = "^$",
        title = "^$",
        xwayland = true,
        float = true,
        fullscreen = false,
        pin = false,
    },
    no_focus = true,
})
