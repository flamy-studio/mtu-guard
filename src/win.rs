//! Windows-only implementation: native SCM + IP Helper API. No shells in runtime.
//! Unsafe code is isolated to FFI buffers, rows and notification handles.

use std::ffi::c_void;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::mem;
use std::path::PathBuf;
use std::ptr::{self, addr_of};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use windows_service::service::{
    ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus, ServiceType,
};
use windows_service::service_control_handler::ServiceControlHandlerResult;
use windows_service::{define_windows_service, service_control_handler, service_dispatcher};
use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_NOT_FOUND, HANDLE};
use windows_sys::Win32::NetworkManagement::IpHelper::{
    CancelMibChangeNotify2, FreeMibTable, GetIfTable2, GetIpInterfaceEntry,
    InitializeIpInterfaceEntry, NotifyIpInterfaceChange, SetIpInterfaceEntry, MIB_IF_ROW2,
    MIB_IF_TABLE2, MIB_IPINTERFACE_ROW,
};
use windows_sys::Win32::NetworkManagement::Ndis::{IfOperStatusUp, NET_LUID_LH};
use windows_sys::Win32::Networking::WinSock::AF_INET;

use crate::policy::{self, Decision, Selection, TARGET_ALIAS, TARGET_MTU};

const SERVICE_NAME: &str = "WithenMtuGuard";
const SWEEP: Duration = Duration::from_secs(30);
const SETTLE: Duration = Duration::from_millis(400);
const VERIFY_DELAY: Duration = Duration::from_millis(350);

type AppResult<T> = Result<T, String>;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Adapter {
    alias: String,
    luid: u64,
    index: u32,
    is_up: bool,
    is_hardware: bool,
    description: String,
    if_type: u32,
}

impl Adapter {
    fn candidate(&self, ipv4_ready: bool) -> policy::Candidate<'_> {
        policy::Candidate {
            alias: &self.alias,
            is_up: self.is_up,
            is_hardware: self.is_hardware,
            ipv4_ready,
        }
    }

    fn details(&self, ipv4_ready: bool) -> String {
        let ipv4 = if self.candidate(false).matches_device() {
            ipv4_ready.to_string()
        } else {
            "not-queried".into()
        };
        format!(
            "{:?} LUID={:#018x} ifIndex={} up={} hardware={} ipv4={} description={:?} type={}",
            self.alias,
            self.luid,
            self.index,
            self.is_up,
            self.is_hardware,
            ipv4,
            self.description,
            self.if_type
        )
    }
}

struct Snapshot {
    adapter: Adapter,
    row: MIB_IPINTERFACE_ROW,
}

struct AdapterScan {
    target: Option<Snapshot>,
    candidates: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Status {
    Waiting,
    Good(Adapter),
    Updated {
        adapter: Adapter,
        old: u32,
        correction_ms: u128,
    },
    Error(String),
}

impl Status {
    fn display(&self) -> String {
        match self {
            Self::Waiting => "[WAITING] no eligible active virtual IPv4 adapter (AmneziaVPN or AmneziaVPN N); connect the VPN and inspect candidate diagnostics".into(),
            Self::Good(adapter) => format!(
                "[PASS] {} IPv4 MTU = {TARGET_MTU}; LUID={:#018x} ifIndex={}; description={:?} type={}",
                adapter.alias, adapter.luid, adapter.index, adapter.description, adapter.if_type
            ),
            Self::Updated { adapter, old, correction_ms } => format!(
                "[PASS] {} MTU {old} -> {TARGET_MTU}; verified; LUID={:#018x} ifIndex={} correction_ms={correction_ms}; description={:?} type={}",
                adapter.alias, adapter.luid, adapter.index, adapter.description, adapter.if_type
            ),
            Self::Error(err) => format!("[FAIL] {err}"),
        }
    }
}

fn system_error(api: &str, code: u32) -> String {
    format!("{api} failed (Windows error {code})")
}

// The same reconciliation path is exercised with deterministic snapshots in tests.
// The native implementation remains the only runtime backend.
trait InterfaceApi {
    fn adapters(&self) -> AppResult<Vec<Adapter>>;
    fn ipv4(&self, adapter: &Adapter) -> AppResult<Option<MIB_IPINTERFACE_ROW>>;
    fn set_ipv4(&self, row: &mut MIB_IPINTERFACE_ROW) -> AppResult<bool>;
    fn wait_for_verification(&self);
}

struct NativeInterfaces;

fn wide_string(value: &[u16]) -> String {
    let end = value.iter().position(|&c| c == 0).unwrap_or(value.len());
    String::from_utf16_lossy(&value[..end])
}

impl InterfaceApi for NativeInterfaces {
    fn adapters(&self) -> AppResult<Vec<Adapter>> {
        let mut table: *mut MIB_IF_TABLE2 = ptr::null_mut();
        // SAFETY: Windows allocates the table; it is freed once after all rows are copied.
        let rc = unsafe { GetIfTable2(&mut table) };
        if rc != 0 {
            return Err(system_error("GetIfTable2", rc));
        }
        if table.is_null() {
            return Err("GetIfTable2 returned a null table".into());
        }
        // SAFETY: addr_of!(Table) respects padding/alignment before the variable-size array.
        let count = unsafe { (*table).NumEntries as usize };
        let first = unsafe { addr_of!((*table).Table) as *const MIB_IF_ROW2 };
        let mut adapters = Vec::new();
        for index in 0..count {
            // SAFETY: NumEntries records belong to this Windows allocation.
            let row = unsafe { &*first.add(index) };
            let alias = wide_string(&row.Alias);
            if alias.to_ascii_lowercase().contains("amnezia") {
                adapters.push(Adapter {
                    alias,
                    // SAFETY: Value is the complete representation of NET_LUID_LH.
                    luid: unsafe { row.InterfaceLuid.Value },
                    index: row.InterfaceIndex,
                    is_up: row.OperStatus == IfOperStatusUp,
                    // Windows SDK: HardwareInterface is bit 0 of this BOOLEAN bitfield.
                    is_hardware: row.InterfaceAndOperStatusFlags._bitfield & 1 != 0,
                    description: wide_string(&row.Description),
                    if_type: row.Type,
                });
            }
        }
        unsafe { FreeMibTable(table.cast::<c_void>()) };
        Ok(adapters)
    }

    fn ipv4(&self, adapter: &Adapter) -> AppResult<Option<MIB_IPINTERFACE_ROW>> {
        // SAFETY: initialize a fresh row; LUID + AF_INET identify this adapter instance.
        let mut row: MIB_IPINTERFACE_ROW = unsafe { mem::zeroed() };
        unsafe { InitializeIpInterfaceEntry(&mut row) };
        row.Family = AF_INET;
        row.InterfaceLuid = NET_LUID_LH {
            Value: adapter.luid,
        };
        let rc = unsafe { GetIpInterfaceEntry(&mut row) };
        if rc == ERROR_NOT_FOUND || rc == ERROR_FILE_NOT_FOUND {
            return Ok(None);
        }
        if rc != 0 {
            return Err(system_error("GetIpInterfaceEntry", rc));
        }
        Ok(Some(row))
    }

    fn set_ipv4(&self, row: &mut MIB_IPINTERFACE_ROW) -> AppResult<bool> {
        // SAFETY: row is a freshly retrieved AF_INET row, identified by the same LUID.
        let rc = unsafe { SetIpInterfaceEntry(row) };
        if rc == ERROR_NOT_FOUND || rc == ERROR_FILE_NOT_FOUND {
            return Ok(false);
        }
        if rc != 0 {
            return Err(system_error(
                "SetIpInterfaceEntry (administrator required)",
                rc,
            ));
        }
        Ok(true)
    }

    fn wait_for_verification(&self) {
        thread::sleep(VERIFY_DELAY);
    }
}

fn scan_adapters(api: &impl InterfaceApi) -> AppResult<AdapterScan> {
    let mut records = Vec::new();
    for adapter in api.adapters()? {
        let row = if adapter.candidate(false).matches_device() {
            // Only absence/initialization becomes None. Other API errors abort selection,
            // because an unqueried candidate must not be silently ignored.
            api.ipv4(&adapter)?
        } else {
            None
        };
        if let Some(row) = &row {
            // SAFETY: Value reads the initialized numeric representation of NET_LUID_LH.
            if row.Family != AF_INET || unsafe { row.InterfaceLuid.Value } != adapter.luid {
                return Err(
                    "GetIpInterfaceEntry returned a different adapter or address family".into(),
                );
            }
        }
        records.push((adapter, row));
    }
    let states = || {
        records
            .iter()
            .map(|(adapter, row)| adapter.candidate(row.is_some()))
    };
    let mut candidates: Vec<_> = records
        .iter()
        .map(|(adapter, row)| adapter.details(row.is_some()))
        .collect();
    candidates.sort();
    let target = match policy::select_adapter(states()) {
        Selection::Waiting => None,
        Selection::Unique(index) => {
            let (adapter, row) = records.swap_remove(index);
            Some(Snapshot {
                adapter,
                row: row.expect("eligible candidates have an IPv4 row"),
            })
        }
        Selection::Ambiguous => {
            let mut active: Vec<_> = records
                .iter()
                .filter(|(adapter, row)| adapter.candidate(row.is_some()).eligible())
                .map(|(adapter, _)| adapter.details(true))
                .collect();
            active.sort();
            return Err(format!(
                "AMBIGUOUS: multiple eligible active IPv4 adapters; refusing to change any: {}",
                active.join("; ")
            ));
        }
    };
    Ok(AdapterScan { target, candidates })
}

fn reconcile() -> Status {
    match apply(&NativeInterfaces) {
        Ok(value) => value,
        Err(err) => Status::Error(err),
    }
}

fn apply(api: &impl InterfaceApi) -> AppResult<Status> {
    let started = Instant::now();
    let Some(initial) = scan_adapters(api)?.target else {
        return Ok(Status::Waiting);
    };
    if policy::decide(Some(initial.row.NlMtu)) == Decision::Correct {
        return Ok(Status::Good(initial.adapter));
    }

    // Re-enumerate and query IPv4 immediately before writing. Do not reuse an old
    // index, old MTU, or a target selected before another eligible adapter appeared.
    let Some(mut target) = scan_adapters(api)?.target else {
        return Ok(Status::Waiting);
    };
    if target.adapter.luid != initial.adapter.luid {
        return Ok(Status::Waiting);
    }
    let old = target.row.NlMtu;
    if policy::decide(Some(old)) == Decision::Correct {
        return Ok(Status::Good(target.adapter));
    }
    // https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-setipinterfaceentry
    // Preserve the complete getter row, except MTU and these required key/IPv4 fields.
    target.row.SitePrefixLength = 0;
    target.row.NlMtu = TARGET_MTU;
    target.row.InterfaceIndex = 0;
    if !api.set_ipv4(&mut target.row)? {
        return Ok(Status::Waiting);
    }
    api.wait_for_verification();
    match scan_adapters(api)?.target {
        Some(current) if current.adapter.luid != target.adapter.luid => Ok(Status::Waiting),
        Some(current) if current.row.NlMtu == TARGET_MTU => Ok(Status::Updated {
            adapter: current.adapter,
            old,
            correction_ms: started.elapsed().as_millis(),
        }),
        Some(current) => Err(format!(
            "MTU verification failed for {:?}: expected {TARGET_MTU}, got {}",
            current.adapter.alias, current.row.NlMtu
        )),
        None => Ok(Status::Waiting),
    }
}

pub fn print_status(strict: bool) -> AppResult<i32> {
    let scan = scan_adapters(&NativeInterfaces)?;
    let code = policy::check_exit_code(scan.target.as_ref().map(|target| target.row.NlMtu));
    match scan.target {
        Some(target) if target.row.NlMtu == TARGET_MTU => {
            println!("{}", Status::Good(target.adapter).display());
        }
        Some(target) => println!(
            "[WARN] {} IPv4 MTU = {}, expected {TARGET_MTU}; LUID={:#018x} ifIndex={}; description={:?} type={}",
            target.adapter.alias, target.row.NlMtu, target.adapter.luid, target.adapter.index,
            target.adapter.description, target.adapter.if_type
        ),
        None => {
            println!("{}", Status::Waiting.display());
            if !scan.candidates.is_empty() {
                println!("[INFO] Amnezia-related candidates (ineligible entries are not modified): {}", scan.candidates.join("; "));
            }
        }
    }
    Ok(if strict { code } else { 0 })
}

pub fn fix_once() -> AppResult<()> {
    let result = reconcile();
    println!("{}", result.display());
    if let Status::Error(err) = result {
        Err(err)
    } else {
        Ok(())
    }
}

#[derive(Debug)]
enum Signal {
    NetworkChanged,
    Stop,
}

// Windows callback must not call IP Helper getters/setters or block on locks.
// We only queue a light notification. Callercontext points to a live boxed SyncSender
// until CancelMibChangeNotify2 has completed.
unsafe extern "system" fn ip_callback(
    callercontext: *const c_void,
    _row: *const MIB_IPINTERFACE_ROW,
    _kind: i32,
) {
    if !callercontext.is_null() {
        let sender = unsafe { &*(callercontext as *const SyncSender<Signal>) };
        let _ = sender.try_send(Signal::NetworkChanged);
    }
}

fn log(message: &str) {
    let base = std::env::var_os("PROGRAMDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\ProgramData"))
        .join("WITHEN")
        .join("MTU Guard");
    if fs::create_dir_all(&base).is_err() {
        eprintln!("{message}");
        return;
    }
    let path = base.join("guard.log");
    // Bounded diagnostics: retain one previous file; no IP, credentials, or VPN configs logged.
    if fs::metadata(&path)
        .map(|m| m.len() > 512 * 1024)
        .unwrap_or(false)
    {
        let _ = fs::remove_file(base.join("guard.log.1"));
        let _ = fs::rename(&path, base.join("guard.log.1"));
    }
    match OpenOptions::new().create(true).append(true).open(path) {
        Ok(mut f) => {
            let timestamp = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis();
            let _ = writeln!(f, "unix_ms={timestamp} {message}");
        }
        Err(_) => eprintln!("{message}"),
    }
}

fn request_stop(sender: &SyncSender<Signal>, stopping: &AtomicBool) {
    stopping.store(true, Ordering::Release);
    // The SCM handler must return promptly, even if network events filled the queue.
    let _ = sender.try_send(Signal::Stop);
}

fn settle_events(receiver: &Receiver<Signal>, stopping: &AtomicBool, delay: Duration) -> bool {
    // Fixed window: coalesce bursts without postponing reconciliation indefinitely.
    // STOP interrupts settling; notifications never build a 16 * 400 ms backlog.
    let deadline = Instant::now() + delay;
    while !stopping.load(Ordering::Acquire) {
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            return false;
        };
        match receiver.recv_timeout(remaining) {
            Ok(Signal::Stop) | Err(RecvTimeoutError::Disconnected) => return true,
            Ok(Signal::NetworkChanged) => {}
            Err(RecvTimeoutError::Timeout) => return stopping.load(Ordering::Acquire),
        }
    }
    true
}

fn loop_guard(
    receiver: &Receiver<Signal>,
    sender: &SyncSender<Signal>,
    stopping: &AtomicBool,
    before_cleanup: impl FnOnce(),
) {
    let ctx = Box::new(sender.clone());
    let mut handle: HANDLE = ptr::null_mut();
    // SAFETY: callback signature matches IP Helper API; context remains valid until
    // cancellation completes. We subscribe before the first scan to avoid startup races.
    let rc = unsafe {
        NotifyIpInterfaceChange(
            AF_INET,
            Some(ip_callback),
            (&*ctx as *const SyncSender<Signal>).cast::<c_void>(),
            false,
            &mut handle,
        )
    };
    if rc != 0 {
        log(&format!(
            "[WARN] NotifyIpInterfaceChange unavailable ({rc}); periodic sweep remains active"
        ));
    }
    let mut previous: Option<Status> = None;
    log("[INFO] MTU Guard started");

    while !stopping.load(Ordering::Acquire) {
        let result = reconcile();
        if previous.as_ref() != Some(&result) {
            log(&result.display());
            previous = Some(result);
        }
        match receiver.recv_timeout(SWEEP) {
            Ok(Signal::Stop) | Err(RecvTimeoutError::Disconnected) => break,
            Ok(Signal::NetworkChanged) => {
                if settle_events(receiver, stopping, SETTLE) {
                    break;
                }
            }
            Err(RecvTimeoutError::Timeout) => {}
        }
    }

    before_cleanup();
    if rc == 0 && !handle.is_null() {
        // SAFETY: cancellation runs on worker thread, never inside notification callback.
        let error = unsafe { CancelMibChangeNotify2(handle) };
        if error != 0 {
            log(&format!("[WARN] CancelMibChangeNotify2: {error}; retaining callback context until process exit"));
            // Cancellation failed: Windows may still invoke the callback. Releasing
            // its context here would cause a use-after-free. The OS reclaims it on exit.
            let _ = Box::leak(ctx);
            return;
        }
    }
    drop(ctx);
    log("[INFO] MTU Guard stopped");
}

pub fn run_console() -> AppResult<()> {
    let (tx, rx) = mpsc::sync_channel(1);
    println!("[INFO] Monitoring {TARGET_ALIAS}; press Ctrl+C to stop");
    loop_guard(&rx, &tx, &AtomicBool::new(false), || {});
    Ok(())
}

define_windows_service!(ffi_service_main, service_main);

fn service_main(_arguments: Vec<std::ffi::OsString>) {
    if let Err(err) = service_body() {
        log(&format!("[FAIL] service: {err}"));
    }
}

fn service_body() -> windows_service::Result<()> {
    let (tx, rx) = mpsc::sync_channel(1);
    let stop_tx = tx.clone();
    let stopping = Arc::new(AtomicBool::new(false));
    let stop_flag = Arc::clone(&stopping);
    let handler = move |event| -> ServiceControlHandlerResult {
        match event {
            ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
            ServiceControl::Stop | ServiceControl::Shutdown => {
                request_stop(&stop_tx, &stop_flag);
                ServiceControlHandlerResult::NoError
            }
            _ => ServiceControlHandlerResult::NotImplemented,
        }
    };
    let status = service_control_handler::register(SERVICE_NAME, handler)?;
    let report = |current_state: ServiceState, accepted: ServiceControlAccept| ServiceStatus {
        service_type: ServiceType::OWN_PROCESS,
        current_state,
        controls_accepted: accepted,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::ZERO,
        process_id: None,
    };
    status.set_service_status(report(
        ServiceState::Running,
        ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
    ))?;
    loop_guard(&rx, &tx, &stopping, || {
        let mut pending = report(ServiceState::StopPending, ServiceControlAccept::empty());
        pending.checkpoint = 1;
        pending.wait_hint = Duration::from_secs(20);
        if let Err(err) = status.set_service_status(pending) {
            log(&format!("[WARN] Could not report STOP_PENDING: {err}"));
        }
    });
    status.set_service_status(report(ServiceState::Stopped, ServiceControlAccept::empty()))?;
    Ok(())
}

pub fn run_service() -> windows_service::Result<()> {
    // Connect to SCM immediately; no network work before service dispatcher.
    service_dispatcher::start(SERVICE_NAME, ffi_service_main)
}

#[cfg(test)]
mod tests;
