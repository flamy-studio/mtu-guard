mod policy;

#[cfg(windows)]
mod win;

fn help() {
    println!(
        "MTU Guard {} | Flamy Studio / Withen Network",
        env!("CARGO_PKG_VERSION")
    );
    println!("Usage: withen-mtu-guard <status|check|fix|service|run-console|version>");
    println!("  status         Inspect the unique active AmneziaVPN[/ N] IPv4 adapter (read-only)");
    println!(
        "  check          Health check: 0=1280, 3=waiting, 4=MTU drift, 1=API error/ambiguity"
    );
    println!("  fix            Enforce 1280 once (administrator required)");
    println!("  service        Windows Service Control Manager entry point");
    println!("  run-console    Debug loop (Ctrl+C to stop)");
}

fn main() {
    let command = std::env::args().nth(1).unwrap_or_else(|| "help".into());
    if command == "version" || command == "--version" {
        println!("{}", env!("CARGO_PKG_VERSION"));
        return;
    }
    #[cfg(windows)]
    {
        let result = match command.as_str() {
            "status" => win::print_status(false),
            "check" => win::print_status(true),
            "fix" => win::fix_once().map(|()| 0),
            "service" => win::run_service()
                .map(|()| 0)
                .map_err(|err| err.to_string()),
            "run-console" => win::run_console().map(|()| 0),
            "help" | "-h" | "--help" => {
                help();
                return;
            }
            _ => {
                help();
                std::process::exit(2);
            }
        };
        match result {
            Ok(code) if code != 0 => std::process::exit(code),
            Ok(_) => {}
            Err(err) => {
                eprintln!("[FAIL] {err}");
                std::process::exit(1);
            }
        }
    }
    #[cfg(not(windows))]
    {
        let _ = command;
        help();
        eprintln!("[INFO] Runtime is Windows-only. Pure policy tests can run on other OSes.");
    }
}
