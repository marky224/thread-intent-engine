"""License Assignment intent handler.

Graph API: POST /users/{id}/assignLicense
Permissions: User.ReadWrite.All, Directory.ReadWrite.All

Supports both Assign and Remove actions. Checks available license count
before assignment and reports if insufficient.
"""

import logging
from typing import Any

from intents.base import BaseIntentHandler
from models.errors import GraphApiError

logger = logging.getLogger(__name__)


class LicenseAssignmentHandler(BaseIntentHandler):

    def validate(self) -> None:
        self.require_field("User Email")
        self.require_field("License SKU")

    def execute(self) -> dict[str, Any]:
        user_id, upn = self.resolve_user("User Email")
        sku_name = self.require_field("License SKU")
        action = self.optional_field("Action", "Assign").lower()

        # Resolve the SKU part number to a SKU ID
        sku_id = self._resolve_sku(sku_name)

        if action == "remove":
            return self._remove_license(user_id, upn, sku_id, sku_name)
        else:
            return self._assign_license(user_id, upn, sku_id, sku_name)

    def _resolve_sku(self, sku_name: str) -> str:
        """Resolve a license SKU part number or display name to a SKU ID."""
        resp = self.graph.get("/subscribedSkus", params={"$select": "skuId,skuPartNumber,consumedUnits,prepaidUnits"})

        if resp.status_code != 200:
            self.raise_graph_error(resp, "List subscribed SKUs")

        skus = resp.json().get("value", [])
        sku_name_lower = sku_name.lower()

        for sku in skus:
            if (
                sku.get("skuPartNumber", "").lower() == sku_name_lower
                or sku.get("skuId", "").lower() == sku_name_lower
            ):
                return sku["skuId"]

        # If exact match fails, try partial match
        for sku in skus:
            if sku_name_lower in sku.get("skuPartNumber", "").lower():
                return sku["skuId"]

        raise GraphApiError(
            message=f"License SKU not found: {sku_name}",
            intent_name=self.payload.intent_name,
            status_code=404,
            graph_error_code="ResourceNotFound",
            suggested_fix=(
                f"License '{sku_name}' was not found in the tenant. "
                f"Available SKUs can be viewed in the Microsoft 365 admin center. "
                f"Common SKU names: ENTERPRISEPACK (E3), ENTERPRISEPREMIUM (E5), "
                f"SPE_E3 (M365 E3), SPE_E5 (M365 E5), EXCHANGESTANDARD (Exchange P1)."
            ),
        )

    def _check_availability(self, sku_id: str, sku_name: str) -> None:
        """Verify there are available licenses before assignment."""
        resp = self.graph.get("/subscribedSkus", params={"$select": "skuId,consumedUnits,prepaidUnits"})
        if resp.status_code != 200:
            return  # Don't block on availability check failure

        for sku in resp.json().get("value", []):
            if sku.get("skuId") == sku_id:
                enabled = sku.get("prepaidUnits", {}).get("enabled", 0)
                consumed = sku.get("consumedUnits", 0)
                available = enabled - consumed

                if available <= 0:
                    raise GraphApiError(
                        message=f"No available licenses for {sku_name} (enabled: {enabled}, consumed: {consumed})",
                        intent_name=self.payload.intent_name,
                        status_code=400,
                        graph_error_code="License_QuotaExceeded",
                        suggested_fix=f"All {enabled} licenses of {sku_name} are in use. Purchase additional licenses.",
                    )

                logger.info("License availability for %s: %d available (%d/%d used)", sku_name, available, consumed, enabled)
                return

    def _assign_license(self, user_id: str, upn: str, sku_id: str, sku_name: str) -> dict[str, Any]:
        """Assign a license to a user."""
        self._check_availability(sku_id, sku_name)

        body = {
            "addLicenses": [{"skuId": sku_id}],
            "removeLicenses": [],
        }
        resp = self.graph.post(f"/users/{user_id}/assignLicense", body=body)

        if resp.status_code == 200:
            logger.info("Assigned license %s to %s", sku_name, upn)
            return {
                "status": "success",
                "action": "assigned",
                "user": upn,
                "license": sku_name,
                "sku_id": sku_id,
            }

        self.raise_graph_error(resp, f"Assign {sku_name} to {upn}")

    def _remove_license(self, user_id: str, upn: str, sku_id: str, sku_name: str) -> dict[str, Any]:
        """Remove a license from a user."""
        body = {
            "addLicenses": [],
            "removeLicenses": [sku_id],
        }
        resp = self.graph.post(f"/users/{user_id}/assignLicense", body=body)

        if resp.status_code == 200:
            logger.info("Removed license %s from %s", sku_name, upn)
            return {
                "status": "success",
                "action": "removed",
                "user": upn,
                "license": sku_name,
                "sku_id": sku_id,
            }

        self.raise_graph_error(resp, f"Remove {sku_name} from {upn}")
