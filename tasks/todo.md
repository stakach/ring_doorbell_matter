# ring_doorbell_matter — implementation progress

Plan: `/home/steve/.claude/plans/sleepy-juggling-spring.md`

## Tasks

- [x] 1. crystal-matter: add notifying `PowerSourceCluster#update_bat_percent_remaining`
      (+3 specs) — pushed as Crystal-Matter/matter@3a4b41d
- [x] 2. Bridge: controller.cr (Control interface over RingDoorbell::Client),
      matter.cr (occupancy+power source endpoints, ding→30s motion w/ extend,
      battery poll loop), cli.cr (env config, doorbell fetch retry)
- [x] 3. Specs: FakeRingControl, 8 examples green (motion trigger/clear/extend,
      multi-doorbell endpoints, nil/unknown id routing, motion_triggers flag,
      battery seed + sync thresholds, hold_time attribute)
- [x] 4. Dockerfile / docker-compose.yml / .gitignore / README
- [x] 5. LIVE: commission with chip-tool, real doorbell press → occupancy
      subscribe shows 1 then 0 after ~30s; battery read = 2× Ring %
- [x] 6. Commit + push to github.com/stakach/ring_doorbell_matter

## Review (live verification, 2026-06-05)

- crystal-matter@3a4b41d (new battery updater) pushed; bridge locks it.
- 8 bridge specs green; format + ameba clean.
- Live, commissioned as chip-tool node 12 (manual code 3497-011-2332,
  discriminator 3843): Occupancy read 0; BatPercentRemaining 124 (= 62%×2);
  BatChargeLevel 0 (Ok). Push listener started only after commissioning.
- Real button press: `ding at Front Entrance — motion for 30s` → chip-tool
  Occupancy read 1 → `motion cleared` exactly 30s later → Occupancy 0.
- Bonus: a live mtalk connection reset occurred mid-test; the listener
  reconnected in 1.5s and the subsequent ding was still delivered.

NOTE: the manual pairing code matches samsung_tv_matter's because manual
codes only encode the 4 MSBs of the discriminator (3842 vs 3843 share them)
plus the same test PIN — only one of the two may be in commissioning mode at
a time when pairing by code.

## Design notes

- Endpoints 1..N = doorbells sorted by Ring id (stable while the device set
  is unchanged; adding/removing doorbells renumbers → re-pair).
- Each endpoint: OccupancySensing (PIR, hold_time attr) + PowerSource
  (Battery feature: bat_percent_remaining 0-200 half-percent, charge level
  Ok>20 / Warning≤20 / Critical≤10, UserReplaceable, bat_present) +
  Identify + FixedLabel(name).
- Ding (and intercom buzz — the library maps both to on_ding) → occupancy
  true; re-press extends via an Atomic generation counter; clear after
  MOTION_HOLD (default 30s).
- Ring motion pushes only trigger when MOTION_TRIGGERS=true (the user's
  audio-only Intercom never sends them).
- No callback suppression needed — sensors take no inbound writes.
- Push listener deferred until commissioned (fabric_table empty check),
  battery polled hourly (Ring rate limits; battery moves slowly).
