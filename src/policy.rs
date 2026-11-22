//! Policy decisions are kept pure and testable without Windows API calls.

pub const TARGET_ALIAS: &str = "AmneziaVPN";
pub const TARGET_MTU: u32 = 1280;

pub const EXIT_WAITING: i32 = 3;
pub const EXIT_DRIFT: i32 = 4;

pub fn check_exit_code(current: Option<u32>) -> i32 {
    match current {
        Some(TARGET_MTU) => 0,
        None => EXIT_WAITING,
        Some(_) => EXIT_DRIFT,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Waiting,
    Correct,
    Change { old: u32, new: u32 },
}

pub fn matches_alias(name: &str) -> bool {
    if name.eq_ignore_ascii_case(TARGET_ALIAS) {
        return true;
    }
    let Some((base, suffix)) = name.rsplit_once(' ') else {
        return false;
    };
    base.eq_ignore_ascii_case(TARGET_ALIAS)
        && !suffix.is_empty()
        && !suffix.starts_with('0')
        && suffix.bytes().all(|byte| byte.is_ascii_digit())
        && suffix.parse::<u32>().is_ok_and(|number| number >= 1)
}

#[derive(Debug, Clone, Copy)]
pub struct Candidate<'a> {
    pub alias: &'a str,
    pub is_up: bool,
    pub is_hardware: bool,
    pub ipv4_ready: bool,
}

impl Candidate<'_> {
    pub fn matches_device(&self) -> bool {
        matches_alias(self.alias) && self.is_up && !self.is_hardware
    }

    pub fn eligible(&self) -> bool {
        self.matches_device() && self.ipv4_ready
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Selection {
    Waiting,
    Unique(usize),
    Ambiguous,
}

pub fn select_adapter<'a>(candidates: impl IntoIterator<Item = Candidate<'a>>) -> Selection {
    let mut selected = Selection::Waiting;
    for (index, candidate) in candidates.into_iter().enumerate() {
        if candidate.eligible() {
            if matches!(selected, Selection::Unique(_)) {
                return Selection::Ambiguous;
            }
            selected = Selection::Unique(index);
        }
    }
    selected
}

pub fn decide(current: Option<u32>) -> Decision {
    match current {
        None => Decision::Waiting,
        Some(TARGET_MTU) => Decision::Correct,
        Some(old) => Decision::Change {
            old,
            new: TARGET_MTU,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adapter_absent_is_not_an_error() {
        assert_eq!(decide(None), Decision::Waiting);
    }

    #[test]
    fn correct_mtu_is_idempotent() {
        assert_eq!(decide(Some(1280)), Decision::Correct);
    }

    #[test]
    fn known_windows_mtu_is_fixed() {
        assert_eq!(
            decide(Some(1376)),
            Decision::Change {
                old: 1376,
                new: 1280
            }
        );
    }

    #[test]
    fn user_selected_lower_mtu_is_restored_to_contract() {
        assert_eq!(
            decide(Some(1200)),
            Decision::Change {
                old: 1200,
                new: 1280
            }
        );
    }

    #[test]
    fn accepts_base_and_canonical_numeric_suffixes() {
        for name in [
            "AmneziaVPN",
            "amneziavpn",
            "AmneziaVPN 1",
            "AMNEZIAVPN 2",
            "AmneziaVPN 12",
            "AmneziaVPN 4294967295",
        ] {
            assert!(matches_alias(name), "{name:?}");
        }
    }

    #[test]
    fn rejects_noncanonical_aliases_and_overflow() {
        for name in [
            "",
            "AmneziaVPN ",
            " AmneziaVPN",
            "AmneziaVPN 0",
            "AmneziaVPN 01",
            "AmneziaVPN +2",
            "AmneziaVPN -2",
            "AmneziaVPN  2",
            "AmneziaVPN 2 ",
            "AmneziaVPN\t2",
            "AmneziaVPN\u{a0}2",
            "AmneziaVPN ２",
            "AmneziaVPN 4294967296",
            "AmneziaVPN Backup",
            "AmneziaVPN-service",
            "AmneziaVPN2",
            "AmneziaWG",
            "Ethernet 2",
            "Wi-Fi",
        ] {
            assert!(!matches_alias(name), "{name:?}");
        }
    }

    fn candidate(alias: &str, up: bool, hardware: bool, ipv4: bool) -> Candidate<'_> {
        Candidate {
            alias,
            is_up: up,
            is_hardware: hardware,
            ipv4_ready: ipv4,
        }
    }

    #[test]
    fn stale_base_does_not_hide_active_suffixed_interface() {
        let stale = candidate("AmneziaVPN", false, false, true);
        let active = candidate("AmneziaVPN 1", true, false, true);
        assert_eq!(select_adapter([stale, active]), Selection::Unique(1));
        assert_eq!(select_adapter([active, stale]), Selection::Unique(0));
    }

    #[test]
    fn active_base_is_selected_when_numbered_interface_is_down() {
        assert_eq!(
            select_adapter([
                candidate("AmneziaVPN 2", false, false, true),
                candidate("AmneziaVPN", true, false, true),
            ]),
            Selection::Unique(1)
        );
    }

    #[test]
    fn multiple_active_candidates_are_ambiguous_in_either_order() {
        let base = candidate("AmneziaVPN", true, false, true);
        let numbered = candidate("AmneziaVPN 2", true, false, true);
        assert_eq!(select_adapter([base, numbered]), Selection::Ambiguous);
        assert_eq!(select_adapter([numbered, base]), Selection::Ambiguous);
    }

    #[test]
    fn physical_foreign_down_and_no_ipv4_interfaces_are_ineligible() {
        assert_eq!(
            select_adapter([
                candidate("AmneziaVPN", true, true, true),
                candidate("Ethernet 2", true, false, true),
                candidate("AmneziaVPN 2", false, false, true),
                candidate("AmneziaVPN 3", true, false, false),
            ]),
            Selection::Waiting
        );
        assert_eq!(select_adapter([]), Selection::Waiting);
    }

    #[test]
    fn initializing_ipv4_candidate_does_not_hide_one_ready_interface() {
        assert_eq!(
            select_adapter([
                candidate("AmneziaVPN", true, false, false),
                candidate("AmneziaVPN 12", true, false, true),
            ]),
            Selection::Unique(1)
        );
    }
}
