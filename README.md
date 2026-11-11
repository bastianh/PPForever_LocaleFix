# PP Forever – Locale Fix

A small companion addon for **PP Forever** (WoW Forever, interface 16001) that fixes
camp-buff detection on non-English clients (deDE, frFR, …).

## The problem

PP Forever detects camp buffs (*Boosted Attack Power*, *Boosted Mana Regeneration*,
*Boosted Stats*) only by their **English aura names**. On other client languages those
names never match, so PP Forever thinks the blessing is missing and keeps trying to cast
it. The server rejects the cast with *"A more powerful spell is already active"*, and
after a few seconds the same player is picked again – an endless retry loop. This hits
Social buffing hardest, since strangers near camps usually carry these buffs.

## What this addon does

It patches PP Forever from the outside, without modifying its files:

- When a blessing is rejected with *"A more powerful spell is already active"*
  (`SPELL_FAILED_AURA_BOUNCED`), that recipient + blessing family is treated as
  covered for 15 minutes. PP Forever then picks an alternative blessing or moves on
  to the next player. This compares against the client's own localized error text,
  so it works in every language.
- Covers Social buffing and the All-in-One button (target and group buffs).
- Optional: localized camp-buff names can be added to the `CAMP_NAMES` table at the
  top of `PPForever_LocaleFix.lua`, so covered players are skipped without a wasted
  cast first.

Active for Paladins only (only blessings are blocked by camp buffs).

## Installation

Copy the `PPForever_LocaleFix` folder into `Interface/AddOns/` next to `PPForever`,
enable **PP Forever - Locale Fix** in the addon list and `/reload`.

## Commands

| Command        | Description                                                  |
| -------------- | ------------------------------------------------------------ |
| `/ppfix`       | Status: hook active, rejections seen, players currently skipped |
| `/ppfix buffs` | Show your target's (or your own) buff names, IDs and icons in a copyable window; also saved to `PPForeverLocaleFixDB` (SavedVariables) on `/reload` |
| `/ppfix clear` | Forget all remembered rejections                             |

## Notes

- Requires PP Forever (tested against 1.0.124).
- Not affiliated with the PP Forever author. If PP Forever fixes this upstream,
  this addon can simply be disabled.
