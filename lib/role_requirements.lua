-- lib/role_requirements.lua
-- Shared role peripheral requirements for config editor / runtime.
-- Keep in sync with the embedded copy in installer-full.lua (installer cannot
-- require local libs before download).

local requirements = {}

requirements.ROLE_ORDER = {
    "controller",
    "matrix",
    "reactor",
    "meter",
    "generator",
    "display",
    "pocket",
}

requirements.ROLE_LABELS = {
    controller = "Controller",
    matrix     = "Matrix Node",
    reactor    = "Reactor Node",
    meter      = "Meter Node",
    generator  = "Generator Node",
    display    = "Display Node",
    pocket     = "Pocket",
}

-- bind=true marks the device peripheral that can be stored as bound_peripheral.
requirements.ROLE_REQUIREMENTS = {
    controller = {
        { types = { "ender_modem", "modem" }, label = "Ender modem", required = true },
        { types = { "monitor" }, label = "Monitor", required = true },
        { types = { "speaker" }, label = "Speaker", required = false },
    },
    matrix = {
        { types = { "ender_modem", "modem" }, label = "Ender modem", required = true },
        {
            types = { "mekanism:induction_port", "inductionPort", "mekanism.induction_port" },
            label = "Induction Port",
            required = true,
            bind = true,
        },
    },
    reactor = {
        { types = { "ender_modem", "modem" }, label = "Ender modem", required = true },
        {
            types = {
                "BigReactors-Reactor",
                "bigger_reactors:reactor_access_port",
                "bigreactors:reactor_access_port",
            },
            label = "Reactor Port",
            required = true,
            bind = true,
        },
    },
    meter = {
        { types = { "ender_modem", "modem" }, label = "Ender modem", required = true },
        {
            types = { "energymeter", "current_transformer", "ie_current_transformer" },
            label = "Energy meter / transformer",
            required = true,
            bind = true,
        },
    },
    generator = {
        { types = { "ender_modem", "modem" }, label = "Ender modem", required = true },
        {
            types = {
                "diesel_generator",
                "ie_diesel_generator",
                "capacitor_lv",
                "capacitor_mv",
                "capacitor_hv",
            },
            label = "IE diesel / capacitor",
            required = true,
            bind = true,
        },
    },
    display = {
        { types = { "ender_modem", "modem" }, label = "Ender modem", required = true },
        { types = { "monitor" }, label = "Monitor", required = true },
    },
    pocket = {
        { types = { "ender_modem", "modem" }, label = "Ender modem", required = true },
    },
}

local BIND_ROLES = {
    matrix = true,
    reactor = true,
    meter = true,
    generator = true,
}

function requirements.supportsBoundPeripheral(role)
    return BIND_ROLES[role] == true
end

function requirements.getBindRequirement(role)
    local reqs = requirements.ROLE_REQUIREMENTS[role]
    if not reqs then return nil end
    for _, req in ipairs(reqs) do
        if req.bind then return req end
    end
    return nil
end

function requirements.findMatchingNames(types)
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        local ptype = peripheral.getType(name)
        for _, wanted in ipairs(types or {}) do
            if ptype == wanted then
                found[#found + 1] = name
                break
            end
        end
    end
    return found
end

function requirements.isValidRole(role)
    return requirements.ROLE_LABELS[role] ~= nil
end

return requirements
