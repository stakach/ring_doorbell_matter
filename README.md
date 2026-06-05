# ring_doorbell_matter

A **Matter bridge** for Ring doorbells. It wraps the
[`ring_doorbell`](https://github.com/stakach/ring_doorbell) client library and
exposes each doorbell on the account to any Matter controller (HomeKit,
chip-tool, ...) as an **occupancy (motion) sensor with battery level**.

A doorbell press triggers the motion sensor for **30 seconds** (configurable);
pressing again extends the window. Ring delivers presses via real-time push
(FCM), so the sensor reacts within a second or two of the button press.

## Endpoints

One endpoint per doorbell (sorted by Ring device id — endpoint numbers stay
stable while the set of doorbells is unchanged; adding/removing a doorbell
renumbers them, so re-pair after changing hardware).

| Cluster | Behaviour |
|---------|-----------|
| **Occupancy Sensing** (PIR) | Occupied for `MOTION_HOLD` seconds after a doorbell press (intercom buzzes count). Re-pressing extends. Changes are pushed to subscribed controllers. |
| **Power Source** (Battery) | `BatPercentRemaining` (Matter half-percent units, i.e. 2× the Ring %) + charge level (Ok / Warning ≤20% / Critical ≤10%), refreshed every `BATTERY_POLL` seconds. |
| **Fixed Label** | The doorbell's Ring name. |

Ring *motion* events (camera models) do **not** trigger the sensor unless
`MOTION_TRIGGERS=true`.

## Running

```bash
shards install
crystal run src/main.cr
# or: shards build && ./bin/ring_doorbell_matter
```

Configuration (env vars, or the matching `--flags`):

| Variable | Default | Purpose |
|----------|---------|---------|
| `RING_TOKEN_FILE` | `data/ring.token` | Ring auth/state file (see Pairing below) |
| `MATTER_STORAGE_FILE` | `data/ring_doorbell_matter_storage.json` | Matter fabric persistence |
| `MOTION_HOLD` | `30` | Seconds the sensor stays occupied after a press |
| `BATTERY_POLL` | `3600` | Battery refresh interval (seconds) |
| `MOTION_TRIGGERS` | `false` | Ring motion events also trigger the sensor |
| `LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |

### Pairing — two steps

1. **Ring:** authenticate once (email + password + 2FA) with the client
   library's init example, which writes the token file:
   `crystal run lib/ring_doorbell/examples/init.cr -- data/ring.token`
   (or copy an existing working `ring.token` into `data/`).
2. **Matter:** on start (uncommissioned) the bridge prints a QR code and a
   manual pairing code. Scan it with your controller, or:
   `chip-tool pairing code 1 <manual-code>`

The Ring cloud is only contacted for the initial doorbell discovery; the push
listener starts once the bridge has been commissioned.

### Docker

Make sure the data folder permissions are correct and the token file is in
place first:

```bash
sudo chown -R 10001:10001 ./data/
docker compose up -d
```

Uses `network_mode: host` (required for mDNS/Matter UDP) and persists the
Matter fabrics + Ring token in `./data`.

## Development

- `crystal spec` — sensor wiring is tested against a fake Ring control (no
  account needed).
- `crystal tool format` / `./bin/ameba` — format and lint.

## Contributing

1. Fork it (<https://github.com/stakach/ring_doorbell_matter/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Stephen von Takach](https://github.com/stakach) - creator and maintainer
