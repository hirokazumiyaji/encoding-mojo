# Repository Guidelines

## Project Structure & Module Organization

This repository provides pure-Mojo data-format libraries. Shared value storage lives in `src/serde/`; public packages are in `src/json/`, `src/yaml/`, `src/toml/`, and `src/csv/`. Each package has an `__init__.mojo` and package-specific implementation files. Tests live in matching `test/<package>/` directories and use `test_*.mojo` names. Benchmarks and Python baselines are under `bench/<package>/`; build, test, and compatibility-case tools are in `scripts/`.

## Build, Test, and Development Commands

Install the Mojo compiler (the project targets Mojo 1.0). Then use:

- `./scripts/run_tests.sh` to run every test module; pass test paths to run selected modules, for example `./scripts/run_tests.sh test/json/test_api.mojo`.
- `./scripts/build_packages.sh` to precompile packages into ignored `build/` outputs.
- `mojo run -I src path/to/program.mojo` to run a program against the source packages.
- `python3 scripts/gen_compat_cases.py` (or the YAML, TOML, or CSV variant) to regenerate differential compatibility cases. Edit generators rather than generated compatibility suites; these scripts require their relevant Python reference packages.

## Coding Style & Naming Conventions

Follow the surrounding Mojo code and keep changes simple, focused, and reusable. Use four-space indentation, descriptive `snake_case` names for functions and files, and `test_*.mojo` for test modules. Prefer direct implementations over compatibility shims or extra fallback paths. Add comments only to explain intent or rationale, not mechanics.

## Testing Guidelines

Tests are standalone Mojo modules rather than a separate test framework. Add focused cases under the corresponding `test/<package>/` directory and run the affected module, then `./scripts/run_tests.sh` for broader changes. Compatibility tests compare generated cases against the respective Python libraries.

## Commit & Pull Request Guidelines

Recent commits use short, imperative subjects describing the change (for example, “Add a CSV package…” or “Fix … defects”); no rigid prefix convention is evident. Keep commits focused. Pull requests should describe behavior and affected packages, link related issues when applicable, and report the test or build commands run. Include benchmark results when performance claims motivate the change.

## Security & Configuration

Generated build artifacts, bytecode, and benchmark data are ignored by Git. Keep generated files and local environment configuration out of commits; do not include secrets in fixtures or examples.
