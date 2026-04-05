use std::io::{self, stdout};

use anyhow::{Context, Result};
use crossterm::{
    event::{Event, EventStream, KeyCode, KeyEventKind, KeyModifiers},
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode},
};
use futures_util::StreamExt;
use ratatui::prelude::*;
use tokio::sync::broadcast::error::RecvError;
use trix_bot::{
    Bot, BotEvent, BotInitConfig, BotLoadConfig, BotStateLayout, ConnectionMode,
    IdentityStoreConfig,
};
use trix_core::{LocalChatListItem, LocalTimelineItem};
use trix_types::ChatId;

use crate::ui;

pub struct AppState {
    pub chats: Vec<LocalChatListItem>,
    /// Selected chat index in `chats`.
    pub chat_selected: Option<usize>,
    pub timeline: Vec<LocalTimelineItem>,
    pub draft: String,
    pub status_line: String,
}

impl AppState {
    fn new() -> Self {
        Self {
            chats: Vec::new(),
            chat_selected: None,
            timeline: Vec::new(),
            draft: String::new(),
            status_line: String::new(),
        }
    }

    fn selected_chat_id(&self) -> Option<ChatId> {
        let idx = self.chat_selected?;
        self.chats.get(idx).map(|c| c.chat_id)
    }
}

pub async fn run(cli: &crate::Cli) -> Result<()> {
    let layout = BotStateLayout::new(&cli.state_dir);
    layout.ensure_root()?;

    let identity_cfg = IdentityStoreConfig {
        plaintext_dev_store: cli.plaintext_dev_store,
        master_secret_env: cli.master_secret_env.clone(),
    };

    let bot = if identity_cfg.exists(&layout) {
        Bot::load(BotLoadConfig {
            state_dir: cli.state_dir.clone(),
            server_url_override: Some(cli.server_url.clone()),
            master_secret_env: cli.master_secret_env.clone(),
            plaintext_dev_store: cli.plaintext_dev_store,
        })
        .await
        .context("failed to load existing bot state (check TRIX_BOT_MASTER_SECRET / identity)")?
    } else {
        Bot::init(BotInitConfig {
            server_url: cli.server_url.clone(),
            state_dir: cli.state_dir.clone(),
            profile_name: cli.profile_name.clone(),
            handle: cli.handle.clone(),
            platform: Some("tui".to_owned()),
            master_secret_env: cli.master_secret_env.clone(),
            plaintext_dev_store: cli.plaintext_dev_store,
        })
        .await
        .context("failed to create new account on server")?
    };

    bot.start().await?;

    enable_raw_mode().context("enable terminal raw mode")?;
    let mut stdout = stdout();
    execute!(stdout, EnterAlternateScreen).context("enter alternate screen")?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout)).context("ratatui terminal")?;

    let mut state = AppState::new();
    state.status_line = format!(
        "account={}  (do not share this state_dir with trix-botd)",
        bot.identity().account_id
    );

    refresh_data(&bot, &mut state).await;

    let mut events_rx = bot.subscribe();
    let mut reader = EventStream::new();

    let loop_result: Result<()> = loop {
        terminal.draw(|f| ui::draw(f, &state))?;

        tokio::select! {
            bot_ev = events_rx.recv() => {
                match bot_ev {
                    Ok(BotEvent::TextMessage { ref chat_id, .. }) | Ok(BotEvent::FileMessage { ref chat_id, .. }) => {
                        if state.selected_chat_id().map(|id| id.0.to_string()) == Some(chat_id.clone()) {
                            refresh_timeline(&bot, &mut state).await;
                        }
                        refresh_chats_only(&bot, &mut state).await;
                    }
                    Ok(BotEvent::Ready { .. }) => {
                        refresh_data(&bot, &mut state).await;
                    }
                    Ok(BotEvent::ConnectionChanged { connected, mode }) => {
                        let mode_s = match mode {
                            ConnectionMode::Websocket => "ws",
                            ConnectionMode::Polling => "poll",
                            ConnectionMode::Disconnected => "off",
                        };
                        state.status_line = format!(
                            "connected={connected} mode={mode_s} account={}",
                            bot.identity().account_id
                        );
                    }
                    Ok(BotEvent::Error { message }) => {
                        state.status_line = format!("error: {message}");
                    }
                    Ok(_) => {}
                    Err(RecvError::Lagged(_)) => {}
                    Err(RecvError::Closed) => break Ok(()),
                }
            }
            maybe_term = reader.next() => {
                match maybe_term {
                    Some(Ok(Event::Key(key))) if key.kind == KeyEventKind::Press => {
                        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('q') {
                            break Ok(());
                        }
                        match key.code {
                            KeyCode::Up => {
                                select_prev(&mut state);
                                refresh_timeline(&bot, &mut state).await;
                            }
                            KeyCode::Down => {
                                select_next(&mut state);
                                refresh_timeline(&bot, &mut state).await;
                            }
                            KeyCode::Enter => {
                                if let Some(chat_id) = state.selected_chat_id() {
                                    let text = std::mem::take(&mut state.draft);
                                    if !text.is_empty() {
                                        match bot.send_text(chat_id, text).await {
                                            Ok(_) => {
                                                refresh_timeline(&bot, &mut state).await;
                                                refresh_chats_only(&bot, &mut state).await;
                                            }
                                            Err(e) => {
                                                state.status_line = format!("send failed: {e:#}");
                                            }
                                        }
                                    }
                                }
                            }
                            KeyCode::Backspace => {
                                state.draft.pop();
                            }
                            KeyCode::Char(c) => {
                                state.draft.push(c);
                            }
                            KeyCode::Esc => {
                                break Ok(());
                            }
                            _ => {}
                        }
                    }
                    Some(Err(e)) => break Err(anyhow::anyhow!("terminal input: {e}")),
                    None => break Ok(()),
                    _ => {}
                }
            }
        }
    };

    disable_raw_mode().ok();
    let mut restore_out = io::stdout();
    execute!(restore_out, LeaveAlternateScreen).ok();
    terminal.show_cursor()?;

    bot.stop().await?;
    loop_result
}

fn select_prev(state: &mut AppState) {
    if state.chats.is_empty() {
        state.chat_selected = None;
        return;
    }
    let len = state.chats.len();
    let cur = state.chat_selected.unwrap_or(0);
    state.chat_selected = Some(cur.saturating_sub(1).min(len - 1));
}

fn select_next(state: &mut AppState) {
    if state.chats.is_empty() {
        state.chat_selected = None;
        return;
    }
    let len = state.chats.len();
    let cur = state.chat_selected.unwrap_or(0);
    state.chat_selected = Some((cur + 1).min(len - 1));
}

async fn refresh_data(bot: &Bot, state: &mut AppState) {
    refresh_chats_only(bot, state).await;
    refresh_timeline(bot, state).await;
}

async fn refresh_chats_only(bot: &Bot, state: &mut AppState) {
    match bot.list_chats().await {
        Ok(chats) => {
            state.chats = chats;
            if state.chats.is_empty() {
                state.chat_selected = None;
            } else {
                let idx = state.chat_selected.unwrap_or(0).min(state.chats.len() - 1);
                state.chat_selected = Some(idx);
            }
        }
        Err(e) => {
            state.status_line = format!("list_chats failed: {e:#}");
        }
    }
}

async fn refresh_timeline(bot: &Bot, state: &mut AppState) {
    let Some(chat_id) = state.selected_chat_id() else {
        state.timeline.clear();
        return;
    };
    match bot.get_timeline(chat_id, Some(200)).await {
        Ok(items) => state.timeline = items,
        Err(e) => {
            state.status_line = format!("timeline failed: {e:#}");
            state.timeline.clear();
        }
    }
}
