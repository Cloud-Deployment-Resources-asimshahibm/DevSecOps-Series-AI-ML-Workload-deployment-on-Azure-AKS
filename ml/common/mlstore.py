"""Minimal model registry on Azure Blob Storage (or a local directory for dev/tests).

URIs:
    az://<storage-account>/<container>[/<prefix>]     e.g. az://aimldevdataab12cd/models
    /local/path or ./relative/path

Layout under the store root:

    <model>/<version>/model.pkl         serialized sklearn pipeline (pickle protocol 5)
    <model>/<version>/metadata.json     metrics, params, gate result, git sha, artifact_sha256
    <model>/<version>/security.json     ModelScan result (written by the scan step, required to promote)
    <model>/latest.json                 {"version": ..., "previous": ...}  <- written ONLY by promotion

Inference servers follow latest.json, so promotion / rollback is a single,
atomic pointer write and never requires a redeploy.

Authentication uses DefaultAzureCredential: Microsoft Entra Workload ID in the
cluster (federated token injected by AKS), `az login` on a laptop. Storage
account keys are disabled on purpose.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
from functools import lru_cache
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

AZ_SCHEME = "az://"


def is_azure(uri: str) -> bool:
    return uri.startswith(AZ_SCHEME)


def split_az(uri: str) -> tuple[str, str, str]:
    """az://account/container/some/prefix -> (account, container, "some/prefix")."""
    parsed = urlparse(uri)
    if parsed.scheme != "az" or not parsed.netloc:
        raise ValueError(f"not an az:// URI: {uri!r}")
    container, _, prefix = parsed.path.lstrip("/").partition("/")
    if not container:
        raise ValueError(f"az:// URI needs a container: {uri!r}")
    return parsed.netloc, container, prefix.strip("/")


@lru_cache(maxsize=8)
def _blob_service(account: str):  # pragma: no cover - exercised against real Azure
    from azure.identity import DefaultAzureCredential
    from azure.storage.blob import BlobServiceClient

    suffix = os.getenv("AZURE_STORAGE_ENDPOINT_SUFFIX", "core.windows.net")
    return BlobServiceClient(f"https://{account}.blob.{suffix}", credential=DefaultAzureCredential())


def _container(account: str, container: str):
    return _blob_service(account).get_container_client(container)


def sha256_file(path: Path | str, chunk: int = 1 << 20) -> str:
    """SHA-256 of a file, used to pin model artifacts (supply-chain integrity)."""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


class IntegrityError(RuntimeError):
    """Model artifact does not match its recorded digest or has not passed the security scan."""


def read_bytes_uri(uri: str) -> bytes:
    """Read raw bytes from az://account/container/blob or a local path."""
    if is_azure(uri):
        account, container, blob = split_az(uri)
        return _container(account, container).download_blob(blob).readall()
    return Path(uri).read_bytes()


def read_json_uri(uri: str) -> dict[str, Any]:
    """Read a JSON document from az://account/container/blob or a local path."""
    return json.loads(read_bytes_uri(uri))


def write_json_uri(uri: str, obj: dict[str, Any]) -> None:
    data = json.dumps(obj, indent=2, sort_keys=True).encode()
    if is_azure(uri):
        from azure.storage.blob import ContentSettings

        account, container, blob = split_az(uri)
        _container(account, container).upload_blob(
            blob, data, overwrite=True, content_settings=ContentSettings(content_type="application/json")
        )
        return
    path = Path(uri)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


class ModelStore:
    def __init__(self, uri: str) -> None:
        self.uri = uri.rstrip("/")
        self.is_azure = is_azure(self.uri)
        if self.is_azure:
            self.account, self.container_name, self.prefix = split_az(self.uri)
            self._container = _container(self.account, self.container_name)
        else:
            self.root = Path(self.uri)

    # ------------------------------------------------------------------ paths
    def _key(self, *parts: str) -> str:
        return "/".join(p.strip("/") for p in (self.prefix, *parts) if p)

    def _path(self, *parts: str) -> Path:
        return self.root.joinpath(*parts)

    def _az(self, *parts: str) -> str:
        return f"{AZ_SCHEME}{self.account}/{self.container_name}/{self._key(*parts)}"

    # ------------------------------------------------------------------ files
    def put_file(self, local: Path, *parts: str) -> str:
        if self.is_azure:
            with open(local, "rb") as fh:
                self._container.upload_blob(self._key(*parts), fh, overwrite=True)
            return self._az(*parts)
        dest = self._path(*parts)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(local, dest)
        return str(dest)

    def get_file(self, local: Path, *parts: str) -> Path:
        local.parent.mkdir(parents=True, exist_ok=True)
        if self.is_azure:
            with open(local, "wb") as fh:
                self._container.download_blob(self._key(*parts)).readinto(fh)
        else:
            shutil.copyfile(self._path(*parts), local)
        return local

    def put_json(self, obj: dict[str, Any], *parts: str) -> None:
        write_json_uri(self._az(*parts) if self.is_azure else str(self._path(*parts)), obj)

    def get_json(self, *parts: str) -> dict[str, Any]:
        return read_json_uri(self._az(*parts) if self.is_azure else str(self._path(*parts)))

    def exists(self, *parts: str) -> bool:
        if self.is_azure:
            return self._container.get_blob_client(self._key(*parts)).exists()
        return self._path(*parts).exists()

    # ------------------------------------------------------------------ registry
    def latest_version(self, model: str) -> str:
        return self.get_json(model, "latest.json")["version"]

    def resolve(self, model: str, version: str = "latest") -> str:
        return self.latest_version(model) if version == "latest" else version

    def promote(self, model: str, version: str) -> dict[str, Any]:
        previous = self.latest_version(model) if self.exists(model, "latest.json") else None
        pointer = {"version": version, "previous": previous}
        self.put_json(pointer, model, "latest.json")
        return pointer
