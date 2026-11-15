"""Offline tests for the private TestFlight pipeline.

python -m unittest discover -s scripts/testflight -p "test_*.py" -v
Needs PyYAML for spec/workflow tests and openssl for CMS/certificate tests; those
skip locally when missing and FAIL when TF_REQUIRE_ALL_TESTS=1 (CI).
"""
import base64
import contextlib
import copy
import datetime as dt
import hashlib
import io
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tf  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
TFDIR = ROOT / "XCodeApps" / "TestFlight"
WORKFLOW = ROOT / ".github" / "workflows" / "ios-testflight.yml"
SCRIPTS = [WORKFLOW, *sorted((ROOT / "scripts" / "testflight").glob("*.sh"))]
REQUIRE_ALL = os.environ.get("TF_REQUIRE_ALL_TESTS") == "1"
TARGETS = {"app": "Silveran Reader (iOS)", "widgets": "Silveran Reader Widgets (iOS)", "share": "Silveran Reader Share (iOS)"}
OPENSSL = os.environ.get("OPENSSL") or shutil.which("openssl")

try:
    import yaml
except ImportError:
    yaml = None


def need(ok, why):
    if not ok:
        if REQUIRE_ALL:
            raise AssertionError(f"required test dependency missing: {why}")
        raise unittest.SkipTest(why)


def load_yaml(path):
    need(yaml, "PyYAML not installed")
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def xcconfig(path):
    settings = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("//")[0].strip()
        m = re.match(r'#include\??\s+"(.+)"', line)
        if m:
            inc = path.parent / m.group(1)
            if inc.exists():
                settings.update(xcconfig(inc))
        elif "=" in line:
            k, v = line.split("=", 1)
            settings[k.strip()] = v.strip()
    return settings


def expand(value, settings):
    for _ in range(10):
        value = re.sub(r"\$\((\w+)\)", lambda m: settings.get(m.group(1), m.group(0)), value)
    return value


def entitlements(name):
    return plistlib.loads((TFDIR / name).read_bytes())


# ------------------------------------------------------------------ config

class ConfigIsolationTests(unittest.TestCase):
    def setUp(self):
        self.settings = xcconfig(TFDIR / "TestFlight.xcconfig")

    def spec(self):
        return load_yaml(TFDIR / "project.yml")

    def test_identity_and_group_resolve_exactly(self):
        s = self.settings
        self.assertEqual(xcconfig(ROOT / "XCodeApps" / "Configs" / "Common.xcconfig")["DEVELOPMENT_TEAM"], "9CJ7KG7UKQ")
        self.assertEqual(s["DEVELOPMENT_TEAM"], "ZN8HWD257P", "must override the repository default 9CJ7KG7UKQ")
        self.assertEqual(tf.VERIFIED_TEAM, "ZN8HWD257P")
        self.assertNotIn("DEVELOPMENT_TEAM", (TFDIR / "project.yml").read_text(encoding="utf-8"),
                         "a target-level DEVELOPMENT_TEAM would mask TestFlight.xcconfig")
        self.assertEqual(s["APP_GROUP_ID"], tf.DEFAULT_GROUP)
        self.assertEqual(s["KEYCHAIN_SERVICE"], tf.KEYCHAIN_SERVICE)
        self.assertEqual(s["KEYCHAIN_GROUP_SUFFIX"], tf.KEYCHAIN_SUFFIX)
        targets = self.spec()["targets"]
        for label, name in TARGETS.items():
            bundle = expand(targets[name]["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"], s)
            self.assertEqual(bundle, tf.BUNDLES[label])
        self.assertEqual(tf.BUNDLES["app"], "com.punkrally.reader.ZN8HWD257P")

    def test_spec_only_uses_testflight_files(self):
        spec = self.spec()
        self.assertEqual(set(spec["targets"]), set(TARGETS.values()))
        tmpl = spec["targetTemplates"]["testFlightBase"]
        self.assertEqual(set(tmpl["configFiles"].values()), {"XCodeApps/TestFlight/TestFlight.xcconfig"})
        self.assertEqual(str(tmpl["settings"]["base"]["IPHONEOS_DEPLOYMENT_TARGET"]), "18.0")
        profiles = set()
        for name, target in spec["targets"].items():
            base = target["settings"]["base"]
            self.assertTrue(base["CODE_SIGN_ENTITLEMENTS"].startswith("XCodeApps/TestFlight/"), name)
            self.assertTrue(base["INFOPLIST_FILE"].startswith(".build-testflight/"), name)
            self.assertEqual(base["INFOPLIST_FILE"], target["info"]["path"])
            profiles.add(base["PROVISIONING_PROFILE_SPECIFIER"])
        self.assertEqual(profiles, {"$(TF_PROFILE_APP)", "$(TF_PROFILE_WIDGETS)", "$(TF_PROFILE_SHARE)"})
        text = (TFDIR / "project.yml").read_text(encoding="utf-8")
        for shipping in ("Configs/Release.xcconfig", "Configs/Debug.xcconfig", "SilveranReaderIos.entitlements",
                         "SilveranReaderWidgets.entitlements", "SilveranReaderShare.entitlements",
                         "Info-iOS.plist", "Info-Widgets-iOS.plist", "Info-Share-iOS.plist", "Local.xcconfig"):
            self.assertNotIn(shipping, text)

    def test_entitlements_omit_carplay_and_share_one_group(self):
        app, widgets, share = (entitlements(n) for n in ("App.entitlements", "Widgets.entitlements", "Share.entitlements"))
        self.assertNotIn(tf.CARPLAY_ENTITLEMENT, app)
        self.assertEqual(set(app), {"com.apple.security.application-groups", "keychain-access-groups"})
        self.assertEqual(app["keychain-access-groups"], ["$(AppIdentifierPrefix)$(KEYCHAIN_GROUP_SUFFIX)"])
        for ent in (app, widgets, share):
            self.assertEqual(ent["com.apple.security.application-groups"], ["$(APP_GROUP_ID)"])
        self.assertEqual(set(widgets), {"com.apple.security.application-groups"})
        self.assertEqual(set(share), {"com.apple.security.application-groups"})

    def test_matches_shipping_ios_targets_except_carplay_and_group(self):
        shipping = load_yaml(ROOT / "XCodeApps" / "project.yml")["targets"]
        ours = self.spec()["targets"]
        for label, name in TARGETS.items():
            want = copy.deepcopy(shipping[name]["info"]["properties"])
            got = ours[name]["info"]["properties"]
            want["SILVERAN_WIDGET_APP_GROUP"] = "$(APP_GROUP_ID)"
            if label == "app":
                self.assertIn(tf.CARPLAY_SCENE_ROLE, want["UIApplicationSceneManifest"]["UISceneConfigurations"])
                del want["UIApplicationSceneManifest"]["UISceneConfigurations"]
                self.assertEqual(got["UIBackgroundModes"], ["audio", "fetch"])
                self.assertEqual(got["UIApplicationSceneManifest"], {"UIApplicationSupportsMultipleScenes": True})
                self.assertIs(got["NSSupportsLiveActivities"], True)
            self.assertEqual(got, want, f"{name} Info drifted from XCodeApps/project.yml")
            self.assertEqual(ours[name]["sources"], shipping[name]["sources"], name)
            self.assertEqual(ours[name]["dependencies"], shipping[name]["dependencies"], name)

    def test_shipping_files_keep_carplay(self):
        ship = plistlib.loads((ROOT / "XCodeApps" / "SilveranReaderIos.entitlements").read_bytes())
        self.assertIs(ship.get(tf.CARPLAY_ENTITLEMENT), True)
        self.assertIn(tf.CARPLAY_SCENE_ROLE, (ROOT / "XCodeApps" / "project.yml").read_text(encoding="utf-8"))


# ------------------------------------------------------------------ signing

TEAM, PREFIX = "ZN8HWD257P", "PFX9876543"  # prefix deliberately != team
UNVERIFIED_TEAMS = ("9CJ7KG7UKQ", "ZZZZZ99999")  # repository default + unrelated well-formed team
NOW = dt.datetime(2026, 11, 1, tzinfo=dt.timezone.utc)
CERT_DER = b"synthetic-distribution-cert"
SHA1 = hashlib.sha1(CERT_DER).hexdigest().upper()
UUIDS = {"app": "11111111-1111-1111-1111-111111111111", "widgets": "22222222-2222-2222-2222-222222222222",
         "share": "33333333-3333-3333-3333-333333333333"}


def cert(team=TEAM, **over):
    c = {"der": CERT_DER, "subject": {"CN": f"Apple Distribution: Josh ({team})", "OU": team},
         "not_before": NOW - dt.timedelta(days=30), "not_after": NOW + dt.timedelta(days=300)}
    c.update(over)
    return c


def profile(label, team=TEAM):
    ent = {"application-identifier": f"{PREFIX}.{tf.BUNDLES[label]}", "com.apple.developer.team-identifier": team,
           "com.apple.security.application-groups": [tf.DEFAULT_GROUP], "get-task-allow": False,
           "beta-reports-active": True}
    if label == "app":
        ent["keychain-access-groups"] = [f"{PREFIX}.*"]
    return {"UUID": UUIDS[label], "Platform": ["iOS"], "TeamIdentifier": [team], "ApplicationIdentifierPrefix": [PREFIX],
            "ExpirationDate": (NOW + dt.timedelta(days=200)).replace(tzinfo=None), "DeveloperCertificates": [CERT_DER],
            "Entitlements": ent}


def profiles(mutate=None, label="app", team=TEAM):
    p = {k: profile(k, team) for k in tf.BUNDLES}
    if mutate:
        mutate(p[label])
    return p


def validate(c=None, p=None, sha1=SHA1, team=TEAM, group=tf.DEFAULT_GROUP):
    return tf.validate_signing(c or cert(), sha1, p or profiles(), team=team, group=group, now=NOW)


class SigningValidationTests(unittest.TestCase):
    def test_valid_material_passes(self):
        self.assertEqual(validate(), (PREFIX, UUIDS))

    def test_profile_rejections(self):
        def ent(key, value):
            return lambda p: p["Entitlements"].__setitem__(key, value)

        cases = {
            "devices": lambda p: p.__setitem__("ProvisionedDevices", ["0000"]),
            "all devices": lambda p: p.__setitem__("ProvisionsAllDevices", True),
            "get-task-allow": ent("get-task-allow", True),
            "no beta": lambda p: p["Entitlements"].pop("beta-reports-active"),
            "expired": lambda p: p.__setitem__("ExpirationDate", (NOW + dt.timedelta(hours=2)).replace(tzinfo=None)),
            "cert missing": lambda p: p.__setitem__("DeveloperCertificates", [b"other"]),
            "wildcard": ent("application-identifier", f"{PREFIX}.*"),
            "team as prefix": ent("application-identifier", f"{TEAM}.{tf.MAIN_BUNDLE}"),
            "other bundle": ent("application-identifier", f"{PREFIX}.com.punkrally.reader"),
            "team": lambda p: p.__setitem__("TeamIdentifier", ["ZZZZZ99999"]),
            "group": ent("com.apple.security.application-groups", ["group.com.punkrally.reader"]),
            "keychain": ent("keychain-access-groups", [f"{PREFIX}.other"]),
            "macOS": lambda p: p.__setitem__("Platform", ["OSX"]),
            "prefix disagreement": lambda p: (p.__setitem__("ApplicationIdentifierPrefix", ["QQQQQ11111"]),
                                              ent("application-identifier", f"QQQQQ11111.{tf.MAIN_BUNDLE}")(p)),
        }
        for name, mutate in cases.items():
            with self.subTest(name), self.assertRaises(tf.Fail):
                validate(p=profiles(mutate))
        with self.subTest("extension group"), self.assertRaises(tf.Fail):
            validate(p=profiles(ent("com.apple.security.application-groups", []), label="share"))

    def test_same_profile_for_all_targets_rejected(self):
        p = profiles()
        p["widgets"]["UUID"] = UUIDS["app"]
        with self.assertRaises(tf.Fail):
            validate(p=p)
        with self.assertRaises(tf.Fail):
            validate(p={k: v for k, v in profiles().items() if k != "share"})

    def test_certificate_rejections(self):
        for name, c in {
            "team": cert(subject={"CN": "Apple Distribution: X (ZZZZZ99999)", "OU": "ZZZZZ99999"}),
            "development": cert(subject={"CN": f"Apple Development: Josh ({TEAM})", "OU": TEAM}),
            "expired": cert(not_after=NOW + dt.timedelta(hours=1)),
            "future": cert(not_before=NOW + dt.timedelta(days=1)),
        }.items():
            with self.subTest(name), self.assertRaises(tf.Fail):
                validate(c=c)
        with self.assertRaises(tf.Fail):
            validate(sha1="0" * 40)
        with self.assertRaises(tf.Fail):
            validate(team="")

    def test_unverified_teams_rejected_at_every_signing_entrypoint(self):
        """Internally consistent material for any team other than ZN8HWD257P must still fail."""
        with tempfile.TemporaryDirectory() as d:
            app = Path(d) / "Silveran Reader.app"
            for name in tf.APPEX_NAMES.values():
                (app / "PlugIns" / name).mkdir(parents=True)
            out = Path(d) / "ExportOptions.plist"
            cli = ["export-options", "--identity-sha1", SHA1, "--out", str(out),
                   *[a for k in tf.BUNDLES for a in (f"--uuid-{k}", UUIDS[k])]]

            def rejected(argv):
                err = io.StringIO()  # keep expected ::error:: lines out of CI annotations
                with contextlib.redirect_stderr(err):
                    self.assertEqual(tf.main(argv), 1)
                self.assertIn("not the verified paid team ZN8HWD257P", err.getvalue())
                self.assertFalse(out.exists())

            for team in UNVERIFIED_TEAMS + ("", "zn8hwd257p", PREFIX):
                with self.subTest(team):
                    for call in (
                        lambda: tf.check_inputs("0.1", tf.DEFAULT_GROUP, "refs/heads/punk-rally-ios", team, signed=True),
                        lambda: validate(c=cert(team), p=profiles(team=team), team=team),
                        lambda: tf.validate_cert(cert(team), team, NOW),
                        lambda: tf.verify_app(app, marketing="0.1", build="42.1", group=tf.DEFAULT_GROUP, team=team,
                                              prefix=PREFIX, uuids=UUIDS, identity_sha1=SHA1),
                        lambda: tf.export_options(team, SHA1, UUIDS),
                    ):
                        with self.assertRaises(tf.Fail):
                            call()
                    rejected(cli + ["--team", team])
            with self.assertRaises(tf.Fail):
                tf.check_inputs("0.1", tf.DEFAULT_GROUP, "refs/heads/punk-rally-ios", None, signed=True)
            rejected(cli)
            self.assertEqual(tf.main(cli + ["--team", TEAM]), 0)
            self.assertEqual(plistlib.loads(out.read_bytes())["teamID"], "ZN8HWD257P")

    def test_identity_certificate_selection(self):
        pem = lambda d: "-----BEGIN CERTIFICATE-----\n" + base64.b64encode(d).decode() + "\n-----END CERTIFICATE-----\n"
        both = pem(b"unrelated") + pem(CERT_DER)
        self.assertEqual(tf.select_identity_cert(both, SHA1), CERT_DER)
        with self.assertRaises(tf.Fail):
            tf.select_identity_cert(pem(b"unrelated"), SHA1)


class ArtifactTests(unittest.TestCase):
    def signed(self, label):
        ent = {"application-identifier": f"{PREFIX}.{tf.BUNDLES[label]}", "com.apple.developer.team-identifier": TEAM,
               "com.apple.security.application-groups": [tf.DEFAULT_GROUP], "get-task-allow": False,
               "beta-reports-active": True}
        if label == "app":
            ent["keychain-access-groups"] = [f"{PREFIX}.{tf.KEYCHAIN_SUFFIX}"]
        return ent

    def check(self, label, ent):
        tf.check_signed_entitlements(label, ent, team=TEAM, prefix=PREFIX, group=tf.DEFAULT_GROUP)

    def test_signed_entitlements(self):
        for label in tf.BUNDLES:
            self.check(label, self.signed(label))
        bad = {
            "carplay": ("app", {tf.CARPLAY_ENTITLEMENT: True}),
            "extra key": ("widgets", {"aps-environment": "production"}),
            "two groups": ("share", {"com.apple.security.application-groups": [tf.DEFAULT_GROUP, "group.x.y"]}),
            "fallback group": ("widgets", {"com.apple.security.application-groups": ["group.com.punkrally.reader"]}),
            "appex keychain": ("share", {"keychain-access-groups": [f"{PREFIX}.{tf.KEYCHAIN_SUFFIX}"]}),
            "debuggable": ("app", {"get-task-allow": True}),
            "team-prefixed keychain": ("app", {"keychain-access-groups": [f"{TEAM}.{tf.KEYCHAIN_SUFFIX}"]}),
        }
        for name, (label, over) in bad.items():
            with self.subTest(name), self.assertRaises(tf.Fail):
                self.check(label, {**self.signed(label), **over})

    def info(self, label, **over):
        info = {"CFBundleIdentifier": tf.BUNDLES[label], "CFBundleShortVersionString": "0.1", "CFBundleVersion": "4201",
                "SILVERAN_WIDGET_APP_GROUP": tf.DEFAULT_GROUP}
        if label == "app":
            info.update({"UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": True},
                         "UIBackgroundModes": ["audio", "fetch"], "KEYCHAIN_SERVICE": tf.KEYCHAIN_SERVICE,
                         "KEYCHAIN_ACCESS_GROUP": f"{PREFIX}.{tf.KEYCHAIN_SUFFIX}", "ITSAppUsesNonExemptEncryption": False,
                         "NSSupportsLiveActivities": True})
        info.update(over)
        return info

    def test_info_checks(self):
        kw = dict(marketing="0.1", build=4201, group=tf.DEFAULT_GROUP, prefix=PREFIX)
        for label in tf.BUNDLES:
            tf.check_info(label, self.info(label), **kw)
        carplay = {"UIApplicationSupportsMultipleScenes": True,
                   "UISceneConfigurations": {tf.CARPLAY_SCENE_ROLE: [{"UISceneConfigurationName": "CarPlay"}]}}
        bad = {
            "carplay scene": ("app", {"UIApplicationSceneManifest": carplay}),
            "build drift": ("widgets", {"CFBundleVersion": "1"}),
            "fallback group": ("share", {"SILVERAN_WIDGET_APP_GROUP": "group.com.punkrally.reader"}),
            "wrong bundle": ("widgets", {"CFBundleIdentifier": "com.punkrally.reader.widgets"}),
            "no audio": ("app", {"UIBackgroundModes": ["fetch"]}),
            "keychain service": ("app", {"KEYCHAIN_SERVICE": "x"}),
            "no live activities": ("app", {"NSSupportsLiveActivities": False}),
        }
        for name, (label, over) in bad.items():
            with self.subTest(name), self.assertRaises(tf.Fail):
                tf.check_info(label, self.info(label, **over), **kw)
        tf.check_info("app", self.info("app", KEYCHAIN_ACCESS_GROUP=tf.KEYCHAIN_SUFFIX), **{**kw, "prefix": None})

    def test_bundle_layout_requires_exactly_two_extensions(self):
        with tempfile.TemporaryDirectory() as d:
            app = Path(d) / "Silveran Reader.app"
            for name in tf.APPEX_NAMES.values():
                (app / "PlugIns" / name).mkdir(parents=True)
            self.assertEqual(set(tf.bundle_paths(app)), set(tf.BUNDLES))
            (app / "PlugIns" / "CarPlay.appex").mkdir()
            with self.assertRaises(tf.Fail):
                tf.bundle_paths(app)

    def test_signer_fingerprint_must_be_selected_identity(self):
        tf.check_signer("app", CERT_DER, SHA1)
        tf.check_signer("app", CERT_DER, SHA1.lower())
        for leaf, sha1 in ((b"same-team-other-cert", SHA1), (CERT_DER, "0" * 40), (b"", SHA1), (CERT_DER, None)):
            with self.assertRaises(tf.Fail):
                tf.check_signer("widgets", leaf, sha1)

    def test_signed_verification_requires_full_identity(self):
        with tempfile.TemporaryDirectory() as d:
            app = Path(d) / "Silveran Reader.app"
            for name in tf.APPEX_NAMES.values():
                (app / "PlugIns" / name).mkdir(parents=True)
            with self.assertRaises(tf.Fail):
                tf.verify_app(app, marketing="0.1", build="42.1", group=tf.DEFAULT_GROUP, team=TEAM,
                              prefix=PREFIX, uuids=UUIDS, identity_sha1=None)

    def test_export_options(self):
        opts = tf.export_options(TEAM, SHA1, UUIDS)
        self.assertEqual(opts["method"], "app-store-connect")
        self.assertEqual(opts["signingStyle"], "manual")
        self.assertIs(opts["manageAppVersionAndBuildNumber"], False)
        self.assertIs(opts["testFlightInternalTestingOnly"], True)
        self.assertEqual(opts["provisioningProfiles"], {tf.BUNDLES[k]: UUIDS[k] for k in tf.BUNDLES})
        self.assertEqual(opts["destination"], "export")


# ------------------------------------------------------------------ gate / release

class GateTests(unittest.TestCase):
    def test_trusted_refs(self):
        for ref in ("refs/heads/punk-rally-ios", "refs/tags/testflight/0.1-42"):
            self.assertTrue(tf.is_trusted_ref(ref), ref)
        for ref in ("refs/heads/main", "refs/heads/feature/private-testflight", "refs/heads/punk-rally-ios-x",
                    "refs/pull/1/merge",
                    "refs/tags/v1", "refs/tags/testflight/../x/y", "", None):
            self.assertFalse(tf.is_trusted_ref(ref), ref)

    def test_signed_modes_release_refs_only(self):
        feature = "refs/heads/feature/private-testflight"
        self.assertFalse(hasattr(tf, "SIGNED_ARCHIVE_ONLY_REF"))
        ok = lambda ref, mode: tf.check_inputs("0.1", tf.DEFAULT_GROUP, ref, TEAM, signed=True, mode=mode)
        releases = ("refs/heads/punk-rally-ios", "refs/tags/testflight/0.1-42", "refs/tags/testflight/rc_1.2")
        for ref in releases:
            for mode in (None, "signed-archive", "upload"):
                ok(ref, mode)
        for ref in (feature, feature + "-x", feature + "/x", "refs/tags/feature/private-testflight",
                    "refs/heads/Feature/private-testflight", "feature/private-testflight",
                    "refs/heads/testflight/x", "refs/tags/testflight/", "refs/heads/main", "refs/pull/1/merge", None):
            for mode in (None, "", "signed-archive", "Signed-Archive", "upload", "validate"):
                with self.subTest(ref=ref, mode=mode), self.assertRaises(tf.Fail):
                    ok(ref, mode)
        cli = lambda ref: ["check-inputs", "--signed", "--ref", ref, "--team", TEAM, "--marketing", "0.1",
                           "--group", tf.DEFAULT_GROUP]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            for mode in ("signed-archive", "upload"):
                self.assertNotEqual(tf.main(cli(feature) + ["--mode", mode]), 0, mode)
                for ref in releases:
                    self.assertEqual(tf.main(cli(ref) + ["--mode", mode]), 0, (ref, mode))
            self.assertNotEqual(tf.main(cli(feature)), 0)
            with self.assertRaises(SystemExit):
                tf.main(cli(feature) + ["--mode", "validate"])

    def test_inputs(self):
        tf.check_inputs("0.1", tf.DEFAULT_GROUP)
        tf.check_inputs("1.2.3", tf.DEFAULT_GROUP, "refs/heads/punk-rally-ios", TEAM, signed=True)
        for args in (("0.1a", tf.DEFAULT_GROUP), ("0.1", "com.punkrally.reader"), ("1.2.3.4", tf.DEFAULT_GROUP)):
            with self.assertRaises(tf.Fail):
                tf.check_inputs(*args)
        with self.assertRaises(tf.Fail):
            tf.check_inputs("0.1", tf.DEFAULT_GROUP, "refs/heads/punk-rally-ios", "", signed=True)
        with self.assertRaises(tf.Fail):
            tf.check_inputs("0.1", tf.DEFAULT_GROUP, "refs/heads/main", TEAM, signed=True)

    def test_environment_protection(self):
        ok = {"protection_rules": [{"type": "required_reviewers"}], "deployment_branch_policy": {"custom_branch_policies": True}}
        tf.check_environment(ok)
        for env in ({"protection_rules": [], "deployment_branch_policy": {"x": 1}},
                    {"protection_rules": [{"type": "required_reviewers"}], "deployment_branch_policy": None},
                    {"protection_rules": [{"type": "wait_timer"}], "deployment_branch_policy": {"x": 1}}):
            with self.assertRaises(tf.Fail):
                tf.check_environment(env)

    def test_build_numbers_monotonic(self):
        self.assertEqual(tf.next_build_number([], 42, 1), "42.1")
        self.assertEqual(tf.next_build_number(["42.1"], 42, 2), "42.2")  # rerun
        self.assertEqual(tf.next_build_number(["42.1"], 42, 1), "43.1")  # collision
        self.assertEqual(tf.next_build_number(["50.3", "junk", None, "1.2.3.4"], 42, 1), "51.1")
        self.assertEqual(tf.next_build_number(["17"], 42, 1), "42.1")
        self.assertEqual(tf.next_build_number(["42"], 42, 1), "42.1")  # 42 == 42.0.0 < 42.1
        for out in (tf.next_build_number(["9998.7"], 3, 1), tf.next_build_number([], 9999, 99)):
            self.assertRegex(out, r"^[1-9][0-9]{0,3}\.[1-9][0-9]?$")
        with self.assertRaises(tf.Fail):
            tf.next_build_number([], 42, 100)
        with self.assertRaises(tf.Fail):
            tf.next_build_number(["9999.5"], 42, 1)

    def test_processing_state_matches_prerelease_locally(self):
        included = [{"type": "preReleaseVersions", "id": "p1", "attributes": {"version": "0.1"}},
                    {"type": "preReleaseVersions", "id": "p2", "attributes": {"version": "0.2"}}]
        build = lambda v, pre, state: {"attributes": {"version": v, "processingState": state},
                                       "relationships": {"preReleaseVersion": {"data": {"id": pre}}}}
        builds = [build("42.1", "p2", "FAILED"), build("42.1", "p1", "PROCESSING")]
        self.assertEqual(tf.processing_state(builds, included, "0.1", "42.1"), "PROCESSING")
        self.assertIsNone(tf.processing_state(builds, included, "0.3", "42.1"))
        self.assertIsNone(tf.processing_state(builds[1:], included, "0.1", "42.2"))

    def test_exact_app_lookup(self):
        apps = [{"id": "1", "attributes": {"bundleId": tf.MAIN_BUNDLE + ".beta"}},
                {"id": "2", "attributes": {"bundleId": tf.MAIN_BUNDLE}}]
        self.assertEqual(tf.exact_app_id(apps, tf.MAIN_BUNDLE), "2")
        with self.assertRaises(tf.Fail):
            tf.exact_app_id(apps[:1], tf.MAIN_BUNDLE)
        with self.assertRaises(tf.Fail):
            tf.exact_app_id(apps + apps[1:], tf.MAIN_BUNDLE)

    def test_ecdsa_der_to_jose(self):
        r, s = b"\x00" + b"\x81" * 32, b"\x01" * 31
        der = bytes([0x30, 4 + len(r) + len(s), 0x02, len(r)]) + r + bytes([0x02, len(s)]) + s
        self.assertEqual(tf.der_ecdsa_to_raw(der), b"\x81" * 32 + b"\x00" + b"\x01" * 31)


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.wf = load_yaml(WORKFLOW)
        self.jobs = self.wf["jobs"]

    def test_manual_only_and_default_validate(self):
        on = self.wf.get("on", self.wf.get(True))
        self.assertEqual(set(on), {"workflow_dispatch"})
        mode = on["workflow_dispatch"]["inputs"]["mode"]
        self.assertEqual(mode["default"], "validate")
        self.assertEqual(self.wf["permissions"], {"contents": "read"})

    def test_unsigned_path_has_no_secrets_or_apple_calls(self):
        job = self.jobs["unsigned-archive"]
        dump = yaml.safe_dump(job)
        self.assertNotIn("secrets.", dump)
        self.assertNotIn("environment", job)
        self.assertNotIn("--asc", dump)
        self.assertNotIn("APPLE_TEAM_ID", dump)
        self.assertNotIn("vars.", dump)
        self.assertIn("build.sh unsigned", dump)
        build = (ROOT / "scripts" / "testflight" / "build.sh").read_text(encoding="utf-8")
        unsigned = next(line for line in build.splitlines() if "CODE_SIGNING_ALLOWED" in line)
        for flag in ("CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", 'CODE_SIGN_IDENTITY=""', 'DEVELOPMENT_TEAM=""'):
            self.assertIn(flag, unsigned)
        self.assertLess(build.index("tf.py export-options --team"), build.index('DEVELOPMENT_TEAM="$APPLE_TEAM_ID"'),
                        "team must be checked before the signed archive")

    def test_signed_job_defaults_to_verified_team(self):
        env = self.jobs["signed"]["env"]
        self.assertEqual(env["APPLE_TEAM_ID"], "${{ vars.APPLE_TEAM_ID || 'ZN8HWD257P' }}")

    def test_signed_and_upload_are_gated(self):
        job = self.jobs["signed"]
        self.assertEqual(job["environment"], "testflight")
        self.assertEqual(job["concurrency"], {"group": "ios-testflight-release", "cancel-in-progress": False})
        self.assertNotIn("validate", job["if"])
        steps = {s["name"]: s for s in job["steps"] if "name" in s}
        gate = steps["Gate (trusted ref, verified team, protected environment)"]["run"]
        self.assertIn("--signed", gate)
        self.assertIn('--mode "$MODE"', gate)
        self.assertEqual(job["env"]["MODE"], "${{ inputs.mode }}")
        self.assertIn("check-environment", gate)
        names = [s.get("name", "") for s in job["steps"]]
        self.assertLess(names.index("Gate (trusted ref, verified team, protected environment)"),
                        names.index("Import signing material (temporary keychain)"))
        for name in ("Upload to TestFlight (internal only)", "Wait for App Store Connect processing"):
            self.assertEqual(steps[name]["if"], "inputs.mode == 'upload'")
        self.assertEqual(steps["Remove signing material"]["if"], "always()")
        key = steps["Import signing material (temporary keychain)"]["env"]["APPSTORE_API_PRIVATE_KEY"]
        self.assertIn("inputs.mode == 'upload'", key)
        self.assertEqual(names[-1], "Remove signing material")
        self.assertIn('--identity-sha1 "$IDENTITY"', steps["Verify signatures + entitlements (archive and IPA)"]["run"])

    def test_checks_job_pins_test_dependency(self):
        dump = yaml.safe_dump(self.jobs["checks"])
        self.assertIn("--require-hashes", dump)
        self.assertIn("TF_REQUIRE_ALL_TESTS", dump)
        self.assertRegex((ROOT / "scripts" / "testflight" / "requirements-test.txt").read_text(encoding="utf-8"),
                         r"PyYAML==[\d.]+ --hash=sha256:[0-9a-f]{64}")

    def test_pins_and_forbidden_patterns(self):
        uses = re.findall(r"uses:\s*(\S+)", WORKFLOW.read_text(encoding="utf-8"))
        self.assertTrue(uses)
        for u in uses:
            self.assertRegex(u, r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$")
        self.assertRegex(self.wf["env"]["XCODEGEN_SHA256"], r"^[0-9a-f]{64}$")
        self.assertGreaterEqual(int(self.wf["env"]["XCODE_VERSION"].split(".")[0]), 26)
        self.assertEqual(self.wf["env"]["XCODE_VERSION"], "26.3")
        for name in ("unsigned-archive", "signed"):
            self.assertEqual(self.jobs[name]["runs-on"], "macos-15-intel", name)
        for path in SCRIPTS + [ROOT / "scripts" / "testflight" / "tf.py"]:
            text = path.read_text(encoding="utf-8")
            for bad in ("-allowProvisioningUpdates", "set -x", "package-ipa", "printenv", "upload-artifact",
                        "actions/cache", "-allowProvisioningDeviceRegistration", "beta-app-review", "betaGroups"):
                self.assertFalse(bad in text, f"{bad} in {path.name}")


# ------------------------------------------------------------------ openssl-backed

class OpenSSLTests(unittest.TestCase):
    def setUp(self):
        need(OPENSSL, "openssl not found")
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        os.environ["OPENSSL"] = OPENSSL

    def ssl(self, *args):
        subprocess.run([OPENSSL, *args], check=True, capture_output=True)

    def make_ca(self, name):
        self.ssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3", "-subj", f"/CN={name}",
                 "-keyout", str(self.tmp / f"{name}.key"), "-out", str(self.tmp / f"{name}.pem"))
        return self.tmp / f"{name}.pem", self.tmp / f"{name}.key"

    def test_cms_profile_signature_fail_closed(self):
        ca, key = self.make_ca("Root")
        other, _ = self.make_ca("Other")
        payload = self.tmp / "p.plist"
        payload.write_bytes(plistlib.dumps({"UUID": UUIDS["app"], "Entitlements": {"get-task-allow": False}}))
        signed = self.tmp / "app.mobileprovision"
        self.ssl("smime", "-sign", "-signer", str(ca), "-inkey", str(key), "-nodetach", "-binary",
                 "-outform", "DER", "-in", str(payload), "-out", str(signed))
        self.assertEqual(tf.decode_profile(signed, ca)["UUID"], UUIDS["app"])
        with self.assertRaises(tf.Fail):
            tf.decode_profile(signed, other)
        data = bytearray(signed.read_bytes())
        i = data.find(UUIDS["app"].encode())
        data[i] ^= 0x01
        tampered = self.tmp / "tampered.mobileprovision"
        tampered.write_bytes(bytes(data))
        with self.assertRaises(tf.Fail):
            tf.decode_profile(tampered, ca)

    def test_certificate_parsing_and_team(self):
        subj = f"/CN=Apple Distribution: Josh, Inc ({TEAM})/OU={TEAM}/O=Josh/C=US"
        self.ssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30", "-subj", subj,
                 "-keyout", str(self.tmp / "d.key"), "-out", str(self.tmp / "d.pem"))
        der = tf.pem_blocks((self.tmp / "d.pem").read_text())[0]
        info = tf.cert_info(der)
        self.assertEqual(info["subject"]["OU"], TEAM)
        self.assertEqual(info["subject"]["CN"], f"Apple Distribution: Josh, Inc ({TEAM})")
        now = dt.datetime.now(dt.timezone.utc)
        tf.validate_cert(info, TEAM, now)
        with self.assertRaises(tf.Fail):
            tf.validate_cert(info, "ZZZZZ99999", now)
        with self.assertRaises(tf.Fail):
            tf.validate_cert(info, TEAM, now + dt.timedelta(days=40))


if __name__ == "__main__":
    unittest.main()
