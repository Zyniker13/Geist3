// SPDX-License-Identifier: MIT OR Apache-2.0
//! The ztop terminal user interface.
//!
//! The render path is separated from terminal state: [`draw`] is a pure
//! function of the [`Ui`] state, which is what makes snapshot tests at
//! 80x24 and at large sizes possible without a pty. [`run`] owns the
//! terminal and a [`Collector`], sampling once per refresh tick and
//! redrawing.

use std::io::{self, Stdout};
use std::time::Duration;

use ratatui::Frame;
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::crossterm::execute;
use ratatui::crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ratatui::layout::{Constraint, Layout};
use ratatui::style::Stylize;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, Gauge, Paragraph, Row, Table};

use ztop_core::collector::{CollectError, Collector};
use ztop_core::model::{Memory, Metric, Process, Sample, Unit};

/// How often the event loop samples and redraws when no key is pressed.
const REFRESH: Duration = Duration::from_secs(1);

const KIB: f64 = 1024.0;
const MIB: f64 = KIB * 1024.0;
const GIB: f64 = MIB * 1024.0;

/// Which process column the table is sorted by.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SortKey {
    Pid,
    User,
    Cpu,
    Mem,
    Resident,
    Name,
}

/// How the table is currently sorted, for the status line.
fn sort_label(sort: SortKey, descending: bool) -> String {
    let name = match sort {
        SortKey::Pid => "pid",
        SortKey::User => "user",
        SortKey::Cpu => "cpu",
        SortKey::Mem => "mem",
        SortKey::Resident => "res",
        SortKey::Name => "name",
    };
    format!("{name}{}", if descending { " ↓" } else { " ↑" })
}

/// Everything the render needs: the last sample, the last error, the sort.
///
/// A failed sample keeps the last good one and records the error, so a
/// transient collector failure does not blank the screen.
#[derive(Debug, Clone)]
pub struct Ui {
    pub sample: Option<Sample>,
    pub error: Option<String>,
    pub sort: SortKey,
    pub descending: bool,
}

impl Default for Ui {
    fn default() -> Self {
        Self {
            sample: None,
            error: None,
            sort: SortKey::Cpu,
            descending: true,
        }
    }
}

impl Ui {
    pub fn new() -> Self {
        Self::default()
    }

    /// Move to the next sort key in cycle order.
    pub fn cycle_sort(&mut self) {
        self.sort = match self.sort {
            SortKey::Pid => SortKey::User,
            SortKey::User => SortKey::Cpu,
            SortKey::Cpu => SortKey::Mem,
            SortKey::Mem => SortKey::Resident,
            SortKey::Resident => SortKey::Name,
            SortKey::Name => SortKey::Pid,
        };
    }

    /// Flip between ascending and descending order.
    pub fn toggle_direction(&mut self) {
        self.descending = !self.descending;
    }

    /// Store a fresh sample, or keep the last good one and record the error.
    pub fn apply(&mut self, result: Result<Sample, CollectError>) {
        match result {
            Ok(sample) => {
                self.sample = Some(sample);
                self.error = None;
            }
            Err(err) => self.error = Some(err.to_string()),
        }
    }
}

/// A stand-in collector for platforms whose live sampler has not landed yet.
///
/// Always reports [`CollectError::Unavailable`]; the TUI shows the message in
/// the header while the process table stays empty.
#[derive(Debug, Clone, Copy, Default)]
pub struct UnavailableCollector;

impl Collector for UnavailableCollector {
    fn sample(&mut self) -> Result<Sample, CollectError> {
        Err(CollectError::Unavailable {
            origin: "ztop",
            what: "live sampling on this platform",
        })
    }
}

/// Terminal handle over the crossterm backend.
type Tui = Terminal<CrosstermBackend<Stdout>>;

/// Run the TUI until the user quits, sampling from `collector`.
///
/// Returns when the user presses `q`, `Esc` or `Ctrl-C`; terminal state is
/// restored even when drawing or sampling fails.
pub fn run(collector: &mut dyn Collector) -> io::Result<()> {
    enable_raw_mode()?;
    let result = run_inner(collector);
    restore()?;
    result
}

fn run_inner(collector: &mut dyn Collector) -> io::Result<()> {
    execute!(io::stdout(), EnterAlternateScreen)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(io::stdout()))?;
    let result = event_loop(&mut terminal, collector);
    execute!(io::stdout(), LeaveAlternateScreen)?;
    result
}

fn restore() -> io::Result<()> {
    disable_raw_mode()?;
    execute!(io::stdout(), LeaveAlternateScreen)?;
    Ok(())
}

fn event_loop(terminal: &mut Tui, collector: &mut dyn Collector) -> io::Result<()> {
    let mut ui = Ui::new();
    ui.apply(collector.sample());
    loop {
        terminal.draw(|frame| draw(frame, &ui))?;
        if event::poll(REFRESH)? {
            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press {
                    match key.code {
                        KeyCode::Char('q') | KeyCode::Esc => return Ok(()),
                        KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                            return Ok(());
                        }
                        KeyCode::Tab => ui.cycle_sort(),
                        KeyCode::Char('i') => ui.toggle_direction(),
                        _ => {}
                    }
                }
            }
        } else {
            ui.apply(collector.sample());
        }
    }
}

/// Render the whole screen: header meters over the process table.
///
/// Pure with respect to `ui`, so tests can drive it through a `TestBackend`.
pub fn draw(frame: &mut Frame, ui: &Ui) {
    let areas = Layout::vertical([Constraint::Length(4), Constraint::Min(1)]).split(frame.area());
    draw_header(frame, ui, areas[0]);
    draw_processes(frame, ui, areas[1]);
}

fn draw_header(frame: &mut Frame, ui: &Ui, area: ratatui::layout::Rect) {
    let rows = Layout::vertical([Constraint::Length(1); 4]).split(area);
    frame.render_widget(Paragraph::new(title_line(ui)), rows[0]);
    draw_cpu_row(frame, ui, rows[1]);
    draw_memory_row(frame, ui, rows[2]);
    frame.render_widget(Paragraph::new(status_line(ui)), rows[3]);
}

fn title_line(ui: &Ui) -> Line<'static> {
    let mut spans = vec![
        Span::from("zTop ").bold(),
        Span::from(env!("CARGO_PKG_VERSION")),
    ];
    if let Some(sample) = &ui.sample {
        spans.push(Span::from(format!(
            "  {}  up {}  {} procs  {}  load {:.2} {:.2} {:.2}",
            sample.hostname,
            uptime_text(&sample.uptime),
            sample.processes.len(),
            cpu_label(sample),
            sample.load_avg[0],
            sample.load_avg[1],
            sample.load_avg[2],
        )));
    }
    Line::from(spans)
}

fn cpu_label(sample: &Sample) -> String {
    match cpu_percent_mean(sample) {
        Some(percent) => format!("cpu {percent:.0}%"),
        None => "cpu n/a".to_string(),
    }
}

fn cpu_percent_mean(sample: &Sample) -> Option<f64> {
    let busy = &sample.cpu.busy_percent;
    if busy.is_empty() {
        return None;
    }
    Some(busy.iter().sum::<f64>() / busy.len() as f64)
}

fn draw_cpu_row(frame: &mut Frame, ui: &Ui, area: ratatui::layout::Rect) {
    let Some(sample) = &ui.sample else {
        return;
    };
    let percents = &sample.cpu.busy_percent;
    if percents.is_empty() {
        frame.render_widget(Paragraph::new("CPU n/a"), area);
        return;
    }
    let per_core = Layout::horizontal(vec![Constraint::Fill(1); percents.len()]).split(area);
    for (core, percent) in percents.iter().enumerate() {
        let gauge = Gauge::default()
            .ratio((*percent / 100.0).clamp(0.0, 1.0))
            .label(format!("{core} {:.0}%", percent));
        frame.render_widget(gauge, per_core[core]);
    }
}

fn draw_memory_row(frame: &mut Frame, ui: &Ui, area: ratatui::layout::Rect) {
    let Some(sample) = &ui.sample else {
        return;
    };
    let halves =
        Layout::horizontal([Constraint::Percentage(60), Constraint::Percentage(40)]).split(area);
    let (ratio, label) = memory_gauge(&sample.memory);
    frame.render_widget(Gauge::default().ratio(ratio).label(label), halves[0]);
    let (ratio, label) = swap_gauge(&sample.memory);
    frame.render_widget(Gauge::default().ratio(ratio).label(label), halves[1]);
}

fn memory_gauge(memory: &Memory) -> (f64, String) {
    match (metric_bytes(&memory.used), metric_bytes(&memory.total)) {
        (Some(used), Some(total)) if total > 0.0 => (
            used / total,
            format!("{} / {}", bytes_text(used), bytes_text(total)),
        ),
        _ => (0.0, "n/a".to_string()),
    }
}

fn swap_gauge(memory: &Memory) -> (f64, String) {
    match (
        metric_bytes(&memory.swap_used),
        metric_bytes(&memory.swap_total),
    ) {
        (Some(used), Some(total)) if total > 0.0 => (
            used / total,
            format!("{} / {}", bytes_text(used), bytes_text(total)),
        ),
        _ => (0.0, "no swap".to_string()),
    }
}

/// Bytes of a metric, when the metric is present and measured in bytes.
fn metric_bytes(metric: &Metric) -> Option<f64> {
    if metric.available && metric.unit == Unit::Bytes {
        Some(metric.value)
    } else {
        None
    }
}

/// Human-readable bytes in binary units.
fn bytes_text(bytes: f64) -> String {
    if bytes >= GIB {
        format!("{:.1} GiB", bytes / GIB)
    } else if bytes >= MIB {
        format!("{:.1} MiB", bytes / MIB)
    } else if bytes >= KIB {
        format!("{:.0} KiB", bytes / KIB)
    } else {
        format!("{bytes:.0} B")
    }
}

/// Uptime as `3d 04:05:06` or `04:05:06`.
fn uptime_text(metric: &Metric) -> String {
    if !metric.available || metric.unit != Unit::Seconds {
        return "n/a".to_string();
    }
    let secs = metric.value as u64;
    let (days, rest) = (secs / 86_400, secs % 86_400);
    let (hours, rest) = (rest / 3_600, rest % 3_600);
    let (minutes, seconds) = (rest / 60, rest % 60);
    if days > 0 {
        format!("{days}d {hours:02}:{minutes:02}:{seconds:02}")
    } else {
        format!("{hours:02}:{minutes:02}:{seconds:02}")
    }
}

fn status_line(ui: &Ui) -> Line<'static> {
    if let Some(error) = &ui.error {
        Line::from(Span::from(format!("error: {error} · q: quit")).red())
    } else if ui.sample.is_some() {
        Line::from(format!(
            "tab: sort {} · i: reverse · q: quit",
            sort_label(ui.sort, ui.descending)
        ))
    } else {
        Line::from("waiting for the first sample · q: quit")
    }
}

fn draw_processes(frame: &mut Frame, ui: &Ui, area: ratatui::layout::Rect) {
    let header = Row::new(["PID", "USER", "STATE", "CPU%", "MEM%", "RES", "NAME"]).bold();
    let mut rows: Vec<Row<'static>> = Vec::new();
    if let Some(sample) = &ui.sample {
        let mut procs: Vec<&Process> = sample.processes.iter().collect();
        procs.sort_by(|a, b| {
            let ord = match ui.sort {
                SortKey::Pid => a.pid.cmp(&b.pid),
                SortKey::User => a.user.cmp(&b.user),
                SortKey::Cpu => a.cpu_percent.total_cmp(&b.cpu_percent),
                SortKey::Mem => a.mem_percent.total_cmp(&b.mem_percent),
                SortKey::Resident => a.resident_bytes.cmp(&b.resident_bytes),
                SortKey::Name => a.name.cmp(&b.name),
            };
            if ui.descending { ord.reverse() } else { ord }
        });
        rows.extend(procs.iter().map(|p| process_row(p)));
    }
    let widths = [
        Constraint::Length(8),
        Constraint::Length(10),
        Constraint::Length(7),
        Constraint::Length(7),
        Constraint::Length(7),
        Constraint::Length(9),
        Constraint::Min(1),
    ];
    let table = Table::new(rows, widths)
        .header(header)
        .block(Block::new().borders(Borders::TOP));
    frame.render_widget(table, area);
}

fn process_row(process: &Process) -> Row<'static> {
    Row::new(vec![
        Cell::from(format!("{:>7}", process.pid)),
        Cell::from(format!("{:>9}", process.user)),
        Cell::from(process.state.clone()),
        Cell::from(format!("{:>6.1}", process.cpu_percent)),
        Cell::from(format!("{:>6.1}", process.mem_percent)),
        Cell::from(format!("{:>8}", bytes_text(process.resident_bytes as f64))),
        Cell::from(process.name.clone()),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use ztop_core::model::{Cpu, CpuTimes, Sensors};

    /// A 4-core, 12-process sample with spread-out values.
    fn sample() -> Sample {
        let cores: Vec<CpuTimes> = (0..4)
            .map(|i| CpuTimes {
                user: i as f64 * 10.0,
                system: 1.0,
                nice: 0.0,
                idle: 10.0,
                io_wait: 0.0,
                irq: 0.0,
                soft_irq: 0.0,
                steal: 0.0,
                guest: 0.0,
            })
            .collect();
        let processes = (1..=12)
            .map(|pid| Process {
                pid,
                parent: None,
                user: "alice".to_string(),
                state: if pid % 2 == 0 { "R" } else { "S" }.to_string(),
                name: format!("worker-{pid:02}"),
                cpu_percent: 100.0 / pid as f64,
                mem_percent: pid as f64,
                virtual_bytes: pid as u64 * 1_000_000,
                resident_bytes: pid as u64 * 100_000,
                threads: pid,
            })
            .collect();
        Sample {
            timestamp_ms: 1_700_000_000_000,
            hostname: "host-a".to_string(),
            cpu: Cpu {
                cores,
                busy_percent: vec![10.0, 25.0, 50.0, 100.0],
                frequency_mhz: Vec::new(),
            },
            memory: Memory {
                total: Metric::available(16.0 * GIB, Unit::Bytes),
                used: Metric::available(6.0 * GIB, Unit::Bytes),
                free: Metric::available(10.0 * GIB, Unit::Bytes),
                swap_total: Metric::available(4.0 * GIB, Unit::Bytes),
                swap_used: Metric::available(GIB, Unit::Bytes),
                compressed: Metric::unavailable(Unit::Bytes),
            },
            load_avg: [0.5, 0.4, 0.3],
            uptime: Metric::available(7_254.0, Unit::Seconds),
            processes,
            disks: Vec::new(),
            net: Vec::new(),
            sensors: Sensors {
                temps: Vec::new(),
                fans: Vec::new(),
                battery: None,
            },
        }
    }

    /// Render into a test backend and return the text of every buffer row.
    fn render(ui: &Ui, width: u16, height: u16) -> Vec<String> {
        let backend = TestBackend::new(width, height);
        let mut terminal = Terminal::new(backend).expect("backend");
        terminal.draw(|frame| draw(frame, ui)).expect("draw");
        let buffer = terminal.backend().buffer().clone();
        (0..buffer.area.height)
            .map(|y| {
                (0..buffer.area.width)
                    .map(|x| buffer[(x, y)].symbol().to_string())
                    .collect::<String>()
            })
            .collect()
    }

    fn ui_with(sample: Option<Sample>, error: Option<String>) -> Ui {
        Ui {
            sample,
            error,
            sort: SortKey::Cpu,
            descending: true,
        }
    }

    #[test]
    fn renders_the_header_and_table_at_80x24() {
        let ui = ui_with(Some(sample()), None);
        let rows = render(&ui, 80, 24);
        assert!(rows[0].contains("zTop 0.1.0"), "{:?}", rows[0]);
        assert!(rows[0].contains("host-a"), "{:?}", rows[0]);
        assert!(rows[0].contains("up 02:00:54"), "{:?}", rows[0]);
        assert!(rows[0].contains("12 procs"), "{:?}", rows[0]);
        assert!(rows[0].contains("cpu 46%"), "{:?}", rows[0]);
        // Per-core gauges: one labelled bar per core.
        assert!(rows[1].contains("0 10%"), "{:?}", rows[1]);
        assert!(rows[1].contains("3 100%"), "{:?}", rows[1]);
        // Memory and swap gauges.
        assert!(rows[2].contains("6.0 GiB / 16.0 GiB"), "{:?}", rows[2]);
        assert!(rows[2].contains("1.0 GiB / 4.0 GiB"), "{:?}", rows[2]);
        // Table header, then the busiest process on top (CPU, descending).
        let header_row = rows
            .iter()
            .position(|row| row.contains("PID") && row.contains("CPU%"))
            .expect("table header");
        assert!(
            rows[header_row + 1].contains("worker-01"),
            "{:?}",
            rows[header_row + 1]
        );
        assert!(
            rows[header_row + 1].contains("100.0"),
            "{:?}",
            rows[header_row + 1]
        );
    }

    #[test]
    fn renders_all_processes_at_large_sizes() {
        let ui = ui_with(Some(sample()), None);
        let rows = render(&ui, 200, 50);
        for pid in 1..=12 {
            let name = format!("worker-{pid:02}");
            assert!(
                rows.iter().any(|row| row.contains(&name)),
                "{name} missing at 200x50"
            );
        }
        // The last worker still sits above the fold with room to spare.
        let last = rows
            .iter()
            .position(|row| row.contains("worker-12"))
            .expect("worker-12 row");
        assert!(last < 40, "last row at {last} of 50");
    }

    #[test]
    fn sorts_by_pid_and_memory() {
        let mut ui = ui_with(Some(sample()), None);
        ui.sort = SortKey::Pid;
        ui.descending = false;
        let rows = render(&ui, 80, 24);
        let header_row = rows
            .iter()
            .position(|row| row.contains("PID"))
            .expect("table header");
        assert!(rows[header_row + 1].contains("worker-01"));

        ui.sort = SortKey::Mem;
        ui.descending = true;
        let rows = render(&ui, 80, 24);
        let header_row = rows
            .iter()
            .position(|row| row.contains("MEM%"))
            .expect("table header");
        assert!(rows[header_row + 1].contains("worker-12"));
    }

    #[test]
    fn renders_the_error_state() {
        let ui = ui_with(None, Some("collector is down".to_string()));
        let rows = render(&ui, 80, 24);
        assert!(
            rows[3].contains("error: collector is down"),
            "{:?}",
            rows[3]
        );
        // The table still renders its header with no sample to show.
        assert!(rows.iter().any(|row| row.contains("CPU%")));
    }

    #[test]
    fn apply_keeps_the_last_good_sample_on_error() {
        let mut ui = Ui::new();
        ui.apply(Err(CollectError::Unavailable {
            origin: "test",
            what: "nothing",
        }));
        assert!(ui.sample.is_none());
        assert!(ui.error.is_some());
        ui.apply(Ok(sample()));
        assert!(ui.error.is_none());
        assert_eq!(ui.sample.as_ref().expect("sample").processes.len(), 12);
        // A later failure keeps the good sample and records the error.
        ui.apply(Err(CollectError::Unavailable {
            origin: "test",
            what: "nothing",
        }));
        assert!(ui.sample.is_some());
        assert!(ui.error.is_some());
    }

    #[test]
    fn sort_cycling_and_direction() {
        let mut ui = Ui::new();
        assert_eq!(ui.sort, SortKey::Cpu);
        assert!(ui.descending);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::Mem);
        for _ in 0..3 {
            ui.cycle_sort();
        }
        assert_eq!(ui.sort, SortKey::Pid);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::User);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::Cpu);
        ui.toggle_direction();
        assert!(!ui.descending);
    }

    /// Dump the 80x24 frame for a human eye:
    /// `cargo test -p ztop-tui --lib dump_screen_snapshot -- --ignored --nocapture`
    #[test]
    #[ignore = "manual inspection helper"]
    fn dump_screen_snapshot() {
        let ui = ui_with(Some(sample()), None);
        for (index, row) in render(&ui, 80, 24).iter().enumerate() {
            println!("{index:2}|{row}");
        }
    }

    #[test]
    fn bytes_and_uptime_helpers() {
        assert_eq!(bytes_text(6.0 * GIB), "6.0 GiB");
        assert_eq!(bytes_text(1.5 * MIB), "1.5 MiB");
        assert_eq!(bytes_text(2.0 * KIB), "2 KiB");
        assert_eq!(bytes_text(5.0), "5 B");
        assert_eq!(
            uptime_text(&Metric::available(7_254.0, Unit::Seconds)),
            "02:00:54"
        );
        assert_eq!(
            uptime_text(&Metric::available(3.0 * 86_400.0 + 60.0, Unit::Seconds)),
            "3d 00:01:00"
        );
        assert_eq!(uptime_text(&Metric::unavailable(Unit::Seconds)), "n/a");
    }
}
