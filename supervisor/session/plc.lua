-- #REQUIRES mqueue.lua
-- #REQUIRES comms.lua
-- #REQUIRES log.lua
-- #REQUIRES util.lua

local RPLC_TYPES = comms.RPLC_TYPES

PLC_S_COMMANDS = {
    SCRAM = 0,
    ENABLE = 1,
    ISS_CLEAR = 2
}

-- PLC supervisor session
function new_session(id, for_reactor, in_queue, out_queue)
    local log_header = "plc_session(" .. id .. "): "

    local self = {
        id = id,
        for_reactor = for_reactor,
        in_q = in_queue,
        out_q = out_queue,
        commanded_state = false,
        -- connection properties
        seq_num = 0,
        connected = true,
        received_struct = false,
        plc_conn_watchdog = util.new_watchdog(3)
        -- when to next retry one of these requests
        retry_times = {
            struct_req = 0,
            scram_req = 0,
            enable_req = 0
        },
        -- session PLC status database
        sDB = {
            control_state = false,
            overridden = false,
            degraded = false,
            iss_status = {
                dmg_crit = false,
                ex_hcool = false,
                ex_waste = false,
                high_temp = false,
                no_fuel = false,
                no_cool = false,
                timed_out = false
            },
            mek_status = {
                heating_rate = 0,

                status = false,
                burn_rate = 0,
                act_burn_rate = 0,
                temp = 0,
                damage = 0,
                boil_eff = 0,
                env_loss = 0,

                fuel = 0,
                fuel_need = 0,
                fuel_fill = 0,
                waste = 0,
                waste_need = 0,
                waste_fill = 0,
                cool_type = "?",
                cool_amnt = 0,
                cool_need = 0,
                cool_fill = 0,
                hcool_type = "?",
                hcool_amnt = 0,
                hcool_need = 0,
                hcool_fill = 0
            },
            mek_struct = {
                heat_cap = 0,
                fuel_asm = 0,
                fuel_sa = 0,
                fuel_cap = 0,
                waste_cap = 0,
                cool_cap = 0,
                hcool_cap = 0,
                max_burn = 0
            }
        }
    }

    local _copy_iss_status = function (iss_status)
        self.sDB.iss_status.dmg_crit  = iss_status[1]
        self.sDB.iss_status.ex_hcool  = iss_status[2]
        self.sDB.iss_status.ex_waste  = iss_status[3]
        self.sDB.iss_status.high_temp = iss_status[4]
        self.sDB.iss_status.no_fuel   = iss_status[5]
        self.sDB.iss_status.no_cool   = iss_status[6]
        self.sDB.iss_status.timed_out = iss_status[7]
    end

    local _copy_status = function (mek_data)
        self.sDB.mek_status.status        = mek_data[1]
        self.sDB.mek_status.burn_rate     = mek_data[2]
        self.sDB.mek_status.act_burn_rate = mek_data[3]
        self.sDB.mek_status.temp          = mek_data[4]
        self.sDB.mek_status.damage        = mek_data[5]
        self.sDB.mek_status.boil_eff      = mek_data[6]
        self.sDB.mek_status.env_loss      = mek_data[7]

        self.sDB.mek_status.fuel          = mek_data[8]
        self.sDB.mek_status.fuel_need     = mek_data[9]
        self.sDB.mek_status.fuel_fill     = mek_data[10]
        self.sDB.mek_status.waste         = mek_data[11]
        self.sDB.mek_status.waste_need    = mek_data[12]
        self.sDB.mek_status.waste_fill    = mek_data[13]
        self.sDB.mek_status.cool_type     = mek_data[14]
        self.sDB.mek_status.cool_amnt     = mek_data[15]
        self.sDB.mek_status.cool_need     = mek_data[16]
        self.sDB.mek_status.cool_fill     = mek_data[17]
        self.sDB.mek_status.hcool_type    = mek_data[18]
        self.sDB.mek_status.hcool_amnt    = mek_data[19]
        self.sDB.mek_status.hcool_need    = mek_data[20]
        self.sDB.mek_status.hcool_fill    = mek_data[21]
    end

    local _copy_struct = function (mek_data)
        self.sDB.mek_struct.heat_cap  = mek_data[1]
        self.sDB.mek_struct.fuel_asm  = mek_data[2]
        self.sDB.mek_struct.fuel_sa   = mek_data[3]
        self.sDB.mek_struct.fuel_cap  = mek_data[4]
        self.sDB.mek_struct.waste_cap = mek_data[5]
        self.sDB.mek_struct.cool_cap  = mek_data[6]
        self.sDB.mek_struct.hcool_cap = mek_data[7]
        self.sDB.mek_struct.max_burn  = mek_data[8]
    end

    local _get_ack = function (pkt)
        if pkt.length == 1 then
            return pkt.data[1]
        else
            log._warning(log_header .. "RPLC ACK length mismatch")
            return nil
        end
    end

    local get_id = function () return self.id end

    local close = function () self.connected = false end

    local check_wd = function (timer)
        return timer == plc_conn_watchdog
    end

    local get_struct = function ()
        if self.received_struct then
            return self.sDB.mek_struct
        else
            -- @todo: need a system in place to re-request this periodically
            return nil
        end
    end

    local iterate = function ()
        if self.connected and ~self.in_q.empty() then
            -- get a new message to process
            local message = self.in_q.pop()

            if message.qtype == mqueue.TYPE.PACKET then
                -- handle an incoming packet from the PLC
                rplc_pkt = message.message.get()

                if rplc_pkt.id == for_reactor then
                    if rplc_pkt.type == RPLC_TYPES.KEEP_ALIVE then
                        -- keep alive reply
                    elseif rplc_pkt.type == RPLC_TYPES.STATUS then
                        -- status packet received, update data
                        if rplc_pkt.length >= 5 then
                            -- @todo [1] is timestamp, determine how this will be used (if at all)
                            self.sDB.control_state = rplc_pkt.data[2]
                            self.sDB.overridden = rplc_pkt.data[3]
                            self.sDB.degraded = rplc_pkt.data[4]
                            self.sDB.mek_status.heating_rate = rplc_pkt.data[5]
    
                            -- attempt to read mek_data table
                            if rplc_pkt.data[6] ~= nil then
                                local status = pcall(_copy_status, rplc_pkt.data[6])
                                if status then
                                    -- copied in status data OK
                                else
                                    -- error copying status data
                                    log._error(log_header .. "failed to parse status packet data")
                                end
                            end
                        else
                            log._warning(log_header .. "RPLC status packet length mismatch")
                        end
                    elseif rplc_pkt.type == RPLC_TYPES.MEK_STRUCT then
                        -- received reactor structure, record it
                        if rplc_pkt.length == 8 then
                            local status = pcall(_copy_struct, rplc_pkt.data)
                            if status then
                                -- copied in structure data OK
                            else
                                -- error copying structure data
                                log._error(log_header .. "failed to parse struct packet data")
                            end
                        else
                            log._warning(log_header .. "RPLC struct packet length mismatch")
                        end
                    elseif rplc_pkt.type == RPLC_TYPES.MEK_SCRAM then
                        -- SCRAM acknowledgement
                        local ack = _get_ack(rplc_pkt)
                        if ack then
                            self.sDB.control_state = false
                        elseif ack == false then
                            log._warning(log_header .. "SCRAM failed!")
                        end
                    elseif rplc_pkt.type == RPLC_TYPES.MEK_ENABLE then
                        -- enable acknowledgement
                        local ack = _get_ack(rplc_pkt)
                        if ack then
                            self.sDB.control_state = true
                        elseif ack == false then
                            log._warning(log_header .. "enable failed!")
                        end
                    elseif rplc_pkt.type == RPLC_TYPES.MEK_BURN_RATE then
                        -- burn rate acknowledgement
                        if _get_ack(rplc_pkt) == false then
                            log._warning(log_header .. "burn rate update failed!")
                        end
                    elseif rplc_pkt.type == RPLC_TYPES.ISS_STATUS then
                        -- ISS status packet received, copy data
                        if rplc_pkt.length == 7 then
                            local status = pcall(_copy_iss_status, rplc_pkt.data)
                            if status then
                                -- copied in ISS status data OK
                            else
                                -- error copying ISS status data
                                log._error(log_header .. "failed to parse ISS status packet data")
                            end
                        else
                            log._warning(log_header .. "RPLC ISS status packet length mismatch")
                        end
                    elseif rplc_pkt.type == RPLC_TYPES.ISS_ALARM then
                        -- ISS alarm
                        self.sDB.overridden = true
                        -- @todo
                    elseif rplc_pkt.type == RPLC_TYPES.ISS_CLEAR then
                        -- ISS clear acknowledgement
                        -- @todo
                    else
                        log._warning(log_header .. "handler received unsupported RPLC packet type " .. rplc_pkt.type)
                    end
                else
                    log._warning(log_header .. "RPLC packet with ID not matching reactor ID: reactor " .. self.for_reactor .. " != " .. rplc_pkt.id)
                end
            elseif message.qtype == mqueue.TYPE.COMMAND then
                -- handle instruction

            end
        end

        return self.connected
    end

    return {
        get_id = get_id,
        check_wd = check_wd,
        get_struct = get_struct,
        close = close,
        iterate = iterate
    }
end