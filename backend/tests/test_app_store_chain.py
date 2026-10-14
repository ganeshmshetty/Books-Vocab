"""Certificate-chain structure checks for App Store JWS verification.

Mirrors the structural rules of Apple's app-store-server-library: exactly three
certificates, CA-capable issuers, matching issuer/subject names, and Apple's
marker OIDs on the intermediate and the leaf.
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

LEAF_OID = "1.2.840.113635.100.6.11.1"
INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1"
BUNDLE_ID = "com.Max0228.BooksBrowser"


def _name(cn: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])


def _cert(
    cn: str,
    *,
    issuer_name: x509.Name | None = None,
    signer_key: ec.EllipticCurvePrivateKey | None = None,
    ca: bool,
    oids: tuple[str, ...] = (),
    key_usage: x509.KeyUsage | None = None,
):
    key = ec.generate_private_key(ec.SECP256R1())
    subject = _name(cn)
    now = datetime.now(tz=UTC)
    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer_name or subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=30))
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
    )
    if key_usage is not None:
        builder = builder.add_extension(key_usage, critical=True)
    for oid in oids:
        builder = builder.add_extension(x509.UnrecognizedExtension(ObjectIdentifier(oid), b"\x05\x00"), critical=False)
    return key, builder.sign(private_key=signer_key or key, algorithm=hashes.SHA256())


def _key_usage(*, key_cert_sign: bool) -> x509.KeyUsage:
    return x509.KeyUsage(
        digital_signature=True,
        content_commitment=False,
        key_encipherment=False,
        data_encipherment=False,
        key_agreement=False,
        key_cert_sign=key_cert_sign,
        crl_sign=False,
        encipher_only=False,
        decipher_only=False,
    )


@pytest.fixture()
def root(monkeypatch, tmp_path):
    key, cert = _cert("Chain Test Root", ca=True)
    pem = tmp_path / "root.pem"
    pem.write_text(cert.public_bytes(serialization.Encoding.PEM).decode("utf-8"))
    monkeypatch.setenv("APP_STORE_ROOT_CA_PATH", str(pem))
    monkeypatch.delenv("APP_STORE_ROOT_CA_PEM", raising=False)
    return key, cert


def _token(certs: list[x509.Certificate], leaf_key) -> str:
    x5c = [base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode("ascii") for c in certs]
    payload = {
        "bundleId": BUNDLE_ID,
        "productId": "com.wordnexus.pro.monthly",
        "transactionId": "tx-1",
        "exp": int(datetime.now(tz=UTC).timestamp()) + 3600,
    }
    return pyjwt.encode(payload, leaf_key, algorithm="ES256", headers={"alg": "ES256", "x5c": x5c})


def _build(
    root,
    *,
    intermediate_ca: bool = True,
    intermediate_oids: tuple[str, ...] = (INTERMEDIATE_OID,),
    intermediate_key_usage: x509.KeyUsage | None = None,
    leaf_issuer_cn: str | None = None,
    leaf_oids: tuple[str, ...] = (LEAF_OID,),
):
    root_key, root_cert = root
    inter_key, inter_cert = _cert(
        "Chain Test Intermediate",
        issuer_name=root_cert.subject,
        signer_key=root_key,
        ca=intermediate_ca,
        oids=intermediate_oids,
        key_usage=intermediate_key_usage,
    )
    leaf_issuer = _name(leaf_issuer_cn) if leaf_issuer_cn else inter_cert.subject
    leaf_key, leaf_cert = _cert(
        "Chain Test Leaf", issuer_name=leaf_issuer, signer_key=inter_key, ca=False, oids=leaf_oids
    )
    return leaf_key, leaf_cert, inter_cert, root_cert


def test_valid_three_certificate_chain_is_accepted(root):
    leaf_key, leaf, inter, root_cert = _build(root)
    result = verify_and_decode_signed_jws(_token([leaf, inter, root_cert], leaf_key), bundle_id=BUNDLE_ID)
    assert result.payload["transactionId"] == "tx-1"


def test_valid_chain_with_key_cert_sign_usage_is_accepted(root):
    leaf_key, leaf, inter, root_cert = _build(root, intermediate_key_usage=_key_usage(key_cert_sign=True))
    verify_and_decode_signed_jws(_token([leaf, inter, root_cert], leaf_key), bundle_id=BUNDLE_ID)


def test_non_ca_intermediate_is_rejected(root):
    leaf_key, leaf, inter, root_cert = _build(root, intermediate_ca=False)
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws(_token([leaf, inter, root_cert], leaf_key), bundle_id=BUNDLE_ID)


def test_intermediate_without_key_cert_sign_usage_is_rejected(root):
    leaf_key, leaf, inter, root_cert = _build(root, intermediate_key_usage=_key_usage(key_cert_sign=False))
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws(_token([leaf, inter, root_cert], leaf_key), bundle_id=BUNDLE_ID)


def test_intermediate_without_marker_oid_is_rejected(root):
    leaf_key, leaf, inter, root_cert = _build(root, intermediate_oids=())
    with pytest.raises(AppStoreVerificationError, match="intermediate"):
        verify_and_decode_signed_jws(_token([leaf, inter, root_cert], leaf_key), bundle_id=BUNDLE_ID)


def test_two_certificate_chain_is_rejected(root):
    leaf_key, leaf, inter, _root_cert = _build(root)
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws(_token([leaf, inter], leaf_key), bundle_id=BUNDLE_ID)


def test_four_certificate_chain_is_rejected(root):
    leaf_key, leaf, inter, root_cert = _build(root)
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws(_token([leaf, inter, inter, root_cert], leaf_key), bundle_id=BUNDLE_ID)


def test_issuer_subject_name_mismatch_is_rejected(root):
    leaf_key, leaf, inter, root_cert = _build(root, leaf_issuer_cn="Some Other Issuer")
    with pytest.raises(AppStoreVerificationError, match="issuer"):
        verify_and_decode_signed_jws(_token([leaf, inter, root_cert], leaf_key), bundle_id=BUNDLE_ID)


def test_end_entity_certificate_in_intermediate_position_is_rejected(root):
    """root -> CA(with marker) -> end-entity(CA:FALSE) -> leaf, presented as a 3-chain."""
    root_key, root_cert = root
    ca_key, ca_cert = _cert(
        "Chain Test CA", issuer_name=root_cert.subject, signer_key=root_key, ca=True, oids=(INTERMEDIATE_OID,)
    )
    ee_key, ee_cert = _cert(
        "Chain Test End Entity", issuer_name=ca_cert.subject, signer_key=ca_key, ca=False, oids=(INTERMEDIATE_OID,)
    )
    leaf_key, leaf = _cert(
        "Chain Test Leaf", issuer_name=ee_cert.subject, signer_key=ee_key, ca=False, oids=(LEAF_OID,)
    )
    with pytest.raises(AppStoreVerificationError):
        verify_and_decode_signed_jws(_token([leaf, ee_cert, ca_cert], leaf_key), bundle_id=BUNDLE_ID)
