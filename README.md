# Performance HUD

A free, native macOS menu-bar performance HUD for Apple Silicon. No Apple Developer
account, no paid app. Two things in one:

1. **Toggles Apple's built-in Metal Performance HUD** (the free in-game overlay from
   the screenshots) on/off — globally or for a single game.
2. **Shows system stats the Metal HUD can't** — CPU, GPU, RAM, die temperature,
   fan RPM, power draw, disk I/O, battery, and network — in the menu bar and a
   sparkline panel.

Built and tested on macOS 26.5, Apple M5 Max.

## Build & run

```bash
./build-app.sh          # produces PerformanceHUD.app (ad-hoc signed, runs locally)
open PerformanceHUD.app # look for the live readout in the menu bar (top-right)
```

For development, `swift build && ./.build/debug/PerformanceHUD` also works.

To **launch at login**: System Settings → General → Login Items → add
`PerformanceHUD.app`.

## Two kinds of overlay

**1. Apple's Metal HUD** — the free, built-in overlay from the screenshots. Toggled
via the `MTL_HUD_ENABLED` environment variable. Shows FPS / frame time / GPU timings
and is the **only** thing that composites over an *exclusive-fullscreen* Metal game
(the OS injects it into the game's render stream). It shows just GPU/Metal info — no
CPU/temp. You must **relaunch the game** after enabling.

**2. This app's Game overlay** — a click-through floating card (styled like the Metal
HUD) showing CPU, GPU, RAM, temp, and network. Each row is individually toggleable
("Overlay contents" in the panel), and the card resizes to fit. Pick which corner it
pins to. It floats over **windowed and borderless-fullscreen** games (most Steam /
Game Porting Toolkit titles). It **cannot** draw over exclusive-fullscreen — use the
Metal HUD there.

### FPS

There is no accurate, free way to read an arbitrary game's frame rate from outside
its process on macOS (no public PresentMon equivalent; accurate numbers require
in-process hooks). So this app does **not** show FPS. Use the accurate sources
instead: the game's own counter (e.g. Lunar Client → Settings → Mods → FPS), or
Apple's Metal HUD for Metal games.

### Enabling the Metal HUD for Steam games

Steam passes its environment to the games it launches, so the global toggle only
works if Steam started *after* it was set. Two ways:

- **Per game (recommended):** Steam → right-click the game → Properties → Launch
  Options: `MTL_HUD_ENABLED=1 %command%`
- **Global:** Quit Steam completely, then use "Launch game with HUD…" → pick
  Steam.app. Or by hand: `launchctl setenv MTL_HUD_ENABLED 1` then restart Steam.

## Menu bar

Fully configurable via checkboxes in the panel — show any combination of CPU %, GPU %,
and RAM (as % or GB). Temperature is intentionally omitted (Macs Fan Control already
shows it). If you turn everything off it falls back to CPU %.

**Hide menu bar in full screen** flips macOS's own setting between "menu bar
everywhere" and "hidden in full screen only" — one click before a film, one click
after. The desktop half of the setting is preserved, not overwritten.

The setting lives in three places and only two of them do anything. macOS reads
the pair of global-domain keys `_HIHideMenuBar` (the desktop half) and
`AppleMenuBarVisibleInFullscreen` (the full-screen half, stored **inverted** —
true means the bar stays visible). `AutoHideMenuBarOption` in
`com.apple.controlcenter` is the System Settings picker's own state, holding its
four options in order: `0` Always, `1` On Desktop Only, `2` In Full Screen Only,
`3` Never. The app writes all three, so the picker agrees with reality.

An earlier version had this backwards and wrote only `AutoHideMenuBarOption`,
which moved the picker and changed nothing else. Two things settle the polarity.
`AppleMenuBarVisibleInFullscreen` and `_HIHideMenuBar` both appear in system
framework code in the dyld shared cache; `AutoHideMenuBarOption` appears in none
of it, nor in System Settings' binary, `PreferencePanes`, or `ExtensionKit` — so
nothing in the OS is in a position to read it. And writing `_HIHideMenuBar`
changes behaviour live: the strip `NSScreen` reserves at the top of the display
moved 39 → 38 → 39 pt within 2.5 s of the write, with no relaunch.

That 1 pt has an explanation. On a notched display the notch stays reserved
whether the bar is showing or not (`safeAreaInsets.top` is 38 pt against a 39 pt
menu bar), so auto-hiding only ever reclaims the 1 pt below it. The same notch
defeats the obvious test of the *full-screen* half from code: window height is
capped at `frame.height - 39` either way, and each Space carries its own
`Menubar` window, so neither geometry nor `CGWindowListCopyWindowInfo` can tell
the two states apart. Confirmed by eye instead — toggle on, full-screen a
window, the bar goes. macOS 26.5.2, M-series MacBook Pro with notch.

## Fan control

Out of scope by design — **Macs Fan Control** (which you already use) owns fan
control. This app only *reads and displays* fan RPM. It has no API to hook into, so
the two apps simply run side by side.

## How the stats are read (all free, no entitlements)

| Metric        | Source |
|---------------|--------|
| CPU           | Mach `host_statistics` (`HOST_CPU_LOAD_INFO`) |
| Memory        | `host_statistics64` (`vm_statistics64`) |
| Memory pressure | `kern.memorystatus_vm_pressure_level` sysctl |
| Swap          | `vm.swapusage` sysctl (`xsw_usage`) |
| GPU           | IOKit `IOAccelerator` → `Device Utilization %` |
| Network       | `getifaddrs` byte-counter deltas |
| Temperature   | SMC `Tp**` (CPU cores) / `Tg**` (GPU); IOHID hub as fallback |
| Fan RPM       | SMC keys `FNum`, `F0Ac`, `F1Ac` |
| Disk I/O      | `IOBlockStorageDriver` byte-counter deltas |
| Battery       | `AppleSmartBattery` IORegistry node |
| Thermal state | `ProcessInfo.thermalState` |
| Clock speeds  | IOReport `CPU Stats` / `GPU Stats` DVFS residency |
| GPU memory    | `IOAccelerator` → `In use system memory` / `Alloc system memory` |
| Top processes | `libproc` CPU-time deltas (`proc_pid_rusage`) |
| Power         | SMC keys `PDTR` (adapter in), `PSTR` (system draw) |
| Power breakdown | IOReport `Energy Model` group (CPU / GPU / ANE / DRAM / fabric / …) |

On M-series the IOHID hub reports generic die sensors (`PMU tdieN`), so the temp
row shows the **hottest die** reading (what drives thermal throttling).

### Temperatures: core sensors, not die sensors

The IOHID thermal hub exposes only generic die-*area* sensors (`PMU tdieN`) which
run **15-20 °C below the real hot spots** — measured together, the hub reported
58.6 °C while the hottest CPU core was 82.2 °C. The panel therefore reads the SMC's
per-core keys (`Tp**`, 23 sensors here) and GPU keys (`Tg**`, 84 sensors), the same
ones Macs Fan Control shows, and falls back to the IOHID hub only if the SMC is
unreachable. The SMC exposes 3738 keys; they're walked once at startup and the
temperature ones cached with their size and type, so each later read is a single
IOKit call (see [What it costs](#what-it-costs)).

### Reading the thermal badge

`ProcessInfo.thermalState` is an *advisory to apps*, not a measurement of clock
limiting, and only its top two tiers mean performance is actually reduced:

| State | Badge | Meaning |
|---|---|---|
| `nominal` | none | Normal. |
| `fair` | `warm` (yellow) | Slightly elevated, fans audible. macOS asks apps to ease off but does **not** cut performance. Routine under sustained load. |
| `serious` | `throttling` (orange) | macOS is reducing performance to shed heat. |
| `critical` | `critical` (red) | Performance heavily cut until the machine cools. |

The menu bar 🔥 fires only on `serious`/`critical`.

**`thermalState` is not a throttle detector.** In a 15-minute soak on an M5 Max it
never left `fair` — through a 100.7 °C peak, package power being cut 93.7 W → 49.7 W,
and GPU clocks falling 55% → 20%. So the panel also carries a **`power limited`**
badge driven by the signal that did track it: power falling below its recent peak
while utilization stays pinned. Replayed against that recorded soak, it flags the
window from 00:87 to 04:40 into the run and clears once the machine settles at its
sustained ~74 W.

Clock percentages are the other check: a cluster at 100% clk is at its top DVFS rung.
But read `clk` together with `busy` — a near-idle cluster reads 100% clk because
macOS races short tasks to completion at full speed, so the panel shows `idle`
instead of a misleading clock figure below 10% busy.

### Why clocks are a percentage, not MHz

Clock speed comes from IOReport's DVFS residency histograms: each cluster reports
how long it spent on each rung of its frequency ladder, and the panel shows the
residency-weighted rung as a percentage of the top state. Cluster names come from
`hw.perflevelN.name`, so they match what Apple calls them on your chip — an M5 Max
reports "Super" and "Performance", not the "Efficiency"/"Performance" pair older
Apple Silicon uses.

Absolute MHz is *not* derivable without root. The device-tree frequency tables
(`voltage-states*` under `IODeviceTree:/arm-io/pmgr`) use two different encodings:
GPU tables store plain Hz, but the CPU cluster tables store a clock **period** in an
undocumented unit (e.g. `50103` down to `14222` across 20 states) with no anchor to
convert it — `clock-frequency` on the CPU device-tree nodes is the 24 MHz timebase,
not a core clock. Matching a table to a cluster by state count is unambiguous
(15-entry tables ↔ the 15-rung 12-core clusters, 20-entry ↔ the 20-rung 6-core one),
but the scale factor isn't recoverable on-device. `sudo powermetrics --samplers
cpu_power` prints real frequencies and could calibrate it — at the cost of requiring
root, which this app otherwise never needs.

### What the power breakdown can and can't tell you

The SoC meters itself per *block*, so CPU / GPU / Neural Engine / DRAM watts are
real measurements — the same counters `powermetrics` reports, but IOReport needs
no root. The panel shows those four inline; **hover the Power row** to float a card
itemising every metered block (memory controller, system cache, SoC fabric, display
engine, camera ISP, video encoder, PCIe …) reconciled against the system total.

The last line, **Not metered**, is not a measurement: it's the total minus everything
metered, covering the screen backlight, SSD, Wi-Fi, speakers, anything charging off a
USB port, and regulator losses. Because it's a remainder of two independently sampled
figures (SMC `PSTR` and the IOReport counters), it's noisy while load is swinging and
settles at steady state.

There is no finer attribution available on a Mac:

- **Per peripheral** (e.g. "how much is my phone drawing?") — no. USB ports expose
  only their *negotiated current limit* (`kUSBWakePortCurrentLimit`, typically
  3000 mA), never actual draw. A charging phone shows up inside `PSTR` and inside
  **Other**, indistinguishable from the backlight.
- **Per process** — no. `powermetrics` per-process "energy impact" is a unitless
  heuristic score (weighted CPU time, wakeups, GPU and disk activity), not watts,
  and it needs root. Hovering the CPU row shows the busiest processes by CPU *time*,
  which is the closest honest equivalent. Note that `proc_pid_rusage` returns `EPERM`
  for processes owned by other users, so system daemons are missing — on this machine
  536 of 785 processes were readable.

## What it costs

A performance monitor that costs performance is self-defeating, so this is measured
rather than assumed. Idle, with the panel closed, on an M5 Max:

| Configuration | CPU |
|---|---|
| **Default (1 s, battery saver on, on battery)** | **0.62% of one core** |
| 1 s, battery saver off | 1.18% |
| Panel open | ~2.6%, only while it's on screen |

For scale, an earlier build that sampled everything at 1 Hz regardless of what was
visible sat at **5.88%** around the clock.

Numbers are 120-second CPU-time deltas (`ps -o time`) on an otherwise idle machine.

### Where it goes

The readers differ by three orders of magnitude, so the ones that matter are worth
knowing. Per sample, on this machine:

| Reader | Wall | CPU |
|---|---|---|
| Thermal (107 SMC keys + IOHID hub) | 67.4 ms | 4.0 ms |
| Power (SMC rails + IOReport blocks) | 6.5 ms | 5.2 ms |
| Clocks (IOReport DVFS residency) | 4.4 ms | 4.4 ms |
| GPU | 0.9 ms | 0.9 ms |
| Top processes (~750 `proc_pid_rusage`) | 0.6 ms | 0.6 ms |
| Battery | 0.2 ms | 0.2 ms |
| Disk / network / CPU / memory | <0.05 ms | <0.05 ms |

The thermal sweep is mostly *blocked* on IOKit rather than burning CPU — the wall
figure is what keeps the machine from settling into idle, which is the number that
matters on battery.

### Sampling is driven by what's on screen

Nothing is polled faster than something visible needs it:

| Reader | Menu bar only | Overlay up | Panel open |
|---|---|---|---|
| Thermal | every 15 s | every 5 s | every tick |
| Power | only under load¹ | only under load¹ | every tick |
| Clocks, top processes | not at all | not at all | every tick |
| CPU, GPU, memory, network, disk, battery | every tick | every tick | every tick |

¹ Also whenever watts are enabled in the menu bar. Otherwise power is read only at
or above `ThrottleDetector.loadThreshold` (70% load) — below it the throttle
detector discards every reading it's handed, so taking them is pure cost.

Delta-based readers (clocks, top processes, the per-block power breakdown) prime on
the first read after a pause instead of publishing a figure that averages over the
whole gap.

**Settings** — "Update every" picks 0.5 / 1 / 2 / 5 s, and "Halve the rate on
battery" (on by default) doubles that interval when unplugged. Timers carry 20%
tolerance so macOS can coalesce their wakeups.

### The four things that actually mattered

1. **Cache the IOHID client and its service list.** The hub matches 77 services here,
   of which 52 ever return a plausible reading (the `PMU tdev*` group sits at
   −9200 °C) and those share only 17 distinct `Product` names. Rebuilding the client
   and re-enumerating every tick cost 109 ms wall / 10.6 ms CPU; reusing them costs
   88 ms / 3.0 ms, and skipping the dead sensors and per-tick name lookups takes the
   rest. Services sharing a name are averaged rather than letting whichever came last
   in an unordered list win.
2. **Read SMC keys in one call, not two.** A key's size and type are fixed for the
   life of the machine and already known from enumeration, so the `kSMCGetKeyInfo`
   probe before every read doubled the syscall count to learn something known at
   startup. Across the 107 cached temperature keys: 47.6 ms → 19.8 ms, with identical
   values on all 107.
3. **Share one SMC connection.** Fans, watts and per-core temps each opened and closed
   their own `AppleSMC` user client per sample.
4. **Don't let SwiftUI re-render what nobody can see.** This was worth more than the
   sensors. A `MenuBarExtra`'s content view stays alive after its window closes, and
   every published sample drove a full AppKit layout pass over the hidden tree —
   ~1% of a core for a view nobody could see. The panel now reads the monitor without
   subscribing to it (`PanelRefresh` relays updates only while it's open), the
   menu-bar label takes a string that's republished only when it changes
   (`MenuBarText`), and the app holds its controllers in `@State` rather than
   `@StateObject` so the scene isn't re-evaluated on every sample.

## Debugging sensors

```bash
./.build/debug/PerformanceHUD --dump-sensors
```

Prints every temperature sensor + fan + power draw + a 1-second CPU/GPU/RAM/network
sample.
Cross-check against the Macs Fan Control window.

```bash
./.build/debug/PerformanceHUD --bench
```

Times every reader, wall and CPU, so the polling rates above stay measured rather
than guessed. Run it before and after touching anything in `Sensors/` or
`SensorBridge`.

## Project layout

```
Sources/SensorBridge/   Objective-C: IOHID temps + SMC fan RPM & watts (private-but-stable SPI)
Sources/PerformanceHUD/
  App/                  entry point, --dump-sensors and --bench modes
  Sensors/              CPU, GPU, Memory, Network, Thermal, Power, SystemMonitor (poller)
  MetalHUD/             MetalHUDController (launchctl toggle)
  System/               MenuBarVisibilityController (global-domain macOS prefs)
  UI/                   MenuBarLabel, StatsPanelView, Sparkline
```

`SystemMonitor` is the poller, and `SensorDemand` next to it is where the polling
rates live — if you add a reader, decide there which parts of the UI justify its
cost rather than adding it to every tick.
