# Parity Checklist

Check an item only when it works and a test or a recorded check shows it. Add the test or check's name after the item. Items marked (Linux) or (macOS) apply on that platform only.

## htop: Header and Meters

- [ ] Per-core CPU bars, split by user, system, nice, I/O wait, IRQ, steal and guest where available
- [x] Average CPU meter; CPU frequency and temperature in meters where available — the CPU row leads with an `Avg` gauge (test `the_cpu_row_leads_with_an_average_meter`), the title line shows the mean frequency as `f X.X GHz` when reported (test `the_title_shows_the_mean_frequency_when_reported`), and the sensors row shows per-sensor temperatures (tests `the_sensors_row_shows_temperature`, `the_sensors_row_shows_temperature_when_available`).
- [x] Memory meter (used, buffers, shared, cache, compressed on macOS) and swap meter — the memory gauge shows the used/total pair plus a breakdown of `buf`, `shmem`, `cache` (Linux), and `comp` (macOS when available) in the label (test `the_memory_gauge_label_reports_compressed_when_the_sample_carries_it` and the fixture replay snapshots); the swap gauge shows used/total (tests `the_memory_and_swap_gauges_show_the_used_and_total`, `the_swap_gauge_label_fits_the_gauge_width`).
- [x] Load average, uptime, task, thread, running and kernel-thread counts — the title line shows the three load averages, the info line shows uptime, task count, running count, thread count and kernel-thread count (Linux only) (tests `the_info_line_reports_thread_counts_when_the_sample_carries_them`, `renders_the_header_and_table_at_80x24`, and the three fixture replay snapshots).
- [x] Battery, clock, hostname and system meters — the info line shows the local clock (`HH:MM:SS`, host time zone, `n/a` when the timestamp cannot be converted), the system string (Linux from `/proc/sys/kernel/osrelease`, macOS from `kern.ostype`/`kern.osrelease`) and the battery (percentage and state) when the sample carries one; the hostname is in the title line. Tests: `the_header_info_line_shows_clock_tasks_and_system`, `the_header_info_line_shows_the_battery_when_present`, `renders_the_header_and_table_at_80x24`.
- [ ] Pressure stall (PSI) meters (Linux); disk I/O and network I/O meters
- [ ] Meter styles: bar, text, graph and LED; configurable columns of meters
- [ ] Screen tabs, including a dedicated I/O screen

## htop: Process Table

- [ ] Every common column: PID, PPID, user, priority, nice, VIRT, RES, SHR, state, CPU%, MEM%, TIME+, command, threads, start time, processor — shown today: PID, user, state, CPU%, MEM%, THR (threads), RES, NICE (Linux `stat` and macOS `ps` when recorded), TIME+ (total CPU time, htop-style `M:SS.s` / `H:MM:SS`, blank when unavailable), NAME; wide terminals (100+ columns) additionally show START (local `MM/DD HH:MM`) and the last processor, keeping names legible at 80 columns. The model also carries priority and shared bytes (Linux `statm`), collected but not yet shown as columns. Tests: `pid_stat_skips_the_parenthesised_command`, `processes_parse_both_recorded_shapes`, `sort_cycling_and_direction`, `the_time_column_shows_total_cpu_time_and_sorts_by_it`, `time_text_formats_minutes_hours_and_blank`, `wide_terminals_gain_start_and_processor_columns`, `local_start_text_formats_as_date_and_time`.
- [x] I/O columns: read and write rates and totals (Linux; where permitted) — per-process `/proc/<pid>/io` feeds both: the TUI table gains conditional `RD/s`/`WR/s` rate columns (shown only while a visible process moves data, so the 80-column table and the recorded fixture renders stay unchanged; compact `3.5Mi`-style cells), and read/write byte totals reach the model and the agent report (kept out of the table for width; an io file the kernel did not fill completely counts as unavailable, not half-known). macOS reports no per-process I/O today (all fields None). Tests: `pid_io_parses_read_and_write_bytes_and_rejects_partial_files`, `io_rates_needs_both_samples_and_a_positive_interval`, `the_io_columns_appear_when_a_process_moves_data`, `the_io_columns_stay_hidden_without_rates`, `replayed_fixtures_carry_no_io_and_render_without_the_io_columns`.
- [ ] Sort by any column, invert sort, and the M, P and T shortcuts — invert (`i`) works, sort cycling (tab) walks pid→user→cpu→mem→res→nice→time→start→cpu-core→name, M/P/T sort by mem/cpu/time directly (uppercase, since lowercase `t` opens the thermal screen), and clicking any sortable header sorts it (flips on repeat; START and the processor header click too on wide terminals). Not yet: sorting from every column that will exist (VIRT, SHR, PPID, command are not columns yet). Tests: `sort_cycling_and_direction`, `mp_t_shortcuts_sort_by_mem_cpu_and_time`, `clicking_the_header_sorts_then_flips`, `the_time_column_shows_total_cpu_time_and_sorts_by_it`, `wide_terminals_gain_start_and_processor_columns`, `sorts_by_pid_and_memory`.
- [x] Tree view with collapse and expand (F5: toggle, Enter: fold/unfold the cursor's subtree) — indented rows with tree characters, hidden-descendant count on folded rows. Tests: `tree_groups_children_under_their_parents`, `a_fold_hides_the_subtree_and_reports_the_count`, `folding_needs_a_cursor_with_children`, `the_tree_render_indents_and_marks_folds`.
- [x] Incremental search (F3) — F3 opens a prompt that edits live; the cursor keeps its row while the pattern still matches, otherwise jumps to the next match after it (case-insensitive, wrapping); F3 again repeats the search forward; Esc/Enter close; follow re-pins to the searched pid. Tests: `f3_search_jumps_to_the_next_name_match`, `the_search_repins_follow`.
- [x] Filter (F4) — F4 opens a prompt that edits live; an empty prompt matches everything; the active pattern shows in the status line. Tests: `the_name_filter_narrows_and_the_status_shows_it`.
- [x] Follow a process (F) — j/k/arrows move a cursor over the visible rows; F pins follow to the cursor's pid across samples and re-pins when the cursor moves; a vanished followed process ends follow mode; the cursor row is highlighted and the list scrolls to keep it visible. Tests: `j_and_k_move_the_cursor_over_visible_rows`, `follow_reselects_the_pid_after_apply`, `follow_ends_when_the_process_vanishes`, `a_plain_cursor_keeps_its_pid_and_dies_with_it`, `the_cursor_scrolls_to_stay_visible`.
- [x] Tag processes (Space), tag children (c), untag all (U) — Space tags or untags the cursor's process with a `*` before the name, `c` tags the cursor's visible descendants, `U` clears every tag; the status line counts the tags and they survive a fresh sample. Tests: `space_tags_the_cursor_and_u_clears_all`, `c_tags_the_visible_descendants`.
- [x] Act on all tagged processes (signals, renice take the tag set) — with no tags the action applies to the cursor's process instead, and outcomes are reported in the status line. Tests: `the_signal_menu_targets_the_tag_set_or_the_cursor`, `renice_plans_target_the_tags_or_the_cursor`, `a_plan_reports_its_outcome_in_the_notice`.
- [x] Send a signal through a signal menu (F9) — a centered popup lists the common signals with a movable selection; Enter sends, Esc cancels, j/k or arrows move with wrap-around. Tests: `the_signal_menu_targets_the_tag_set_or_the_cursor`, `the_menu_wraps_and_cancels`, `the_menu_renders_as_a_centered_popup`.
- [x] Open the signal menu with `K` — `k` stays cursor-up (decision 0012); `K` and F9 both open the popup
- [x] Renice up and down (F7 / F8) — F7 raises priority one step, F8 lowers it, applying to the same target set as signals; failures are reported in the status line. Tests: `renice_plans_target_the_tags_or_the_cursor`, `a_plan_reports_its_outcome_in_the_notice`.
- [ ] I/O priority (i, Linux) and CPU affinity (a, Linux)
- [x] PID filter (`-p`) — `ztop -p 7,42` (comma separated, repeatable) starts with `Ui::pid_filter` set; the table hides other pids in flat and tree view (an orphaned child becomes a root) and the status line shows `pids:N`. Tests: `the_pid_filter_lists_only_the_requested_pids`, `the_pid_filter_applies_in_tree_mode`, `pids_parse_comma_separated`
- [x] User filter (u) — `u` cycles all users, then each user present in the sample in sorted order, then back to all; the status line shows the active user. Tests: `the_user_filter_cycles_through_the_sample_users`.
- [ ] Show or hide userland and kernel threads (H, K), and program path (p)
- [ ] Process environment (e), open files (l) and syscall trace (s) where the OS allows
- [ ] Highlight new and dying processes, and large numbers
- [ ] Pause updates (Z) and redraw (Ctrl-L)
- [ ] Read-only mode (`--readonly`)

## htop: Setup and Options

- [ ] Setup screen (F2) for meters, display options, colors and columns
- [x] Config file saved and reloaded — F2 saves JSON to the user's config directory (Application Support on macOS, XDG elsewhere) when the setup screen closes; `ztop` loads it at startup and a missing or malformed file means defaults, with unknown fields from a future version tolerated. Tests: `config::tests::config_roundtrips_through_a_file`, `a_missing_config_file_means_defaults`, `a_malformed_config_file_means_defaults`, `unknown_fields_and_missing_fields_are_tolerated`, `tests::open_setup_remembers_where_it_returned`.
- [x] Color schemes, including monochrome; `--no-color` — `Theme::Color` (default) and `Theme::Mono` picked on the setup screen; the theme colors the CPU/memory/swap gauges and dims the status line, and `--no-color` forces mono for one run without saving the override. Tests: `tests::gauge_style_follows_the_theme`, `tests::the_setup_screen_shows_its_options_and_help`, `ztop: no_color_flag_parses`.
- [x] Mouse support: click to select, sort and use the function bar — left-click
      selects a row, a header click sorts (clicking the sorted column again flips
      direction), the wheel walks the selection, and a function-bar click replays the
      key its label names through the same `handle_key` the keyboard uses
      (`status_parts`/`status_hint_at`/`hint_key` share one string between the draw
      path and the click map; clicks do nothing while a prompt is open). Tests:
      `clicking_a_row_selects_it`, `clicking_the_header_sorts_then_flips`,
      `clicking_a_function_bar_hint_replays_the_key`, `clicking_quit_replays_the_quit_key`,
      `clicking_the_disks_hint_replays_d`, `clicks_are_ignored_while_a_prompt_is_open`.
- [ ] Command-line options: delay (`-d`), user (`-u`), PIDs (`-p`), sort key (`-s`), tree (`-t`)
- [ ] Help screen (F1) and a man page

## asitop: Apple Silicon (macOS)

- [x] Chip name, and E-core and P-core counts (counts gated on the documented
      perflevel names; degrade to unavailable when a machine names them otherwise —
      decision 0013)
- [ ] E-cluster and P-cluster utilization and frequency
- [ ] Per-core utilization and frequency
- [ ] GPU utilization and frequency
- [ ] ANE power
- [ ] CPU, GPU and package power, with current, average and peak values
- [ ] Power history charts with a configurable averaging window
- [ ] Memory and swap use
- [ ] Thermal pressure
- [ ] Interval and color options
- [ ] All of the above without root

## Beyond Both

- [x] Per-disk usage, and disk I/O panels — the `d` screen lists each disk with its
      mount, used/total bytes and usage percent plus lifetime read/write counters,
      with read/write rates where a live collector measured a delta (a first sample or
      a fixture shows `-`); Linux parses `/proc/diskstats` with mount points from
      `/proc/mounts` and usage from statvfs; macOS reports no disks today and shows
      the honest empty state (decision 0009). Tests:
      `the_disk_panel_shows_usage_counters_and_rates`,
      `panels_without_data_say_so_instead_of_fake_zeros`,
      `panels_without_a_sample_wait_for_data`, `counter_rate_needs_previous_and_positive_interval`.
- [x] Network interfaces with rates and totals — the `n` screen lists each interface
      with rx/tx byte totals and rates plus packet counters; rates come from
      `counter_rate` deltas between live samples (`/proc/net/dev` on Linux; macOS
      reports no interfaces today). Tests:
      `the_network_panel_shows_interfaces_and_rates`.
- [x] Temperatures and fans — TUI header row: temps (up to 3), fans (up to 1), system/GPU watts. Snapshot test at 80x24 (5-row header), plus fixture replay at 80x24 (4-row header when no sensors).
- [ ] Linux GPUs: NVIDIA through NVML, AMD through sysfs
- [ ] cgroup and container awareness (Linux)
- [ ] `ztop connect` shows a remote agent in the TUI

## Agent and Hub

- [ ] `ztop agent` with ring-buffer history
- [ ] TLS, pairing code and QR, pinned certificates, tokens with list and revoke
- [ ] Localhost-only until configured
- [ ] Bonjour discovery
- [ ] Signals and renice only when the config and the token allow
- [ ] `ztop hub` with SQLite history, serving the same protocol
- [ ] launchd and systemd services

## App

- [ ] Add a host by Bonjour or by hand, and pair
- [ ] Fleet overview with live cards; stale and unreachable hosts obvious
- [ ] Host detail with charts for every metric
- [ ] Apple Silicon view for Macs
- [ ] Process list: search, sort and, where allowed, signals
- [ ] Disks, network, temperatures and fans
- [ ] Alerts with thresholds and local notifications
- [ ] Mac app installs and runs the hub as a login item; iPad works through the hub
- [ ] iPad split view and Stage Manager sizes; Mac window sizes
- [ ] VoiceOver, Dynamic Type and contrast pass

## Packaging

- [ ] Homebrew formula with a `brew services` agent
- [ ] `.deb` for amd64 and arm64 with a systemd unit and a dedicated user
- [ ] Install, upgrade and uninstall tested in CI on both
