# Recorded power checks (macOS, Apple Silicon)

This records what the macOS collector measures, how each value was verified
without root, and what could not be verified. The no-root policy (decision
0009) means every metric `ztop` reports must work without `sudo`; data that
needs more is marked unavailable, never faked.

`powermetrics` itself requires root (it exits 5 when run unprivileged), so a
direct side-by-side against it was **not** run: an unprivileged comparison
would be fake, and running it with sudo is out of scope for the automated
build. The checks below use probe programs written against the same
interfaces the collector uses, run twice on the development host, plus
behavioral cross-checks.

## What the collector reads

| Metric | Source | Verified by |
| --- | --- | --- |
| GPU watts | IOReport `Energy Model` group, `GPU Energy` channel: delta of a cumulative nanjoule counter between two cooked samples | Probe under a Metal burner: delta ≈ 34.77e9 nJ over a 4 s window ≈ 8.7 W; idle 0.3–2.7 W in repeated peeks |
| System watts | AppleSMC key `PSTR` (`flt`, 4 bytes) | Probe reads 5.72–6.24 W idle, 17 W while the machine compiles; rises under load |
| Temperatures | AppleSMC keys (`TCMb` CPU composite, `Te07`–`Te0i` CPU dies, `Tg01` GPU, `Ta0P` ambient) | Probe values 28–49 °C idle on the same host the fixtures were recorded on; die readings cluster within ~1 °C of each other |
| Fan speeds | AppleSMC keys `F0Ac` (current), `F0Mx` (maximum) | Probe reads 1000–1001 RPM idle current, 4900–4906 RPM maximum across three independent probes |
| CPU energy | — | **Unavailable**: enumerating all 8,709 IOReport channels finds only 6 energy-unit channels (GPU + 5 PCIe); none is CPU |
| CPU frequency | — | **Unavailable**: no unprivileged sysctl or IOReport channel exposes live per-core MHz on this host |

## The live-peek check (what CI's live test pins)

`crates/core/tests/macos_live.rs` runs two real samples on the test machine.
It first asks IOKit directly whether an Apple SMC device exists — a check
independent of collector code, so a collector regression cannot hide behind
an absent device. When the device exists, the test requires non-empty
temperature and fan lists and in-range values (0–150 °C, 0–20000 rpm, system
power 0–500 W); when it does not (a VM), it requires empty lists and
unavailable power, so nothing is ever faked.

## Known limits

- The exact watt numbers above were recorded on one Apple Silicon desktop
  host; other machines report their own values. Tests pin ranges, never
  the recorded numbers.
- `PSTR` semantics (whole-system draw, as reported by the SMC) were
  confirmed only behaviorally: it rises under load. A root-run
  `powermetrics` comparison would confirm it exactly and needs a human
  with the password.
- Fan maximums differ slightly between probes (4900 vs 4906 RPM), which is
  the SMC reporting the same key at different moments.
