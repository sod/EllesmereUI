# CDM Bar Dividers

## Context

CDM bars display cooldown icons as a dense row: `a-b-c-d-e-f`. There is no way to
visually separate groups of spells. Users want to inject empty-space dividers between
groups to improve readability: `a-b  c-d  e-f`.

## Goal

Add support for divider entries in CDM bars — empty visual slots that push subsequent
icons to the right (or down for vertical bars), creating group separation.

## Approach

Store dividers as a sentinel value (`-1`) directly inside the existing `assignedSpells`
array alongside spell IDs. This is zero-migration: the array is already mixed (spells,
trinket slots -13/-14, item presets ≤-100); -1 slots neatly into the unused range.

Each divider occupies **one visual slot** (iconSize + spacing) of empty space, identical
to what a hidden icon would look like. In `LayoutCDMBar`, a `dividerOffsets` table maps
each real icon index → number of dividers before it, shifting the icon's visual column
by that count. The bar container grows to include the extra slots. The preview in Options
already iterates `assignedSpells` entry-by-entry, so dividers naturally appear as empty
grey slots.

Dividers can be inserted via a right-click context option on any spell slot, and removed
via right-click or middle-click on a divider slot. Drag-drop reorder already works
index-by-index on `assignedSpells`, so dividers can be repositioned for free.

---

## File Changes

### 1. `EllesmereUICooldownManager.lua` — **Modify**

**a) Define constant** (top of file, near other `ns.*` definitions):
```lua
ns.CDM_DIVIDER_ID = -1
```

**b) `CountCDMBarSpells` (~line 2319)**
Currently counts every `sid ~= 0`. Since `-1` satisfies that, dividers are already
counted — which is correct (they occupy visual slots). No change needed, but add a
comment clarifying the intent.

**c) `ComputeCDMBarSize` (~line 2329)**
No change needed; it calls `ComputeTopRowStride(barData, count)` where `count` already
includes dividers via `CountCDMBarSpells`.

**d) `ComputeTopRowStride` (~line 2298)**
No change. Receives total slot count (icons + dividers) from callers.

**e) Add helper `BuildDividerOffsets(barKey)` (new, just before `LayoutCDMBar`)**
Returns `offsets` table and `totalDividers` count:
```lua
local function BuildDividerOffsets(barKey)
    local sd = ns.GetBarSpellData(barKey)
    local spells = sd and sd.assignedSpells
    if not spells then return {}, 0 end
    local offsets, iconIdx, divCount = {}, 0, 0
    for _, sid in ipairs(spells) do
        if sid == ns.CDM_DIVIDER_ID then
            divCount = divCount + 1
        elseif sid and sid ~= 0 then
            iconIdx = iconIdx + 1
            offsets[iconIdx] = divCount   -- dividers before this icon
        end
    end
    return offsets, divCount
end
```

**f) `LayoutCDMBar` (~line 2371)** — core layout change

After computing `count` / `sizeCount`, call `BuildDividerOffsets` and add
`totalDividers` to `sizeCount`:

```lua
local dividerOffsets, totalDividers = BuildDividerOffsets(barKey)
sizeCount = sizeCount + totalDividers   -- widen container for extra slots
```

In the icon-positioning loop (~line 2507), replace the col/row mapping:

```lua
-- Was: col = i - 1  (for top row)
-- Now: account for dividers before this icon
local visualSlot  -- 0-based
if i <= topRowCount then
    visualSlot = (i - 1) + (dividerOffsets[i] or 0)
    col = visualSlot   -- single row: col == visualSlot
    row = 0
else
    local bottomIdx = (i - topRowCount - 1) + (dividerOffsets[i] or 0)
    col = bottomIdx % stride
    row = 1 + math.floor(bottomIdx / stride)
end
```

Also update `sizeCount` calculation to count dividers in the existing trinket/spell
loop:
```lua
-- Add to the visibleAssigned loop:
elseif sid == ns.CDM_DIVIDER_ID then
    visibleAssigned = visibleAssigned + 1
```

---

### 2. `EllesmereUICdmHooks.lua` — **Modify**

**`spellOrder` building loop (~line 1331)** — skip dividers so sort indices are
sequential without gaps and no stale `-1` key is written:

```lua
-- Change condition from:
if sid and sid ~= 0 then
-- To:
if sid and sid ~= 0 and sid ~= ns.CDM_DIVIDER_ID then
```

Dividers generate no frames and need no sort order entry.

---

### 3. `EllesmereUICdmSpellPicker.lua` — **Modify**

Add two new public functions:

```lua
-- Insert a divider before position `beforeIdx` in assignedSpells
function ns.InsertDivider(barKey, beforeIdx)
    local sd = ns.GetBarSpellData(barKey)
    if not sd or not sd.assignedSpells then return end
    table.insert(sd.assignedSpells, beforeIdx, ns.CDM_DIVIDER_ID)
    if ns.FullCDMRebuild then ns.FullCDMRebuild("divider_insert") end
end

-- Remove a divider at index `idx` (no-op if the entry is not a divider)
function ns.RemoveDivider(barKey, idx)
    local sd = ns.GetBarSpellData(barKey)
    if not sd or not sd.assignedSpells then return end
    if sd.assignedSpells[idx] == ns.CDM_DIVIDER_ID then
        table.remove(sd.assignedSpells, idx)
        if ns.FullCDMRebuild then ns.FullCDMRebuild("divider_remove") end
    end
end
```

Also: `RemoveTrackedSpell` currently routes spells to a ghost bar. Ensure it guards
against being called on a divider index by checking for `CDM_DIVIDER_ID` at the start
and returning (or delegating to `RemoveDivider` instead).

---

### 4. `EUI_CooldownManager_Options.lua` — **Modify**

**a) Preview `Update()` — slot rendering (~line 6996)**

Add a divider check at the top of the slot rendering block:

```lua
local isDivider = (id == ns.CDM_DIVIDER_ID)
slot._isDivider = isDivider

if isDivider then
    slot._icon:SetTexture(nil)
    slot._previewSpellID = nil
    -- Render as faint empty placeholder to distinguish from normal blank slots
    slot._bg:SetColorTexture(0.3, 0.3, 0.3, 0.25)
else
    -- existing icon/trinket/item rendering unchanged
end
```

**b) Preview `Update()` — stride / gridSlots (~line 6875)**

`count = #tracked` already includes dividers (they are in `tracked` because `sid <= 0`
passes the filter). The stride and container-size calculations use `count`, so they
automatically account for dividers. No code changes needed here.

**c) Click handler for divider slots (~line 6402)**

Add a guard at the top of `OnClick`:

```lua
-- Divider slot: middle-click removes, right-click shows mini context menu
if self._isDivider then
    if button == "MiddleButton" then
        ns.RemoveDivider(bd.key, self._slotIdx)
        RefreshCDPreview()
    elseif button == "RightButton" or button == "LeftButton" then
        ShowDividerContextMenu(self, bd.key, self._slotIdx)
    end
    return
end
```

**d) New function `ShowDividerContextMenu(anchor, barKey, idx)`**

Simple dropdown using the addon's existing styling, with one option: "Remove Divider".

**e) "Insert Divider" option for spell slots**

In the right-click / `ShowSpellPicker` flow, add: **"Insert Divider Before"** (inserts
at `si`) and **"Insert Divider After"** (inserts at `si + 1`). Exact integration point
confirmed when reading `ShowSpellPicker` during implementation.

---

## Implementation Steps

### Task 1 — Constant + core helpers
1. Add `ns.CDM_DIVIDER_ID = -1` near top of `EllesmereUICooldownManager.lua`
2. Add `BuildDividerOffsets(barKey)` helper just before `LayoutCDMBar`

### Task 2 — Layout engine
3. Update `LayoutCDMBar`: call `BuildDividerOffsets`, add dividers to `sizeCount`, update col/row mapping to use visual slot indices
4. Update `EllesmereUICdmHooks.lua` `spellOrder` loop to skip dividers

### Task 3 — API
5. Add `ns.InsertDivider` and `ns.RemoveDivider` to `EllesmereUICdmSpellPicker.lua`
6. Guard `ns.RemoveTrackedSpell` against being called on a divider index

### Task 4 — Options UI
7. Update preview slot rendering in `Update()` to render divider slots as grey placeholders
8. Add divider guard and mini context menu to `OnClick` handler
9. Add `ShowDividerContextMenu` function
10. Add "Insert Divider Before/After" option to the existing right-click spell context menu

---

## Acceptance Criteria

- [ ] A bar with `assignedSpells = [A, B, -1, C, D]` displays A and B, a gap the width of one icon, then C and D. Container width = 5 icon slots.
- [ ] Multiple consecutive dividers each add one full slot of extra space.
- [ ] Trailing divider widens the container with no icon after it.
- [ ] Inserting a divider via right-click "Insert Divider Before/After" places it correctly in `assignedSpells` and the bar updates immediately.
- [ ] Removing a divider (middle-click or right-click "Remove Divider") removes it and the bar tightens immediately.
- [ ] Drag-drop reorder of dividers in the preview works (divider can be moved between spell positions).
- [ ] Single-row bar with dividers: icons and gaps rendered correctly for all five grow directions (RIGHT, LEFT, CENTER, UP, DOWN).
- [ ] Bars without any dividers are completely unchanged in behaviour.
- [ ] Preview in Options shows divider slots as faint grey placeholder squares.

---

## Verification Steps

1. **In-game, single-row bar (RIGHT grow)**: Add spells A, B, C → right-click B → "Insert Divider After" → gap appears between B and C; container widens by one slot.
2. **Remove**: Right-click divider → "Remove Divider" → gap closes.
3. **LEFT grow bar**: Same test — verify gap direction is correct.
4. **Options preview**: Open EllesmereUI options → CDM panel → select bar → divider shows as empty grey box at correct position.
5. **Drag-drop**: Drag divider slot to new position; verify `assignedSpells` updates and bar re-layouts.
6. **No regression**: A bar with zero dividers lays out identically to before.

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| `-1` used elsewhere as a valid spell ID | Spell IDs are always ≥ 0; negative values already reserved by this addon for trinkets/items |
| Multi-row + dividers: centering calculations off | Accept for v1 — single-row is the primary use case; multi-row may be imprecise but not broken |
| `ShowSpellPicker` internals complex to extend | Read the function during implementation; fallback: show a separate minimal dropdown for divider insert |
| Drag ghost frame for a divider looks blank | Grey ghost during drag is acceptable and distinguishable |
| `RemoveTrackedSpell` routed incorrectly on divider index | Explicit guard added; dividers are never routed to ghost bar |
