local M = {}

-- The v1 wire protocol has no general authorization-error envelope. A denial
-- therefore produces no success response or room broadcast.
local teacher_only = {
    save_room_data = true,
    create_vote = true,
    end_vote = true,
    close_vote = true,
}

function M.check(member, command)
    if not member then return false, "membership is missing" end
    if teacher_only[command] and not member.isMaster then
        return false, "teacher role required"
    end
    return true
end

function M.can_view_vote_details(member)
    return member ~= nil and member.isMaster == true
end

return M
