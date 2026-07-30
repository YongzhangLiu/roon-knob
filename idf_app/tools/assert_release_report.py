#!/usr/bin/env python3
"""Host-side assertion over the release-config report. Issue #202.

This is the layer that makes one narrow claim true rather than assumed: **a
``build-idf`` job cannot run UNENFORCED**. Forcing
``-DRK_ENFORCE_RELEASE_CONFIG=ON`` in the container is necessary but not
sufficient: the flag could be flipped, the checker deleted, or the CMake call
removed, and the build would still go green. So CI additionally requires, *on the
host*, that the build produced a report which says the gate really ran, really
enforced, and really passed -- over the same config file the build resolved.

The claim stops exactly there. It is deliberately NOT "CI cannot opt out":

* **Publication eligibility is gated**, by a real in-repo dependency: ``release``
  *and* ``deploy-pr-preview`` both declare
  ``needs: [build-idf, release-config-fixtures, build-stale-config]``, so any one
  of the three proof jobs red or skipped stops both a published firmware asset and
  a flashable preview. An earlier revision of this docstring described an
  asymmetry -- the preview path needing only two of the three, so a red
  ``build-stale-config`` alone stopped a release but not a preview. That gap is
  closed; the two prerequisite lists are now identical. This is job-graph parity,
  not full artifact-validation parity: ``release`` later re-asserts the downloaded
  report before publishing, while ``deploy-pr-preview`` does not. #210 tracks that
  caller-workflow gap.
* **Merging is not gated.** Branch protection on ``master`` currently defines no
  required status checks, so a maintainer can merge with every #202 job red.
  Nothing in this file, or anywhere in this tree, changes that.

Assertions:

* the report exists, is JSON, and declares the expected schema
* ``enforced`` matches ``--expect-enforced`` (default ``true``)
* ``verdict`` matches ``--expect-verdict`` (default ``pass``)
* with ``--config``, ``config_digest`` equals a locally computed sha256 of that
  file -- so a stale report from an earlier configure cannot be replayed
* with ``--forbid-absent-satisfied``, no ``invariants[]`` row has status
  ``absent_satisfied`` -- so a negative invariant that quietly stopped being
  checked, because its symbol left the SDK schema, fails here instead of passing
  green. This asserts the *caller's* knowledge of its own build, and changes no
  checker semantics; the general fix is #206.

Exit 0 when every assertion holds, 1 when any fails, 64 on bad usage.

The residual ceiling is stated honestly in the ADR: this script catches a flipped
flag, a deleted checker and a removed CMake call, but deleting *this step* from
the workflow is not detectable in-repo. Closing that requires branch protection
with required status checks -- which are **currently absent** on ``master``, and
which #202 does not touch: adding them is a repository-settings change needing
maintainer authorization, named in the ADR as a follow-up.

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
    # "any" exists so a caller can decline to assert a field it has no independent
    # knowledge of. Asserting that a report says `enforced: true` when the same
    # caller just told the same checker `--enforced yes` is circular: it re-reads
    # its own input and proves nothing. In that situation the real enforcement is
    # the checker's exit code, and the assertions worth making here are the ones
    # about evidence the caller did NOT supply (--require-logs-read,
    # --expect-log-marker).
    parser.add_argument("--expect-verdict", choices=["pass", "fail", "any"], default="pass")
    parser.add_argument("--expect-enforced", choices=["true", "false", "any"], default="true")
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
    parser.add_argument("--forbid-absent-satisfied", action="store_true",
                        help="fail if any invariants[] row has status "
                             "'absent_satisfied'. Supply this only from a caller that "
                             "knows its own build currently has none, so a negative "
                             "invariant whose symbol later leaves the SDK schema turns "
                             "the build red instead of silently going unchecked (#206). "
                             "Asserts the caller's knowledge; changes no checker "
                             "semantics.")

    def _usage_error(message: str) -> None:
        sys.stdout.write("%s: %s\n" % (TOKEN_USAGE, message))
        raise SystemExit(EXIT_USAGE)

    parser.error = _usage_error  # type: ignore[assignment]
    args = parser.parse_args(argv)

    # Same absent-vs-empty contract as the checker: an empty value is a wiring
    # bug, and an empty expected marker would match everything and prove nothing.
    for flag, values in (("--report", [args.report]),
                         ("--config", [args.config] if args.config is not None else []),
                         ("--expect-log-marker", args.expect_log_marker)):
        for value in values:
            if value is not None and not str(value).strip():
                _usage_error("%s was supplied with an empty value; omit the flag entirely "
                             "if it is not requested" % flag)

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

        if args.expect_enforced != "any":
            expect_enforced = args.expect_enforced == "true"
            if report.get("enforced") is not expect_enforced:
                failures.append("enforced is %r, expected %r"
                                % (report.get("enforced"), expect_enforced))

        if args.expect_verdict != "any" and report.get("verdict") != args.expect_verdict:
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

        # Caller-owned coverage floor. `absent_satisfied` is the checker's correct
        # reading of an expected-false symbol that is not written out -- absence
        # means "not enabled" -- but it is also indistinguishable from the symbol
        # having LEFT the SDK schema, in which case that invariant silently stops
        # being checked and the report still says `pass`. Distinguishing the two
        # needs active Kconfig evidence the checker does not have, which is why the
        # general fix is #206 and why nothing here changes what the checker decides.
        # What a caller CAN do is assert the shape of its own build: the release
        # config resolves every negative invariant to an explicit `false` today, so
        # zero such rows is a fact CI can pin. Supplied from the caller rather than
        # derived from the report, for the same reason as --expect-log-marker: a
        # report-sourced version of this check would have nothing to iterate over
        # in exactly the case it is meant to catch.
        if args.forbid_absent_satisfied:
            rows = report.get("invariants")
            if not isinstance(rows, list) or not rows:
                failures.append("--forbid-absent-satisfied was requested but the report "
                                "records no invariants[] rows, so there is nothing to "
                                "check: this cannot be read as zero absent invariants")
            else:
                for index, row in enumerate(rows):
                    if not isinstance(row, dict) or "status" not in row:
                        failures.append("invariants[%d] is malformed: expected an object "
                                        "with a status field, so absence coverage cannot be "
                                        "checked" % index)
                    elif row.get("status") == "absent_satisfied":
                        failures.append("invariant %r is satisfied only by ABSENCE "
                                        "(status=absent_satisfied): the expected-false "
                                        "symbol may be legitimately hidden/off or may have "
                                        "left the SDK schema; those causes are "
                                        "indistinguishable here, so CI refuses the narrowed "
                                        "coverage (see #206)" % row.get("name"))

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

    sys.stdout.write("%s: enforced=%s verdict=%s%s%s%s\n"
                     % (TOKEN_OK, args.expect_enforced, args.expect_verdict,
                        " digest-matched" if args.config else "",
                        " markers=%s" % ",".join(args.expect_log_marker)
                        if args.expect_log_marker else "",
                        " no-absent-satisfied" if args.forbid_absent_satisfied else ""))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
