// SPDX-License-Identifier: MIT OR Apache-2.0
//! The ztop terminal user interface.
//!
//! The render path is separated from terminal state: [`draw`] is a pure
//! function of the TUI state, which is what makes the 80x24 snapshot tests of
//! milestone M3 possible without a pty.

use std::io::{self, Stdout};
use std::time::Duration;

use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::crossterm::execute;
use ratatui::crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ratatui::text::Line;
use ratatui::widgets::Paragraph;

type Tui = Terminal<CrosstermBackend<Stdout>>;

/// Run the interactive TUI until the user quits with `q`, `Esc` or Ctrl-C.
pub fn run() -> io::Result<()> {
    enable_raw_mode()?;
    let result = (|| -> io::Result<()> {
        execute!(io::stdout(), EnterAlternateScreen)?;
        let mut terminal = Terminal::new(CrosstermBackend::new(io::stdout()))?;
        event_loop(&mut terminal)
    })();
    restore()?;
    result
}

fn restore() -> io::Result<()> {
    disable_raw_mode()?;
    execute!(io::stdout(), LeaveAlternateScreen)?;
    Ok(())
}

fn event_loop(terminal: &mut Tui) -> io::Result<()> {
    loop {
        terminal.draw(draw)?;
        if event::poll(Duration::from_millis(250))? {
            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press {
                    match key.code {
                        KeyCode::Char('q') | KeyCode::Esc => return Ok(()),
                        KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                            return Ok(());
                        }
                        _ => {}
                    }
                }
            }
        }
    }
}

/// Draw one frame. Pure with respect to terminal state so tests can render it.
pub fn draw(frame: &mut ratatui::Frame) {
    let version = env!("CARGO_PKG_VERSION");
    let text = vec![
        Line::from(format!("zTop {version}")),
        Line::from("skeleton build - collectors arrive in milestone M1"),
        Line::from("press q to quit"),
    ];
    frame.render_widget(Paragraph::new(text), frame.area());
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;

    /// The text of one buffer row, cell symbols concatenated.
    fn row_text(buffer: &ratatui::buffer::Buffer, y: u16) -> String {
        (0..buffer.area.width)
            .map(|x| buffer[(x, y)].symbol().to_string())
            .collect()
    }

    #[test]
    fn renders_the_header_in_80x24() {
        let backend = TestBackend::new(80, 24);
        let mut terminal = Terminal::new(backend).expect("test terminal");
        terminal.draw(draw).expect("draw");
        let buffer = terminal.backend().buffer();
        assert!(
            row_text(buffer, 0).starts_with("zTop 0.1.0"),
            "row 0: {:?}",
            row_text(buffer, 0)
        );
        assert!(row_text(buffer, 1).contains("skeleton build"));
        assert!(row_text(buffer, 2).contains("press q to quit"));
    }
}
