from types import SimpleNamespace
from uuid import uuid4

import pytest

from server import billing, usage


def transaction(user_id=None, **changes):
    values = {
        "bundleId": "com.example.musicscan",
        "productId": "com.musicscan.pro.yearly",
        "appAccountToken": user_id or str(uuid4()),
        "originalTransactionId": "original-123",
        "transactionId": "transaction-456",
        "purchaseDate": 1_800_000_000_000,
        "signedDate": 1_800_000_010_000,
        "expiresDate": 1_900_000_000_000,
        "revocationDate": None,
        "environment": "Sandbox",
        "rawOfferType": 1,
    }
    values.update(changes)
    return SimpleNamespace(**values)


def test_verified_transaction_normalizes_to_existing_entitlement_fields(monkeypatch):
    uid = str(uuid4())
    tx = billing._normalize_transaction(transaction(uid), uid)

    assert tx["active"] is True
    assert tx["product_id"] == "com.musicscan.pro.yearly"
    assert tx["is_trial"] is True
    assert tx["period_start"].startswith("2027-")
    assert tx["period_end"].startswith("2030-")


@pytest.mark.parametrize("changes", [
    {"bundleId": "other.bundle"},
    {"productId": "com.musicscan.pro.fake"},
    {"appAccountToken": str(uuid4())},
])
def test_rejects_wrong_app_product_or_user(changes):
    uid = str(uuid4())
    with pytest.raises(ValueError):
        billing._normalize_transaction(transaction(uid, **changes), uid)


def test_revoked_and_expired_transactions_are_inactive():
    uid = str(uuid4())
    assert not billing._normalize_transaction(transaction(uid, revocationDate=1), uid)["active"]
    assert not billing._normalize_transaction(transaction(uid, expiresDate=1), uid)["active"]


def test_set_entitlement_receives_verified_purchase_fields(monkeypatch):
    calls = []
    monkeypatch.setattr(usage, "enabled", lambda: True)
    monkeypatch.setattr(usage, "_rpc_raw", lambda name, args: calls.append((name, args)))
    tx = {"active": True, "product_id": "yearly", "period_start": "start", "period_end": "end",
          "is_trial": False, "signed_at": "signed"}

    assert usage.record_transaction("user-1", tx)
    assert calls == [("set_entitlement", {"p_user": "user-1", "p_active": True, "p_product": "yearly",
                                             "p_start": "start", "p_end": "end", "p_trial": False,
                                             "p_signed_at": "signed"})]


def test_transaction_signature_verifier_is_required(monkeypatch):
    uid = str(uuid4())
    tx = transaction(uid)
    class Verifier:
        def verify_and_decode_signed_transaction(self, signed):
            assert signed == "apple-signed-jws"
            return tx
    monkeypatch.setattr(billing, "_verifier", lambda _environment: Verifier())

    assert billing.verify_transaction("apple-signed-jws", uid)["active"]


def test_notifications_use_signed_transaction_and_account_token(monkeypatch):
    from appstoreserverlibrary.models.Environment import Environment
    uid = str(uuid4())
    tx = transaction(uid)
    notice = SimpleNamespace(
        data=SimpleNamespace(bundleId="com.example.musicscan", signedTransactionInfo="nested-jws",
                             signedRenewalInfo=None, environment=Environment.SANDBOX),
        rawNotificationType="DID_RENEW", signedDate=1_800_000_020_000,
    )
    class Verifier:
        def verify_and_decode_notification(self, _signed): return notice
        def verify_and_decode_signed_transaction(self, _signed): return tx
    monkeypatch.setattr(billing, "_verifier", lambda _environment: Verifier())

    verified = billing.verify_notification("apple-notification-jws")
    assert verified["user_id"] == uid
    assert verified["type"] == "DID_RENEW"
    assert verified["transaction"]["active"] is True
    assert verified["transaction"]["signed_at"].startswith("2027-")


def test_notification_account_token_can_come_from_verified_renewal_info(monkeypatch):
    from appstoreserverlibrary.models.Environment import Environment
    uid = str(uuid4())
    tx = transaction(None, appAccountToken=None)
    renewal = SimpleNamespace(gracePeriodExpiresDate=None, appAccountToken=uid)
    notice = SimpleNamespace(
        data=SimpleNamespace(bundleId="com.example.musicscan", signedTransactionInfo="nested-jws",
                             signedRenewalInfo="renewal-jws", environment=Environment.SANDBOX),
        rawNotificationType="DID_RENEW", signedDate=1_800_000_020_000,
    )
    class Verifier:
        def verify_and_decode_notification(self, _signed): return notice
        def verify_and_decode_signed_transaction(self, _signed): return tx
        def verify_and_decode_renewal_info(self, _signed): return renewal
    monkeypatch.setattr(billing, "_verifier", lambda _environment: Verifier())

    verified = billing.verify_notification("apple-notification-jws")
    assert verified["user_id"] == uid
