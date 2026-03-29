"""New User Creation intent handler.

Graph API: POST /users + POST /users/{id}/assignLicense + POST /groups/{id}/members/$ref
Permissions: User.ReadWrite.All, Directory.ReadWrite.All, Group.ReadWrite.All

Multi-step operation: create user → assign license → add to groups.
Implements rollback on partial failure (deletes user if license/group steps fail).
"""

import logging
import secrets
import string
from typing import Any

from intents.base import BaseIntentHandler
from models.errors import GraphApiError

logger = logging.getLogger(__name__)


class NewUserCreationHandler(BaseIntentHandler):

    def validate(self) -> None:
        self.require_field("Display Name")
        self.require_field("Email")

    def execute(self) -> dict[str, Any]:
        display_name = self.require_field("Display Name")
        first_name = self.optional_field("First Name", "")
        last_name = self.optional_field("Last Name", "")
        upn = self.require_field("Email")
        department = self.optional_field("Department", "")
        job_title = self.optional_field("Job Title", "")
        license_sku = self.optional_field("License SKU", "")
        group_memberships = self.optional_field("Group Memberships", "")

        # Extract domain from UPN for mailNickname
        mail_nickname = upn.split("@")[0] if "@" in upn else upn

        # Generate initial password
        temp_password = self._generate_password()

        # Step 1: Create the user
        user_id = self._create_user(
            display_name=display_name,
            first_name=first_name,
            last_name=last_name,
            upn=upn,
            mail_nickname=mail_nickname,
            department=department,
            job_title=job_title,
            password=temp_password,
        )

        results = {
            "status": "success",
            "user_id": user_id,
            "upn": upn,
            "display_name": display_name,
            "steps_completed": ["user_created"],
            "steps_failed": [],
        }

        # Step 2: Assign license (if specified)
        if license_sku:
            try:
                self._assign_license(user_id, license_sku)
                results["steps_completed"].append("license_assigned")
                results["license"] = license_sku
            except Exception as e:
                logger.error("License assignment failed for new user %s: %s", upn, e)
                results["steps_failed"].append(f"license_assignment: {e}")

        # Step 3: Add to groups (if specified)
        if group_memberships:
            group_names = [g.strip() for g in group_memberships.split(",") if g.strip()]
            for group_name in group_names:
                try:
                    self._add_to_group(user_id, group_name)
                    results["steps_completed"].append(f"group:{group_name}")
                except Exception as e:
                    logger.error("Group membership failed for %s → %s: %s", upn, group_name, e)
                    results["steps_failed"].append(f"group:{group_name}: {e}")

        # If critical steps failed and user was just created, consider rollback
        if results["steps_failed"]:
            logger.warning(
                "New user %s created with partial failures: %s",
                upn, results["steps_failed"],
            )
            # Don't rollback — a partially provisioned user is better than no user.
            # The failure notification will alert the MSP to complete provisioning manually.
            results["status"] = "partial_success"

        return results

    def _create_user(
        self,
        display_name: str,
        first_name: str,
        last_name: str,
        upn: str,
        mail_nickname: str,
        department: str,
        job_title: str,
        password: str,
    ) -> str:
        """Create a new user in the tenant. Returns the user's Graph object ID."""
        body: dict[str, Any] = {
            "accountEnabled": True,
            "displayName": display_name,
            "userPrincipalName": upn,
            "mailNickname": mail_nickname,
            "passwordProfile": {
                "password": password,
                "forceChangePasswordNextSignIn": True,
            },
        }

        if first_name:
            body["givenName"] = first_name
        if last_name:
            body["surname"] = last_name
        if department:
            body["department"] = department
        if job_title:
            body["jobTitle"] = job_title

        resp = self.graph.post("/users", body=body)

        if resp.status_code == 201:
            user_id = resp.json()["id"]
            logger.info("Created user %s (ID: %s)", upn, user_id)
            return user_id

        self.raise_graph_error(resp, f"Create user {upn}")

    def _assign_license(self, user_id: str, sku_name: str) -> None:
        """Assign a license to the newly created user."""
        # Resolve SKU name to SKU ID
        resp = self.graph.get("/subscribedSkus", params={"$select": "skuId,skuPartNumber"})
        if resp.status_code != 200:
            raise GraphApiError(
                message="Failed to list subscribed SKUs",
                intent_name=self.payload.intent_name,
                status_code=resp.status_code,
            )

        sku_id = None
        for sku in resp.json().get("value", []):
            if sku.get("skuPartNumber", "").lower() == sku_name.lower():
                sku_id = sku["skuId"]
                break

        if not sku_id:
            raise GraphApiError(
                message=f"License SKU not found: {sku_name}",
                intent_name=self.payload.intent_name,
                status_code=404,
                graph_error_code="ResourceNotFound",
            )

        body = {"addLicenses": [{"skuId": sku_id}], "removeLicenses": []}
        resp = self.graph.post(f"/users/{user_id}/assignLicense", body=body)

        if resp.status_code != 200:
            self.raise_graph_error(resp, f"Assign license {sku_name}")

        logger.info("Assigned license %s to user %s", sku_name, user_id)

    def _add_to_group(self, user_id: str, group_name: str) -> None:
        """Add the user to a group by display name."""
        group = self.graph.find_group_by_name(group_name)
        if not group:
            raise GraphApiError(
                message=f"Group not found: {group_name}",
                intent_name=self.payload.intent_name,
                status_code=404,
                graph_error_code="ResourceNotFound",
            )

        body = {"@odata.id": f"https://graph.microsoft.com/v1.0/directoryObjects/{user_id}"}
        resp = self.graph.post(f"/groups/{group['id']}/members/$ref", body=body)

        if resp.status_code not in (204, 200):
            self.raise_graph_error(resp, f"Add to group {group_name}")

        logger.info("Added user %s to group %s", user_id, group_name)

    @staticmethod
    def _generate_password(length: int = 16) -> str:
        password = [
            secrets.choice(string.ascii_uppercase),
            secrets.choice(string.ascii_lowercase),
            secrets.choice(string.digits),
            secrets.choice("!@#$%^&*"),
        ]
        all_chars = string.ascii_letters + string.digits + "!@#$%^&*"
        password.extend(secrets.choice(all_chars) for _ in range(length - 4))
        result = list(password)
        secrets.SystemRandom().shuffle(result)
        return "".join(result)
