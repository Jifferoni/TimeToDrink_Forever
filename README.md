# Time To Drink (Forever)

**WoW Forever addon · v1.0.0-beta**
By Jifferoni / Deedee Megadoodu

## Why this exists

Your tank pulled the whole room. Again. Your healer is at 4% mana, clutching a drink they never got to open. Time To Drink watches their mana and tells the party to hold the pull. Hydrated healers keep you alive.

## Install

1. Copy the `TimeToDrink_Forever` folder into:
   ```
   <World of Warcraft>\_forever_\Interface\AddOns\
   ```
   During the beta the folder may be `_classic_beta_` instead.
2. You should end up with:
   ```
   ...\Interface\AddOns\TimeToDrink_Forever\TimeToDrink_Forever.toc
   ...\Interface\AddOns\TimeToDrink_Forever\TimeToDrink_Forever.lua
   ```
3. Restart the game. A new addon folder isn't picked up by `/reload`.

> If the AddOns list says **"out of date"**, tick **Load out of date AddOns**. The interface number (16001) is the beta value and may change at launch.

## Opening it

- Type `/ttd`
- Click the addon compartment button (the little drawer by the minimap)
- Or go to **Options > AddOns > Time To Drink**

## The window

- **Healer:** pick from your group. Solo, you are picked automatically. Joining a new party clears it and opens the window.
- **Live mana bar:** blue, turns amber below Low and red below OOM. The red and amber zones and marker lines show where alerts fire.
- **Sliders:** Low and OOM. Low always stays at least 5% above OOM; raising OOM pushes Low up with it. The mouse wheel nudges by 1%.
- **Repeat alerts every:** 10 to 120 seconds in 5 second steps.
- **Switches:** party chat alerts, on-screen warning (only you see it), sound, and a movable mini mana bar overlay.
- **Messages:** Low mana / OOM / Healer picked tabs, clickable tokens, and a live preview. Enter saves, Escape cancels, and an empty box restores the default.

### Message tokens

| Token | Becomes |
|---|---|
| `{healer}` | The selected healer's name |
| `{mana}` | The healer's current mana % |
| `{threshold}` | Your Low mana threshold % |
| `{oom}` | Your OOM threshold % |

## WoW Forever limits (why there is a probe)

WoW Forever may hide some values from addons ("secret values") and may block addons from sending chat inside instances. This build handles both without errors:

- **Hidden mana:** the bar still fills (the game draws it), but the addon can't compare it, so no alert fires. The window says *hidden in combat*.
- **Chat locked:** party messages are skipped and the on-screen warning still shows. The footer says *Chat blocked here*.

### `/ttd probe`

Prints what your client allows: your build, whether your and your healer's mana is readable, and whether chat is locked. `/ttd probe chat` also sends one test line to party chat plus a hidden addon message, and reports whether they arrived.

Please run it in three places:

1. In a city, in a party
2. Inside a dungeon, out of combat
3. Inside a dungeon, in combat

The last result is also saved in:

```
WTF\Account\<name>\SavedVariables\TimeToDrink_Forever.lua
```

You can send that file instead of screenshots.

## Commands

| Command | What it does |
|---|---|
| `/ttd` | Open / close the window |
| `/ttd probe` | Report what this client allows |
| `/ttd probe chat` | Probe plus a real chat + addon message test |
| `/ttd test` | Show a sample on-screen warning |
| `/ttd bar` | Show / hide the mini mana bar |
| `/ttd lock` | Lock / unlock the mini mana bar |
| `/ttd scale 0.9` | Resize the window (0.6 to 1.4) |
| `/ttd reset` | Recenter the window and mini bar |
| `/ttd status` | Print current settings |

## Credits

Title font: **Pirata One** by Rodrigo Fuenzalida and Nicolas Massi, used under the SIL Open Font License 1.1 (see `Fonts\PirataOne-OFL.txt`).
