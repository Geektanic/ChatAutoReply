# ChatAutoReply

ChatAutoReply is a lightweight rule-based auto-response addon for World of Warcraft.

It allows you to define multiple reply rules with per-channel control, match modes, cooldowns, and export/import functionality.

Designed primarily for guild utility use.

---

## Features

- Multiple independent reply rules
- Per-rule channel selection (Guild, Party, Raid, Whisper, Say, Yell)
- Match modes:
  - Contains
  - Starts With
  - Exact
  - Whole Word
- Per-sender cooldown
- Global safety cooldown
- Optional:
  - Ignore your own messages
  - Ignore likely addon/bot messages
- Export and import configuration
- Resizable UI
- First-match priority system (rules are evaluated top to bottom)

---

## Commands

- /car
  - Opens or closes the configuration window.
- /car export
  - Opens a copyable export string of your configuration.
- /car import
  - Opens a paste window to import a configuration string.
- /car help
  - Displays command help in chat.

---

## How Rules Work

Rules are evaluated from top to bottom.

When a message matches a rule:

1. The rule must be enabled.
2. The rule must be listening to that chat channel.
3. The message must match the rule's match mode.
4. Cooldowns must allow a reply.

Once a rule replies, evaluation stops.
Lower rules will not be checked for that message.

This allows rule priority ordering.

---

## Usage Tips

- Put more specific rules near the top.
- Place broad or catch-all rules near the bottom.
- Use "Exact" or "Starts With" to prevent accidental matches.
- Use cooldowns to avoid spam or repeated triggers.

---

## Safety

ChatAutoReply includes:
- Per-sender cooldowns
- Global cooldown
- First-match stop behavior
- Optional filtering of likely addon/system messages

Use responsibly and in accordance with Blizzard's addon policies.

---

## License

I don't know, if you steal it, give me some credit.