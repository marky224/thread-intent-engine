"""Remove User from Group intent handler.

Graph API: DELETE /groups/{id}/members/{userId}/$ref
Permission: GroupMember.ReadWrite.All

Validates membership exists before attempting removal.
"""

import logging
from typing import Any

from intents.base import BaseIntentHandler
from models.errors import GraphApiError

logger = logging.getLogger(__name__)


class RemoveUserFromGroupHandler(BaseIntentHandler):

    def validate(self) -> None:
        self.require_field("User Email")
        self.require_field("Group Name")

    def execute(self) -> dict[str, Any]:
        user_id, upn = self.resolve_user("User Email")
        group_id, group_name = self.resolve_group("Group Name")

        # Verify user is actually a member
        if not self.graph.is_member_of_group(group_id, user_id):
            logger.info("User %s is not a member of group %s — nothing to remove", upn, group_name)
            return {
                "status": "success",
                "action": "not_a_member",
                "user": upn,
                "group": group_name,
                "message": f"{upn} is not a member of {group_name}",
            }

        # Remove user from group
        resp = self.graph.delete(f"/groups/{group_id}/members/{user_id}/$ref")

        if resp.status_code == 204:
            logger.info("Removed %s from group %s", upn, group_name)
            return {
                "status": "success",
                "action": "removed",
                "user": upn,
                "group": group_name,
            }

        self.raise_graph_error(resp, f"Remove {upn} from {group_name}")
