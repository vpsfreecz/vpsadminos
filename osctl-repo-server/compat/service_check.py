"""Black-box native catalog/GC and old-client checks against an isolated service.

The caller supplies an already running disposable server and the real control
binary. This script never starts a server or connects to a default/live address.
"""

import argparse
import hashlib
import http.client
import json
from pathlib import Path
import subprocess
import tempfile
import urllib.parse
import uuid


FIXTURES = Path(__file__).resolve().parents[1] / "testdata/native"
TUPLE_KEYS = ("vendor", "variant", "arch", "distribution", "version")
FILENAMES = {"tar": "image-archive.tar", "zfs": "image-stream.tar"}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class ServiceCheck:
    def __init__(self, args):
        self.args = args
        self.base = args.url.rstrip("/")
        parsed = urllib.parse.urlsplit(self.base)
        require(parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost", "::1"),
                "Only an explicitly supplied disposable loopback HTTP service is accepted")
        require(not parsed.query and not parsed.fragment, "URL must not include query/fragment")
        self.source = "1" * 40

    def control(self, operation, params=None, run_key=None, role="producer", body=b"", error=None,
                allow_missing=False):
        request = {"request_id": str(uuid.uuid4()), "operation": operation,
                   "repository": self.args.repository, "params": params or {}}
        if run_key:
            request["run_key"] = run_key
        wire = json.dumps(request).encode() + b"\n" + body
        process = subprocess.run([self.args.cli, "ctl", "--socket", getattr(self.args, role)],
                                 input=wire, capture_output=True, timeout=10, check=False)
        try:
            response = json.loads(process.stdout)
        except ValueError as exc:
            raise AssertionError(f"{operation}: invalid CLI response {process.stderr!r}") from exc
        if allow_missing and not response["ok"] and response["error"]["code"] == "not_found":
            return None
        if error:
            require(not response["ok"] and response["error"]["code"] == error,
                    f"{operation}: expected {error}, got {response}")
            return response
        require(response["ok"], f"{operation}: {response}")
        require(process.returncode == 0, f"{operation}: CLI exit {process.returncode}")
        return response.get("result")

    def http(self, path, method="GET", headers=None):
        parsed = urllib.parse.urlsplit(self.base)
        connection = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=5)
        try:
            connection.request(method, parsed.path + path, headers=headers or {"Accept-Encoding": "identity"})
            response = connection.getresponse()
            fields = response.getheaders()
            body = response.read()
            lengths = [v for k, v in fields if k.lower() == "content-length"]
            encodings = [v for k, v in fields if k.lower() == "transfer-encoding"]
            require(len(lengths) <= 1 and not (lengths and encodings),
                    f"{path}: invalid or duplicate response framing: {fields}")
            if method == "GET" and response.status == 200:
                require(not lengths or int(lengths[0]) == len(body), f"{path}: wrong Content-Length")
            require(not response.getheader("Content-Encoding"), f"{path}: encoded identity response")
            return response.status, dict((k.lower(), v) for k, v in fields), body
        finally:
            connection.close()

    def catalog(self, expected, prefix=""):
        status, headers, body = self.http(prefix + "/v1/INDEX.json")
        require(status == 200, f"INDEX returned {status}")
        require(json.loads(body) == expected["index"], "INDEX differs from native semantics/order")
        require("last-modified" in headers, "Old clients require Last-Modified")
        if prefix:
            status, _, body = self.http(prefix + "/v1/INDEX.json",
                                       headers={"If-Modified-Since": headers["last-modified"]})
            require(status == 304 and not body, "Sealed INDEX IMS did not return 304")
        return headers

    def payloads(self, expected, prefix="", sealed=False):
        for path, payload in expected["files"].items():
            route = prefix + "/" + path
            status, headers, body = self.http(route)
            require(status == 200 and body == payload["contents"].encode(), f"Wrong bytes at {route}")
            require(hashlib.sha256(body).hexdigest() == payload["sha256"], f"Wrong hash at {route}")
            require("last-modified" in headers, f"Missing payload Last-Modified at {route}")
            status, head, body = self.http(route, "HEAD")
            require(status == 200 and body == b"", f"Invalid HEAD at {route}")
            require(int(head["content-length"]) == payload["size"], f"Wrong HEAD size at {route}")
            status, _, body = self.http(route, headers={"If-Modified-Since": headers["last-modified"],
                                                       "Accept-Encoding": "identity"})
            require(status in (200, 304), f"Invalid IMS status at {route}")
            if sealed:
                require(status == 304 and not body, f"Sealed payload IMS did not return 304: {route}")

    def aliases(self, expected, prefix=""):
        # Native symlinks are an independent oracle for combined default/tag paths.
        for image in expected["index"]["images"]:
            vendor = image["vendor"]
            variant = image["variant"]
            vendors = expected["index"]["vendors"]
            choices = [(vendor, variant)]
            if vendors.get(vendor) == variant:
                choices.append((vendor, "default"))
                if vendors.get("default") == vendor:
                    choices.append(("default", "default"))
            for fmt, native_path in image["image"].items():
                payload = expected["files"]["v1/" + native_path]["contents"].encode()
                for alias_vendor, alias_variant in choices:
                    for version in [image["version"], *image["tags"]]:
                        path = "/".join((prefix, "v1", alias_vendor, alias_variant,
                                         image["arch"], image["distribution"], version, FILENAMES[fmt]))
                        status, _, body = self.http(path)
                        require(status == 200 and body == payload, f"Native alias mismatch at {path}")

    def begin(self, descriptors, failed, snapshot):
        all_items = descriptors + failed
        expected = [{"id": f"item-{i}", "order": i, "tags": d["tags"]}
                    for i, d in enumerate(all_items)]
        result = self.control("begin", {"id": "compat-" + str(uuid.uuid4()), "attempt": 1,
                                       "source": {"sha": self.source, "input_digest": "a" * 64,
                                                  "event": "push", "ref": "refs/heads/staging"},
                                       "expected": expected, "defaults": snapshot["index"]["vendors"],
                                       "lease_seconds": 300})
        key = result["key"]
        # Reverse completion deliberately: configured order must determine tags.
        for i in reversed(range(len(all_items))):
            descriptor = all_items[i]
            item_id = f"item-{i}"
            fields = dict(zip(TUPLE_KEYS, descriptor["tuple"]))
            fields.update(formats=descriptor["formats"], config_digest="b" * 64)
            self.control("bind", {"item_id": item_id, "attempt": 1, "descriptor": fields}, key)
            success = i < len(descriptors)
            if success:
                for fmt in descriptor["formats"]:
                    path = "/".join(("v1", *descriptor["tuple"], FILENAMES[fmt]))
                    payload = snapshot["files"][path]
                    self.control("upload", {"item_id": item_id, "attempt": 1, "format": fmt,
                                            "sha256": payload["sha256"], "size": payload["size"]},
                                 key, body=payload["contents"].encode())
            self.control("result", {"item_id": item_id, "attempt": 1,
                                    "config_digest": "b" * 64, "build_ok": success,
                                    "tests_ok": success, "state": "verified" if success else "failed"}, key)
        self.control("finish", run_key=key)
        return key, [f"item-{i}" for i in range(len(descriptors))]

    def publish(self, key, items, snapshot, gc):
        public = self.control("status")
        self.control("publish", {"generation": public["generation"], "items": items,
                                 "defaults": snapshot["index"]["vendors"], "gc": gc,
                                 "ancestors": ["1" * 40, "2" * 40]}, key, role="publisher")

    def native_client(self, expected, prefix=""):
        url = self.base + prefix
        with tempfile.TemporaryDirectory(prefix="osctl-repo-old-client-") as cache:
            image = expected["index"]["images"][0]
            fmt, relpath = next(iter(image["image"].items()))
            identity = [image[k] for k in TUPLE_KEYS] + [fmt]
            wanted = expected["files"]["v1/" + relpath]["contents"].encode()
            command = [self.args.native_cli, "remote", "get", "stream"]
            direct = subprocess.run(command + [url, *identity], capture_output=True, timeout=15, check=True)
            require(direct.stdout == wanted, "Native direct client bytes differ")
            cached = command + ["--cache", cache, "--force-check", url, *identity]
            for _ in range(2):
                result = subprocess.run(cached, capture_output=True, timeout=15, check=True)
                require(result.stdout == wanted, "Native forced-check cached client bytes differ")

    def same_tuple_refresh(self, expected, baseline_key):
        image = expected["index"]["images"][0]
        descriptor = {"tuple": [image[k] for k in TUPLE_KEYS], "tags": image["tags"],
                      "formats": list(image["image"])}
        changed = json.loads(json.dumps(expected))
        fmt, relpath = next(iter(image["image"].items()))
        old = expected["files"]["v1/" + relpath]["contents"].encode()
        for native_path in image["image"].values():
            payload = changed["files"]["v1/" + native_path]
            payload["contents"] += "same-tuple replacement\n"
            raw = payload["contents"].encode()
            payload.update(sha256=hashlib.sha256(raw).hexdigest(), size=len(raw))
        route = "/v1/" + relpath
        _, old_headers, _ = self.http(route)
        with tempfile.TemporaryDirectory(prefix="osctl-repo-refresh-") as cache:
            command = [self.args.native_cli, "remote", "get", "stream", "--cache", cache,
                       "--force-check", self.base, *descriptor["tuple"], fmt]
            before = subprocess.run(command, capture_output=True, timeout=15, check=True)
            require(before.stdout == old, "Native pre-replacement cache bytes differ")
            self.source = "3" * 40
            key, items = self.begin([descriptor], [], changed)
            self.publish(key, items, changed, [])
            status, _, body = self.http(route, headers={"If-Modified-Since": old_headers["last-modified"]})
            new = changed["files"]["v1/" + relpath]["contents"].encode()
            require(status == 200 and body == new, "Replacement returned stale 304/old payload")
            after = subprocess.run(command, capture_output=True, timeout=15, check=True)
            require(after.stdout == new, "Native cached client retained replaced bytes")
            status, _, body = self.http(f"/runs/{baseline_key}" + route)
            require(status == 200 and body == old, "Public replacement changed pinned baseline bytes")

    def failed_existing_tuple(self, expected):
        image = expected["index"]["images"][0]
        descriptor = {"tuple": [image[k] for k in TUPLE_KEYS], "tags": image["tags"],
                      "formats": list(image["image"])}
        key, _ = self.begin([], [descriptor], expected)
        self.control("seal", run_key=key, error="not_ready")
        relpath = next(iter(image["image"].values()))
        status, _, _ = self.http(f"/runs/{key}/v1/" + relpath)
        require(status in (409, 503), "Existing public tuple masked a failed selected rebuild")

    def run(self):
        oracle = json.loads((FIXTURES / f"{self.args.scenario}.json").read_text())
        initial = self.control("status", allow_missing=True)
        require(initial is None or not initial["catalog"]["images"], "Service repository must start empty")
        spec = oracle["operations"]
        key, items = self.begin(spec["baseline"], [], oracle["baseline"])
        baseline_key = key
        self.control("seal", run_key=key)
        self.catalog(oracle["baseline"], f"/runs/{key}")
        initial_gc = spec["gc"] if not spec["updates"] else []
        self.publish(key, items, oracle["baseline"], initial_gc)
        if spec["updates"]:
            self.source = "2" * 40
            key, items = self.begin(spec["updates"], spec["failed"], oracle["before_gc"])
            if spec["failed"]:
                self.control("seal", run_key=key, error="not_ready")
                status, _, _ = self.http(f"/runs/{key}/v1/INDEX.json")
                require(status in (409, 503), "Failed selected images must prevent ready run INDEX")
            else:
                self.control("seal", run_key=key)
                self.catalog(oracle["before_gc"], f"/runs/{key}")
                self.payloads(oracle["before_gc"], f"/runs/{key}", sealed=True)
                self.native_client(oracle["before_gc"], f"/runs/{key}")
            self.publish(key, items, oracle["before_gc"], spec["gc"])
        self.catalog(oracle["after_gc"])
        self.payloads(oracle["after_gc"])
        self.aliases(oracle["after_gc"])
        self.native_client(oracle["after_gc"])
        for image in oracle["after_gc"]["index"]["images"]:
            if "tar" not in image["image"]:
                route = "/v1/" + "/".join(image[k] for k in TUPLE_KEYS) + "/image-archive.tar"
                require(self.http(route)[0] == 404, "Stream-only image unexpectedly has archive format")
        if not spec["updates"]:
            # The sealed pre-GC view retains bytes hidden from the public catalog.
            self.payloads(oracle["baseline"], f"/runs/{key}", sealed=True)
        missing = "/v1/vpsadminos/minimal/x86_64/unknown/0/image-archive.tar"
        require(self.http(missing)[0] == 404, "Unknown image path must return 404")
        self.failed_existing_tuple(oracle["after_gc"])
        self.same_tuple_refresh(oracle["after_gc"], baseline_key)
        print(f"PASS {self.args.scenario}: native INDEX/GC/aliases/bytes, HTTP framing and old clients")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("url", "cli", "native-cli", "producer", "publisher", "repository"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--scenario", choices=("catalog", "gc", "subset", "mixed_failure"), required=True)
    ServiceCheck(parser.parse_args()).run()
