-- FS25 Auto Bale by FS Modding
-- Adds an "Auto Bale" button to the farmland menu of the map (under "Tag Place").
-- The mod looks for straw lying on the field, turns it into bales (litres of straw / litres per bale)
-- and puts the bales in stacks (blocks of 4x4x4 or 6x6x6). Before the bales are made, you click on the map where
-- they should be delivered: the stacks are put there (a free, level place near the point). Without a point
-- (console autoBale) they lie at the edge of the field. The straw on the field is removed completely.
-- The job costs 100 per straw row, plus 200 for the delivery to the chosen point.

AutoBale = {}
AutoBale.modName = g_currentModName

AutoBale.useRoundBales = false     -- console: autoBaleType square|round
AutoBale.pricePerRow = 100         -- money per straw row (console: autoBalePrice)
AutoBale.wrapGrass = true          -- console: autoBaleGrass silage|grass (grass windrows become wrapped silage bales or plain grass bales)
AutoBale.stackSize = 4             -- console: autoBaleStack 0|4|6 (0 = single bales in a row, only square bales are stacked)

AutoBale.TOP_SIZE = 32             -- first search blocks in metres, split in four until LEAF_SIZE
AutoBale.LEAF_SIZE = 1
AutoBale.BBOX_MARGIN = 8           -- search a little outside the field outline
AutoBale.MAX_QUERIES = 250000      -- safety limit for density map queries per scan
AutoBale.CLEAN_PASSES = 4          -- how often the field is checked and cleaned again after the first removal
AutoBale.MIN_PARTIAL = 0.05        -- a rest of at least 5% of a bale becomes one smaller bale
AutoBale.MAX_BALES = 400
AutoBale.GAP = 0.25                -- space between two bales in metres
AutoBale.EDGE_INSET = 1.5          -- distance between the bale and the field outline in metres
AutoBale.CORNER_MARGIN = 3         -- keep the corners of the field free
AutoBale.ROWS_PER_EDGE = 3         -- bale rows (or blocks) next to each other on one edge
AutoBale.STACK_GAP = 0.08          -- space between two bales of one block in metres
AutoBale.LAYER_GAP = 0.04          -- space between two layers of one block in metres
AutoBale.BLOCK_GAP = 1.0           -- space between two blocks in metres
AutoBale.STACK_DROP = 0.1          -- bales of a block are created this high above the ground and settle
AutoBale.SEARCH_STEP = 1.0         -- step in metres when a place along the edge is not usable
AutoBale.ROW_LINK = 2              -- straw blocks of 2 m that are this close belong to the same straw row
AutoBale.GHOST_MARGIN = 1          -- cells (1 m) around the straw that are cleared too: the visual rest of a windrow
AutoBale.CLEAN_BLOCK = 4           -- block size in metres for the console command autoBaleClean

AutoBale.deliveryFee = 200          -- money for the delivery to a point chosen on the map (console: autoBaleFee)
AutoBale.askPoint = true            -- the button asks for the delivery point on the map (console: autoBalePick)
AutoBale.POINT_ROW_LENGTH = 36      -- stacks at a chosen point: a row of blocks gets this long at most (metres)
AutoBale.POINT_SEARCH_STEP = 6      -- the place is searched in rings around the point, ring after ring (metres)
AutoBale.POINT_SEARCH_MAX = 48      -- furthest distance from the chosen point (metres)
AutoBale.POINT_MAX_SLOPE = 1.0      -- the ground under a row of blocks may differ this much in height (metres)

-- what lies on the ground is detected automatically: straw, dry grass (hay) and fresh grass
-- (silage or grass bales). Hay can only become hay bales, fresh grass that dried turns into hay by itself.
AutoBale.KINDS = { "straw", "hay", "grass" }
function AutoBale.getKindFillType(kind)
    if kind == "straw" then
        return FillType.STRAW
    elseif kind == "hay" then
        return FillType.DRYGRASS_WINDROW
    elseif kind == "grass" then
        return FillType.GRASS_WINDROW
    end
    return nil
end

AutoBale.STATUS = {
    OK = 1,
    NO_STRAW = 2,
    NOT_OWNER = 3,
    NO_FIELD = 4,
    NO_BALE = 5,
    TOO_LITTLE = 6,
    NO_SPACE = 7,
    BAD_FARMLAND = 8,
    NO_MONEY = 9,
}

local function getText(key)
    return g_i18n:getText(key, AutoBale.modName)
end

local function logInfo(text)
    print("[AutoBale] " .. text)
end

local function logWarning(text)
    if Logging ~= nil and Logging.warning ~= nil then
        Logging.warning("[AutoBale] " .. text)
    else
        print("[AutoBale] " .. text)
    end
end

local function noOwnerFarmId()
    if FarmlandManager ~= nil and FarmlandManager.NO_OWNER_FARM_ID ~= nil then
        return FarmlandManager.NO_OWNER_FARM_ID
    end
    return 0
end

function AutoBale.notify(text)
    if g_dedicatedServer ~= nil then
        return
    end
    local mission = g_currentMission
    if mission ~= nil and mission.addIngameNotification ~= nil then
        mission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, text)
    end
end

-- ---------------------------------------------------------------------------
-- Geometry helpers
-- ---------------------------------------------------------------------------

local function pointInPolygon(x, z, pts)
    local inside = false
    local j = #pts
    for i = 1, #pts do
        local xi, zi, xj, zj = pts[i].x, pts[i].z, pts[j].x, pts[j].z
        if ((zi > z) ~= (zj > z)) and (x < (xj - xi) * (z - zi) / (zj - zi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

function AutoBale.getFarmlandField(farmland)
    if farmland == nil then
        return nil
    end
    if farmland.field ~= nil then
        return farmland.field
    end
    if g_fieldManager ~= nil and g_fieldManager.farmlandIdFieldMapping ~= nil then
        return g_fieldManager.farmlandIdFieldMapping[farmland.id]
    end
    return nil
end

function AutoBale.getFieldPolygon(field)
    local pts = {}
    if field == nil or field.polygonPoints == nil then
        return pts
    end
    for _, node in ipairs(field.polygonPoints) do
        local x, _, z = getWorldTranslation(node)
        pts[#pts + 1] = { x = x, z = z }
    end
    return pts
end

-- ---------------------------------------------------------------------------
-- Price: money per straw row
-- ---------------------------------------------------------------------------

local function formatMoney(value)
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        return g_i18n:formatMoney(value, 0, true, true)
    end
    return tostring(value)
end

local function getBalance(farmId)
    local farm = g_farmManager ~= nil and g_farmManager:getFarmById(farmId) or nil
    if farm == nil then
        return nil
    end
    if farm.getBalance ~= nil then
        return farm:getBalance()
    end
    return farm.money
end

function AutoBale.canPay(farmId, cost)
    if cost <= 0 then
        return true
    end
    local balance = getBalance(farmId)
    return balance == nil or balance >= cost
end

function AutoBale.charge(farmId, cost)
    if cost > 0 then
        local moneyType = MoneyType ~= nil and (MoneyType.AI or MoneyType.OTHER) or nil
        g_currentMission:addMoney(-cost, farmId, moneyType, true, true)
    end
end

-- A straw row is a line of straw that hangs together: cells of straw that are not further apart
-- than about 3 to 5 m (ROW_LINK blocks of 2 m) belong to the same row. Two windrows next to each other (work width) are two rows.
function AutoBale.countRows(cells)
    local parent, index = {}, {}
    local list = {}
    for _, c in ipairs(cells) do
        local gx, gz = math.floor(c.x0 / 2), math.floor(c.z0 / 2)
        local key = gx .. ":" .. gz
        if index[key] == nil then
            list[#list + 1] = { gx = gx, gz = gz }
            index[key] = #list
            parent[#list] = #list
        end
    end

    local function find(a)
        while parent[a] ~= a do
            parent[a] = parent[parent[a]]
            a = parent[a]
        end
        return a
    end

    for i, c in ipairs(list) do
        for dx = 0, AutoBale.ROW_LINK do
            for dz = -AutoBale.ROW_LINK, AutoBale.ROW_LINK do
                if dx > 0 or dz > 0 then
                    local j = index[(c.gx + dx) .. ":" .. (c.gz + dz)]
                    if j ~= nil then
                        local ra, rb = find(i), find(j)
                        if ra ~= rb then
                            parent[ra] = rb
                        end
                    end
                end
            end
        end
    end

    local roots, count = {}, 0
    for i = 1, #list do
        local r = find(i)
        if not roots[r] then
            roots[r] = true
            count = count + 1
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Straw scan (density map)
-- ---------------------------------------------------------------------------

-- Splits the area around the field into blocks. Empty blocks are dropped with one query,
-- blocks with straw are split down to small cells, so the scan stays fast.
function AutoBale.scan(farmlandId, pts, fillTypeIndex)
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(pts) do
        minX = math.min(minX, p.x)
        maxX = math.max(maxX, p.x)
        minZ = math.min(minZ, p.z)
        maxZ = math.max(maxZ, p.z)
    end
    minX, maxX = minX - AutoBale.BBOX_MARGIN, maxX + AutoBale.BBOX_MARGIN
    minZ, maxZ = minZ - AutoBale.BBOX_MARGIN, maxZ + AutoBale.BBOX_MARGIN

    local cells, total, queries = {}, 0, 0
    local leaf = AutoBale.LEAF_SIZE

    local function block(x0, z0, size)
        if queries >= AutoBale.MAX_QUERIES then
            return
        end
        queries = queries + 1
        local liters = DensityMapHeightUtil.getFillLevelAtArea(fillTypeIndex, x0, z0, x0 + size, z0, x0, z0 + size)
        if liters == nil or liters <= 0 then
            return
        end
        if size <= leaf then
            local id = g_farmlandManager:getFarmlandIdAtWorldPosition(x0 + size * 0.5, z0 + size * 0.5)
            if id == farmlandId then
                cells[#cells + 1] = { x0 = x0, z0 = z0, size = size, liters = liters }
                total = total + liters
            end
            return
        end
        local h = size * 0.5
        block(x0, z0, h)
        block(x0 + h, z0, h)
        block(x0, z0 + h, h)
        block(x0 + h, z0 + h, h)
    end

    local top = AutoBale.TOP_SIZE
    local x = math.floor(minX / top) * top
    while x < maxX do
        local z = math.floor(minZ / top) * top
        while z < maxZ do
            block(x, z, top)
            z = z + top
        end
        x = x + top
    end

    return cells, total, queries
end

function AutoBale.removeCells(cells, fillTypeIndex)
    for _, c in ipairs(cells) do
        DensityMapHeightUtil.removeFromGroundByArea(c.x0, c.z0, c.x0 + c.size, c.z0, c.x0, c.z0 + c.size, fillTypeIndex)
    end
end

-- true when another material than `fillTypeIndex` lies on the ground at this place
-- (the clean up then leaves the place alone)
function AutoBale.hasOtherFill(x, z, fillTypeIndex)
    local util = DensityMapHeightUtil
    if util == nil or util.getHeightTypeDescAtWorldPos == nil then
        return false
    end
    local ok, desc = pcall(function()
        local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
        return util.getHeightTypeDescAtWorldPos(x, y, z, 0.4)
    end)
    if not ok or type(desc) ~= "table" then
        return false
    end
    local ft = desc.fillTypeIndex
    return ft ~= nil and ft ~= FillType.UNKNOWN and ft ~= fillTypeIndex
end

local function clearBlock(x0, z0, size)
    DensityMapHeightUtil.clearArea(x0, z0, x0 + size, z0, x0, z0 + size)
end

-- The windrow leaves a visual trace in the height map even when no straw is counted any more
-- (the baler and the scan do not see it, but it is there). The cells that held straw and the ring
-- around them are cleared with the area clearing of the game, as it is done under new buildings.
-- Places with another material on the ground and places of other farmlands are not touched.
function AutoBale.clearGhosts(farmlandId, cells, fillTypeIndex)
    local margin = AutoBale.GHOST_MARGIN
    local seen, list = {}, {}
    for _, c in ipairs(cells) do
        for dx = -margin, margin do
            for dz = -margin, margin do
                local x0, z0 = c.x0 + dx * c.size, c.z0 + dz * c.size
                local key = x0 .. ":" .. z0
                if not seen[key] then
                    seen[key] = true
                    list[#list + 1] = { x0 = x0, z0 = z0, size = c.size }
                end
            end
        end
    end

    local cleared = 0
    for _, c in ipairs(list) do
        local cx, cz = c.x0 + c.size * 0.5, c.z0 + c.size * 0.5
        if g_farmlandManager:getFarmlandIdAtWorldPosition(cx, cz) == farmlandId and not AutoBale.hasOtherFill(cx, cz, fillTypeIndex) then
            clearBlock(c.x0, c.z0, c.size)
            cleared = cleared + 1
        end
    end
    return cleared
end

-- Removes the straw, looks again and removes what is still there (until the field is clean),
-- then erases the visual rest of the windrows.
-- Returns the litres that could not be removed (0 when the field is clean).
function AutoBale.clearStraw(farmlandId, pts, fillTypeIndex, cells)
    local all = {}
    for _, c in ipairs(cells) do
        all[#all + 1] = c
    end

    AutoBale.removeCells(cells, fillTypeIndex)
    local left = nil
    for _ = 1, AutoBale.CLEAN_PASSES do
        local rest, total = AutoBale.scan(farmlandId, pts, fillTypeIndex)
        if total <= 0 then
            left = 0
            break
        end
        for _, c in ipairs(rest) do
            all[#all + 1] = c
        end
        AutoBale.removeCells(rest, fillTypeIndex)
    end
    if left == nil then
        local _, total = AutoBale.scan(farmlandId, pts, fillTypeIndex)
        left = total
        if left > 0 then
            logWarning(string.format("%d L of straw could not be removed from farmland %d", math.floor(left), farmlandId))
        end
    end

    AutoBale.clearGhosts(farmlandId, all, fillTypeIndex)
    return left
end

-- Console autoBaleClean: erases the loose material on the whole field of a farmland (also the
-- visual rests of straw windrows that were removed earlier). Blocks with another material are skipped.
function AutoBale.cleanField(farmlandId, farmId)
    local farmland = g_farmlandManager:getFarmlandById(farmlandId)
    if farmland == nil then
        return nil, "Unknown farmland"
    end
    if farmId == nil or farmId == noOwnerFarmId() or g_farmlandManager:getFarmlandOwner(farmlandId) ~= farmId then
        return nil, "Auto Bale only works on your own land"
    end
    local pts = AutoBale.getFieldPolygon(AutoBale.getFarmlandField(farmland))
    if #pts < 3 then
        return nil, "Farmland " .. tostring(farmlandId) .. " has no field"
    end

    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(pts) do
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minZ, maxZ = math.min(minZ, p.z), math.max(maxZ, p.z)
    end
    local size = AutoBale.CLEAN_BLOCK
    local cleared, skipped = 0, 0
    local x = math.floor((minX - AutoBale.BBOX_MARGIN) / size) * size
    while x < maxX + AutoBale.BBOX_MARGIN do
        local z = math.floor((minZ - AutoBale.BBOX_MARGIN) / size) * size
        while z < maxZ + AutoBale.BBOX_MARGIN do
            local cx, cz = x + size * 0.5, z + size * 0.5
            if g_farmlandManager:getFarmlandIdAtWorldPosition(cx, cz) == farmlandId then
                if AutoBale.hasOtherFill(cx, cz, FillType.STRAW) then
                    skipped = skipped + 1
                else
                    clearBlock(x, z, size)
                    cleared = cleared + 1
                end
            end
            z = z + size
        end
        x = x + size
    end
    return cleared, skipped
end

-- ---------------------------------------------------------------------------
-- Bale type
-- ---------------------------------------------------------------------------

-- the biggest straw bale of the wanted shape (base game bales first)
function AutoBale.findBale(round, fillTypeIndex)
    if g_baleManager == nil or g_baleManager.bales == nil then
        return nil
    end
    local best = nil
    for index, bale in ipairs(g_baleManager.bales) do
        if bale.isAvailable and (bale.isRoundbale == true) == round then
            local capacity = g_baleManager:getBaleCapacityByBaleIndex(index, fillTypeIndex)
            if capacity > 0 then
                local isBase = bale.customEnvironment == nil
                local better = best == nil
                    or (isBase and not best.isBase)
                    or (isBase == best.isBase and capacity > best.capacity)
                if better then
                    best = {
                        index = index,
                        xmlFilename = bale.xmlFilename,
                        capacity = capacity,
                        isBase = isBase,
                        round = round,
                        width = bale.width or 1.2,
                        height = bale.height or 0.9,
                        length = bale.length or 2.4,
                        diameter = bale.diameter or 1.8,
                    }
                end
            end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Places at the field edge
-- ---------------------------------------------------------------------------

-- Stack sizes that are tried one after the other when the wanted one does not fit at the field edge
function AutoBale.stackLadder(size)
    local ladder = {}
    for _, s in ipairs({ 6, 4, 3, 2 }) do
        if s <= size then
            ladder[#ladder + 1] = s
        end
    end
    ladder[#ladder + 1] = 1
    return ladder
end

-- 0 / 4 / 6 from the console or the network, everything else becomes 4
function AutoBale.normalizeStack(value)
    value = tonumber(value)
    if value == 0 or value == 4 or value == 6 then
        return value
    end
    return 4
end

-- The bales are put into blocks of size x size x size (a rest forms a smaller last block, filled
-- layer by layer, so every bale lies on another bale or on the ground).
function AutoBale.planBlocks(count, size)
    local blocks = {}
    local perBlock = size * size * size
    local left = count
    while left > 0 do
        local n = math.min(left, perBlock)
        local cols = math.min(size, n)
        local rows = math.min(size, math.ceil(n / cols))
        blocks[#blocks + 1] = { count = n, cols = cols, rows = rows }
        left = left - n
    end
    return blocks
end

local function rectsOverlap(a, b)
    local axes = { { a.ux, a.uz }, { a.nx, a.nz }, { b.ux, b.uz }, { b.nx, b.nz } }
    local dx, dz = b.cx - a.cx, b.cz - a.cz
    for _, ax in ipairs(axes) do
        local ex, ez = ax[1], ax[2]
        local ra = a.hu * math.abs(a.ux * ex + a.uz * ez) + a.hn * math.abs(a.nx * ex + a.nz * ez)
        local rb = b.hu * math.abs(b.ux * ex + b.uz * ez) + b.hn * math.abs(b.nx * ex + b.nz * ez)
        if math.abs(dx * ex + dz * ez) >= ra + rb - 1e-6 then      -- touching is fine
            return false
        end
    end
    return true
end

-- Places for the blocks along the field outline, longest edge first. Every edge gets up to
-- ROWS_PER_EDGE rows of blocks (the next row lies further inside the field) before the next edge
-- is used. Returns one placement per block or nil when not all blocks fit.
-- A placement is the corner of the block (ox, oz), the direction along the edge (ux, uz), the
-- direction into the field (nx, nz) and the size of the block in bales (cols along the edge, rows across).
function AutoBale.getSlots(pts, farmlandId, blocks, pitchL, pitchW, gap)
    local n = #pts
    local corner = AutoBale.CORNER_MARGIN
    local fullDepth, minLen = 0, math.huge
    for _, b in ipairs(blocks) do
        b.len = b.cols * pitchL
        b.depth = b.rows * pitchW
        fullDepth = math.max(fullDepth, b.depth)
        minLen = math.min(minLen, b.len)
    end

    local edges = {}
    for i = 1, n do
        local a, c = pts[i], pts[i % n + 1]
        local dx, dz = c.x - a.x, c.z - a.z
        local len = math.sqrt(dx * dx + dz * dz)
        if len >= minLen + 2 * corner then
            local ux, uz = dx / len, dz / len
            local nx, nz = -uz, ux
            local mx, mz = a.x + dx * 0.5, a.z + dz * 0.5
            if not pointInPolygon(mx + nx * (AutoBale.EDGE_INSET + 0.5), mz + nz * (AutoBale.EDGE_INSET + 0.5), pts) then
                nx, nz = -nx, -nz
            end
            edges[#edges + 1] = { ax = a.x, az = a.z, ux = ux, uz = uz, nx = nx, nz = nz, len = len }
        end
    end
    table.sort(edges, function(p, q) return p.len > q.len end)

    local placed, rects = {}, {}
    local total = #blocks
    local nextBlock = 1

    local function usable(e, t0, off0, b)
        local rect = {
            ux = e.ux, uz = e.uz, nx = e.nx, nz = e.nz,
            hu = b.len * 0.5, hn = b.depth * 0.5,
            cx = e.ax + e.ux * (t0 + b.len * 0.5) + e.nx * (off0 + b.depth * 0.5),
            cz = e.az + e.uz * (t0 + b.len * 0.5) + e.nz * (off0 + b.depth * 0.5),
        }
        for _, other in ipairs(rects) do
            if rectsOverlap(rect, other) then
                return nil
            end
        end
        -- corners, middle of the sides and middle of the block must lie on the field
        for _, fu in ipairs({ 0, 0.5, 1 }) do
            for _, fn in ipairs({ 0, 0.5, 1 }) do
                local x = e.ax + e.ux * (t0 + b.len * fu) + e.nx * (off0 + b.depth * fn)
                local z = e.az + e.uz * (t0 + b.len * fu) + e.nz * (off0 + b.depth * fn)
                if not pointInPolygon(x, z, pts) or g_farmlandManager:getFarmlandIdAtWorldPosition(x, z) ~= farmlandId then
                    return nil
                end
            end
        end
        return rect
    end

    for _, e in ipairs(edges) do
        for row = 0, AutoBale.ROWS_PER_EDGE - 1 do
            local off0 = AutoBale.EDGE_INSET + row * (fullDepth + gap)
            local t = corner
            while nextBlock <= total do
                local b = blocks[nextBlock]
                if t + b.len > e.len - corner + 1e-6 then
                    break
                end
                local rect = usable(e, t, off0, b)
                if rect ~= nil then
                    rects[#rects + 1] = rect
                    placed[nextBlock] = {
                        ox = e.ax + e.ux * t + e.nx * off0,
                        oz = e.az + e.uz * t + e.nz * off0,
                        ux = e.ux, uz = e.uz, nx = e.nx, nz = e.nz,
                        cols = b.cols, rows = b.rows, count = b.count,
                    }
                    nextBlock = nextBlock + 1
                    t = t + b.len + gap
                else
                    t = t + AutoBale.SEARCH_STEP
                end
            end
            if nextBlock > total then
                return placed
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Places at a point chosen on the map
-- ---------------------------------------------------------------------------

local function collisionFlag(name)
    if CollisionFlag ~= nil and CollisionFlag[name] ~= nil then
        return CollisionFlag[name]
    end
    return 0
end

-- called by overlapBox for everything that stands in the box (vehicles, bales, trees, buildings, the player)
function AutoBale:spaceCallback(nodeId)
    if AutoBale.space ~= nil and nodeId ~= nil and nodeId ~= 0 then
        AutoBale.space.blocked = true
    end
end

function AutoBale.isOnMap(x, z)
    local mission = g_currentMission
    local half = mission ~= nil and mission.terrainSize ~= nil and mission.terrainSize * 0.5 or math.huge
    return x == x and z == z and math.abs(x) < half - 4 and math.abs(z) < half - 4
end

-- is the box (centre cx / cz, half sizes halfX / halfZ along the axes) level, dry and empty?
-- light = only vehicles, bales, trees and the player count (not buildings and other scenery)
function AutoBale.isPlaceFree(cx, cz, halfX, halfZ, height, light)
    if not AutoBale.isOnMap(cx - halfX, cz - halfZ) or not AutoBale.isOnMap(cx + halfX, cz + halfZ) then
        return false
    end
    local lo, hi = math.huge, -math.huge
    for _, fx in ipairs({ -1, -0.5, 0, 0.5, 1 }) do
        for _, fz in ipairs({ -1, 0, 1 }) do
            local h = getTerrainHeightAtWorldPos(g_terrainNode, cx + halfX * fx, 0, cz + halfZ * fz)
            lo, hi = math.min(lo, h), math.max(hi, h)
        end
    end
    if hi - lo > AutoBale.POINT_MAX_SLOPE then
        return false
    end
    local waterY = g_currentMission ~= nil and g_currentMission.waterY or nil
    if waterY ~= nil and lo < waterY + 0.05 then
        return false
    end
    local halfHeight = math.max(1.8, height * 0.5 + 0.4)
    local mask = collisionFlag("VEHICLE") + collisionFlag("DYNAMIC_OBJECT") + collisionFlag("TREE") + collisionFlag("PLAYER")
    if not light then
        mask = mask + collisionFlag("STATIC_OBJECT") + collisionFlag("BUILDING")
    end
    AutoBale.space = { blocked = false }
    overlapBox(cx, hi + halfHeight + 0.3, cz, 0, 0, 0, halfX, halfHeight, halfZ, "spaceCallback", AutoBale, mask, true, true, true, false)
    local free = not AutoBale.space.blocked
    AutoBale.space = nil
    return free
end

-- Places for the blocks around the point (px, pz): rows of blocks side by side (north / east axes), the whole
-- group centred on the point. When the place is not free, the group is moved ring after ring away from the point.
-- Returns the same placements as getSlots (or nil when no place was found within POINT_SEARCH_MAX).
function AutoBale.getSlotsAt(px, pz, blocks, pitchL, pitchW, gap, height, light)
    for _, b in ipairs(blocks) do
        b.len = b.cols * pitchL
        b.depth = b.rows * pitchW
    end

    local rows, cur = {}, nil
    for i, b in ipairs(blocks) do
        if cur == nil or (cur.width > 0 and cur.width + gap + b.len > AutoBale.POINT_ROW_LENGTH) then
            cur = { first = i, last = i, width = 0, depth = 0 }
            rows[#rows + 1] = cur
        end
        cur.width = cur.width + (cur.width > 0 and gap or 0) + b.len
        cur.depth = math.max(cur.depth, b.depth)
        cur.last = i
    end
    local width, depth = 0, 0
    for r, row in ipairs(rows) do
        width = math.max(width, row.width)
        depth = depth + row.depth + (r > 1 and gap or 0)
    end

    local shifts = { { 0, 0 } }
    local step = AutoBale.POINT_SEARCH_STEP
    for radius = step, AutoBale.POINT_SEARCH_MAX, step do
        local count = math.max(8, math.floor(2 * math.pi * radius / step))
        for k = 0, count - 1 do
            local a = 2 * math.pi * k / count
            shifts[#shifts + 1] = { math.cos(a) * radius, math.sin(a) * radius }
        end
    end

    for _, shift in ipairs(shifts) do
        local x0 = px + shift[1] - width * 0.5
        local z0 = pz + shift[2] - depth * 0.5
        local placed, ok = {}, true
        local zRow = z0
        for _, row in ipairs(rows) do
            local xRow = x0 + (width - row.width) * 0.5
            if not AutoBale.isPlaceFree(xRow + row.width * 0.5, zRow + row.depth * 0.5, row.width * 0.5, row.depth * 0.5, height, light) then
                ok = false
                break
            end
            local x = xRow
            for i = row.first, row.last do
                local b = blocks[i]
                placed[i] = { ox = x, oz = zRow, ux = 1, uz = 0, nx = 0, nz = 1, cols = b.cols, rows = b.rows, count = b.count }
                x = x + b.len + gap
            end
            zRow = zRow + row.depth + gap
        end
        if ok then
            placed.distance = math.sqrt(shift[1] * shift[1] + shift[2] * shift[2])
            return placed
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Creating bales (server)
-- ---------------------------------------------------------------------------

local function getYRotation(ux, uz)
    if MathUtil ~= nil and MathUtil.getYRotationFromDirection ~= nil then
        return MathUtil.getYRotationFromDirection(ux, uz)
    end
    return math.atan2(ux, uz)
end

-- highest ground under the bale (centre and the four corners of its footprint)
local function getGroundHeight(x, z, ux, uz, nx, nz, halfLength, halfWidth)
    local h = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    for _, sl in ipairs({ -1, 1 }) do
        for _, sw in ipairs({ -1, 1 }) do
            local px = x + ux * halfLength * sl + nx * halfWidth * sw
            local pz = z + uz * halfLength * sl + nz * halfWidth * sw
            h = math.max(h, getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz))
        end
    end
    return h
end

function AutoBale.spawnBale(info, fillTypeIndex, fillLevel, x, y, z, ry, farmId, wrap)
    local mission = g_currentMission
    local baleObject = Bale.new(mission:getIsServer(), mission:getIsClient())
    if baleObject:loadFromConfigXML(info.xmlFilename, x, y, z, 0, ry, 0) then
        baleObject:setFillType(fillTypeIndex)
        baleObject:setFillLevel(fillLevel)
        baleObject:setOwnerFarmId(farmId, true)
        baleObject:register()
        if wrap and baleObject.setWrappingState ~= nil then
            -- wrapped grass bales ferment to silage in the game
            local ok = pcall(function()
                baleObject:setWrappingState(1)
            end)
            if not ok then
                logWarning("could not wrap a grass bale")
            end
        end
        return true
    end
    return false
end

-- Creates the bales of all blocks. The bale with the index `lastIndex` gets `lastLevel`, the others `level`.
-- Returns how many bales were created and how many of them were the last (smaller) one.
function AutoBale.spawnBlocks(info, seq, placements, pitchL, pitchW, size, farmId)
    local height = info.round and info.diameter or info.height
    local halfLength = (info.round and info.diameter or info.length) * 0.5
    local halfWidth = info.width * 0.5
    local drop = size == 1 and 0.35 or AutoBale.STACK_DROP
    local created, partialCreated, index = 0, 0, 0
    local made = {}

    for _, block in ipairs(placements) do
        local perLayer = block.cols * block.rows
        local ry = getYRotation(block.ux, block.uz)
        for j = 0, block.count - 1 do
            index = index + 1
            local spec = seq[index]
            if spec ~= nil then
                local layer = math.floor(j / perLayer)
                local rest = j % perLayer
                local row = math.floor(rest / block.cols)
                local col = rest % block.cols
                local t = (col + 0.5) * pitchL
                local off = (row + 0.5) * pitchW
                local x = block.ox + block.ux * t + block.nx * off
                local z = block.oz + block.uz * t + block.nz * off
                local ground = getGroundHeight(x, z, block.ux, block.uz, block.nx, block.nz, halfLength, halfWidth)
                local y = ground + drop + height * 0.5 + layer * (height + AutoBale.LAYER_GAP)
                if AutoBale.spawnBale(spec.info, spec.fillType, spec.level, x, y, z, ry, farmId, spec.wrap) then
                    created = created + 1
                    made[spec.kind] = (made[spec.kind] or 0) + 1
                    if spec.partial then
                        partialCreated = partialCreated + 1
                    end
                end
            end
        end
    end
    return created, partialCreated, made
end

-- ---------------------------------------------------------------------------
-- Main job (runs on the server)
-- ---------------------------------------------------------------------------

-- px / pz: the point chosen on the map (the stacks are delivered there), nil = at the edge of the field
function AutoBale.run(farmlandId, farmId, round, dryRun, stack, px, pz, wrapGrass)
    local S = AutoBale.STATUS
    local toPoint = px ~= nil and pz ~= nil
    local result = { status = S.OK, farmlandId = farmlandId or 0, liters = 0, bales = 0, capacity = 0, partial = 0, stack = 1, rows = 0, cost = 0, dryRun = dryRun == true,
        delivered = toPoint, fee = 0, nStraw = 0, nHay = 0, nGrass = 0, wrapped = wrapGrass == true, x = toPoint and math.floor(px + 0.5) or 0, z = toPoint and math.floor(pz + 0.5) or 0 }
    if toPoint and not AutoBale.isOnMap(px, pz) then
        result.status = S.NO_SPACE
        return result
    end

    local farmland = g_farmlandManager:getFarmlandById(farmlandId)
    if farmland == nil then
        result.status = S.BAD_FARMLAND
        return result
    end

    if farmId == nil or farmId == noOwnerFarmId() or g_farmlandManager:getFarmlandOwner(farmlandId) ~= farmId then
        result.status = S.NOT_OWNER
        return result
    end

    local pts = AutoBale.getFieldPolygon(AutoBale.getFarmlandField(farmland))
    if #pts < 3 then
        result.status = S.NO_FIELD
        return result
    end

    -- what lies on the ground: straw, hay (dry grass) and fresh grass, each one becomes its own kind of bale
    local groups = {}
    local totalLiters, totalCount, missingBale = 0, 0, false
    local geo = nil
    for _, kind in ipairs(AutoBale.KINDS) do
        local fillTypeIndex = AutoBale.getKindFillType(kind)
        if fillTypeIndex ~= nil then
            local cells, total = AutoBale.scan(farmlandId, pts, fillTypeIndex)
            if total > 0 then
                local info = AutoBale.findBale(round == true, fillTypeIndex)
                if info == nil then
                    missingBale = true
                else
                    local full = math.floor(total / info.capacity)
                    local rest = total - full * info.capacity
                    local partial = rest >= info.capacity * AutoBale.MIN_PARTIAL
                    groups[#groups + 1] = {
                        kind = kind, fillType = fillTypeIndex, cells = cells, total = total, info = info,
                        full = full, rest = rest, partial = partial, count = full + (partial and 1 or 0),
                        wrap = kind == "grass" and wrapGrass == true,
                    }
                    totalLiters = totalLiters + total
                    totalCount = totalCount + full + (partial and 1 or 0)
                    -- one common size for the stacks: the biggest bale
                    if geo == nil then
                        geo = { round = info.round, width = info.width, height = info.height, length = info.length, diameter = info.diameter }
                    else
                        geo.width = math.max(geo.width, info.width)
                        geo.height = math.max(geo.height, info.height)
                        geo.length = math.max(geo.length, info.length)
                        geo.diameter = math.max(geo.diameter, info.diameter)
                    end
                end
            end
        end
    end
    result.liters = math.floor(totalLiters)
    if #groups == 0 then
        result.status = missingBale and S.NO_BALE or S.NO_STRAW
        return result
    end
    result.capacity = groups[1].info.capacity

    local count = totalCount
    local info = geo
    local cells = {}
    for _, g in ipairs(groups) do
        for _, c in ipairs(g.cells) do
            cells[#cells + 1] = c
        end
        result.bales = result.bales + g.full
        if g.partial then
            result.partial = result.partial + math.floor(g.rest)
        end
        if g.kind == "straw" then
            result.nStraw = g.count
        elseif g.kind == "hay" then
            result.nHay = g.count
        else
            result.nGrass = g.count
        end
    end

    if count == 0 then
        result.status = S.TOO_LITTLE
        return result
    end
    if count > AutoBale.MAX_BALES then
        result.status = S.NO_SPACE
        return result
    end

    -- only square bales are stacked, round bales roll away
    local wanted = 1
    if not info.round then
        wanted = math.max(1, AutoBale.normalizeStack(stack))
    end

    local placements, size, pitchL, pitchW
    -- at a point: first with everything that stands there, then (when nothing was found) without buildings and scenery
    for pass = 1, toPoint and 2 or 1 do
        for _, s in ipairs(AutoBale.stackLadder(wanted)) do
            local gapInside = s == 1 and AutoBale.GAP or AutoBale.STACK_GAP
            local pl = (info.round and info.diameter or info.length) + gapInside
            local pw = info.width + gapInside
            local blocks = AutoBale.planBlocks(count, s)
            local blockGap = s == 1 and 0 or AutoBale.BLOCK_GAP
            local found
            if toPoint then
                local height = s * (info.round and info.diameter or info.height) + 0.3
                found = AutoBale.getSlotsAt(px, pz, blocks, pl, pw, blockGap, height, pass == 2)
            else
                found = AutoBale.getSlots(pts, farmlandId, blocks, pl, pw, blockGap)
            end
            if found ~= nil then
                placements, size, pitchL, pitchW = found, s, pl, pw
                break
            end
        end
        if placements ~= nil then
            if toPoint then
                logInfo(string.format("point %.0f / %.0f: %d bales in blocks of %d, %.0f m from the point%s", px, pz, count, size, placements.distance or 0,
                    pass == 2 and " (buildings and scenery were not checked, nothing else was free)" or ""))
            end
            break
        end
    end
    if placements == nil then
        result.status = S.NO_SPACE
        return result
    end
    result.stack = size

    result.rows = 0
    for _, g in ipairs(groups) do
        result.rows = result.rows + AutoBale.countRows(g.cells)
    end
    result.cost = result.rows * AutoBale.pricePerRow
    result.fee = toPoint and AutoBale.deliveryFee or 0

    if result.dryRun then
        return result
    end

    if not AutoBale.canPay(farmId, result.cost + result.fee) then
        result.status = S.NO_MONEY
        return result
    end
    AutoBale.charge(farmId, result.cost + result.fee)

    -- the straw, hay and grass disappear completely, then the bales are created
    result.left = 0
    local seq = {}
    for _, g in ipairs(groups) do
        result.left = result.left + AutoBale.clearStraw(farmlandId, pts, g.fillType, g.cells)
        for _ = 1, g.full do
            seq[#seq + 1] = { info = g.info, fillType = g.fillType, level = g.info.capacity, kind = g.kind, wrap = g.wrap }
        end
        if g.partial then
            seq[#seq + 1] = { info = g.info, fillType = g.fillType, level = g.rest, kind = g.kind, wrap = g.wrap, partial = true }
        end
    end

    local created, partialCreated, made = AutoBale.spawnBlocks(info, seq, placements, pitchL, pitchW, size, farmId)
    result.nStraw, result.nHay, result.nGrass = made.straw or 0, made.hay or 0, made.grass or 0
    if partialCreated == 0 then
        result.partial = 0
    end
    result.bales = created - partialCreated

    AutoBale.totalBales = (AutoBale.totalBales or 0) + created
    return result
end

-- ---------------------------------------------------------------------------
-- Result message
-- ---------------------------------------------------------------------------

function AutoBale.formatResult(r)
    local S = AutoBale.STATUS
    local id = tostring(r.farmlandId)
    if r.status == S.OK then
        local nStraw, nHay, nGrass = r.nStraw or 0, r.nHay or 0, r.nGrass or 0
        local total = nStraw + nHay + nGrass
        if total == 0 then
            total = r.bales + (r.partial > 0 and 1 or 0)
        end
        local text
        if r.dryRun then
            text = string.format(getText("autobale_preview"), id, r.liters, total)
        elseif r.delivered then
            text = string.format(getText("autobale_doneAt"), id, total, r.x or 0, r.z or 0)
        else
            text = string.format(getText("autobale_done"), id, total)
        end
        -- the kinds are named only when there is more than one
        local kinds = {}
        if nStraw > 0 then
            kinds[#kinds + 1] = string.format(getText("autobale_kindStraw"), nStraw)
        end
        if nHay > 0 then
            kinds[#kinds + 1] = string.format(getText("autobale_kindHay"), nHay)
        end
        if nGrass > 0 then
            kinds[#kinds + 1] = string.format(getText(r.wrapped and "autobale_kindSilage" or "autobale_kindGrass"), nGrass)
        end
        if #kinds > 1 then
            text = text .. " (" .. table.concat(kinds, ", ") .. ")"
        end
        local money = (r.cost or 0) + (r.fee or 0)
        if money > 0 then
            text = text .. " " .. string.format(getText(r.dryRun and "autobale_costPreview" or "autobale_cost"), formatMoney(money))
        end
        return text
    elseif r.status == S.NO_STRAW then
        return string.format(getText("autobale_noStraw"), id)
    elseif r.status == S.NOT_OWNER then
        return getText("autobale_notOwner")
    elseif r.status == S.NO_FIELD then
        return string.format(getText("autobale_noField"), id)
    elseif r.status == S.NO_BALE then
        return getText("autobale_noBale")
    elseif r.status == S.TOO_LITTLE then
        return string.format(getText("autobale_tooLittle"), id, r.liters)
    elseif r.status == S.NO_SPACE then
        return string.format(getText(r.delivered and "autobale_noSpacePoint" or "autobale_noSpace"), id)
    elseif r.status == S.NO_MONEY then
        return string.format(getText("autobale_noMoney"), id, formatMoney((r.cost or 0) + (r.fee or 0)))
    end
    return getText("autobale_badFarmland")
end

function AutoBale.showResult(r)
    AutoBale.notify(AutoBale.formatResult(r))
end

-- ---------------------------------------------------------------------------
-- Network events
-- ---------------------------------------------------------------------------

-- client -> server: do the job for this farmland
AutoBaleRequestEvent = {}
local AutoBaleRequestEvent_mt = Class(AutoBaleRequestEvent, Event)
InitEventClass(AutoBaleRequestEvent, "AutoBaleRequestEvent")

function AutoBaleRequestEvent.emptyNew()
    return Event.new(AutoBaleRequestEvent_mt)
end

function AutoBaleRequestEvent.new(farmlandId, round, dryRun, stack, px, pz, wrapGrass)
    local self = AutoBaleRequestEvent.emptyNew()
    self.farmlandId = farmlandId
    self.round = round == true
    self.dryRun = dryRun == true
    self.stack = AutoBale.normalizeStack(stack)
    self.wrapGrass = wrapGrass ~= false
    self.hasPoint = px ~= nil and pz ~= nil
    self.x = px or 0
    self.z = pz or 0
    return self
end

function AutoBaleRequestEvent:readStream(streamId, connection)
    self.farmlandId = streamReadInt32(streamId)
    self.round = streamReadBool(streamId)
    self.dryRun = streamReadBool(streamId)
    self.stack = streamReadUInt8(streamId)
    self.wrapGrass = streamReadBool(streamId)
    self.hasPoint = streamReadBool(streamId)
    if self.hasPoint then
        self.x = streamReadFloat32(streamId)
        self.z = streamReadFloat32(streamId)
    end
    self:run(connection)
end

function AutoBaleRequestEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmlandId)
    streamWriteBool(streamId, self.round)
    streamWriteBool(streamId, self.dryRun)
    streamWriteUInt8(streamId, self.stack or 4)
    streamWriteBool(streamId, self.wrapGrass ~= false)
    streamWriteBool(streamId, self.hasPoint == true)
    if self.hasPoint then
        streamWriteFloat32(streamId, self.x)
        streamWriteFloat32(streamId, self.z)
    end
end

function AutoBaleRequestEvent:run(connection)
    if connection:getIsServer() then
        return
    end
    -- the farm comes from the connection, never from the client
    local farmId = nil
    local userId = g_currentMission.userManager:getUserIdByConnection(connection)
    if userId ~= nil then
        local farm = g_farmManager:getFarmByUserId(userId)
        if farm ~= nil then
            farmId = farm.farmId
        end
    end
    local px, pz = nil, nil
    if self.hasPoint then
        px, pz = self.x, self.z
    end
    local result = AutoBale.run(self.farmlandId, farmId, self.round, self.dryRun, self.stack, px, pz, self.wrapGrass)
    connection:sendEvent(AutoBaleResultEvent.new(result))
end

-- server -> the client that asked: what happened
AutoBaleResultEvent = {}
local AutoBaleResultEvent_mt = Class(AutoBaleResultEvent, Event)
InitEventClass(AutoBaleResultEvent, "AutoBaleResultEvent")

function AutoBaleResultEvent.emptyNew()
    return Event.new(AutoBaleResultEvent_mt)
end

function AutoBaleResultEvent.new(r)
    local self = AutoBaleResultEvent.emptyNew()
    self.r = r
    return self
end

function AutoBaleResultEvent:readStream(streamId, connection)
    self.r = {
        status = streamReadUInt8(streamId),
        farmlandId = streamReadInt32(streamId),
        liters = streamReadInt32(streamId),
        bales = streamReadInt32(streamId),
        capacity = streamReadInt32(streamId),
        partial = streamReadInt32(streamId),
        stack = streamReadUInt8(streamId),
        rows = streamReadInt32(streamId),
        cost = streamReadInt32(streamId),
        dryRun = streamReadBool(streamId),
        delivered = streamReadBool(streamId),
        fee = streamReadInt32(streamId),
        x = streamReadInt32(streamId),
        z = streamReadInt32(streamId),
        nStraw = streamReadInt32(streamId),
        nHay = streamReadInt32(streamId),
        nGrass = streamReadInt32(streamId),
        wrapped = streamReadBool(streamId),
    }
    self:run(connection)
end

function AutoBaleResultEvent:writeStream(streamId, connection)
    local r = self.r
    streamWriteUInt8(streamId, r.status)
    streamWriteInt32(streamId, r.farmlandId)
    streamWriteInt32(streamId, r.liters)
    streamWriteInt32(streamId, r.bales)
    streamWriteInt32(streamId, r.capacity)
    streamWriteInt32(streamId, r.partial)
    streamWriteUInt8(streamId, r.stack or 1)
    streamWriteInt32(streamId, r.rows or 0)
    streamWriteInt32(streamId, r.cost or 0)
    streamWriteBool(streamId, r.dryRun == true)
    streamWriteBool(streamId, r.delivered == true)
    streamWriteInt32(streamId, r.fee or 0)
    streamWriteInt32(streamId, r.x or 0)
    streamWriteInt32(streamId, r.z or 0)
    streamWriteInt32(streamId, r.nStraw or 0)
    streamWriteInt32(streamId, r.nHay or 0)
    streamWriteInt32(streamId, r.nGrass or 0)
    streamWriteBool(streamId, r.wrapped == true)
end

function AutoBaleResultEvent:run(connection)
    if connection:getIsServer() then
        AutoBale.showResult(self.r)
    end
end

-- entry point for the button and the console; px / pz = point chosen on the map (nil = at the field edge)
function AutoBale.request(farmlandId, dryRun, px, pz)
    local mission = g_currentMission
    if mission == nil or farmlandId == nil then
        return false
    end
    if mission:getIsServer() then
        local result = AutoBale.run(farmlandId, mission:getFarmId(), AutoBale.useRoundBales, dryRun, AutoBale.stackSize, px, pz, AutoBale.wrapGrass)
        AutoBale.showResult(result)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(AutoBaleRequestEvent.new(farmlandId, AutoBale.useRoundBales, dryRun, AutoBale.stackSize, px, pz, AutoBale.wrapGrass))
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Map menu: "Auto Bale" under "Tag Place"
-- ---------------------------------------------------------------------------

function AutoBale.isOwnFarmland(farmland)
    if farmland == nil or g_currentMission == nil or g_farmlandManager == nil then
        return false
    end
    local farmId = g_currentMission:getFarmId()
    if farmId == nil or farmId == noOwnerFarmId() then
        return false
    end
    return g_farmlandManager:getFarmlandOwner(farmland.id) == farmId
end

-- moves every button with an id >= fromId one place down (ids and entries), to make room at fromId
local function makeRoomAt(actions, contextActions, fromId)
    for name, id in pairs(actions) do
        if type(id) == "number" and id >= fromId then
            actions[name] = id + 1
        end
    end
    local ids = {}
    for id in pairs(contextActions) do
        if type(id) == "number" and id >= fromId then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids, function(a, b)
        return a > b
    end)
    for _, id in ipairs(ids) do
        contextActions[id + 1] = contextActions[id]
        contextActions[id] = nil
    end
end

function AutoBale.onLoadMapFinished(self, superFunc)
    superFunc(self)

    local actions = InGameMenuMapFrame.ACTIONS
    if actions == nil or self.contextActions == nil then
        logWarning("map menu has another layout, the Auto Bale button is not available (console: autoBale)")
        return
    end

    if actions.AUTO_BALE == nil then
        if actions.AUTO_HARVEST ~= nil then
            -- Auto Harvest was loaded first: Auto Bale takes its place and Auto Harvest moves directly under it
            local harvestId = actions.AUTO_HARVEST
            makeRoomAt(actions, self.contextActions, harvestId)
            actions.AUTO_BALE = harvestId
        else
            -- the id is appended at the end, so the ids of the base game buttons stay as they are
            local count = 0
            for _ in pairs(actions) do
                count = count + 1
            end
            actions.AUTO_BALE = count + 1
        end
    end

    self.contextActions[actions.AUTO_BALE] = {
        title = getText("autobale_button"),
        callback = AutoBale.onButton,
        isActive = false,
    }
end

function AutoBale.setMapInputContext(self, superFunc, ...)
    superFunc(self, ...)

    local actions = InGameMenuMapFrame.ACTIONS
    if actions == nil or actions.AUTO_BALE == nil or self.contextActions == nil then
        return
    end
    local action = self.contextActions[actions.AUTO_BALE]
    if action == nil then
        return
    end

    local farmland = self.selectedFarmland
    action.isActive = farmland ~= nil
        and AutoBale.isOwnFarmland(farmland)
        and AutoBale.getFarmlandField(farmland) ~= nil
end

-- ---------------------------------------------------------------------------
-- Choosing the delivery point on the map (client)
-- ---------------------------------------------------------------------------

-- true when the click on the map can be caught (the hooks at the bottom of the file are installed)
function AutoBale.canPick()
    return AutoBale.askPoint == true and AutoBale.pickHooked == true
end

function AutoBale.startPicking(farmlandId)
    AutoBale.picking = { farmlandId = farmlandId }
    AutoBale.notify(getText("autobale_pick"))
end

function AutoBale.cancelPicking(withMessage)
    if AutoBale.picking ~= nil then
        AutoBale.picking = nil
        if withMessage then
            AutoBale.notify(getText("autobale_pickCancel"))
        end
    end
end

-- the point was chosen: now the job is done
function AutoBale.finishPicking(worldX, worldZ)
    local picking = AutoBale.picking
    AutoBale.picking = nil
    if picking ~= nil then
        AutoBale.request(picking.farmlandId, false, worldX, worldZ)
    end
end

-- InGameMenuMapFrame:onClickMap(element, worldX, worldZ)
function AutoBale.onClickMap(self, superFunc, element, worldX, worldZ, ...)
    if AutoBale.picking ~= nil and type(worldX) == "number" and type(worldZ) == "number" then
        AutoBale.finishPicking(worldX, worldZ)
        return
    end
    return superFunc(self, element, worldX, worldZ, ...)
end

-- InGameMenuMapFrame:onClickHotspot(element, hotspot): a click on an icon of the map is a point, too
function AutoBale.onClickHotspot(self, superFunc, element, hotspot, ...)
    if AutoBale.picking ~= nil and hotspot ~= nil then
        local x, z = hotspot.worldX, hotspot.worldZ
        if (x == nil or z == nil) and hotspot.getWorldPosition ~= nil then
            x, z = hotspot:getWorldPosition()
        end
        if type(x) == "number" and type(z) == "number" then
            AutoBale.finishPicking(x, z)
            return
        end
    end
    return superFunc(self, element, hotspot, ...)
end

-- the map is closed while the point is asked for: nothing happens
function AutoBale.onFrameClose(self)
    AutoBale.cancelPicking(true)
end

-- a line at the top of the map while the point is asked for
function AutoBale.drawPickHint(self)
    if AutoBale.picking == nil then
        return
    end
    pcall(function()
        setTextBold(true)
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(1, 1, 1, 1)
        renderText(0.5, 0.95, 0.024, getText("autobale_pickHint"))
        setTextBold(false)
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(1, 1, 1, 1)
    end)
end

-- answer of the "Are you sure?" question: Yes asks for the delivery point on the map (or starts the job
-- at the field edge when the map cannot be clicked), No just closes the Auto Bale menu
-- (called as callback(target, yes), or callback(yes) when the dialog has no target)
-- true when fresh grass (not hay) lies on the field: then the player is asked what kind of bales he wants
function AutoBale.fieldHasGrass(farmlandId)
    local fillTypeIndex = AutoBale.getKindFillType("grass")
    if fillTypeIndex == nil then
        return false
    end
    local ok, has = pcall(function()
        local farmland = g_farmlandManager:getFarmlandById(farmlandId)
        local pts = AutoBale.getFieldPolygon(AutoBale.getFarmlandField(farmland))
        if #pts < 3 then
            return false
        end
        local _, total = AutoBale.scan(farmlandId, pts, fillTypeIndex)
        return total > 0
    end)
    return ok and has == true
end

-- after the questions: the point is asked on the map, or the job starts at once
function AutoBale.proceed(farmlandId)
    if AutoBale.canPick() then
        AutoBale.startPicking(farmlandId)
    else
        AutoBale.request(farmlandId, false)
    end
end

-- Yes = wrapped silage bales, No = plain grass bales
function AutoBale.onGrassChoice(first, second)
    local yes = second
    if second == nil then
        yes = first
    end
    local farmlandId = AutoBale.pendingGrassFarmlandId
    AutoBale.pendingGrassFarmlandId = nil
    if farmlandId ~= nil then
        AutoBale.wrapGrass = yes == true
        AutoBale.proceed(farmlandId)
    end
end

function AutoBale.onConfirm(first, second)
    local yes = second
    if second == nil then
        yes = first
    end
    local farmlandId = AutoBale.pendingFarmlandId
    AutoBale.pendingFarmlandId = nil
    if yes == true and farmlandId ~= nil then
        if YesNoDialog ~= nil and YesNoDialog.show ~= nil and AutoBale.fieldHasGrass(farmlandId) then
            AutoBale.pendingGrassFarmlandId = farmlandId
            YesNoDialog.show(AutoBale.onGrassChoice, AutoBale, string.format(getText("autobale_askGrass"), tostring(farmlandId)), getText("autobale_button"))
        else
            AutoBale.proceed(farmlandId)
        end
    end
end

function AutoBale.onButton(frame, element)
    local farmland = frame.selectedFarmland

    -- the Auto Bale menu is closed in every case
    if InGameMenuMapUtil ~= nil and InGameMenuMapUtil.hideContextBox ~= nil then
        InGameMenuMapUtil.hideContextBox(frame.contextBox)
        InGameMenuMapUtil.hideContextBox(frame.contextBoxPlayer)
        InGameMenuMapUtil.hideContextBox(frame.contextBoxFarmland)
    end

    if farmland ~= nil then
        if YesNoDialog ~= nil and YesNoDialog.show ~= nil then
            AutoBale.pendingFarmlandId = farmland.id
            local text
            if AutoBale.canPick() then
                text = string.format(getText("autobale_confirmPoint"), tostring(farmland.id), formatMoney(AutoBale.pricePerRow), formatMoney(AutoBale.deliveryFee))
            else
                text = string.format(getText("autobale_confirm"), tostring(farmland.id), formatMoney(AutoBale.pricePerRow))
            end
            YesNoDialog.show(AutoBale.onConfirm, AutoBale, text, getText("autobale_button"))
        else
            AutoBale.request(farmland.id, false)
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Console
-- ---------------------------------------------------------------------------

local function getPlayerPosition()
    local x, z
    if g_localPlayer ~= nil and g_localPlayer.getPosition ~= nil then
        local px, _, pz = g_localPlayer:getPosition()
        x, z = px, pz
    end
    local vehicle = g_currentMission ~= nil and g_currentMission.controlledVehicle or nil
    if vehicle ~= nil and vehicle.rootNode ~= nil then
        local vx, _, vz = getWorldTranslation(vehicle.rootNode)
        x, z = vx, vz
    end
    return x, z
end

local function getPlayerFarmlandId()
    local x, z = getPlayerPosition()
    if x == nil then
        return nil
    end
    return g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
end

-- autoBale [farmlandId] [x z | here]: same as the button. Without a point the bales lie at the field edge,
-- with a point (or "here" = where you stand) the stacks are delivered there. Farmland under the player when no id is given
function AutoBale:consoleRun(a, b, c)
    local usage = "Usage: autoBale [farmlandId] [x z | here] (stand on your field or give the farmland number)"
    local id, px, pz
    local first, second, third = tonumber(a), tonumber(b), tonumber(c)
    if a == "here" then
        px, pz = getPlayerPosition()
    elseif first ~= nil and second ~= nil and third ~= nil then
        id, px, pz = first, second, third
    elseif first ~= nil and second ~= nil then
        px, pz = first, second
    elseif first ~= nil then
        id = first
        if b == "here" then
            px, pz = getPlayerPosition()
        end
    elseif a ~= nil then
        return usage
    end
    id = id or getPlayerFarmlandId()
    if id == nil or id == 0 then
        return usage
    end
    if b == "here" and px == nil then
        return "Cannot find your position"
    end
    AutoBale.request(id, false, px, pz)
    if px ~= nil then
        return string.format("Auto Bale started for farmland %d, delivery to %.0f / %.0f", id, px, pz)
    end
    return "Auto Bale started for farmland " .. tostring(id)
end

-- autoBaleScan [farmlandId]: only counts, changes nothing
function AutoBale:consoleScan(farmlandIdText)
    local id = tonumber(farmlandIdText) or getPlayerFarmlandId()
    if id == nil or id == 0 then
        return "Usage: autoBaleScan [farmlandId]"
    end
    AutoBale.request(id, true)
    return "Auto Bale scan (no changes) for farmland " .. tostring(id)
end

-- autoBaleType square|round
function AutoBale:consoleType(kind)
    if kind ~= nil then
        AutoBale.useRoundBales = (kind == "round")
    end
    return "Auto Bale makes " .. (AutoBale.useRoundBales and "round" or "square") .. " bales. Usage: autoBaleType square|round"
end

-- autoBalePrice [amount]: money per straw row
function AutoBale:consolePrice(value)
    if value ~= nil then
        local price = tonumber(value)
        if price == nil or price < 0 then
            return "Usage: autoBalePrice [money per straw row]"
        end
        AutoBale.pricePerRow = math.floor(price)
    end
    return "Auto Bale costs " .. formatMoney(AutoBale.pricePerRow) .. " per straw row. Usage: autoBalePrice [amount]"
end

-- autoBaleFee [amount]: money for the delivery to the chosen point
function AutoBale:consoleFee(value)
    if value ~= nil then
        local fee = tonumber(value)
        if fee == nil or fee < 0 then
            return "Usage: autoBaleFee [money for the delivery]"
        end
        AutoBale.deliveryFee = math.floor(fee)
    end
    return "The delivery to a chosen point costs " .. formatMoney(AutoBale.deliveryFee) .. ". Usage: autoBaleFee [amount]"
end

-- autoBalePick on|off: the button asks for the delivery point (on) or puts the bales at the field edge (off)
function AutoBale:consolePick(value)
    if value == "on" or value == "off" then
        AutoBale.askPoint = value == "on"
    elseif value ~= nil then
        return "Usage: autoBalePick on|off"
    end
    return "The button " .. (AutoBale.askPoint and "asks for the delivery point on the map" or "puts the bales at the field edge") .. ". Usage: autoBalePick on|off"
end

-- autoBaleClean [farmlandId]: erases straw rests (also the invisible-to-the-scan traces) on the field
function AutoBale:consoleClean(farmlandIdText)
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer() then
        return "autoBaleClean only works on the host / in single player"
    end
    local id = tonumber(farmlandIdText) or getPlayerFarmlandId()
    if id == nil or id == 0 then
        return "Usage: autoBaleClean [farmlandId] (stand on your field or give the farmland number)"
    end
    local cleared, info = AutoBale.cleanField(id, mission:getFarmId())
    if cleared == nil then
        return info
    end
    return string.format("Auto Bale cleaned farmland %d: %d blocks of %d m cleared, %d skipped (other material)", id, cleared, AutoBale.CLEAN_BLOCK, info)
end

-- autoBaleStack 0|4|6
function AutoBale:consoleStack(value)
    if value ~= nil then
        local size = tonumber(value)
        if size ~= 0 and size ~= 4 and size ~= 6 then
            return "Usage: autoBaleStack 0|4|6 (0 = single bales in a row, 4 = blocks of 4x4x4, 6 = blocks of 6x6x6)"
        end
        AutoBale.stackSize = size
    end
    if AutoBale.stackSize == 0 then
        return "Auto Bale puts single bales in a row. Usage: autoBaleStack 0|4|6"
    end
    return string.format("Auto Bale stacks square bales in blocks of %dx%dx%d. Usage: autoBaleStack 0|4|6", AutoBale.stackSize, AutoBale.stackSize, AutoBale.stackSize)
end

-- autoBaleGrass silage|grass
function AutoBale:consoleGrass(kind)
    if kind ~= nil then
        kind = string.lower(kind)
        if kind == "silage" or kind == "wrapped" then
            AutoBale.wrapGrass = true
        elseif kind == "grass" or kind == "plain" then
            AutoBale.wrapGrass = false
        else
            return "Usage: autoBaleGrass silage|grass"
        end
    end
    return "Auto Bale makes " .. (AutoBale.wrapGrass and "wrapped silage bales" or "plain grass bales") .. " from fresh grass. Usage: autoBaleGrass silage|grass"
end

function AutoBale:consoleInfo()
    local lines = {}
    local actions = InGameMenuMapFrame ~= nil and InGameMenuMapFrame.ACTIONS or nil
    lines[#lines + 1] = "AutoBale | map button id: " .. tostring(actions ~= nil and actions.AUTO_BALE or "NOT REGISTERED")
        .. " | stack: " .. tostring(AutoBale.stackSize) .. " | price per row: " .. tostring(AutoBale.pricePerRow) .. " | delivery fee: " .. tostring(AutoBale.deliveryFee)
        .. " | map click: " .. (AutoBale.pickHooked and (AutoBale.askPoint and "asks for the point" or "off") or "NOT AVAILABLE") .. " | bales created: " .. tostring(AutoBale.totalBales or 0)
    lines[#lines + 1] = "fresh grass becomes: " .. (AutoBale.wrapGrass and "wrapped silage bales" or "plain grass bales")
    for _, kind in ipairs(AutoBale.KINDS) do
        local fillTypeIndex = AutoBale.getKindFillType(kind)
        for _, round in ipairs({ false, true }) do
            local info = fillTypeIndex ~= nil and AutoBale.findBale(round, fillTypeIndex) or nil
            if info ~= nil then
                lines[#lines + 1] = string.format("%s %s bale: %d L | %s", round and "round" or "square", kind, info.capacity, tostring(info.xmlFilename))
            else
                lines[#lines + 1] = (round and "round" or "square") .. " " .. kind .. " bale: NOT FOUND"
            end
        end
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Hooks (installed once when the mod is loaded)
-- ---------------------------------------------------------------------------

if InGameMenuMapFrame ~= nil and InGameMenuMapFrame.onLoadMapFinished ~= nil and InGameMenuMapFrame.setMapInputContext ~= nil then
    InGameMenuMapFrame.onLoadMapFinished = Utils.overwrittenFunction(InGameMenuMapFrame.onLoadMapFinished, AutoBale.onLoadMapFinished)
    InGameMenuMapFrame.setMapInputContext = Utils.overwrittenFunction(InGameMenuMapFrame.setMapInputContext, AutoBale.setMapInputContext)
else
    logWarning("InGameMenuMapFrame not found, the Auto Bale button is not available (console: autoBale)")
end

-- the click on the map that chooses the delivery point
if InGameMenuMapFrame ~= nil and InGameMenuMapFrame.onClickMap ~= nil then
    InGameMenuMapFrame.onClickMap = Utils.overwrittenFunction(InGameMenuMapFrame.onClickMap, AutoBale.onClickMap)
    if InGameMenuMapFrame.onClickHotspot ~= nil then
        InGameMenuMapFrame.onClickHotspot = Utils.overwrittenFunction(InGameMenuMapFrame.onClickHotspot, AutoBale.onClickHotspot)
    end
    if InGameMenuMapFrame.onFrameClose ~= nil then
        InGameMenuMapFrame.onFrameClose = Utils.appendedFunction(InGameMenuMapFrame.onFrameClose, AutoBale.onFrameClose)
    end
    if InGameMenuMapFrame.draw ~= nil then
        InGameMenuMapFrame.draw = Utils.appendedFunction(InGameMenuMapFrame.draw, AutoBale.drawPickHint)
    end
    AutoBale.pickHooked = true
else
    logWarning("the click on the map cannot be caught, the bales are put at the field edge (console: autoBale [farmlandId] [x z])")
end

addConsoleCommand("autoBale", "Straw on the field to bales: autoBale [farmlandId] [x z | here] (with a point they are delivered there)", "consoleRun", AutoBale)
addConsoleCommand("autoBaleGrass", "Fresh grass to wrapped silage bales or plain grass bales: autoBaleGrass silage|grass", "consoleGrass", AutoBale)
addConsoleCommand("autoBaleScan", "Count the straw and the bales without changing anything: autoBaleScan [farmlandId]", "consoleScan", AutoBale)
addConsoleCommand("autoBaleType", "Bale shape: autoBaleType square|round", "consoleType", AutoBale)
addConsoleCommand("autoBalePrice", "Money per straw row: autoBalePrice [amount]", "consolePrice", AutoBale)
addConsoleCommand("autoBaleClean", "Erase loose material (straw rests) on the field: autoBaleClean [farmlandId]", "consoleClean", AutoBale)
addConsoleCommand("autoBaleStack", "Stack the bales in blocks: autoBaleStack 0|4|6 (0 = single bales in a row)", "consoleStack", AutoBale)
addConsoleCommand("autoBaleFee", "Money for the delivery to the chosen point: autoBaleFee [amount]", "consoleFee", AutoBale)
addConsoleCommand("autoBalePick", "The button asks for the delivery point on the map: autoBalePick on|off", "consolePick", AutoBale)
addConsoleCommand("autoBaleInfo", "Show the Auto Bale status", "consoleInfo", AutoBale)
