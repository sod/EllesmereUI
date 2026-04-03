-------------------------------------------------------------------------------
--  EllesmereUICdmSpellPicker.lua
--  Interactive Preview Helpers (used by options spell picker)
--  Spell list building, add/remove/swap/move/replace operations, and
--  custom bar creation/removal.
-------------------------------------------------------------------------------
local _, ns = ...

-- Upvalue aliases (tables/functions populated by EllesmereUICooldownManager.lua)
local ECME                   = ns.ECME
local barDataByKey           = ns.barDataByKey
local cdmBarFrames           = ns.cdmBarFrames
local cdmBarIcons            = ns.cdmBarIcons
local ResolveChildSpellID    = ns.ResolveChildSpellID
local ResolveInfoSpellID     = ns.ResolveInfoSpellID
-- _cdIDToCorrectSID removed from main file; hooks resolve per-frame now.
-- SpellPicker still writes to this for its own local matching.
local _cdIDToCorrectSID      = ns._cdIDToCorrectSID or {}
local _tickCDUtilTrackedSet  = ns._tickCDUtilTrackedSet
local _tickBuffIconTrackedSet = ns._tickBuffIconTrackedSet
local ComputeTopRowStride    = ns.ComputeTopRowStride

--- Get all available CDM spells for a bar's categories.
-- Forward declaration -- defined after GetCDMSpellsForBar (which calls it)
local SpellUsedOnAnyOtherBar

--- Returns array of { cdID, spellID, name, icon, isDisplayed, isKnown [, isExtra] }
--- Sorted: displayed+known first, then known, then unlearned (desaturated).
function ns.GetCDMSpellsForBar(barKey)
    -- Deferred-access aliases (populated after file load)
    local CDM_BAR_CATEGORIES = ns.CDM_BAR_CATEGORIES
    local BLIZZ_CDM_FRAMES = ns.BLIZZ_CDM_FRAMES

    -- Resolve bar type for custom bars
    local barType
    local p = ECME.db.profile
    local bd = barDataByKey[barKey]
    if bd then barType = bd.barType end
    -- Default bars have implicit types
    if not barType then
        if barKey == "cooldowns" then barType = "cooldowns"
        elseif barKey == "utility" then barType = "utility"
        elseif barKey == "buffs" then barType = "buffs"
        end
    end

    -- Misc bars use the normal custom bar spell picker (no early return)

    local cats = CDM_BAR_CATEGORIES[barKey]
        or CDM_BAR_CATEGORIES[barType or "cooldowns"]
        or { 0, 1 }

    -- Build our pool set: spellIDs we're currently tracking on this bar
    local ourPool = {}  -- [spellID or name] = true
    local sd = ns.GetBarSpellData(barKey)
    if sd and sd.assignedSpells then
        for _, sid in ipairs(sd.assignedSpells) do
            if sid and sid ~= 0 then
                ourPool[sid] = true
                -- Also match by name so same-name variants (ability vs aura)
                -- show as "on this bar" in the picker.
                local sname = sid > 0 and C_Spell.GetSpellName(sid)
                if sname then ourPool[sname] = true end
            end
        end
    end

    -- Use the centralized per-viewer tracked sets built each tick.
    -- Same sets drive the untracked overlay on bars.
    local isBuffType = (barType == "buffs")
    local blizzTracked = isBuffType and _tickBuffIconTrackedSet or _tickCDUtilTrackedSet

    -- Build a cdID -> spellID lookup from viewer children so the
    -- dropdown loop (which iterates cdIDs without children) can use the
    -- frame-resolved spellID instead of the potentially wrong cooldownInfo.
    local cdIDToChildSID = {}
    local function ScanViewerForChildSIDs(viewerName)
        local vf = _G[viewerName]
        if not vf then return end
        local function ProcessChild(child)
            if not child then return end
            local sid = ResolveChildSpellID(child)
            if sid and sid > 0 then
                local cdID = child.cooldownID or (child.cooldownInfo and child.cooldownInfo.cooldownID)
                if cdID then
                    cdIDToChildSID[cdID] = sid
                    if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
                        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                        if info then
                            local infoSid = ResolveInfoSpellID(info)
                            if infoSid and sid ~= infoSid then
                                _cdIDToCorrectSID[cdID] = sid
                            end
                        end
                    end
                end
            end
        end
        for i = 1, vf:GetNumChildren() do
            ProcessChild(select(i, vf:GetChildren()))
        end
        if vf.itemFramePool and vf.itemFramePool.EnumerateActive then
            for frame in vf.itemFramePool:EnumerateActive() do
                ProcessChild(frame)
            end
        end
    end
    if isBuffType then
        ScanViewerForChildSIDs("BuffIconCooldownViewer")
        ScanViewerForChildSIDs("BuffBarCooldownViewer")
    else
        ScanViewerForChildSIDs("EssentialCooldownViewer")
        ScanViewerForChildSIDs("UtilityCooldownViewer")
    end

    local spells = {}
    local seen = {}
    local seenSpellID = {}  -- dedup by spellID across categories

    -- Cache category data to avoid double API calls (pre-scan + main loop).
    local catCache = {}
    for _, cat in ipairs(cats) do
        local allIDs  = C_CooldownViewer.GetCooldownViewerCategorySet(cat, true) or {}
        local knownIDs = C_CooldownViewer.GetCooldownViewerCategorySet(cat, false) or {}
        local knownSet = {}
        for _, id in ipairs(knownIDs) do knownSet[id] = true end
        catCache[#catCache + 1] = { cat = cat, allIDs = allIDs, knownSet = knownSet }
    end

    -- Pre-scan ALL categories before the main loop. Blizzard can issue two cdIDs
    -- for the same spell (one learned, one not) and they can be in different
    -- categories. Building spellIDKnown per-category would miss cross-category
    -- matches, causing the spell to appear unlearned if the unlearned cdID is in
    -- an earlier category than the learned one. Register every spellID variant
    -- (frame-resolved, override/linked, base) for learned cdIDs.
    local spellIDKnown = {}
    for _, cd in ipairs(catCache) do
        for _, cdID in ipairs(cd.allIDs) do
            if cd.knownSet[cdID] then
                local s1 = cdIDToChildSID[cdID]
                if s1 and s1 > 0 then spellIDKnown[s1] = true end
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                if info then
                    local s2 = ResolveInfoSpellID(info)
                    if s2 and s2 > 0 then spellIDKnown[s2] = true end
                    if info.spellID and info.spellID > 0 then spellIDKnown[info.spellID] = true end
                end
            end
        end
    end

    for _, cd in ipairs(catCache) do
        local cat, allIDs, knownSet = cd.cat, cd.allIDs, cd.knownSet

        for _, cdID in ipairs(allIDs) do
            if not seen[cdID] then
                seen[cdID] = true
                -- Prefer the frame-resolved spellID from the viewer child scan.
                -- The cooldownInfo struct can contain the wrong spellID for buff
                -- entries (spec aura instead of the actual tracked buff).
                local cdInfo  -- retain for base spellID fallback in isKnown check
                local sid = cdIDToChildSID[cdID]
                if not sid then
                    cdInfo = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                    if cdInfo then sid = ResolveInfoSpellID(cdInfo) end
                end
                sid = sid or 0
                if sid > 0 and not seenSpellID[sid] then
                    local name = C_Spell.GetSpellName(sid)
                    local tex = C_Spell.GetSpellTexture(sid)
                    -- Dedup by both spellID and name: some spells have
                    -- multiple cdIDs with different spellIDs but the same
                    -- name (e.g. "Voidfall" ability vs "Voidfall" aura).
                    -- Prefer the version that's in the buff viewer (tracked).
                    if not cdInfo then
                        cdInfo = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                    end
                    local baseSid = cdInfo and cdInfo.spellID
                    if baseSid and baseSid > 0 then seenSpellID[baseSid] = true end
                    local isTracked = blizzTracked[sid]
                    -- Skip if we already have a tracked version with this name
                    -- (keeps the viewer-tracked version, drops the other)
                    local nameUsed = seenSpellID[name]
                    if name and (tex or cat == 2 or cat == 3) and (not nameUsed or (isTracked and not nameUsed._tracked)) then
                        -- If replacing a previous entry, remove it
                        if nameUsed then
                            for si = #spells, 1, -1 do
                                if spells[si].name == name then
                                    table.remove(spells, si)
                                    break
                                end
                            end
                        end
                        seenSpellID[sid] = true
                        seenSpellID[name] = { _tracked = isTracked }
                        local usedOnBar = SpellUsedOnAnyOtherBar(sid, barKey)
                        local baseKnown = cdInfo and cdInfo.spellID
                            and cdInfo.spellID > 0 and spellIDKnown[cdInfo.spellID]
                        -- Is this spell in the correct Blizzard CDM section for this bar?
                        local trackedForBar = ns.IsSpellTrackedForBarType(sid, barType)
                        spells[#spells + 1] = {
                            cdID = cdID,
                            spellID = sid,
                            name = name,
                            icon = tex,
                            cdmCat = cat,
                            cdmCatGroup = (cat == 2 or cat == 3) and "buff" or "cooldown",
                            isDisplayed = ourPool[sid] or (name and ourPool[name]) or blizzTracked[sid] or false,
                            onEUIBar = (ourPool[sid] or (name and ourPool[name]) or usedOnBar) and true or false,
                            isKnown = knownSet[cdID] or spellIDKnown[sid] or baseKnown or false,
                            usedOnBar = usedOnBar,
                            isTrackedForBar = trackedForBar,
                        }
                    end
                end
            end
        end
    end

    -- Sort: within each category, known+displayed first, then known, then unlearned; alpha within tier
    table.sort(spells, function(a, b)
        if a.cdmCat ~= b.cdmCat then return (a.cdmCat or 0) < (b.cdmCat or 0) end
        local aScore = (a.isKnown and 2 or 0) + (a.isDisplayed and 1 or 0)
        local bScore = (b.isKnown and 2 or 0) + (b.isDisplayed and 1 or 0)
        if aScore ~= bScore then return aScore > bScore end
        return a.name < b.name
    end)


    return spells
end

-- (ns.GetTBBSpellPool removed -- TBB disabled pending rewrite)

--- Check if a cooldownID has a Blizzard CDM child (is "displayed")
function ns.IsSpellDisplayedInCDM(barKey, cdID)
    local BLIZZ_CDM_FRAMES = ns.BLIZZ_CDM_FRAMES
    local blizzName = BLIZZ_CDM_FRAMES[barKey]
    if not blizzName then return false end
    local blizzFrame = _G[blizzName]
    if not blizzFrame then return false end
    for i = 1, blizzFrame:GetNumChildren() do
        local child = select(i, blizzFrame:GetChildren())
        if child then
            local cid = child.cooldownID
            if not cid and child.cooldownInfo then
                cid = child.cooldownInfo.cooldownID
            end
            if cid == cdID then return true end
        end
    end
    return false
end

--- Swap two tracked spell positions
function ns.SwapTrackedSpells(barKey, idx1, idx2)
    local sd = ns.GetBarSpellData(barKey)
    if not sd then return false end
    if not sd.assignedSpells then sd.assignedSpells = {} end
    local t = sd.assignedSpells
    if idx1 < 1 or idx2 < 1 then return false end
    local maxIdx = math.max(idx1, idx2)
    while #t < maxIdx do t[#t + 1] = 0 end
    t[idx1], t[idx2] = t[idx2], t[idx1]
    while #t > 0 and (t[#t] == 0 or t[#t] == nil) do t[#t] = nil end
    local frame = cdmBarFrames[barKey]
    if frame then frame._blizzCache = nil end
    if ns.QueueReanchor then ns.QueueReanchor() end
    return true
end

--- Move a tracked spell from one position to another (insert, not swap)
function ns.MoveTrackedSpell(barKey, fromIdx, toIdx)
    if fromIdx == toIdx then return false end
    local sd = ns.GetBarSpellData(barKey)
    if not sd then return false end
    if not sd.assignedSpells then sd.assignedSpells = {} end
    local t = sd.assignedSpells
    if fromIdx < 1 or fromIdx > #t then return false end
    if toIdx < 1 then toIdx = 1 end
    while #t < toIdx do t[#t + 1] = 0 end
    local val = table.remove(t, fromIdx)
    table.insert(t, toIdx, val)
    while #t > 0 and (t[#t] == 0 or t[#t] == nil) do t[#t] = nil end
    local frame = cdmBarFrames[barKey]
    if frame then frame._blizzCache = nil end
    if ns.QueueReanchor then ns.QueueReanchor() end
    return true
end

-- Returns the bar type ("buffs", "cooldowns", "utility", etc.) for a given barKey.
local function GetBarType(barKey)
    if barKey == "cooldowns" then return "cooldowns" end
    if barKey == "utility"   then return "utility"   end
    if barKey == "buffs"     then return "buffs"     end
    local bd = barDataByKey[barKey]
    return bd and bd.barType
end

-------------------------------------------------------------------------------
--  Centralized Spell Assignment Checks
--  Used by spell pickers, overlay system, and options to determine:
--  1. Is a spell already on ANY bar (CDM bars + TBB)?
--  2. Is a spell tracked in the correct Blizzard CDM section for a bar type?
-------------------------------------------------------------------------------

--- Check if a spell is already assigned to another bar within the SAME family.
--- CD/utility bars only check other CD/utility bars.
--- Buff bars only check other buff bars.
--- TBB bars only check other TBB bars.
--- Returns nil if not found, or the bar's display name if found.
--- excludeBarKey: skip this bar (so the current bar doesn't block itself).
SpellUsedOnAnyOtherBar = function(spellID, excludeBarKey)
    local p = ECME.db.profile
    local excludeType = GetBarType(excludeBarKey)
    local excludeIsBuff = (excludeType == "buffs")
    local _FindOverride = C_SpellBook and C_SpellBook.FindSpellOverrideByID

    -- Check CDM bars (same family only, skip ghost bars)
    for _, b in ipairs(p.cdmBars.bars) do
        if b.key ~= excludeBarKey and not b.isGhostBar then
            local otherType = GetBarType(b.key)
            local otherIsBuff = (otherType == "buffs")
            if excludeIsBuff == otherIsBuff then
                local sd = ns.GetBarSpellData(b.key)
                if sd and sd.assignedSpells then
                    for _, sid in ipairs(sd.assignedSpells) do
                        if sid == spellID then return b.name or b.key end
                        -- Also match talent overrides (e.g. Avenging Wrath → Avenging Crusader)
                        if _FindOverride and sid > 0 then
                            local ovr = _FindOverride(sid)
                            if ovr and ovr > 0 and ovr == spellID then return b.name or b.key end
                        end
                    end
                end
            end
        end
    end
    return nil
end
ns.SpellUsedOnAnyOtherBar = SpellUsedOnAnyOtherBar

--- Same check but for TBB (Tracking Bars check other Tracking Bars only).
function ns.SpellUsedOnAnyOtherTBB(spellID, excludeIdx)
    local tbb = ns.GetTrackedBuffBars and ns.GetTrackedBuffBars()
    if not tbb or not tbb.bars then return nil end
    for i, cfg in ipairs(tbb.bars) do
        if i ~= excludeIdx then
            if cfg.spellID and cfg.spellID == spellID then
                return cfg.name or ("Tracking Bar " .. i)
            end
            if cfg.spellIDs then
                for _, sid in ipairs(cfg.spellIDs) do
                    if sid == spellID then return cfg.name or ("Tracking Bar " .. i) end
                end
            end
        end
    end
    return nil
end

--- Check if a spell is tracked in the correct Blizzard CDM section for a bar type.
--- Returns true if the spell is properly tracked (no popup/overlay needed).
---
--- Rules:
---   CD/utility bar: must be in Essential/Utility viewer
---   Buff bar: must be in BuffIcon viewer (not just Tracked Bars)
---   TBB: must be in BuffBar viewer (not just Tracked Buffs)
--- Cached spell lookup sets. Rebuilt once per RebuildCDMSpellCaches() call
--- instead of doing full category scans per-frame.
local _knownSpellSet = {}    -- learned spells (cat, false)
local _allSpellSet = {}      -- all spells including unlearned (cat, true)
local _cdmSpellCacheDirty = true

function ns.MarkCDMSpellCacheDirty()
    _cdmSpellCacheDirty = true
end

local function RebuildCDMSpellCaches()
    if not _cdmSpellCacheDirty then return end
    _cdmSpellCacheDirty = false
    wipe(_knownSpellSet)
    wipe(_allSpellSet)
    if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCategorySet then return end
    local gci = C_CooldownViewer.GetCooldownViewerCooldownInfo
    if not gci then return end
    for cat = 0, 3 do
        local knownIDs = C_CooldownViewer.GetCooldownViewerCategorySet(cat, false)
        if knownIDs then
            for _, cdID in ipairs(knownIDs) do
                local info = gci(cdID)
                if info then
                    if info.spellID and info.spellID > 0 then
                        _knownSpellSet[info.spellID] = true
                    end
                    if info.overrideSpellID and info.overrideSpellID > 0 then
                        _knownSpellSet[info.overrideSpellID] = true
                    end
                    local sid = ns.ResolveInfoSpellID(info)
                    if sid and sid > 0 then _knownSpellSet[sid] = true end
                end
            end
        end
        local allIDs = C_CooldownViewer.GetCooldownViewerCategorySet(cat, true)
        if allIDs then
            for _, cdID in ipairs(allIDs) do
                local info = gci(cdID)
                if info then
                    if info.spellID and info.spellID > 0 then
                        _allSpellSet[info.spellID] = true
                    end
                    if info.overrideSpellID and info.overrideSpellID > 0 then
                        _allSpellSet[info.overrideSpellID] = true
                    end
                    local sid = ns.ResolveInfoSpellID(info)
                    if sid and sid > 0 then _allSpellSet[sid] = true end
                end
            end
        end
    end
end
ns.RebuildCDMSpellCaches = RebuildCDMSpellCaches

function ns.IsSpellKnownInCDM(spellID)
    if not spellID or spellID <= 0 then return false end
    RebuildCDMSpellCaches()
    return _knownSpellSet[spellID] == true
end

function ns.IsSpellInAnyCDMCategory(spellID)
    if not spellID or spellID <= 0 then return false end
    RebuildCDMSpellCaches()
    return _allSpellSet[spellID] == true
end

function ns.IsSpellTrackedForBarType(spellID, barType)
    if not spellID or spellID <= 0 then return false end
    if barType == "buffs" then
        return ns._tickBuffIconTrackedSet[spellID] and true or false
    elseif barType == "tbb" then
        -- Frame-based: iterate BuffBarCooldownViewer pool with robust
        -- multi-field matching instead of spell-ID cache lookup.
        return ns.IsSpellInBuffBarViewer and ns.IsSpellInBuffBarViewer(spellID) or false
    else
        -- Frame-based: iterate Essential/Utility viewer pools with robust
        -- multi-field matching instead of spell-ID cache lookup.
        return ns.IsSpellInCDUtilViewer and ns.IsSpellInCDUtilViewer(spellID) or false
    end
end

--- Add a preset group to a bar.
--- For custom_buff bars: adds ALL spell IDs as plain entries (each gets
--- its own C_UnitAuras check — only the active variant shows).
--- For other bars: adds primary ID with duration/group metadata.
function ns.AddPresetToBar(barKey, preset)
    local sd = ns.GetBarSpellData(barKey)
    if not sd then return false end
    if not sd.assignedSpells then sd.assignedSpells = {} end
    local spellList = sd.assignedSpells

    -- Check bar type
    local bd = barDataByKey[barKey]
    local isCustomBuff = bd and bd.barType == "custom_buff"

    if isCustomBuff then
        if preset.glowBased then
            -- Glow-based presets removed (Time Spiral etc.)
            return false
        else
            local primaryID = preset.spellIDs[1]
            for _, existing in ipairs(spellList) do
                if existing == primaryID then return false, "exists" end
            end
            spellList[#spellList + 1] = primaryID
            if not sd.spellDurations then sd.spellDurations = {} end
            sd.spellDurations[primaryID] = preset.duration or 30
        end
    else
        -- Legacy: add primary ID with duration/group metadata
        local primaryID = preset.spellIDs[1]
        for _, existing in ipairs(spellList) do
            if existing == primaryID then return false, "exists" end
        end
        spellList[#spellList + 1] = primaryID
        if not sd.customSpellDurations then sd.customSpellDurations = {} end
        sd.customSpellDurations[primaryID] = preset.duration
        if not sd.customSpellGroups then sd.customSpellGroups = {} end
        for _, sid in ipairs(preset.spellIDs) do
            sd.customSpellGroups[sid] = primaryID
        end
    end

    local frame = cdmBarFrames[barKey]
    if frame then frame._blizzCache = nil; frame._prevVisibleCount = nil end
    return true
end

--- Add a tracked spell (spellID) to a bar
function ns.AddTrackedSpell(barKey, id)
    local sd = ns.GetBarSpellData(barKey)
    if not sd then return false end
    if not sd.assignedSpells then sd.assignedSpells = {} end

    -- If this spell is a conditional override (e.g. Glacial Spike),
    -- store the base spell (e.g. Frostbolt) instead. The base spell
    -- is stable across state changes; the route map's forward lookup
    -- (FindSpellOverrideByID) maps base -> active override at runtime.
    if id > 0 and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
       and C_CooldownViewer.GetCooldownViewerCooldownInfo then
        local bd0 = barDataByKey[barKey]
        local barType = bd0 and bd0.barType
        -- Only for Essential/Utility bars (main and custom CD/utility)
        if barType ~= "buffs" and barType ~= "custom_buff" then
            local originalID = id
            for cat = 0, 3 do
                if id ~= originalID then break end  -- already resolved
                local allIDs = C_CooldownViewer.GetCooldownViewerCategorySet(cat, true)
                if allIDs then
                    for _, cdID in ipairs(allIDs) do
                        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                        if info and info.overrideSpellID == originalID
                           and info.spellID and info.spellID > 0
                           and info.spellID ~= originalID then
                            id = info.spellID
                            break
                        end
                    end
                end
            end
        end
    end

    for _, existing in ipairs(sd.assignedSpells) do
        if existing == id then return false end
    end
    local bd = barDataByKey[barKey]
    local numRows = bd and bd.numRows or 1
    if numRows < 1 then numRows = 1 end
    local curCount = #sd.assignedSpells
    local stride, _, topRowCount = ComputeTopRowStride(bd or {}, curCount)
    if stride < 1 then stride = 1 end
    local newCount = curCount + 1
    local newStride, _, newTopRow = ComputeTopRowStride(bd or {}, newCount)
    if newStride < 1 then newStride = 1 end
    if newStride == stride and newTopRow > topRowCount then
        table.insert(sd.assignedSpells, topRowCount + 1, id)
    else
        sd.assignedSpells[newCount] = id
    end
    if sd.removedSpells then sd.removedSpells[id] = nil end
    -- Remove from ghost CD bar if it was previously "removed" (routed there)
    local ghostKey = ns.GHOST_CD_BAR_KEY
    if ghostKey then
        local ghostSD = ns.GetBarSpellData(ghostKey)
        if ghostSD and ghostSD.assignedSpells then
            for gi = #ghostSD.assignedSpells, 1, -1 do
                if ghostSD.assignedSpells[gi] == id then
                    table.remove(ghostSD.assignedSpells, gi)
                end
            end
        end
    end
    local frame = cdmBarFrames[barKey]
    if frame then frame._blizzCache = nil; frame._prevVisibleCount = nil end
    if ns.RebuildSpellRouteMap then ns.RebuildSpellRouteMap() end
    if ns.QueueReanchor then ns.QueueReanchor() end
    return true
end

--- Remove a tracked spell by index. Routes the spell to the ghost CD
--- bar so it stays in the routing system (cdidRouteMap) but is hidden.
function ns.RemoveTrackedSpell(barKey, idx)
    local sd = ns.GetBarSpellData(barKey)
    if not sd then return false end
    local list = sd.assignedSpells
    if not list or idx < 1 or idx > #list then return false end
    -- Guard: dividers are not tracked spells; delegate to RemoveDivider instead.
    if list[idx] == ns.CDM_DIVIDER_ID then
        return ns.RemoveDivider(barKey, idx) or false
    end
    -- Prevent emptying default bars (cooldowns/utility)
    if (barKey == "cooldowns" or barKey == "utility") and #list <= 1 then
        print("|cffff6060[EllesmereUI CDM]|r Cannot remove the last spell from a default bar.")
        return false
    end
    local removedID = list[idx]
    table.remove(list, idx)
    -- Route to ghost CD bar (replaces the old removedSpells mechanism).
    -- The spell stays routed via cdidRouteMap but the ghost bar is hidden.
    -- Only Blizzard viewer spells (positive IDs) go to ghost bar.
    -- Presets (trinkets <= -13, items <= -100) are not viewer spells.
    local ghostKey = ns.GHOST_CD_BAR_KEY
    local isNonViewer = removedID and removedID > 0
        and ((sd.customSpellIDs and sd.customSpellIDs[removedID])
          or (ns._myRacialsSet and ns._myRacialsSet[removedID]))
    if removedID and removedID > 0 and not isNonViewer and ghostKey then
        local ghostSD = ns.GetBarSpellData(ghostKey)
        if ghostSD then
            if not ghostSD.assignedSpells then ghostSD.assignedSpells = {} end
            local found = false
            for _, existing in ipairs(ghostSD.assignedSpells) do
                if existing == removedID then found = true; break end
            end
            if not found then
                ghostSD.assignedSpells[#ghostSD.assignedSpells + 1] = removedID
            end
        end
    end
    if removedID and sd.customSpellDurations then
        sd.customSpellDurations[removedID] = nil
    end
    if removedID and sd.customSpellIDs then
        sd.customSpellIDs[removedID] = nil
    end
    if removedID and sd.customSpellGroups then
        for variantID, primaryID in pairs(sd.customSpellGroups) do
            if primaryID == removedID then
                sd.customSpellGroups[variantID] = nil
            end
        end
    end
    local frame = cdmBarFrames[barKey]
    if frame then frame._blizzCache = nil; frame._prevVisibleCount = nil end
    if ns.RebuildSpellRouteMap then ns.RebuildSpellRouteMap() end
    if ns.QueueReanchor then ns.QueueReanchor() end
    return true
end

--- Replace a tracked spell at a given index with a new spellID
function ns.ReplaceTrackedSpell(barKey, idx, newID)
    local sd = ns.GetBarSpellData(barKey)
    if not sd then return false end
    if not sd.assignedSpells then sd.assignedSpells = {} end
    local list = sd.assignedSpells
    if idx < 1 then return false end
    while #list < idx do list[#list + 1] = 0 end
    -- Remove duplicate if newID already exists at a different index
    for i, existing in ipairs(list) do
        if existing == newID and i ~= idx then
            table.remove(list, i)
            if i < idx then idx = idx - 1 end
            break
        end
    end
    list[idx] = newID
    while #list > 0 and (list[#list] == 0 or list[#list] == nil) do list[#list] = nil end
    if sd.removedSpells then sd.removedSpells[newID] = nil end
    local frame = cdmBarFrames[barKey]
    if frame then frame._blizzCache = nil; frame._prevVisibleCount = nil end
    if ns.QueueReanchor then ns.QueueReanchor() end
    return true
end

-- Add a new custom CDM bar
function ns.AddCDMBar(barType, name, numRows)
    local BuildAllCDMBars = ns.BuildAllCDMBars
    local LayoutCDMBar = ns.LayoutCDMBar
    local RegisterCDMUnlockElements = ns.RegisterCDMUnlockElements
    local MAX_CUSTOM_BARS = ns.MAX_CUSTOM_BARS

    local p = ECME.db.profile
    local bars = p.cdmBars.bars
    -- Count existing custom bars (non-default)
    local customCount = 0
    for _, b in ipairs(bars) do
        if b.key ~= "cooldowns" and b.key ~= "utility" and b.key ~= "buffs" and not b.isGhostBar then
            customCount = customCount + 1
        end
    end
    if customCount >= MAX_CUSTOM_BARS then return nil end
    -- Determine bar type label for default name
    barType = barType or "cooldowns"
    local typeLabel = barType == "cooldowns" and "Cooldowns"
                   or barType == "utility" and "Utility"
                   or barType == "buffs" and "Buffs"
                   or barType == "custom_buff" and "Auras"
                   or "Cooldowns"
    -- Count existing custom bars of this type for numbering
    local typeCount = 0
    for _, b in ipairs(bars) do
        if b.barType == barType then typeCount = typeCount + 1 end
    end
    local key = "custom_" .. (#bars + 1) .. "_" .. GetTime()
    key = key:gsub("%.", "_")
    bars[#bars + 1] = {
        key = key, name = name or ("Custom " .. typeLabel .. " Bar " .. (typeCount + 1)),
        barType = barType,
        enabled = true, iconSize = 36, numRows = numRows or 1,
        spacing = 2,
        borderSize = 1, borderR = 0, borderG = 0, borderB = 0, borderA = 1,
        borderClassColor = false, borderThickness = "thin",
        bgR = 0.08, bgG = 0.08, bgB = 0.08, bgA = 0.6,
        iconZoom = 0.08, iconShape = "none",
        verticalOrientation = false, barBgEnabled = false,        barBgR = 0, barBgG = 0, barBgB = 0,
        showCooldownText = true, cooldownFontSize = 12,
        showCharges = true, chargeFontSize = 11,
        desaturateOnCD = true, swipeAlpha = 0.7,
        activeStateAnim = "blizzard",
        anchorTo = "none", anchorPosition = "left",
        anchorOffsetX = 0, anchorOffsetY = 0,
        barVisibility = "always", housingHideEnabled = true,
        visHideHousing = true, visOnlyInstances = false,
        visHideMounted = false, visHideNoTarget = false, visHideNoEnemy = false,
        showStackCount = false, stackCountSize = 11,
        stackCountX = 0, stackCountY = 0,
        stackCountR = 1, stackCountG = 1, stackCountB = 1,
        -- Custom bars use a spell list instead of mirroring Blizzard
        outOfRangeOverlay = false,
        pandemicGlow = false,
        pandemicGlowStyle = 1,
        pandemicGlowColor = { r = 1, g = 1, b = 0 },
        pandemicGlowLines = 8,
        pandemicGlowThickness = 2,
        pandemicGlowSpeed = 4,
    }
    -- Initialize spell data in the global store for this custom bar
    local sd = ns.GetBarSpellData(key)
    if sd then sd.assignedSpells = {} end
    BuildAllCDMBars()
    LayoutCDMBar(key)
    if ns.QueueReanchor then ns.QueueReanchor() end
    RegisterCDMUnlockElements()
    return key
end

-- Remove a custom CDM bar (only custom bars, not the 3 defaults)
function ns.RemoveCDMBar(key)
    if key == "cooldowns" or key == "utility" or key == "buffs" then return false end
    local RegisterCDMUnlockElements = ns.RegisterCDMUnlockElements
    local p = ECME.db.profile
    for i, barData in ipairs(p.cdmBars.bars) do
        if barData.key == key then
            -- Clean up frame
            local frame = cdmBarFrames[key]
            if frame then EllesmereUI.SetElementVisibility(frame, false) end
            cdmBarFrames[key] = nil
            cdmBarIcons[key] = nil
            p.cdmBarPositions[key] = nil
            table.remove(p.cdmBars.bars, i)
            -- Clean up orphaned spell data for the deleted bar (all specs)
            local sa = EllesmereUIDB and EllesmereUIDB.spellAssignments
            local sp = sa and sa.specProfiles
            if sp then
                for _, specData in pairs(sp) do
                    if specData.barSpells and specData.barSpells[key] then
                        specData.barSpells[key] = nil
                    end
                end
            end
            -- Unregister from unlock mode
            if EllesmereUI and EllesmereUI.UnregisterUnlockElement then
                EllesmereUI:UnregisterUnlockElement("CDM_" .. key)
            end
            -- Re-register remaining bars to update linkedKeys
            RegisterCDMUnlockElements()
            -- Rebuild route maps and reanchor so frames stop routing
            -- to the deleted bar key
            if ns.RebuildSpellRouteMap then ns.RebuildSpellRouteMap() end
            if ns.QueueReanchor then ns.QueueReanchor() end
            return true
        end
    end
    return false
end

-------------------------------------------------------------------------------
--  Ghost Buff Bar helpers: route/unroute spells to hide them from buff bars
-------------------------------------------------------------------------------
function ns.HideBuffSpell(spellID)
    if not spellID or spellID <= 0 then return end
    local ghostKey = ns.GHOST_BUFF_BAR_KEY
    if not ghostKey then return end
    local sd = ns.GetBarSpellData(ghostKey)
    if not sd then return end
    if not sd.assignedSpells then sd.assignedSpells = {} end
    for _, sid in ipairs(sd.assignedSpells) do
        if sid == spellID then return end
    end
    sd.assignedSpells[#sd.assignedSpells + 1] = spellID
    if ns.RebuildSpellRouteMap then ns.RebuildSpellRouteMap() end
    if ns.QueueReanchor then ns.QueueReanchor() end
end

function ns.UnhideBuffSpell(spellID)
    if not spellID or spellID <= 0 then return end
    local ghostKey = ns.GHOST_BUFF_BAR_KEY
    if not ghostKey then return end
    local sd = ns.GetBarSpellData(ghostKey)
    if not sd or not sd.assignedSpells then return end
    for i = #sd.assignedSpells, 1, -1 do
        if sd.assignedSpells[i] == spellID then
            table.remove(sd.assignedSpells, i)
        end
    end
    if ns.RebuildSpellRouteMap then ns.RebuildSpellRouteMap() end
    if ns.QueueReanchor then ns.QueueReanchor() end
end

function ns.IsBuffSpellHidden(spellID)
    if not spellID or spellID <= 0 then return false end
    local ghostKey = ns.GHOST_BUFF_BAR_KEY
    if not ghostKey then return false end
    local sd = ns.GetBarSpellData(ghostKey)
    if not sd or not sd.assignedSpells then return false end
    for _, sid in ipairs(sd.assignedSpells) do
        if sid == spellID then return true end
    end
    return false
end

-- Insert a visual space divider before position `beforeIdx` in assignedSpells.
function ns.InsertDivider(barKey, beforeIdx)
    local sd = ns.GetBarSpellData(barKey)
    if not sd or not sd.assignedSpells then return end
    table.insert(sd.assignedSpells, beforeIdx, ns.CDM_DIVIDER_ID)
    if ns.FullCDMRebuild then ns.FullCDMRebuild("divider_insert") end
end

-- Remove a divider at index `idx` (no-op if the entry is not a divider).
function ns.RemoveDivider(barKey, idx)
    local sd = ns.GetBarSpellData(barKey)
    if not sd or not sd.assignedSpells then return end
    if sd.assignedSpells[idx] == ns.CDM_DIVIDER_ID then
        table.remove(sd.assignedSpells, idx)
        if ns.FullCDMRebuild then ns.FullCDMRebuild("divider_remove") end
    end
end
