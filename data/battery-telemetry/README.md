# Battery telemetry logger

The raw telemetry behind the review's battery numbers is **not** published:
two months of timestamped power draw is also a map of the owner's days, and
that stays private. What is here is the instrument, so anyone can reproduce
the dataset on their own unit:

- `battery-calib-log` — a ~15-line shell sampler: once a minute it appends
  `iso_time,uptime_s,capacity_pct,energy_wh,power_w,voltage_v,status,ttoe_min`
  for BAT0 to `/var/log/battery-calibration.csv`, with a `sync` after each
  line so the final samples survive a hard power cut (on this machine, a
  real concern — see the review).
- `battery-telemetry.service` — its systemd unit (`Nice=19`, auto-restart).

Install: script to `/usr/local/bin/`, unit to `/etc/systemd/system/`, then
`systemctl enable --now battery-telemetry`.

The aggregates the review quotes from the private dataset: median
on-battery draw ~11.7 W (p25 8.1 W, p5 4.4 W), ~3.1 h real mixed-use
runtime, best fully-recorded discharge ≥ 28 Wh vs the 36.48 Wh label,
charging ~60 %/h, and EC hard-cutoffs observed at 9.1 V / "20 %" (heavy
load) vs 10.38 V / "2 %" (light load). Gauge caveats apply: `energy_now` is
exactly capacity-percent × design capacity, wear tracking does not exist,
and only terminal voltage is a trustworthy low-battery signal.
