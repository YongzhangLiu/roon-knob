#!/usr/bin/env python3
"""Host-side assertion over the release-config report. Issue #202.

This is the layer that makes "CI cannot opt out" true rather than assumed.
Forcing ``-DRK_ENFORCE_RELEASE_CONFIG=ON`` in the container is necessary but not
sufficient: the flag could be flipped, the checker deleted, or the CMake call
removed, and the build would still go green. So CI additionally requires, *on the
host*, that the build produced a report which says the gate really ran, really
enforced, and really passed -- over the same config file the build resolved.

Assertions:

* the report exists, is JSON, and declares the expected schema
* ``enforced`` matches ``--expect-enforced`` (default ``true``)
* ``verdict`` matches ``--expect-verdict`` (default ``pass``)
* with ``--config``, ``config_digest`` equals a locally computed sha256 of that
  file -- so a stale report from an earlier configure cannot be replayed

Exit 0 when every assertion holds, 1 when any fails, 64 on bad usage.

The residual ceiling is stated honestly in the ADR: this script catches a flipped
flag, a deleted checker and a removed CMake call, but deleting *this step* from
the workflow is not detectable in-repo. Closing that requires branch protection
with required checks, which #202 does not touch.

Standard library only, so it runs on a bare CI host with no ESP-IDF present.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

SCHEMA = "rk-release-config/1"
TOKEN_OK = "RK-RELCFG-ASSERT-OK"
TOKEN_FAIL = "RK-RELCFG-ASSERT-FAIL"
TOKEN_USAGE = "RK-RELCFG-ASSERT-USAGE"

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_USAGE = 64


def sha256_file(path: str) -> str | None:
    try:
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(65536), b""):
                digest.update(chunk)
        return "sha256:" + digest.hexdigest()
    except OSError:
        return None


def observed_markers(report: dict) -> set:
    """Markers the report says it actually saw, across every scanned log."""
    found: set = set()
    scanned = report.get("logs_scanned")
    if isinstance(scanned, list):
        for entry in scanned:
            if isinstance(entry, dict):
                found.update(entry.get("markers_found") or [])
    return found


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="assert_release_report.py",
        description="Assert a #202 release-config report proves the gate ran and passed.",
    )
    parser.add_argument("--report", required=True, help="path to rk_release_config.json")
    parser.add_argument("--config", help="path to the sdkconfig.json the report should describe")
    parser.add_argument("--expect-verdict", choices=["pass", "fail"], default="pass")
    parser.add_argument("--expect-enforced", choices=["true", "false"], default="true")
    parser.add_argument("--require-logs-read", action="store_true",
                        help="additionally require the report to prove a log was actually "
                             "read: at least one entry in logs_scanned, every entry "
                             "read with non-zero bytes, every required marker found, and "
                             "no recorded log problems")
    parser.add_argument("--expect-log-marker", action="append", default=[], metavar="TEXT",
                        help="require TEXT to appear in some logs_scanned[].markers_found "
                             "(repeatable). Checked against what the report OBSERVED, "
                             "independently of logs_required_markers -- which is the "
                             "report's own claim about what was asked of it, and so cannot "
                             "prove the marker was ever required. Supply this from the "
                             "caller (CI) to make the log-identity check caller-owned.")

    def _usage_error(message: str) -> None:
        sys.stdout.write("%s: %s\n" % (TOKEN_USAGE, message))
        raise SystemExit(EXIT_USAGE)

    parser.error = _usage_error  # type: ignore[assignment]
    args = parser.parse_args(argv)

    failures: list[str] = []
    report: dict | None = None

    if not os.path.isfile(args.report):
        failures.append("no report at %s (checker did not run, or CMake call removed)"
                        % args.report)
    else:
        try:
            with open(args.report, encoding="utf-8") as handle:
                loaded = json.load(handle)
            if isinstance(loaded, dict):
                report = loaded
            else:
                failures.append("report top-level JSON is %s, expected object"
                                % type(loaded).__name__)
        except json.JSONDecodeError as exc:
            failures.append("report is malformed JSON at line %d: %s" % (exc.lineno, exc.msg))
        except OSError as exc:
            failures.append("report unreadable: %s" % exc.__class__.__name__)

    if report is not None:
        if report.get("schema") != SCHEMA:
            failures.append("schema is %r, expected %r" % (report.get("schema"), SCHEMA))

        expect_enforced = args.expect_enforced == "true"
        if report.get("enforced") is not expect_enforced:
            failures.append("enforced is %r, expected %r"
                            % (report.get("enforced"), expect_enforced))

        if report.get("verdict") != args.expect_verdict:
            failures.append("verdict is %r, expected %r"
                            % (report.get("verdict"), args.expect_verdict))

        if args.require_logs_read:
            # A report that scanned no log cannot be evidence that the
            # kconfgen-delegated undefined-symbol determination was made.
            scanned = report.get("logs_scanned")
            if not isinstance(scanned, list) or not scanned:
                failures.append("report proves no log was read (logs_scanned is empty): "
                                "the undefined-symbol determination did not happen")
            else:
                for entry in scanned:
                    path = entry.get("path") if isinstance(entry, dict) else "<malformed>"
                    if not isinstance(entry, dict) or entry.get("read") is not True:
                        failures.append("report says log was not read: %s" % path)
                    elif not entry.get("bytes"):
                        failures.append("report says log was empty: %s" % path)
            required = report.get("logs_required_markers") or []
            for marker in required:
                if marker not in observed_markers(report):
                    failures.append("report does not show required log marker %r" % marker)
            problems = report.get("log_problems") or []
            for problem in problems:
                failures.append("report records a log problem: %s" % problem)

        # Caller-owned log identity. Deliberately NOT gated on --require-logs-read
        # and deliberately NOT read from logs_required_markers: if a workflow edit
        # drops --log-must-contain, the report records an empty requirement list and
        # a report-sourced check iterates zero times and passes. The expected marker
        # therefore has to come from here, the auditor's side.
        if args.expect_log_marker:
            found = observed_markers(report)
            scanned = report.get("logs_scanned")
            if not isinstance(scanned, list) or not scanned:
                failures.append("expected log marker(s) %s but the report scanned no log"
                                % args.expect_log_marker)
            for marker in args.expect_log_marker:
                if marker not in found:
                    failures.append("report does not show expected log marker %r in any "
                                    "logs_scanned[].markers_found: the log audited is not "
                                    "the one the gate wrote" % marker)

        if args.config:
            local = sha256_file(args.config)
            if local is None:
                failures.append("cannot digest %s" % args.config)
            elif report.get("config_digest") != local:
                failures.append("config_digest %r does not match local digest of %s (%r): "
                                "the report does not describe this build"
                                % (report.get("config_digest"), args.config, local))

    if failures:
        for reason in failures:
            sys.stdout.write("%s: %s\n" % (TOKEN_FAIL, reason))
        return EXIT_FAIL

    sys.stdout.write("%s: enforced=%s verdict=%s%s%s\n"
                     % (TOKEN_OK, args.expect_enforced, args.expect_verdict,
                        " digest-matched" if args.config else "",
                        " markers=%s" % ",".join(args.expect_log_marker)
                        if args.expect_log_marker else ""))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
