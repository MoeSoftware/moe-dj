Config = {}

Config.Debug = false

--------------------------------------------------------------------------------
-- Framework core
--------------------------------------------------------------------------------
--[[
 'auto'        -> probe for qbx_core, then qb-core, then es_extended
 'qbx_core'    -> force Qbox
 'qb-core'     -> force QBCore
 'es_extended' -> force ESX
 'none'        -> no core. Job/grade locks are hidden in /djmanager and any
                  stored locks are ignored (every booth is open to anyone).
]]
Config.Core = 'auto'

-- ACE permission required to run /djmanager and manage booths.
-- Grant in server.cfg, e.g.:  add_ace group.admin moedj.admin allow
Config.AdminAce = 'moedj.admin'

--------------------------------------------------------------------------------
-- New-booth defaults (only used when a core is present)
--------------------------------------------------------------------------------
Config.DefaultJob = ''        -- '' = anyone can DJ
Config.DefaultGrades = {}     -- {}  = all grades of DefaultJob allowed

--------------------------------------------------------------------------------
-- Audio & proximity
--------------------------------------------------------------------------------
Config.DefaultRange = 30.0          -- meters from a speaker before audio is silent
Config.DefaultFalloff = 'linear'    -- 'linear' | 'quadratic'
Config.MaxSpeakers = 10             -- per booth
Config.MaxConcurrentBooths = 3      -- max simultaneous audio instances per client
Config.ProximityInterval = 300      -- ms, loop rate when a booth is nearby, you can increase this to save CPU if needed
Config.IdleInterval = 1000          -- ms, loop rate when no booth is nearby, you can increase this to save CPU if needed
Config.CoarsePrecheckRange = 60.0   -- m, cheap booth-anchor check before per-speaker math

--------------------------------------------------------------------------------
-- Playback sync
--------------------------------------------------------------------------------
Config.ResyncInterval = 300       -- ms, periodic drift check per active booth (if you notice unsynced audio, maybe lower this a bit, but it will impact performance if ran too fast)
Config.DriftThreshold = 2.5         -- seconds of drift before a hard re-seek

--------------------------------------------------------------------------------
-- Anti-grief
--------------------------------------------------------------------------------
Config.ActionCooldown = 800         -- ms between queue/control actions per DJ
Config.MaxQueueLength = 50

--------------------------------------------------------------------------------
-- Jukebox interaction
--------------------------------------------------------------------------------
Config.InteractKey = 38             -- 38 = E (keybind fallback when no target system)
Config.InteractDistance = 2.0       -- m, how close to interact (keybind + target range)
Config.UseTarget = true             -- detect & use ox_target / qb-target if present
Config.TargetIcon = 'fa-solid fa-music'
Config.TargetLabel = 'Use jukebox'

--------------------------------------------------------------------------------
-- Features
--------------------------------------------------------------------------------
Config.LiveBlip = true              -- recolor a booth's blip + "(LIVE)" while it plays
Config.ListenerToast = false        -- show a "now playing" toast when a listener enters range
Config.EmbedErrorGrace = 5000       -- ms to wait for a successful load before auto-skipping a dead track
Config.AccessRefreshInterval = 15000 -- ms, how often clients refresh their per-booth DJ access map

--------------------------------------------------------------------------------
-- DUI screen
--------------------------------------------------------------------------------
Config.Dui = {
    width          = 512,    -- DUI render resolution (keep ~2:1 for a screen)
    height         = 256,
    range          = 20.0,   -- drive the screen from the nearest booth within this distance
    updateInterval = 500,    -- ms between state pushes to the screen
    propDistance   = 70.0,   -- spawn a booth's jukebox prop within this distance
    drawDistance   = 12.0,   -- only render the screen quad within this distance of the prop
    minSpacing     = 8.0,    -- jukeboxes must be at least this far apart (prevents the
                             -- screen/interaction from flip-flopping between two close props)
--[[
        Selectable models.
        LOCAL space (metres): x = right(+)/left(-), y = forward(+)/back(-), z = up(+)/down(-),
        w/h = width/height (keep ~2:1 to match the DUI). Optional rx/ry/rz tilt the quad
        (degrees; default 0). Run /djscreen near a prop to nudge a model's surface live and
        print the values to paste back here.
]]
    models = {
        {
            label   = 'Clubhouse Jukebox',
            model   = 'bkr_prop_clubhouse_jukebox_01a',
            surface = { x = 0.011, y = -0.235, z = 1.861, w = 0.660, h = 0.320 },
            interactDistance = 3.0, -- optional; bigger prop -> reach further (defaults to Config.InteractDistance)
        },
        {
            label   = 'DJ Deck',
            model   = 'prop_dj_deck_02',
            surface = { x = 0.361, y = 0.190, z = 0.266, w = 1.165, h = 0.590 },
        },
        -- Add more models here, e.g.:
        -- {
        --     label   = 'Arcade Machine',
        --     model   = 'prop_arcade_01',
        --     surface = { x = 0.0, y = -0.30, z = 1.30, w = 0.55, h = 0.32, rx = -40.0, ry = 0.0, rz = 30.0 },
        -- },
    },

    -- Interactive focus (walk up + use the screen as a DJ).
    -- Interact key/distance/target come from Config.Interact settings.
    cursorSpeed      = 0.5,   -- on-screen cursor sensitivity
    camDistance      = 0.55,  -- how far the focus camera sits from the screen
    camFov           = 38.0,  -- focus camera FOV (lower = screen fills more)
    clickKey         = 24,    -- left mouse = click
    exitKey          = 177,   -- Backspace/Esc = stop focusing
}

--------------------------------------------------------------------------------
-- Branding (This is not shown to the players, just admins/owners)
--------------------------------------------------------------------------------
Config.Brand = {
    name    = 'Moe DJ',
    author  = 'Moe',
    store   = 'https://www.moesoftware.com/',
    discord = 'https://discord.gg/jF67XzaNUG',
}

--------------------------------------------------------------------------------
-- URL safety
--------------------------------------------------------------------------------
Config.AllowedHosts = {
    'youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com', 'youtu.be',
}
