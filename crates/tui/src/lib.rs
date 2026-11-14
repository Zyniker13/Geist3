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
use ratatui::backend::{CrosstermBackend, TestBackend};
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
use ztop_core::control::{self, Control, Plan};
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

/// One row of the process table: a process plus its tree depth (always 0
/// when tree view is off) and how many visible descendants a fold on it
/// hides (always 0 outside tree view).
pub struct TreeRow<'a> {
    pub process: &'a Process,
    pub depth: usize,
    pub hidden: usize,
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

/// Everything the render needs: the last sample, the last error, the sort,
/// and the active filters.
///
/// A failed sample keeps the last good one and records the error, so a
/// transient collector failure does not blank the screen.
#[derive(Debug, Clone)]
pub struct Ui {
    pub sample: Option<Sample>,
    pub error: Option<String>,
    pub sort: SortKey,
    pub descending: bool,
    /// Name filter. `Some` means the filter prompt is open; an empty string
    /// matches everything, so opening the filter never hides rows by itself.
    pub filter: Option<String>,
    /// When set, only this user's processes are listed.
    pub user_filter: Option<String>,
    /// The highlighted process, by pid. The cursor stays on the same pid
    /// across samples when it still exists.
    pub cursor: Option<u32>,
    /// Follow mode: re-select this pid on every sample, htop-style. When the
    /// followed process disappears, follow mode ends.
    pub follow: Option<u32>,
    /// Tree view: group processes under their parents instead of sorting
    /// them into one flat list.
    pub tree: bool,
    /// Pids whose subtree is folded away in tree mode.
    pub collapsed: std::collections::BTreeSet<u32>,
    /// Incremental search prompt. `Some` means the prompt is open; the
    /// cursor follows the next row whose name matches the pattern.
    pub search: Option<String>,
    /// Pids tagged with Space (and `c` for children). Actions apply to
    /// every tagged process at once.
    pub tags: std::collections::BTreeSet<u32>,
    /// The open signal menu's selected row index, when the menu is open.
    pub menu: Option<usize>,
    /// The last control action's outcome, shown in the status line until
    /// the next sample arrives.
    pub notice: Option<String>,
}

impl Default for Ui {
    fn default() -> Self {
        Self {
            sample: None,
            error: None,
            sort: SortKey::Cpu,
            descending: true,
            filter: None,
            user_filter: None,
            cursor: None,
            follow: None,
            tree: false,
            collapsed: std::collections::BTreeSet::new(),
            search: None,
            tags: std::collections::BTreeSet::new(),
            menu: None,
            notice: None,
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

    /// Open or close the name-filter prompt. Closing discards the pattern;
    /// opening starts from an empty prompt and closes the search prompt —
    /// the two share the keyboard.
    pub fn toggle_filter(&mut self) {
        match self.filter {
            Some(_) => self.filter = None,
            None => {
                self.search = None;
                self.filter = Some(String::new());
            }
        }
    }

    /// Type one character into the open filter prompt.
    pub fn filter_push(&mut self, c: char) {
        if let Some(text) = &mut self.filter {
            text.push(c);
        }
    }

    /// Erase the last character from the open filter prompt.
    pub fn filter_pop(&mut self) {
        if let Some(text) = &mut self.filter {
            text.pop();
        }
    }

    /// Close the filter prompt without clearing the text (Enter).
    pub fn close_filter(&mut self) {
        self.filter = None;
    }

    /// Open or close the incremental-search prompt. Closing discards the
    /// pattern and keeps the cursor where the search left it; opening
    /// starts from an empty prompt and closes the filter prompt — the two
    /// share the keyboard.
    pub fn toggle_search(&mut self) {
        if self.search.is_some() {
            self.search = None;
        } else {
            self.filter = None;
            self.search = Some(String::new());
        }
    }

    /// Close the search prompt, keeping the cursor where it jumped.
    pub fn close_search(&mut self) {
        self.search = None;
    }

    /// Type one character into the open search prompt and re-run the
    /// search from the cursor.
    pub fn search_push(&mut self, c: char) {
        if let Some(text) = &mut self.search {
            text.push(c);
        }
        self.search_scan(0);
    }

    /// Erase the last character from the open search prompt and re-run the
    /// search from the cursor.
    pub fn search_pop(&mut self) {
        if let Some(text) = &mut self.search {
            text.pop();
        }
        self.search_scan(0);
    }

    /// Jump the cursor to the next match after it (F3 again while the
    /// prompt is open), wrapping around the table.
    pub fn search_next(&mut self) {
        self.search_scan(1);
    }

    /// Scan the visible rows for the first one whose name contains the
    /// open search pattern, case-insensitively, starting `skip` rows after
    /// the cursor and wrapping around. Moves the cursor (and re-pins
    /// follow) there; with no match — or an empty prompt — the cursor
    /// stays put. `skip` 0 re-checks the cursor's own row first, so
    /// editing the pattern keeps the cursor while it still matches.
    fn search_scan(&mut self, skip: isize) {
        let Some(pattern) = self.search.as_deref() else {
            return;
        };
        let pattern = pattern.to_lowercase();
        if pattern.is_empty() {
            return;
        }
        let rows = self.ordered_rows();
        if rows.is_empty() {
            return;
        }
        let len = rows.len() as isize;
        let start = rows
            .iter()
            .position(|r| Some(r.process.pid) == self.cursor)
            .map_or(0, |i| i as isize);
        for step in 0..len {
            let index = (start + skip + step).rem_euclid(len) as usize;
            if rows[index].process.name.to_lowercase().contains(&pattern) {
                self.cursor = Some(rows[index].process.pid);
                if self.follow.is_some() {
                    self.follow = self.cursor;
                }
                return;
            }
        }
    }

    /// Tag or untag the cursor's process (Space).
    pub fn toggle_tag(&mut self) {
        if let Some(pid) = self.cursor {
            if self.tags.contains(&pid) {
                self.tags.remove(&pid);
            } else {
                self.tags.insert(pid);
            }
        }
    }

    /// Tag every visible descendant of the cursor's process (`c`).
    pub fn tag_children(&mut self) {
        let Some(selected) = self.cursor else {
            return;
        };
        let Some(sample) = &self.sample else {
            return;
        };
        for process in &sample.processes {
            if process.pid != selected
                && self.visible(process)
                && self.ancestors(process).contains(&selected)
            {
                self.tags.insert(process.pid);
            }
        }
    }

    /// Clear every tag (`U`).
    pub fn untag_all(&mut self) {
        self.tags.clear();
    }

    /// Every pid a control action applies to: the tagged set when any
    /// process is tagged, otherwise the cursor's process.
    fn targets(&self) -> Vec<u32> {
        if !self.tags.is_empty() {
            self.tags.iter().copied().collect()
        } else {
            self.cursor.iter().copied().collect()
        }
    }

    /// Open the signal menu (F9) over the tag set, or the cursor's process
    /// when nothing is tagged. Any open prompt closes first; without a
    /// target the menu stays closed.
    pub fn open_menu(&mut self) {
        self.filter = None;
        self.search = None;
        if !self.targets().is_empty() {
            self.menu = Some(0);
        }
    }

    /// Close the signal menu without acting (Esc).
    pub fn close_menu(&mut self) {
        self.menu = None;
    }

    /// Move the menu selection down, wrapping at the end.
    pub fn menu_next(&mut self) {
        if let Some(selected) = self.menu {
            let count = control::common_signals().len();
            self.menu = Some((selected + 1) % count);
        }
    }

    /// Move the menu selection up, wrapping at the top.
    pub fn menu_prev(&mut self) {
        if let Some(selected) = self.menu {
            let count = control::common_signals().len();
            self.menu = Some((selected + count - 1) % count);
        }
    }

    /// Turn the menu's selection into a signal plan over the targets and
    /// close the menu; `None` when the menu is closed or the targets
    /// vanished while it was open.
    pub fn confirm_menu(&mut self) -> Option<Plan> {
        let selected = self.menu.take()?;
        let (_, sig) = control::common_signals()[selected];
        let pids = self.targets();
        (!pids.is_empty()).then_some(Plan {
            pids,
            action: Control::Signal(sig),
        })
    }

    /// A plan to shift every target's nice value by `delta` (F7 raises
    /// priority, F8 lowers it); `None` when there is no target.
    pub fn renice_plan(&self, delta: i32) -> Option<Plan> {
        let pids = self.targets();
        (!pids.is_empty()).then_some(Plan {
            pids,
            action: Control::Renice(delta),
        })
    }

    /// Cycle the user filter through the users present in the current
    /// sample: all users, then each user in sorted order, then back to all.
    ///
    /// When the filtered user's processes disappear from a later sample the
    /// filter wraps back to "all users" on the next press.
    pub fn cycle_user_filter(&mut self) {
        let users: Vec<&str> = self
            .sample
            .as_ref()
            .map(|s| {
                let mut users: Vec<&str> = s.processes.iter().map(|p| p.user.as_str()).collect();
                users.sort_unstable();
                users.dedup();
                users
            })
            .unwrap_or_default();
        self.user_filter = match (&self.user_filter, users.as_slice()) {
            (None, [first, ..]) => Some((*first).to_string()),
            (Some(current), rest) => {
                // The next user after `current` in sorted order, wrapping to
                // "all users" past the last (or when `current` vanished).
                rest.iter()
                    .skip_while(|u| **u != current.as_str())
                    .nth(1)
                    .map(|u| (*u).to_string())
            }
            (None, []) => None,
        };
    }

    /// Does a process pass the current name and user filters?
    ///
    /// The name match is a case-insensitive substring; an empty prompt
    /// matches everything.
    pub fn visible(&self, process: &Process) -> bool {
        if let Some(user) = &self.user_filter {
            if &process.user != user {
                return false;
            }
        }
        if let Some(pattern) = &self.filter {
            let pattern = pattern.to_lowercase();
            if !pattern.is_empty() && !process.name.to_lowercase().contains(&pattern) {
                return false;
            }
        }
        true
    }

    /// The processes the table shows, filtered and in display order. The
    /// cursor, the draw path and the tests all use this one ordering.
    pub fn ordered_visible(&self) -> Vec<&Process> {
        let mut procs: Vec<&Process> = self
            .sample
            .as_ref()
            .map(|s| s.processes.iter().filter(|p| self.visible(p)).collect())
            .unwrap_or_default();
        procs.sort_by(|a, b| self.compare(a, b));
        procs
    }

    /// The ordering rule for the flat list and for tree siblings.
    fn compare(&self, a: &Process, b: &Process) -> std::cmp::Ordering {
        let ord = match self.sort {
            SortKey::Pid => a.pid.cmp(&b.pid),
            SortKey::User => a.user.cmp(&b.user),
            SortKey::Cpu => a.cpu_percent.total_cmp(&b.cpu_percent),
            SortKey::Mem => a.mem_percent.total_cmp(&b.mem_percent),
            SortKey::Resident => a.resident_bytes.cmp(&b.resident_bytes),
            SortKey::Name => a.name.cmp(&b.name),
        };
        if self.descending { ord.reverse() } else { ord }
    }

    /// Switch between the flat list and the tree view.
    pub fn toggle_tree(&mut self) {
        self.tree = !self.tree;
    }

    /// Fold or unfold the subtree of the cursor's process. A row without
    /// children has nothing to fold; the cursor then stays where it is.
    pub fn toggle_collapse(&mut self) {
        let Some(selected) = self.cursor else {
            return;
        };
        if self.has_visible_descendants(selected) {
            if self.collapsed.contains(&selected) {
                self.collapsed.remove(&selected);
            } else {
                self.collapsed.insert(selected);
            }
        }
    }

    /// Does any visible process descend from this pid?
    fn has_visible_descendants(&self, pid: u32) -> bool {
        self.sample.as_ref().is_some_and(|sample| {
            sample
                .processes
                .iter()
                .any(|p| self.visible(p) && self.ancestors(p).contains(&pid))
        })
    }

    /// The pids a process descends from within one sample.
    fn ancestors(&self, process: &Process) -> std::collections::BTreeSet<u32> {
        let mut set = std::collections::BTreeSet::new();
        let Some(sample) = &self.sample else {
            return set;
        };
        let mut parent = process.parent;
        while let Some(pid) = parent {
            if !set.insert(pid) {
                break; // parent cycles end here
            }
            parent = sample
                .processes
                .iter()
                .find(|p| p.pid == pid)
                .and_then(|p| p.parent);
        }
        set
    }

    /// The rows the table shows, filtered and in display order: a flat
    /// list when tree view is off, otherwise processes grouped under their
    /// parents with siblings in sort order. A matched child of an
    /// unmatched parent becomes a root; a folded row hides its subtree and
    /// reports how many visible descendants it hides.
    pub fn ordered_rows(&self) -> Vec<TreeRow<'_>> {
        let procs = self.ordered_visible();
        if !self.tree {
            return procs
                .into_iter()
                .map(|process| TreeRow {
                    process,
                    depth: 0,
                    hidden: 0,
                })
                .collect();
        }
        let mut children: std::collections::BTreeMap<u32, Vec<&Process>> = Default::default();
        let mut roots: Vec<&Process> = Vec::new();
        for p in &procs {
            match p
                .parent
                .and_then(|pid| procs.iter().find(|q| q.pid == pid && q.pid != p.pid))
            {
                Some(parent) => children.entry(parent.pid).or_default().push(p),
                None => roots.push(p),
            }
        }
        fn hidden_descendants(
            pid: u32,
            children: &std::collections::BTreeMap<u32, Vec<&Process>>,
        ) -> usize {
            children.get(&pid).map_or(0, |kids| {
                kids.len()
                    + kids
                        .iter()
                        .map(|k| hidden_descendants(k.pid, children))
                        .sum::<usize>()
            })
        }
        fn walk<'a>(
            list: &[&'a Process],
            depth: usize,
            children: &std::collections::BTreeMap<u32, Vec<&'a Process>>,
            collapsed: &std::collections::BTreeSet<u32>,
            rows: &mut Vec<TreeRow<'a>>,
        ) {
            for p in list {
                if collapsed.contains(&p.pid) {
                    rows.push(TreeRow {
                        process: p,
                        depth,
                        hidden: hidden_descendants(p.pid, children),
                    });
                } else {
                    rows.push(TreeRow {
                        process: p,
                        depth,
                        hidden: 0,
                    });
                    if let Some(kids) = children.get(&p.pid) {
                        walk(kids, depth + 1, children, collapsed, rows);
                    }
                }
            }
        }
        let mut rows = Vec::new();
        walk(&roots, 0, &children, &self.collapsed, &mut rows);
        rows
    }

    /// Move the cursor down one visible row (or onto the first row).
    pub fn select_next(&mut self) {
        let rows = self.ordered_rows();
        if rows.is_empty() {
            return;
        }
        let index = rows
            .iter()
            .position(|r| Some(r.process.pid) == self.cursor)
            .map_or(0, |i| (i + 1).min(rows.len() - 1));
        self.cursor = Some(rows[index].process.pid);
        if self.follow.is_some() {
            self.follow = self.cursor;
        }
    }

    /// Move the cursor up one visible row (or onto the first row).
    pub fn select_prev(&mut self) {
        let rows = self.ordered_rows();
        if rows.is_empty() {
            return;
        }
        let index = rows
            .iter()
            .position(|r| Some(r.process.pid) == self.cursor)
            .map_or(0, |i| i.saturating_sub(1));
        self.cursor = Some(rows[index].process.pid);
        if self.follow.is_some() {
            self.follow = self.cursor;
        }
    }

    /// Turn follow on for the cursor's process, or off when it is already
    /// following. Without a cursor there is nothing to follow.
    pub fn toggle_follow(&mut self) {
        if self.follow.is_some() {
            self.follow = None;
        } else {
            self.follow = self.cursor;
        }
    }

    /// Store a fresh sample, or keep the last good one and record the error.
    ///
    /// The cursor rides along by pid: a followed process is re-selected on
    /// every sample, a plain cursor keeps its pid while it still exists, and
    /// a vanished followed process ends follow mode.
    pub fn apply(&mut self, result: Result<Sample, CollectError>) {
        match result {
            Ok(sample) => {
                let exists =
                    |pid: u32, sample: &Sample| sample.processes.iter().any(|p| p.pid == pid);
                if let Some(followed) = self.follow {
                    if exists(followed, &sample) {
                        self.cursor = Some(followed);
                    } else {
                        self.follow = None;
                        self.cursor = None;
                    }
                } else if let Some(selected) = self.cursor {
                    if !exists(selected, &sample) {
                        self.cursor = None;
                    }
                }
                self.sample = Some(sample);
                self.error = None;
                // A control notice lives for exactly one refresh.
                self.notice = None;
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
                        // Ctrl-C always quits, even while typing a filter.
                        KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                            return Ok(());
                        }
                        KeyCode::Tab => ui.cycle_sort(),
                        // While the filter prompt is open the keys edit it:
                        // Esc closes, Backspace erases, everything printable
                        // types — including `q` and `i`.
                        KeyCode::Esc if ui.filter.is_some() => ui.close_filter(),
                        KeyCode::Backspace if ui.filter.is_some() => ui.filter_pop(),
                        KeyCode::Char(c) if ui.filter.is_some() => ui.filter_push(c),
                        // While the search prompt is open the keys edit it:
                        // F3 repeats the search, Esc/Enter close, Backspace
                        // erases, everything printable types.
                        KeyCode::Esc if ui.search.is_some() => ui.close_search(),
                        KeyCode::Backspace if ui.search.is_some() => ui.search_pop(),
                        KeyCode::F(3) if ui.search.is_some() => ui.search_next(),
                        KeyCode::Enter if ui.search.is_some() => ui.close_search(),
                        KeyCode::Char(c) if ui.search.is_some() => ui.search_push(c),
                        // While the signal menu is open the keys drive it:
                        // Esc closes, j/k move, Enter sends to the targets.
                        KeyCode::Esc if ui.menu.is_some() => ui.close_menu(),
                        KeyCode::Char('j') | KeyCode::Down if ui.menu.is_some() => ui.menu_next(),
                        KeyCode::Char('k') | KeyCode::Up if ui.menu.is_some() => ui.menu_prev(),
                        KeyCode::Enter if ui.menu.is_some() => {
                            if let Some(plan) = ui.confirm_menu() {
                                run_plan(&mut ui, &plan);
                            }
                        }
                        _ if ui.menu.is_some() => {}
                        KeyCode::Char('q') | KeyCode::Esc => return Ok(()),
                        KeyCode::Char('i') => ui.toggle_direction(),
                        KeyCode::F(3) => ui.toggle_search(),
                        KeyCode::F(4) => ui.toggle_filter(),
                        KeyCode::Char('u') => ui.cycle_user_filter(),
                        KeyCode::Char(' ') => ui.toggle_tag(),
                        KeyCode::Char('c') => ui.tag_children(),
                        KeyCode::Char('U') => ui.untag_all(),
                        KeyCode::F(9) => ui.open_menu(),
                        KeyCode::F(7) => {
                            if let Some(plan) = ui.renice_plan(-1) {
                                run_plan(&mut ui, &plan);
                            }
                        }
                        KeyCode::F(8) => {
                            if let Some(plan) = ui.renice_plan(1) {
                                run_plan(&mut ui, &plan);
                            }
                        }
                        KeyCode::Char('f') | KeyCode::Char('F') => ui.toggle_follow(),
                        KeyCode::F(5) => ui.toggle_tree(),
                        KeyCode::Enter => ui.toggle_collapse(),
                        KeyCode::Char('j') | KeyCode::Down => ui.select_next(),
                        KeyCode::Char('k') | KeyCode::Up => ui.select_prev(),
                        _ => {}
                    }
                }
            }
        } else {
            ui.apply(collector.sample());
        }
    }
}

/// Execute a control plan against the real processes and record the
/// outcome in the status line for one refresh.
fn run_plan(ui: &mut Ui, plan: &Plan) {
    let results = control::execute(plan);
    let ok = results.iter().filter(|(_, result)| result.is_ok()).count();
    let failed = results.len() - ok;
    let label = match plan.action {
        Control::Signal(sig) => format!("signal {}", control::signal_name(sig)),
        Control::Renice(delta) => format!("renice {delta:+}"),
    };
    ui.notice = Some(if failed == 0 {
        format!("{label}: {ok} pid(s)")
    } else {
        let mut notice = format!("{label}: {ok} ok, {failed} failed");
        if let Some(first) = results
            .into_iter()
            .filter_map(|(_, result)| result.err())
            .next()
        {
            notice.push_str(&format!(": {first}"));
        }
        notice
    });
}

/// Render `ui` into `width` x `height` lines of text, exactly as a real
/// terminal of that size would show it.
///
/// This is one implementation for two users: the replay command prints the
/// lines, and snapshot tests assert on them. No rendering logic is
/// duplicated — both paths feed the same [`draw`] through a `TestBackend`.
pub fn draw_lines(ui: &Ui, width: u16, height: u16) -> Vec<String> {
    let mut terminal = Terminal::new(TestBackend::new(width, height)).expect("test backend");
    terminal
        .draw(|frame| draw(frame, ui))
        .expect("draw into the test backend");
    let buffer = terminal.backend().buffer().clone();
    (0..buffer.area.height)
        .map(|y| {
            (0..buffer.area.width)
                .map(|x| buffer[(x, y)].symbol().to_string())
                .collect::<String>()
        })
        .collect()
}

/// Render the whole screen: header meters over the process table.
///
/// Pure with respect to `ui`, so tests can drive it through a `TestBackend`.
pub fn draw(frame: &mut Frame, ui: &Ui) {
    let header = Constraint::Length(4 + u16::from(sensors_present(ui)));
    let areas = Layout::vertical([header, Constraint::Min(1)]).split(frame.area());
    draw_header(frame, ui, areas[0]);
    draw_processes(frame, ui, areas[1]);
    if ui.menu.is_some() {
        draw_menu(frame, ui, frame.area());
    }
}

/// The signal menu: a bordered popup centered over the screen, one row per
/// signal with `>` marking the selection. Enter sends, Esc cancels.
fn draw_menu(frame: &mut Frame, ui: &Ui, area: ratatui::layout::Rect) {
    let signals = control::common_signals();
    let width = 44.min(area.width);
    let height = (signals.len() as u16 + 3).min(area.height);
    let x = area.x + area.width.saturating_sub(width) / 2;
    let y = area.y + area.height.saturating_sub(height) / 2;
    let rect = ratatui::layout::Rect {
        x,
        y,
        width,
        height,
    };
    frame.render_widget(ratatui::widgets::Clear, rect);
    let selected = ui.menu.unwrap_or(0);
    let mut lines = vec![Line::from("Send signal (Enter sends, Esc cancels)").bold()];
    for (index, (name, number)) in signals.iter().enumerate() {
        let marker = if index == selected { "> " } else { "  " };
        lines.push(Line::from(format!("{marker}{name} ({number})")));
    }
    let menu = Paragraph::new(lines).block(Block::new().borders(Borders::ALL));
    frame.render_widget(menu, rect);
}

/// True when the sample carries any sensor reading worth a header row.
///
/// Battery is deliberately absent: nothing renders it yet, and a row must
/// never appear empty.
fn sensors_present(ui: &Ui) -> bool {
    ui.sample.as_ref().is_some_and(|sample| {
        let sensors = &sample.sensors;
        !sensors.temps.is_empty()
            || !sensors.fans.is_empty()
            || sensors.gpu_watts.available
            || sensors.system_watts.available
    })
}

fn draw_header(frame: &mut Frame, ui: &Ui, area: ratatui::layout::Rect) {
    let with_sensors = sensors_present(ui);
    let rows = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        if with_sensors {
            Constraint::Length(1)
        } else {
            Constraint::Length(0)
        },
        Constraint::Length(1),
    ])
    .split(area);
    frame.render_widget(Paragraph::new(title_line(ui)), rows[0]);
    draw_cpu_row(frame, ui, rows[1]);
    draw_memory_row(frame, ui, rows[2]);
    if with_sensors {
        frame.render_widget(Paragraph::new(sensors_line(ui)), rows[3]);
    }
    frame.render_widget(Paragraph::new(status_line(ui)), rows[4]);
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

/// Compact per-second rate for the I/O columns: `3.5Mi`-style, at most
/// five characters, so the table stays usable at 80 columns. `None`
/// (no rate, e.g. the first sample) renders as blank.
fn rate_text(rate: Option<f64>) -> String {
    const TIB: f64 = 1024.0 * GIB;
    let Some(rate) = rate else {
        return String::new();
    };
    let (value, suffix) = if rate >= TIB {
        (rate / TIB, "Ti")
    } else if rate >= GIB {
        (rate / GIB, "Gi")
    } else if rate >= MIB {
        (rate / MIB, "Mi")
    } else if rate >= KIB {
        (rate / KIB, "Ki")
    } else {
        (rate, "B")
    };
    if value >= 10.0 {
        format!("{value:.0}{suffix}")
    } else {
        format!("{value:.1}{suffix}")
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

/// One compact line of sensor readings, when the host reports any.
///
/// Renders the collector's own labels verbatim; the row only exists when
/// there is something to show, so an empty list never draws an empty line.
fn sensors_line(ui: &Ui) -> Line<'static> {
    let Some(sample) = &ui.sample else {
        return Line::from("");
    };
    let mut parts: Vec<String> = Vec::new();
    for temp in sample.sensors.temps.iter().take(3) {
        if temp.celsius.available {
            parts.push(format!("{} {:.1}°C", temp.label, temp.celsius.value));
        }
    }
    for fan in sample.sensors.fans.iter().take(1) {
        if fan.rpm.available {
            parts.push(format!("{} {}rpm", fan.label, fan.rpm.value as u32));
        }
    }
    if sample.sensors.system_watts.available {
        parts.push(format!("Sys {:.1}W", sample.sensors.system_watts.value));
    }
    if sample.sensors.gpu_watts.available {
        parts.push(format!("GPU {:.1}W", sample.sensors.gpu_watts.value));
    }
    Line::from(parts.join("  "))
}

fn status_line(ui: &Ui) -> Line<'static> {
    if let Some(error) = &ui.error {
        Line::from(Span::from(format!("error: {error} · q: quit")).red())
    } else if ui.sample.is_some() {
        let mut parts = Vec::new();
        if let Some(pattern) = &ui.filter {
            parts.push(format!("filter:/{pattern}"));
        }
        if let Some(user) = &ui.user_filter {
            parts.push(format!("user:{user}"));
        }
        if let Some(followed) = ui.follow {
            let name = ui
                .sample
                .as_ref()
                .and_then(|s| s.processes.iter().find(|p| p.pid == followed))
                .map_or_else(|| format!("pid {followed}"), |p| p.name.clone());
            parts.push(format!("follow:{name}"));
        }
        if ui.tree {
            parts.push("tree".to_string());
        }
        if let Some(pattern) = &ui.search {
            parts.push(format!("search:/{pattern}"));
        }
        let tagged = ui.tags.len();
        if tagged > 0 {
            parts.push(format!("tagged:{tagged}"));
        }
        if let Some(notice) = &ui.notice {
            parts.push(notice.clone());
        }
        parts.push(format!(
            "q: quit · tab: sort {} · i: reverse · f3: search · f4: filter · u: user · space: tag · j/k: select · f: follow · f5: tree · enter: fold · f9: signal · f7/f8: renice",
            sort_label(ui.sort, ui.descending)
        ));
        Line::from(parts.join(" · "))
    } else {
        Line::from("waiting for the first sample · q: quit")
    }
}

fn draw_processes(frame: &mut Frame, ui: &Ui, area: ratatui::layout::Rect) {
    // I/O columns appear only when some visible process actually moves
    // data: otherwise they are two mostly blank columns at 80 columns.
    let procs = ui.ordered_rows();
    let show_io = procs_io_visible(&procs);
    let mut header_names = vec!["PID", "USER", "STATE", "CPU%", "MEM%", "THR", "RES", "NAME"];
    if show_io {
        // Inserted before NAME, which stays the flexible last column.
        header_names.splice(7..7, ["RD/s", "WR/s"]);
    }
    let header = Row::new(header_names).bold();
    let mut rows: Vec<Row<'static>> = Vec::new();
    // Keep the cursor in view: scroll only far enough. The fold is what fits
    // under the table header (the block's top border takes one line).
    let fold = area.height.saturating_sub(2) as usize;
    let cursor_index = procs.iter().position(|r| Some(r.process.pid) == ui.cursor);
    let offset = match cursor_index {
        Some(index) if fold > 0 => index.saturating_sub(fold - 1).min(index),
        _ => 0,
    };
    for row_view in procs.iter().skip(offset).take(fold) {
        let mut row = process_row(
            row_view,
            ui.tree,
            ui.tags.contains(&row_view.process.pid),
            show_io,
        );
        if Some(row_view.process.pid) == ui.cursor {
            row = row.style(ratatui::style::Style::default().reversed());
        }
        rows.push(row);
    }
    let mut widths = vec![
        Constraint::Length(8),
        Constraint::Length(10),
        Constraint::Length(7),
        Constraint::Length(7),
        Constraint::Length(7),
        Constraint::Length(5),
        Constraint::Length(9),
    ];
    if show_io {
        widths.extend([Constraint::Length(5), Constraint::Length(5)]);
    }
    widths.push(Constraint::Min(1));
    let table = Table::new(rows, widths)
        .header(header)
        .block(Block::new().borders(Borders::TOP));
    frame.render_widget(table, area);
}

/// Whether the I/O rate columns are worth showing: at least one row in
/// the visible set moves data in either direction.
fn procs_io_visible<'a>(rows: impl IntoIterator<Item = &'a TreeRow<'a>>) -> bool {
    rows.into_iter().any(|row| {
        row.process.io.read_rate.unwrap_or(0.0) > 0.0
            || row.process.io.write_rate.unwrap_or(0.0) > 0.0
    })
}

/// One table row. Tagged processes carry a `*` before the name, htop-style.
fn process_row(row_view: &TreeRow<'_>, tree: bool, tagged: bool, show_io: bool) -> Row<'static> {
    let name = if tree {
        let indent = "  ".repeat(row_view.depth);
        let branch = if row_view.depth > 0 { "└─ " } else { "" };
        let folded = if row_view.hidden > 0 {
            format!(" (+{})", row_view.hidden)
        } else {
            String::new()
        };
        format!("{indent}{branch}{}{folded}", row_view.process.name)
    } else {
        row_view.process.name.clone()
    };
    let name = if tagged { format!("* {name}") } else { name };
    let mut cells = vec![
        Cell::from(format!("{:>7}", row_view.process.pid)),
        Cell::from(format!("{:>9}", row_view.process.user)),
        Cell::from(row_view.process.state.clone()),
        Cell::from(format!("{:>6.1}", row_view.process.cpu_percent)),
        Cell::from(format!("{:>6.1}", row_view.process.mem_percent)),
        Cell::from(format!("{:>4}", row_view.process.threads)),
        Cell::from(format!(
            "{:>8}",
            bytes_text(row_view.process.resident_bytes as f64)
        )),
    ];
    if show_io {
        cells.push(Cell::from(format!(
            "{:>5}",
            rate_text(row_view.process.io.read_rate)
        )));
        cells.push(Cell::from(format!(
            "{:>5}",
            rate_text(row_view.process.io.write_rate)
        )));
    }
    cells.push(Cell::from(name));
    Row::new(cells)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ztop_core::model::{Cpu, CpuTimes, Fan, Metric, ProcessIo, Sensors, TempSensor, Unit};

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
                io: ProcessIo::default(),
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
                gpu_watts: Metric::unavailable(Unit::Watts),
                system_watts: Metric::unavailable(Unit::Watts),
            },
        }
    }

    /// A tree sample where pid 1 (cpu 100) has children 2 (50) and 3 (33.3),
    /// and pid 2 has child 4 (25).
    fn sample_with_tree() -> Sample {
        let mut s = sample();
        for (pid, parent) in [(2u32, Some(1u32)), (3, Some(1)), (4, Some(2))] {
            s.processes[(pid - 1) as usize].parent = parent;
        }
        s
    }

    /// A sample with real I/O rates on worker-01 and totals-only data on
    /// worker-02.
    fn sample_with_io() -> Sample {
        let mut s = sample();
        s.processes[0].io = ProcessIo {
            read_bytes: Some(1_500_000),
            write_bytes: Some(300_000),
            read_rate: Some(1.5 * MIB),
            write_rate: Some(300.0 * KIB),
        };
        s.processes[1].io = ProcessIo {
            read_bytes: Some(100),
            write_bytes: Some(50),
            read_rate: Some(0.0),
            write_rate: Some(0.0),
        };
        s
    }

    /// Render through the public helper under test.
    fn render(ui: &Ui, width: u16, height: u16) -> Vec<String> {
        draw_lines(ui, width, height)
    }

    fn ui_with(sample: Option<Sample>, error: Option<String>) -> Ui {
        Ui {
            sample,
            error,
            ..Ui::new()
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
    fn the_io_columns_appear_when_a_process_moves_data() {
        let ui = ui_with(Some(sample_with_io()), None);
        let rows = render(&ui, 80, 24);
        let header_row = rows
            .iter()
            .position(|row| row.contains("RD/s") && row.contains("WR/s"))
            .expect("io header row");
        let first = &rows[header_row + 1];
        // worker-01 sorts first; its rates render compactly, read before
        // write, in the order the header promises. At 80 columns the two
        // new columns squeeze the name down to eight characters.
        assert!(first.contains("worker-0"), "{first:?}");
        assert!(first.contains("1.5Mi"), "{first:?}");
        assert!(first.contains("300Ki"), "{first:?}");
        assert!(
            first.find("1.5Mi") < first.find("300Ki"),
            "read rate should come before the write rate: {first:?}"
        );
    }

    #[test]
    fn the_io_columns_stay_hidden_without_rates() {
        // Totals alone do not open the columns: fixture replay carries
        // totals and must keep rendering exactly as before.
        let mut s = sample();
        s.processes[0].io = ProcessIo {
            read_bytes: Some(100),
            write_bytes: Some(50),
            read_rate: None,
            write_rate: None,
        };
        let ui = ui_with(Some(s), None);
        let rows = render(&ui, 80, 24);
        assert!(
            !rows.iter().any(|row| row.contains("RD/s")),
            "io columns should stay hidden: {rows:?}"
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
    fn sensors_row_applies_only_when_the_sample_has_readings() {
        let mut sample = sample();

        // Without readings the header keeps its four rows: status on row 3.
        let ui = ui_with(Some(sample.clone()), None);
        let rows = render(&ui, 80, 24);
        assert_eq!(rows.len(), 24);
        assert!(
            rows[3].contains("q: quit"),
            "status stays on row 3: {:?}",
            rows[3]
        );
        assert!(!rows[3].contains("°C"));

        // With readings a fifth header row appears between memory and status.
        sample.sensors.temps = vec![
            TempSensor {
                label: "CPU composite".to_string(),
                celsius: Metric::available(78.7, Unit::Celsius),
            },
            TempSensor {
                label: "CPU die 7".to_string(),
                celsius: Metric::available(48.5, Unit::Celsius),
            },
        ];
        sample.sensors.fans = vec![Fan {
            label: "Fan 0".to_string(),
            rpm: Metric::available(1001.0, Unit::RevolutionsPerMinute),
        }];
        sample.sensors.system_watts = Metric::available(17.0, Unit::Watts);
        sample.sensors.gpu_watts = Metric::available(0.3, Unit::Watts);
        let ui = ui_with(Some(sample), None);
        let rows = render(&ui, 80, 24);
        assert_eq!(rows.len(), 24);
        assert!(
            rows[3].starts_with("CPU composite 78.7°C"),
            "sensors row on row 3: {:?}",
            rows[3]
        );
        assert!(
            rows[3].contains("Fan 0 1001rpm"),
            "fan reading present: {:?}",
            rows[3]
        );
        assert!(
            rows[3].contains("Sys 17.0W"),
            "system power present: {:?}",
            rows[3]
        );
        assert!(
            rows[4].contains("q: quit"),
            "status moves to row 4: {:?}",
            rows[4]
        );
    }

    #[test]
    fn the_name_filter_narrows_and_the_status_shows_it() {
        let mut ui = ui_with(Some(sample()), None);
        ui.toggle_filter();
        for c in "worker-01".chars() {
            ui.filter_push(c);
        }
        let rows = render(&ui, 80, 24);
        assert!(rows.iter().any(|row| row.contains("worker-01")));
        assert!(!rows.iter().any(|row| row.contains("worker-02")));
        assert!(
            rows.iter().any(|row| row.contains("filter:/worker-01")),
            "status shows the pattern: {:?}",
            rows.iter().find(|row| row.contains("tab: sort"))
        );

        // Erasing characters widens the match again.
        for _ in 0..6 {
            ui.filter_pop();
        }
        let rows = render(&ui, 80, 24);
        assert!(rows.iter().any(|row| row.contains("worker-02")));
        assert!(rows.iter().any(|row| row.contains("filter:/wor")));

        // Closing the prompt discards the pattern entirely.
        ui.close_filter();
        let rows = render(&ui, 80, 24);
        assert!(rows.iter().any(|row| row.contains("worker-01")));
        assert!(!rows.iter().any(|row| row.contains("filter:/")));
    }

    #[test]
    fn the_user_filter_cycles_through_the_sample_users() {
        let mut sample = sample();
        sample.processes[0].user = "bob".to_string(); // worker-01 -> bob
        let mut ui = ui_with(Some(sample), None);

        // All users first.
        let rows = render(&ui, 80, 24);
        assert!(rows.iter().any(|row| row.contains("worker-01")));
        assert!(rows.iter().any(|row| row.contains("worker-02")));
        assert!(!rows.iter().any(|row| row.contains("user:")));

        // alice: bob's process is hidden.
        ui.cycle_user_filter();
        let rows = render(&ui, 80, 24);
        assert!(!rows.iter().any(|row| row.contains("worker-01")));
        assert!(rows.iter().any(|row| row.contains("worker-02")));
        assert!(rows.iter().any(|row| row.contains("user:alice")));

        // bob: only worker-01 remains.
        ui.cycle_user_filter();
        let rows = render(&ui, 80, 24);
        assert!(rows.iter().any(|row| row.contains("worker-01")));
        assert!(!rows.iter().any(|row| row.contains("worker-02")));
        assert!(rows.iter().any(|row| row.contains("user:bob")));

        // Past the last user wraps back to all.
        ui.cycle_user_filter();
        let rows = render(&ui, 80, 24);
        assert!(rows.iter().any(|row| row.contains("worker-01")));
        assert!(rows.iter().any(|row| row.contains("worker-02")));
    }

    #[test]
    fn the_thread_column_sits_between_memory_and_resident() {
        let ui = ui_with(Some(sample()), None);
        let rows = render(&ui, 80, 24);
        let header_row = rows
            .iter()
            .position(|row| row.contains("PID"))
            .expect("table header");
        let header = &rows[header_row];
        let mem = header.find("MEM%").expect("MEM% header");
        let thr = header.find("THR").expect("THR header");
        let res = header.find("RES").expect("RES header");
        assert!(mem < thr && thr < res, "column order in {header:?}");
    }

    #[test]
    fn j_and_k_move_the_cursor_over_visible_rows() {
        let mut ui = ui_with(Some(sample()), None);

        // No cursor until the first key press; then the first visible row
        // (cpu desc: worker-01 has the highest cpu).
        let rows = render(&ui, 80, 24);
        assert!(rows.iter().any(|row| row.contains("worker-12")));
        ui.select_next();
        assert_eq!(ui.cursor, Some(1));

        // Down twice more lands on worker-03; up once walks back.
        ui.select_next();
        ui.select_next();
        assert_eq!(ui.cursor, Some(3));
        ui.select_prev();
        assert_eq!(ui.cursor, Some(2));

        // The top row stops the cursor; it never wraps.
        for _ in 0..12 {
            ui.select_prev();
        }
        assert_eq!(ui.cursor, Some(1));
    }

    #[test]
    fn follow_reselects_the_pid_after_apply() {
        let mut ui = ui_with(Some(sample()), None);
        ui.select_next();
        ui.select_next(); // cursor on pid 2 (second row, cpu desc)
        ui.toggle_follow();
        assert_eq!(ui.follow, Some(2));

        // A fresh sample in which pid 2 sinks to the bottom of the cpu order
        // still leaves the cursor on it.
        let mut next = sample();
        for process in &mut next.processes {
            if process.pid == 2 {
                process.cpu_percent = 0.1;
            }
        }
        ui.apply(Ok(next));
        assert_eq!(ui.cursor, Some(2));
        assert_eq!(ui.follow, Some(2));

        // Moving the cursor while following re-pins follow to the new row
        // (one row up from the bottom of the new order is pid 12).
        ui.select_prev();
        assert_eq!(ui.follow, Some(12));
    }

    #[test]
    fn follow_ends_when_the_process_vanishes() {
        let mut ui = ui_with(Some(sample()), None);
        ui.select_next();
        ui.toggle_follow();
        assert_eq!(ui.follow, Some(1));

        let mut next = sample();
        next.processes.retain(|p| p.pid != 1);
        ui.apply(Ok(next));
        assert_eq!(ui.follow, None);
        assert_eq!(ui.cursor, None);
    }

    #[test]
    fn a_plain_cursor_keeps_its_pid_and_dies_with_it() {
        let mut ui = ui_with(Some(sample()), None);
        for _ in 0..5 {
            ui.select_next();
        }
        assert_eq!(ui.cursor, Some(5));

        // Same pid in a new sample keeps the cursor despite reordering.
        let mut next = sample();
        for process in &mut next.processes {
            if process.pid == 5 {
                process.cpu_percent = 0.0;
            }
        }
        ui.apply(Ok(next));
        assert_eq!(ui.cursor, Some(5));
        assert_eq!(ui.follow, None);

        // The pid vanishing clears the cursor but never starts follow.
        let mut gone = sample();
        gone.processes.retain(|p| p.pid != 5);
        ui.apply(Ok(gone));
        assert_eq!(ui.cursor, None);
        assert_eq!(ui.follow, None);
    }

    #[test]
    fn the_cursor_scrolls_to_stay_visible() {
        let mut ui = ui_with(Some(sample()), None);
        // Walk deep into the table; the fold at 80x10 is 4 process rows.
        for _ in 0..8 {
            ui.select_next();
        }
        assert_eq!(ui.cursor, Some(8)); // worker-08
        let rows = render(&ui, 80, 10);
        assert!(rows.iter().any(|row| row.contains("worker-08")));
        assert!(
            !rows.iter().any(|row| row.contains("worker-01")),
            "the top of the list scrolled away"
        );
        assert!(rows.iter().any(|row| row.contains("worker-05")));
        assert!(
            rows.iter().any(|row| row.contains("PID")),
            "the table header stays visible"
        );
    }

    #[test]
    fn tree_groups_children_under_their_parents() {
        let mut s = sample();
        for (pid, parent) in [(2u32, Some(1u32)), (3, Some(1)), (4, Some(2))] {
            s.processes[(pid - 1) as usize].parent = parent;
        }
        let ui = ui_with(Some(s), None);
        // Flat mode is unchanged by the parent links.
        let flat: Vec<u32> = ui.ordered_rows().iter().map(|r| r.process.pid).collect();
        assert_eq!(flat, vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
        let mut tree_ui = ui_with(Some(sample_with_tree()), None);
        tree_ui.toggle_tree();
        let rows = tree_ui.ordered_rows();
        let pids: Vec<u32> = rows.iter().map(|r| r.process.pid).collect();
        // worker-01 (cpu 100) roots the tree; its children 2 and 3 follow in
        // sort order, 4 nests under 2, then the other roots.
        assert_eq!(pids, vec![1, 2, 4, 3, 5, 6, 7, 8, 9, 10, 11, 12]);
        let depths: Vec<usize> = rows.iter().map(|r| r.depth).collect();
        assert_eq!(depths, vec![0, 1, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0]);
    }

    #[test]
    fn a_fold_hides_the_subtree_and_reports_the_count() {
        let mut ui = ui_with(Some(sample_with_tree()), None);
        ui.toggle_tree();
        ui.cursor = Some(1);
        ui.toggle_collapse();
        assert_eq!(ui.collapsed, std::iter::once(1).collect());
        let rows = ui.ordered_rows();
        assert_eq!(rows.len(), 9, "three descendants fold away");
        assert_eq!(rows[0].process.pid, 1);
        assert_eq!(rows[0].hidden, 3);
        assert_eq!(rows[1].process.pid, 5);
        // Unfolding brings the whole subtree back.
        ui.toggle_collapse();
        assert!(ui.collapsed.is_empty());
        assert_eq!(ui.ordered_rows().len(), 12);
    }

    #[test]
    fn folding_needs_a_cursor_with_children() {
        let mut ui = ui_with(Some(sample_with_tree()), None);
        ui.toggle_tree();
        // No cursor: nothing to fold.
        ui.toggle_collapse();
        assert!(ui.collapsed.is_empty());
        // worker-05 has no visible children: nothing to fold either.
        ui.cursor = Some(5);
        ui.toggle_collapse();
        assert!(ui.collapsed.is_empty());
    }

    #[test]
    fn the_tree_render_indents_and_marks_folds() {
        let mut ui = ui_with(Some(sample_with_tree()), None);
        ui.toggle_tree();
        ui.cursor = Some(1);
        ui.toggle_collapse();
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter().any(|row| row.contains("worker-01 (+3)")),
            "the folded row reports its hidden descendants: {rows:?}"
        );
        assert!(
            !rows.iter().any(|row| row.contains("worker-02")),
            "folded descendants stay hidden"
        );
        // Unfold and check the indent prefix on a grandchild.
        ui.toggle_collapse();
        let rows = render(&ui, 80, 24);
        assert!(rows.iter().any(|row| row.contains("└─ worker-04")));
        assert!(rows.iter().any(|row| row.contains("└─ worker-02")));
    }

    #[test]
    fn f3_search_jumps_to_the_next_name_match() {
        let mut ui = ui_with(Some(sample()), None);
        ui.toggle_search();
        for c in "07".chars() {
            ui.search_push(c);
        }
        assert_eq!(ui.cursor, Some(7), "the first match of \"07\" is worker-07");
        // Closing keeps the cursor where the search left it.
        ui.close_search();
        assert_eq!(ui.cursor, Some(7));
        assert!(ui.search.is_none());
        // A wider pattern keeps the cursor while its row still matches.
        ui.toggle_search();
        for c in "wor".chars() {
            ui.search_push(c);
        }
        assert_eq!(ui.cursor, Some(7));
        // F3 again moves to the next match after the cursor.
        ui.search_next();
        assert_eq!(ui.cursor, Some(8), "the next worker after 7 is worker-08");
        // A pattern with no match leaves the cursor alone; backspacing back
        // to a matching pattern re-finds the current row.
        ui.search_push('z');
        assert_eq!(ui.cursor, Some(8));
        let status = status_line(&ui).to_string();
        assert!(status.contains("search:/worz"), "status: {status}");
        ui.search_pop();
        assert_eq!(ui.cursor, Some(8));
    }

    #[test]
    fn the_search_repins_follow() {
        let mut ui = ui_with(Some(sample()), None);
        ui.toggle_search();
        for c in "02".chars() {
            ui.search_push(c);
        }
        assert_eq!(ui.cursor, Some(2));
        ui.toggle_follow();
        // Re-open with a fresh pattern: the jump drags follow along.
        ui.close_search();
        ui.toggle_search();
        for c in "05".chars() {
            ui.search_push(c);
        }
        assert_eq!(ui.cursor, Some(5));
        assert_eq!(ui.follow, Some(5), "follow re-pins to the searched pid");
    }

    #[test]
    fn space_tags_the_cursor_and_u_clears_all() {
        let mut ui = ui_with(Some(sample()), None);
        ui.cursor = Some(2);
        ui.toggle_tag();
        assert_eq!(ui.tags.len(), 1);
        assert!(ui.tags.contains(&2));
        // Tagged rows carry a `*` before the name; the status line counts.
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter().any(|row| row.contains("* worker-02")),
            "the tagged row shows a star: {rows:?}"
        );
        assert!(
            !rows.iter().any(|row| row.contains("* worker-03")),
            "untagged rows stay clean: {rows:?}"
        );
        let status = status_line(&ui).to_string();
        assert!(status.contains("tagged:1"), "status: {status}");
        // Space again untags; tags survive a fresh sample.
        ui.toggle_tag();
        assert!(ui.tags.is_empty());
        ui.toggle_tag();
        ui.cursor = Some(3);
        ui.toggle_tag();
        ui.apply(Ok(sample()));
        assert_eq!(ui.tags.len(), 2);
        // `U` clears every tag at once.
        ui.untag_all();
        assert!(ui.tags.is_empty());
        // Space without a cursor is a no-op.
        ui.cursor = None;
        ui.toggle_tag();
        assert!(ui.tags.is_empty());
    }

    #[test]
    fn c_tags_the_visible_descendants() {
        let mut ui = ui_with(Some(sample_with_tree()), None);
        ui.toggle_tree();
        ui.cursor = Some(1);
        ui.tag_children();
        // Children 2 and 3 plus grandchild 4 — but not the cursor itself.
        assert!(ui.tags.contains(&2));
        assert!(ui.tags.contains(&3));
        assert!(ui.tags.contains(&4));
        assert!(!ui.tags.contains(&1));
        assert_eq!(ui.tags.len(), 3);
        // Tagged descendants show the marker; the untagged root does not.
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter().any(|row| row.contains("*   └─ worker-02")),
            "the tagged child shows a star: {rows:?}"
        );
        assert!(
            rows.iter()
                .any(|row| row.contains("worker-01") && !row.contains('*')),
            "the root stays untagged: {rows:?}"
        );
        // `c` without a cursor does nothing.
        let mut empty = ui_with(Some(sample()), None);
        empty.tag_children();
        assert!(empty.tags.is_empty());
    }

    #[test]
    fn the_signal_menu_targets_the_tag_set_or_the_cursor() {
        let mut ui = ui_with(Some(sample()), None);
        // Nothing tagged and nothing selected: the menu stays closed.
        ui.open_menu();
        assert!(ui.menu.is_none());
        // Opening over a process offers the signals from the top.
        ui.cursor = Some(4);
        ui.open_menu();
        assert_eq!(ui.menu, Some(0));
        // Enter turns the selection into a plan over the cursor's process.
        ui.menu_next();
        ui.menu_next();
        assert_eq!(ui.menu, Some(2));
        let plan = ui.confirm_menu().expect("plan");
        assert_eq!(plan.pids, vec![4]);
        assert_eq!(plan.action, Control::Signal(3), "the third entry is QUIT");
        assert!(ui.menu.is_none(), "Enter closes the menu");
        // The tag set takes over from the cursor, in pid order.
        ui.tags.insert(2);
        ui.tags.insert(3);
        ui.open_menu();
        let plan = ui.confirm_menu().expect("plan");
        assert_eq!(plan.pids, vec![2, 3]);
    }

    #[test]
    fn the_menu_wraps_and_cancels() {
        let mut ui = ui_with(Some(sample()), None);
        ui.cursor = Some(1);
        ui.open_menu();
        let count = control::common_signals().len();
        ui.menu_prev();
        assert_eq!(ui.menu, Some(count - 1), "wraps upward");
        ui.menu_next();
        assert_eq!(ui.menu, Some(0), "wraps back down");
        ui.close_menu();
        assert!(ui.confirm_menu().is_none(), "a closed menu never acts");
    }

    #[test]
    fn renice_plans_target_the_tags_or_the_cursor() {
        let mut ui = ui_with(Some(sample()), None);
        assert!(ui.renice_plan(-1).is_none(), "no target, no plan");
        ui.cursor = Some(4);
        assert_eq!(
            ui.renice_plan(-1),
            Some(Plan {
                pids: vec![4],
                action: Control::Renice(-1),
            })
        );
        // The tag set wins over the cursor, in pid order.
        ui.tags.insert(3);
        ui.tags.insert(2);
        assert_eq!(
            ui.renice_plan(1),
            Some(Plan {
                pids: vec![2, 3],
                action: Control::Renice(1),
            })
        );
    }

    #[test]
    fn a_plan_reports_its_outcome_in_the_notice() {
        let mut ui = ui_with(Some(sample()), None);
        // Signal 0 performs the permission check but sends nothing, so the
        // real plan path runs without disturbing anything.
        run_plan(
            &mut ui,
            &Plan {
                pids: vec![std::process::id()],
                action: Control::Signal(0),
            },
        );
        let notice = ui.notice.clone().expect("notice");
        assert!(notice.contains("signal SIG0"), "{notice}");
        assert!(notice.contains("1 pid(s)"), "{notice}");
        // A pid that cannot be acted on is reported with the first failure.
        run_plan(
            &mut ui,
            &Plan {
                pids: vec![399_999_999],
                action: Control::Renice(-1),
            },
        );
        let notice = ui.notice.clone().expect("notice");
        assert!(notice.contains("renice -1"), "{notice}");
        assert!(notice.contains("0 ok, 1 failed"), "{notice}");
        // The notice clears with the next sample.
        ui.apply(Ok(sample()));
        assert!(ui.notice.is_none());
    }

    #[test]
    fn the_menu_renders_as_a_centered_popup() {
        let mut ui = ui_with(Some(sample()), None);
        ui.cursor = Some(1);
        ui.menu = Some(5);
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter().any(|row| row.contains("Send signal")),
            "the popup title shows: {rows:?}"
        );
        assert!(
            rows.iter().any(|row| row.contains("> TERM")),
            "the selection marker shows: {rows:?}"
        );
        assert!(
            rows.iter().any(|row| row.contains("  KILL (9)")),
            "unselected rows keep the two-space indent: {rows:?}"
        );
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
        // A second frame with a cursor and follow mode active.
        let mut ui = ui_with(Some(sample()), None);
        for _ in 0..5 {
            ui.select_next();
        }
        ui.toggle_follow();
        ui.toggle_filter();
        for c in "wor".chars() {
            ui.filter_push(c);
        }
        println!("---- cursor on pid 5, follow on, filter prompt open ----");
        for (index, row) in render(&ui, 80, 24).iter().enumerate() {
            println!("{index:2}|{row}");
        }
        // A third frame with the signal menu open over two tagged processes.
        let mut ui = ui_with(Some(sample()), None);
        ui.tags.insert(4);
        ui.tags.insert(5);
        ui.open_menu();
        for _ in 0..4 {
            ui.menu_next();
        }
        println!("---- tags on 4+5, signal menu open, KILL selected ----");
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
