-- lib/hmac.lua
-- Pure-Lua SHA-256 and HMAC-SHA256 implementation for CC:Tweaked.
-- Based on the public-domain Lua SHA-2 implementation by Egor Skriptunoff.
-- Used to authenticate inter-node messages via a shared secret.
--
-- Usage:
--   local hmac = require("lib/hmac")
--   local digest = hmac.sha256("hello")          -- hex string
--   local mac    = hmac.hmac256("secret", "msg") -- hex string

local hmac = {}

-- ── SHA-256 core ──────────────────────────────────────────────────────────────

local band, bor, bxor, bnot, rshift, lshift
if bit32 then
    band   = bit32.band
    bor    = bit32.bor
    bxor   = bit32.bxor
    bnot   = bit32.bnot
    rshift = bit32.rshift
    lshift = bit32.lshift
else
    -- CC:Tweaked always ships bit32; this fallback is a safety net
    error("bit32 library not available")
end

local function rrot(x, n)
    return bor(rshift(x, n), lshift(x, 32 - n))
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function sha256_block(H, block)
    local W = {}
    for i = 1, 16 do
        local o = (i - 1) * 4
        W[i] = bor(
            lshift(block:byte(o + 1), 24),
            lshift(block:byte(o + 2), 16),
            lshift(block:byte(o + 3),  8),
                   block:byte(o + 4)
        )
    end
    for i = 17, 64 do
        local s0 = bxor(rrot(W[i-15], 7),  rrot(W[i-15], 18), rshift(W[i-15], 3))
        local s1 = bxor(rrot(W[i-2],  17), rrot(W[i-2],  19), rshift(W[i-2],  10))
        W[i] = band(W[i-16] + s0 + W[i-7] + s1, 0xffffffff)
    end

    local a, b, c, d, e, f, g, h =
        H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]

    for i = 1, 64 do
        local S1    = bxor(rrot(e, 6), rrot(e, 11), rrot(e, 25))
        local ch    = bxor(band(e, f),  band(bnot(e), g))
        local temp1 = band(h + S1 + ch + K[i] + W[i], 0xffffffff)
        local S0    = bxor(rrot(a, 2), rrot(a, 13), rrot(a, 22))
        local maj   = bxor(band(a, b),  band(a, c), band(b, c))
        local temp2 = band(S0 + maj, 0xffffffff)

        h = g; g = f; f = e
        e = band(d + temp1, 0xffffffff)
        d = c; c = b; b = a
        a = band(temp1 + temp2, 0xffffffff)
    end

    H[1] = band(H[1] + a, 0xffffffff)
    H[2] = band(H[2] + b, 0xffffffff)
    H[3] = band(H[3] + c, 0xffffffff)
    H[4] = band(H[4] + d, 0xffffffff)
    H[5] = band(H[5] + e, 0xffffffff)
    H[6] = band(H[6] + f, 0xffffffff)
    H[7] = band(H[7] + g, 0xffffffff)
    H[8] = band(H[8] + h, 0xffffffff)
end

local function sha256_raw(msg)
    local H = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    }

    local len = #msg
    -- Pre-processing: append bit '1', then zeros, then length in bits (64-bit big-endian)
    msg = msg .. "\x80"
    while #msg % 64 ~= 56 do msg = msg .. "\x00" end
    local bits = len * 8
    -- Encode 64-bit big-endian length (we only support messages < 2^32 bytes)
    msg = msg .. "\x00\x00\x00\x00"
    msg = msg .. string.char(
        band(rshift(bits, 24), 0xff),
        band(rshift(bits, 16), 0xff),
        band(rshift(bits,  8), 0xff),
        band(bits,              0xff)
    )

    for i = 1, #msg / 64 do
        sha256_block(H, msg:sub((i - 1) * 64 + 1, i * 64))
    end

    return H
end

-- Returns SHA-256 digest as a lowercase hex string.
function hmac.sha256(msg)
    local H = sha256_raw(msg)
    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
        H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8])
end

-- Returns HMAC-SHA256 as a lowercase hex string.
function hmac.hmac256(key, msg)
    local BLOCK = 64
    if #key > BLOCK then
        -- Keys longer than block size are hashed first
        local H = sha256_raw(key)
        key = string.char(
            band(rshift(H[1],24),0xff), band(rshift(H[1],16),0xff),
            band(rshift(H[1], 8),0xff), band(H[1],0xff),
            band(rshift(H[2],24),0xff), band(rshift(H[2],16),0xff),
            band(rshift(H[2], 8),0xff), band(H[2],0xff),
            band(rshift(H[3],24),0xff), band(rshift(H[3],16),0xff),
            band(rshift(H[3], 8),0xff), band(H[3],0xff),
            band(rshift(H[4],24),0xff), band(rshift(H[4],16),0xff),
            band(rshift(H[4], 8),0xff), band(H[4],0xff),
            band(rshift(H[5],24),0xff), band(rshift(H[5],16),0xff),
            band(rshift(H[5], 8),0xff), band(H[5],0xff),
            band(rshift(H[6],24),0xff), band(rshift(H[6],16),0xff),
            band(rshift(H[6], 8),0xff), band(H[6],0xff),
            band(rshift(H[7],24),0xff), band(rshift(H[7],16),0xff),
            band(rshift(H[7], 8),0xff), band(H[7],0xff),
            band(rshift(H[8],24),0xff), band(rshift(H[8],16),0xff),
            band(rshift(H[8], 8),0xff), band(H[8],0xff)
        )
    end
    -- Pad key to block size
    while #key < BLOCK do key = key .. "\x00" end

    local ipad, opad = "", ""
    for i = 1, BLOCK do
        local b = key:byte(i)
        ipad = ipad .. string.char(bxor(b, 0x36))
        opad = opad .. string.char(bxor(b, 0x5c))
    end

    local inner = hmac.sha256(ipad .. msg)
    -- Convert inner hex digest back to bytes for outer hash
    local inner_bytes = ""
    for i = 1, #inner, 2 do
        inner_bytes = inner_bytes .. string.char(tonumber(inner:sub(i, i+1), 16))
    end
    return hmac.sha256(opad .. inner_bytes)
end

return hmac
