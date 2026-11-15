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
use ratatui::crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEvent, KeyEventKind,
    KeyModifiers, MouseButton, MouseEventKind,
};
use ratatui::crossterm::execute;
use ratatui::crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, Gauge, Paragraph, Row, Table};

use ztop_core::collector::{CollectError, Collector};
use ztop_core::control::{self, Control, Plan};
use ztop_core::model::{Memory, Metric, Process, Sample, Unit};

mod config;
pub use config::{Config, Theme};

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
    Virtual,
    Shared,
    Priority,
    Nice,
    TotalTime,
    Start,
    Processor,
    Parent,
    Name,
    Command,
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
        SortKey::Virtual => "virt",
        SortKey::Shared => "shr",
        SortKey::Priority => "pri",
        SortKey::Nice => "nice",
        SortKey::TotalTime => "time",
        SortKey::Start => "start",
        SortKey::Processor => "cpu-core",
        SortKey::Parent => "ppid",
        SortKey::Name => "name",
        SortKey::Command => "command",
    };
    format!("{name}{}", if descending { " ↓" } else { " ↑" })
}

/// Which screen the UI shows. The process table is the default; the Apple
/// Silicon screen (`a`) shows chip, power and cluster metrics that only make
/// sense on Apple Silicon Macs, and the setup screen (F2) edits the options
/// that are saved to the config file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Screen {
    ProcessTable,
    AppleSilicon,
    Disk,
    Network,
    Thermal,
    Setup,
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
    /// Pids passed with `ztop -p`. An empty set lists every process; a
    /// non-empty set hides every process whose pid is not in it.
    pub pid_filter: std::collections::BTreeSet<u32>,
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
    /// Which screen is showing (process table, Apple Silicon or setup).
    pub screen: Screen,
    /// The saved setup: theme and display options, edited on the setup
    /// screen (F2) and saved to the config file when it closes.
    pub config: Config,
    /// The setup screen's selected row.
    pub setup_select: usize,
    /// Where the setup screen (F2) returns to when it closes.
    pub setup_return: Screen,
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
            pid_filter: std::collections::BTreeSet::new(),
            cursor: None,
            follow: None,
            tree: false,
            collapsed: std::collections::BTreeSet::new(),
            search: None,
            tags: std::collections::BTreeSet::new(),
            menu: None,
            notice: None,
            screen: Screen::ProcessTable,
            config: Config::default(),
            setup_select: 0,
            setup_return: Screen::ProcessTable,
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
            SortKey::Resident => SortKey::Virtual,
            SortKey::Virtual => SortKey::Shared,
            SortKey::Shared => SortKey::Nice,
            SortKey::Nice => SortKey::TotalTime,
            SortKey::TotalTime => SortKey::Start,
            SortKey::Start => SortKey::Processor,
            SortKey::Processor => SortKey::Parent,
            SortKey::Parent => SortKey::Priority,
            SortKey::Priority => SortKey::Name,
            SortKey::Name => SortKey::Command,
            SortKey::Command => SortKey::Pid,
        };
    }

    /// Flip between ascending and descending order.
    pub fn toggle_direction(&mut self) {
        self.descending = !self.descending;
    }

    /// Switch to the Apple Silicon screen, or back to the process table
    /// when already on it.
    ///
    /// The screen state is per-view, so each keeps its own settings.
    pub fn toggle_screen(&mut self) {
        self.goto_screen(Screen::AppleSilicon);
    }

    /// Switch to one of the extra screens, or back to the process table
    /// when the screen is already showing: every screen key (`a`, `d`,
    /// `n`, `t`) is an absolute address and a second press returns.
    ///
    /// The setup screen consumes every key and holds until it is finished,
    /// so it cannot be toggled away.
    pub fn goto_screen(&mut self, screen: Screen) {
        if self.screen == Screen::Setup {
            return;
        }
        self.screen = if self.screen == screen {
            Screen::ProcessTable
        } else {
            screen
        };
    }

    /// Build the UI with a saved setup loaded from the config file: the
    /// theme comes from it, and so does the tree view's initial state.
    pub fn with_config(config: Config) -> Self {
        Self {
            config: config.clone(),
            tree: config.start_in_tree,
            ..Default::default()
        }
    }

    /// Open the setup screen (F2), remembering where to return to.
    pub fn open_setup(&mut self) {
        self.setup_return = self.screen;
        self.screen = Screen::Setup;
    }

    /// Leave the setup screen and put the save outcome in the status line,
    /// where it stays until the next sample arrives.
    fn finish_setup(&mut self, result: io::Result<std::path::PathBuf>) {
        self.screen = self.setup_return;
        self.notice = Some(match result {
            Ok(path) => format!("Setup saved to {}", config::display_path(&path)),
            Err(err) => format!("Setup save failed: {err}"),
        });
    }

    /// The setup screen's row count, for the wrapping navigation.
    const SETUP_ROWS: usize = 2;

    /// Move the setup selection down, wrapping at the end.
    pub fn setup_next(&mut self) {
        self.setup_select = (self.setup_select + 1) % Self::SETUP_ROWS;
    }

    /// Move the setup selection up, wrapping at the top.
    pub fn setup_prev(&mut self) {
        self.setup_select = (self.setup_select + Self::SETUP_ROWS - 1) % Self::SETUP_ROWS;
    }

    /// Toggle the selected setup option.
    pub fn setup_toggle(&mut self) {
        match self.setup_select {
            0 => {
                self.config.theme = match self.config.theme {
                    Theme::Color => Theme::Mono,
                    Theme::Mono => Theme::Color,
                }
            }
            1 => self.config.start_in_tree = !self.config.start_in_tree,
            _ => {}
        }
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
        if !self.pid_filter.is_empty() && !self.pid_filter.contains(&process.pid) {
            return false;
        }
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
            SortKey::Virtual => a.virtual_bytes.cmp(&b.virtual_bytes),
            SortKey::Shared => a.shared_bytes.cmp(&b.shared_bytes),
            SortKey::Priority => a.priority.cmp(&b.priority),
            SortKey::Nice => a.nice.cmp(&b.nice),
            SortKey::TotalTime => a.total_time_ns.cmp(&b.total_time_ns),
            SortKey::Start => a.start_time_secs.cmp(&b.start_time_secs),
            SortKey::Processor => a.processor.cmp(&b.processor),
            SortKey::Parent => a.parent.cmp(&b.parent),
            SortKey::Name => a.name.cmp(&b.name),
            // The command falls back to the short name, the same text the
            // NAME column shows when no command line was recorded.
            SortKey::Command => a
                .command
                .clone()
                .unwrap_or_else(|| a.name.clone())
                .cmp(&b.command.clone().unwrap_or_else(|| b.name.clone())),
        };
        if self.descending { ord.reverse() } else { ord }
    }

    /// Sort by one key directly (a mouse click on the header): clicking
    /// the key already sorting flips the direction, otherwise the new key
    /// starts descending like the default sort.
    pub fn sort_by(&mut self, key: SortKey) {
        if self.sort == key {
            self.toggle_direction();
        } else {
            self.sort = key;
            self.descending = true;
        }
    }

    /// Select the process on visible row `index` (0 = the first visible
    /// row); a click past the last row leaves the cursor where it is.
    pub fn select_visible_row(&mut self, index: usize) {
        let pid = self.ordered_rows().get(index).map(|row| row.process.pid);
        if let Some(pid) = pid {
            self.cursor = Some(pid);
        }
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
/// `pids` is the `ztop -p` list: when it is not empty, the table lists only
/// those processes.
///
/// Returns when the user presses `q`, `Esc` or `Ctrl-C`; terminal state is
/// restored even when drawing or sampling fails.
pub fn run(collector: &mut dyn Collector, pids: &[u32], config: Config) -> io::Result<()> {
    enable_raw_mode()?;
    let result = run_inner(collector, pids, config);
    restore()?;
    result
}

fn run_inner(collector: &mut dyn Collector, pids: &[u32], config: Config) -> io::Result<()> {
    execute!(io::stdout(), EnterAlternateScreen, EnableMouseCapture)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(io::stdout()))?;
    let result = event_loop(&mut terminal, collector, pids, config);
    execute!(io::stdout(), LeaveAlternateScreen, DisableMouseCapture)?;
    result
}

fn restore() -> io::Result<()> {
    disable_raw_mode()?;
    execute!(io::stdout(), LeaveAlternateScreen, DisableMouseCapture)?;
    Ok(())
}

/// Drive the state with one pressed key; true when the key quits.
///
/// Both the keyboard and the mouse feed this: a click on a function-bar
/// hint is replayed as the key press its label names, so the two paths
/// stay one code path.
fn handle_key(ui: &mut Ui, key: KeyEvent) -> bool {
    match key.code {
        // Ctrl-C always quits, even while typing a filter.
        KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => return true,
        // While the setup screen (F2) is open the keys drive
        // it: Esc/F2 close it (saving), j/k move, Space or
        // Enter toggle the selected option; everything else
        // — including the table keys — does nothing.
        KeyCode::Esc if ui.screen == Screen::Setup => {
            ui.finish_setup(ui.config.save());
        }
        KeyCode::F(2) if ui.screen == Screen::Setup => {
            ui.finish_setup(ui.config.save());
        }
        KeyCode::Char('j') | KeyCode::Down if ui.screen == Screen::Setup => {
            ui.setup_next();
        }
        KeyCode::Char('k') | KeyCode::Up if ui.screen == Screen::Setup => {
            ui.setup_prev();
        }
        KeyCode::Enter | KeyCode::Char(' ') if ui.screen == Screen::Setup => {
            ui.setup_toggle();
        }
        _ if ui.screen == Screen::Setup => {}
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
                run_plan(ui, &plan);
            }
        }
        _ if ui.menu.is_some() => {}
        KeyCode::Char('q') | KeyCode::Esc => return true,
        // `a` flips between the process table and the Apple
        // Silicon screen; on the silicon screen the table
        // keys have no meaning, so they do nothing.
        // `a`, `d`, `n` and `t` each address one extra screen; a second
        // press returns to the process table.
        KeyCode::Char('a') => ui.goto_screen(Screen::AppleSilicon),
        KeyCode::Char('d') => ui.goto_screen(Screen::Disk),
        KeyCode::Char('n') => ui.goto_screen(Screen::Network),
        KeyCode::Char('t') => ui.goto_screen(Screen::Thermal),
        // F2 opens the setup screen from any sample screen.
        KeyCode::F(2) if ui.screen != Screen::Setup => ui.open_setup(),
        // On the extra screens the table keys have no meaning, so they
        // do nothing.
        _ if ui.screen != Screen::ProcessTable => {}
        KeyCode::Char('i') => ui.toggle_direction(),
        // htop's M/P/T sort shortcuts; uppercase like `K` (decision 0012),
        // since lowercase `t` opens the thermal screen.
        KeyCode::Char('M') => ui.sort_by(SortKey::Mem),
        KeyCode::Char('P') => ui.sort_by(SortKey::Cpu),
        KeyCode::Char('T') => ui.sort_by(SortKey::TotalTime),
        KeyCode::F(3) => ui.toggle_search(),
        KeyCode::F(4) => ui.toggle_filter(),
        KeyCode::Char('u') => ui.cycle_user_filter(),
        KeyCode::Char(' ') => ui.toggle_tag(),
        KeyCode::Char('c') => ui.tag_children(),
        KeyCode::Char('U') => ui.untag_all(),
        KeyCode::F(9) | KeyCode::Char('K') => ui.open_menu(),
        KeyCode::F(7) => {
            if let Some(plan) = ui.renice_plan(-1) {
                run_plan(ui, &plan);
            }
        }
        KeyCode::F(8) => {
            if let Some(plan) = ui.renice_plan(1) {
                run_plan(ui, &plan);
            }
        }
        KeyCode::Char('f') | KeyCode::Char('F') => ui.toggle_follow(),
        KeyCode::F(5) => ui.toggle_tree(),
        KeyCode::Enter => ui.toggle_collapse(),
        KeyCode::Char('j') | KeyCode::Down => ui.select_next(),
        KeyCode::Char('k') | KeyCode::Up => ui.select_prev(),
        _ => {}
    }
    false
}

fn event_loop(
    terminal: &mut Tui,
    collector: &mut dyn Collector,
    pids: &[u32],
    config: Config,
) -> io::Result<()> {
    let mut ui = Ui::with_config(config);
    ui.pid_filter = pids.iter().copied().collect();
    ui.apply(collector.sample());
    loop {
        let area = terminal.draw(|frame| draw(frame, &ui))?.area;
        if event::poll(REFRESH)? {
            let event = event::read()?;
            if let Event::Key(key) = event {
                if key.kind == KeyEventKind::Press && handle_key(&mut ui, key) {
                    return Ok(());
                }
            } else if let Event::Mouse(mouse) = event {
                if let Some(key) = handle_mouse(&mut ui, mouse.kind, mouse.column, mouse.row, area)
                {
                    if handle_key(&mut ui, key) {
                        return Ok(());
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
    if ui.screen == Screen::Setup {
        draw_setup(frame, ui, frame.area());
        return;
    }
    if ui.screen == Screen::AppleSilicon {
        draw_silicon(frame, ui, frame.area());
        if ui.menu.is_some() {
            draw_menu(frame, ui, frame.area());
        }
        return;
    }
    if ui.screen == Screen::Disk {
        draw_disks(frame, ui, frame.area());
        return;
    }
    if ui.screen == Screen::Network {
        draw_network(frame, ui, frame.area());
        return;
    }
    if ui.screen == Screen::Thermal {
        draw_thermal(frame, ui, frame.area());
        return;
    }
    let (header_area, table_area) = split_table_area(ui, frame.area());
    draw_header(frame, ui, header_area);
    draw_processes(frame, ui, table_area);
    if ui.menu.is_some() {
        draw_menu(frame, ui, frame.area());
    }
}

/// One `label     value` row for the Apple Silicon screen.
fn kv(label: &str, value: String) -> Line<'static> {
    Line::from(vec![
        Span::from(format!("{label:<10}")).bold(),
        Span::raw(value),
    ])
}

/// The Apple Silicon screen: chip identity, core counts, memory and power,
/// plus a whole-system power-history chart.
///
/// Sources the unprivileged collector cannot read (cluster utilization and
/// frequency, CPU/ANE power, GPU busy) render as an explicit gap line
/// instead of fake zeros (decision 0013).
fn draw_silicon(frame: &mut Frame, ui: &Ui, area: ratatui::layout::Rect) {
    use ratatui::symbols::Marker;
    use ratatui::widgets::{Axis, Block, Chart, Dataset, GraphType, Paragraph};
    let titled = |title: &'static str| Block::default().borders(Borders::ALL).title(title);
    let Some(sample) = ui.sample.as_ref() else {
        frame.render_widget(
            Paragraph::new(vec![Line::from("no sample yet")]).block(titled("Apple Silicon")),
            area,
        );
        return;
    };
    let asil = &sample.apple_silicon;
    let Some(chip) = asil.chip_name.as_deref() else {
        let text = vec![
            Line::from("This machine is not Apple Silicon (chip name unknown)."),
            Line::from("Press a to return to the process table."),
        ];
        frame.render_widget(Paragraph::new(text).block(titled("Apple Silicon")), area);
        return;
    };

    let rows = Layout::vertical([Constraint::Length(12), Constraint::Min(1)]).split(area);

    let count = |metric: &Metric| {
        if metric.available {
            format!("{}", metric.value as u64)
        } else {
            "-".to_string()
        }
    };
    let watt = |metric: &Metric| {
        if metric.available {
            format!("{:.1} W", metric.value)
        } else {
            "-".to_string()
        }
    };
    let bytes = |used: &Metric, total: &Metric, fallback: &str| match (
        metric_bytes(used),
        metric_bytes(total),
    ) {
        (Some(used), Some(total)) if total > 0.0 => {
            format!("{} / {}", bytes_text(used), bytes_text(total))
        }
        _ => fallback.to_string(),
    };
    let logical = sample.cpu.busy_percent.len();
    let busy_mean = if logical > 0 {
        sample.cpu.busy_percent.iter().sum::<f64>() / logical as f64
    } else {
        0.0
    };
    let per_core = sample
        .cpu
        .busy_percent
        .iter()
        .map(|percent| format!("{percent:.0}%"))
        .collect::<Vec<_>>()
        .join(" ");
    let power = format!(
        "now {}  avg {}  peak {}",
        watt(&asil.current_watts),
        watt(&asil.average_watts),
        watt(&asil.peak_watts)
    );
    let info = vec![
        kv("Chip", chip.to_string()),
        kv(
            "Cores",
            format!(
                "{}P + {}E ({logical} logical, busy {busy_mean:.0}%)",
                count(&asil.p_core_count),
                count(&asil.e_core_count)
            ),
        ),
        kv(
            "Per-core",
            if per_core.is_empty() {
                "-".to_string()
            } else {
                per_core
            },
        ),
        kv(
            "Memory",
            bytes(&sample.memory.used, &sample.memory.total, "n/a"),
        ),
        kv(
            "Swap",
            bytes(
                &sample.memory.swap_used,
                &sample.memory.swap_total,
                "no swap",
            ),
        ),
        kv("Power", power),
        kv("GPU", watt(&sample.sensors.gpu_watts)),
        Line::from(""),
        Line::from("Unavailable unprivileged: CPU power, ANE power, cluster busy/frequency,"),
        Line::from("GPU busy/frequency, thermal pressure (decision 0013)"),
        Line::from(""),
        Line::from("a process table · q quit"),
    ];
    frame.render_widget(Paragraph::new(info).block(titled("Apple Silicon")), rows[0]);

    let points: Vec<(f64, f64)> = asil
        .power_history
        .iter()
        .enumerate()
        .map(|(index, point)| (index as f64, point.watts))
        .collect();
    if points.len() < 2 {
        frame.render_widget(
            Paragraph::new(vec![Line::from("collecting power history…")])
                .block(titled("Power history (W)")),
            rows[1],
        );
        return;
    }
    let peak = points
        .iter()
        .map(|(_, watts)| *watts)
        .fold(0.0_f64, f64::max);
    let chart = Chart::new(vec![
        Dataset::default()
            .marker(Marker::Braille)
            .graph_type(GraphType::Line)
            .data(&points),
    ])
    .block(titled("Power history (W)"))
    .x_axis(Axis::default().bounds([0.0, (points.len() - 1) as f64]))
    .y_axis(Axis::default().bounds([0.0, (peak * 1.2).max(1.0)]));
    frame.render_widget(chart, rows[1]);
}

/// The empty state for the data panels: an honest "nothing here" note for
/// platforms that do not report the data, plus the key back to the table.
fn panel_empty(title: &'static str, what: &str, key: char) -> Paragraph<'static> {
    Paragraph::new(vec![
        Line::from(format!("No {what} data on this host.")),
        Line::from(""),
        Line::from(format!("{key} process table · q quit")),
    ])
    .block(Block::default().borders(Borders::ALL).title(title))
}

/// The disk panel: per-disk usage and lifetime I/O counters, with rates
/// where a live collector measured them (a first sample or a fixture has
/// none, shown as `-`). macOS reports no disks today and shows the empty
/// state rather than fake zeros (decision 0009).
fn draw_disks(frame: &mut Frame, ui: &Ui, area: ratatui::layout::Rect) {
    let titled = |title: &'static str| Block::default().borders(Borders::ALL).title(title);
    let Some(sample) = ui.sample.as_ref() else {
        frame.render_widget(
            Paragraph::new(vec![Line::from("no sample yet")]).block(titled("Disks")),
            area,
        );
        return;
    };
    if sample.disks.is_empty() {
        frame.render_widget(panel_empty("Disks", "disk", 'd'), area);
        return;
    }
    let size = |bytes: u64| {
        if bytes > 0 {
            bytes_text(bytes as f64)
        } else {
            "-".to_string()
        }
    };
    let rate = |rate: Option<f64>| rate.map_or_else(|| "-".to_string(), |r| rate_text(Some(r)));
    let mut lines = vec![Line::from(
        format!(
            "{:<9} {:<11} {:>9} {:>6} {:>9} {:>6} {:>7} {:>7} {:>5}",
            "device", "mount", "read", "read/s", "write", "write/s", "size", "used", "used%"
        )
        .bold(),
    )];
    for disk in &sample.disks {
        let pct = if disk.total_bytes > 0 {
            format!("{:.1}%", disk.usage_pct)
        } else {
            "-".to_string()
        };
        lines.push(Line::from(format!(
            "{:<9} {:<11.11} {:>9} {:>6} {:>9} {:>6} {:>7} {:>7} {:>5}",
            disk.name,
            disk.mount,
            bytes_text(disk.read_bytes as f64),
            rate(disk.read_rate),
            bytes_text(disk.write_bytes as f64),
            rate(disk.write_rate),
            size(disk.total_bytes),
            size(disk.used_bytes),
            pct,
        )));
    }
    lines.push(Line::from(""));
    lines.push(Line::from("d process table · q quit"));
    frame.render_widget(Paragraph::new(lines).block(titled("Disks")), area);
}

/// The network panel: per-interface lifetime counters with rates where a
/// live collector measured them. Same empty-state rule as the disk panel.
fn draw_network(frame: &mut Frame, ui: &Ui, area: ratatui::layout::Rect) {
    let titled = |title: &'static str| Block::default().borders(Borders::ALL).title(title);
    let Some(sample) = ui.sample.as_ref() else {
        frame.render_widget(
            Paragraph::new(vec![Line::from("no sample yet")]).block(titled("Network")),
            area,
        );
        return;
    };
    if sample.net.is_empty() {
        frame.render_widget(panel_empty("Network", "network", 'n'), area);
        return;
    }
    let rate = |rate: Option<f64>| rate.map_or_else(|| "-".to_string(), |r| rate_text(Some(r)));
    let mut lines = vec![Line::from(
        format!(
            "{:<10} {:>9} {:>6} {:>9} {:>6} {:>9} {:>9}",
            "iface", "rx", "rx/s", "tx", "tx/s", "rx pkts", "tx pkts"
        )
        .bold(),
    )];
    for iface in &sample.net {
        lines.push(Line::from(format!(
            "{:<10} {:>9} {:>6} {:>9} {:>6} {:>9} {:>9}",
            iface.name,
            bytes_text(iface.rx_bytes as f64),
            rate(iface.rx_rate),
            bytes_text(iface.tx_bytes as f64),
            rate(iface.tx_rate),
            iface.rx_packets,
            iface.tx_packets,
        )));
    }
    lines.push(Line::from(""));
    lines.push(Line::from("n process table · q quit"));
    frame.render_widget(Paragraph::new(lines).block(titled("Network")), area);
}

/// The sensors panel: temperatures, fans, battery and power draw, one
/// `label value` row each. An absent reading renders as a dash, never a
/// fake zero (decision 0009).
fn draw_thermal(frame: &mut Frame, ui: &Ui, area: ratatui::layout::Rect) {
    let titled = |title: &'static str| Block::default().borders(Borders::ALL).title(title);
    let Some(sample) = ui.sample.as_ref() else {
        frame.render_widget(
            Paragraph::new(vec![Line::from("no sample yet")]).block(titled("Sensors")),
            area,
        );
        return;
    };
    let sensors = &sample.sensors;
    if sensors.temps.is_empty() && sensors.fans.is_empty() && sensors.battery.is_none() {
        frame.render_widget(panel_empty("Sensors", "temperature or fan", 't'), area);
        return;
    }
    let celsius = |metric: &Metric| {
        if metric.available {
            format!("{:.1} °C", metric.value)
        } else {
            "-".to_string()
        }
    };
    let rpm = |metric: &Metric| {
        if metric.available {
            format!("{:.0} rpm", metric.value)
        } else {
            "-".to_string()
        }
    };
    let watt = |metric: &Metric| {
        if metric.available {
            format!("{:.1} W", metric.value)
        } else {
            "-".to_string()
        }
    };
    let mut lines = vec![Line::from("Temperatures".bold())];
    if sensors.temps.is_empty() {
        lines.push(Line::from("  none reported"));
    }
    for sensor in &sensors.temps {
        lines.push(Line::from(format!(
            "  {:<12} {}",
            sensor.label,
            celsius(&sensor.celsius)
        )));
    }
    lines.push(Line::from("Fans".bold()));
    if sensors.fans.is_empty() {
        lines.push(Line::from("  none reported"));
    }
    for fan in &sensors.fans {
        lines.push(Line::from(format!("  {:<12} {}", fan.label, rpm(&fan.rpm))));
    }
    if let Some(battery) = &sensors.battery {
        lines.push(Line::from("Battery".bold()));
        lines.push(Line::from(format!(
            "  {} {} · {}",
            battery_percent_text(&battery.percent),
            battery_state_text(battery.state),
            watt(&battery.power_watts)
        )));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(format!(
        "GPU power {} · system power {}",
        watt(&sensors.gpu_watts),
        watt(&sensors.system_watts)
    )));
    lines.push(Line::from("t process table · q quit"));
    frame.render_widget(Paragraph::new(lines).block(titled("Sensors")), area);
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
    frame.render_widget(Paragraph::new(info_line(ui)), rows[3]);
    if with_sensors {
        frame.render_widget(Paragraph::new(sensors_line(ui)), rows[4]);
    }
    let status = Paragraph::new(status_line(ui));
    let status = match ui.config.theme {
        Theme::Color => status.style(Style::new().dim()),
        Theme::Mono => status,
    };
    frame.render_widget(status, rows[5]);
}

/// The setup screen (F2): the saved options, edited in place and saved to
/// the config file when the screen closes.
fn draw_setup(frame: &mut Frame, ui: &Ui, area: ratatui::layout::Rect) {
    let mut lines = vec![
        Line::from(""),
        option_row(
            ui,
            0,
            "Theme",
            match ui.config.theme {
                Theme::Color => "color",
                Theme::Mono => "mono",
            },
        ),
        option_row(
            ui,
            1,
            "Start in tree view",
            if ui.config.start_in_tree { "yes" } else { "no" },
        ),
        Line::from(""),
        Line::from("j/k move   Space/Enter toggle   Esc/F2 saves and closes"),
        Line::from(""),
    ];
    lines.push(match config::config_path() {
        Some(path) => Line::from(format!("Config file: {}", config::display_path(&path))),
        None => Line::from("Config file: none (no home directory)"),
    });
    frame.render_widget(
        Paragraph::new(lines).block(Block::default().borders(Borders::ALL).title("Setup")),
        area,
    );
}

/// One row of the setup screen; the selected one is highlighted.
fn option_row(ui: &Ui, index: usize, label: &str, value: &str) -> Line<'static> {
    let selected = ui.setup_select == index;
    let marker = if selected { '>' } else { ' ' };
    let mut line = Line::from(format!("{marker} {label:<18} {value}"));
    if selected {
        line = line.style(Style::new().reversed());
    }
    line
}

fn title_line(ui: &Ui) -> Line<'static> {
    let mut spans = vec![
        Span::from("zTop ").bold(),
        Span::from(env!("CARGO_PKG_VERSION")),
    ];
    if let Some(sample) = &ui.sample {
        spans.push(Span::from(format!(
            "  {}  up {}  {} procs{}  load {:.2} {:.2} {:.2}",
            sample.hostname,
            uptime_text(&sample.uptime),
            sample.processes.len(),
            frequency_text(sample),
            sample.load_avg[0],
            sample.load_avg[1],
            sample.load_avg[2],
        )));
    }
    Line::from(spans)
}

/// The mean CPU frequency for the title (` f 3.1 GHz`), shown when the
/// sample carries at least one core frequency.
fn frequency_text(sample: &Sample) -> String {
    let values: Vec<f64> = sample
        .cpu
        .frequency_mhz
        .iter()
        .filter(|metric| metric.available)
        .map(|metric| metric.value)
        .collect();
    if values.is_empty() {
        return String::new();
    }
    let mean = values.iter().sum::<f64>() / values.len() as f64;
    if mean >= 1000.0 {
        format!(" f {:.1} GHz", mean / 1000.0)
    } else {
        format!(" f {:.0} MHz", mean)
    }
}

/// The header's info line: the local clock, the task counts, the system
/// string and the battery — each shown only when the sample carries it.
fn info_line(ui: &Ui) -> Line<'static> {
    let Some(sample) = &ui.sample else {
        return Line::from("");
    };
    let mut spans = vec![Span::from(ztop_core::clock::local_time_text(sample.timestamp_ms)).bold()];
    spans.push(Span::from(format!(
        "  Tasks: {}, {} running",
        sample.processes.len(),
        sample
            .processes
            .iter()
            .filter(|process| process.state == "R")
            .count(),
    )));
    if sample.threads.available {
        spans.push(Span::from(format!("  {} thr", sample.threads.value as u64)));
    }
    if sample.kernel_threads.available {
        spans.push(Span::from(format!(
            "  {} kthr",
            sample.kernel_threads.value as u64
        )));
    }
    if !sample.system.is_empty() {
        spans.push(Span::from(format!("  {}", sample.system)));
    }
    if let Some(battery) = &sample.sensors.battery {
        spans.push(Span::from(format!(
            "  bat {} {}",
            battery_percent_text(&battery.percent),
            battery_state_text(battery.state),
        )));
    }
    Line::from(spans)
}

/// Battery percentage text: `NN%` or `-` when the machine reports none.
fn battery_percent_text(percent: &Metric) -> String {
    if percent.available {
        format!("{:.0}%", percent.value)
    } else {
        "-".to_string()
    }
}

/// The battery state as a word.
fn battery_state_text(state: ztop_core::model::BatteryState) -> &'static str {
    match state {
        ztop_core::model::BatteryState::Charging => "charging",
        ztop_core::model::BatteryState::Discharging => "discharging",
        ztop_core::model::BatteryState::Full => "full",
        ztop_core::model::BatteryState::Unknown => "unknown",
    }
}

fn cpu_percent_mean(sample: &Sample) -> Option<f64> {
    let busy = &sample.cpu.busy_percent;
    if busy.is_empty() {
        return None;
    }
    Some(busy.iter().sum::<f64>() / busy.len() as f64)
}

/// The style bars paint with: the theme's color, or plain in mono.
fn gauge_style(ui: &Ui, colored: Style) -> Style {
    match ui.config.theme {
        Theme::Color => colored,
        Theme::Mono => Style::new(),
    }
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
    // One wider "Avg" meter, then the per-core meters.
    let mut constraints = vec![Constraint::Length(10)];
    constraints.extend(vec![Constraint::Fill(1); percents.len()]);
    let split = Layout::horizontal(constraints).split(area);
    let mean = cpu_percent_mean(sample).unwrap_or(0.0);
    let avg = Gauge::default()
        .ratio((mean / 100.0).clamp(0.0, 1.0))
        .label(format!("Avg {:.0}%", mean))
        .gauge_style(gauge_style(ui, Style::new().green()));
    frame.render_widget(avg, split[0]);
    for (core, percent) in percents.iter().enumerate() {
        let gauge = Gauge::default()
            .ratio((*percent / 100.0).clamp(0.0, 1.0))
            .label(format!("{core} {:.0}%", percent))
            .gauge_style(gauge_style(ui, Style::new().green()));
        frame.render_widget(gauge, split[core + 1]);
    }
}

fn draw_memory_row(frame: &mut Frame, ui: &Ui, area: ratatui::layout::Rect) {
    let Some(sample) = &ui.sample else {
        return;
    };
    let halves =
        Layout::horizontal([Constraint::Percentage(60), Constraint::Percentage(40)]).split(area);
    let (ratio, label) = memory_gauge(&sample.memory, halves[0].width as usize);
    frame.render_widget(
        Gauge::default()
            .ratio(ratio)
            .label(label)
            .gauge_style(gauge_style(ui, Style::new().cyan())),
        halves[0],
    );
    let (ratio, label) = swap_gauge(&sample.memory);
    frame.render_widget(
        Gauge::default()
            .ratio(ratio)
            .label(label)
            .gauge_style(gauge_style(ui, Style::new().yellow())),
        halves[1],
    );
}

/// The memory gauge: the used/total ratio and the label for the gauge's
/// width. The breakdown joins the label only as far as the width allows
/// (keeping a few columns for the bar to show itself), so a narrow
/// terminal drops the trailing parts instead of hiding the meter.
fn memory_gauge(memory: &Memory, width: usize) -> (f64, String) {
    match (metric_bytes(&memory.used), metric_bytes(&memory.total)) {
        (Some(used), Some(total)) if total > 0.0 => {
            let mut label = format!("{} / {}", bytes_text(used), bytes_text(total));
            for part in breakdown_parts(memory) {
                let separator = if label.contains(" · ") { " " } else { " · " };
                let candidate = format!("{label}{separator}{part}");
                if candidate.chars().count() > width.saturating_sub(4) {
                    break;
                }
                label = candidate;
            }
            (used / total, label)
        }
        _ => (0.0, "n/a".to_string()),
    }
}

/// The Linux memory breakdown parts for the gauge label: buffers, shared
/// and cache, only when the platform reports them. macOS reports none, so
/// its label stays the plain used/total pair.
fn breakdown_parts(memory: &Memory) -> Vec<String> {
    [
        ("buf", metric_bytes(&memory.buffers)),
        ("shmem", metric_bytes(&memory.shared)),
        ("cache", metric_bytes(&memory.cache)),
        ("comp", metric_bytes(&memory.compressed)),
    ]
    .into_iter()
    .filter_map(|(name, bytes)| bytes.map(|value| format!("{name} {}", bytes_text(value))))
    .collect()
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

/// Total CPU time for the TIME+ column, htop-style: `M:SS.s` under an
/// hour, `H:MM:SS` above. Unavailable renders blank (column width 7).
fn time_text(total_time_ns: Option<u64>) -> String {
    let Some(ns) = total_time_ns else {
        return String::new();
    };
    let total_secs = ns / 1_000_000_000;
    let tenths = (ns / 100_000_000) % 10;
    if total_secs < 3600 {
        format!("{}:{:02}.{}", total_secs / 60, total_secs % 60, tenths)
    } else {
        format!(
            "{}:{:02}:{:02}",
            total_secs / 3_600,
            (total_secs % 3_600) / 60,
            total_secs % 60
        )
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

/// The status line's items, state first and the function-bar hints last;
/// `status_line` renders it and `status_hint_at` maps click columns back
/// to the hint labels, so the two agree on where each hint sits.
fn status_parts(ui: &Ui) -> Vec<String> {
    if let Some(error) = &ui.error {
        return vec![format!("error: {error} · q: quit")];
    }
    if ui.sample.is_none() {
        return vec!["waiting for the first sample · q: quit".to_string()];
    }
    let mut parts = Vec::new();
    if let Some(pattern) = &ui.filter {
        parts.push(format!("filter:/{pattern}"));
    }
    if let Some(user) = &ui.user_filter {
        parts.push(format!("user:{user}"));
    }
    if !ui.pid_filter.is_empty() {
        parts.push(format!("pids:{}", ui.pid_filter.len()));
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
        "q: quit · tab: sort {} · i: reverse · f3: search · f4: filter · u: user · space: tag · j/k: select · f: follow · f5: tree · enter: fold · f9: signal · f7/f8: renice · a: silicon · d: disks · n: net · t: temps",
        sort_label(ui.sort, ui.descending)
    ));
    parts
}

fn status_line(ui: &Ui) -> Line<'static> {
    let joined = status_parts(ui).join(" · ");
    if ui.error.is_some() {
        Line::from(Span::from(joined).red())
    } else {
        Line::from(joined)
    }
}

/// The key a click on the status line replays: the label the click lands
/// on names its key ("tab: sort"), while state text (filter, search,
/// tags, notices) replays nothing. The labels here and the hints in
/// `status_parts` must stay in step.
fn status_hint_at(ui: &Ui, column: u16) -> Option<KeyEvent> {
    let line = status_parts(ui).join(" · ");
    let len = line.chars().count() as u16;
    let column = column.min(len);
    let mut offset = 0;
    for item in line.split(" · ") {
        let width = item.chars().count() as u16;
        if column < offset + width {
            break;
        }
        if column < offset + width + 3 {
            return None;
        }
        offset += width + 3;
    }
    // `offset` counts characters while slicing needs a byte index: the
    // line holds multibyte characters (the sort arrow, the separators).
    let byte_at = line
        .char_indices()
        .nth(offset as usize)
        .map_or(line.len(), |(i, _)| i);
    hint_key(line[byte_at..].split_once(": ")?.0)
}

fn hint_key(label: &str) -> Option<KeyEvent> {
    let code = match label {
        "q" => KeyCode::Char('q'),
        "tab" => KeyCode::Tab,
        "i" => KeyCode::Char('i'),
        "f3" => KeyCode::F(3),
        "f4" => KeyCode::F(4),
        "u" => KeyCode::Char('u'),
        "space" => KeyCode::Char(' '),
        "j/k" => KeyCode::Char('j'),
        "f" => KeyCode::Char('f'),
        "f5" => KeyCode::F(5),
        "enter" => KeyCode::Enter,
        "f9" => KeyCode::F(9),
        "f7/f8" => KeyCode::F(7),
        "a" => KeyCode::Char('a'),
        "d" => KeyCode::Char('d'),
        "n" => KeyCode::Char('n'),
        "t" => KeyCode::Char('t'),
        _ => return None,
    };
    Some(KeyEvent::from(code))
}

/// The header meters' and the process table's areas: the table sits below
/// the header. The draw path and mouse clicks share this split, so a click
/// lands on what is on screen.
fn split_table_area(
    ui: &Ui,
    total: ratatui::layout::Rect,
) -> (ratatui::layout::Rect, ratatui::layout::Rect) {
    let header = Constraint::Length(5 + u16::from(sensors_present(ui)));
    let areas = Layout::vertical([header, Constraint::Min(1)]).split(total);
    (areas[0], areas[1])
}

fn draw_processes(frame: &mut Frame, ui: &Ui, area: ratatui::layout::Rect) {
    // I/O columns appear only when some visible process actually moves
    // data: otherwise they are two mostly blank columns at 80 columns.
    // The wide-terminal columns tier by width (see Columns::plan).
    let procs = ui.ordered_rows();
    let show_io = procs_io_visible(&procs);
    let columns = Columns::plan(area.width, show_io);
    let header = Row::new(columns.names.clone()).bold();
    let mut rows: Vec<Row<'static>> = Vec::new();
    // Keep the cursor in view: scroll only far enough. The fold is what fits
    // under the table header (the block's top border takes one line).
    let fold = area.height.saturating_sub(2) as usize;
    let cursor_index = procs.iter().position(|r| Some(r.process.pid) == ui.cursor);
    let offset = table_scroll(cursor_index, fold);
    for row_view in procs.iter().skip(offset).take(fold) {
        let mut row = process_row(
            row_view,
            ui.tree,
            ui.tags.contains(&row_view.process.pid),
            &columns,
        );
        if Some(row_view.process.pid) == ui.cursor {
            row = row.style(ratatui::style::Style::default().reversed());
        }
        rows.push(row);
    }
    let table = Table::new(rows, columns.widths)
        .header(header)
        .block(Block::new().borders(Borders::TOP));
    frame.render_widget(table, area);
}

/// The first visible row index so the cursor stays in view: scroll only
/// far enough. The draw path and mouse clicks share this, so they agree
/// on which row sits where.
fn table_scroll(cursor_index: Option<usize>, fold: usize) -> usize {
    match cursor_index {
        Some(index) if fold > 0 => index.saturating_sub(fold - 1).min(index),
        _ => 0,
    }
}

/// Whether the I/O rate columns are worth showing: at least one row in
/// the visible set moves data in either direction.
fn procs_io_visible<'a>(rows: impl IntoIterator<Item = &'a TreeRow<'a>>) -> bool {
    rows.into_iter().any(|row| {
        row.process.io.read_rate.unwrap_or(0.0) > 0.0
            || row.process.io.write_rate.unwrap_or(0.0) > 0.0
    })
}

/// The process table's columns for one draw: which columns show, their
/// widths and the sort key each header sorts by. The draw path, the row
/// cells and the click map all read this one plan, so a click always
/// lands on the column it points at.
///
/// Columns tier by terminal width so 80-column layouts keep NAME legible
/// and the recorded snapshots stay stable: the base columns at any width,
/// START and the last processor from 100 columns, VIRT and SHR from 120,
/// PPID from 140. The I/O rate columns join whenever a visible process
/// moves data, just before NAME.
struct Columns {
    /// Header labels in draw order, NAME last.
    names: Vec<&'static str>,
    /// Column widths in the same order, NAME the flexible remainder.
    widths: Vec<Constraint>,
    /// Sort key per column, None where the column does not sort (state,
    /// threads, the I/O rates).
    keys: Vec<Option<SortKey>>,
}

impl Columns {
    fn plan(area_width: u16, show_io: bool) -> Self {
        let mut names: Vec<&'static str> = vec![
            "PID", "USER", "STATE", "CPU%", "MEM%", "THR", "RES", "NICE", "TIME+",
        ];
        let mut keys: Vec<Option<SortKey>> = vec![
            Some(SortKey::Pid),
            Some(SortKey::User),
            None,
            Some(SortKey::Cpu),
            Some(SortKey::Mem),
            None,
            Some(SortKey::Resident),
            Some(SortKey::Nice),
            Some(SortKey::TotalTime),
        ];
        let mut widths: Vec<Constraint> = vec![
            Constraint::Length(7),
            Constraint::Length(7),
            Constraint::Length(5),
            Constraint::Length(5),
            Constraint::Length(5),
            Constraint::Length(3),
            Constraint::Length(8),
            Constraint::Length(4),
            Constraint::Length(7),
        ];
        let mut extend = |names_add: &[(&'static str, u16, Option<SortKey>)]| {
            for (name, width, key) in names_add {
                names.push(name);
                keys.push(*key);
                widths.push(Constraint::Length(*width));
            }
        };
        if area_width >= 100 {
            extend(&[
                ("START", 11, Some(SortKey::Start)),
                ("CPU", 3, Some(SortKey::Processor)),
            ]);
        }
        if area_width >= 120 {
            extend(&[
                ("VIRT", 8, Some(SortKey::Virtual)),
                ("SHR", 7, Some(SortKey::Shared)),
            ]);
        }
        if area_width >= 140 {
            extend(&[("PPID", 7, Some(SortKey::Parent))]);
        }
        if area_width >= 160 {
            extend(&[("PRI", 4, Some(SortKey::Priority))]);
        }
        if show_io {
            extend(&[("RD/s", 5, None), ("WR/s", 5, None)]);
        }
        names.push("NAME");
        keys.push(Some(SortKey::Name));
        widths.push(Constraint::Min(1));
        if area_width >= 160 {
            names.push("COMMAND");
            keys.push(Some(SortKey::Command));
            widths.push(Constraint::Length(32));
        }
        Self {
            names,
            widths,
            keys,
        }
    }

    /// The sort key a click on column `x` (relative to the table's left
    /// edge) lands on, or None for a column that does not sort. One cell
    /// of column spacing separates the columns, matching the draw path.
    /// The name column takes the middle of the table (`Min`); fixed
    /// columns after it (COMMAND) get the last `width + 1` cells.
    fn sort_key_at(&self, x: u16, total: u16) -> Option<SortKey> {
        let mut left = 0u16;
        for (index, width) in self.widths.iter().enumerate() {
            let Constraint::Length(width) = width else {
                // The name column, then any fixed columns after it: the
                // rest of the table minus their spans belongs to the name.
                let trailing = &self.widths[index + 1..];
                let after: u16 = trailing
                    .iter()
                    .filter_map(|width| match width {
                        Constraint::Length(width) => Some(width + 1),
                        _ => None,
                    })
                    .sum();
                if x >= total.saturating_sub(after) {
                    let mut right = total.saturating_sub(after);
                    for (offset, width) in trailing.iter().enumerate() {
                        let Constraint::Length(width) = width else {
                            return self.keys[index + 1 + offset];
                        };
                        // The last column's span runs to the table's edge.
                        let is_last = offset + 1 == trailing.len();
                        let hit = if is_last {
                            x >= right
                        } else {
                            x >= right && x < right + width
                        };
                        if hit {
                            return self.keys[index + 1 + offset];
                        }
                        right += width + 1;
                    }
                    return None;
                }
                return self.keys[index];
            };
            if x >= left && x < left + width {
                return self.keys[index];
            }
            left += width + 1;
        }
        None
    }
}

/// One mouse event on the process table: a left click selects the row it
/// lands on or sorts by the header column it points at; the wheel moves
/// the cursor. Clicks while a prompt or the menu is open are ignored, and
/// the setup and Apple Silicon screens have no table to click.
fn handle_mouse(
    ui: &mut Ui,
    kind: MouseEventKind,
    column: u16,
    row: u16,
    total: ratatui::layout::Rect,
) -> Option<KeyEvent> {
    if ui.screen != Screen::ProcessTable
        || ui.menu.is_some()
        || ui.filter.is_some()
        || ui.search.is_some()
    {
        return None;
    }
    let (header, table) = split_table_area(ui, total);
    // The function bar is the header area's last row (the status line);
    // a click there replays the hint's key, like pressing the label.
    if header.y + 4 + u16::from(sensors_present(ui)) == row {
        return match kind {
            MouseEventKind::Down(MouseButton::Left) => status_hint_at(ui, column),
            _ => None,
        };
    }
    if row < table.y || row >= table.y + table.height {
        return None;
    }
    let local = row - table.y;
    match kind {
        MouseEventKind::Down(MouseButton::Left) => {
            if local == 1 {
                let procs = ui.ordered_rows();
                let show_io = procs_io_visible(&procs);
                let columns = Columns::plan(table.width, show_io);
                if let Some(key) = columns.sort_key_at(column.saturating_sub(table.x), table.width)
                {
                    ui.sort_by(key);
                }
            } else if local >= 2 {
                let procs = ui.ordered_rows();
                let fold = table.height.saturating_sub(2) as usize;
                let cursor_index = procs.iter().position(|r| Some(r.process.pid) == ui.cursor);
                let offset = table_scroll(cursor_index, fold);
                ui.select_visible_row(local as usize - 2 + offset);
            }
        }
        MouseEventKind::ScrollUp => ui.select_prev(),
        MouseEventKind::ScrollDown => ui.select_next(),
        _ => {}
    }
    None
}

/// One table row: the cells follow the column plan, so a column exists in
/// a row exactly when its header does. Tagged processes carry a `*`
/// before the name, htop-style.
fn process_row(
    row_view: &TreeRow<'_>,
    tree: bool,
    tagged: bool,
    columns: &Columns,
) -> Row<'static> {
    let base = row_view
        .process
        .command
        .clone()
        .unwrap_or_else(|| row_view.process.name.clone());
    let shown = if tree {
        let indent = "  ".repeat(row_view.depth);
        let branch = if row_view.depth > 0 { "└─ " } else { "" };
        let folded = if row_view.hidden > 0 {
            format!(" (+{})", row_view.hidden)
        } else {
            String::new()
        };
        format!("{indent}{branch}{base}{folded}")
    } else {
        base
    };
    let name = if tagged { format!("* {shown}") } else { shown };
    let process = row_view.process;
    let cells: Vec<Cell<'static>> = columns
        .names
        .iter()
        .map(|column| match *column {
            "PID" => Cell::from(format!("{:>7}", process.pid)),
            "USER" => Cell::from(format!("{:>7}", process.user)),
            "STATE" => Cell::from(process.state.clone()),
            "CPU%" => Cell::from(format!("{:>5.1}", process.cpu_percent)),
            "MEM%" => Cell::from(format!("{:>5.1}", process.mem_percent)),
            "THR" => Cell::from(format!("{:>3}", process.threads)),
            "RES" => Cell::from(format!("{:>8}", bytes_text(process.resident_bytes as f64))),
            "NICE" => match process.nice {
                Some(nice) => Cell::from(format!("{:>4}", nice)),
                None => Cell::from(""),
            },
            "PRI" => match process.priority {
                Some(priority) => Cell::from(format!("{:>4}", priority)),
                None => Cell::from(""),
            },
            "TIME+" => Cell::from(format!("{:>7}", time_text(process.total_time_ns))),
            // Start time in local MM/DD HH:MM and the last processor the
            // process ran on; both blank when the collector could not tell.
            "START" => match process.start_time_secs {
                Some(secs) => {
                    Cell::from(format!("{:>11}", ztop_core::clock::local_start_text(secs)))
                }
                None => Cell::from(""),
            },
            "CPU" => match process.processor {
                Some(core) => Cell::from(format!("{:>3}", core)),
                None => Cell::from(""),
            },
            "VIRT" => Cell::from(format!("{:>8}", bytes_text(process.virtual_bytes as f64))),
            // Shared bytes are blank where the platform does not report
            // them (macOS today).
            "SHR" => match process.shared_bytes {
                Some(bytes) => Cell::from(format!("{:>7}", bytes_text(bytes as f64))),
                None => Cell::from(""),
            },
            "PPID" => match process.parent {
                Some(parent) => Cell::from(format!("{:>7}", parent)),
                None => Cell::from(""),
            },
            "RD/s" => Cell::from(format!("{:>5}", rate_text(process.io.read_rate))),
            "WR/s" => Cell::from(format!("{:>5}", rate_text(process.io.write_rate))),
            "NAME" => Cell::from(name.clone()),
            // The command column shows the raw command line (or the short
            // name) with no tree or tag decoration.
            "COMMAND" => Cell::from(
                process
                    .command
                    .clone()
                    .unwrap_or_else(|| process.name.clone()),
            ),
            other => unreachable!("unknown process table column {other:?}"),
        })
        .collect();
    Row::new(cells)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ztop_core::model::{
        Battery, BatteryState, Cpu, CpuTimes, Disk, Fan, Metric, NetIf, ProcessIo, Sensors,
        TempSensor, Unit,
    };

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
                priority: Some((20 + pid) as i32),
                nice: Some(0),
                shared_bytes: Some(4096),
                total_time_ns: Some(pid as u64 * 1_000_000_000),
                start_time_secs: Some(1_700_000_000 + pid as u64),
                processor: Some((pid - 1) % 4),
                command: None,
                io: ProcessIo::default(),
            })
            .collect();
        Sample {
            timestamp_ms: 1_700_000_000_000,
            hostname: "host-a".to_string(),
            system: "Linux 6.8.0-test".to_string(),
            threads: Metric::available(78.0, Unit::Count),
            kernel_threads: Metric::available(2.0, Unit::Count),
            cpu: Cpu {
                cores,
                busy_percent: vec![10.0, 25.0, 50.0, 100.0],
                frequency_mhz: Vec::new(),
            },
            memory: Memory {
                total: Metric::available(16.0 * GIB, Unit::Bytes),
                used: Metric::available(6.0 * GIB, Unit::Bytes),
                free: Metric::available(10.0 * GIB, Unit::Bytes),
                buffers: Metric::available(340.0 * MIB, Unit::Bytes),
                shared: Metric::available(89.0 * MIB, Unit::Bytes),
                cache: Metric::available(2.0 * GIB, Unit::Bytes),
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
            apple_silicon: ztop_core::model::AppleSilicon::default(),
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

    /// A sample with one disk (usage plus rates) and one interface with
    /// rates, matching the core test fixture values.
    fn sample_with_disks() -> Sample {
        let mut s = sample();
        s.disks = vec![Disk {
            name: "sda".to_string(),
            read_bytes: 1_474_182 * 512,
            write_bytes: 7_098_027 * 512,
            mount: "/".to_string(),
            total_bytes: 500_000_000_000,
            used_bytes: 150_000_000_000,
            usage_pct: 30.0,
            read_rate: Some(120_000.0),
            write_rate: Some(45_000.0),
        }];
        s.net = vec![NetIf {
            name: "eth0".to_string(),
            rx_bytes: 265_744_198,
            rx_packets: 29_836,
            tx_bytes: 1_193_601,
            tx_packets: 10_693,
            rx_rate: Some(240_000.0),
            tx_rate: Some(60_000.0),
        }];
        s
    }

    /// A sample with a temperature, a fan and a charging battery.
    fn sample_with_sensors() -> Sample {
        let mut s = sample();
        s.sensors.temps = vec![TempSensor {
            label: "SoC".to_string(),
            celsius: Metric::available(45.0, Unit::Celsius),
        }];
        s.sensors.fans = vec![Fan {
            label: "Fan 1".to_string(),
            rpm: Metric::available(1200.0, Unit::RevolutionsPerMinute),
        }];
        s.sensors.battery = Some(Battery {
            percent: Metric::available(87.0, Unit::Percent),
            power_watts: Metric::available(4.25, Unit::Watts),
            state: BatteryState::Charging,
        });
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
        // The CPU row leads with the average meter.
        assert!(rows[1].contains("Avg 46%"), "{:?}", rows[1]);
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
    fn mp_t_shortcuts_sort_by_mem_cpu_and_time() {
        let mut ui = ui_with(Some(sample()), None);
        for (code, key) in [
            (KeyCode::Char('M'), SortKey::Mem),
            (KeyCode::Char('P'), SortKey::Cpu),
            (KeyCode::Char('T'), SortKey::TotalTime),
        ] {
            handle_key(&mut ui, KeyEvent::from(code));
            assert_eq!(ui.sort, key, "{code:?} sorts by {key:?}");
        }
        // Off the table the shortcuts do nothing: lowercase `t` opens the
        // thermal screen and uppercase `T` must not sort there.
        handle_key(&mut ui, KeyEvent::from(KeyCode::Char('t')));
        handle_key(&mut ui, KeyEvent::from(KeyCode::Char('T')));
        assert_eq!(ui.screen, Screen::Thermal);
        assert_eq!(ui.sort, SortKey::TotalTime);
    }

    #[test]
    fn wide_terminals_gain_start_and_processor_columns() {
        // Clicking the START header (x 60 at 100 columns) sorts by start
        // time descending: worker-12 started last (1_700_000_012) and last
        // ran on core 3, so it leads with an MM/DD HH:MM start cell and
        // the processor id in the CPU column.
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 100, 24);
        handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            60,
            6,
            screen,
        );
        assert_eq!(ui.sort, SortKey::Start);
        let rows = render(&ui, 100, 24);
        let header_row = rows
            .iter()
            .position(|row| row.contains("START") && row.contains("CPU"))
            .expect("START and CPU headers at 100 columns");
        let first = &rows[header_row + 1];
        assert!(first.contains("worker-12"), "{first:?}");
        // The exact MM/DD HH:MM shape is unit-tested in the clock module
        // (zone-independent); here the date slash and the core id show.
        assert!(first.contains('/'), "{first:?}");
        let cells: Vec<&str> = first.split_whitespace().collect();
        assert!(cells.contains(&"3"), "last processor cell: {first:?}");
        // At 80 columns the extra columns stay hidden and a click at the
        // old TIME+ offset still sorts time, not start.
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 80, 24);
        handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            60,
            6,
            screen,
        );
        assert!(!render(&ui, 80, 24).iter().any(|row| row.contains("START")));
        // Clicking the CPU column header (x 72) sorts by last processor;
        // the core-3 ties (pids 4, 8, 12) keep their pid order, so
        // worker-04 leads under a stable sort.
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 100, 24);
        handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            72,
            6,
            screen,
        );
        assert_eq!(ui.sort, SortKey::Processor);
        let rows = render(&ui, 100, 24);
        let header_row = rows
            .iter()
            .position(|row| row.contains("START"))
            .expect("table header");
        assert!(
            rows[header_row + 1].contains("worker-04"),
            "{:?}",
            rows[header_row + 1]
        );
    }

    #[test]
    fn wider_terminals_gain_virt_shr_and_ppid() {
        // 120 columns add VIRT and SHR; PPID waits for 140.
        let at_120 = render(&ui_with(Some(sample()), None), 120, 24);
        assert!(at_120.iter().any(|row| row.contains("VIRT")));
        assert!(at_120.iter().any(|row| row.contains("SHR")));
        assert!(!at_120.iter().any(|row| row.contains("PPID")));
        assert!(
            render(&ui_with(Some(sample()), None), 100, 24)
                .iter()
                .all(|row| !row.contains("VIRT"))
        );
        assert!(
            render(&ui_with(Some(sample()), None), 140, 24)
                .iter()
                .any(|row| row.contains("PPID"))
        );
        // Clicking VIRT (x 76 at 120 columns) sorts by virtual size; the
        // sample scales virtual bytes by pid, so worker-12 leads.
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 120, 24);
        handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            76,
            6,
            screen,
        );
        assert_eq!(ui.sort, SortKey::Virtual);
        let rows = render(&ui, 120, 24);
        let header_row = rows
            .iter()
            .position(|row| row.contains("VIRT"))
            .expect("VIRT header");
        assert!(
            rows[header_row + 1].contains("worker-12"),
            "{:?}",
            rows[header_row + 1]
        );
        // SHR (x 85) and PPID (x 93 at 140) map to their sort keys too;
        // the sample's shared bytes and parents are all equal or absent,
        // so only the key itself is asserted.
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 120, 24);
        handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            85,
            6,
            screen,
        );
        assert_eq!(ui.sort, SortKey::Shared);
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 140, 24);
        handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            93,
            6,
            screen,
        );
        assert_eq!(ui.sort, SortKey::Parent);
    }

    /// The 160-column tier adds PRI (after PPID) and COMMAND (after NAME).
    /// COMMAND sorts by the recorded command line, falling back to the
    /// short name the way the NAME column shows it.
    #[test]
    fn widest_terminals_gain_pri_and_command() {
        let rows = render(&ui_with(Some(sample()), None), 160, 24);
        assert!(rows.iter().any(|row| row.contains("PRI")));
        assert!(rows.iter().any(|row| row.contains("COMMAND")));
        assert!(
            !rows
                .iter()
                .any(|row| row.contains("COMMAND") && row.contains("worker-01 "))
        );
        // The sample's priority is Some(20 + pid): worker-04 shows 24.
        let header = rows.iter().position(|row| row.contains("PRI")).unwrap();
        assert!(
            rows[header + 1..]
                .iter()
                .filter(|row| row.contains("worker-04"))
                .all(|row| row.contains("24")),
            "worker-04 priority missing: {:?}",
            rows[header + 1..]
                .iter()
                .find(|row| row.contains("worker-04"))
        );
        // Clicking PRI sorts by priority; the x anchor comes from the
        // rendered header so the test does not hard-code column math.
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 160, 24);
        let pri_x = rows
            .iter()
            .find(|row| row.contains("PRI"))
            .and_then(|row| row.find("PRI"))
            .expect("PRI header cell") as u16;
        handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            pri_x,
            6,
            screen,
        );
        assert_eq!(ui.sort, SortKey::Priority);
        // Clicking COMMAND (x 140 at 160) sorts by the command (fallback
        // names here), so worker-12 leads under the default descending.
        let mut ui = ui_with(Some(sample()), None);
        handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            140,
            6,
            screen,
        );
        assert_eq!(ui.sort, SortKey::Command);
        let rows = render(&ui, 160, 24);
        let header = rows.iter().position(|row| row.contains("COMMAND")).unwrap();
        assert!(
            rows[header + 1].contains("worker-12"),
            "{:?}",
            rows[header + 1]
        );
        // At 140 columns neither column exists. A click at x 139 lands in
        // NAME and sorts by name, as the name column always has.
        let at_140 = render(&ui_with(Some(sample()), None), 140, 24);
        assert!(!at_140.iter().any(|row| row.contains("PRI")));
        assert!(!at_140.iter().any(|row| row.contains("COMMAND")));
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 140, 24);
        handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            139,
            6,
            screen,
        );
        assert_eq!(ui.sort, SortKey::Name);
    }

    #[test]
    fn time_text_formats_minutes_hours_and_blank() {
        assert_eq!(time_text(None), "");
        assert_eq!(time_text(Some(0)), "0:00.0");
        assert_eq!(time_text(Some(1_000_000_000)), "0:01.0");
        assert_eq!(time_text(Some(3_599_900_000_000)), "59:59.9");
        assert_eq!(time_text(Some(3_600_000_000_000)), "1:00:00");
        assert_eq!(time_text(Some(36_610_000_000_000)), "10:10:10");
    }

    #[test]
    fn the_time_column_shows_total_cpu_time_and_sorts_by_it() {
        let mut ui = ui_with(Some(sample()), None);
        // worker-12 holds 12 s of total CPU time; sorted descending by `T`
        // it must lead the table and read `0:12.0` in the TIME+ column.
        handle_key(&mut ui, KeyEvent::from(KeyCode::Char('T')));
        let rows = render(&ui, 80, 24);
        let header_row = rows
            .iter()
            .position(|row| row.contains("TIME+"))
            .expect("TIME+ header");
        let first = &rows[header_row + 1];
        assert!(first.contains("worker-12"), "{first:?}");
        assert!(first.contains("0:12.0"), "{first:?}");
        // Clicking the TIME+ header (x 52) sorts the same column.
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 80, 24);
        handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            52,
            6,
            screen,
        );
        assert_eq!(ui.sort, SortKey::TotalTime);
    }

    #[test]
    fn renders_the_error_state() {
        let ui = ui_with(None, Some("collector is down".to_string()));
        let rows = render(&ui, 80, 24);
        assert!(
            rows[4].contains("error: collector is down"),
            "{:?}",
            rows[4]
        );
        // The table still renders its header with no sample to show.
        assert!(rows.iter().any(|row| row.contains("CPU%")));
    }

    #[test]
    fn sensors_row_applies_only_when_the_sample_has_readings() {
        let mut sample = sample();

        // Without readings the header keeps its five rows: status on row 4.
        let ui = ui_with(Some(sample.clone()), None);
        let rows = render(&ui, 80, 24);
        assert_eq!(rows.len(), 24);
        assert!(
            rows[4].contains("q: quit"),
            "status stays on row 4: {:?}",
            rows[4]
        );
        assert!(!rows[4].contains("°C"));

        // With readings a sixth header row appears between memory and status.
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
            rows[4].starts_with("CPU composite 78.7°C"),
            "sensors row on row 4: {:?}",
            rows[4]
        );
        assert!(
            rows[4].contains("Fan 0 1001rpm"),
            "fan reading present: {:?}",
            rows[4]
        );
        assert!(
            rows[4].contains("Sys 17.0W"),
            "system power present: {:?}",
            rows[4]
        );
        assert!(
            rows[5].contains("q: quit"),
            "status moves to row 5: {:?}",
            rows[5]
        );
    }

    /// The header's info line shows the local clock (its exact value
    /// follows the machine's time zone, so the test matches the shape),
    /// the task counts and the system string.
    #[test]
    fn the_header_info_line_shows_clock_tasks_and_system() {
        let ui = ui_with(Some(sample()), None);
        let rows = render(&ui, 80, 24);
        let clock = &rows[3][..8.min(rows[3].len())];
        assert!(
            clock.len() == 8
                && clock.chars().nth(2) == Some(':')
                && clock.chars().nth(5) == Some(':')
                && clock.chars().all(|c| c.is_ascii_digit() || c == ':'),
            "the info line opens with a clock: {:?}",
            rows[3]
        );
        assert!(
            rows[3].contains("Tasks: 12, 6 running"),
            "task counts present: {:?}",
            rows[3]
        );
        assert!(
            rows[3].contains("Linux 6.8.0-test"),
            "system string present: {:?}",
            rows[3]
        );
        assert!(
            !rows[3].contains("bat"),
            "no battery, no claim: {:?}",
            rows[3]
        );
    }

    /// When the sample carries a battery the info line reports its
    /// percentage and state.
    #[test]
    fn the_header_info_line_shows_the_battery_when_present() {
        let mut sample = sample();
        // Keep the line short: without thread counts the battery segment
        // fits the 80-column test terminal.
        sample.threads = Metric::unavailable(Unit::Count);
        sample.kernel_threads = Metric::unavailable(Unit::Count);
        sample.sensors.battery = Some(Battery {
            percent: Metric::available(87.0, Unit::Percent),
            state: BatteryState::Discharging,
            power_watts: Metric::available(12.5, Unit::Watts),
        });
        let ui = ui_with(Some(sample), None);
        let rows = render(&ui, 80, 24);
        assert!(
            rows[3].contains("bat 87% discharging"),
            "battery present: {:?}",
            rows[3]
        );
    }

    /// The info line reports the host's thread and kernel-thread counts
    /// when the sample carries them.
    #[test]
    fn the_info_line_reports_thread_counts_when_the_sample_carries_them() {
        let ui = ui_with(Some(sample()), None);
        let rows = render(&ui, 80, 24);
        assert!(
            rows[3].contains("78 thr") && rows[3].contains("2 kthr"),
            "thread counts present: {:?}",
            rows[3]
        );
    }

    /// When the platform reports no thread counts the info line stays
    /// quiet about them instead of claiming zero.
    #[test]
    fn the_info_line_omits_thread_counts_when_unavailable() {
        let mut sample = sample();
        sample.threads = Metric::unavailable(Unit::Count);
        sample.kernel_threads = Metric::unavailable(Unit::Count);
        let ui = ui_with(Some(sample), None);
        let rows = render(&ui, 80, 24);
        assert!(
            !rows[3].contains("thr") && !rows[3].contains("kthr"),
            "no thread claims: {:?}",
            rows[3]
        );
    }

    /// The title shows the mean CPU frequency when the sample carries
    /// core frequencies, and stays quiet when it does not.
    #[test]
    fn the_title_shows_the_mean_frequency_when_reported() {
        let mut sample = sample();
        sample.cpu.frequency_mhz = vec![Metric::available(3115.0, Unit::Hertz)];
        let mut quiet = sample.clone();
        quiet.cpu.frequency_mhz = Vec::new();
        let ui = ui_with(Some(sample), None);
        let rows = render(&ui, 80, 24);
        assert!(
            rows[0].contains("f 3.1 GHz"),
            "frequency in the title: {:?}",
            rows[0]
        );
        let ui = ui_with(Some(quiet), None);
        assert!(
            !render(&ui, 80, 24)[0].contains(" f "),
            "no frequency claim: {:?}",
            render(&ui, 80, 24)[0]
        );
    }

    /// The CPU row leads with an average meter before the per-core ones.
    #[test]
    fn the_cpu_row_leads_with_an_average_meter() {
        let ui = ui_with(Some(sample()), None);
        let rows = render(&ui, 80, 24);
        assert!(
            rows[1].contains("Avg"),
            "average meter present: {:?}",
            rows[1]
        );
    }

    /// The memory gauge label reports compressed memory when the sample
    /// carries it (macOS), and nothing about it when it does not (Linux).
    #[test]
    fn the_memory_gauge_label_reports_compressed_when_the_sample_carries_it() {
        let mut s = sample();
        // 1 MiB so the breakdown fits in the 80-col gauge.
        s.memory.compressed = Metric::available(1.0 * 1024.0 * 1024.0, Unit::Bytes);
        // Test memory_gauge directly at 80 cols so the breakdown fits.
        let (_, label) = memory_gauge(&s.memory, 80);
        assert!(
            label.contains("comp 1.0 MiB"),
            "compressed in the label: {:?}",
            label
        );
        let (_, label) = memory_gauge(&sample().memory, 80);
        assert!(
            !label.contains("comp"),
            "no compressed claim on Linux: {:?}",
            label
        );
    }

    /// The memory gauge label fits the gauge's width and keeps a few
    /// columns for the bar: the breakdown joins only as far as it fits,
    /// while the used/total pair always stays.
    #[test]
    fn the_memory_gauge_label_fits_the_gauge_and_keeps_the_bar_room() {
        let sample = sample();
        let gib = 1024.0 * 1024.0 * 1024.0;
        let (ratio, wide) = memory_gauge(&sample.memory, 72);
        assert!((ratio - 6.0 * gib / (16.0 * gib)).abs() < 1e-9, "ratio");
        assert_eq!(
            wide,
            "6.0 GiB / 16.0 GiB · buf 340.0 MiB shmem 89.0 MiB cache 2.0 GiB"
        );
        let (_, narrow) = memory_gauge(&sample.memory, 48);
        assert_eq!(narrow, "6.0 GiB / 16.0 GiB · buf 340.0 MiB");
        let (_, tiny) = memory_gauge(&sample.memory, 12);
        assert!(
            tiny.starts_with("6.0 GiB / 16.0 GiB"),
            "used/total survives a tiny gauge: {tiny}"
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
    fn the_pid_filter_lists_only_the_requested_pids() {
        let mut ui = ui_with(Some(sample()), None);
        ui.pid_filter = [7u32, 12].into_iter().collect();

        // Only the requested rows survive, and the status line names them.
        let rows = render(&ui, 80, 24);
        assert!(rows.iter().any(|row| row.contains("worker-07")));
        assert!(rows.iter().any(|row| row.contains("worker-12")));
        assert!(!rows.iter().any(|row| row.contains("worker-01")));
        assert!(rows.iter().any(|row| row.contains("pids:2")));

        // An empty set lists everything again.
        ui.pid_filter.clear();
        let rows = render(&ui, 80, 24);
        assert!(rows.iter().any(|row| row.contains("worker-01")));
        assert!(!rows.iter().any(|row| row.contains("pids:")));
    }

    #[test]
    fn the_pid_filter_applies_in_tree_mode() {
        let mut ui = ui_with(Some(sample_with_tree()), None);
        ui.tree = true;
        // Only pid 4 (a leaf under 2 under 1) survives; with its ancestors
        // filtered away it becomes a root row.
        ui.pid_filter = [4u32].into_iter().collect();

        let rows: Vec<_> = ui
            .ordered_rows()
            .iter()
            .map(|row| row.process.pid)
            .collect();
        assert_eq!(rows, vec![4]);

        // The subtree relationship still renders when the parent matches.
        ui.pid_filter = [2u32, 4].into_iter().collect();
        let rows: Vec<_> = ui
            .ordered_rows()
            .iter()
            .map(|row| (row.process.pid, row.depth))
            .collect();
        assert_eq!(rows, vec![(2, 0), (4, 1)]);
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
        let rows = render(&ui, 80, 11);
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
        // The menu lists each platform's numbers in number order, so the
        // marker row is derived from the shared list rather than a fixed
        // name: index 5 is TERM on macOS but USR1 on Linux.
        let (name, number) = control::common_signals()[5];
        assert!(
            rows.iter()
                .any(|row| row.contains(&format!("> {name} ({number})"))),
            "the selection marker shows: {rows:?}"
        );
        let (kill, kill_number) = control::common_signals()[4];
        assert!(
            rows.iter()
                .any(|row| row.contains(&format!("  {kill} ({kill_number})"))),
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
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::Resident);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::Virtual);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::Shared);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::Nice);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::TotalTime);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::Start);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::Processor);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::Parent);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::Priority);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::Name);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::Command);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::Pid);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::User);
        ui.cycle_sort();
        assert_eq!(ui.sort, SortKey::Cpu);
        ui.toggle_direction();
        assert!(!ui.descending);
    }

    /// A sample for the Apple Silicon screen: named chip, cluster counts,
    /// power readings and a two-point history so the chart draws.
    fn sample_with_silicon() -> Sample {
        let mut s = sample();
        s.sensors.gpu_watts = Metric::available(2.1, Unit::Watts);
        s.apple_silicon = ztop_core::model::AppleSilicon {
            chip_name: Some("Apple M3 Pro".into()),
            e_core_count: Metric::available(2.0, Unit::Count),
            p_core_count: Metric::available(2.0, Unit::Count),
            current_watts: Metric::available(12.34, Unit::Watts),
            average_watts: Metric::available(9.87, Unit::Watts),
            peak_watts: Metric::available(15.6, Unit::Watts),
            power_history: vec![
                ztop_core::model::PowerSample {
                    timestamp_ms: 1_700_000_000_000,
                    watts: 10.0,
                },
                ztop_core::model::PowerSample {
                    timestamp_ms: 1_700_000_002_000,
                    watts: 12.34,
                },
            ],
            ..ztop_core::model::AppleSilicon::default()
        };
        s
    }

    /// The Apple Silicon screen renders chip, cluster counts, power and the
    /// history chart — and none of the process table behind it.
    #[test]
    fn the_silicon_screen_shows_chip_cores_and_power() {
        let mut ui = ui_with(Some(sample_with_silicon()), None);
        ui.screen = Screen::AppleSilicon;
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter().any(|row| row.contains("Apple M3 Pro")),
            "chip name shows: {rows:?}"
        );
        assert!(
            rows.iter()
                .any(|row| row.contains("2P + 2E (4 logical, busy 46%)")),
            "cluster counts and aggregate busy show: {rows:?}"
        );
        assert!(
            rows.iter().any(|row| row.contains("10% 25% 50% 100%")),
            "per-core busy shows: {rows:?}"
        );
        assert!(
            rows.iter()
                .any(|row| row.contains("now 12.3 W  avg 9.9 W  peak 15.6 W")),
            "power summary shows: {rows:?}"
        );
        assert!(
            rows.iter().any(|row| row.contains("GPU       2.1 W")),
            "{rows:?}"
        );
        assert!(
            rows.iter()
                .any(|row| row.contains("Unavailable unprivileged")),
            "the gap line shows: {rows:?}"
        );
        assert!(
            rows.iter().any(|row| row.contains("Power history (W)")),
            "the chart block shows: {rows:?}"
        );
        assert!(
            !rows.iter().any(|row| row.contains("worker-01")),
            "the process table stays hidden: {rows:?}"
        );
    }

    /// With fewer than two power points the chart area says it is still
    /// collecting instead of drawing an empty graph.
    #[test]
    fn the_silicon_chart_waits_for_two_points() {
        let mut s = sample_with_silicon();
        s.apple_silicon.power_history.pop();
        let mut ui = ui_with(Some(s), None);
        ui.screen = Screen::AppleSilicon;
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter()
                .any(|row| row.contains("collecting power history")),
            "the collecting note shows: {rows:?}"
        );
    }

    /// A machine without a chip name gets an explicit message, not a wall
    /// of dashes.
    #[test]
    fn the_silicon_screen_says_so_on_non_apple_machines() {
        let mut ui = ui_with(Some(sample()), None);
        ui.screen = Screen::AppleSilicon;
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter().any(|row| row.contains("not Apple Silicon")),
            "the explanation shows: {rows:?}"
        );
        assert!(
            !rows.iter().any(|row| row.contains("worker-01")),
            "the process table stays hidden: {rows:?}"
        );
    }

    /// `toggle_screen` flips between the table and the Apple Silicon screen
    /// and back; the draw dispatch follows it in both directions.
    #[test]
    fn toggle_screen_flips_between_table_and_silicon() {
        let mut ui = Ui::new();
        assert_eq!(ui.screen, Screen::ProcessTable);
        ui.toggle_screen();
        assert_eq!(ui.screen, Screen::AppleSilicon);
        ui.sample = Some(sample_with_silicon());
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter().any(|row| row.contains("Apple M3 Pro")),
            "{rows:?}"
        );
        ui.toggle_screen();
        assert_eq!(ui.screen, Screen::ProcessTable);
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter().any(|row| row.contains("worker-01")),
            "back on the table: {rows:?}"
        );
    }

    /// `open_setup` remembers the screen it was opened from and closing the
    /// setup screen returns there with the save outcome in the notice.
    #[test]
    fn open_setup_remembers_where_it_returned() {
        let mut ui = Ui::new();
        ui.toggle_screen();
        ui.open_setup();
        assert_eq!(ui.screen, Screen::Setup);
        assert_eq!(ui.setup_return, Screen::AppleSilicon);
        ui.finish_setup(Ok(std::path::PathBuf::from("ztop-config.json")));
        assert_eq!(ui.screen, Screen::AppleSilicon);
        assert!(ui.notice.is_some(), "the save outcome is reported");
        // Opening setup from the table remembers the table instead.
        ui.toggle_screen();
        ui.open_setup();
        assert_eq!(ui.setup_return, Screen::ProcessTable);
        // The setup screen cannot toggle away; `a` cannot reach it, but the
        // method still holds the screen.
        ui.toggle_screen();
        assert_eq!(ui.screen, Screen::Setup);
    }

    /// The setup screen's rows wrap and each toggle flips its option.
    #[test]
    fn setup_navigation_wraps_and_toggles() {
        let mut ui = Ui::new();
        assert_eq!(ui.setup_select, 0);
        ui.setup_toggle();
        assert_eq!(ui.config.theme, Theme::Mono);
        ui.setup_toggle();
        assert_eq!(ui.config.theme, Theme::Color);
        ui.setup_next();
        ui.setup_toggle();
        assert!(ui.config.start_in_tree);
        ui.setup_prev();
        assert_eq!(ui.setup_select, 0);
        ui.setup_prev();
        assert_eq!(ui.setup_select, 1, "moving up from the first row wraps");
    }

    /// The setup screen shows both options with their values, the help line,
    /// the config file path, and marks the selected row.
    #[test]
    fn the_setup_screen_shows_its_options_and_help() {
        let mut ui = Ui::new();
        ui.screen = Screen::Setup;
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter()
                .any(|row| row.contains("> Theme") && row.contains("color")),
            "the theme row, selected: {rows:?}"
        );
        assert!(
            rows.iter()
                .any(|row| row.contains("Start in tree view") && row.contains("no")),
            "{rows:?}"
        );
        assert!(rows.iter().any(|row| row.contains("j/k move")), "{rows:?}");
        assert!(
            rows.iter().any(|row| row.contains("Config file:")),
            "{rows:?}"
        );
        // Moving down moves the marker; toggling the theme changes the value.
        ui.setup_next();
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter().any(|row| row.contains("> Start in tree view")),
            "the second row, selected: {rows:?}"
        );
        ui.setup_select = 0;
        ui.config.theme = Theme::Mono;
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter()
                .any(|row| row.contains("Theme") && row.contains("mono"))
        );
    }

    /// Mouse support (docs/parity.md: "click to select, sort and use the
    /// function bar"): a left click on a process row moves the selection
    /// to that row, and the wheel walks the selection.
    #[test]
    fn clicking_a_row_selects_it() {
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 80, 24);
        // Sensorless fixture: the table starts at y 5 — border, column
        // header, then the rows — so the first row sits at y 7.
        let first = ui.ordered_rows()[0].process.pid;
        let second = ui.ordered_rows()[1].process.pid;
        handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            0,
            7,
            screen,
        );
        assert_eq!(ui.cursor, Some(first));
        handle_mouse(&mut ui, MouseEventKind::ScrollDown, 0, 7, screen);
        assert_eq!(ui.cursor, Some(second));
    }

    /// A click on a column header sorts by that column; clicking the
    /// column that already sorts flips the direction.
    #[test]
    fn clicking_the_header_sorts_then_flips() {
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 80, 24);
        let pids: Vec<u32> = ui.ordered_rows().iter().map(|r| r.process.pid).collect();
        // The PID column starts at x 0, so column 0 is its header cell.
        handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            0,
            6,
            screen,
        );
        assert_eq!(
            ui.ordered_rows()[0].process.pid,
            *pids.iter().max().unwrap()
        );
        handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            0,
            6,
            screen,
        );
        assert_eq!(
            ui.ordered_rows()[0].process.pid,
            *pids.iter().min().unwrap()
        );
    }

    /// A click on the function bar replays the key its label names: the
    /// `i: reverse` hint flips the sort direction like pressing i.
    #[test]
    fn clicking_a_function_bar_hint_replays_the_key() {
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 80, 24);
        // The status row sits at y 3 on the sensorless fixture; find the
        // hint's column in the same string the draw path renders.
        let line = status_parts(&ui).join(" · ");
        let x = line.split("i: reverse").next().unwrap().chars().count() as u16;
        let procs = ui.ordered_rows();
        let last = procs.last().unwrap().process.pid;
        let key = handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            x,
            4,
            screen,
        )
        .expect("the i hint replays i");
        handle_key(&mut ui, key);
        assert_eq!(ui.ordered_rows()[0].process.pid, last);
    }

    /// The data screens: `d`, `n` and `t` address their panel, a second
    /// press returns to the table, and `a` stays an absolute address from
    /// anywhere. On a panel the table keys do nothing; F2 still opens setup.
    #[test]
    fn screen_keys_address_panels_and_return() {
        let mut ui = ui_with(Some(sample()), None);
        for (code, screen) in [
            (KeyCode::Char('d'), Screen::Disk),
            (KeyCode::Char('n'), Screen::Network),
            (KeyCode::Char('t'), Screen::Thermal),
        ] {
            handle_key(&mut ui, KeyEvent::from(code));
            assert_eq!(ui.screen, screen, "{code:?} addresses its screen");
            handle_key(&mut ui, KeyEvent::from(code));
            assert_eq!(ui.screen, Screen::ProcessTable, "a second press returns");
        }
        handle_key(&mut ui, KeyEvent::from(KeyCode::Char('d')));
        handle_key(&mut ui, KeyEvent::from(KeyCode::Char('a')));
        assert_eq!(ui.screen, Screen::AppleSilicon, "a is an absolute address");
        // The table keys have no meaning on a panel and do nothing.
        handle_key(&mut ui, KeyEvent::from(KeyCode::Char('j')));
        assert_eq!(ui.screen, Screen::AppleSilicon);
        handle_key(&mut ui, KeyEvent::from(KeyCode::F(2)));
        assert_eq!(ui.screen, Screen::Setup);
    }

    /// The disk panel: usage, lifetime counters and rates, all on one row.
    #[test]
    fn the_disk_panel_shows_usage_counters_and_rates() {
        let mut ui = ui_with(Some(sample_with_disks()), None);
        ui.screen = Screen::Disk;
        let rows = render(&ui, 100, 24);
        let disk_row = rows
            .iter()
            .find(|row| row.contains("sda"))
            .expect("disk row");
        assert!(disk_row.contains('/'), "{disk_row}");
        assert!(disk_row.contains("30.0%"), "{disk_row}");
        assert!(disk_row.contains(&rate_text(Some(120_000.0))), "{disk_row}");
        assert!(disk_row.contains(&rate_text(Some(45_000.0))), "{disk_row}");
        assert!(
            disk_row.contains(&bytes_text(150_000_000_000.0)),
            "{disk_row}"
        );
    }

    /// The network panel: counters, rates and packet totals per interface.
    #[test]
    fn the_network_panel_shows_interfaces_and_rates() {
        let mut ui = ui_with(Some(sample_with_disks()), None);
        ui.screen = Screen::Network;
        let rows = render(&ui, 100, 24);
        let net_row = rows
            .iter()
            .find(|row| row.contains("eth0"))
            .expect("iface row");
        assert!(net_row.contains(&bytes_text(265_744_198.0)), "{net_row}");
        assert!(net_row.contains(&rate_text(Some(240_000.0))), "{net_row}");
        assert!(net_row.contains(&rate_text(Some(60_000.0))), "{net_row}");
        assert!(net_row.contains("29836"), "{net_row}");
        assert!(net_row.contains("10693"), "{net_row}");
    }

    /// The sensors panel: temperatures, fans, battery and power draw.
    #[test]
    fn the_thermal_panel_shows_temps_fans_battery_and_power() {
        let mut ui = ui_with(Some(sample_with_sensors()), None);
        ui.screen = Screen::Thermal;
        let rows = render(&ui, 100, 24);
        let flat = rows.join("\n");
        assert!(flat.contains("SoC"), "{flat}");
        assert!(flat.contains("45.0 °C"), "{flat}");
        assert!(flat.contains("Fan 1"), "{flat}");
        assert!(flat.contains("1200 rpm"), "{flat}");
        assert!(flat.contains("87%"), "{flat}");
        assert!(flat.contains("charging"), "{flat}");
        assert!(flat.contains("4.2 W"), "{flat}");
    }

    /// Hosts that report none of a panel's data get an honest empty state,
    /// never fake zeros (decision 0009).
    #[test]
    fn panels_without_data_say_so_instead_of_fake_zeros() {
        let mut ui = ui_with(Some(sample()), None);
        ui.screen = Screen::Disk;
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter()
                .any(|row| row.contains("No disk data on this host.")),
            "{rows:?}"
        );
        ui.screen = Screen::Network;
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter()
                .any(|row| row.contains("No network data on this host.")),
            "{rows:?}"
        );
        ui.screen = Screen::Thermal;
        let rows = render(&ui, 80, 24);
        assert!(
            rows.iter()
                .any(|row| row.contains("No temperature or fan data on this host.")),
            "{rows:?}"
        );
    }

    #[test]
    fn the_name_column_shows_the_command_when_the_capture_has_one() {
        // worker-12 carries a recorded command line; the others show
        // their short names as before.
        let mut flat_sample = sample();
        flat_sample.processes[11].command = Some("ztop --watch".to_string());
        let rows = render(&ui_with(Some(flat_sample), None), 80, 24);
        assert!(rows.iter().any(|row| row.contains("ztop --watch")));
        assert!(rows.iter().any(|row| row.contains("worker-04")));
        // Tree mode indents the command like it indented the name.
        let mut tree_sample = sample();
        tree_sample.processes[11].command = Some("ztop --watch".to_string());
        let mut ui = ui_with(Some(tree_sample), None);
        ui.toggle_tree();
        let rows = render(&ui, 80, 24);
        assert!(rows.iter().any(|row| row.contains("ztop --watch")));
    }

    /// Before the first sample the panels wait for data instead of lying.
    #[test]
    fn panels_without_a_sample_wait_for_data() {
        let mut ui = ui_with(None, None);
        ui.screen = Screen::Disk;
        assert!(
            render(&ui, 80, 24)
                .iter()
                .any(|row| row.contains("no sample yet"))
        );
    }

    /// Clicking the `d: disks` hint replays d: the hint bar reaches the
    /// panels too (at a width wide enough to show the label).
    #[test]
    fn clicking_the_disks_hint_replays_d() {
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 200, 24);
        let line = status_parts(&ui).join(" · ");
        let x = line.split("d: disks").next().unwrap().chars().count() as u16;
        let key = handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            x,
            4,
            screen,
        )
        .expect("the d hint replays d");
        handle_key(&mut ui, key);
        assert_eq!(ui.screen, Screen::Disk);
    }

    /// The `q: quit` hint replays q, which quits — the full click path
    /// reaches the same handler the keyboard uses.
    #[test]
    fn clicking_quit_replays_the_quit_key() {
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 80, 24);
        // `q: quit` starts the function bar, so column 0 lands on it.
        let key = handle_mouse(
            &mut ui,
            MouseEventKind::Down(MouseButton::Left),
            0,
            4,
            screen,
        )
        .expect("the q hint replays q");
        assert!(handle_key(&mut ui, key), "the replayed q quits");
    }

    /// While a prompt (filter, search, signal menu) is open the mouse
    /// does nothing, matching the keyboard where the prompt eats keys.
    #[test]
    fn clicks_are_ignored_while_a_prompt_is_open() {
        let mut ui = ui_with(Some(sample()), None);
        let screen = ratatui::layout::Rect::new(0, 0, 80, 24);
        ui.toggle_filter();
        assert!(ui.filter.is_some());
        assert_eq!(
            handle_mouse(
                &mut ui,
                MouseEventKind::Down(MouseButton::Left),
                0,
                6,
                screen
            ),
            None
        );
        assert_eq!(
            handle_mouse(
                &mut ui,
                MouseEventKind::Down(MouseButton::Left),
                0,
                4,
                screen
            ),
            None
        );
        assert_eq!(ui.cursor, None);
    }

    /// `gauge_style` passes colors through in color mode and drops them in
    /// mono mode.
    #[test]
    fn gauge_style_follows_the_theme() {
        let mut ui = Ui::new();
        assert_eq!(gauge_style(&ui, Style::new().green()), Style::new().green());
        ui.config.theme = Theme::Mono;
        assert_eq!(gauge_style(&ui, Style::new().green()), Style::new());
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

    /// Dump the 80x24 setup frame for a human eye:
    /// `cargo test -p ztop-tui --lib dump_setup_snapshot -- --ignored --nocapture`
    #[test]
    #[ignore = "manual inspection helper"]
    fn dump_setup_snapshot() {
        let mut ui = ui_with(Some(sample()), None);
        ui.screen = Screen::Setup;
        for (index, row) in render(&ui, 80, 24).iter().enumerate() {
            println!("{index:2}|{row}");
        }
        // A second frame with the second row selected and mono theme.
        ui.setup_next();
        ui.config.theme = Theme::Mono;
        println!("---- second row selected, mono theme ----");
        for (index, row) in render(&ui, 80, 24).iter().enumerate() {
            println!("{index:2}|{row}");
        }
    }

    /// Dump the 80x24 Apple Silicon frame for a human eye:
    /// `cargo test -p ztop-tui --lib dump_silicon_snapshot -- --ignored --nocapture`
    #[test]
    #[ignore = "manual inspection helper"]
    fn dump_silicon_snapshot() {
        let mut ui = ui_with(Some(sample_with_silicon()), None);
        ui.screen = Screen::AppleSilicon;
        for (index, row) in render(&ui, 80, 24).iter().enumerate() {
            println!("{index:2}|{row}");
        }
        // A machine without a chip name shows the explanation instead.
        let mut ui = ui_with(Some(sample()), None);
        ui.screen = Screen::AppleSilicon;
        println!("---- sample without Apple Silicon data ----");
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
