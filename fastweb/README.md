# fastweb_power

Live power draw from the Fastweb portal, into Home Assistant, as a plain watt number.

Fastweb publishes realtime consumption on the "Power Control" page under `myfastweb.it`, which is what you want if you're paying per-kWh. That page is behind their normal customer login, renders client-side, and talks to an AJAX endpoint guarded by a `securityToken` scraped out of the page HTML. Getting `curl` through that is doable but annoying, so this script does the awkward parts.

**It prints one integer (watts) to stdout and nothing else.** Logs go to stderr. Exit `0` means you got a reading; anything non-zero means the sensor should be marked unavailable. That's the whole contract, because it's the one `command_line` sensor wants.

## Requirements

`bash`, `curl`, `python3`. No `jq`, no Node, no browser.

## Setup

1. Get the folder onto the box, e.g. `/config/scripts/fastweb/`:

   ```bash
   mkdir -p /config/scripts/fastweb
   cp fastweb_power.sh /config/scripts/fastweb/
   cp .env.example /config/scripts/fastweb/.env
   ```

2. Edit `/config/scripts/fastweb/.env`:

   ```
   FW_USER=your-myfastweb-username
   FW_PASS=your-myfastweb-password
   ```

   These are the same credentials you'd type into the MyFastweb site. The parser is strict `KEY=VALUE`: no `export`, no quoting, no spaces around the `=`. It deliberately doesn't use `source` so passwords containing `#`, `;`, quotes or spaces don't get mangled by the shell.

   ```bash
   chmod 600 /config/scripts/fastweb/.env
   ```

3. Add the sensor to your Home Assistant `configuration.yaml`:

   ```yaml
   command_line:
     - sensor:
         name: "Fastweb Power Realtime"
         unique_id: fastweb_power_realtime
         command: "/config/scripts/fastweb/fastweb_power.sh"
         unit_of_measurement: "W"
         device_class: power
         state_class: measurement
         scan_interval: 300
   ```

   That's the `configuration.yaml` in this folder, unchanged. `scan_interval` is in seconds, so **300 is every 5 minutes**, see [Being a good citizen](#being-a-good-citizen) for why.

4. `ha core check`, restart, done. The first poll logs in and writes a cookie jar; everything after that reuses it.

You can sanity-check outside Home Assistant:

```bash
/config/scripts/fastweb/fastweb_power.sh
# 437
```

## Config

Everything's overridable via environment variables if you need it:

| Variable | Default | What it is |
| --- | --- | --- |
| `FW_ENV` | `<script dir>/.env` | Where the credentials live |
| `FW_JAR` | `<script dir>/fastweb_jar.txt` | The persisted cookie jar |

Both resolve relative to the script's own directory, so absolute paths are fine and moving the folder around doesn't break anything. To force a re-login without waiting, delete the jar.

## How the session works

This is the part that took me the longest to get right, so it's written down here.

Fastweb's login is a three-step AJAX dance:

1. GET the login page, pull a 64-hex `securityToken` out of the HTML.
2. POST it, along with the username and password, to the `login/ajax/` endpoint. Success is `"errorCode": 0`.
3. **Then** GET `/accesso/profile/?DirectLink=...`.

Step 3 is not optional. Skip it and the consumption endpoint cheerfully answers `Account non valido`, which is Italian for **"Invalid account"**, even though your cookies are perfectly valid. It seems to be a profile-priming hop the real browser makes on the way into the account area. Took me a while to work out that it wasn't a credential problem.

Once authenticated, the cookie jar lives at `fastweb_jar.txt` next to the script. Each poll:

- checks the jar exists (an empty jar would otherwise let the page redirect to login, which *also* contains a `securityToken`, so the liveness check would pass on a dead session, hence the explicit guard),
- loads the page, extracts a fresh token,
- POSTs `action=consumptionRealtime`,
- reads `.data.realtime`,
- writes the refreshed cookies back.

If the session has died, the script re-logs in and retries once. So a normal steady-state poll performs **no** login at all, which matters because hammering the login endpoint is the fastest way to get flagged.

Exit codes: `0` got a reading, `2` session unusable (triggers one re-login and retry), `1` hard failure like a network error or unparseable response. `curl` and `python3` are checked up front, so a bare container missing either fails loudly instead of leaving you with a mysterious empty sensor.

## Dashboard and energy

Because the sensor declares `device_class: power`, `state_class: measurement` and a unit of `W`, Home Assistant treats it as a real power meter. It works in the built-in Energy dashboard and on any custom one, nothing special to configure.

For a custom dashboard, a history graph shows your usage over a day:

```yaml
type: history-graph
title: Fastweb Power
entities:
  - entity: sensor.fastweb_power_realtime
hours_to_show: 24
```

Or a gauge if you want it glanceable:

```yaml
type: gauge
entity: sensor.fastweb_power_realtime
name: Live power
min: 0
max: 1000
severity:
  green: 0
  yellow: 300
  red: 600
```

Tune the thresholds to your own contract, mine are guesses for a ~1 Gbps FTTH line.

### Monthly kWh

The script only reports instantaneous watts, so there's no cumulative total. You don't need to write one either. Add the sensor under Settings → Dashboards → Energy → Electricity grid → Add grid connection, set as consumption from the grid, and the energy subsystem integrates it for you using the same trapezoidal rule a Riemann sum helper would. It computes the delta across whichever period you're viewing, so daily, weekly, monthly and yearly breakdowns all come from that one sensor. Leave returned to the grid empty unless you genuinely export.

If you want a monotonically increasing kWh sensor for your own dashboards or automations rather than only for the Energy dashboard, that's the Integration helper (Devices & Services → Helpers → Create Helper → Integration, subtitle reads "Riemann sum energy sensor"; searching "Riemann" finds nothing). Trapezoidal rule, Precision 3, leave Max sub-interval at its 60 minute default. Entirely optional.

Accuracy is a direct function of the polling interval. At the 5 minute default, treat the monthly total as an estimate rather than something to reconcile against a bill: any integral samples at discrete points, so across each window you're assuming draw is flat, and real draw isn't. Appliances cycle, the ONT and router load constantly, short peaks get missed entirely. Expect the right ballpark and a few percent off either way, drifting more the longer a gap sits between a failed poll and the re-login.

That's a deliberate trade. If accuracy against your bill matters more to you than the polling footprint, drop `scan_interval` to 60 and the error drops to a fraction of a percent. Just be aware you're making that call, not me.

## Being a good citizen

This hits a customer portal from a residential IP with a session that refreshes on a timer, and none of it is a documented API. To their infrastructure that looks exactly like a scraper. The polite thing is to make it cheap to ignore.

**Which is why polling is 5 minutes, not 1.** There's no functional reason for it, since realtime power draw doesn't meaningfully change in 60 seconds, and pushing lower is the fastest route to being rate-limited or locked out. If you lower it, that's your call, but you're spending someone else's anti-abuse budget on a graph.

The general rule: if it breaks, make it poll *less*. There's no use case here where more frequent polling is worth getting your account locked.

## When it breaks

**Sensor goes unavailable every few hours.** Most likely the session expiring, which the script already handles by re-logging in. Occasional blips are fine. If it flaps constantly, they're rate-limiting you: raise `scan_interval` to 600 or higher first. If you see `session expired or not established` followed by a successful re-login in the logs, that's the script doing its job. Persistent failure means the re-login itself is broken.

**Login fails with an `errorCode` other than `0`.** Read `errorMessage` in the logs. Captcha or "too many attempts" means back off: stop the sensor, wait, then resume at a longer interval. Repeated failed logins are worse than a stale cookie, because that's the pattern which looks like credential stuffing.

**`Account non valido` ("Invalid account") even though login succeeded.** That's the profile hop, not your credentials. If you modified the script, check `do_login` still issues the `/accesso/profile/` request and still saves the jar afterwards. If that's intact and you're still seeing it, delete `fastweb_jar.txt`, run the script by hand once, and see if that clears it.

**`login: securityToken not found in page`.** Fastweb changed the login page, or you're being served a captcha or a "session busy" interstitial. Open the login URL in a browser and see what you actually get.

**`cannot read credentials file`.** Wrong path, or the file isn't there. Remember `.env` is gitignored, so you have to create it yourself on each machine.

**Permissions.** Both `.env` and the jar want `chmod 600` and ownership by whatever user Home Assistant runs as. A permission error here shows up as an unauthenticated request rather than an error message, which is annoying to debug.

**Works by hand but the sensor is unavailable.** Home Assistant kills `command_line` sensors after 60 seconds. The script has 30-second `curl` timeouts and can do a login plus a fetch in the worst case, so it's not hugely comfortable, though with a 5-minute interval you have plenty of headroom. Also check you don't have the script running in a terminal at the same time, since that's two sources hitting the portal at once.

**You got blocked outright.** Back off completely, and if it persists after a few hours Fastweb have probably flagged the account. There's no technical workaround, so asking them nicely is the only move. If their support is any good they'll tell you whether they offer an official API, which would be the correct long-term answer to all of this.

## How this was built

The idea is genuinely mine: I wanted this number on a graph, and my own account was the data source. I worked out the HTTP traffic by hand, browser devtools and Network tab, copying the login POST and following the redirects one at a time until the flow made sense, then rebuilding it in `curl`.

AI helped, and it's worth being specific about where rather than shrugging at it. The useful part was narrowing down the `Account non valido` failure: I'd assumed my session or credentials were wrong and was going in circles, and having it reason about the redirect sequence pointed at the missing `/accesso/profile/` hop, which is the one thing I'd have missed. It also cleaned up bits of the shell, the strict env parser and some awkward quoting, and tidied the retry logic.

Everything else, deciding what to scrape, the session strategy, the polling interval, the actual debugging on a live account, was me. There are no tests behind this, which is the honest limitation of the whole thing.

## Where this goes next

Scraping a portal gives you the number the provider chose to publish, on their schedule, sampled at whatever rate I feel like polling. It's a decent realtime view and a rough monthly estimate, but it isn't measurement.

The plan is to measure the actual thing. The Fastweb Power Control plug is a device on my own network, so there's a version of this that doesn't involve their website at all: find out what the hardware exposes locally over WiFi and report straight from that. Likely a local API or an MQTT topic, possibly undocumented, possibly something Fastweb intended to expose and nobody wrote up yet.

That's the version worth building properly, and the one I'd want as a HACS integration, since it removes the credential handling, the scraping fragility and the polite-polling constraint all at once. Studying the device locally also gives me something closer to ground truth to validate the scraped numbers against, which is the real answer to the accuracy question above.

Current state: one script, one sensor, and a lot of reading to do.

## Caveats

Unofficial, obviously. It scrapes a portal rather than using an API, so it breaks whenever Fastweb feels like it, and there's no guarantee they'd be thrilled about it. Your password sits in plaintext in `.env`. Don't put this folder in a public repo without the `.gitignore`.