#!/usr/bin/env python3
"""Private TestFlight CI helper (stdlib only).

Fail-closed checks used by .github/workflows/ios-testflight.yml: inputs/ref gate,
distribution certificate + App Store profile validation, signed/unsigned
artifact verification, and read-only App Store Connect lookups. Shells out to
openssl / security / codesign on the macOS runner. Never prints secret values,
tokens, or profile payloads.
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

VERIFIED_TEAM = "ZN8HWD257P"  # paid Apple Developer team, verified by the user in the portal
MAIN_BUNDLE = "com.punkrally.reader.ZN8HWD257P"
BUNDLES = {"app": MAIN_BUNDLE, "widgets": MAIN_BUNDLE + ".widgets", "share": MAIN_BUNDLE + ".share"}
APPEX_NAMES = {"widgets": "Silveran Reader Widgets.appex", "share": "Silveran Reader Share.appex"}
DEFAULT_GROUP = "group.com.punkrally.reader.ZN8HWD257P"
KEYCHAIN_SUFFIX = "com.kyonifer.silveran.shared"
KEYCHAIN_SERVICE = "com.kyonifer.silveran.storyteller"
CARPLAY_ENTITLEMENT = "com.apple.developer.carplay-audio"
CARPLAY_SCENE_ROLE = "CPTemplateApplicationSceneSessionRoleApplication"
TRUSTED_REFS = (r"refs/heads/punk-rally-ios", r"refs/tags/testflight/[0-9A-Za-z._-]+")
TEAM_RE = re.compile(r"[A-Z0-9]{10}")
GROUP_RE = re.compile(r"group\.[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+")
MARKETING_RE = re.compile(r"[0-9]+(\.[0-9]+){0,2}")
UUID_RE = re.compile(r"[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}")
MIN_VALIDITY = dt.timedelta(days=1)
SIGNED_ENTITLEMENT_KEYS = {
    "application-identifier",
    "com.apple.developer.team-identifier",
    "com.apple.security.application-groups",
    "get-task-allow",
    "beta-reports-active",
}
ASC = "https://api.appstoreconnect.apple.com"


class Fail(Exception):
    pass


def require(cond, msg):
    if not cond:
        raise Fail(msg)


def utc(value):
    return value.replace(tzinfo=dt.timezone.utc) if value.tzinfo is None else value


def emit(key, value):
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as f:
            f.write(f"{key}={value}\n")
    print(f"{key}={value}")


def run(cmd, data=None):
    return subprocess.run(cmd, input=data, capture_output=True, check=False)


def openssl():
    return os.environ.get("OPENSSL", "openssl")


# ---------------------------------------------------------------- inputs / gate

def is_trusted_ref(ref):
    return any(re.fullmatch(p, ref or "") for p in TRUSTED_REFS)


def check_team(team):
    require(team == VERIFIED_TEAM, f"Team ID {team!r} is not the verified paid team {VERIFIED_TEAM}")


def check_inputs(marketing, group, ref=None, team=None, signed=False, mode=None):
    require(MARKETING_RE.fullmatch(marketing or ""), f"marketing version {marketing!r} must be 1-3 numeric components")
    require(GROUP_RE.fullmatch(group or ""), f"App Group {group!r} is not a valid group.* identifier")
    if signed:
        require(is_trusted_ref(ref), f"ref {ref!r} is not a trusted release ref for mode {mode!r} {TRUSTED_REFS}")
        check_team(team)


def check_environment(env):
    """GitHub environment JSON must carry required reviewers and a branch policy."""
    rules = env.get("protection_rules") or []
    require(any(r.get("type") == "required_reviewers" for r in rules),
            "environment 'testflight' has no required reviewers; configure it before signing/upload")
    require(env.get("deployment_branch_policy"),
            "environment 'testflight' has no deployment branch/tag policy; restrict it to trusted release refs")


def parse_build(version):
    parts = str(version).split(".")
    if not 1 <= len(parts) <= 3 or not all(p.isdigit() for p in parts):
        return None
    return tuple(int(p) for p in parts) + (0,) * (3 - len(parts))


def next_build_number(existing_versions, run_number, run_attempt):
    """'<run>.<attempt>', bumped above every existing ASC build (incl. processing)."""
    require(run_number >= 1 and 1 <= run_attempt < 100, "invalid run number/attempt")
    build = (run_number, run_attempt, 0)
    latest = max(filter(None, map(parse_build, existing_versions)), default=(0, 0, 0))
    if build <= latest:
        build = (latest[0] + 1, 1, 0)
    require(build[0] <= 9999, "CFBundleVersion major component would exceed 4 digits; revisit the numbering scheme")
    return f"{build[0]}.{build[1]}"


# ---------------------------------------------------------------- certificate

def pem_blocks(text):
    return [base64.b64decode("".join(b.split()))
            for b in re.findall(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", text, re.S)]


def parse_dn(dn):
    parts = {}
    for item in re.split(r"(?<!\\),", dn):
        if "=" in item:
            k, v = item.split("=", 1)
            parts[k.strip()] = v.replace("\\", "").strip()
    return parts


def cert_info(der):
    r = run([openssl(), "x509", "-inform", "DER", "-noout", "-subject", "-nameopt", "RFC2253",
             "-startdate", "-enddate"], der)
    require(r.returncode == 0, "cannot parse distribution certificate")
    fields = dict(line.split("=", 1) for line in r.stdout.decode().splitlines() if "=" in line)
    when = lambda s: dt.datetime.strptime(s.strip(), "%b %d %H:%M:%S %Y GMT").replace(tzinfo=dt.timezone.utc)
    return {"der": der, "subject": parse_dn(fields["subject"].strip()),
            "not_before": when(fields["notBefore"]), "not_after": when(fields["notAfter"])}


def select_identity_cert(pem_text, identity_sha1):
    matches = [d for d in pem_blocks(pem_text) if hashlib.sha1(d).hexdigest().upper() == identity_sha1.upper()]
    require(len(matches) == 1, "imported certificate does not match the code-signing identity (private key)")
    return matches[0]


def validate_cert(cert, team, now):
    check_team(team)
    cn = cert["subject"].get("CN", "")
    require(cert["subject"].get("OU") == team, "certificate team (OU) does not match APPLE_TEAM_ID")
    require(cn.startswith(("Apple Distribution:", "iPhone Distribution:")), "certificate is not an Apple Distribution certificate")
    require(cn.endswith(f"({team})"), "certificate common name team does not match APPLE_TEAM_ID")
    require(cert["not_before"] <= now, "certificate is not yet valid")
    require(cert["not_after"] - now >= MIN_VALIDITY, "certificate is expired or expires within 24h")


# ---------------------------------------------------------------- profiles

def decode_profile(path, roots_pem):
    """Verify the CMS signature against Apple roots and return the payload plist."""
    r = run([openssl(), "smime", "-verify", "-purpose", "any", "-inform", "DER", "-in", str(path),
             "-CAfile", str(roots_pem)])
    require(r.returncode == 0 and r.stdout, f"{Path(path).name}: CMS signature does not verify")
    try:
        return plistlib.loads(r.stdout)
    except Exception:
        raise Fail(f"{Path(path).name}: signed payload is not a property list")


def validate_profile(label, profile, *, team, cert_der, group, now):
    """IOS_APP_STORE profile for BUNDLES[label]; returns (prefix, uuid)."""
    bundle = BUNDLES[label]
    ent = profile.get("Entitlements") or {}
    p = f"profile[{label}]"
    require(UUID_RE.fullmatch(str(profile.get("UUID", ""))), f"{p}: missing UUID")
    require("iOS" in (profile.get("Platform") or []), f"{p}: not an iOS profile")
    require(profile.get("TeamIdentifier") == [team], f"{p}: TeamIdentifier does not match APPLE_TEAM_ID")
    require("ProvisionedDevices" not in profile, f"{p}: lists devices (development/ad-hoc), not IOS_APP_STORE")
    require(not profile.get("ProvisionsAllDevices"), f"{p}: enterprise profile, not IOS_APP_STORE")
    require(ent.get("get-task-allow") is False, f"{p}: get-task-allow must be false")
    require(ent.get("beta-reports-active") is True, f"{p}: beta-reports-active missing (not an App Store profile)")
    exp = profile.get("ExpirationDate")
    require(isinstance(exp, dt.datetime) and utc(exp) - now >= MIN_VALIDITY, f"{p}: expired or expires within 24h")
    require(cert_der in (profile.get("DeveloperCertificates") or []), f"{p}: does not contain the imported distribution certificate")
    prefixes = profile.get("ApplicationIdentifierPrefix") or []
    require(len(prefixes) == 1 and TEAM_RE.fullmatch(prefixes[0]), f"{p}: needs exactly one ApplicationIdentifierPrefix")
    prefix = prefixes[0]
    require(ent.get("application-identifier") == f"{prefix}.{bundle}", f"{p}: application-identifier must be exactly <prefix>.{bundle}")
    require(ent.get("com.apple.developer.team-identifier") == team, f"{p}: team-identifier entitlement mismatch")
    require(group in (ent.get("com.apple.security.application-groups") or []), f"{p}: App Group {group} not granted")
    if label == "app":
        allowed = ent.get("keychain-access-groups") or []
        require(f"{prefix}.{KEYCHAIN_SUFFIX}" in allowed or f"{prefix}.*" in allowed,
                f"{p}: keychain group {prefix}.{KEYCHAIN_SUFFIX} not allowed")
    return prefix, profile["UUID"]


def validate_signing(cert, identity_sha1, profiles, *, team, group, now):
    check_team(team)
    require(GROUP_RE.fullmatch(group or ""), "invalid App Group")
    require(hashlib.sha1(cert["der"]).hexdigest().upper() == identity_sha1.upper(), "certificate/identity mismatch")
    validate_cert(cert, team, now)
    require(set(profiles) == set(BUNDLES), "need exactly the app, widgets and share profiles")
    results = {k: validate_profile(k, profiles[k], team=team, cert_der=cert["der"], group=group, now=now) for k in BUNDLES}
    require(len({prefix for prefix, _ in results.values()}) == 1, "profiles disagree on ApplicationIdentifierPrefix")
    require(len({uuid for _, uuid in results.values()}) == 3, "each target needs its own profile")
    return results["app"][0], {k: uuid for k, (_, uuid) in results.items()}


# ---------------------------------------------------------------- artifacts

def check_info(label, info, *, marketing, build, group, prefix=None):
    i = f"Info[{label}]"
    require(info.get("CFBundleIdentifier") == BUNDLES[label], f"{i}: bundle id {info.get('CFBundleIdentifier')!r}")
    require(info.get("CFBundleShortVersionString") == marketing, f"{i}: marketing version mismatch")
    require(info.get("CFBundleVersion") == str(build), f"{i}: CFBundleVersion mismatch")
    require(info.get("SILVERAN_WIDGET_APP_GROUP") == group, f"{i}: SILVERAN_WIDGET_APP_GROUP != {group}")
    if label != "app":
        return
    scenes = info.get("UIApplicationSceneManifest") or {}
    require(CARPLAY_SCENE_ROLE not in (scenes.get("UISceneConfigurations") or {}), f"{i}: CarPlay scene must be omitted")
    require(scenes.get("UIApplicationSupportsMultipleScenes") is True, f"{i}: scene manifest changed")
    require({"audio", "fetch"} <= set(info.get("UIBackgroundModes") or []), f"{i}: UIBackgroundModes audio/fetch missing")
    require(info.get("KEYCHAIN_SERVICE") == KEYCHAIN_SERVICE, f"{i}: KEYCHAIN_SERVICE changed")
    kag = str(info.get("KEYCHAIN_ACCESS_GROUP", ""))
    if prefix:
        require(kag == f"{prefix}.{KEYCHAIN_SUFFIX}", f"{i}: KEYCHAIN_ACCESS_GROUP != {prefix}.{KEYCHAIN_SUFFIX}")
    else:  # unsigned: no App ID prefix is known
        require(kag == KEYCHAIN_SUFFIX or kag.endswith("." + KEYCHAIN_SUFFIX), f"{i}: KEYCHAIN_ACCESS_GROUP suffix changed")
    require(info.get("ITSAppUsesNonExemptEncryption") is False, f"{i}: ITSAppUsesNonExemptEncryption must be false")


def check_signed_entitlements(label, ent, *, team, prefix, group):
    e = f"entitlements[{label}]"
    require(CARPLAY_ENTITLEMENT not in ent, f"{e}: {CARPLAY_ENTITLEMENT} must not be signed in")
    allowed = SIGNED_ENTITLEMENT_KEYS | ({"keychain-access-groups"} if label == "app" else set())
    require(not set(ent) - allowed, f"{e}: unexpected entitlements {sorted(set(ent) - allowed)}")
    require(ent.get("application-identifier") == f"{prefix}.{BUNDLES[label]}", f"{e}: application-identifier mismatch")
    require(ent.get("com.apple.developer.team-identifier") == team, f"{e}: team-identifier mismatch")
    require(ent.get("com.apple.security.application-groups") == [group], f"{e}: App Group must be exactly [{group}]")
    require(ent.get("get-task-allow", False) is False, f"{e}: get-task-allow must be false")
    if label == "app":
        require(ent.get("keychain-access-groups") == [f"{prefix}.{KEYCHAIN_SUFFIX}"], f"{e}: keychain-access-groups mismatch")
    else:
        require("keychain-access-groups" not in ent, f"{e}: extensions must not claim keychain groups")


def bundle_paths(app):
    app = Path(app)
    found = sorted(p.name for p in (app / "PlugIns").glob("*.appex"))
    require(found == sorted(APPEX_NAMES.values()), f"embedded extensions {found} != {sorted(APPEX_NAMES.values())}")
    return {"app": app, **{k: app / "PlugIns" / v for k, v in APPEX_NAMES.items()}}


def check_signer(label, leaf_der, identity_sha1):
    require(leaf_der and hashlib.sha1(leaf_der).hexdigest().upper() == (identity_sha1 or "").upper(),
            f"{label}: signing certificate is not the selected identity")


def signing_leaf(path):
    with tempfile.TemporaryDirectory() as d:
        r = run(["codesign", "-d", f"--extract-certificates={d}/cert", str(path)])
        leaf = Path(d, "cert0")
        return leaf.read_bytes() if r.returncode == 0 and leaf.is_file() else b""


def verify_app(app, *, marketing, build, group, team=None, prefix=None, uuids=None, identity_sha1=None):
    paths = bundle_paths(app)
    signed = team is not None
    if signed:
        check_team(team)
        require(prefix and identity_sha1 and uuids and all(uuids.values()), "signed verification needs prefix, identity and UUIDs")
        r = run(["codesign", "--verify", "--deep", "--strict", str(paths["app"])])
        require(r.returncode == 0, "codesign --verify --deep --strict failed")
    for label, path in paths.items():
        with open(path / "Info.plist", "rb") as f:
            check_info(label, plistlib.load(f), marketing=marketing, build=build, group=group, prefix=prefix)
        if not signed:
            continue
        r = run(["codesign", "-d", "--entitlements", "-", "--xml", str(path)])
        require(r.returncode == 0 and r.stdout, f"{label}: cannot read signed entitlements")
        check_signed_entitlements(label, plistlib.loads(r.stdout), team=team, prefix=prefix, group=group)
        meta = run(["codesign", "-dvv", str(path)]).stderr.decode()
        require(f"TeamIdentifier={team}" in meta, f"{label}: signature team mismatch")
        require(re.search(r"^Authority=(Apple|iPhone) Distribution: .*\(" + team + r"\)$", meta, re.M),
                f"{label}: not signed by the Apple Distribution identity")
        check_signer(label, signing_leaf(path), identity_sha1)
        r = run(["security", "cms", "-D", "-i", str(path / "embedded.mobileprovision")])
        require(r.returncode == 0, f"{label}: embedded.mobileprovision unreadable")
        require(plistlib.loads(r.stdout).get("UUID") == uuids[label], f"{label}: embedded profile is not the mapped profile")
    print(f"verified {'signed' if signed else 'unsigned'} {paths['app'].name}: {', '.join(BUNDLES.values())} "
          f"version {marketing} ({build})")


def export_options(team, identity_sha1, uuids):
    check_team(team)
    return {
        "method": "app-store-connect",
        "destination": "export",
        "signingStyle": "manual",
        "teamID": team,
        "signingCertificate": identity_sha1,
        "provisioningProfiles": {BUNDLES[k]: uuids[k] for k in BUNDLES},
        "manageAppVersionAndBuildNumber": False,
        "testFlightInternalTestingOnly": True,
        "uploadSymbols": True,
    }


def patch_wordaligner(root):
    """Same Swift 6.2 type-checker workaround as scripts/iosbuild."""
    target = """        let idealTakes: [Double] = (0..<intervals).map { i in
            Double(totalWords) * max(0.0, bounds[i+1] - bounds[i]) / totalDuration
        }"""
    replacement = """        let idealTakes: [Double] = (0..<intervals).map { i -> Double in
            let span = max(0.0, bounds[i+1] - bounds[i])
            return Double(totalWords) * span / totalDuration
        }"""
    for path in Path(root).rglob("WordAligner.swift"):
        text = path.read_text(encoding="utf-8")
        if target in text:
            path.chmod(0o644)
            path.write_text(text.replace(target, replacement), encoding="utf-8")
            print(f"Patched {path}")


# ---------------------------------------------------------------- App Store Connect (read-only)

def der_ecdsa_to_raw(sig):
    require(sig[0] == 0x30, "bad ECDSA signature")
    i = 3 if sig[1] & 0x80 else 2
    out = b""
    for _ in range(2):
        require(sig[i] == 0x02, "bad ECDSA signature")
        n = sig[i + 1]
        out += sig[i + 2:i + 2 + n].lstrip(b"\0").rjust(32, b"\0")
        i += 2 + n
    return out


def asc_token():
    key_id, issuer, key_path = (os.environ.get(k, "") for k in ("APPSTORE_API_KEY_ID", "APPSTORE_ISSUER_ID", "ASC_KEY_PATH"))
    require(key_id and issuer and key_path and Path(key_path).is_file(), "App Store Connect API key is not configured")
    b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=")
    now = int(time.time())
    head = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    body = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}).encode())
    signing_input = head + b"." + body
    r = run([openssl(), "dgst", "-sha256", "-sign", key_path], signing_input)
    require(r.returncode == 0, "cannot sign App Store Connect token")
    return (signing_input + b"." + b64(der_ecdsa_to_raw(r.stdout))).decode()


def asc_get_all(path, params, max_pages=20):
    """Returns (data, included) across pages."""
    url = f"{ASC}{path}?{urllib.parse.urlencode(params)}"
    items, included = [], []
    for _ in range(max_pages):
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {asc_token()}"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                doc = json.load(resp)
        except urllib.error.HTTPError as err:
            raise Fail(f"App Store Connect GET {path} -> HTTP {err.code}")
        items += doc.get("data") or []
        included += doc.get("included") or []
        url = (doc.get("links") or {}).get("next")
        if not url:
            return items, included
        require(url.startswith(ASC + "/"), "unexpected pagination host")
    raise Fail(f"App Store Connect GET {path}: too many pages")


def processing_state(builds, included, marketing, build):
    """State of the build whose version AND included preReleaseVersion match, else None."""
    versions = {i["id"]: (i.get("attributes") or {}).get("version")
                for i in included if i.get("type") == "preReleaseVersions"}
    for b in builds:
        rel = (((b.get("relationships") or {}).get("preReleaseVersion") or {}).get("data") or {}).get("id")
        if (b.get("attributes") or {}).get("version") == str(build) and versions.get(rel) == marketing:
            return b["attributes"].get("processingState", "UNKNOWN")
    return None


def exact_app_id(apps, bundle):
    matches = [a["id"] for a in apps if (a.get("attributes") or {}).get("bundleId") == bundle]
    require(len(matches) == 1, f"expected exactly one App Store Connect app with bundle id {bundle}, found {len(matches)}")
    return matches[0]


def asc_wait(app_id, marketing, build, timeout_min):
    deadline = time.time() + timeout_min * 60
    state = "NOT_VISIBLE"
    while time.time() < deadline:
        builds, included = asc_get_all("/v1/builds", {
            "filter[app]": app_id, "filter[version]": str(build), "include": "preReleaseVersion",
            "fields[builds]": "version,processingState,preReleaseVersion", "fields[preReleaseVersions]": "version"})
        found = processing_state(builds, included, marketing, build)
        if found:
            state = found
            require(state not in ("FAILED", "INVALID"), f"App Store Connect processing ended in {state}")
            if state == "VALID":
                return state
        time.sleep(60)
    return state


# ---------------------------------------------------------------- CLI

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check-inputs")
    c.add_argument("--marketing", required=True)
    c.add_argument("--group", required=True)
    c.add_argument("--ref")
    c.add_argument("--team")
    c.add_argument("--signed", action="store_true")
    c.add_argument("--mode", choices=("signed-archive", "upload"))
    c = sub.add_parser("check-environment")
    c.add_argument("json_path")
    c = sub.add_parser("build-number")
    c.add_argument("--run-number", type=int, required=True)
    c.add_argument("--run-attempt", type=int, required=True)
    c.add_argument("--asc", action="store_true", help="look up the app and existing builds (read-only)")
    c = sub.add_parser("validate-signing")
    for a in ("team", "group", "identity-sha1", "certs-pem", "roots", "app", "widgets", "share"):
        c.add_argument(f"--{a}", required=True)
    for name in ("verify-app", "export-options"):
        c = sub.add_parser(name)
        c.add_argument("--team")
        c.add_argument("--prefix")
        c.add_argument("--identity-sha1")
        for k in BUNDLES:
            c.add_argument(f"--uuid-{k}")
    v = sub.choices["verify-app"]
    v.add_argument("--app", required=True)
    v.add_argument("--marketing", required=True)
    v.add_argument("--build", required=True)
    v.add_argument("--group", required=True)
    sub.choices["export-options"].add_argument("--out", required=True)
    c = sub.add_parser("asc-wait")
    for a in ("app-id", "marketing", "build"):
        c.add_argument(f"--{a}", required=True)
    c.add_argument("--timeout-min", type=int, default=45)
    c = sub.add_parser("patch-wordaligner")
    c.add_argument("root")
    args = ap.parse_args(argv)
    uuids = lambda: {k: getattr(args, f"uuid_{k}") for k in BUNDLES}

    try:
        if args.cmd == "check-inputs":
            check_inputs(args.marketing, args.group, args.ref, args.team, args.signed, args.mode)
            print("inputs ok")
        elif args.cmd == "check-environment":
            check_environment(json.loads(Path(args.json_path).read_text(encoding="utf-8")))
            print("environment protection ok")
        elif args.cmd == "build-number":
            versions = []
            if args.asc:
                apps, _ = asc_get_all("/v1/apps", {"filter[bundleId]": MAIN_BUNDLE, "fields[apps]": "bundleId"})
                app_id = exact_app_id(apps, MAIN_BUNDLE)
                emit("app_id", app_id)
                builds, _ = asc_get_all("/v1/builds", {"filter[app]": app_id, "limit": "200", "fields[builds]": "version"})
                versions = [b["attributes"].get("version") for b in builds]
            emit("build_number", next_build_number(versions, args.run_number, args.run_attempt))
        elif args.cmd == "validate-signing":
            now = dt.datetime.now(dt.timezone.utc)
            cert = cert_info(select_identity_cert(Path(args.certs_pem).read_text(encoding="utf-8"), args.identity_sha1))
            profiles = {k: decode_profile(getattr(args, k), args.roots) for k in BUNDLES}
            prefix, ids = validate_signing(cert, args.identity_sha1, profiles, team=args.team, group=args.group, now=now)
            emit("prefix", prefix)
            for k, uuid in ids.items():
                emit(f"uuid_{k}", uuid)
            print(f"certificate valid until {cert['not_after']:%Y-%m-%d}; profiles valid until "
                  + ", ".join(f"{k} {utc(profiles[k]['ExpirationDate']):%Y-%m-%d}" for k in BUNDLES))
        elif args.cmd == "verify-app":
            verify_app(args.app, marketing=args.marketing, build=args.build, group=args.group,
                       team=args.team, prefix=args.prefix, uuids=uuids() if args.team else None,
                       identity_sha1=args.identity_sha1)
        elif args.cmd == "export-options":
            require(all(uuids().values()), "export-options needs 3 UUIDs")
            Path(args.out).write_bytes(plistlib.dumps(export_options(args.team, args.identity_sha1, uuids())))
        elif args.cmd == "asc-wait":
            state = asc_wait(args.app_id, args.marketing, args.build, args.timeout_min)
            emit("processing_state", state)
        elif args.cmd == "patch-wordaligner":
            patch_wordaligner(args.root)
    except Fail as err:
        print(f"::error::{err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
