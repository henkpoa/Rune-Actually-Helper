# Rune-Actually-Helper

An Ashita v4 addon that keeps a Rune Fencer's runes up and uses Vivacious Pulse
automatically — a rework of GetAwayCoxn's original **Rune Helper** that
*actually* tracks the ability cooldown (hence the name), doesn't spam, doesn't
crash, and doesn't look like a ransom note.

> **Credit & license.** This is a derivative work of
> **[Rune Helper](https://github.com/GetAwayCoxn/Rune-Helper) by GetAwayCoxn (Dan)**,
> the original author who wrote the first version this is built on. It is
> redistributed under that project's original **MIT License** (see
> [`LICENSE`](LICENSE), which retains the original copyright). Thanks also to
> **Thorny** for the buff-count approach borrowed from LuaAshitacast.

## Install

Drop the `Rune-Actually-Helper` folder in `Ashita\addons\`, then:

```
/addon load Rune-Actually-Helper
```

(Add that line to your `Default.txt` / script to load it every boot.)

## Commands

| Command | What it does |
| --- | --- |
| `/rah` | show / hide the window |
| `/rah toggle` | engage / disengage the automation |
| `/rah on` \| `off` | engage / disengage explicitly |
| `/rah show` \| `hide` | show / hide the window |

`/runeactuallyhelper` works everywhere `/rah` does.

## Using it

1. Pick up to three runes in the window (slot 3 is main-job RUN only; `/RUN`
   holds two).
2. Optionally enable **Vivacious Pulse** and set the HP% threshold to fire it at.
3. Click **Engage** (or `/rah toggle`).

It keeps your chosen runes up and, once they're all up, uses Vivacious Pulse
when your HP drops below the threshold. Run **3× Tenebrae** and the threshold is
read as **MP%** instead (that's the configuration where Vivacious Pulse restores
MP). Everything you set is remembered per character.

## What changed from the original

- **Real cooldown tracking.** The original looked the rune recast up by the name
  "Rune Enchantment", but the game shares one recast timer across all eight rune
  abilities and reports it under a rune *name* (Ignis, Gelus, …). So the check
  never matched, always read 0, and the ability got spammed until the buffs
  happened to land. This version detects the rune recast by any rune name and
  adds a lag-margin debounce, so it issues **one ability per margin window** and
  never re-queues into the network round-trip.
- **No more crashes.** The recast scan used to read `ability.Name` *before*
  checking the record was non-nil — a nil record threw every frame it happened.
  Every lookup is now nil-checked, and the per-frame work and the whole draw are
  wrapped so an error can't take the addon (or your UI) down.
- **Pause, don't disable.** In town, while zoning, mounted, or when you can't
  act, it *pauses* and auto-resumes — instead of silently switching itself off
  so you had to re-enable it every time.
- **Cleaner rune logic.** Your selection is treated as a multiset: stack the
  same element up to 3×, in any mix; it only ever casts the missing one.
- **Settings persist per character**, and the window wears CatsEyeXI/dlac's dark
  theme.

## Notes

- The **Lag margin** (Advanced) is the minimum wait between ability attempts.
  The default (2.0s) is safe; raise it if you play on high latency.
- Vivacious Pulse is a main-job RUN ability learned at level 45, so its controls
  only appear (and only fire) on a main RUN at 45+. Runes are likewise capped to
  what you can actually hold at your level, so a leveling RUN never chases a rune
  it can't keep.

Credit to **GetAwayCoxn** for the original Rune Helper, and to **Thorny** for the
buff-count approach it borrowed from LuaAshitacast.
