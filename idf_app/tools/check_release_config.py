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
5     ``RK-RELCFG-NOLOG``         a log was *requested* via ``--log`` but is
                                  absent, unreadable, empty, or missing a marker
                                  required by ``--log-must-contain``
6     ``RK-RELCFG-NOREPORT``      a report was *requested* via ``--report`` but
                                  could not be written
64    ``RK-RELCFG-USAGE``         bad invocation (distinct from every verdict)
===== =========================== =============================================

**Precedence, when more than one condition holds:**

```
NOCONFIG (3)  >  NOREPORT (6)  >  NOLOG (5)  >  UNDEFINED (4)  >  VIOLATION (2)
```

The first three mean the checker could not make, or could not record, a
trustworthy determination, and must not be reported as a mere policy violation.
Every applicable token is still printed, so nothing is hidden by the precedence;
only the *exit code* is single-valued. A config that is both undefined and
violating exits 4 while the violation rows remain visible in the report's
``invariants``.

**A requested report that cannot be written is a failure, and the verdict cannot
be "pass".** ``--report`` is the artifact CI audits, so writing nothing while
printing ``RK-RELCFG-OK`` would be the same fail-open asymmetry as treating a
missing ``--log`` as silence. When the write fails, the ``OK`` token is withdrawn,
``RK-RELCFG-NOREPORT`` is emitted, the printed verdict becomes ``fail``, and the
exit code becomes 6 (or stays 3 if the config was also unusable). Passing no
``--report`` is different and legitimate — no artifact was requested, so none is
owed.

The report is written **atomically** (temp file plus ``os.replace``) so a failure
partway through can never leave a truncated file that a later reader would parse
as a pass.

**A requested log that cannot be read is a failure, not silence.** ``--log`` is
how the kconfgen-delegated undefined-symbol determination reaches this checker,
so treating an absent, unreadable or empty log as "nothing found" would make that
determination fail *open* — the exact asymmetry this design rejects everywhere
else ("absent != satisfied"). Passing no ``--log`` at all is different and
legitimate: the determination is then simply not requested, which is the case for
the configure-time CMake gate, and it never fails on that basis.

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
EXIT_NOLOG = 5
EXIT_NOREPORT = 6
EXIT_USAGE = 64

TOKEN_OK = "RK-RELCFG-OK"
TOKEN_VIOLATION = "RK-RELCFG-VIOLATION"
TOKEN_NOCONFIG = "RK-RELCFG-NOCONFIG"
TOKEN_UNDEFINED = "RK-RELCFG-UNDEFINED"
TOKEN_NOLOG = "RK-RELCFG-NOLOG"
TOKEN_NOREPORT = "RK-RELCFG-NOREPORT"
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


def scan_logs(paths: list[str], markers: list[str]) -> tuple[list[str], list[dict], list[str]]:
    """Collect kconfgen-reported unknown symbols from *requested* logs.

    Returns (unknown_symbol_names, per_log_records, problems).

    Requesting a log via --log is a claim that the log exists and holds the
    kconfgen output to be judged. If it does not, that claim is false and the
    caller must hear about it: the path is recorded with ``read: false`` (or
    ``bytes: 0``) and a problem is returned, which main() turns into
    RK-RELCFG-NOLOG and a non-zero exit. Silence is never inferred from absence.

    Nothing from a log's *contents* is ever placed in the returned data or the
    problems: only symbol names, the path, a byte count, and marker booleans.
    Log lines carry assigned values, which can be credentials.
    """
    found: list[str] = []
    scanned: list[dict] = []
    problems: list[str] = []
    marker_seen = {marker: False for marker in markers}

    for path in paths:
        record: dict = {"path": path, "read": False, "bytes": 0}
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError as exc:
            record["error"] = exc.__class__.__name__
            scanned.append(record)
            problems.append("requested log could not be read (%s): %s"
                            % (exc.__class__.__name__, path))
            continue

        record["read"] = True
        record["bytes"] = len(text)
        if not text.strip():
            record["empty"] = True
            scanned.append(record)
            problems.append("requested log is empty: %s" % path)
            continue

        hits = sorted({m.group(1) for m in KCONFGEN_UNKNOWN_RE.finditer(text)})
        record["unknown_symbols"] = hits
        record["markers_found"] = sorted(m for m in markers if m in text)
        for marker in markers:
            if marker in text:
                marker_seen[marker] = True
        scanned.append(record)
        for sym in hits:
            if sym not in found:
                found.append(sym)

    for marker in markers:
        if not marker_seen[marker]:
            problems.append("no requested log contains the required marker %r "
                            "(the log read is not the one the gate wrote)" % marker)

    return sorted(found), scanned, problems


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
                             "warning (repeatable). Requesting a log makes its presence, "
                             "readability and non-emptiness part of the contract: a log "
                             "that cannot be read is RK-RELCFG-NOLOG, not silence.")
    parser.add_argument("--log-must-contain", action="append", default=[], metavar="TEXT",
                        help="require TEXT to appear in at least one --log (repeatable); "
                             "proves the log actually read is the one the gate wrote")
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
    log_symbols, logs_scanned, log_problems = scan_logs(args.log, args.log_must_contain)

    if cfg is not None:
        rows, violations, undefined = evaluate(cfg)
        undefined = undefined + ["CONFIG_%s" % s for s in log_symbols]

    # Emit every applicable token, then let precedence pick the single exit code:
    # NOCONFIG > NOLOG > UNDEFINED > VIOLATION. The first three mean "no
    # trustworthy determination was made" and must outrank a policy violation.
    if cfg is None:
        tokens.append("%s: %s" % (TOKEN_NOCONFIG, noconfig_reason))
    for problem in log_problems:
        tokens.append("%s: %s" % (TOKEN_NOLOG, problem))
    for name in undefined:
        tokens.append("%s: %s" % (TOKEN_UNDEFINED, name))
    for sym in violations:
        tokens.append("%s: %s" % (TOKEN_VIOLATION, sym))

    if cfg is None:
        exit_code = EXIT_NOCONFIG
    elif log_problems:
        exit_code = EXIT_NOLOG
    elif undefined:
        exit_code = EXIT_UNDEFINED
    elif violations:
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
        # Provenance only, and deliberately non-failing: --defaults is never
        # parsed, so nothing is inferred from a defaults file being absent and it
        # cannot make any determination fail open. `readable` is recorded so a
        # mis-wired path is still visible rather than merely implied by a null.
        "defaults": [{"path": os.path.abspath(p),
                      "digest": sha256_file(p),
                      "readable": sha256_file(p) is not None}
                     for p in args.defaults],
        "invariants": rows,
        "undefined_symbols": undefined,
        "logs_requested": len(args.log),
        "logs_scanned": logs_scanned,
        "logs_required_markers": list(args.log_must_contain),
        "log_problems": log_problems,
    }

    # A requested report that cannot be written is a determination that cannot be
    # recorded, which is not a trustworthy pass. Written atomically so a partial
    # file can never be parsed as a pass by a later reader.
    report_problem: str | None = None
    if args.report:
        tmp_path = args.report + ".tmp"
        try:
            parent = os.path.dirname(os.path.abspath(args.report))
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(tmp_path, "w", encoding="utf-8") as handle:
                json.dump(report, handle, indent=2, sort_keys=True)
                handle.write("\n")
            os.replace(tmp_path, args.report)
            lines.append("RK-RELCFG-REPORT: %s" % args.report)
        except OSError as exc:
            report_problem = "requested report could not be written (%s): %s" \
                             % (exc.__class__.__name__, args.report)
            try:
                if os.path.exists(tmp_path):
                    os.unlink(tmp_path)
            except OSError:
                pass

    if report_problem:
        # Withdraw OK: nothing may print a passing verdict after failing to
        # produce the artifact CI audits. NOCONFIG still outranks NOREPORT.
        tokens = [t for t in tokens if t != TOKEN_OK]
        tokens.append("%s: %s" % (TOKEN_NOREPORT, report_problem))
        verdict = "fail"
        if cfg is not None:
            exit_code = EXIT_NOREPORT

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
