use ratatui::{
    Frame,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph, Wrap},
};

use crate::app::AppState;

pub fn draw(f: &mut Frame<'_>, state: &AppState) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Min(3),
            Constraint::Length(3),
        ])
        .split(f.area());

    let status = Line::from(vec![Span::styled(
        state.status_line.as_str(),
        Style::default().add_modifier(Modifier::DIM),
    )]);
    f.render_widget(Paragraph::new(status), chunks[0]);

    let mid = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(32), Constraint::Percentage(68)])
        .split(chunks[1]);

    let chat_items: Vec<ListItem> = state
        .chats
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let style = if Some(i) == state.chat_selected {
                Style::default().add_modifier(Modifier::BOLD | Modifier::REVERSED)
            } else {
                Style::default()
            };
            ListItem::new(Line::from(Span::styled(c.display_title.clone(), style)))
        })
        .collect();

    let chats_block = Block::default()
        .borders(Borders::ALL)
        .title(" Chats (↑/↓) ");
    let chat_list = List::new(chat_items).block(chats_block);
    f.render_widget(chat_list, mid[0]);

    let timeline_text = timeline_lines(state);
    let timeline = Paragraph::new(timeline_text)
        .block(Block::default().borders(Borders::ALL).title(" Timeline "))
        .wrap(Wrap { trim: true });
    f.render_widget(timeline, mid[1]);

    let input_block = Block::default()
        .borders(Borders::ALL)
        .title(" Message (Enter to send, Ctrl+Q quit) ");
    let input = Paragraph::new(Line::from(vec![
        Span::raw("> "),
        Span::styled(state.draft.as_str(), Style::default()),
    ]))
    .block(input_block);
    f.render_widget(input, chunks[2]);

    if let Some(area) = cursor_area(chunks[2]) {
        let x = area.x + 2 + draft_cursor_column(state.draft.as_str());
        let y = area.y + 1;
        let cx = x.min(area.x + area.width.saturating_sub(1));
        f.set_cursor_position((cx, y));
    }
}

fn draft_cursor_column(s: &str) -> u16 {
    s.chars().count().min(u16::MAX as usize) as u16
}

fn timeline_lines(state: &AppState) -> Vec<Line<'static>> {
    if state.chats.is_empty() {
        return vec![Line::from("No chats yet.")];
    }
    if state.timeline.is_empty() {
        return vec![Line::from("No messages (syncing or empty).")];
    }

    state
        .timeline
        .iter()
        .map(|item| {
            let who = if item.is_outgoing {
                "you"
            } else {
                item.sender_display_name.as_str()
            };
            let body = if !item.preview_text.is_empty() {
                item.preview_text.clone()
            } else {
                format!("<{:?}>", item.projection_kind)
            };
            Line::from(vec![
                Span::styled(
                    format!("[{who}] "),
                    Style::default().add_modifier(Modifier::DIM),
                ),
                Span::raw(body),
            ])
        })
        .collect()
}

fn cursor_area(input_chunk: Rect) -> Option<Rect> {
    if input_chunk.width > 2 && input_chunk.height > 2 {
        Some(Rect {
            x: input_chunk.x,
            y: input_chunk.y,
            width: input_chunk.width,
            height: input_chunk.height,
        })
    } else {
        None
    }
}
