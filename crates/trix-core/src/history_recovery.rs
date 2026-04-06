use std::collections::BTreeSet;

use crate::{LocalHistoryRepairWindow, LocalMessageRecoveryState};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ChatHistoryRecovery {
    summary_window: Option<LocalHistoryRepairWindow>,
    unavailable_server_seqs: BTreeSet<u64>,
    backfillable_unavailable_server_seqs: BTreeSet<u64>,
}

impl ChatHistoryRecovery {
    pub(crate) fn new(
        pending_window: Option<LocalHistoryRepairWindow>,
        projected_gap_window: Option<LocalHistoryRepairWindow>,
        unavailable_server_seqs: BTreeSet<u64>,
    ) -> Self {
        let unavailable_window = range_from_server_seqs(&unavailable_server_seqs);
        let backfillable_unavailable_server_seqs = match pending_window {
            Some(window) => unavailable_server_seqs
                .iter()
                .copied()
                .filter(|server_seq| {
                    *server_seq < window.from_server_seq || *server_seq > window.through_server_seq
                })
                .collect(),
            None => unavailable_server_seqs.clone(),
        };
        let summary_window = match (pending_window, projected_gap_window, unavailable_window) {
            (Some(_), _, _) => merge_windows([pending_window, unavailable_window]),
            (None, Some(projected_gap), Some(unavailable)) => {
                merge_windows([Some(projected_gap), Some(unavailable)])
            }
            (None, _, Some(unavailable)) => Some(unavailable),
            (None, Some(projected_gap), None) => Some(projected_gap),
            (None, None, None) => None,
        };

        Self {
            summary_window,
            unavailable_server_seqs,
            backfillable_unavailable_server_seqs,
        }
    }

    pub(crate) fn summary_window(&self) -> Option<LocalHistoryRepairWindow> {
        self.summary_window
    }

    pub(crate) fn has_backfillable_unavailable_messages(&self) -> bool {
        !self.backfillable_unavailable_server_seqs.is_empty()
    }

    pub(crate) fn recovery_state_for_message(
        &self,
        server_seq: u64,
        has_materialized_body: bool,
    ) -> Option<LocalMessageRecoveryState> {
        (!has_materialized_body)
            .then_some(server_seq)
            .filter(|server_seq| {
                self.summary_window
                    .map(|window| {
                        *server_seq >= window.from_server_seq
                            && *server_seq <= window.through_server_seq
                    })
                    .unwrap_or(false)
            })
            .map(|_| LocalMessageRecoveryState::PendingSiblingHistory)
    }
}

fn range_from_server_seqs(server_seqs: &BTreeSet<u64>) -> Option<LocalHistoryRepairWindow> {
    Some(LocalHistoryRepairWindow {
        from_server_seq: *server_seqs.iter().next()?,
        through_server_seq: *server_seqs.iter().next_back()?,
    })
}

fn merge_windows<I>(windows: I) -> Option<LocalHistoryRepairWindow>
where
    I: IntoIterator<Item = Option<LocalHistoryRepairWindow>>,
{
    let mut windows = windows.into_iter().flatten();
    let first = windows.next()?;
    Some(
        windows.fold(first, |merged, window| LocalHistoryRepairWindow {
            from_server_seq: merged.from_server_seq.min(window.from_server_seq),
            through_server_seq: merged.through_server_seq.max(window.through_server_seq),
        }),
    )
}
