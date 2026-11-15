# BulkPalPicker

A UE4SS Lua mod for Palworld: **Shift + right-click** a Pal to act on every Pal of the same kind
on the current Palbox page.

- **Pal Merchant, sell screen:** selects all of them for sale. Shift + right-click a Pal that is
  already selected to deselect them all.
- **Pal Disassembly Conveyor** (and other Pal container screens): sends all of them across, just as
  a normal right-click does for one Pal. From the conveyor side it sends them back.

> **Disclaimer: this mod was vibe coded.** It was written with an AI assistant and
> shaped by trial and error in game, not by someone who knows Palworld's or UE4SS's
> internals. It works on my setup (Steam on Linux/Proton, the official mod loader),
> but it hasn't been reviewed or tested much beyond that. Use it at your own risk,
> and keep backups of your saves.

## Rules

- "Same kind" means the same species. Alphas count as their species (setting `SEPARATE_ALPHAS`).
- Favorite Pals are never selected or sent (`SKIP_FAVORITES`).
- Lucky Pals are only included when the Pal you click is Lucky too (`LUCKY_ONLY_WITH_LUCKY`).
- Only Pals in the same container as the one you click are affected (e.g. the Palbox). On the sell
  screen your party is always excluded.
- Nothing is confirmed for you: you still press Sell yourself, and a full conveyor simply stops
  accepting Pals.

The settings are at the top of `Scripts/main.lua`.

## Requirements

- Palworld with UE4SS (the Workshop "UE4SS Experimental (Palworld)" used by the official mod loader)

## Install

Copy this folder to `Palworld/Mods/NativeMods/UE4SS/Mods/BulkPalPicker/`
(`Scripts/main.lua` and the empty `enabled.txt`). UE4SS starts it automatically.

## How it works

- **Shift:** in menus the game's player controller does not see keyboard keys, so Shift is read
  through a UE4SS keybind on Shift + right mouse button, which reads the keyboard from Windows.
- **Sell screen** (`WBP_Shop_Pal_00_C`): a right-click calls `SelectSellSlot(slotButton)`, which
  toggles the Pal (`Unselect Sell Slot` when it was selected). The mod follows those calls to know
  what is selected, and after a Shift-click calls `SelectSellSlot` for the other matching Pals.
- **Container screens** (`WBP_IngameMenu_CommonCharacterContainer_C`): the screen remembers the slot
  under the mouse (`OnHoverPalSlot`) and a right-click sends it (`OnSendSlotInput`). The mod notes
  the hovered Pal's species and, after a Shift-click, repeats "hover, send" for the other matches.
- **Pal of a slot button:** `GetTargetSlot` returns it through an output parameter, so it is called
  with a table and read from `TargetSlot`.
- Work is done one Pal per game tick and never inside the game's own call.

The mod only hooks functions that fire on clicks and mouse-overs. It deliberately does not hook
`OnUpdateSlot_Binded`, which fires on every slot update and made the conveyor screen take ~10 s to
open during development.

## Troubleshooting

Everything is logged to `Mods/NativeMods/UE4SS/UE4SS.log` with the prefix `[BulkPalPicker]`:
the first clicks on each screen (with the detected Shift state), how many Pals were selected or
sent, why nothing was done when no match was found, and hook call counts every 30 seconds.

## Compatibility

Works with mods that enlarge the conveyor (e.g. Pal Disassembly Conveyor - 100 Slots): they replace
the conveyor object, not the container screen this mod uses.
