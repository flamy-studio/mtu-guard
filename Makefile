.PHONY: help fmt fmt-check lint test build-win release-check clean
help:
	@echo "fmt fmt-check lint test build-win release-check clean"
fmt:
	cargo fmt
fmt-check:
	cargo fmt --all -- --check
lint:
	cargo clippy --locked --target x86_64-pc-windows-msvc --all-targets -- -D warnings
test:
	cargo test --locked --all-targets
build-win:
	cargo build --release --locked --target x86_64-pc-windows-msvc
release-check: fmt-check lint test build-win
clean:
	cargo clean
