-- #REQUIRES mqueue.lua
-- #REQUIRES log.lua

-- Supervisor Sessions Handler

SESSION_TYPE = {
    RTU_SESSION = 0,
    PLC_SESSION = 1,
    COORD_SESSION = 2
}

local self = {
    num_reactors = 0,
    rtu_sessions = {},
    plc_sessions = {},
    coord_sessions = {},
    next_rtu_id = 0,
    next_plc_id = 0,
    next_coord_id = 0
}

function alloc_reactor_plcs(num_reactors)
    self.num_reactors = num_reactors
    for i = 1, num_reactors do
        table.insert(self.plc_sessions, false)
    end
end

function find_session(stype, remote_port)
    if stype == SESSION_TYPE.RTU_SESSION then
        for i = 1, #self.rtu_sessions do
            if self.rtu_sessions[i].r_host == remote_port then
                return self.rtu_sessions[i]
            end
        end
    elseif stype == SESSION_TYPE.PLC_SESSION then
        for i = 1, #self.plc_sessions do
            if self.plc_sessions[i].r_host == remote_port then
                return self.plc_sessions[i]
            end
        end
    elseif stype == SESSION_TYPE.COORD_SESSION then
        for i = 1, #self.coord_sessions do
            if self.coord_sessions[i].r_host == remote_port then
                return self.coord_sessions[i]
            end
        end
    else
        log._error("cannot search for unknown session type " .. stype, true)
    end

    return nil
end

function get_reactor_session(reactor)
    local session = nil

    for i = 1, #self.plc_sessions do
        if self.plc_sessions[i].reactor == reactor then
            session = self.plc_sessions[i]
        end
    end

    return session
end

function establish_plc_session(remote_port, for_reactor)
    if get_reactor_session(for_reactor) == nil then 
        local plc_s = {
            open = true,
            reactor = for_reactor,
            r_host = remote_port,
            in_queue = mqueue.new(),
            out_queue = mqueue.new(),
            instance = nil
        }

        plc_s.instance = plc.new_session(next_plc_id, plc_s.in_queue, plc_s.out_queue)
        table.insert(self.plc_sessions, plc_s)
        next_plc_id = next_plc_id + 1

        -- success
        return plc_s.instance.get_id()
    else
        -- reactor already assigned to a PLC
        return false
    end
end

local function _iterate(sessions)
    for i = 1, #sessions do
        local session = sessions[i]
        if session.open then
            local ok = session.instance.iterate()
            if not ok then
                session.open = false
                session.instance.close()
            end
        end
    end
end

function iterate_all()
    -- iterate RTU sessions
    _iterate(self.rtu_sessions)

    -- iterate PLC sessions
    _iterate(self.plc_sessions)

    -- iterate coordinator sessions
    _iterate(self.coord_sessions)
end

local function _free_closed(sessions)
    local move_to = 1
    for i = 1, #sessions do
        local session = sessions[i]
        if session ~= nil then
            if sessions[i].open then
                if sessions[move_to] == nil then
                    sessions[move_to] = session
                    sessions[i] = nil
                end
                move_to = move_to + 1
            else
                sessions[i] = nil
            end
        end
    end
end

function free_all_closed()
    -- free closed RTU sessions
    _free_closed(self.rtu_sessions)

    -- free closed PLC sessions
    _free_closed(self.plc_sessions)

    -- free closed coordinator sessions
    _free_closed(self.coord_sessions)
end
