"""Verify Apple-signed subscription transactions before a server entitlement is changed.

The app sends StoreKit's JWS transaction. The server validates Apple's certificate chain, bundle, product,
environment and appAccountToken, then stores only the small set of fields needed for page access. App Store Server
Notifications V2 refresh the same entitlement on renewals, refunds and expiry.
"""
from __future__ import annotations

import os
import time
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from uuid import UUID

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier, VerificationException

ROOT = Path(__file__).resolve().parents[1]
ROOT_CERT = ROOT / "server" / "certs" / "AppleRootCA-G3.cer"
PRODUCT_IDS = {
    "com.allenjue.musicscan.pro.monthly",
    "com.allenjue.musicscan.pro.yearly",
}


def _bundle_id() -> str:
    return os.environ.get("APPLE_BUNDLE_ID", "com.allenjue.musicscan")


def _ms_time(value: int | None) -> str | None:
    if value is None:
        return None
    return datetime.fromtimestamp(value / 1000, tz=timezone.utc).isoformat()


@lru_cache(maxsize=2)
def _verifier(environment: Environment) -> SignedDataVerifier:
    if not ROOT_CERT.is_file():
        raise RuntimeError("Apple root certificate is missing")
    app_apple_id = os.environ.get("APPLE_APP_ID")
    if environment == Environment.PRODUCTION and not app_apple_id:
        raise RuntimeError("APPLE_APP_ID is required for production transaction verification")
    return SignedDataVerifier(
        [ROOT_CERT.read_bytes()],
        True,
        environment,
        _bundle_id(),
        int(app_apple_id) if environment == Environment.PRODUCTION else None,
    )


def verify_transaction(signed_transaction: str, user_id: str) -> dict:
    """Return normalized transaction fields only after Apple's JWS verification succeeds."""
    if not isinstance(signed_transaction, str) or len(signed_transaction) > 64_000:
        raise ValueError("Invalid signed transaction")
    transaction = None
    last_error: Exception | None = None
    for env in (Environment.PRODUCTION, Environment.SANDBOX):
        try:
            transaction = _verifier(env).verify_and_decode_signed_transaction(signed_transaction)
            break
        except (VerificationException, RuntimeError, ValueError) as exc:
            last_error = exc
    if transaction is None:
        raise ValueError("Apple transaction signature could not be verified") from last_error
    return _normalize_transaction(transaction, user_id)


def _normalize_transaction(transaction, user_id: str, grace_period_expires: int | None = None,
                           account_token: str | None = None) -> dict:
    if transaction.bundleId != _bundle_id():
        raise ValueError("Transaction belongs to a different app")
    if transaction.productId not in PRODUCT_IDS:
        raise ValueError("Transaction product is not a MusicScan Pro subscription")
    try:
        expected = UUID(user_id)
        account = UUID(transaction.appAccountToken or account_token or "")
    except (ValueError, TypeError, AttributeError) as exc:
        raise ValueError("Transaction is not tied to this MusicScan account") from exc
    if account != expected:
        raise ValueError("Transaction is not tied to this MusicScan account")
    if not transaction.originalTransactionId or not transaction.transactionId:
        raise ValueError("Subscription transaction identifiers are missing")
    if not transaction.purchaseDate or not transaction.signedDate:
        raise ValueError("Subscription transaction dates are missing")

    now_ms = int(time.time() * 1000)
    expiry = transaction.expiresDate
    if grace_period_expires and (expiry is None or grace_period_expires > expiry):
        expiry = grace_period_expires
    active = bool(expiry and expiry > now_ms and transaction.revocationDate is None)
    environment = getattr(transaction.environment, "value", transaction.environment)
    offer_type = getattr(transaction, "rawOfferType", None)
    return {
        "active": active,
        "product_id": transaction.productId,
        "period_start": _ms_time(transaction.purchaseDate),
        "period_end": _ms_time(expiry),
        "is_trial": offer_type == 1,
        "original_transaction_id": transaction.originalTransactionId,
        "transaction_id": transaction.transactionId,
        "environment": str(environment or "unknown"),
        "signed_at": _ms_time(transaction.signedDate),
    }


def verify_notification(signed_payload: str) -> dict:
    """Verify an App Store Server Notifications V2 envelope and its nested transaction data."""
    if not isinstance(signed_payload, str) or len(signed_payload) > 1_000_000:
        raise ValueError("Invalid notification")
    last_error: Exception | None = None
    notification = None
    for env in (Environment.PRODUCTION, Environment.SANDBOX):
        try:
            notification = _verifier(env).verify_and_decode_notification(signed_payload)
            break
        except (VerificationException, RuntimeError, ValueError) as exc:
            last_error = exc
    if notification is None:
        raise ValueError("Apple notification signature could not be verified") from last_error
    data = notification.data
    if not data:
        return {"type": notification.rawNotificationType or "unknown", "transaction": None}
    if data.bundleId != _bundle_id():
        raise ValueError("Notification belongs to a different app")
    if not data.signedTransactionInfo:
        return {"type": notification.rawNotificationType or "unknown", "transaction": None}
    env = data.environment
    if env not in (Environment.PRODUCTION, Environment.SANDBOX):
        raise ValueError("Unsupported App Store environment")
    tx = _verifier(env).verify_and_decode_signed_transaction(data.signedTransactionInfo)
    renewal = None
    if data.signedRenewalInfo:
        renewal = _verifier(env).verify_and_decode_renewal_info(data.signedRenewalInfo)
    grace = renewal.gracePeriodExpiresDate if renewal else None
    token = tx.appAccountToken or (renewal.appAccountToken if renewal else None)
    if not token:
        return {"type": notification.rawNotificationType or "unknown", "transaction": None}
    try:
        user_id = str(UUID(token))
    except ValueError as exc:
        raise ValueError("Notification account token is invalid") from exc
    normalized = _normalize_transaction(tx, user_id, grace, token)
    if notification.signedDate:
        normalized["signed_at"] = _ms_time(notification.signedDate)
    return {"type": notification.rawNotificationType or "unknown", "user_id": user_id,
            "transaction": normalized}
