"""Add User to Group intent handler.

Graph API: POST /groups/{id}/members/$ref
Permission: GroupMember.ReadWrite.All

Validates group exists and user is not already a member before adding.
"""

import logging
from typing import Any

from intents.base import BaseIntentHandler

logger = logging.getLogger(__name__)


class AddUserToGroupHandler(BaseIntentHandler):

    def validate(self) -> None:
        self.require_field("User Email")
        self.require_field("Group Name")

    def execute(self) -> dict[str, Any]:
        user_id, upn = self.resolve_user("User Email")
        group_id, group_name = self.resolve_group("Group Name")

        # Check if already a member
        if self.graph.is_member_of_group(group_id, user_id):
            logger.info("User %s is already a member of group %s — skipping", upn, group_name)
            return {
                "status": "success",
                "action": "already_member",
                "user": upn,
                "group": group_name,
                "message": f"{upn} is already a member of {group_name}",
            }

        # Add user to group
        body = {
            "@odata.id": f"https://graph.microsoft.com/v1.0/directoryObjects/{user_id}"
        }
        resp = self.graph.post(f"/groups/{group_id}/members/$ref", body=body)

        if resp.status_code == 204:
            logger.info("Added %s to group %s", upn, group_name)
            return {
                "status": "success",
                "action": "added",
                "user": upn,
                "group": group_name,
            }

        self.raise_graph_error(resp, f"Add {upn} to {group_name}")
