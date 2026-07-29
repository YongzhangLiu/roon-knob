#!/usr/bin/env python3
"""Validate declared release invariants against IDF's *resolved* configuration.

Issue #202. Committed defaults (``sdkconfig.defaults``) are an *input*: they can be
stale, renamed, ignored because ``sdkconfig`` already exists, or overridden by
``sdkconfig.local`` / ``SDKCONFIG_DEFAULTS`` / ``-D`` cache variables. They therefore
cannot prove what the compiler actually used. IDF's generated
``build/config/sdkconfig.json`` can, so that is the only thing this checker reads
for invariant evaluation.

Design constraints (from the accepted solution/review/dissent for #202):

* **Dependency-free.** Python standard library only, so it runs on a bare CI host
  as well as inside the IDF container.
* **Explicit config path.** No searching, no implicit build dir. ``--config`` is
  required, which is what makes the fixtures possible.
* **Stable tokens.** Every verdict is emitted as an ``RK-RELCFG-*`` token. CI and
  the fixture runner match those tokens exactly, so "the build failed" is never
  mistaken for "the gate fired".
* **The checker identifies its own failure.** A missing or malformed config is
  ``RK-RELCFG-NOCONFIG`` (exit 3), never a silent pass.
* **Undefined ``sdkconfig.defaults`` symbols are kconfgen's verdict, not ours.**
  ``esp-idf-kconfig`` already decides this on the exact input file, with correct
  alias/rename semantics, and prints:

      warning: unknown kconfig symbol 'SYM' assigned to 'VALUE' in FILE

  This checker only *consumes* that line from a build log (``--log``). It never
  reimplements the determination, and it never echoes the assigned value -- the
  value can be a credential (``sdkconfig.defaults`` historically carried one), so
  only the symbol name is ever extracted or reported.
* **Absent != satisfied, where absence is meaningful.** IDF omits symbols from
  ``sdkconfig.json`` when they are not written out, so the rule is directional:
  a ``true``-expected symbol that is absent is a violation (it is definitely not
  enabled), a ``false``-expected symbol that is absent is satisfied, and the whole
  optimization choice family being absent is ``RK-RELCFG-UNDEFINED`` (the symbol
  names themselves have moved -- a checker-integrity failure, not a config error).

Exit codes -- stable, asserted by ``tools/test_check_release_config.sh``:

===== =========================== =============================================
Code  Token                       Meaning
===== =========================== =============================================
0     ``RK-RELCFG-OK``            every declared invariant holds
2     ``RK-RELCFG-VIOLATION``     config resolved to a value the release forbids
3     ``RK-RELCFG-NOCONFIG``      config missing / unreadable / malformed
4     ``RK-RELCFG-UNDEFINED``     symbol family absent, or kconfgen reported an
                                  assignment to an unknown symbol
64    ``RK-RELCFG-USAGE``         bad invocation (distinct from every verdict)
===== =========================== =============================================

``--enforced`` never changes the exit code. It is recorded in the report and the
banner only; suppressing *failure* is the caller's decision (CMake's
``RK_ENFORCE_RELEASE_CONFIG``), and suppressing the *record* is never allowed.

Invariant symbol names and the expected defaults below were verified against the
exact ESP-IDF commit CI built with, ``8543b57cf15853fd8648cb12e63a1b0e7ea4075b``
(``v5.4.4-1000-g8543b57cf15``); see
docs/meta/decisions/2026-07-29_DECISION_EFFECTIVE_RELEASE_CONFIG.md.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

SCHEMA = "rk-release-config/1"
ISSUE = 202

EXIT_OK = 0
EXIT_VIOLATION = 2
EXIT_NOCONFIG = 3
EXIT_UNDEFINED = 4
EXIT_USAGE = 64

TOKEN_OK = "RK-RELCFG-OK"
TOKEN_VIOLATION = "RK-RELCFG-VIOLATION"
TOKEN_NOCONFIG = "RK-RELCFG-NOCONFIG"
TOKEN_UNDEFINED = "RK-RELCFG-UNDEFINED"
TOKEN_USAGE = "RK-RELCFG-USAGE"

# kconfgen's own wording, from esp-idf-kconfig's defaults-loading path. Verified
# byte-identical across every release the release-v5.4 constraint
# (esp-idf-kconfig>=2.0.2,<3.0.0) can resolve to, and observed verbatim in the
# #202 measurement logs produced by the CI image. The value is deliberately NOT
# captured: it may be a credential.
KCONFGEN_UNKNOWN_RE = re.compile(r"warning: unknown kconfig symbol '([A-Za-z0-9_]+)' assigned to ")

# The optimization invariant is deliberately looser than "the measured winner".
# sdkconfig.defaults carries the measured choice (SIZE, see the ADR); the gate
# only insists the build is optimized, so that a hardware-driven SIZE<->PERF
# switch in #203 does not require editing the gate, its fixtures and the ADR.
CHOICE_INVARIANT = {
    "name": "COMPILER_OPTIMIZATION",
    "kind": "choice_exactly_one",
    "allowed": ["COMPILER_OPTIMIZATION_SIZE", "COMPILER_OPTIMIZATION_PERF"],
    "rejected": ["COMPILER_OPTIMIZATION_DEBUG", "COMPILER_OPTIMIZATION_NONE"],
    "why": "release builds must be optimized; exactly one of SIZE/PERF, never DEBUG/NONE",
}

# (symbol, expected, why). Expected True means "absence is a violation".
BOOL_INVARIANTS = [
    ("COMPILER_OPTIMIZATION_ASSERTIONS_ENABLE", True,
     "OTA field devices with no crash-reporting channel; pins IDF's own default"),
    ("SPIRAM", True, "artwork RGB565 buffers do not fit without PSRAM"),
    ("PARTITION_TABLE_CUSTOM", True, "OTA layout comes from partitions.csv"),
    ("HEAP_POISONING_DISABLED", True, "heap poisoning is a debug-only cost"),
    ("HEAP_TRACING_OFF", True, "heap tracing adds permanent IRAM and malloc overhead"),
    ("COMPILER_DUMP_RTL_FILES", False, "debug-only compiler output"),
    ("ESP_DEBUG_STUBS_ENABLE", False, "debug-only on-target stubs"),
    ("ESP_SYSTEM_PANIC_GDBSTUB", False, "a field device must reboot, not wait for gdb"),
    ("FREERTOS_USE_TRACE_FACILITY", False, "debug-only scheduler bookkeeping"),
]

# Asserted only at the value sdkconfig.defaults already declares (lines 9-10).
# #202 takes no position on 8MB vs 16MB and touches no image header: that
# disagreement belongs to #203.
STRING_INVARIANTS = [
    ("ESPTOOLPY_FLASHSIZE", "16MB",
     "must match the flash size the committed defaults declare; direction is #203"),
]


def sanitize(line: str) -> str:
    """Make a line safe for CMake's ``fail_at_build_time`` (``ARGN`` splits on ``;``)."""
    return line.replace(";", ",").replace("\r", " ").replace("\n", " ").strip()


def sha256_file(path: str) -> str | None:
    try:
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(65536), b""):
                digest.update(chunk)
        return "sha256:" + digest.hexdigest()
    except OSError:
        return None


def evaluate(cfg: dict) -> tuple[list[dict], list[str], list[str]]:
    """Return (rows, violation_symbols, undefined_names)."""
    rows: list[dict] = []
    violations: list[str] = []
    undefined: list[str] = []

    members = CHOICE_INVARIANT["allowed"] + CHOICE_INVARIANT["rejected"]
    present = [m for m in members if m in cfg]
    selected = [m for m in CHOICE_INVARIANT["allowed"] if cfg.get(m) is True]
    forbidden_on = [m for m in CHOICE_INVARIANT["rejected"] if cfg.get(m) is True]

    if not present:
        # The whole family is missing: the symbol names have moved out from under
        # us. Absent must not read as pass.
        rows.append({
            "name": CHOICE_INVARIANT["name"],
            "kind": CHOICE_INVARIANT["kind"],
            "expected": "exactly one of %s true; %s false"
                        % (CHOICE_INVARIANT["allowed"], CHOICE_INVARIANT["rejected"]),
            "actual": "no member of the choice is present in the resolved config",
            "status": "undefined",
            "why": CHOICE_INVARIANT["why"],
        })
        undefined.append(CHOICE_INVARIANT["name"])
    else:
        status = "pass"
        for sym in forbidden_on:
            violations.append(sym)
            status = "fail"
        if len(selected) != 1:
            violations.append("COMPILER_OPTIMIZATION_CHOICE")
            status = "fail"
        rows.append({
            "name": CHOICE_INVARIANT["name"],
            "kind": CHOICE_INVARIANT["kind"],
            "expected": "exactly one of %s true; %s false"
                        % (CHOICE_INVARIANT["allowed"], CHOICE_INVARIANT["rejected"]),
            "actual": {m: cfg.get(m, None) for m in members},
            "status": status,
            "why": CHOICE_INVARIANT["why"],
        })

    for sym, expected, why in BOOL_INVARIANTS:
        actual = cfg.get(sym, None)
        if expected:
            # Absent means "not written out", which means "not enabled".
            status = "pass" if actual is True else "fail"
        else:
            if sym not in cfg:
                status = "absent_satisfied"
            else:
                status = "pass" if actual is not True else "fail"
        if status == "fail":
            violations.append(sym)
        rows.append({"name": sym, "kind": "bool", "expected": expected,
                     "actual": actual, "status": status, "why": why})

    for sym, expected, why in STRING_INVARIANTS:
        actual = cfg.get(sym, None)
        status = "pass" if actual == expected else "fail"
        if status == "fail":
            violations.append(sym)
        rows.append({"name": sym, "kind": "string", "expected": expected,
                     "actual": actual, "status": status, "why": why})

    return rows, violations, undefined


def scan_logs(paths: list[str]) -> tuple[list[str], list[dict]]:
    """Collect kconfgen-reported unknown symbols. Names only -- never values."""
    found: list[str] = []
    scanned: list[dict] = []
    for path in paths:
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError as exc:
            scanned.append({"path": path, "read": False, "error": exc.__class__.__name__})
            continue
        hits = sorted({m.group(1) for m in KCONFGEN_UNKNOWN_RE.finditer(text)})
        scanned.append({"path": path, "read": True, "unknown_symbols": hits})
        for sym in hits:
            if sym not in found:
                found.append(sym)
    return sorted(found), scanned


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check_release_config.py",
        description="Validate release invariants against IDF's resolved sdkconfig.json.",
        add_help=True,
    )
    parser.add_argument("--config", required=True,
                        help="path to IDF's generated build/config/sdkconfig.json")
    parser.add_argument("--report", help="path to write the JSON report")
    parser.add_argument("--enforced", choices=["yes", "no"], default="no",
                        help="record whether the caller will fail the build on a bad verdict")
    parser.add_argument("--log", action="append", default=[], metavar="PATH",
                        help="build/configure log to scan for kconfgen's unknown-symbol "
                             "warning (repeatable)")
    parser.add_argument("--defaults", action="append", default=[], metavar="PATH",
                        help="defaults file to record for provenance (repeatable); never "
                             "parsed for invariants -- kconfgen owns that verdict")

    # A usage error must not be confusable with a verdict, so it gets its own code.
    def _usage_error(message: str) -> None:
        sys.stdout.write(sanitize("%s: %s" % (TOKEN_USAGE, message)) + "\n")
        raise SystemExit(EXIT_USAGE)

    parser.error = _usage_error  # type: ignore[assignment]

    args = parser.parse_args(argv)

    lines: list[str] = []
    tokens: list[str] = []
    cfg: dict | None = None
    noconfig_reason: str | None = None

    if not os.path.isfile(args.config):
        noconfig_reason = "no such file: %s" % args.config
    else:
        try:
            with open(args.config, encoding="utf-8") as handle:
                loaded = json.load(handle)
            if not isinstance(loaded, dict):
                noconfig_reason = "top-level JSON value is %s, expected object" \
                                  % type(loaded).__name__
            else:
                cfg = loaded
        except json.JSONDecodeError as exc:
            noconfig_reason = "malformed JSON at line %d: %s" % (exc.lineno, exc.msg)
        except OSError as exc:
            noconfig_reason = "unreadable: %s" % exc.__class__.__name__

    rows: list[dict] = []
    violations: list[str] = []
    undefined: list[str] = []
    log_symbols, logs_scanned = scan_logs(args.log)

    if cfg is None:
        tokens.append("%s: %s" % (TOKEN_NOCONFIG, noconfig_reason))
        exit_code = EXIT_NOCONFIG
    else:
        rows, violations, undefined = evaluate(cfg)
        undefined = undefined + ["CONFIG_%s" % s for s in log_symbols]
        if undefined:
            for name in undefined:
                tokens.append("%s: %s" % (TOKEN_UNDEFINED, name))
            exit_code = EXIT_UNDEFINED
        elif violations:
            for sym in violations:
                tokens.append("%s: %s" % (TOKEN_VIOLATION, sym))
            exit_code = EXIT_VIOLATION
        else:
            tokens.append(TOKEN_OK)
            exit_code = EXIT_OK

    verdict = "pass" if exit_code == EXIT_OK else "fail"
    digest = sha256_file(args.config)

    report = {
        "schema": SCHEMA,
        "issue": ISSUE,
        "enforced": args.enforced == "yes",
        "verdict": verdict,
        "exit_code": exit_code,
        "tokens": tokens,
        "config_path": os.path.abspath(args.config),
        "config_digest": digest,
        "defaults": [{"path": os.path.abspath(p), "digest": sha256_file(p)}
                     for p in args.defaults],
        "invariants": rows,
        "undefined_symbols": undefined,
        "logs_scanned": logs_scanned,
    }

    if args.report:
        try:
            parent = os.path.dirname(os.path.abspath(args.report))
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(args.report, "w", encoding="utf-8") as handle:
                json.dump(report, handle, indent=2, sort_keys=True)
                handle.write("\n")
            lines.append("RK-RELCFG-REPORT: %s" % args.report)
        except OSError as exc:
            lines.append("RK-RELCFG-REPORT-ERROR: %s" % exc.__class__.__name__)

    if args.enforced == "yes":
        lines.append("RK-RELCFG-ENFORCED: violations fail the build")
    else:
        lines.append("***********************************************************")
        lines.append("*** RELEASE CONFIG INVARIANTS NOT ENFORCED              ***")
        lines.append("*** RK_ENFORCE_RELEASE_CONFIG=OFF - local builds only   ***")
        lines.append("***********************************************************")

    lines.extend(tokens)
    if digest:
        lines.append("RK-RELCFG-DIGEST: %s" % digest)
    lines.append("RK-RELCFG-VERDICT: %s" % verdict)

    # Guarantee non-empty, ;-free output: CMake's fail_at_build_time() takes a
    # required positional first line and splits ARGN on ';'.
    out = [sanitize(line) for line in lines]
    out = [line for line in out if line]
    if not out:
        out = ["RK-RELCFG-INTERNAL: checker produced no output"]
    sys.stdout.write("\n".join(out) + "\n")
    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
