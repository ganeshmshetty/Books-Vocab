"""Unit-level security contract for App Store JWS verification.

Directly exercises ``verify_and_decode_signed_jws`` (the trust root for every
StoreKit subscription proof) against the three hardening requirements:

1. alg pinned to ES256 — algorithm is NOT taken from the attacker-controlled
   JWS header.
2. claim verification — ``exp`` is enforced and the ``bundleId`` claim, when
   present, must match this app.
3. cert-chain OID pin — the leaf must carry Apple's App Store OID
   ``1.2.840.113635.100.6.11.1`` so an arbitrary cert merely chained to the
   Apple Root cannot impersonate the App Store leaf.

Each requirement has a positive case (a correctly-structured Apple-shaped proof
verifies) and negative cases (the attack is rejected).
"""

from __future__ import annotations

import base64
from datetime import UTC, datetime, timedelta

import jwt as pyjwt
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID, ObjectIdentifier

from kg.app_store import AppStoreVerificationError, verify_and_decode_signed_jws

APPLE_APP_STORE_OID = "1.2.840.113635.100.6.11.1"
APPLE_INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1"
BUNDLE_ID = "com.Max0228.BooksBrowser"


def _build_certificate(
    subject_cn: str,
    *,
    issuer_cert=None,
    issuer_key=None,
    extra_extensions: list | None = None,
):
    key = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject_cn)])
    issuer = issuer_cert.subject if issuer_cert else subject
    signer_key = issuer_key or key
    now = datetime.now(tz=UTC)
    is_ca = issuer_cert is None or issuer_key is not None
    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=30))
        .add_extension(x509.BasicConstraints(ca=is_ca, path_length=None), critical=True)
    )
    for ext in extra_extensions or []:
        builder = builder.add_extension(ext, critical=False)
    cert = builder.sign(private_key=signer_key, algorithm=hashes.SHA256())
    return key, cert


def _x5c(chain) -> list[str]:
    return [
        base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode("ascii")
        for c in (chain["leaf_cert"], chain["inter_cert"], chain["root_cert"])
    ]


def _sign(payload: dict, *, chain, algorithm: str = "ES256", headers: dict | None = None) -> str:
    base_headers = {"alg": algorithm, "x5c": _x5c(chain)}
    if headers:
        base_headers.update(headers)
    key = chain["leaf_key"]
    if algorithm == "none":
        # Unsigned downgrade attack: PyJWT requires key=None for alg="none".
        key = None
    elif algorithm == "HS256":
        # alg-confusion: attacker HMACs with a symmetric secret of their choosing.
        key = "anything-the-attacker-wants"
    return pyjwt.encode(payload, key, algorithm=algorithm, headers=base_headers)


def _valid_payload(**overrides) -> dict:
    now_ms = int(datetime.now(tz=UTC).timestamp() * 1000)
    payload = {
        "bundleId": BUNDLE_ID,
        "productId": "com.wordnexus.pro.monthly",
        "transactionId": "tx-1",
        "originalTransactionId": "otx-1",
        "expiresDate": now_ms + 7 * 24 * 60 * 60 * 1000,
        # exp is the JWT-standard expiry claim (seconds). Apple sets this on the JWS.
        "exp": int(datetime.now(tz=UTC).timestamp()) + 3600,
    }
    payload.update(overrides)
    return payload


@pytest.fixture()
def root_ca(monkeypatch, tmp_path):
    """Install a trusted root and return a factory for chains rooted at it.

    All chains in a single test share one root so the chain terminates at the
    trusted root regardless of leaf OID presence.
    """
    root_key, root_cert = _build_certificate("Test Apple Root")
    root_pem = tmp_path / "root.pem"
    root_pem.write_text(root_cert.public_bytes(serialization.Encoding.PEM).decode("utf-8"))
    monkeypatch.setenv("APP_STORE_ROOT_CA_PATH", str(root_pem))
    monkeypatch.delenv("APP_STORE_ROOT_CA_PEM", raising=False)

    def make_chain(*, leaf_has_apple_oid: bool):
        inter_key, inter_cert = _build_certificate(
            "Test Apple Intermediate",
            issuer_cert=root_cert,
            issuer_key=root_key,
            extra_extensions=[x509.UnrecognizedExtension(ObjectIdentifier(APPLE_INTERMEDIATE_OID), b"\x05\x00")],
        )
        leaf_exts = []
        if leaf_has_apple_oid:
            leaf_exts.append(x509.UnrecognizedExtension(ObjectIdentifier(APPLE_APP_STORE_OID), b"\x05\x00"))
        leaf_key, leaf_cert = _build_certificate(
            "Test Apple Leaf",
            issuer_cert=inter_cert,
            issuer_key=inter_key,
            extra_extensions=leaf_exts,
        )
        return {
            "root_cert": root_cert,
            "inter_cert": inter_cert,
            "leaf_key": leaf_key,
            "leaf_cert": leaf_cert,
        }

    return make_chain


# ---------------------------------------------------------------------------
# Positive: a correctly-structured Apple-shaped proof verifies. This guards
# against false positives that would kill real subscriber entitlements.
# ---------------------------------------------------------------------------


def test_valid_apple_shaped_jws_verifies(root_ca):
    chain = root_ca(leaf_has_apple_oid=True)
    token = _sign(_valid_payload(), chain=chain)
    verified = verify_and_decode_signed_jws(token, bundle_id=BUNDLE_ID)
    assert verified.payload["bundleId"] == BUNDLE_ID
    assert verified.payload["transactionId"] == "tx-1"


def test_renewal_info_without_bundle_id_still_verifies(root_ca):
    """JWSRenewalInfoDecodedPayload legitimately has no bundleId. Absence must
    NOT be rejected — only a *mismatching* bundleId is an attack."""
    chain = root_ca(leaf_has_apple_oid=True)
    renewal = {
        "originalTransactionId": "otx-1",
        "autoRenewStatus": 0,
        "exp": int(datetime.now(tz=UTC).timestamp()) + 3600,
    }
    token = _sign(renewal, chain=chain)
    verified = verify_and_decode_signed_jws(token, bundle_id=BUNDLE_ID)
    assert verified.payload["autoRenewStatus"] == 0


# ---------------------------------------------------------------------------
# Vuln 1: alg pinned to ES256 — header alg is ignored.
# ---------------------------------------------------------------------------


def test_alg_none_downgrade_rejected(root_ca):
    chain = root_ca(leaf_has_apple_oid=True)
    token = _sign(_valid_payload(), chain=chain, algorithm="none")
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws(token, bundle_id=BUNDLE_ID)


def test_alg_hs256_confusion_rejected(root_ca):
    """Classic alg-confusion: signer treats the EC public key as an HMAC secret.
    Must be rejected because we pin ES256 and never read header alg."""
    chain = root_ca(leaf_has_apple_oid=True)
    token = _sign(_valid_payload(), chain=chain, algorithm="HS256")
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws(token, bundle_id=BUNDLE_ID)


# ---------------------------------------------------------------------------
# Vuln 2: claim verification — exp enforced, bundleId mismatch rejected.
# ---------------------------------------------------------------------------


def test_expired_jws_rejected(root_ca):
    chain = root_ca(leaf_has_apple_oid=True)
    # Past the 60s clock-skew leeway so this is unambiguously expired, not drift.
    token = _sign(
        _valid_payload(exp=int(datetime.now(tz=UTC).timestamp()) - 300),
        chain=chain,
    )
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws(token, bundle_id=BUNDLE_ID)


def test_bundle_id_mismatch_rejected(root_ca):
    chain = root_ca(leaf_has_apple_oid=True)
    token = _sign(_valid_payload(bundleId="com.evil.app"), chain=chain)
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws(token, bundle_id=BUNDLE_ID)


# ---------------------------------------------------------------------------
# Vuln 3: cert-chain OID pin — leaf must carry Apple App Store OID.
# ---------------------------------------------------------------------------


def test_leaf_without_apple_oid_rejected(root_ca):
    """A cert chained to the Apple Root but lacking the App Store OID is not a
    legitimate App Store leaf and must be rejected even though the chain is
    otherwise valid and the signature is correct."""
    chain = root_ca(leaf_has_apple_oid=False)
    token = _sign(_valid_payload(), chain=chain)
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws(token, bundle_id=BUNDLE_ID)


def test_broken_chain_rejected(root_ca):
    """A chain that does NOT terminate at the trusted root is rejected."""
    # Build a chain rooted at a *different* (untrusted) root.
    foreign_root_key, foreign_root = _build_certificate("Foreign Root")
    inter_key, inter_cert = _build_certificate(
        "Foreign Intermediate", issuer_cert=foreign_root, issuer_key=foreign_root_key
    )
    leaf_key, leaf_cert = _build_certificate(
        "Foreign Leaf",
        issuer_cert=inter_cert,
        issuer_key=inter_key,
        extra_extensions=[x509.UnrecognizedExtension(ObjectIdentifier(APPLE_APP_STORE_OID), b"\x05\x00")],
    )
    chain = {
        "root_cert": foreign_root,
        "inter_cert": inter_cert,
        "leaf_key": leaf_key,
        "leaf_cert": leaf_cert,
    }
    token = _sign(_valid_payload(), chain=chain)
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws(token, bundle_id=BUNDLE_ID)


def test_forged_inner_link_with_real_root_tail_rejected(root_ca):
    """Attacker keeps the REAL trusted root at the chain tail but forges the
    inner link: the intermediate is signed by an attacker key, not the root.

    The inner-link signature check (intermediate-signed-by-root) raises
    cryptography's ``InvalidSignature``. That is NOT a subclass of
    ``AppStoreVerificationError`` / ``ValueError``, so if the check ran outside a
    try/except it would escape the domain-error boundary and surface as HTTP 500
    instead of 400. This asserts the chain verifier collapses it to the domain
    error so the billing handler can map it to 400.
    """
    chain = root_ca(leaf_has_apple_oid=True)

    # Re-mint the intermediate cert with the SAME subject/public key but signed
    # by an attacker key. The root_cert in the chain is the genuine trusted root,
    # so the chain still *terminates* at a trusted root — only the inner link
    # (inter signed-by root) is forged.
    attacker_key = ec.generate_private_key(ec.SECP256R1())
    inter_cert = chain["inter_cert"]
    now = datetime.now(tz=UTC)
    forged_inter = (
        x509.CertificateBuilder()
        .subject_name(inter_cert.subject)
        .issuer_name(chain["root_cert"].subject)
        .public_key(inter_cert.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=30))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(private_key=attacker_key, algorithm=hashes.SHA256())
    )
    chain["inter_cert"] = forged_inter

    token = _sign(_valid_payload(), chain=chain)
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws(token, bundle_id=BUNDLE_ID)


def test_forged_leaf_signature_with_real_root_tail_rejected(root_ca):
    """Attacker signs the leaf with their own key (not the genuine intermediate's
    key) while keeping the real intermediate + real trusted root in the chain.

    Same boundary as above: the leaf->intermediate signature check raises
    ``InvalidSignature``, which must be collapsed to ``AppStoreVerificationError``
    rather than escaping as a raw cryptography exception (HTTP 500).
    """
    chain = root_ca(leaf_has_apple_oid=True)

    attacker_key = ec.generate_private_key(ec.SECP256R1())
    leaf_cert = chain["leaf_cert"]
    now = datetime.now(tz=UTC)
    forged_leaf = (
        x509.CertificateBuilder()
        .subject_name(leaf_cert.subject)
        # Keep the issuer name pointing at the real intermediate so the chain
        # structure is intact; only the signing key is wrong.
        .issuer_name(chain["inter_cert"].subject)
        .public_key(chain["leaf_key"].public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=30))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(
            x509.UnrecognizedExtension(ObjectIdentifier(APPLE_APP_STORE_OID), b"\x05\x00"),
            critical=False,
        )
        .sign(private_key=attacker_key, algorithm=hashes.SHA256())
    )
    chain["leaf_cert"] = forged_leaf

    token = _sign(_valid_payload(), chain=chain)
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws(token, bundle_id=BUNDLE_ID)


# ---------------------------------------------------------------------------
# Robustness: a small clock-skew leeway is allowed on exp so a legitimate proof
# that just barely crossed expiry due to clock drift is not killed, while a
# proof past the leeway window is still rejected.
# ---------------------------------------------------------------------------


def test_exp_within_leeway_still_verifies(root_ca):
    """A proof expired by less than the leeway window still verifies (clock-skew
    tolerance). Its signature is genuine — only the wall clock disagrees."""
    chain = root_ca(leaf_has_apple_oid=True)
    token = _sign(
        _valid_payload(exp=int(datetime.now(tz=UTC).timestamp()) - 30),
        chain=chain,
    )
    verified = verify_and_decode_signed_jws(token, bundle_id=BUNDLE_ID)
    assert verified.payload["bundleId"] == BUNDLE_ID


def test_exp_beyond_leeway_rejected(root_ca):
    """A proof expired well beyond the leeway window is still rejected."""
    chain = root_ca(leaf_has_apple_oid=True)
    token = _sign(
        _valid_payload(exp=int(datetime.now(tz=UTC).timestamp()) - 600),
        chain=chain,
    )
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws(token, bundle_id=BUNDLE_ID)


def test_malformed_header_collapses_to_verification_error():
    """Malformed JWS segments must not leak parser errors to the caller."""
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws("bm90LWpzb24.aW52YWxpZA.x")
