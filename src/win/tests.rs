use super::*;
use std::cell::{Cell, RefCell};
use std::collections::VecDeque;

type ReadResponse = (u64, AppResult<Option<MIB_IPINTERFACE_ROW>>);

struct FakeInterfaces {
    scans: RefCell<VecDeque<Vec<Adapter>>>,
    reads: RefCell<VecDeque<ReadResponse>>,
    writes: RefCell<Vec<MIB_IPINTERFACE_ROW>>,
    set_result: RefCell<AppResult<bool>>,
    waits: Cell<usize>,
}

impl FakeInterfaces {
    fn new(scans: Vec<Vec<Adapter>>, reads: Vec<ReadResponse>) -> Self {
        Self {
            scans: RefCell::new(scans.into()),
            reads: RefCell::new(reads.into()),
            writes: RefCell::new(Vec::new()),
            set_result: RefCell::new(Ok(true)),
            waits: Cell::new(0),
        }
    }

    fn done(&self) {
        assert!(self.scans.borrow().is_empty(), "unused adapter snapshots");
        assert!(self.reads.borrow().is_empty(), "unused IPv4 reads");
    }
}

impl InterfaceApi for FakeInterfaces {
    fn adapters(&self) -> AppResult<Vec<Adapter>> {
        Ok(self
            .scans
            .borrow_mut()
            .pop_front()
            .expect("unexpected enumeration"))
    }

    fn ipv4(&self, adapter: &Adapter) -> AppResult<Option<MIB_IPINTERFACE_ROW>> {
        let (expected_luid, response) = self
            .reads
            .borrow_mut()
            .pop_front()
            .expect("unexpected IPv4 query");
        assert_eq!(
            adapter.luid, expected_luid,
            "query must use the selected LUID"
        );
        response
    }

    fn set_ipv4(&self, row: &mut MIB_IPINTERFACE_ROW) -> AppResult<bool> {
        self.writes.borrow_mut().push(*row);
        self.set_result.borrow().clone()
    }

    fn wait_for_verification(&self) {
        self.waits.set(self.waits.get() + 1);
    }
}

fn adapter(alias: &str, luid: u64) -> Adapter {
    Adapter {
        alias: alias.into(),
        luid,
        index: luid as u32 + 10,
        is_up: true,
        is_hardware: false,
        description: "WireGuard Tunnel".into(),
        if_type: 53,
    }
}

fn row(luid: u64, mtu: u32) -> MIB_IPINTERFACE_ROW {
    MIB_IPINTERFACE_ROW {
        Family: AF_INET,
        InterfaceLuid: NET_LUID_LH { Value: luid },
        InterfaceIndex: 88,
        NlMtu: mtu,
        SitePrefixLength: 64,
        Metric: 37,
        ForwardingEnabled: true,
        ..Default::default()
    }
}

fn ready(luid: u64, mtu: u32) -> ReadResponse {
    (luid, Ok(Some(row(luid, mtu))))
}

#[test]
fn active_suffix_is_fixed_without_querying_stale_base_and_other_fields_are_preserved() {
    let mut stale = adapter("AmneziaVPN", 1);
    stale.is_up = false;
    let active = adapter("AmneziaVPN 1", 2);
    let scan = vec![stale, active];
    let api = FakeInterfaces::new(
        vec![scan.clone(), scan.clone(), scan],
        vec![ready(2, 1376), ready(2, 1376), ready(2, TARGET_MTU)],
    );
    assert!(
        matches!(apply(&api).unwrap(), Status::Updated { adapter, old: 1376, .. } if adapter.alias == "AmneziaVPN 1")
    );
    let writes = api.writes.borrow();
    assert_eq!(writes.len(), 1);
    let written = &writes[0];
    assert_eq!(unsafe { written.InterfaceLuid.Value }, 2);
    assert_eq!(written.Family, AF_INET);
    assert_eq!(written.NlMtu, TARGET_MTU);
    assert_eq!(written.SitePrefixLength, 0);
    assert_eq!(written.InterfaceIndex, 0);
    assert_eq!(written.Metric, 37);
    assert!(written.ForwardingEnabled);
    assert_eq!(api.waits.get(), 1);
    api.done();
}

#[test]
fn two_active_ipv4_candidates_abort_before_any_write() {
    let api = FakeInterfaces::new(
        vec![vec![adapter("AmneziaVPN", 1), adapter("AmneziaVPN 2", 2)]],
        vec![ready(1, 1280), ready(2, 1376)],
    );
    let error = apply(&api).unwrap_err();
    assert!(error.contains("AMBIGUOUS"));
    assert!(error.contains("AmneziaVPN 2"));
    assert!(api.writes.borrow().is_empty());
    api.done();
}

#[test]
fn physical_adapter_with_matching_name_does_not_block_virtual_target() {
    let mut physical = adapter("AmneziaVPN", 1);
    physical.is_hardware = true;
    let api = FakeInterfaces::new(
        vec![vec![physical, adapter("AmneziaVPN 2", 2)]],
        vec![ready(2, 1280)],
    );
    assert!(matches!(apply(&api).unwrap(), Status::Good(target) if target.alias == "AmneziaVPN 2"));
    assert!(api.writes.borrow().is_empty());
    api.done();
}

#[test]
fn only_inactive_or_invalid_aliases_wait_without_ipv4_queries() {
    let mut down = adapter("AmneziaVPN 2", 1);
    down.is_up = false;
    let api = FakeInterfaces::new(
        vec![vec![
            down,
            adapter("AmneziaVPN +2", 2),
            adapter("Ethernet 2", 3),
        ]],
        vec![],
    );
    assert_eq!(apply(&api).unwrap(), Status::Waiting);
    assert!(api.writes.borrow().is_empty());
    api.done();
}

#[test]
fn missing_ipv4_row_is_waiting_without_a_write() {
    let api = FakeInterfaces::new(vec![vec![adapter("AmneziaVPN 2", 2)]], vec![(2, Ok(None))]);
    assert_eq!(apply(&api).unwrap(), Status::Waiting);
    assert!(api.writes.borrow().is_empty());
    api.done();
}

#[test]
fn disappearing_interface_before_write_is_waiting_without_a_write() {
    let api = FakeInterfaces::new(
        vec![vec![adapter("AmneziaVPN 2", 2)], vec![]],
        vec![ready(2, 1376)],
    );
    assert_eq!(apply(&api).unwrap(), Status::Waiting);
    assert!(api.writes.borrow().is_empty());
    api.done();
}

#[test]
fn changed_activity_or_hardware_state_before_write_cancels_the_write() {
    for hardware in [false, true] {
        let initial = adapter("AmneziaVPN 2", 2);
        let mut changed = initial.clone();
        changed.is_hardware = hardware;
        changed.is_up = hardware;
        let api = FakeInterfaces::new(vec![vec![initial], vec![changed]], vec![ready(2, 1376)]);
        assert_eq!(apply(&api).unwrap(), Status::Waiting);
        assert!(api.writes.borrow().is_empty());
        api.done();
    }
}

#[test]
fn replacement_luid_before_write_is_not_written() {
    let api = FakeInterfaces::new(
        vec![
            vec![adapter("AmneziaVPN 2", 2)],
            vec![adapter("AmneziaVPN 2", 3)],
        ],
        vec![ready(2, 1376), ready(3, 1376)],
    );
    assert_eq!(apply(&api).unwrap(), Status::Waiting);
    assert!(api.writes.borrow().is_empty());
    api.done();
}

#[test]
fn second_eligible_adapter_appearing_before_write_aborts() {
    let target = adapter("AmneziaVPN 2", 2);
    let api = FakeInterfaces::new(
        vec![
            vec![target.clone()],
            vec![target, adapter("AmneziaVPN 3", 3)],
        ],
        vec![ready(2, 1376), ready(2, 1376), ready(3, 1376)],
    );
    assert!(apply(&api).unwrap_err().contains("AMBIGUOUS"));
    assert!(api.writes.borrow().is_empty());
    api.done();
}

#[test]
fn api_error_for_another_possible_candidate_is_not_silently_ignored() {
    let api = FakeInterfaces::new(
        vec![vec![adapter("AmneziaVPN", 1), adapter("AmneziaVPN 2", 2)]],
        vec![ready(1, 1376), (2, Err("Windows error 5".into()))],
    );
    assert_eq!(apply(&api).unwrap_err(), "Windows error 5");
    assert!(api.writes.borrow().is_empty());
    api.done();
}

#[test]
fn another_actor_correcting_mtu_before_write_prevents_redundant_set() {
    let scan = vec![adapter("AmneziaVPN 2", 2)];
    let api = FakeInterfaces::new(
        vec![scan.clone(), scan],
        vec![ready(2, 1376), ready(2, 1280)],
    );
    assert!(matches!(apply(&api).unwrap(), Status::Good(_)));
    assert!(api.writes.borrow().is_empty());
    api.done();
}

#[test]
fn interface_disappearing_at_set_is_waiting_not_false_success() {
    let scan = vec![adapter("AmneziaVPN 2", 2)];
    let api = FakeInterfaces::new(
        vec![scan.clone(), scan],
        vec![ready(2, 1376), ready(2, 1376)],
    );
    *api.set_result.borrow_mut() = Ok(false);
    assert_eq!(apply(&api).unwrap(), Status::Waiting);
    assert_eq!(api.writes.borrow().len(), 1);
    assert_eq!(api.waits.get(), 0);
    api.done();
}

#[test]
fn interface_disappearing_or_replaced_after_set_is_not_reported_as_updated() {
    for final_scan in [vec![], vec![adapter("AmneziaVPN 2", 3)]] {
        let replaced = !final_scan.is_empty();
        let scan = vec![adapter("AmneziaVPN 2", 2)];
        let mut reads = vec![ready(2, 1376), ready(2, 1376)];
        if replaced {
            reads.push(ready(3, 1280));
        }
        let api = FakeInterfaces::new(vec![scan.clone(), scan, final_scan], reads);
        assert_eq!(apply(&api).unwrap(), Status::Waiting);
        assert_eq!(api.writes.borrow().len(), 1);
        api.done();
    }
}

#[test]
fn failed_verification_is_an_error() {
    let scan = vec![adapter("AmneziaVPN 2", 2)];
    let api = FakeInterfaces::new(
        vec![scan.clone(), scan.clone(), scan],
        vec![ready(2, 1376), ready(2, 1376), ready(2, 1376)],
    );
    assert!(apply(&api).unwrap_err().contains("verification failed"));
    assert_eq!(api.writes.borrow().len(), 1);
    api.done();
}

#[test]
fn status_keeps_real_alias_case_and_suffix() {
    let display = Status::Good(adapter("amneziavpn 12", 12)).display();
    assert!(display.starts_with("[PASS] amneziavpn 12 IPv4"));
    assert!(display.contains("description=\"WireGuard Tunnel\""));
}

#[test]
fn ipv4_disappearing_during_revalidation_does_not_reuse_the_first_row() {
    let scan = vec![adapter("AmneziaVPN 2", 2)];
    let api = FakeInterfaces::new(
        vec![scan.clone(), scan],
        vec![ready(2, 1376), (2, Ok(None))],
    );
    assert_eq!(apply(&api).unwrap(), Status::Waiting);
    assert!(api.writes.borrow().is_empty());
    api.done();
}

#[test]
fn mismatched_ipv4_identity_is_an_error_without_a_write() {
    let api = FakeInterfaces::new(
        vec![vec![adapter("AmneziaVPN 2", 2)]],
        vec![(2, Ok(Some(row(3, 1376))))],
    );
    assert!(apply(&api).unwrap_err().contains("different adapter"));
    assert!(api.writes.borrow().is_empty());
    api.done();
}

#[test]
fn set_error_is_not_reported_as_a_success() {
    let scan = vec![adapter("AmneziaVPN 2", 2)];
    let api = FakeInterfaces::new(
        vec![scan.clone(), scan],
        vec![ready(2, 1376), ready(2, 1376)],
    );
    *api.set_result.borrow_mut() = Err("Windows error 5".into());
    assert_eq!(apply(&api).unwrap_err(), "Windows error 5");
    assert_eq!(api.writes.borrow().len(), 1);
    assert_eq!(api.waits.get(), 0);
    api.done();
}

#[test]
fn stop_is_retained_when_network_event_queue_is_full() {
    let (tx, rx) = mpsc::sync_channel(1);
    tx.try_send(Signal::NetworkChanged).unwrap();
    let stopping = AtomicBool::new(false);
    request_stop(&tx, &stopping);
    assert!(stopping.load(Ordering::Acquire));
    assert!(matches!(rx.try_recv(), Ok(Signal::NetworkChanged)));
}

#[test]
fn stop_wakes_idle_worker() {
    let (tx, rx) = mpsc::sync_channel(1);
    let stopping = AtomicBool::new(false);
    request_stop(&tx, &stopping);
    assert!(stopping.load(Ordering::Acquire));
    assert!(matches!(rx.try_recv(), Ok(Signal::Stop)));
}

#[test]
fn notification_burst_has_only_one_pending_wakeup() {
    let (tx, rx) = mpsc::sync_channel(1);
    for _ in 0..1000 {
        unsafe { ip_callback((&tx as *const SyncSender<Signal>).cast(), ptr::null(), 0) };
    }
    assert!(matches!(rx.try_recv(), Ok(Signal::NetworkChanged)));
    assert!(rx.try_recv().is_err());
}

#[test]
fn stop_interrupts_settling_without_waiting_for_timeout() {
    let (tx, rx) = mpsc::sync_channel(1);
    let stopping = AtomicBool::new(false);
    tx.try_send(Signal::Stop).unwrap();
    assert!(settle_events(&rx, &stopping, Duration::from_secs(60)));
}

#[test]
fn continuous_events_do_not_extend_settle_deadline() {
    let (tx, rx) = mpsc::sync_channel(1);
    let running = Arc::new(AtomicBool::new(true));
    let keep_running = Arc::clone(&running);
    let producer = thread::spawn(move || {
        while keep_running.load(Ordering::Acquire) {
            let _ = tx.try_send(Signal::NetworkChanged);
            thread::yield_now();
        }
    });
    let started = Instant::now();
    assert!(!settle_events(
        &rx,
        &AtomicBool::new(false),
        Duration::from_millis(20)
    ));
    running.store(false, Ordering::Release);
    producer.join().unwrap();
    assert!(started.elapsed() < Duration::from_secs(2));
}
