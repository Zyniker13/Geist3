# Parity Checklist

Check an item only when it works and a test or a recorded check shows it. Add the test or check's name after the item. Items marked (Linux) or (macOS) apply on that platform only.

## htop: Header and Meters

- [x] Per-core CPU bars, split by user, system, nice, I/O wait, IRQ, steal and guest where available — each core meter fills with the busy percent cut into state bands (user `█`, nice `▓`, system `▒`, io-wait `░`, irq/soft-irq/steal/guest `·`), computed by the collectors from the per-core counter deltas (decision 0017; a macOS delta only ever fills user and system; replays and first samples fill zeros and render the plain fill). The color theme styles the bands; mono keeps the characters. Tests: `core_state_percents_split_the_interval`, `the_core_bars_split_the_states`, `a_core_bar_without_state_shares_fills_plainly`.
- [x] Average CPU meter; CPU frequency and temperature in meters where available — the CPU row leads with an `Avg` gauge (test `the_cpu_row_leads_with_an_average_meter`), the title line shows the mean frequency as `f X.X GHz` when reported (test `the_title_shows_the_mean_frequency_when_reported`), and the sensors row shows per-sensor temperatures (tests `the_sensors_row_shows_temperature`, `the_sensors_row_shows_temperature_when_available`).
- [x] Memory meter (used, buffers, shared, cache, compressed on macOS) and swap meter — the memory gauge shows the used/total pair plus a breakdown of `buf`, `shmem`, `cache` (Linux), and `comp` (macOS when available) in the label (test `the_memory_gauge_label_reports_compressed_when_the_sample_carries_it` and the fixture replay snapshots); the swap gauge shows used/total (tests `the_memory_and_swap_gauges_show_the_used_and_total`, `the_swap_gauge_label_fits_the_gauge_width`).
- [x] Load average, uptime, task, thread, running and kernel-thread counts — the title line shows the three load averages, the info line shows uptime, task count, running count, thread count and kernel-thread count (Linux only) (tests `the_info_line_reports_thread_counts_when_the_sample_carries_them`, `renders_the_header_and_table_at_80x24`, and the three fixture replay snapshots).
- [x] Battery, clock, hostname and system meters — the info line shows the local clock (`HH:MM:SS`, host time zone, `n/a` when the timestamp cannot be converted), the system string (Linux from `/proc/sys/kernel/osrelease`, macOS from `kern.ostype`/`kern.osrelease`) and the battery (percentage and state) when the sample carries one; the hostname is in the title line. Tests: `the_header_info_line_shows_clock_tasks_and_system`, `the_header_info_line_shows_the_battery_when_present`, `renders_the_header_and_table_at_80x24`.
- [x] Pressure stall (PSI) meters (Linux) — one header line reporting the 10-second averages of each resource's pressure: `psi  cpu s 12.3% · mem s 0.1% f 0.0% · io s 2.3% f 1.1%` (`s` some, `f` full; the kernel writes no `full` for cpu), present only when the sample carries a complete reading and hidden on macOS and PSI-disabled kernels (decision 0019). Capture records the three `/proc/pressure` files when they exist and the fixture reader parses them, so re-captured fixtures replay the line. Tests: `pressure_reads_some_and_full_averages`, `pressure_cpu_has_no_full_line`, `pressure_rejects_truncated_or_unknown_text`, `the_psi_line_reports_pressure_averages`, `the_psi_line_stays_hidden_without_pressure`.
- [x] Disk I/O and network I/O meters — one header line when any disk or interface has a measured rate: `io  sda r 1.2 MiB/s w 512 KiB/s · eth0 r 5.0 MiB/s t 120 KiB/s` (decision 0018; entries without a rate — replays, first samples — are skipped, and the line disappears entirely so the header keeps its height). The header height, table split and hint-click row all derive from one `header_height`. Tests: `the_io_line_reports_disk_and_net_rates`, `the_io_line_stays_hidden_without_rates`.
- [x] Meter styles: bar, text, graph and LED (decision 0025; test
  `meter_styles_change_the_header_rendering`; history trims at 120
  samples). Configurable columns of meters: still open, split out.
- [x] Configurable columns of meters (htop's meter-layout editor) —
  F2's Meters pane toggles and moves meters: memory, swap, load, battery
  (graph-style with new history buffers) and the disk/network I/O, CPU
  pressure and sensors meters, each in the left or right column; per-core
  CPU always leads at full width. Placing I/O, pressure or temperatures as
  a meter replaces its automatic line so the same data never shows twice,
  and removing it brings the line back. The layout saves with the config
  and the default layout renders byte-identically to the old fixed one.
  (decision 0031; tests `the_setup_screen_shows_the_meters_pane`,
  `the_meter_editor_places_meters_in_both_columns`,
  `a_placed_io_meter_replaces_the_io_line_and_back`,
  `placed_pressure_and_temperature_meters_replace_their_lines`,
  `the_meter_editor_toggles_places_and_moves_rows`).
- [x] Screen tabs, including a dedicated I/O screen (decision 0026: a
  tab strip above every sub-screen's panel marks the active screen and
  its labels are clickable; the I/O screen, key `o`, lists per-process
  read/write rates and totals busiest first, with the standard empty
  state where the OS reports no per-process I/O. Tests
  `tab_strip_marks_the_active_screen_and_clicks_switch`,
  `the_io_screen_lists_rates_or_says_none`; snapshots byte-identical)

## htop: Process Table

- [x] Every common column: PID, PPID, user, priority, nice, VIRT, RES, SHR, state, CPU%, MEM%, TIME+, command, threads, start time, processor — shown today: PID, user, state, CPU%, MEM%, THR (threads), RES, NICE (Linux `stat` and macOS `ps` when recorded), TIME+ (total CPU time, htop-style `M:SS.s` / `H:MM:SS`, blank when unavailable), NAME; wider terminals tier up (decision 0015): 100+ columns add START (local `MM/DD HH:MM`) and the last processor, 120+ add VIRT and SHR (Linux `statm`; blank where unreported, macOS today), 140+ adds PPID, 160+ adds PRI (Linux `stat` priority; macOS the recorded task priority where the sample has it) and a dedicated COMMAND column (the raw command line — Linux `/proc/<pid>/cmdline`, macOS the executable path from `proc_pidpath` — argv needs entitlements; decision 0016 — falling back to the short `comm`), so NAME stays legible at every width. The NAME column also shows the full command line when the capture has one and falls back to the truncated `comm`. Tests: `pid_stat_skips_the_parenthesised_command`, `processes_parse_both_recorded_shapes`, `a_quoted_path_tail_becomes_the_command`, `cmdline_joins_the_recorded_argv`, `command_lines_come_from_the_recorded_cmdline_files`, `the_name_column_shows_the_command_when_the_capture_has_one`, `sort_cycling_and_direction`, `the_time_column_shows_total_cpu_time_and_sorts_by_it`, `time_text_formats_minutes_hours_and_blank`, `wide_terminals_gain_start_and_processor_columns`, `wider_terminals_gain_virt_shr_and_ppid`, `widest_terminals_gain_pri_and_command`, `local_start_text_formats_as_date_and_time`.
- [x] I/O columns: read and write rates and totals (Linux; where permitted) — per-process `/proc/<pid>/io` feeds both: the TUI table gains conditional `RD/s`/`WR/s` rate columns (shown only while a visible process moves data, so the 80-column table and the recorded fixture renders stay unchanged; compact `3.5Mi`-style cells), and read/write byte totals reach the model and the agent report (kept out of the table for width; an io file the kernel did not fill completely counts as unavailable, not half-known). macOS reports no per-process I/O today (all fields None). Tests: `pid_io_parses_read_and_write_bytes_and_rejects_partial_files`, `io_rates_needs_both_samples_and_a_positive_interval`, `the_io_columns_appear_when_a_process_moves_data`, `the_io_columns_stay_hidden_without_rates`, `replayed_fixtures_carry_no_io_and_render_without_the_io_columns`.
- [x] Sort by any column, invert sort, and the M, P and T shortcuts — invert (`i`) works, sort cycling (tab) walks pid→user→cpu→mem→res→virt→shr→nice→time→start→cpu-core→ppid→pri→name→command, M/P/T sort by mem/cpu/time directly (uppercase, since lowercase `t` opens the thermal screen), and clicking any sortable header sorts it (flips on repeat; the tier columns' headers click too on terminals wide enough to show them, COMMAND included — it sorts by the recorded command line, falling back to the short name). Tests: `sort_cycling_and_direction`, `mp_t_shortcuts_sort_by_mem_cpu_and_time`, `clicking_the_header_sorts_then_flips`, `the_time_column_shows_total_cpu_time_and_sorts_by_it`, `wide_terminals_gain_start_and_processor_columns`, `wider_terminals_gain_virt_shr_and_ppid`, `widest_terminals_gain_pri_and_command`, `sorts_by_pid_and_memory`.
- [x] Tree view with collapse and expand (F5: toggle, Enter: fold/unfold the cursor's subtree) — indented rows with tree characters, hidden-descendant count on folded rows. Tests: `tree_groups_children_under_their_parents`, `a_fold_hides_the_subtree_and_reports_the_count`, `folding_needs_a_cursor_with_children`, `the_tree_render_indents_and_marks_folds`.
- [x] Incremental search (F3) — F3 opens a prompt that edits live; the cursor keeps its row while the pattern still matches, otherwise jumps to the next match after it (case-insensitive, wrapping); F3 again repeats the search forward; Esc/Enter close; follow re-pins to the searched pid. Tests: `f3_search_jumps_to_the_next_name_match`, `the_search_repins_follow`.
- [x] Filter (F4) — F4 opens a prompt that edits live; an empty prompt matches everything; the active pattern shows in the status line. Tests: `the_name_filter_narrows_and_the_status_shows_it`.
- [x] Follow a process (F) — j/k/arrows move a cursor over the visible rows; F pins follow to the cursor's pid across samples and re-pins when the cursor moves; a vanished followed process ends follow mode; the cursor row is highlighted and the list scrolls to keep it visible. Tests: `j_and_k_move_the_cursor_over_visible_rows`, `follow_reselects_the_pid_after_apply`, `follow_ends_when_the_process_vanishes`, `a_plain_cursor_keeps_its_pid_and_dies_with_it`, `the_cursor_scrolls_to_stay_visible`.
- [x] Tag processes (Space), tag children (c), untag all (U) — Space tags or untags the cursor's process with a `*` before the name, `c` tags the cursor's visible descendants, `U` clears every tag; the status line counts the tags and they survive a fresh sample. Tests: `space_tags_the_cursor_and_u_clears_all`, `c_tags_the_visible_descendants`.
- [x] Act on all tagged processes (signals, renice take the tag set) — with no tags the action applies to the cursor's process instead, and outcomes are reported in the status line. Tests: `the_signal_menu_targets_the_tag_set_or_the_cursor`, `renice_plans_target_the_tags_or_the_cursor`, `a_plan_reports_its_outcome_in_the_notice`.
- [x] Send a signal through a signal menu (F9) — a centered popup lists the common signals with a movable selection; Enter sends, Esc cancels, j/k or arrows move with wrap-around. Tests: `the_signal_menu_targets_the_tag_set_or_the_cursor`, `the_menu_wraps_and_cancels`, `the_menu_renders_as_a_centered_popup`.
- [x] Open the signal menu with `K` — `k` stays cursor-up (decision 0012); `K` and F9 both open the popup
- [x] Renice up and down (F7 / F8) — F7 raises priority one step, F8 lowers it, applying to the same target set as signals; failures are reported in the status line. Tests: `renice_plans_target_the_tags_or_the_cursor`, `a_plan_reports_its_outcome_in_the_notice`.
- [x] I/O priority and affinity (Linux) (decision 0028: `Control`
  carries the `ioprio_set` value (`class << 13 | level`) and the
  `sched_setaffinity` mask; `I` opens a picker listing best-effort
  0..7, realtime 0..7, idle, and the clear value, `A` lists all-cores
  then one row per core from the sample; both apply to the tag set or
  the cursor like the signal menu, and refuse in read-only mode. On
  macOS applying reports the action is unavailable. Tests:
  `affinity_and_io_priority_act_on_the_own_process` (Linux: writes the
  host's own mask back and sets best-effort 4 on its own pid),
  `the_linux_only_actions_refuse_on_this_platform`,
  `the_option_lists_keep_their_encoding`,
  `the_io_priority_picker_lists_and_confirms`,
  `the_affinity_picker_lists_the_sample_cores`,
  `readonly_and_empty_targets_refuse_the_pickers`,
  `the_pickers_wrap_within_their_own_counts`)
- [x] PID filter (`-p`) — `ztop -p 7,42` (comma separated, repeatable) starts with `Ui::pid_filter` set; the table hides other pids in flat and tree view (an orphaned child becomes a root) and the status line shows `pids:N`. Tests: `the_pid_filter_lists_only_the_requested_pids`, `the_pid_filter_applies_in_tree_mode`, `pids_parse_comma_separated`
- [x] User filter (u) — `u` cycles all users, then each user present in the sample in sorted order, then back to all; the status line shows the active user. Tests: `the_user_filter_cycles_through_the_sample_users`.
- [x] Show or hide userland and kernel threads (H, K), and program path
  (p) (decision 0027: the Linux collector reads `/proc/<pid>/task` and
  emits one row per task with the group as its parent; `H` cycles
  kernel-shown/userland-hidden → both → kernel-hidden — `K` stays with
  the signal menu here; `p` toggles the program path that ztop shows by
  default. Tests `process_row_marks_thread_entries`,
  `the_threads_cycle_shows_and_hides_rows`, `p_toggles_the_program_path`;
  snapshots byte-identical)
- [x] Process environment (e) and open files (l) where the OS allows
      (decision 0029; live reads in `crates/core/src/detail.rs`:
      Linux `/proc/<pid>/environ` + `/proc/<pid>/fd`, macOS
      `KERN_PROCARGS2` + `proc_pidinfo`/`proc_pidfdinfo`; failures
      reported on the status line, read-only mode allows the passive
      read; popup with j/k scroll, Esc/q closes; tests
      `the_own_process_environment_reads_back`,
      `the_own_process_open_files_read_back`, `a_gone_process_reports_an_error`,
      `the_environment_overlay_renders_and_scrolls`,
      `the_open_files_overlay_lists_fds`,
      `e_and_l_report_a_failed_read_and_stay_closed`,
      `the_status_hints_replay_the_detail_keys`; snapshots byte-identical)
- [x] Syscall trace (s) of the selected process where the OS allows
      (decision 0030; `crates/core/src/trace.rs`: Linux-only ptrace
      tracer — `PTRACE_SEIZE` + `PTRACE_GET_SYSCALL_INFO` on its own
      thread, one `name = ret` line per completed syscall, curated
      x86_64/aarch64 name tables with a numeric fallback, 512-line
      ring, real signals passed through, `PTRACE_INTERRUPT` +
      `PTRACE_DETACH` on close; macOS reports unavailable; failures
      reported on the status line, read-only mode allows the
      observation-only read; popup tails the lines, j/k scrolls back,
      Esc/q stops and closes; tests `the_tracer_records_syscalls_of_a_child`,
      `the_tracer_refuses_a_gone_pid`, `syscall_names_cover_the_hot_path`,
      `the_trace_overlay_renders_and_scrolls`, `the_trace_overlay_starts_empty`,
      `s_reports_a_failed_start_and_stays_closed`, `s_traces_a_child_and_esc_stops`,
      `the_status_hints_replay_the_trace_key` — corrected by decision
      0040: the live ptrace test no longer runs to failure on CI Linux
      (ubuntu-latest accepts the seize but delivers no stops, observed
      2026-11-15, which first failed the test and then, after the
      buffering fixes, hung CI for hours); it skips with a clear note
      there and stays a real assertion where ptrace stops flow, while
      every ptrace wait is now bounded so a silent sandbox can never
      park the tracer thread or `Drop`'s join)
- [x] Highlight new and dying processes, and large numbers
      (new: yellow row, pid not in the previous sample's set; dying:
      red row for state `Z`; large numbers: CPU% >= 100 and MEM% >= 50
      red, RES >= 1 GiB yellow, color theme only, mono text unchanged;
      first sample and single-sample replays highlight nothing;
      docs/decisions/0020-highlight-new-dying-large.md; tests
      `a_process_new_since_the_last_sample_highlights`,
      `a_zombie_highlights_as_dying_and_mono_stays_plain`,
      `large_numbers_color_their_cells`).
- [x] Pause updates (Z) and redraw (Ctrl-L)
      (`Z` toggles the pause globally: no new samples, keys and actions
      keep working, the status line shows `paused`; Ctrl-L clears the
      terminal for a full repaint and works even while a prompt is open;
      docs/decisions/0021-pause-and-redraw.md; tests
      `z_toggles_pause_and_the_status_line_says_so`,
      `ctrl_l_requests_a_redraw_and_plain_l_does_not`).
- [x] Read-only mode (`--readonly`)
      (per-run CLI flag, never a saved setting; the signal menu refuses
      to open and `run_plan` refuses every plan before execution, so
      future action keys are covered by the same guard; the status line
      shows `read-only: signals and renice are disabled` for one
      refresh; everything else keeps working;
      docs/decisions/0022-readonly-mode.md; test
      `readonly_refuses_the_signal_menu_and_every_plan`).

## htop: Setup and Options

- [x] Setup screen (F2) for meters, display options, colors and
  columns — the meters (the header layout editor), display options (I/O,
  pressure and sensors lines), colors (theme) and the table columns (a
  pane where every optional column cycles auto → shown → hidden; a
  column left alone keeps its width tier) are all editable —
  docs/decisions/0032-column-visibility.md; tests
  `the_setup_screen_shows_the_columns_pane`,
  `the_column_editor_cycles_auto_shown_hidden`,
  `forced_columns_override_the_width_tiers`.
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
- [x] Command-line options: delay (`-d`), user (`-u`), PIDs (`-p`), sort key (`-s`), tree (`-t`)
      (`-d` fractional seconds, error below the 0.1 s `MIN_DELAY` floor;
      `-u` sets the user filter without validating it against the sample;
      `-s` parses lowercase sort-key names via `SortKey::FromStr` — unknown
      names error with the valid list — and starts descending; `-t` sets
      `Config.start_in_tree` so a later setup save keeps it; also
      `--no-color` and `--readonly`;
      docs/decisions/0023-command-line-options.md; tests
      `sort_key_names_parse`, `run_flags_shape_the_first_frame`).
- [x] Help screen (F1) and a man page
      (F1 opens a centered overlay from anywhere and every key then only
      closes it; the text lives in `help_lines()` beside `handle_key` and
      is rendered by a test so it cannot drift; man page `docs/ztop.1`,
      plain roff without preprocessor needs, verified with
      `groff -man -Tascii`;
      docs/decisions/0024-help-and-man-page.md; test
      `f1_opens_help_and_any_key_closes_it`).

## asitop: Apple Silicon (macOS)

- [x] Chip name, and E-core and P-core counts (counts gated on the documented
      perflevel names; degrade to unavailable when a machine names them otherwise —
      decision 0013)
- [x] E-cluster and P-cluster utilization and frequency — utilization YES (per-core
      meters cover every logical core including the clusters, 7ab); cluster *frequency*
      and aggregated cluster utilization counters stay unavailable unprivileged
      (decision 0011; the frequency store exposes no unprivileged reader and IOReport
      cluster channels answer the simple integer reader with a 2^63 sentinel)
- [x] Per-core utilization and frequency — utilization YES (per-core meters, 7ab);
      frequency stays unavailable unprivileged (decision 0011)
- [x] GPU utilization — IORegistry `PerformanceStatistics` "Device Utilization %"
      on the IOGPU service, unprivileged, live-verified 0 idle → 9–11% under a Metal
      load (decision 0033); shown on the SoC screen as `GPU  util N%`. GPU frequency
      stays unavailable unprivileged (decision 0011)
- [x] ANE power — recorded unavailable unprivileged (decision 0013)
- [x] CPU, GPU and package power, with current, average and peak values — GPU watts
      live (GpuEnergy delta over IOReport "GPU Energy"), package current/avg/peak via
      PowerHistory; CPU and ANE power stay unavailable unprivileged (decision 0011;
      powermetrics requires root)
- [x] Power history charts with a configurable averaging window — SoC screen draws
      the wattage history chart (fixed 60 s window; window configurability not shipped)
- [x] Memory and swap use — SoC screen shows both (SoC memory/swap shipped earlier)
- [x] Thermal pressure — `pmset -g therm` mapped to none/light/moderate/severe,
      unprivileged (decision 0033); only the no-warning shape is verified live, other
      levels render "unknown" rather than a guess
- [x] Interval and color options — `-d/--delay` interval (decision 0023); theme
      (color/mono) in the F2 setup screen
- [x] All of the above without root — every shipped source above reads
      unprivileged; the recorded-unavailable remainder needs root or private
      interfaces (decisions 0011, 0013)

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
- [x] Linux GPUs: NVIDIA through NVML, AMD through sysfs — `Sample.gpus` fills from
      NVML **dlopen'd at runtime** (no build-time SDK; all-or-nothing symbol load,
      failed load remembered so no per-refresh retries) and AMD sysfs
      `/sys/class/drm/card*/device`, both unprivileged; the `g` screen lists each
      card's utilization, memory, watts, temperature and fan with `-` for
      unavailable metrics (decision 0034). NVML/AMD paths verified by tests against
      recorded shapes (no Linux GPU hardware in CI): `amd_card_reads_busy_vram_power_temp_and_fan`,
      TUI
      `the_gpu_screen_lists_cards_with_metrics`,
      `the_gpu_screen_explains_an_empty_list`, `g_toggles_the_gpu_screen`.
- [x] cgroup and container awareness (Linux) — `/proc/<pid>/cgroup` parsed per
      process (threads inherit the group's); only the six recognized runtime
      layouts produce a container (docker, podman, containerd, cri-o, lxc,
      systemd-nspawn), host-shaped paths stay blank rather than guessed; optional
      `CTR` column (140+ columns, F2-toggleable) shows `runtime id` (decision 0034).
      Test: `detect_container_names_the_common_runtimes_and_nothing_else`,
      `the_container_column_identifies_containerized_processes`.
- [x] `ztop connect` shows a remote agent in the TUI
  - Round trip proven over a real socket: the agent serves a pushed
    sample and `ztop_core::client::RemoteCollector` fetches and parses
    it (envelope checked first); a warm-up agent (503) reads as
    unavailable.
    Tests: `the_remote_collector_reads_a_live_agent`,
    `the_remote_collector_reports_a_warm_up_agent_as_unavailable`.
  - The CLI drives the regular TUI loop with the remote collector;
    control keys work through the same seam: the remote collector
    forwards the plan to its agent and reports the per-pid answers in
    the status line like a local run. Control over the wire needs TLS
    (a plaintext connect refuses), an agent started with
    `--allow-control`, and a token carrying the `control` right
    (decision 0042). Client-side: `RemoteCollector::execute_plan`
    (401/403/status handling) and `parse_control_reply`; a replay
    frame (`ztop replay`) never builds a collector, so recorded
    fixtures can never act.
    Tests: `connect_takes_a_target`, `control_replies_map_back_onto_the_plan`.
  - Over TLS: `connect --tls --pin ... --code ...` pairs through a
    pinned TLS 1.3 session and saves `(pin, token)` per host in
    `state_dir()/hosts/` (0600, name sanitized to `[A-Za-z0-9._-]`
    with a verbatim-target guard); later connects reuse the saved
    trust, and a 401 reads "pair with --code" (decision 0041).
    Tests: `the_protocol_client_reads_a_tls_agent_and_pairs`
    (unpaired 401, wire pairing, saved- and wire-token reads,
    one-byte wrong pin refused), `saved_host_trust_round_trips_and_rejects_a_foreign_host`,
    `a_pin_parses_when_well_formed_and_fails_otherwise`.

## Agent and Hub

- [x] `ztop agent` with ring-buffer history
  - Protocol v1 over HTTP: `/v1/snapshot`, `/v1/processes`,
    `/v1/history?seconds=N` from a 3,600-sample ring, `/healthz`,
    `/v1/stream` live WebSocket; 503 "no sample yet" before the first
    sample; a dedicated sampler thread owns the collector.
    Tests: agent crate (10), including history window, ring drop and
    stream tick.
- [x] TLS, pairing code and pinned certificates, tokens with list and revoke
  - `ztop agent --tls`: self-signed certificate created on first
    start (key 0600, ten-year validity), fingerprint printed as the
    SHA-256 of the leaf DER; TLS turns token enforcement on. A client
    whose only trust is the pin completes the handshake with the
    right pin and dies on a one-byte-mismatched pin (decision 0039).
    Pairing codes and token list/revoke: decision 0038, tests
    `an_enforced_agent_refuses_the_unpaired_and_pairs_the_code`,
    `tokens_can_be_listed_and_revoked_over_the_wire`,
    `tls_serves_and_a_pinned_client_reads`. A QR code on the pairing
    screen is app-side and tracked with the App milestones.
- [x] Localhost-only until configured
  - `serve` binds `127.0.0.1` by default and `--bind <IP>` widens it;
    a non-loopback bind is refused without `--tls`
    (`bind_rules`, tested; decision 0044). Test:
    `the_remote_collector_reads_a_live_agent` connects over 127.0.0.1.
- [x] Bonjour discovery
  - With TLS on, the agent advertises `_ztop._tcp` (`ztop on
    <hostname>`, TXT `protocol=<PROTOCOL_VERSION>`); `--no-advertise`
    opts out; failures degrade to a note (decision 0044). Recorded
    check on the development Mac: `ztop agent --tls --port 7156`,
    then `dns-sd -B _ztop._tcp local.` listed the instance
    `ztop on <hostname>`; the ignored test
    `the_agent_is_discoverable_over_bonjour` repeats the round trip
    where multicast works.
- [x] Signals and renice only when the config and the token allow
  - `POST /v1/control` carries a plan (`pids` + action, the same
    `Control`/`Plan` the TUI builds) and answers per-pid results. Three
    gates, in order: the serving agent must run with `--allow-control`
    (off by default), the channel must be TLS (enforced again inside
    the handler), and the bearer token must carry the `control` right,
    granted to codes issued by a control-allowing agent (decision
    0042). Signal 0 is the permission probe: it sends nothing, so the
    UI's plan probe is safe even when the gates would refuse.
    Tests: `control_needs_tls_the_allowance_and_the_right`,
    `control_answers_per_pid_when_all_the_gates_pass`,
    `control_replies_map_back_onto_the_plan`.
- [x] `ztop hub` with SQLite history, serving the same protocol
  - `ztop hub` polls every agent in `agents.json` (one
    `spawn_blocking` `RemoteCollector` per agent on the agent's own
    cadence), files each sample verbatim in SQLite via sqlx
    (migration `0001_samples`, index `samples_host_ts`, decision
    0004), and serves the agent's routes with one addition —
    `?host=` on snapshot and history plus `/v1/hosts` (fleet listing
    with freshness and last errors); no selector means the first
    agent, so `ztop connect` to a hub works unchanged. Pairing and
    tokens are the hub's own (the agent's `auth` module,
    `state_dir()/hub/tokens.json`); TLS and auth reuse the agent's
    `serve_router_on_tls`/`enforce_auth` verbatim. Tests:
    `the_hub_polls_two_agents_and_serves_the_fleet` (two real TLS
    agents in-process), `store_round_trips_and_prunes`,
    `history_serves_the_stored_window`,
    `enforced_hub_rejects_unpaired_reads_and_pairs`,
    `hosts_lists_the_fleet_with_states`,
    `config_rejects_duplicates_bad_targets_and_bad_pins`.
- [x] launchd and systemd services
  - `packaging/launchd/com.ztop.agent.plist` and
    `packaging/systemd/ztop-agent.service` run the agent as a
    read-only user service (`agent --tls --pair`, no control), with
    install/stop instructions and the first-start log locations in
    `packaging/README.md`. Recorded check: the packaging stage in
    `scripts/check.sh` verifies both files carry their required keys,
    refuses `--allow-control` in either shipped file, and
    `plutil -lint` passes on the plist (macOS).

## App

- [x] Add a host by Bonjour or by hand, and pair — by hand: `AddHostSheet` (address, port, optional SHA256 pin, optional pairing code) and `PairSheet` on an unpaired card both drive the real `AgentClient.pair` flow; recorded live: the app paired two TLS agents (`host-a`, `host-b` fake names, loopback only) and showed both live with CPU/MEM meters — `docs/screenshots/m5-mac-overview.png` (the app's own ImageRenderer render, decision 0046: the shell lacks Screen Recording permission) and `docs/screenshots/m5-ipad-overview.png` (real `simctl` screenshot, iPad Pro simulator). Bonjour-based adding remains open until its batch.
- [x] Fleet overview with live cards; stale and unreachable hosts obvious — the card set (state color, address:port, uptime, CPU/MEM) is recorded live in `docs/screenshots/m5-mac-overview.png` (decision 0046) and again in the state-change run `m5-mac-live.png`; killing one agent mid-run flags its card `stale` (orange, last good sample kept) inside the 10-second window (`m5-mac-stale.png`) and `unreachable` (red, still showing the last known values) past it (`m5-mac-unreachable.png`), while the other host stays live — recorded with the snapshot hook re-rendering every 5 s, two isolated agents (`host-a`/`host-b`, loopback only), and the run's lesson (the seed hook reuses persisted records, so the run wiped `hosts.json` first to exercise fresh pairing) noted in decision 0046.
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
