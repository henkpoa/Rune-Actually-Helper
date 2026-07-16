--[[
    Rune-Actually-Helper.lua  --  Ashita v4 addon for Rune Fencer

    A rewrite of GetAwayCoxn's "Rune Helper" that ACTUALLY tracks ability
    cooldowns (hence the name). The original fired /ja every single frame
    because it looked the rune recast up by the name "Rune Enchantment" --
    but the game shares one recast timer across all eight rune abilities and
    resolves that timer to a rune NAME (Ignis, Gelus, ...), never the string
    "Rune Enchantment". So its recast check matched nothing, always read 0,
    and it spammed the ability until the buffs happened to land. It also
    dereferenced a nil ability record while scanning recast slots, which is
    where the random crashes came from.

    This version:
      * reads the real rune recast by detecting ANY rune name in the recast
        table (robust against the shared-timer-id quirk),
      * adds a local "just cast" debounce with a lag margin, so it issues at
        most one ability per margin window and never re-queues into the
        network round-trip window (the actual source of the spam),
      * nil-checks every AshitaCore lookup and isolates the per-frame work and
        the window body in pcall -- with imgui.Begin/End kept OUTSIDE it so the
        window stack can never be left unbalanced (no more crashes),
      * maintains your chosen runes as a multiset (stack the same element up
        to 3x, any mix), casting only the deficit,
      * pauses -- instead of permanently disabling -- in town / while zoning /
        mounted / incapacitated, and auto-resumes when the condition clears,
      * remembers your settings per character (runes, pulse %, margin, on/off),
      * wears CatsEyeXI/dlac's dark theme so it doesn't look like a ransom note.

    Commands:  /rah            toggle the window
               /rah toggle     engage / disengage the automation
               /rah on|off     engage / disengage explicitly
               /rah show|hide  show / hide the window
    (/runeactuallyhelper is accepted everywhere /rah is.)

    Credit to GetAwayCoxn for the original Rune Helper, and to Thorny for the
    GetBuffCount idea it borrowed from LuaAshitacast.
]]--

addon.name    = 'Rune-Actually-Helper';
addon.author  = 'GetAwayCoxn, rework by henkpoa';
addon.version = '2.00';
addon.desc    = 'Auto rune enchantment + Vivacious Pulse for RUN, with real cooldown tracking.';
addon.link    = 'https://github.com/GetAwayCoxn/Rune-Helper';

require('common');
local imgui = require('imgui');

-- Optional libs: never let a missing/older library take the addon down.
local settings = (function() local ok, m = pcall(require, 'settings'); return ok and m or nil; end)();
local chat     = (function() local ok, m = pcall(require, 'chat');     return ok and m or nil; end)();

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local JOB_RUN = 22;   -- Rune Fencer main-job id (dlac's JOB table)
local PULSE_LEVEL = 45;   -- RUN level Vivacious Pulse is learned at

-- Combo index (1..8) -> rune ability / buff name. Index 0 is "None".
-- These strings are BOTH the /ja name and the buff name the game reports,
-- so the same table drives casting and buff counting.
local RUNE_NAMES = { 'Ignis', 'Gelus', 'Flabra', 'Tellus', 'Sulpor', 'Unda', 'Lux', 'Tenebrae' };
local RUNE_LOOKUP = {};
for i, n in ipairs(RUNE_NAMES) do RUNE_LOOKUP[n] = i; end
local TENEBRAE = 8;   -- index of the dark rune (Vivacious Pulse -> MP restore)

-- imgui.Combo item list. '\0'-separated, 0-based -> matches config.runes values.
local RUNE_COMBO = 'None\0Ignis\0Gelus\0Flabra\0Tellus\0Sulpor\0Unda\0Lux\0Tenebrae\0';

-- Statuses that stop you acting: casting into them just wastes the queue. Names
-- are matched against the game's buff-name strings; unknown names are harmless.
local CANT_ACT = {
    ['Sleep'] = true, ['Petrification'] = true, ['Stun'] = true, ['Terror'] = true,
    ['Charm'] = true, ['Amnesia'] = true, ['Lullaby'] = true,
};

-- Towns / safe areas where abilities are pointless or blocked. Copied from the
-- original; used to PAUSE (not disable) the automation while you're in one.
local TOWNS = T{
    'Tavnazian Safehold','Al Zahbi','Aht Urhgan Whitegate','Nashmau','Southern San d\'Oria [S]',
    'Bastok Markets [S]','Windurst Waters [S]','San d\'Oria-Jeuno Airship','Bastok-Jeuno Airship',
    'Windurst-Jeuno Airship','Kazham-Jeuno Airship','Southern San d\'Oria','Northern San d\'Oria',
    'Port San d\'Oria','Chateau d\'Oraguille','Bastok Mines','Bastok Markets','Port Bastok','Metalworks',
    'Windurst Waters','Windurst Walls','Port Windurst','Windurst Woods','Heavens Tower','Ru\'Lude Gardens',
    'Upper Jeuno','Lower Jeuno','Port Jeuno','Rabao','Selbina','Mhaura','Kazham','Norg','Mog Garden',
    'Celennia Memorial Library','Western Adoulin','Eastern Adoulin',
};

-- dlac / CatsEyeXI partyfinder theme (from dlac/ui/uistyle.lua). {ImGuiCol_*, {r,g,b,a}}.
-- Built through add() so a color id this imgui build doesn't define is skipped.
local THEME = {};
local function addc(id, col) if id ~= nil then THEME[#THEME + 1] = { id, col }; end end
addc(ImGuiCol_Text,                 { 0.90, 0.90, 0.90, 1.00 });
addc(ImGuiCol_TextDisabled,         { 0.50, 0.50, 0.50, 1.00 });
addc(ImGuiCol_WindowBg,             { 0.06, 0.06, 0.08, 0.96 });
addc(ImGuiCol_ChildBg,              { 0.08, 0.08, 0.10, 1.00 });
addc(ImGuiCol_PopupBg,              { 0.08, 0.08, 0.10, 0.96 });
addc(ImGuiCol_Border,               { 0.30, 0.30, 0.35, 0.50 });
addc(ImGuiCol_FrameBg,              { 0.12, 0.12, 0.15, 1.00 });
addc(ImGuiCol_FrameBgHovered,       { 0.18, 0.18, 0.22, 1.00 });
addc(ImGuiCol_FrameBgActive,        { 0.22, 0.22, 0.28, 1.00 });
addc(ImGuiCol_TitleBg,              { 0.05, 0.05, 0.07, 1.00 });
addc(ImGuiCol_TitleBgActive,        { 0.10, 0.10, 0.14, 1.00 });
addc(ImGuiCol_ScrollbarBg,          { 0.05, 0.05, 0.07, 0.80 });
addc(ImGuiCol_ScrollbarGrab,        { 0.30, 0.30, 0.35, 1.00 });
addc(ImGuiCol_ScrollbarGrabHovered, { 0.40, 0.40, 0.45, 1.00 });
addc(ImGuiCol_ScrollbarGrabActive,  { 0.50, 0.50, 0.55, 1.00 });
addc(ImGuiCol_Button,               { 0.18, 0.18, 0.22, 1.00 });
addc(ImGuiCol_ButtonHovered,        { 0.28, 0.28, 0.35, 1.00 });
addc(ImGuiCol_ButtonActive,         { 0.35, 0.35, 0.42, 1.00 });
addc(ImGuiCol_Header,               { 0.18, 0.18, 0.24, 1.00 });
addc(ImGuiCol_HeaderHovered,        { 0.26, 0.26, 0.34, 1.00 });
addc(ImGuiCol_HeaderActive,         { 0.32, 0.32, 0.40, 1.00 });
addc(ImGuiCol_CheckMark,            { 0.65, 0.75, 0.90, 1.00 });
addc(ImGuiCol_SliderGrab,           { 0.40, 0.45, 0.55, 1.00 });
addc(ImGuiCol_SliderGrabActive,     { 0.55, 0.60, 0.72, 1.00 });
addc(ImGuiCol_Separator,            { 0.30, 0.30, 0.35, 0.50 });
addc(ImGuiCol_SeparatorHovered,     { 0.40, 0.40, 0.48, 0.78 });
addc(ImGuiCol_SeparatorActive,      { 0.50, 0.50, 0.58, 1.00 });
addc(ImGuiCol_TitleBgCollapsed,     { 0.05, 0.05, 0.07, 0.80 });
addc(ImGuiCol_ResizeGrip,           { 0.30, 0.30, 0.35, 0.40 });
addc(ImGuiCol_ResizeGripHovered,    { 0.40, 0.40, 0.48, 0.66 });
addc(ImGuiCol_ResizeGripActive,     { 0.50, 0.50, 0.58, 0.90 });
addc(ImGuiCol_TextSelectedBg,       { 0.30, 0.40, 0.60, 0.55 });

-- Accent colours (mirror dlac's chatfmt: pale gold + coral) plus a status trio.
local COL_GOLD  = { 0.85, 0.75, 0.45, 1.00 };
local COL_CORAL = { 0.96, 0.55, 0.45, 1.00 };
local COL_GOOD  = { 0.55, 0.85, 0.55, 1.00 };
local COL_WARN  = { 0.92, 0.80, 0.40, 1.00 };
local COL_BAD   = { 0.90, 0.45, 0.45, 1.00 };
local COL_DIM   = { 0.55, 0.55, 0.60, 1.00 };

-- ---------------------------------------------------------------------------
-- Persistent settings (per character, via Ashita's settings lib when present)
-- ---------------------------------------------------------------------------

local defaults = T{
    runes          = T{ 0, 0, 0 },   -- combo indices (0 = None, 1..8 = rune)
    pulseEnabled   = true,
    pulseThreshold = 85,             -- HP% (or MP% when running 3x Tenebrae)
    margin         = 2.0,            -- seconds; lag guard between ability attempts
    enabled        = false,          -- automation on/off (user intent)
};

local config;

-- Coerce every field to a sane type/range so a hand-edited, truncated or
-- legacy settings file can never feed a nil into a widget or the worker.
local function normalizeConfig()
    -- Never REASSIGN config here: settings.load always hands back the cached
    -- table, and swapping it for a fresh one would silently detach us from the
    -- settings cache so nothing saved again. We only ever fix field values.
    if type(config) ~= 'table' then return; end
    if type(config.runes) ~= 'table' then config.runes = { 0, 0, 0 }; end
    for i = 1, 3 do
        local v = config.runes[i];
        if type(v) ~= 'number' then
            config.runes[i] = 0;
        else
            -- Floor + clamp (like pulseThreshold): a fractional index from a
            -- hand-edited file would make RUNE_NAMES[idx] nil -> concat error.
            config.runes[i] = math.max(0, math.min(8, math.floor(v)));
        end
    end
    if type(config.pulseEnabled) ~= 'boolean' then config.pulseEnabled = true; end
    if type(config.pulseThreshold) ~= 'number' then config.pulseThreshold = 85; end
    config.pulseThreshold = math.max(0, math.min(100, math.floor(config.pulseThreshold)));
    if type(config.margin) ~= 'number' then config.margin = 2.0; end
    config.margin = math.max(0.5, math.min(4.0, config.margin));
    if type(config.enabled) ~= 'boolean' then config.enabled = false; end
end

if settings ~= nil then
    config = settings.load(defaults);
else
    config = defaults;   -- no persistence available; run with defaults in memory
end
normalizeConfig();

-- The settings lib swaps the table on character login; keep our reference live.
if settings ~= nil then
    settings.register('settings', 'rah_settings_update', function(s)
        if type(s) == 'table' then config = s; end   -- only swap to a valid cached table
        normalizeConfig();
        settings.save();
    end);
end

-- ---------------------------------------------------------------------------
-- Runtime state (recomputed every frame; the UI reads it, the worker acts on it)
-- ---------------------------------------------------------------------------

local view = { is_open = false };

local state = {
    lastCastAt = 0,      -- os.clock() of our last queued ability (global JA debounce)
    saveAt     = nil,    -- debounced settings save time
    -- refreshed each frame:
    job        = { isMain = false, isSub = false, valid = false, runeCap = 0, mainLevel = 0 },
    hpp        = 0,
    mpp        = 0,
    runeRecast = 0,      -- seconds until the rune group is ready (0 = ready)
    pulseRecast= 0,      -- seconds until Vivacious Pulse is ready
    active     = {},     -- active[runeIndex] = count of that rune currently up
    mounted    = false,
    incapacit  = false,
    canAct     = false,  -- all gating conditions satisfied
    reason     = '',     -- why we're paused (shown in the UI)
    reasonCol  = COL_DIM,
};

-- ---------------------------------------------------------------------------
-- Chat output (dlac-style coloured header)
-- ---------------------------------------------------------------------------

local HEADER = (chat ~= nil) and '\30\78[\30\08rah\30\78]\30\01 ' or '[rah] ';
local function say(s)  print(HEADER .. tostring(s)); end
local function good(s) print(HEADER .. ((chat ~= nil) and chat.success(tostring(s)) or tostring(s))); end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function saveSoon()
    if settings ~= nil then state.saveAt = os.clock() + 0.75; end
end

-- Queue a job ability on ourselves. mode 1 matches the original (worked fine --
-- the bug was never the queue, it was the frequency).
local function useJA(name)
    AshitaCore:GetChatManager():QueueCommand(1, '/ja "' .. name .. '" <me>');
end

-- ---------------------------------------------------------------------------
-- Per-frame state refresh
-- ---------------------------------------------------------------------------

-- The game shares one recast timer-id across abilities by job combo, and
-- GetAbilityByTimerId can hand back nil for a shared id. recast.lua works around
-- that by scanning every ability for a matching RecastTimerId; we mirror it so a
-- nil resolution never makes a real cooldown read as "ready". Only runs on the
-- (rare) nil path.
local function abilityByTimerFallback(res, id)
    for a = 0, 2048 do
        local cand = res:GetAbilityById(a);
        if cand ~= nil and cand.RecastTimerId == id then return cand; end
    end
    return nil;
end

-- Read the rune-group and Vivacious Pulse recasts (in seconds). Robust against
-- the shared-timer-id quirk: we treat the slot whose resolved ability name is
-- ANY rune as the rune recast, and match Vivacious Pulse by exact name. Every
-- lookup is nil-checked BEFORE use (the original crashed by doing it after).
local function readRecasts()
    local rune, pulse = 0, 0;
    local mm  = AshitaCore:GetMemoryManager();
    local res = AshitaCore:GetResourceManager();
    if mm == nil or res == nil then return rune, pulse; end
    local rc = mm:GetRecast();
    if rc == nil then return rune, pulse; end
    for x = 0, 31 do
        local id    = rc:GetAbilityTimerId(x);
        local timer = rc:GetAbilityTimer(x);
        if (id ~= 0 or x == 0) and timer > 0 then
            local ability = res:GetAbilityByTimerId(id);
            if ability == nil then ability = abilityByTimerFallback(res, id); end
            if ability ~= nil and ability.Name ~= nil then
                local name = ability.Name[1];
                if name ~= nil then
                    if RUNE_LOOKUP[name] ~= nil then
                        rune = timer / 60;            -- jiffies -> seconds
                    elseif name == 'Vivacious Pulse' then
                        pulse = timer / 60;
                    end
                end
            end
        end
    end
    return rune, pulse;
end

-- Walk the player's buffs once: count each active rune, and flag mounted /
-- incapacitated. Returns active[runeIndex]=count, mounted, incapacitated.
local function readBuffs(player)
    local active = {};
    local mounted, incap = false, false;
    if player == nil then return active, mounted, incap; end
    local res   = AshitaCore:GetResourceManager();
    local buffs = player:GetBuffs();
    if res == nil or buffs == nil then return active, mounted, incap; end
    for _, buff in pairs(buffs) do
        local name = res:GetString('buffs.names', buff);
        if name ~= nil then
            local idx = RUNE_LOOKUP[name];
            if idx ~= nil then
                active[idx] = (active[idx] or 0) + 1;
            elseif name == 'Mounted' then
                mounted = true;
            elseif CANT_ACT[name] then
                incap = true;
            end
        end
    end
    return active, mounted, incap;
end

-- How many runes a Rune Fencer can hold at a given level (retail breakpoints:
-- 1 rune < 35, 2 runes 35-64, 3 runes 65+). Keeps a leveling RUN from targeting
-- more runes than it can actually hold -- otherwise the deficit never clears and
-- it re-casts forever. (Adjust here if CatsEyeXI uses different breakpoints.)
local function runeLevelCap(level)
    if     level >= 65 then return 3;
    elseif level >= 35 then return 2;
    elseif level >= 1  then return 1;
    else                    return 0; end
end

-- Refresh everything the UI and worker need. Cheap; safe to run every frame.
local function refreshState()
    state.canAct = false;   -- default: a mid-function throw can't leave this stale-true
    local mm = AshitaCore:GetMemoryManager();
    if mm == nil then return; end
    local player = mm:GetPlayer();
    local party  = mm:GetParty();
    if player == nil or party == nil then
        state.reason, state.reasonCol = 'Not logged in', COL_DIM;
        return;
    end

    -- Job (main / sub RUN) and how many runes it can hold at this level.
    local main, sub = player:GetMainJob(), player:GetSubJob();
    state.job.isMain = (main == JOB_RUN);
    state.job.isSub  = (sub == JOB_RUN);
    state.job.valid  = state.job.isMain or state.job.isSub;
    state.job.mainLevel = player:GetMainJobLevel() or 0;
    if state.job.isMain then
        state.job.runeCap = runeLevelCap(state.job.mainLevel);
    elseif state.job.isSub then
        state.job.runeCap = math.min(2, runeLevelCap(player:GetSubJobLevel() or 0));
    else
        state.job.runeCap = 0;
    end

    -- Vitals + buffs + recasts.
    state.hpp = party:GetMemberHPPercent(0) or 0;
    state.mpp = party:GetMemberMPPercent(0) or 0;
    state.active, state.mounted, state.incapacit = readBuffs(player);
    state.runeRecast, state.pulseRecast = readRecasts();

    -- Gating: figure out whether we may act, and why not if we can't.
    local zoning = (player:GetIsZoning() ~= 0);
    local res    = AshitaCore:GetResourceManager();
    local area   = (res ~= nil) and res:GetString('zones.names', party:GetMemberZone(0)) or nil;
    if not state.job.valid then
        state.canAct, state.reason, state.reasonCol = false, 'Not a Rune Fencer', COL_DIM;
    elseif zoning then
        state.canAct, state.reason, state.reasonCol = false, 'Zoning', COL_WARN;
    elseif state.hpp < 1 then
        state.canAct, state.reason, state.reasonCol = false, 'No HP (dead / loading)', COL_WARN;
    elseif state.mounted then
        state.canAct, state.reason, state.reasonCol = false, 'Mounted', COL_WARN;
    elseif area == nil or TOWNS:contains(area) then
        state.canAct, state.reason, state.reasonCol = false, 'In town', COL_WARN;
    elseif state.incapacit then
        state.canAct, state.reason, state.reasonCol = false, 'Can\'t act', COL_WARN;
    else
        state.canAct, state.reason, state.reasonCol = true, 'Engaged', COL_GOOD;
    end
end

-- ---------------------------------------------------------------------------
-- Decision logic
-- ---------------------------------------------------------------------------

-- Build the desired rune multiset from the slots. Two independent limits apply:
--   slotCap  -- how many SLOTS this job exposes (3 main / 2 /RUN). We read only
--              that many slots, so /RUN never picks up a stale main-only slot 3.
--   cap      -- how many runes are actually HOLDABLE (slotCap clamped by level).
--              The list is trimmed to this, so a leveling RUN never chases a
--              rune it can't keep (which would loop forever). Returns the ordered
--              list (duplicates allowed) and cap.
local function desiredRunes()
    local slotCap = state.job.isMain and 3 or (state.job.isSub and 2 or 0);
    local cap     = math.min(slotCap, state.job.runeCap or slotCap);
    local list = {};
    for i = 1, slotCap do
        if #list >= cap then break; end
        local idx = config.runes[i];
        if type(idx) == 'number' and idx >= 1 and idx <= 8 then
            list[#list + 1] = idx;
        end
    end
    return list, cap;
end

-- The first desired rune (in slot order) that isn't yet at its wanted count,
-- or nil when the whole desired set is up. Counts as a multiset, so 2x Ignis
-- only reports a deficit while fewer than two Ignis are active.
local function runeDeficit(desired)
    local want, seen = {}, {};
    for _, id in ipairs(desired) do want[id] = (want[id] or 0) + 1; end
    for _, id in ipairs(desired) do
        if not seen[id] then
            seen[id] = true;
            if (state.active[id] or 0) < want[id] then return id; end
        end
    end
    return nil;
end

-- One action per frame at most: runes first (until the set is up), then pulse.
-- The global debounce (lastCastAt + margin) bridges the network round-trip so
-- we never re-queue while a just-issued ability hasn't registered its recast
-- yet -- that window was the original's spam.
local function tryCast()
    if not (config.enabled and state.canAct) then return; end

    local now = os.clock();
    if now < state.lastCastAt + (config.margin or 2.0) then return; end

    local desired = desiredRunes();
    if #desired == 0 then return; end   -- nothing selected

    -- Runes: cast the first deficit element when the shared recast is ready.
    local deficit = runeDeficit(desired);
    if deficit ~= nil then
        if state.runeRecast <= 0 then
            useJA(RUNE_NAMES[deficit]);
            state.lastCastAt = now;
        end
        return;   -- don't also pulse while still stacking runes
    end

    -- Vivacious Pulse: only once the desired runes are all up, main job only.
    -- Level-gated (learned at RUN 45): below that it isn't in the recast table,
    -- so pulseRecast would read 0 and we'd queue a "cannot use" every margin.
    if config.pulseEnabled and state.job.isMain and state.job.mainLevel >= PULSE_LEVEL and state.pulseRecast <= 0 then
        -- 3x Tenebrae converts Vivacious Pulse to an MP restore -> gate on MP%.
        local mpMode = (#desired == 3);
        for _, id in ipairs(desired) do if id ~= TENEBRAE then mpMode = false; break; end end
        local pct = mpMode and state.mpp or state.hpp;
        if pct < config.pulseThreshold then
            useJA('Vivacious Pulse');
            state.lastCastAt = now;
        end
    end
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local function pushTheme()
    for _, s in ipairs(THEME) do imgui.PushStyleColor(s[1], s[2]); end
end
local function popTheme()
    imgui.PopStyleColor(#THEME);
end

-- Colour a recast value: green when ready, gold while counting down.
local function drawRecast(label, secs)
    imgui.Text(label);
    imgui.SameLine();
    if secs <= 0 then
        imgui.TextColored(COL_GOOD, 'ready');
    else
        imgui.TextColored(COL_GOLD, string.format('%.1fs', secs));
    end
end

-- The window BODY (everything between Begin and End). Kept separate so the
-- frame hook can pcall JUST this: an error here can no longer skip the
-- imgui.End() below it and leave the window stack unbalanced (which is what
-- would actually crash the client on a later frame).
local function drawBody()
    -- Header line (pale gold brackets + coral name, like dlac's chat).
    imgui.TextColored(COL_GOLD, '[');   imgui.SameLine(0, 0);
    imgui.TextColored(COL_CORAL, 'Rune-Actually-Helper'); imgui.SameLine(0, 0);
    imgui.TextColored(COL_GOLD, ']');
    imgui.SameLine();
    if state.job.isMain then      imgui.TextColored(COL_DIM, 'RUN');
    elseif state.job.isSub then   imgui.TextColored(COL_DIM, '/RUN');
    else                          imgui.TextColored(COL_DIM, 'not RUN'); end

    imgui.Separator();

    -- Status line: automation state and, when paused, why.
    if not config.enabled then
        imgui.TextColored(COL_DIM, 'Status: Disabled');
    elseif state.canAct then
        imgui.TextColored(COL_GOOD, 'Status: Engaged');
    else
        imgui.TextColored(COL_WARN, 'Status: Paused -- ' .. state.reason);
    end

    -- Live vitals + recasts.
    imgui.TextColored(COL_DIM, string.format('HP %d%%   MP %d%%', state.hpp, state.mpp));
    drawRecast('Rune recast:', state.runeRecast);
    local canPulse = state.job.isMain and state.job.mainLevel >= PULSE_LEVEL;
    if config.pulseEnabled and canPulse then drawRecast('Pulse recast:', state.pulseRecast); end

    imgui.Separator();

    -- Rune selectors. /RUN only exposes two slots (slot 3 is main-job only).
    local slots = state.job.isMain and 3 or 2;
    for i = 1, 3 do
        local label = 'Rune ' .. i;
        if i > slots then
            imgui.TextDisabled(label .. ':  main-job only');
        else
            local sel = { config.runes[i] };
            if imgui.Combo(label, sel, RUNE_COMBO) then
                config.runes[i] = sel[1];
                saveSoon();
            end
        end
    end

    -- Which of the desired runes are currently up.
    local desired = desiredRunes();
    if #desired > 0 then
        imgui.Spacing();
        imgui.TextColored(COL_DIM, 'Runes up:');
        imgui.SameLine();
        local shown = {};
        for k, id in ipairs(desired) do
            shown[id] = (shown[id] or 0) + 1;
            local up = (state.active[id] or 0) >= shown[id];
            if k > 1 then imgui.SameLine(); end
            imgui.TextColored(up and COL_GOOD or COL_DIM, RUNE_NAMES[id]);
        end
    end

    imgui.Separator();

    -- Vivacious Pulse controls (main-job RUN, level 45+ -- when it's usable).
    if canPulse then
        local pe = { config.pulseEnabled };
        if imgui.Checkbox('Vivacious Pulse', pe) then config.pulseEnabled = pe[1]; saveSoon(); end
        imgui.ShowHelp('Auto-uses Vivacious Pulse once your runes are up. With 3x Tenebrae the threshold is read as MP% instead of HP%.');
        if config.pulseEnabled then
            local thr = { config.pulseThreshold };
            if imgui.SliderInt('Pulse at %', thr, 0, 100) then
                config.pulseThreshold = thr[1];
                saveSoon();
            end
        end
    elseif state.job.isMain then
        imgui.TextDisabled('Vivacious Pulse:  learned at RUN 45');
    else
        imgui.TextDisabled('Vivacious Pulse:  main-job only');
    end

    imgui.Separator();

    -- Lag margin (advanced).
    local mg = { config.margin };
    if imgui.SliderFloat('Lag margin (s)', mg, 0.5, 4.0, '%.1f') then
        config.margin = mg[1];
        saveSoon();
    end
    imgui.ShowHelp('Minimum wait between ability attempts. Covers the delay before a used ability shows its recast, so nothing gets spammed. Raise it if you have high latency.');

    imgui.Spacing();

    -- Big enable/disable button. Push -> click -> pop are kept tight (no other
    -- call between) so the pushed colour can never leak if imgui errored.
    local btnCol = config.enabled and { 0.30, 0.15, 0.15, 1.0 } or { 0.15, 0.30, 0.18, 1.0 };
    imgui.PushStyleColor(ImGuiCol_Button, btnCol);
    local clicked = imgui.Button(config.enabled and 'Disengage' or 'Engage', { -1, 0 });
    imgui.PopStyleColor(1);
    if clicked then config.enabled = not config.enabled; saveSoon(); end

    imgui.TextColored(COL_DIM, '/rah toggle to engage   -   /rah to hide');
end

local function drawWindow()
    -- Min-width floor while still auto-fitting height/content (AlwaysAutoResize).
    imgui.SetNextWindowSizeConstraints({ 290, 0 }, { 10000, 10000 });
    local flags = ImGuiWindowFlags_AlwaysAutoResize or 0;
    local open = { view.is_open };
    -- Begin/End are OUTSIDE the pcall so End() always runs even if the body
    -- raises -- an unmatched Begin would trip imgui's stack assert next frame.
    local vis = imgui.Begin('Rune-Actually-Helper', open, flags);
    if vis then pcall(drawBody); end
    imgui.End();

    -- Window closed via its [x]: keep the user's intent in sync.
    if open[1] == false then view.is_open = false; end
end

-- ---------------------------------------------------------------------------
-- Frame hook: refresh, act, draw. Each stage is isolated so an error in one
-- can never take down the others or leak the imgui style stack.
-- ---------------------------------------------------------------------------

ashita.events.register('d3d_present', 'rah_present', function()
    pcall(refreshState);
    pcall(tryCast);

    -- Debounced settings save (avoids a disk write per slider tick).
    if state.saveAt ~= nil and os.clock() >= state.saveAt then
        state.saveAt = nil;
        if settings ~= nil then pcall(settings.save); end
    end

    if not view.is_open then return; end
    pushTheme();
    pcall(drawWindow);
    popTheme();
end);

-- ---------------------------------------------------------------------------
-- Command hook
-- ---------------------------------------------------------------------------

ashita.events.register('command', 'rah_command', function(e)
    local args = e.command:args();
    if #args == 0 then return; end
    local cmd = args[1]:lower();
    if cmd ~= '/rah' and cmd ~= '/runeactuallyhelper' then return; end
    e.blocked = true;

    local sub = (#args >= 2) and args[2]:lower() or nil;
    if sub == nil then
        view.is_open = not view.is_open;
    elseif sub == 'toggle' then
        config.enabled = not config.enabled;
        saveSoon();
        say(config.enabled and 'Engaged.' or 'Disengaged.');
    elseif sub == 'on' or sub == 'engage' then
        config.enabled = true;  saveSoon(); good('Engaged.');
    elseif sub == 'off' or sub == 'disengage' then
        config.enabled = false; saveSoon(); say('Disengaged.');
    elseif sub == 'show' then
        view.is_open = true;
    elseif sub == 'hide' then
        view.is_open = false;
    else
        say('commands: /rah [toggle | on | off | show | hide]');
    end
end);

-- Persist once on unload so nothing is lost if a change was still debouncing.
ashita.events.register('unload', 'rah_unload', function()
    if settings ~= nil then pcall(settings.save); end
end);
