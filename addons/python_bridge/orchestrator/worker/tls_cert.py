#!/usr/bin/env python3
"""Selbstsignierte TLS-Zertifikate - **ohne Zusatzpakete** (nur Standardbibliothek).

Warum eigener Code?

Der Worker soll verschluesselte Verbindungen (`wss://`) anbieten koennen, ohne
dass der Benutzer `openssl`, `cryptography`, Zertifikatsdateien oder Terminal-
befehle besorgen muss. `cryptography` ist nicht ueberall vorhanden, und ein
`openssl`-Aufruf scheitert auf einem nackten Windows. Deshalb erzeugt dieses
Modul ein selbstsigniertes RSA-2048-Zertifikat direkt in Python:

    RSA-Schluessel   : Miller-Rabin-Primzahlen + e=65537
    Private Key      : PKCS#8 ("BEGIN PRIVATE KEY")
    Zertifikat       : X.509 v3, CA:TRUE (dadurch als eigene CA nutzbar),
                       SAN fuer localhost + erkannte LAN-Adressen
    Signatur         : RSA / SHA-256, PKCS#1 v1.5

Damit kann die Managerseite waehlen zwischen

    * "Zertifikat anheften"  (TLSOptions.client(<cert>))  - echte Pruefung
    * "selbstsigniert erlaubt" (TLSOptions.client_unsafe)  - nur Verschluesselung

Das Zertifikat liegt im Cache des Workers und wird wiederverwendet; laeuft es
ab, wird still ein neues erzeugt.

Sicherheitshinweis: der private Schluessel bleibt auf dem Rechner des Workers
(Rechte 0600) und wird **nie** ueber das Netz gesendet. Der Fingerabdruck
(SHA-256) geht an den Manager - aber nur zur Anzeige/Erkennung, er ist kein
Geheimnis.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import socket
import stat
import time
from pathlib import Path

__all__ = [
    "ensure_self_signed",
    "certificate_fingerprint",
    "format_fingerprint",
    "CertificateError",
]

# 825 Tage ist die uebliche Obergrenze, die Browser fuer selbstsignierte
# Zertifikate akzeptieren. Danach wird automatisch neu erzeugt.
_VALID_DAYS = 825
_KEY_BITS = 2048
_PUBLIC_EXPONENT = 65537
_ORG = "PythonBridge"
_SERVER_CN = "python_bridge_worker"

# DigestInfo-Prefix fuer SHA-256 (RFC 8017, Abschnitt 9.2). Damit ist die
# Signatur exakt eine PKCS#1-v1.5-Signatur ueber SHA-256.
_SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")


class CertificateError(RuntimeError):
    """Zertifikat konnte nicht erzeugt oder gelesen werden."""


# ------------------------------------------------------------------ ASN.1/DER
def _der_len(length: int) -> bytes:
    if length < 0x80:
        return bytes([length])
    raw = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(raw)]) + raw


def _tlv(tag: int, payload: bytes) -> bytes:
    return bytes([tag]) + _der_len(len(payload)) + payload


def _seq(*items: bytes) -> bytes:
    return _tlv(0x30, b"".join(items))


def _set(*items: bytes) -> bytes:
    return _tlv(0x31, b"".join(items))


def _int(value: int) -> bytes:
    if value == 0:
        return _tlv(0x02, b"\x00")
    raw = value.to_bytes((value.bit_length() + 8) // 8, "big")
    return _tlv(0x02, raw)


def _bitstring(payload: bytes) -> bytes:
    return _tlv(0x03, b"\x00" + payload)


def _octetstring(payload: bytes) -> bytes:
    return _tlv(0x04, payload)


def _null() -> bytes:
    return _tlv(0x05, b"")


def _utf8(value: str) -> bytes:
    return _tlv(0x0C, value.encode("utf-8"))


def _utctime(when: float) -> bytes:
    stamp = time.gmtime(when)
    text = time.strftime("%y%m%d%H%M%SZ", stamp)
    return _tlv(0x17, text.encode("ascii"))


def _oid(dotted: str) -> bytes:
    parts = [int(p) for p in dotted.split(".")]
    if len(parts) < 2:
        raise CertificateError("ungueltige OID: %s" % dotted)
    first = 40 * parts[0] + parts[1]
    body = bytearray([first])
    for value in parts[2:]:
        chunk = [value & 0x7F]
        value >>= 7
        while value:
            chunk.append(0x80 | (value & 0x7F))
            value >>= 7
        body.extend(reversed(chunk))
    return _tlv(0x06, bytes(body))


_OID_RSA_ENCRYPTION = "1.2.840.113549.1.1.1"
_OID_SHA256_RSA = "1.2.840.113549.1.1.11"
_OID_CN = "2.5.4.3"
_OID_O = "2.5.4.10"
_OID_BASIC_CONSTRAINTS = "2.5.29.19"
_OID_KEY_USAGE = "2.5.29.15"
_OID_EXT_KEY_USAGE = "2.5.29.37"
_OID_SUBJECT_ALT_NAME = "2.5.29.17"
_OID_SUBJECT_KEY_ID = "2.5.29.14"
_OID_SERVER_AUTH = "1.3.6.1.5.5.7.3.1"
_OID_CLIENT_AUTH = "1.3.6.1.5.5.7.3.2"


def _signature_algorithm() -> bytes:
    """AlgorithmIdentifier fuer die Signatur (sha256WithRSAEncryption)."""
    return _seq(_oid(_OID_SHA256_RSA), _null())


def _key_algorithm() -> bytes:
    """AlgorithmIdentifier des **Schluessels** (rsaEncryption).

    Wichtig: Signatur- und Schluessel-Algorithmus sind zwei verschiedene OIDs.
    Wird hier die Signatur-OID verwendet, kann OpenSSL den oeffentlichen
    Schluessel nicht dekodieren ("X509_PUBKEY_get0: decode error") und lehnt
    das ganze Zertifikat ab.
    """
    return _seq(_oid(_OID_RSA_ENCRYPTION), _null())


def _name(common_name: str, organization: str) -> bytes:
    # RelativeDistinguishedName = SET OF AttributeTypeAndValue (je ein Wert,
    # damit die Sortierung der SET-Elemente irrelevant bleibt).
    return _seq(
        _set(_seq(_oid(_OID_O), _utf8(organization))),
        _set(_seq(_oid(_OID_CN), _utf8(common_name))),
    )


# ----------------------------------------------------------------- RSA-Schluessel
_SMALL_PRIMES = (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59,
                 61, 67, 71, 73, 79, 83, 89, 97, 101, 103, 107, 109, 113, 127,
                 131, 137, 139, 149, 151, 157, 163, 167, 173, 179, 181, 191, 193,
                 197, 199, 211, 223, 227, 229, 233, 239, 241, 251)


def _is_probable_prime(candidate: int) -> bool:
    """Miller-Rabin mit festen kleinen Basen + Zufallsbasen.

    Fuer RSA-2048 reicht das mit deutlichem Abstand aus (Fehlerwahrscheinlich-
    keit < 2^-100); teure Tests werden durch die kleinen Teiler vorher
    abgefangen.
    """
    if candidate < 2:
        return False
    for prime in _SMALL_PRIMES:
        if candidate % prime == 0:
            return candidate == prime
    d = candidate - 1
    s = 0
    while d % 2 == 0:
        d //= 2
        s += 1
    bases = list(_SMALL_PRIMES) + [secrets.randbelow(candidate - 3) + 2 for _ in range(16)]
    for base in bases:
        base %= candidate
        if base < 2:
            continue
        x = pow(base, d, candidate)
        if x in (1, candidate - 1):
            continue
        for _ in range(s - 1):
            x = x * x % candidate
            if x == candidate - 1:
                break
        else:
            return False
    return True


def _random_prime(bits: int) -> int:
    while True:
        candidate = secrets.randbits(bits) | (1 << (bits - 1)) | 1
        # p-1 muss teilerfremd zu e sein, sonst ist d nicht berechenbar.
        if (candidate - 1) % _PUBLIC_EXPONENT == 0:
            continue
        if _is_probable_prime(candidate):
            return candidate


def _generate_rsa(bits: int = _KEY_BITS) -> dict:
    """Erzeugt einen RSA-Schluessel und gibt die PKCS#1-Bestandteile zurueck."""
    e = _PUBLIC_EXPONENT
    half = bits // 2
    while True:
        p = _random_prime(half)
        q = _random_prime(bits - half)
        if p == q:
            continue
        n = p * q
        if n.bit_length() != bits:
            continue
        phi = (p - 1) * (q - 1)
        if phi % e == 0:
            continue
        d = pow(e, -1, phi)
        break
    # PKCS#1 erwartet p > q, damit qInv definiert und der CRT-Ablauf eindeutig ist.
    if p < q:
        p, q = q, p
    return {
        "n": n,
        "e": e,
        "d": d,
        "p": p,
        "q": q,
        "dp": d % (p - 1),
        "dq": d % (q - 1),
        "qinv": pow(q, -1, p),
    }


def _private_key_der(key: dict) -> bytes:
    """PKCS#8 PrivateKeyInfo (universell lesbar, auch von Python/OpenSSL)."""
    pkcs1 = _seq(
        _int(0),
        _int(key["n"]),
        _int(key["e"]),
        _int(key["d"]),
        _int(key["p"]),
        _int(key["q"]),
        _int(key["dp"]),
        _int(key["dq"]),
        _int(key["qinv"]),
    )
    return _seq(
        _int(0),
        _seq(_oid(_OID_RSA_ENCRYPTION), _null()),
        _octetstring(pkcs1),
    )


def _public_key_der(key: dict) -> bytes:
    return _seq(_int(key["n"]), _int(key["e"]))


def _sign(key: dict, data: bytes) -> bytes:
    """PKCS#1 v1.5 Signatur ueber SHA-256."""
    digest = hashlib.sha256(data).digest()
    k = (key["n"].bit_length() + 7) // 8
    padding = b"\xff" * (k - len(_SHA256_DIGEST_INFO) - len(digest) - 3)
    encoded = b"\x00\x01" + padding + b"\x00" + _SHA256_DIGEST_INFO + digest
    signature = pow(int.from_bytes(encoded, "big"), key["d"], key["n"])
    return signature.to_bytes(k, "big")


# ------------------------------------------------------------------ LAN-Adressen
def _local_ipv4_addresses() -> list:
    """Alle lokalen IPv4-Adressen, die der Manager plausibel benutzt."""
    found = []

    def _add(value: str) -> None:
        if value and value != "127.0.0.1" and value not in found:
            found.append(value)

    # UDP-Trick: liefert die Adresse des Standard-Interfaces, ohne zu senden.
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("8.8.8.8", 80))
        _add(probe.getsockname()[0])
    except OSError:
        pass
    finally:
        probe.close()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            _add(info[4][0])
    except OSError:
        pass
    return found


def _subject_alt_name(addresses: list) -> bytes:
    names = [b"\x82" + _der_len(len(b"localhost")) + b"localhost"]  # dNSName
    for address in ["127.0.0.1"] + list(addresses):
        try:
            packed = socket.inet_aton(address)
        except OSError:
            continue
        names.append(b"\x87" + _der_len(len(packed)) + packed)  # iPAddress
    return _seq(*names)


def _extensions(addresses: list, key: dict) -> bytes:
    # CA:TRUE + keyCertSign: dadurch ist dieses Zertifikat seine **eigene** CA.
    # Genau das erlaubt dem Manager das Anheften (TLSOptions.client).
    basic = _seq(_tlv(0x01, b"\xff"))                    # critical, CA:TRUE
    # Bit 0 digitalSignature, Bit 2 keyEncipherment, Bit 5 keyCertSign,
    # Bit 6 cRLSign -> 0b10100110 (Bit 0 ist das hoechste Bit des ersten Bytes).
    key_usage = _bitstring(bytes([0b10100110]))
    ext_key_usage = _seq(_oid(_OID_SERVER_AUTH), _oid(_OID_CLIENT_AUTH))
    subject_key_id = _octetstring(
        hashlib.sha1(key["n"].to_bytes((key["n"].bit_length() + 7) // 8, "big")).digest())
    items = [
        _seq(_oid(_OID_BASIC_CONSTRAINTS), _tlv(0x01, b"\xff"), _octetstring(basic)),
        _seq(_oid(_OID_KEY_USAGE), _tlv(0x01, b"\xff"), _octetstring(key_usage)),
        _seq(_oid(_OID_EXT_KEY_USAGE), _octetstring(ext_key_usage)),
        _seq(_oid(_OID_SUBJECT_ALT_NAME), _octetstring(_subject_alt_name(addresses))),
        _seq(_oid(_OID_SUBJECT_KEY_ID), _octetstring(subject_key_id)),
    ]
    # [3] EXPLICIT Extensions: der Kontext-Wrapper enthaelt **eine** SEQUENCE
    # (Extensions = SEQUENCE OF Extension) - ohne sie ist das Zertifikat formal
    # ungueltig und wird von OpenSSL/Browsern abgelehnt.
    return _tlv(0xA3, _seq(*items))


def _certificate_der(key: dict, common_name: str, organization: str,
                     addresses: list, days: int) -> bytes:
    now = time.time()
    name = _name(common_name, organization)
    tbs = _seq(
        _tlv(0xA0, _int(2)),                             # version v3
        _int(secrets.randbits(64) | 1),                  # serialNumber
        _signature_algorithm(),
        name,                                            # issuer
        _seq(_utctime(now - 3600), _utctime(now + days * 86400)),
        name,                                            # subject (selbstsigniert)
        _seq(_key_algorithm(), _bitstring(_public_key_der(key))),
        _extensions(addresses, key),
    )
    return _seq(tbs, _signature_algorithm(), _bitstring(_sign(key, tbs)))


# ----------------------------------------------------------------------- PEM
def _pem(der: bytes, label: str) -> str:
    body = base64.b64encode(der).decode("ascii")
    lines = [body[i:i + 64] for i in range(0, len(body), 64)]
    return "-----BEGIN %s-----\n%s\n-----END %s-----\n" % (label, "\n".join(lines), label)


def _pem_to_der(text: str, label: str) -> bytes:
    begin = "-----BEGIN %s-----" % label
    end = "-----END %s-----" % label
    start = text.find(begin)
    stop = text.find(end)
    if start < 0 or stop < 0:
        raise CertificateError("kein %s-Block gefunden" % label)
    body = "".join(text[start + len(begin):stop].split())
    try:
        return base64.b64decode(body, validate=True)
    except (ValueError, TypeError) as exc:
        raise CertificateError("PEM nicht lesbar: %s" % exc) from None


def certificate_fingerprint(pem_text: str) -> str:
    """SHA-256 ueber das DER-Zertifikat als Hex (ohne Trennzeichen)."""
    return hashlib.sha256(_pem_to_der(pem_text, "CERTIFICATE")).hexdigest()


def format_fingerprint(hex_digest: str) -> str:
    """64-Hex -> gut lesbare Schreibweise mit Doppelpunkten."""
    cleaned = "".join(ch for ch in hex_digest if ch in "0123456789abcdefABCDEF")
    pairs = [cleaned[i:i + 2].upper() for i in range(0, len(cleaned), 2)]
    return ":".join(pairs)


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise CertificateError("Datei nicht lesbar (%s): %s" % (path, exc)) from None


def ensure_self_signed(cache_dir: str | os.PathLike,
                       common_name: str = _SERVER_CN,
                       organization: str = _ORG,
                       days: int = _VALID_DAYS,
                       log=None) -> dict:
    """Liefert (und erzeugt bei Bedarf) ein selbstsigniertes Zertifikat.

    Rueckgabe:
        {"cert": <pfad>, "key": <pfad>, "fingerprint": "<64 hex>", "created": bool}

    Der Aufruf ist idempotent: existieren Zertifikat und Schluessel noch und
    sind sie nicht abgelaufen, werden sie wiederverwendet (stabiler Finger-
    abdruck ueber Neustarts hinweg - wichtig, damit der Manager den Rechner
    wiedererkennt).
    """
    def _say(message: str) -> None:
        if log is not None:
            log(message)

    base = Path(cache_dir).expanduser()
    tls_dir = base / "tls"
    cert_path = tls_dir / "worker-cert.pem"
    key_path = tls_dir / "worker-key.pem"
    meta_path = tls_dir / "worker-cert.json"
    meta: dict = {}
    if meta_path.is_file():
        try:
            loaded = json.loads(meta_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                meta = loaded
        except (OSError, ValueError):
            meta = {}
    if cert_path.is_file() and key_path.is_file() and meta:
        created = float(meta.get("created", 0))
        if created > 0 and time.time() < created + (days - 7) * 86400:
            try:
                pem = _read_text(cert_path)
                fingerprint = certificate_fingerprint(pem)
                if fingerprint == str(meta.get("fingerprint", "")):
                    return {"cert": str(cert_path), "key": str(key_path),
                            "fingerprint": fingerprint, "created": False}
            except CertificateError:
                pass  # beschaedigt -> neu erzeugen

    try:
        tls_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise CertificateError("TLS-Ordner nicht anlegbar (%s): %s" % (tls_dir, exc)) from None

    addresses = _local_ipv4_addresses()
    _say("Erzeuge selbstsigniertes TLS-Zertifikat (RSA-%d) ..." % _KEY_BITS)
    key = _generate_rsa(_KEY_BITS)
    cert_der = _certificate_der(key, common_name, organization, addresses, days)
    cert_pem = _pem(cert_der, "CERTIFICATE")
    key_pem = _pem(_private_key_der(key), "PRIVATE KEY")

    # Schluessel zuerst und sofort mit engen Rechten schreiben; erst danach
    # atomar umbenennen, damit nie ein halb geschriebener Schluessel liegen
    # bleibt.
    key_tmp = key_path.with_suffix(".pem.tmp")
    try:
        key_tmp.write_text(key_pem, encoding="utf-8")
        os.chmod(key_tmp, stat.S_IRUSR | stat.S_IWUSR)
        os.replace(key_tmp, key_path)
        cert_tmp = cert_path.with_suffix(".pem.tmp")
        cert_tmp.write_text(cert_pem, encoding="utf-8")
        os.replace(cert_tmp, cert_path)
    except OSError as exc:
        raise CertificateError("Zertifikat nicht schreibbar: %s" % exc) from None

    fingerprint = hashlib.sha256(cert_der).hexdigest()
    meta = {
        "created": time.time(),
        "days": days,
        "fingerprint": fingerprint,
        "common_name": common_name,
        "addresses": addresses,
        "key_bits": _KEY_BITS,
    }
    try:
        meta_tmp = meta_path.with_suffix(".json.tmp")
        meta_tmp.write_text(json.dumps(meta, indent=2), encoding="utf-8")
        os.replace(meta_tmp, meta_path)
    except OSError:
        pass  # Metadaten sind nur Komfort; fehlen sie, wird neu erzeugt.
    _say("Zertifikat erzeugt: %s" % format_fingerprint(fingerprint))
    return {"cert": str(cert_path), "key": str(key_path),
            "fingerprint": fingerprint, "created": True}


if __name__ == "__main__":  # kleine Selbstprobe / Diagnose
    import argparse
    import tempfile

    ap = argparse.ArgumentParser(description="Selbstsigniertes Worker-Zertifikat")
    ap.add_argument("--cache-dir", default="")
    ap.add_argument("--cn", default=_SERVER_CN)
    ap.add_argument("--print-cert", action="store_true")
    ns = ap.parse_args()
    target = ns.cache_dir or (Path(tempfile.gettempdir()) / "python_bridge_worker")
    result = ensure_self_signed(target, ns.cn, log=print)
    print("cert:", result["cert"])
    print("key :", result["key"])
    print("SHA-256:", format_fingerprint(result["fingerprint"]))
    if ns.print_cert:
        print(_read_text(Path(result["cert"])))
